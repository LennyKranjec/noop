import SwiftUI
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

    init(log: BreathSessionLog? = nil, clock: @escaping () -> Date = { Date() }) {
        self.log = log ?? BreathSessionLog.shared
        self.clock = clock
    }

    private var nowTs: Int { Int(clock().timeIntervalSince1970) }

    // MARK: - Flow

    /// Start the pre-session quiet reading. `onPacedStart` runs when it ends — that is where the view
    /// starts its pacer, so no pacing ever overlaps the quiet window.
    func begin(paceBpm: Double, repo: Repository?, onPacedStart: @escaping () -> Void) {
        guard phase == .idle || phase == .done else { return }
        reset()
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

// MARK: - Views (tokens only; the design package restyles)

/// "Sit comfortably — 90 s quiet reading." with a countdown and a skip.
struct BreathSessionPhaseBanner: View {
    @ObservedObject var recorder: BreathSessionRecorder

    var body: some View {
        if recorder.phase == .preQuiet || recorder.phase == .postQuiet {
            StrandCard(padding: 14, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recorder.phase == .preQuiet
                         ? String(localized: "Sit comfortably — 90 s quiet reading.")
                         : String(localized: "Stay seated the same way — 90 s quiet reading."))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(String(localized: "Breathe normally, no pacer. The first 30 s are settling time."))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack {
                        if let end = recorder.phaseEndsAt, end > Date() {
                            Text(timerInterval: Date()...end, countsDown: true)
                                .font(StrandFont.mono(13))
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer()
                        Button(String(localized: "Skip reading")) { recorder.skipQuiet() }
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }
}

/// Before / After / During, each honest: a reading or "—" with its reason. No peak, no percentage that was
/// not computed from two gated quiet windows.
struct BreathSessionResultCard: View {
    @ObservedObject var recorder: BreathSessionRecorder

    var body: some View {
        if recorder.phase == .done, let r = recorder.result {
            StrandCard(padding: 14, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Session result")).strandOverline()
                    row(String(localized: "Before"), BreathSessionOutcome.line(r.pre))
                    row(String(localized: "After"), BreathSessionOutcome.line(r.post)
                        + (BreathSessionOutcome.changeLine(r.change).map { "   " + $0 } ?? ""))
                    if r.paceBpm > 0 {
                        // Only a paced session has a breathing swing to describe; a guided (text-only)
                        // protocol has no pace, so no During line rather than a misleading "—".
                        Text(BreathSessionOutcome.duringLine(r.duringSwingBpm))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let line = BreathSessionOutcome.comparisonLine(recorder.comparison) {
                        Text(line)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text(String(localized: "Two short readings are noisy: this describes today's session, it is not a test."))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
