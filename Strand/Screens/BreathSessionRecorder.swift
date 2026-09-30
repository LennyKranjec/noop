import SwiftUI
import Combine
import StrandAnalytics
import StrandDesign

// BreathSessionRecorder.swift — the honest session flow around Breathe's pacer (HEALTH_V2 S4 §4.1, §4.3).
//
// PHASES: idle → preQuiet (90 s, no pacer) → paced (the existing pacer, unchanged) → postQuiet (90 s,
// no pacer) → done. The recorder collects R-R per phase from the view's `onRRPackets` feed (the one
// correct way to consume packets — see RRPacketObserver.swift), stamps each packet with its arrival
// second, and hands the three windows to `BreathSessionOutcome`. The paced beats are kept apart and only
// ever feed the DURING swing.
//
// EVERY COMPLETED SESSION IS STORED (`BreathSessionLog`), including one whose quiet windows failed their
// gates — the record then says why, and the card shows "—" with that reason instead of a percentage.
//
// COST: one sleeping Task per quiet phase (no timer, no frame clock). The countdown is `Text(timerInterval:)`,
// which the system renders without a per-frame view update; it exists only while a quiet phase runs.
//
// Hooked into `BreathingView` by the design package (hand-off): begin on Start, ingest in `onRRPackets`,
// finish in `stop()`, cancel on mode change / disappear.
//
// STRAP-CUE HOOKS (BODY): the strap's own breathing pacer (`StrapCueEngine.startBreathing`) runs the same
// quiet → paced → quiet shape with no screen open. `StrapBreathSessionBridge` follows its phase callbacks
// (`onBreathPhase`, `onBreathingCancelled`) with an EXTERNALLY TIMED recorder — the engine owns the clock,
// the recorder only collects and scores — and reports the Breathe screen's own session to the engine
// (`isExternalMindfulSessionActive`) so the sitting-break nudge never buzzes into a breathing session.

@MainActor
final class BreathSessionRecorder: ObservableObject {

    enum Phase: Equatable {
        case idle, preQuiet, paced, postQuiet, done
    }

    @Published private(set) var phase: Phase = .idle
    /// When the current quiet phase ends (drives the countdown). nil outside quiet phases.
    @Published private(set) var phaseEndsAt: Date?
    @Published private(set) var result: BreathSessionOutcome.Result?
    @Published private(set) var comparison: BreathSessionOutcome.PersonalComparison?
    /// Stored sessions before this one — the comparison line only appears from 5.
    @Published private(set) var storedSessions: Int = 0

    /// Upper bound on buffered paced beats (15 min at 200 bpm with margin).
    static let maxPacedBeats = 4000
    /// A session is stored once the paced phase has run at least this long.
    static let minPacedSeconds = 60

    private var preStart = 0
    private var pacedStart = 0
    private var pacedEnd = 0
    private var postStart = 0
    private var postEnd = 0
    private var preRR: [ResonanceEngine.RrBeat] = []
    private var pacedRR: [ResonanceEngine.RrBeat] = []
    private var postRR: [ResonanceEngine.RrBeat] = []
    private var paceBpm: Double = 0
    private var quietTask: Task<Void, Never>?
    private var onPacedStart: (() -> Void)?
    private weak var repo: Repository?
    private let log: BreathSessionLog
    private let clock: () -> Date
    /// The strap pacer owns the phase clock (`StrapBreathSessionBridge`): no quiet-phase timers here.
    private var externallyTimed = false

    /// The SCREEN-driven recorders (the Breathe view's, not the strap pacer's), held WEAKLY: a recorder
    /// that goes away with its view simply drops out, so this can never latch "a session is running"
    /// after a screen vanished without cancelling (the sticky-flag failure mode). Read by the strap-cue
    /// engine through `isExternalMindfulSessionActive`.
    private static let screenRecorders = NSHashTable<BreathSessionRecorder>.weakObjects()
    /// True while a Breathe-screen session is running (quiet before, paced or quiet after).
    static var screenSessionRunning: Bool { screenRecorders.allObjects.contains { $0.isRunning } }

    init(log: BreathSessionLog? = nil, clock: @escaping () -> Date = { Date() }) {
        self.log = log ?? BreathSessionLog.shared
        self.clock = clock
    }

    /// A session is between its first quiet reading and its result.
    var isRunning: Bool { Self.isRunningPhase(phase) }

    private static func isRunningPhase(_ p: Phase) -> Bool {
        p == .preQuiet || p == .paced || p == .postQuiet
    }

    private var nowTs: Int { Int(clock().timeIntervalSince1970) }

    // MARK: - Flow

    /// Start the pre-session quiet reading. `onPacedStart` runs when it ends — that is where the view
    /// starts its pacer, so no pacing ever overlaps the quiet window.
    func begin(paceBpm: Double, repo: Repository?, externallyTimed: Bool = false,
               onPacedStart: @escaping () -> Void) {
        guard phase == .idle || phase == .done else { return }
        reset()
        self.externallyTimed = externallyTimed
        if !externallyTimed { Self.screenRecorders.add(self) }
        self.paceBpm = paceBpm
        self.repo = repo
        self.onPacedStart = onPacedStart
        preStart = nowTs
        phase = .preQuiet
        scheduleQuietEnd(seconds: BreathSessionOutcome.quietSeconds) { [weak self] in self?.startPaced() }
    }

    /// Skip the current quiet phase. The skipped window is too short and abstains honestly.
    func skipQuiet() {
        switch phase {
        case .preQuiet: startPaced()
        case .postQuiet: complete()
        default: break
        }
    }

    /// The pacer stopped: begin the post-session quiet reading.
    func finish() {
        guard phase == .paced else { return }
        pacedEnd = nowTs
        postStart = pacedEnd
        phase = .postQuiet
        scheduleQuietEnd(seconds: BreathSessionOutcome.quietSeconds) { [weak self] in self?.complete() }
    }

    /// Leaving the screen or switching mode. A session whose paced phase ran is still stored (its post
    /// reading abstains as too short); one that never got past the pre reading is dropped.
    func cancel() {
        switch phase {
        case .paced:
            pacedEnd = nowTs
            postStart = pacedEnd
            complete()
        case .postQuiet:
            complete()
        case .preQuiet:
            quietTask?.cancel()
            reset()
        case .idle, .done:
            break
        }
    }

    // MARK: - Externally timed (the strap pacer's phase callbacks)

    /// The strap pacer's quiet "before" reading ended and pacing began.
    func markPacedStart() {
        guard externallyTimed, phase == .preQuiet else { return }
        startPaced()
    }

    /// The strap pacer's quiet "after" reading ended: score and store the session.
    func completeNow() {
        guard externallyTimed else { return }
        switch phase {
        case .paced:
            pacedEnd = nowTs
            postStart = pacedEnd
            complete()
        case .postQuiet:
            complete()
        default:
            break
        }
    }

    /// The strap pacer was stopped early: drop the session (the engine's contract for
    /// `onBreathingCancelled`), whatever phase it reached.
    func discard() {
        reset()
    }

    /// One R-R packet, stamped with its arrival second.
    func ingest(_ rr: [Int]) {
        guard !rr.isEmpty else { return }
        let ts = nowTs
        let beats = rr.map { ResonanceEngine.RrBeat(ts: ts, rrMs: $0) }
        switch phase {
        case .preQuiet: preRR.append(contentsOf: beats)
        case .paced:
            pacedRR.append(contentsOf: beats)
            if pacedRR.count > Self.maxPacedBeats { pacedRR.removeFirst(pacedRR.count - Self.maxPacedBeats) }
        case .postQuiet: postRR.append(contentsOf: beats)
        case .idle, .done: break
        }
    }

    // MARK: - Internals

    private func reset() {
        quietTask?.cancel()
        quietTask = nil
        phaseEndsAt = nil
        result = nil
        comparison = nil
        preRR = []; pacedRR = []; postRR = []
        preStart = 0; pacedStart = 0; pacedEnd = 0; postStart = 0; postEnd = 0
        phase = .idle
    }

    private func scheduleQuietEnd(seconds: Int, then action: @escaping @MainActor () -> Void) {
        quietTask?.cancel()
        phaseEndsAt = clock().addingTimeInterval(TimeInterval(seconds))
        // The strap pacer ends its own quiet phases (`markPacedStart` / `completeNow`).
        guard !externallyTimed else { quietTask = nil; return }
        quietTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func startPaced() {
        guard phase == .preQuiet else { return }
        quietTask?.cancel()
        quietTask = nil
        phaseEndsAt = nil
        pacedStart = nowTs
        phase = .paced
        let go = onPacedStart
        onPacedStart = nil
        go?()
    }

    private func complete() {
        guard phase == .postQuiet || phase == .paced else { return }
        quietTask?.cancel()
        quietTask = nil
        phaseEndsAt = nil
        postEnd = nowTs
        let outcome = BreathSessionOutcome.evaluate(
            pre: .init(startTs: preStart, endTs: pacedStart, rr: preRR),
            pacedRR: pacedRR, pacedStartTs: pacedStart, pacedEndTs: pacedEnd,
            post: .init(startTs: postStart, endTs: postEnd, rr: postRR),
            paceBpm: paceBpm)
        result = outcome
        phase = .done
        guard pacedEnd - pacedStart >= Self.minPacedSeconds else { return }
        let record = BreathSessionRecord(
            id: String(preStart),
            day: Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(preStart))),
            startTs: preStart,
            pacedMinutes: Double(pacedEnd - pacedStart) / 60.0,
            outcome: outcome)
        storedSessions = BreathSessionLog.pastDeltas(log.sessions, beforeTs: preStart).count
        let log = self.log
        let repo = self.repo
        Task { @MainActor [weak self] in
            let c = await log.append(record, repo: repo)
            self?.comparison = c
        }
    }
}

// MARK: - Strap-cue hooks (HD ledger: onBreathPhase / onBreathingCancelled / isExternalMindfulSessionActive)

/// Follows the strap's breathing pacer with an externally timed `BreathSessionRecorder`, so a session
/// paced on the wrist (no screen open) gets the same honest before/after and is stored like one run from
/// the Breathe screen. R-R comes from the live state's packet counter (`rrSeq`, the one correct way to
/// consume packets — equal consecutive packets both count).
///
/// COST: one Combine subscription, alive only between the pacer's first and last phase; nothing runs
/// otherwise.
///
/// Wiring: `attach(to:)` is idempotent. The app model calls it once where it wires the strap cues (hand-off);
/// the Breathe screen also calls it on appear so the Breathe session is reported even before that lands.
@MainActor
final class StrapBreathSessionBridge {

    static let shared = StrapBreathSessionBridge()

    /// The recorder of the strap-paced session in progress (nil between sessions).
    private(set) var recorder: BreathSessionRecorder?
    private var rrSink: AnyCancellable?
    private weak var attached: StrapCueEngine?

    func attach(to cues: StrapCueEngine) {
        guard attached !== cues else { return }
        attached = cues
        cues.isExternalMindfulSessionActive = { BreathSessionRecorder.screenSessionRunning }
        cues.onBreathPhase = { [weak self, weak cues] phase, _ in
            guard let self, let cues else { return }
            self.handle(phase, settings: cues.settings)
        }
        cues.onBreathingCancelled = { [weak self] in self?.cancel() }
    }

    private func handle(_ phase: StrapCueBreathPhase, settings: StrapCueSettings) {
        switch phase {
        case .preQuietStart:
            cancel()
            let model = AppModel.shared
            let pace = StrapCueTimers.breathPlan(pacedMinutes: settings.breathingMinutes,
                                                 paceBpm: settings.breathingPaceBpm).paceBpm
            let r = BreathSessionRecorder()
            r.begin(paceBpm: pace, repo: model?.repo, externallyTimed: true, onPacedStart: {})
            recorder = r
            if let live = model?.live {
                rrSink = live.$rrSeq
                    .dropFirst()
                    .sink { [weak live, weak r] _ in
                        guard let live, let r, !live.rr.isEmpty else { return }
                        r.ingest(live.rr)
                    }
            }
        case .pacedStart:
            recorder?.markPacedStart()
        case .pacedEnd:
            recorder?.finish()
        case .postQuietEnd:
            recorder?.completeNow()
            rrSink = nil
            recorder = nil
        }
    }

    private func cancel() {
        rrSink = nil
        recorder?.discard()
        recorder = nil
    }
}

// MARK: - Views (Telos: faux-glass cards, MetricReadouts; BODY package)

/// "Sit comfortably — 90 s quiet reading." with a countdown and a skip.
///
/// COST: static apart from `Text(timerInterval:)`, which the system renders without a view update.
struct BreathSessionPhaseBanner: View {
    @ObservedObject var recorder: BreathSessionRecorder

    var body: some View {
        if recorder.phase == .preQuiet || recorder.phase == .postQuiet {
            StrandCard(tint: TelosColor.rest) {
                VStack(alignment: .leading, spacing: TelosSpace.s) {
                    HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                        Image(systemName: "waveform.path.ecg")
                            .font(TelosType.glyphChevron)
                            .foregroundStyle(TelosColor.rest)
                            .accessibilityHidden(true)
                        Text(recorder.phase == .preQuiet ? "Before" : "After")
                            .telosScale()
                            .textCase(.uppercase)
                            .foregroundStyle(TelosColor.textTertiary)
                        Spacer(minLength: TelosSpace.s)
                        if let end = recorder.phaseEndsAt, end > Date() {
                            Text(timerInterval: Date()...end, countsDown: true)
                                .font(TelosType.numeralS)
                                .foregroundStyle(TelosColor.textPrimary)
                        }
                    }
                    Text(recorder.phase == .preQuiet
                         ? String(localized: "Sit comfortably — 90 s quiet reading.")
                         : String(localized: "Stay seated the same way — 90 s quiet reading."))
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(localized: "Breathe normally, no pacer. The first 30 s are settling time."))
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(String(localized: "Skip reading")) { recorder.skipQuiet() }
                            .buttonStyle(.noopGhost)
                    }
                }
            }
        }
    }
}

/// Before / After as two `MetricReadout`s (§6.14 honest breathing), each a gated reading or "—" with its
/// reason; the change chip only when BOTH windows passed; the During swing labelled as mechanical. No
/// peak, no percentage that was not computed from two gated quiet windows, no "improved" claim — the tone
/// of the change is neutral until the personal comparison (≥ 5 sessions) says larger / similar / smaller.
struct BreathSessionResultCard: View {
    @ObservedObject var recorder: BreathSessionRecorder

    var body: some View {
        if recorder.phase == .done, let r = recorder.result {
            BreathSessionResultPanel(result: r, comparison: recorder.comparison)
        }
    }
}

/// The result layout, shared by the live result and the last stored session.
struct BreathSessionResultPanel: View {
    let result: BreathSessionOutcome.Result
    let comparison: BreathSessionOutcome.PersonalComparison?
    var title: LocalizedStringKey = "Session result"
    var at: Date? = nil

    var body: some View {
        StrandCard(tint: TelosColor.rest) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                Text(title)
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: TelosSpace.l) {
                        readout("Before", result.pre, delta: nil)
                        readout("After", result.post, delta: changeDelta)
                    }
                    VStack(alignment: .leading, spacing: TelosSpace.m) {
                        readout("Before", result.pre, delta: nil)
                        readout("After", result.post, delta: changeDelta)
                    }
                }
                if result.paceBpm > 0 {
                    // Only a paced session has a breathing swing to describe; a guided (text-only)
                    // protocol has no pace, so no During line rather than a misleading "—".
                    Text(BreathSessionOutcome.duringLine(result.duringSwingBpm))
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let line = BreathSessionOutcome.comparisonLine(comparison) {
                    Text(line)
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(String(localized: "Two short readings are noisy: this describes today's session, it is not a test."))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The change in RMSSD, only when both windows passed. Neutral tone: two 60-s windows cannot say
    /// "better".
    private var changeDelta: TelosDelta? {
        guard let c = result.change else { return nil }
        let pct = TelosDelta.value(c.deltaPct, tone: .flat)
        return TelosDelta(text: pct.text.map { $0 + " %" }, tone: .flat)
    }

    private func readout(_ label: LocalizedStringKey, _ r: BreathSessionOutcome.QuietReading,
                         delta: TelosDelta?) -> some View {
        let value: Double? = r.passed ? r.rmssd : nil
        let reason: Text? = r.abstention.map { Text(verbatim: $0.text) }
        let hr: TelosProvenance? = (r.passed ? r.meanHr : nil).map {
            TelosProvenance(sourceText: Text(verbatim: "HR \(Int($0.rounded()))"), updated: at)
        }
        return MetricReadout(label, value: value, unit: "ms", size: .large,
                             absentReason: reason, delta: delta, provenance: hr,
                             ink: TelosColor.rest)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
