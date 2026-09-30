import Foundation
import Combine
import StrandAnalytics
import WhoopProtocol
#if os(iOS)
import UIKit
#endif

/// A line in the Strap-cue history the settings screen shows: what was cued, when, and what really happened.
struct StrapCueLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let at: Date
    let kind: StrapCueKind
    let text: String
    /// true = reached the wearer (strap or phone fallback), false = not delivered, nil = not an attempt
    /// (a hold, a missed timer).
    let delivered: Bool?
}

/// An app event that may buzz the strap through `StrapCueEngine.fire(_:eventId:)` (DESIGN_V2 decisions 16–17).
enum StrapCueEvent: String, CaseIterable {
    /// Telos Lift: the rest timer the wearer started has run out. REQUESTED: no budget, no quiet hours, but
    /// the one-minute spacing and honest delivery still apply.
    case restOver
    /// A big reward moment (PR, quest/goal completed, level up). Unrequested: budgeted, never in the sleep
    /// window or quiet hours, once per event id.
    case reward
    /// A big penalty moment (the daily penalty card, a broken streak). Same rules as `reward`.
    case penalty

    var kind: StrapCueKind {
        switch self {
        case .restOver: return .restOver
        case .reward: return .reward
        case .penalty: return .penalty
        }
    }
}

/// What `fire` actually did — never what was hoped.
enum StrapCueFireResult: Equatable {
    /// Decided now: `.strap` (write issued to a reachable, accepting strap), `.phone(reason:)` (the strap could
    /// not be reached, NOOP was in front, the phone buzzed instead) or `.notDelivered(reason:)`.
    case attempted(StrapCueOutcome)
    /// The motor is busy or the one-minute spacing has not passed: the engine re-fires at `at` (≤ ~60 s) and
    /// logs the real outcome then.
    case scheduled(at: Date)
    /// Not sent: switched off, duplicate event, wrist alerts off, sleep window, quiet hours, budget spent.
    case held(StrapCueHold)
}

/// STRAP CUES — purposeful vibrations on the WHOOP strap in everyday life (Telos 2.0).
///
/// The runtime around the pure `StrandAnalytics/StrapCues` logic: it gathers the inputs (iPhone motion, live
/// strap HR, the sleep plan, what the app is doing), asks the pure detectors and gates, walks the pattern on
/// the strap through the existing buzz path, and reports HONESTLY what happened. It owns no BLE: `AppModel`
/// wires the closures below to `buzz(loops:)`, `ble.commandChannelReady` and `live.strapWritesRefused` — the
/// same reads the wake-buzz ringer uses — so a cue to an unreachable or refusing strap is logged as not
/// delivered and never claimed.
///
/// CUES: the sitting-break nudge (default ON; the priority), the breathing pacer, wind-down and "screens
/// off" at the sleep anchor's times, focus blocks and a silent meditation timer (all default OFF). The
/// patterns are defined once in `StrapCueVocabulary`; the rules (budget, quiet hours, spacing) in
/// `StrapCueGate`; the sitting-break logic in `SittingBreakDetector`.
///
/// COST (DESIGN_V2 §8, "every flourish names its cost"): one 60 s repeating main-run-loop timer while the
/// engine is started, plus a throttled tick from the live-HR sink (at most one per 55 s). Each tick runs one
/// CoreMotion activity-history query and ~1–2 pedometer history queries (the first tick after launch reads
/// ~3 h once, ~180 small queries), a pure evaluation over ≤ 180 minutes, and at most one strap write burst.
/// Nothing runs while iOS has the app suspended; a tick on the next wake catches up from the motion history.
///
/// LIMITS, stated in the UI: cues need the strap connected to this phone; timers and the pacer run while NOOP
/// is alive (foreground, or woken in the background by the strap); the phone fallback only ever fires while
/// NOOP is in front.
@MainActor
final class StrapCueEngine: ObservableObject {

    /// The one engine. `AppModel` wires and starts it; the Lift logger and the moment presenter call `fire`.
    static let shared = StrapCueEngine()

    // MARK: - Published state (the settings screen reads these)

    @Published private(set) var settings: StrapCueSettings
    @Published private(set) var motionAccess: MotionAccess
    @Published private(set) var sittingVerdict: SittingBreakVerdict = .off
    /// Observed low-movement time so far, when it could be measured.
    @Published private(set) var sittingSeconds: Int?
    /// Why the most recent ambient cue was HELD, cleared once one goes out.
    @Published private(set) var lastHold: StrapCueHold?
    @Published private(set) var remainingBudget: Int
    /// Whether the sleep anchor produced a plan for tonight or this morning.
    @Published private(set) var sleepPlanAvailable = false
    @Published private(set) var focusEndsAt: Date?
    @Published private(set) var meditationEndsAt: Date?
    @Published private(set) var breathingEndsAt: Date?
    @Published private(set) var breathingPhase: StrapCueBreathPhase?
    @Published private(set) var history: [StrapCueLogEntry] = []

    // MARK: - Wiring (set by AppModel; see the hand-off notes)

    /// Play ONE pulse of `loops` motor loops. Wired to `AppModel.buzz(loops:)`.
    var buzzPulse: ((UInt8) -> Void)?
    /// Whether a write right now could reach the strap (`ble.commandChannelReady`). Unwired = reachable, the
    /// same direction as `WakeBuzzRinger.strapReady`: this type must not invent a failure it cannot observe.
    var strapReady: (() -> Bool)?
    /// Whether the strap is refusing writes (`live.strapWritesRefused`). Unwired = not refused.
    var bondRefused: (() -> Bool)?
    /// The shared strap log (`live.append(log:)`).
    var strapLog: ((String) -> Void)?
    /// The sleep plan for the night that ENDS on the local day containing the given date, nil when the anchor
    /// abstains. Wired to package HA's `SleepScheduleProvider` (see the hand-off).
    var sleepPlan: ((Date) -> SleepSchedulePlan?)?
    /// `AppModel.activeWorkout != nil`.
    var isWorkoutActive: (() -> Bool)?
    /// A breathing / meditation session running OUTSIDE this engine (the Breathe screen, HD's recorder).
    var isExternalMindfulSessionActive: (() -> Bool)?
    /// Pacer phase boundaries, for HD's `BreathSessionRecorder` (quiet before → paced → quiet after).
    var onBreathPhase: ((StrapCueBreathPhase, Date) -> Void)?
    /// The pacer was stopped before its end: the recorder should discard the session.
    var onBreathingCancelled: (() -> Void)?
    /// A meditation timer completed on time: log `seconds` of meditation (`Repository.logMeditation`).
    var onMeditationCompleted: ((Int) -> Void)?
    /// Phone haptic for the fallback; nil = `SystemHaptics` (tap for breath phases, summon otherwise).
    var phoneHaptic: ((StrapCueKind) -> Void)?
    /// True while the morning flow is on screen (set by the iOS shell).
    var morningFlowActive = false

    // MARK: - Private

    private let defaults: UserDefaults
    private let motion = PhoneMotionSource()
    private var sittingState: SittingBreakState
    private var ledger: StrapCueLedger
    private var meditationStartedAt: Date?
    private var tickTimer: Timer?
    private var preciseTimer: Timer?
    /// When the running tick started. A Date, not a flag: a tick that never finished cannot wedge the engine
    /// (it is ignored after `tickStaleAfter`).
    private var tickStartedAt: Date?
    private var lastTickAt: Date = .distantPast
    /// Live strap HR, per local minute start → samples.
    private var hrByMinute: [Int: [Int]] = [:]
    private var breathWork: [DispatchWorkItem] = []
    /// The sitting verdict / hold last written to the logs, so a steady state is logged once, not every minute.
    private var loggedSittingKey: String?

    static let tickInterval: TimeInterval = 60
    static let hrTickThrottle: TimeInterval = 55
    static let tickStaleAfter: TimeInterval = 120
    static let maxHistory = 40

    private enum Key {
        static let settings = "strapCues.settings.v1"
        static let sitting = "strapCues.sittingState.v1"
        static let ledger = "strapCues.ledger.v1"
        static let focusEnds = "strapCues.focusEndsAt"
        static let meditationEnds = "strapCues.meditationEndsAt"
        static let meditationStarted = "strapCues.meditationStartedAt"
        static let history = "strapCues.history.v1"
    }

    init(defaults: UserDefaults = .standard) {
        // Every @Published value is set through its BACKING storage: assigning `self.x` to a wrapped property
        // before all stored properties are initialised is the "'self' used before all stored properties are
        // initialized" error that only an app-target build would catch.
        self.defaults = defaults
        let s = (StrapCueEngine.decode(StrapCueSettings.self, defaults.data(forKey: Key.settings))
                 ?? StrapCueSettings()).sanitized()
        _settings = Published(initialValue: s)
        _motionAccess = Published(initialValue: PhoneMotionSource.access())
        _remainingBudget = Published(initialValue: s.dailyBudget)
        _history = Published(initialValue: StrapCueEngine.decode([StrapCueLogEntry].self,
                                                                 defaults.data(forKey: Key.history)) ?? [])
        _focusEndsAt = Published(initialValue: defaults.object(forKey: Key.focusEnds) as? Date)
        _meditationEndsAt = Published(initialValue: defaults.object(forKey: Key.meditationEnds) as? Date)
        self.sittingState = StrapCueEngine.decode(SittingBreakState.self, defaults.data(forKey: Key.sitting)) ?? .initial
        self.ledger = StrapCueEngine.decode(StrapCueLedger.self, defaults.data(forKey: Key.ledger)) ?? .empty
        self.meditationStartedAt = defaults.object(forKey: Key.meditationStarted) as? Date
    }

    // MARK: - Lifecycle

    /// Arm the minute tick and run one now. Idempotent.
    func start() {
        if tickTimer == nil {
            let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            tickTimer = t
        }
        armPreciseTimer()
        tick()
    }

    /// Evaluate everything now. Safe to call from anywhere on the main actor, as often as you like: a tick
    /// already running is not doubled.
    func tick(now: Date = Date()) {
        if let started = tickStartedAt, now.timeIntervalSince(started) < Self.tickStaleAfter { return }
        tickStartedAt = now
        lastTickAt = now
        Task { @MainActor in
            await self.runTick(now: now)
            self.tickStartedAt = nil
        }
    }

    /// Live strap HR from the HR sink. Also the background heartbeat: a BLE wake that delivers HR ticks the
    /// engine (throttled), which is what lets a cue fire while NOOP is in the background.
    func ingestHeartRate(_ bpm: Int?, at date: Date = Date()) {
        if let bpm, (30...220).contains(bpm) {
            let sec = Int(date.timeIntervalSince1970)
            hrByMinute[sec - ((sec % 60) + 60) % 60, default: []].append(bpm)
            if hrByMinute.count > SittingBreakDetector.lookbackMinutes + 30 {
                let floor = sec - (SittingBreakDetector.lookbackMinutes + 5) * 60
                hrByMinute = hrByMinute.filter { $0.key >= floor }
            }
        }
        if date.timeIntervalSince(lastTickAt) >= Self.hrTickThrottle { tick(now: date) }
    }

    // MARK: - Settings

    func update(_ change: (inout StrapCueSettings) -> Void) {
        var s = settings
        change(&s)
        settings = s.sanitized()
        Self.encode(settings, to: defaults, key: Key.settings)
        // Switching a cue off also stops anything of it that is running, so no end cue arrives later.
        if !settings.breathingPacerEnabled && breathingEndsAt != nil { stopBreathing() }
        if !settings.focusBlocksEnabled && focusEndsAt != nil { cancelFocusBlock() }
        if !settings.meditationTimerEnabled && meditationEndsAt != nil { cancelMeditation() }
        tick()
    }

    func requestMotionAccess() async {
        motionAccess = await motion.requestAccess()
        tick()
    }

    /// Automations' "Wrist alerts" master (default OFF). Only the cues whose `heldByWristAlertsMaster` is true
    /// (wind-down, screens off) consult it; the sitting-break nudge and reward / penalty cues have their own
    /// switches alone (coordinator decision — see `StrapCueGate`).
    var wristAlertsOn: Bool { defaults.object(forKey: AppModel.wristAlertsMasterKey) as? Bool ?? false }

    // MARK: - Timers the wearer starts

    func startFocusBlock(now: Date = Date()) {
        guard settings.focusBlocksEnabled else { return }
        let end = now.addingTimeInterval(TimeInterval(settings.focusMinutes * 60))
        focusEndsAt = end
        defaults.set(end, forKey: Key.focusEnds)
        note(.focusEnd, "Focus block started: \(settings.focusMinutes) min")
        armPreciseTimer()
        tick(now: now)
    }

    func cancelFocusBlock() {
        guard focusEndsAt != nil else { return }
        focusEndsAt = nil
        defaults.removeObject(forKey: Key.focusEnds)
        note(.focusEnd, "Focus block cancelled")
        armPreciseTimer()
    }

    func startMeditation(now: Date = Date()) {
        guard settings.meditationTimerEnabled else { return }
        let minutes = max(settings.meditationMinutes, StrapCueSettings.meditationMinimumMinutes)
        let end = now.addingTimeInterval(TimeInterval(minutes * 60))
        meditationStartedAt = now
        meditationEndsAt = end
        defaults.set(now, forKey: Key.meditationStarted)
        defaults.set(end, forKey: Key.meditationEnds)
        note(.meditationEnd, "Meditation timer started: \(minutes) min")
        armPreciseTimer()
        tick(now: now)
    }

    func cancelMeditation() {
        guard meditationEndsAt != nil else { return }
        clearMeditation()
        note(.meditationEnd, "Meditation timer cancelled (not logged)")
        armPreciseTimer()
    }

    private func clearMeditation() {
        meditationEndsAt = nil
        meditationStartedAt = nil
        defaults.removeObject(forKey: Key.meditationEnds)
        defaults.removeObject(forKey: Key.meditationStarted)
    }

    // MARK: - Breathing pacer

    /// Quiet "before" reading → paced breathing (one pattern per phase) → quiet "after" reading → time's up.
    /// Runs while NOOP is alive; the phase boundaries go to `onBreathPhase` for the honest before/after.
    func startBreathing(now: Date = Date()) {
        guard settings.breathingPacerEnabled, breathingEndsAt == nil else { return }
        let plan = StrapCueTimers.breathPlan(pacedMinutes: settings.breathingMinutes, paceBpm: settings.breathingPaceBpm)
        breathingEndsAt = now.addingTimeInterval(TimeInterval(plan.totalMs) / 1000)
        note(.breathingDone, "Breathing pacer started: \(settings.breathingMinutes) min at \(Int(plan.paceBpm.rounded())) breaths/min, with a 90 s quiet reading before and after")
        for step in plan.steps {
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.runBreathStep(step) }
            }
            breathWork.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(step.offsetMs) / 1000, execute: item)
        }
    }

    func stopBreathing() {
        guard breathingEndsAt != nil else { return }
        finishBreathing()
        onBreathingCancelled?()
        note(.breathingDone, "Breathing pacer stopped early")
    }

    private func finishBreathing() {
        breathWork.forEach { $0.cancel() }
        breathWork = []
        breathingEndsAt = nil
        breathingPhase = nil
    }

    private func runBreathStep(_ step: StrapCueBreathPlan.Step) {
        guard breathingEndsAt != nil else { return }
        let now = Date()
        if let phase = step.phase {
            breathingPhase = phase
            onBreathPhase?(phase, now)
        }
        if let kind = step.cue {
            // A breath cue that cannot go out NOW is skipped, not queued: a late "breathe in" is wrong.
            if case .allow = gate(kind, now: now) { deliver(kind, now: now) }
        }
        if step.phase == .postQuietEnd { finishBreathing() }
    }

    // MARK: - App events (Telos Lift rest timer, reward / penalty moments)

    /// Buzz the strap for an app event and report honestly what happened. Synchronous to call; main actor.
    ///
    /// - `fire(.restOver)` when a Lift rest period ends.
    /// - `fire(.reward, eventId: "pr:<exerciseId>:<sessionId>")` / `fire(.penalty, eventId: "penaltyCard:<yyyy-MM-dd>")`
    ///   alongside the full-screen moment. `eventId` must identify the EVENT (not the kind of event): a second
    ///   call with the same id is held as `.duplicate` once the first one reached the wearer.
    @discardableResult
    func fire(_ event: StrapCueEvent, eventId: String? = nil, now: Date = Date()) -> StrapCueFireResult {
        let kind = event.kind
        let key = eventId.map { StrapCueGate.eventKey(kind, eventId: $0) }
        switch gate(kind, now: now, eventKey: key) {
        case .hold(let h):
            if h != .duplicate { note(kind, "\(kind.label) held: \(h.text)") }
            return .held(h)
        case .deferUntil(let ms):
            let at = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSince(now))) { [weak self] in
                Task { @MainActor in _ = self?.fire(event, eventId: eventId) }
            }
            return .scheduled(at: at)
        case .allow:
            let outcome = deliver(kind, now: now, detail: eventId.map { "event \($0)" })
            // Only a cue that REACHED the wearer consumes the event: an undelivered one may be fired again.
            if outcome.reachedWearer, let key { ledger = StrapCueGate.markFired(key, ledger: ledger) }
            Self.encode(ledger, to: defaults, key: Key.ledger)
            return .attempted(outcome)
        }
    }

    // MARK: - Late correction from the strap

    /// Feed the strap's offloaded step counter samples (after a history sync). They can only DELAY the next
    /// nudge (a break the phone missed) and mark a past nudge a false alarm — never cause one.
    func reconcileStrapSteps(_ samples: [StepSample]) {
        guard settings.sittingBreakEnabled, samples.count >= 2 else { return }
        let per = SittingBreakDetector.strapMinuteSteps(ts: samples.map(\.ts), counter: samples.map(\.counter))
        let r = SittingBreakDetector.reconcile(sittingState, strapMinuteSteps: per,
                                               intervalMinutes: settings.sittingIntervalMinutes)
        sittingState = r.state
        Self.encode(sittingState, to: defaults, key: Key.sitting)
        if let at = r.falseAlarmAt {
            let when = Date(timeIntervalSince1970: TimeInterval(at))
            note(.sittingBreak, "The strap's offload shows you did move before the \(Self.clock(when)) nudge - the phone missed it (false alarm)")
        }
    }

    // MARK: - The tick

    private func runTick(now: Date) async {
        let nowSec = Int(now.timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: now)
        motionAccess = PhoneMotionSource.access()
        checkTimers(now: now, nowSec: nowSec)
        checkEvening(now: now, nowSec: nowSec, tz: tz)
        await evaluateSitting(now: now, nowSec: nowSec, tz: tz)
        remainingBudget = StrapCueGate.remainingBudget(ledger, settings: settings, nowMs: nowSec * 1000, tzOffsetSec: tz)
        Self.encode(ledger, to: defaults, key: Key.ledger)
        Self.encode(sittingState, to: defaults, key: Key.sitting)
        armPreciseTimer()
    }

    private func checkTimers(now: Date, nowSec: Int) {
        if let end = focusEndsAt {
            switch StrapCueTimers.state(endsAt: Int(end.timeIntervalSince1970), nowSec: nowSec) {
            case .running: break
            case .fire:
                focusEndsAt = nil
                defaults.removeObject(forKey: Key.focusEnds)
                deliverRequested(.focusEnd, now: now)
            case .missed(let late):
                focusEndsAt = nil
                defaults.removeObject(forKey: Key.focusEnds)
                note(.focusEnd, "Focus block ended \(late / 60) min ago while NOOP was suspended - too late to buzz")
            }
        }
        if let end = meditationEndsAt {
            let started = meditationStartedAt
            switch StrapCueTimers.state(endsAt: Int(end.timeIntervalSince1970), nowSec: nowSec) {
            case .running: break
            case .fire:
                clearMeditation()
                deliverRequested(.meditationEnd, now: now)
                if let started { onMeditationCompleted?(Int(end.timeIntervalSince(started))) }
            case .missed(let late):
                clearMeditation()
                note(.meditationEnd, "Meditation timer ended \(late / 60) min ago while NOOP was suspended - too late to buzz, and not logged automatically")
            }
        }
    }

    /// A requested cue (timer end): waits only for the motor. If the motor is busy it goes out right after.
    private func deliverRequested(_ kind: StrapCueKind, now: Date) {
        switch gate(kind, now: now) {
        case .allow:
            deliver(kind, now: now)
        case .deferUntil(let ms):
            // The motor is busy with another pattern for at most a few seconds.
            let delay = min(10, max(0, TimeInterval(ms) / 1000 - now.timeIntervalSince1970))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor in self?.deliverRequested(kind, now: Date()) }
            }
        case .hold(let h):
            note(kind, "\(kind.label) not sent: \(h.text)")
        }
    }

    private func checkEvening(now: Date, nowSec: Int, tz: Int) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        for kind in [StrapCueKind.windDown, .screensOff] where settings.isEnabled(kind) {
            // The night ending today (a wind-down after midnight) and the one ending tomorrow (this evening).
            for offset in [0, 1] {
                guard let wakeDay = cal.date(byAdding: .day, value: offset, to: today),
                      let plan = sleepPlan?(wakeDay),
                      let slot = StrapCueTimers.eveningSlot(kind, plan: plan),
                      let day = cal.date(byAdding: .day, value: slot.dayShift, to: wakeDay),
                      let fireAt = cal.date(bySettingHour: slot.minuteOfDay / 60, minute: slot.minuteOfDay % 60,
                                            second: 0, of: day) else { continue }
                let wakeKey = StrapCueClock.dayKey(epochSec: Int(wakeDay.timeIntervalSince1970),
                                                   tzOffsetSec: TimeZone.current.secondsFromGMT(for: wakeDay))
                let key = StrapCueTimers.eveningKey(kind, wakeDayKey: wakeKey)
                guard !StrapCueGate.hasFired(key, ledger: ledger) else { continue }
                switch StrapCueTimers.state(endsAt: Int(fireAt.timeIntervalSince1970), nowSec: nowSec) {
                case .running:
                    continue
                case .missed:
                    // Passed while NOOP could not act (or before the switch was on): retire it quietly.
                    ledger = StrapCueGate.markFired(key, ledger: ledger)
                case .fire:
                    switch gate(kind, now: now) {
                    case .allow:
                        let outcome = deliver(kind, now: now)
                        // Undelivered: retried on the next tick while inside the grace window.
                        if outcome.reachedWearer { ledger = StrapCueGate.markFired(key, ledger: ledger) }
                    case .deferUntil:
                        continue
                    case .hold(let h):
                        ledger = StrapCueGate.markFired(key, ledger: ledger)
                        lastHold = h
                        note(kind, "\(kind.label) held: \(h.text)")
                    }
                }
            }
        }
    }

    private func evaluateSitting(now: Date, nowSec: Int, tz: Int) async {
        let config = SittingBreakConfig(settings)
        guard config.enabled else {
            sittingVerdict = .off
            sittingSeconds = nil
            return
        }
        var minutes: [MovementMinute] = []
        if motionAccess == .authorized {
            let phone = await motion.minutes(fromSec: nowSec - SittingBreakDetector.lookbackMinutes * 60, toSec: nowSec)
            minutes = phone.map { m in
                MovementMinute(start: m.start, activity: m.activity, confidence: m.confidence, steps: m.steps,
                               heartRate: Self.median(hrByMinute[m.start]))
            }
        }
        let n = nights(now: now)
        let nightToday = n.today
        let nightTomorrow = n.tomorrow
        sleepPlanAvailable = nightToday != nil || nightTomorrow != nil
        let context = SittingBreakContext(
            motionAccess: motionAccess,
            inSleepWindow: StrapCueNight.inSleepWindow(nowSec: nowSec, tzOffsetSec: tz, endingToday: nightToday,
                                                       endingTomorrow: nightTomorrow),
            lastWakeAt: StrapCueNight.lastWakeAt(nowSec: nowSec, tzOffsetSec: tz, endingToday: nightToday),
            workoutActive: isWorkoutActive?() ?? false,
            mindfulSessionActive: breathingEndsAt != nil || meditationEndsAt != nil
                || (isExternalMindfulSessionActive?() ?? false),
            focusBlockActive: focusEndsAt.map { $0 > now } ?? false,
            morningFlowActive: morningFlowActive)
        let decision = SittingBreakDetector.evaluate(minutes: minutes, context: context, config: config,
                                                     state: sittingState, nowSec: nowSec, tzOffsetSec: tz)
        sittingState = decision.nextState
        sittingVerdict = decision.verdict
        sittingSeconds = decision.sittingSeconds

        // Gate BEFORE logging, so a held nudge is logged once as held rather than flapping every tick.
        var gateVerdict: StrapCueGateVerdict?
        var hold: StrapCueHold?
        if case .nudge = decision.verdict {
            let g = gate(.sittingBreak, now: now)
            gateVerdict = g
            if case .hold(let h) = g { hold = h }
        }
        logSittingTransition(decision.verdict, hold: hold)

        guard case .nudge(let secs) = decision.verdict, let g = gateVerdict else { return }
        switch g {
        case .allow:
            let outcome = deliver(.sittingBreak, now: now, detail: "after \(secs / 60) min without a movement break")
            sittingState = outcome.reachedWearer
                ? SittingBreakDetector.recordNudge(sittingState, at: nowSec)
                : SittingBreakDetector.recordUndelivered(sittingState, at: nowSec)
        case .deferUntil:
            break
        case .hold(let h):
            lastHold = h
        }
    }

    /// Log the sitting status when it CHANGES category (and holds once per reason), never once a minute.
    private func logSittingTransition(_ v: SittingBreakVerdict, hold: StrapCueHold?) {
        let key: String
        let text: String
        if let h = hold {
            key = "hold.\(h.rawValue)"
            text = "Sitting-break nudge due but held: \(h.text)"
        } else {
            switch v {
            case .abstain(let a):
                key = "abstain.\(a.rawValue)"
                text = "Sitting-break nudge silent: \(a.text)"
            case .suppressed(let s):
                key = "suppressed.\(s.rawValue)"
                text = "Sitting-break nudge paused: \(s.text)"
            default:
                key = "active"
                text = ""
            }
        }
        guard key != loggedSittingKey else { return }
        loggedSittingKey = key
        if !text.isEmpty { strapLog?(text) }
    }

    // MARK: - Gate + delivery

    private func gate(_ kind: StrapCueKind, now: Date, eventKey: String? = nil) -> StrapCueGateVerdict {
        guard settings.isEnabled(kind) else { return .hold(.switchedOff) }
        let nowMs = Int(now.timeIntervalSince1970 * 1000)
        let tz = TimeZone.current.secondsFromGMT(for: now)
        var sleeping = false
        if !kind.isRequested {
            let n = nights(now: now)
            sleeping = StrapCueNight.inSleepWindow(nowSec: nowMs / 1000, tzOffsetSec: tz,
                                                   endingToday: n.today, endingTomorrow: n.tomorrow)
        }
        return StrapCueGate.check(kind, ledger: ledger, settings: settings, wristAlertsOn: wristAlertsOn,
                                  nowMs: nowMs, tzOffsetSec: tz, inSleepWindow: sleeping, eventKey: eventKey)
    }

    /// The night ending today and the one ending tomorrow, from the sleep anchor (nil when it abstains).
    private func nights(now: Date) -> (today: StrapCueNight?, tomorrow: StrapCueNight?) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let a = sleepPlan?(today).map { StrapCueNight($0) }
        let b = cal.date(byAdding: .day, value: 1, to: today).flatMap { sleepPlan?($0) }.map { StrapCueNight($0) }
        return (a, b)
    }

    private var appInForeground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return false   // a Mac has no Taptic "phone" to fall back to
        #endif
    }

    /// Send one cue and report where it ended up. Decides BEFORE writing (the write itself cannot tell us:
    /// `send` drops a write to a missing link silently and a refused write fails asynchronously), walks the
    /// pattern pulse by pulse re-checking the link, and records only what reached the wearer.
    @discardableResult
    private func deliver(_ kind: StrapCueKind, now: Date, detail: String? = nil) -> StrapCueOutcome {
        let verdict = StrapCueDelivery.verdict(hasSink: buzzPulse != nil, strapReachable: strapReady?() ?? true,
                                               bondRefused: bondRefused?() ?? false)
        let outcome = StrapCueOutcome.resolve(verdict, appInForeground: appInForeground,
                                              phoneFallbackEnabled: settings.phoneFallbackEnabled)
        switch outcome {
        case .strap: walk(kind)
        case .phone: playPhone(kind)
        case .notDelivered: break
        }
        if outcome.reachedWearer {
            ledger = StrapCueGate.recordDelivered(kind, ledger: ledger, nowMs: Int(now.timeIntervalSince1970 * 1000),
                                                  tzOffsetSec: TimeZone.current.secondsFromGMT(for: now))
            if !kind.isRequested { lastHold = nil }
        }
        let isBreathPhase = kind == .breathInhale || kind == .breathExhale
        // A 5-minute pacer is 60 phase cues: log those only when they did NOT go to the strap.
        if !(isBreathPhase && outcome == .strap) {
            let line = outcome.logLine(kind) + (detail.map { " - \($0)" } ?? "")
            strapLog?(line)
            append(StrapCueLogEntry(id: UUID(), at: now, kind: kind, text: line, delivered: outcome.reachedWearer))
        }
        return outcome
    }

    /// Walk the pattern's pulses on the strap: the first now, the rest on their offsets, each re-checking the
    /// link so a pulse the link can no longer carry is reported, not assumed.
    private func walk(_ kind: StrapCueKind) {
        let pulses = kind.pattern.pulses
        guard let first = pulses.first else { return }
        buzzPulse?(UInt8(clamping: first.loops))
        for p in pulses.dropFirst() {
            DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(p.offsetMs) / 1000) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    let ok = StrapCueDelivery.verdict(hasSink: self.buzzPulse != nil,
                                                      strapReachable: self.strapReady?() ?? true,
                                                      bondRefused: self.bondRefused?() ?? false) == .sent
                    if ok {
                        self.buzzPulse?(UInt8(clamping: p.loops))
                    } else {
                        self.strapLog?("Strap cue \(kind.label): the link dropped mid-pattern - later pulses were not sent")
                    }
                }
            }
        }
    }

    private func playPhone(_ kind: StrapCueKind) {
        if let phoneHaptic { phoneHaptic(kind); return }
        SystemHaptics.play(kind == .breathInhale || kind == .breathExhale ? .tap : .summon)
    }

    // MARK: - Precise end timers

    /// One-shot timer at the next timer end, so a focus block / meditation ends on the second while NOOP is
    /// alive instead of on the next minute tick.
    private func armPreciseTimer() {
        preciseTimer?.invalidate()
        preciseTimer = nil
        let next = [focusEndsAt, meditationEndsAt].compactMap { $0 }.min()
        guard let fire = next, fire > Date() else { return }
        let t = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        preciseTimer = t
    }

    // MARK: - History + persistence

    private func note(_ kind: StrapCueKind, _ text: String) {
        strapLog?("Strap cues: \(text)")
        append(StrapCueLogEntry(id: UUID(), at: Date(), kind: kind, text: text, delivered: nil))
    }

    private func append(_ e: StrapCueLogEntry) {
        history.append(e)
        if history.count > Self.maxHistory { history.removeFirst(history.count - Self.maxHistory) }
        Self.encode(history, to: defaults, key: Key.history)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to d: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func median(_ xs: [Int]?) -> Double? {
        guard let xs, !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? Double(s[mid]) : Double(s[mid - 1] + s[mid]) / 2
    }

    nonisolated static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
