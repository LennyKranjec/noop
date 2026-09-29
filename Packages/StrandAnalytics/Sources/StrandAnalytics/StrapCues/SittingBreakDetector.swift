import Foundation

// SittingBreakDetector.swift — the pure core of the Strap-cue SITTING-BREAK NUDGE ("time for a short walk").
//
// ── WHAT IT DETECTS, HONESTLY ────────────────────────────────────────────────────────────────────────
// LOW MOVEMENT, NOT SITTING. Sedentary behaviour is defined as any WAKING behaviour at ≤ 1.5 METs in a
// sitting, reclining or lying posture (Tremblay et al. 2017, SBRN Terminology Consensus, IJBNPA 14:75), and
// the studies measure it with thigh-worn posture sensors. A wrist strap and a phone cannot tell sitting
// from standing still, so this detector never claims posture: it counts MINUTES OF MOVEMENT, and "sedentary"
// here means "the configured interval passed without a movement break". The settings copy says the same.
//
// ── THE EVIDENCE BEHIND THE DEFAULTS ─────────────────────────────────────────────────────────────────
// * Duran AT, … Diaz KM (2023), Med Sci Sports Exerc 55(5):847–855 — a randomized crossover LAB study
//   (n = 11, one 8-hour day per condition) of 1 or 5 minutes of light walking every 30 or 60 minutes. 5 min
//   every 30 min was the most effective schedule tested, lowering the postprandial glucose response and blood
//   pressure versus uninterrupted sitting. Hence the default 30-minute interval and a nudge that suggests
//   about 5 minutes of easy walking.
// * Dunstan DW et al. (2012), Diabetes Care 35(5):976–983 — 2-minute bouts of light or moderate walking
//   every 20 minutes over 5 hours lowered postprandial glucose and insulin in overweight/obese adults
//   (n = 19). Hence a break is counted from about 2 minutes of movement.
// These are ACUTE outcomes over hours in the lab. Neither study shows long-term health effects of a wrist
// nudge, and nothing here claims so.
//
// ── THE SIGNAL, AND WHY IT IS THE PHONE ──────────────────────────────────────────────────────────────
// WHOOP step/motion data only reaches the app with the historical OFFLOAD, minutes late, and on the owner's
// 5/MG firmware the live raw motion stream is not available at all ("R10/R11 Realtime (raw stream) skipped —
// no WHOOP 5/MG framing for this command yet"). So LIVE movement comes from the iPhone (CMMotionActivity and
// CMPedometer). Strap offload steps are used only to RECONCILE afterwards (`reconcile`): they can move the
// last break later and mark a nudge as a false alarm, but they never trigger a cue. Live strap HR is only
// SUPPORTING evidence (rule 3 below).
//
// A minute counts as MOVING if any of:
//   1. the phone's motion activity says walking / running / cycling with at least medium confidence;
//   2. the phone's pedometer counted ≥ `movingCadenceSpm` (60) steps in that minute — the lower edge of the
//      "slow walking" cadence band (Tudor-Locke et al. 2018, Br J Sports Med 52:776, put ~100 steps/min at
//      roughly 3 METs; 60–99 is slow-to-medium walking, below it is puttering);
//   3. live strap HR ≥ the wearer's own sitting baseline + `hrLiftBpm` (10) for this minute AND the one
//      before (2 minutes sustained), while the phone is NOT confidently stationary and not in a car. This
//      catches stairs, cooking and tidying, which move the body with few steps. It is never enough on its
//      own: a phone confidently at rest overrules it. The baseline is the median HR of the wearer's own
//      recent still minutes (≥ 10 of them in the last 2 h) — never a population constant.
// A BREAK is ≥ `breakMovingMinutes` (2) moving minutes inside any `breakSpanMinutes` (3) consecutive minutes,
// or ≥ `breakPooledSteps` (120) steps inside such a span (a 2-minute walk that straddles minute boundaries).
// Ten steps to the printer is not a break; the studied dose is minutes of walking.
//
// ── WHEN IT MUST NOT GUESS ───────────────────────────────────────────────────────────────────────────
// It ABSTAINS — stays silent and says why — when Motion & Fitness is not granted or not available, when the
// newest phone minute is stale, and when the phone is evidently NOT WITH THE WEARER: a long stretch of the
// phone confidently stationary while the strap shows the wearer's HR lifted and sustained (someone moving
// around, phone on a desk). Minutes it cannot see (no phone data, or inside such a stretch) also restart the
// timer: it only ever claims "no break for N minutes" over minutes it actually observed.
//
// ── SUPPRESSION, RESET AND BACKOFF ───────────────────────────────────────────────────────────────────
// Silent during the sleep window (from the sleep anchor), quiet hours, an active workout, a meditation or
// breathing session, a running focus block, the morning flow, and while the phone says it is in a car.
// Sleep, quiet hours, workouts and meditation/breathing also RESTART the timer (their end is a fresh start);
// a focus block, the morning flow and driving do not — sitting in a car or at a focus block is still sitting,
// the nudge simply waits. After a nudge it waits for the break; an ignored nudge is repeated after
// `renudgeMinutes` (30); after `maxIgnored` (3) ignored in a row it stops for `backoffMinutes` (120). Any
// break clears all of that.
//
// Pure, deterministic, no clock reads: `nowSec` and the tz offset are passed in. Swift-only in 2.0.

// MARK: - Inputs

/// What the phone's motion coprocessor says the phone is doing.
public enum PhoneActivityKind: String, Equatable, Sendable, Codable {
    case stationary, walking, running, cycling, automotive, unknown
}

public enum PhoneActivityConfidence: Int, Equatable, Comparable, Sendable, Codable {
    case low = 0, medium = 1, high = 2
    public static func < (a: PhoneActivityConfidence, b: PhoneActivityConfidence) -> Bool { a.rawValue < b.rawValue }
}

/// Whether the app may read Motion & Fitness, as the OS reports it.
public enum MotionAccess: String, Equatable, Sendable, Codable {
    case authorized, notDetermined, denied, restricted
    /// This device (or platform — macOS) has no motion activity / step counting.
    case unavailable
}

/// One observed local-clock minute. `start` is epoch seconds on a minute boundary. Every field may be nil:
/// nil means "no data", never zero.
public struct MovementMinute: Equatable, Sendable, Codable {
    public let start: Int
    public let activity: PhoneActivityKind?
    public let confidence: PhoneActivityConfidence?
    /// Phone pedometer steps inside this minute.
    public let steps: Int?
    /// Median live strap HR inside this minute (bpm).
    public let heartRate: Double?

    public init(start: Int, activity: PhoneActivityKind? = nil, confidence: PhoneActivityConfidence? = nil,
                steps: Int? = nil, heartRate: Double? = nil) {
        self.start = start
        self.activity = activity
        self.confidence = confidence
        self.steps = steps
        self.heartRate = heartRate
    }

    public var end: Int { start + 60 }
    /// The phone said SOMETHING about this minute.
    public var phoneObserved: Bool { activity != nil || steps != nil }
    public var phoneConfidentlyStationary: Bool { activity == .stationary && confidence == .high }
    public var phoneInCar: Bool {
        activity == .automotive && (confidence ?? .low) >= .medium
    }
}

/// The situation right now, as the app sees it.
public struct SittingBreakContext: Equatable, Sendable {
    public var motionAccess: MotionAccess
    /// Inside tonight's / this morning's sleep window from the sleep anchor.
    public var inSleepWindow: Bool
    /// The end of the most recent sleep window at or before now (the wake instant), when known.
    public var lastWakeAt: Int?
    public var workoutActive: Bool
    public var mindfulSessionActive: Bool
    public var focusBlockActive: Bool
    public var morningFlowActive: Bool

    public init(motionAccess: MotionAccess, inSleepWindow: Bool = false, lastWakeAt: Int? = nil,
                workoutActive: Bool = false, mindfulSessionActive: Bool = false,
                focusBlockActive: Bool = false, morningFlowActive: Bool = false) {
        self.motionAccess = motionAccess
        self.inSleepWindow = inSleepWindow
        self.lastWakeAt = lastWakeAt
        self.workoutActive = workoutActive
        self.mindfulSessionActive = mindfulSessionActive
        self.focusBlockActive = focusBlockActive
        self.morningFlowActive = morningFlowActive
    }
}

public struct SittingBreakConfig: Equatable, Sendable {
    public var enabled: Bool
    public var intervalMinutes: Int
    public var quietStartMin: Int
    public var quietEndMin: Int

    public init(enabled: Bool = true, intervalMinutes: Int = StrapCueSettings.defaultSittingIntervalMinutes,
                quietStartMin: Int = 22 * 60, quietEndMin: Int = 7 * 60) {
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.quietStartMin = quietStartMin
        self.quietEndMin = quietEndMin
    }

    public init(_ s: StrapCueSettings) {
        self.init(enabled: s.sittingBreakEnabled, intervalMinutes: s.sittingIntervalMinutes,
                  quietStartMin: s.quietStartMin, quietEndMin: s.quietEndMin)
    }
}

/// What the detector carries between evaluations. Persist verbatim; start from `.initial`. Instants, not
/// flags, so no state can latch on a failure path.
public struct SittingBreakState: Equatable, Sendable, Codable {
    /// End of the newest break seen (live or reconciled).
    public var lastBreakEnd: Int?
    /// Restart point from sessions that reset the timer (workout, meditation/breathing), last seen active.
    public var sessionFloor: Int?
    /// When the last nudge reached the wearer.
    public var lastNudgeAt: Int?
    /// Set when a nudge reached the wearer, cleared by a break or once the nudge is judged ignored.
    public var awaitingBreakSince: Int?
    /// Nudges ignored in a row.
    public var ignoredStreak: Int
    /// No nudges before this instant (after `maxIgnored` ignored nudges).
    public var backoffUntil: Int?
    /// The last nudge that could not be delivered (strap unreachable, no fallback), to pace retries.
    public var lastUndeliveredAt: Int?
    /// Nudges a later strap offload showed were false alarms (a break the phone missed). Diagnostic.
    public var falseAlarms: Int

    public init(lastBreakEnd: Int? = nil, sessionFloor: Int? = nil, lastNudgeAt: Int? = nil,
                awaitingBreakSince: Int? = nil, ignoredStreak: Int = 0, backoffUntil: Int? = nil,
                lastUndeliveredAt: Int? = nil, falseAlarms: Int = 0) {
        self.lastBreakEnd = lastBreakEnd
        self.sessionFloor = sessionFloor
        self.lastNudgeAt = lastNudgeAt
        self.awaitingBreakSince = awaitingBreakSince
        self.ignoredStreak = ignoredStreak
        self.backoffUntil = backoffUntil
        self.lastUndeliveredAt = lastUndeliveredAt
        self.falseAlarms = falseAlarms
    }

    public static let initial = SittingBreakState()
}

// MARK: - Outputs

public enum SittingBreakAbstention: String, Equatable, Sendable, Codable {
    case motionNotAuthorized
    case motionUnavailable
    case noRecentPhoneData
    case phoneNotWithWearer

    public var text: String {
        switch self {
        case .motionNotAuthorized:
            return "Needs Motion & Fitness access to see when you move. Without it the nudge stays silent rather than guess."
        case .motionUnavailable:
            return "This device can't report motion, so the nudge stays silent rather than guess."
        case .noRecentPhoneData:
            return "The phone hasn't reported motion for the last few minutes, so the nudge is waiting rather than guessing."
        case .phoneNotWithWearer:
            return "Your phone seems to be lying still while your strap shows you moving, so it can't vouch for you. The nudge is paused until the phone moves with you again."
        }
    }
}

public enum SittingBreakSuppression: String, Equatable, Sendable, Codable {
    case sleepWindow, quietHours, workout, mindfulSession, focusBlock, morningFlow, driving, backoff

    public var text: String {
        switch self {
        case .sleepWindow: return "Sleep window."
        case .quietHours: return "Quiet hours."
        case .workout: return "Workout in progress."
        case .mindfulSession: return "Meditation or breathing session in progress."
        case .focusBlock: return "Focus block running — the nudge waits for its end."
        case .morningFlow: return "Morning flow open."
        case .driving: return "The phone says you're in a vehicle."
        case .backoff: return "Three nudges in a row went unanswered, so it's resting for two hours."
        }
    }
}

public enum SittingBreakVerdict: Equatable, Sendable {
    case off
    case abstain(SittingBreakAbstention)
    case suppressed(SittingBreakSuppression)
    /// Low movement for `seconds` so far, below the interval.
    case accumulating(seconds: Int)
    /// A nudge reached the wearer at `since`; waiting for the break (or the re-nudge time).
    case awaitingBreak(since: Int)
    /// A delivery failed recently; the next attempt waits until `until`.
    case retryLater(until: Int)
    /// Nudge now.
    case nudge(sittingSeconds: Int)
}

public struct SittingBreakDecision: Equatable, Sendable {
    public let verdict: SittingBreakVerdict
    /// Observed low-movement time up to the newest phone minute, when it could be measured.
    public let sittingSeconds: Int?
    /// The wearer's sitting HR baseline used for rule 3, nil when there were not enough still minutes.
    public let baselineHr: Double?
    /// Persist this.
    public let nextState: SittingBreakState
}

public enum MinuteMovement: Equatable, Sendable {
    public enum Evidence: String, Equatable, Sendable { case activity, cadence, heartRate }
    case moving(Evidence)
    case still
    /// No phone data for this minute (or the phone was evidently not with the wearer).
    case unobserved
}

// MARK: - Engine

public enum SittingBreakDetector {

    // ── Thresholds (one place; `SittingBreakDetectorTests` pins them) ──
    /// Steps in one minute that make it a moving minute (lower edge of slow walking).
    public static let movingCadenceSpm = 60
    /// HR lift over the wearer's own sitting baseline (bpm) for rule 3.
    public static let hrLiftBpm: Double = 10
    /// Trailing window (minutes) the sitting-HR baseline is read from, and the still minutes it needs.
    public static let baselineWindowMinutes = 120
    public static let baselineMinStillMinutes = 10
    /// A break: this many moving minutes inside this many consecutive minutes…
    public static let breakMovingMinutes = 2
    public static let breakSpanMinutes = 3
    /// …or this many steps inside such a span (2 minutes at the moving cadence).
    public static let breakPooledSteps = 120
    /// A run of this many or more unobserved minutes restarts the timer; shorter holes are tolerated.
    public static let unobservedResetMinutes = 3
    /// The newest phone minute must end within this many seconds of now.
    public static let freshnessSeconds = 180
    /// Phone-not-with-wearer: a confidently-stationary stretch at least this long, containing at least
    /// `notCarriedLiftedMinutes` minutes of sustained HR lift.
    public static let notCarriedStationaryMinutes = 10
    public static let notCarriedLiftedMinutes = 3
    /// Re-nudge an ignored nudge after this long; after `maxIgnored` in a row, rest for `backoffMinutes`.
    public static let renudgeMinutes = 30
    public static let maxIgnored = 3
    public static let backoffMinutes = 120
    /// After a nudge that could not be delivered, wait this long before trying again.
    public static let undeliveredRetrySeconds = 300
    /// How far back the runtime should supply minutes: the baseline window plus the longest interval.
    public static let lookbackMinutes = baselineWindowMinutes + 60

    // MARK: Minute classification

    /// Sorted, de-duplicated (last wins) minutes.
    static func normalized(_ minutes: [MovementMinute]) -> [MovementMinute] {
        var byStart: [Int: MovementMinute] = [:]
        for m in minutes { byStart[m.start] = m }
        return byStart.keys.sorted().compactMap { byStart[$0] }
    }

    static func movingByPhone(_ m: MovementMinute) -> MinuteMovement.Evidence? {
        if let a = m.activity, a == .walking || a == .running || a == .cycling, (m.confidence ?? .low) >= .medium {
            return .activity
        }
        if let s = m.steps, s >= movingCadenceSpm { return .cadence }
        return nil
    }

    /// The wearer's sitting HR: median HR of still minutes (phone observed, not moving by the phone, and
    /// either stationary or stepless) in the `baselineWindowMinutes` before `nowSec`. Nil below
    /// `baselineMinStillMinutes`.
    public static func sittingBaseline(_ minutes: [MovementMinute], nowSec: Int) -> Double? {
        let from = nowSec - baselineWindowMinutes * 60
        let hrs = minutes.compactMap { m -> Double? in
            guard m.start >= from, m.start < nowSec, let hr = m.heartRate, hr > 0, m.phoneObserved,
                  movingByPhone(m) == nil, !m.phoneInCar,
                  m.activity == .stationary || (m.steps ?? 0) == 0 else { return nil }
            return hr
        }.sorted()
        guard hrs.count >= baselineMinStillMinutes else { return nil }
        let mid = hrs.count / 2
        return hrs.count % 2 == 1 ? hrs[mid] : (hrs[mid - 1] + hrs[mid]) / 2
    }

    /// Per-minute: is the HR lifted over the baseline for this minute AND the previous (consecutive) one?
    static func sustainedLift(_ ms: [MovementMinute], baseline: Double?) -> [Bool] {
        guard let base = baseline else { return Array(repeating: false, count: ms.count) }
        func lifted(_ m: MovementMinute) -> Bool { (m.heartRate ?? 0) >= base + hrLiftBpm }
        return ms.indices.map { (i: Int) -> Bool in
            guard i > 0, ms[i - 1].start == ms[i].start - 60 else { return false }
            return lifted(ms[i]) && lifted(ms[i - 1])
        }
    }

    /// Classify every minute (input must be `normalized`).
    public static func classify(_ ms: [MovementMinute], baseline: Double?) -> [MinuteMovement] {
        let lift = sustainedLift(ms, baseline: baseline)
        return ms.indices.map { (i: Int) -> MinuteMovement in
            let m = ms[i]
            if let e = movingByPhone(m) { return .moving(e) }
            if !m.phoneObserved { return .unobserved }
            if lift[i] && !m.phoneConfidentlyStationary && !m.phoneInCar { return .moving(.heartRate) }
            return .still
        }
    }

    /// End of the newest break in `ms` (normalized), or nil.
    public static func lastBreakEnd(_ ms: [MovementMinute], classes: [MinuteMovement]) -> Int? {
        var best: Int?
        for i in ms.indices {
            let spanEnd = ms[i].start + breakSpanMinutes * 60
            var moving = 0, steps = 0
            var lastMovingEnd: Int?, lastStepEnd: Int?
            var j = i
            while j < ms.count && ms[j].start < spanEnd {
                if case .moving = classes[j] { moving += 1; lastMovingEnd = ms[j].end }
                if let s = ms[j].steps, s > 0 { steps += s; lastStepEnd = ms[j].end }
                j += 1
            }
            var end: Int?
            if moving >= breakMovingMinutes { end = lastMovingEnd }
            if steps >= breakPooledSteps, let e = lastStepEnd { end = max(end ?? e, e) }
            if let e = end { best = max(best ?? e, e) }
        }
        return best
    }

    /// Stretches where the phone was confidently stationary for ≥ `notCarriedStationaryMinutes` while the
    /// strap showed ≥ `notCarriedLiftedMinutes` of sustained HR lift: the phone was not with the wearer.
    /// Returned as (start, end) epoch ranges, oldest first.
    public static func notCarriedStretches(_ ms: [MovementMinute], baseline: Double?) -> [(start: Int, end: Int)] {
        let lift = sustainedLift(ms, baseline: baseline)
        var out: [(start: Int, end: Int)] = []
        var i = 0
        while i < ms.count {
            guard ms[i].phoneConfidentlyStationary && (ms[i].steps ?? 0) == 0 else { i += 1; continue }
            var j = i, lifted = 0
            while j < ms.count, ms[j].phoneConfidentlyStationary, (ms[j].steps ?? 0) == 0,
                  j == i || ms[j].start == ms[j - 1].start + 60 {
                if lift[j] { lifted += 1 }
                j += 1
            }
            if j - i >= notCarriedStationaryMinutes && lifted >= notCarriedLiftedMinutes {
                out.append((start: ms[i].start, end: ms[j - 1].end))
            }
            i = j
        }
        return out
    }

    /// The latest instant from which every minute up to the newest one was observed (holes shorter than
    /// `unobservedResetMinutes` tolerated), or the first minute's start.
    static func observedSince(_ ms: [MovementMinute], classes: [MinuteMovement]) -> Int? {
        guard let first = ms.first else { return nil }
        var since = first.start
        var runStart: Int?, runLen = 0
        var prevEnd = first.start
        for i in ms.indices {
            // A missing minute between two entries counts as unobserved.
            let gap = (ms[i].start - prevEnd) / 60
            if gap > 0 {
                if runStart == nil { runStart = prevEnd }
                runLen += gap
            }
            if case .unobserved = classes[i] {
                if runStart == nil { runStart = ms[i].start }
                runLen += 1
            } else {
                if runLen >= unobservedResetMinutes { since = max(since, ms[i].start) }
                runStart = nil; runLen = 0
            }
            prevEnd = ms[i].end
        }
        if runLen >= unobservedResetMinutes { since = max(since, prevEnd) }
        return since
    }

    // MARK: The decision

    public static func evaluate(minutes raw: [MovementMinute], context: SittingBreakContext,
                                config: SittingBreakConfig, state: SittingBreakState,
                                nowSec: Int, tzOffsetSec: Int) -> SittingBreakDecision {
        var next = state
        func done(_ v: SittingBreakVerdict, _ secs: Int? = nil, _ base: Double? = nil) -> SittingBreakDecision {
            SittingBreakDecision(verdict: v, sittingSeconds: secs, baselineHr: base, nextState: next)
        }

        guard config.enabled else { return done(.off) }
        switch context.motionAccess {
        case .authorized: break
        case .unavailable: return done(.abstain(.motionUnavailable))
        case .notDetermined, .denied, .restricted: return done(.abstain(.motionNotAuthorized))
        }

        // Sessions that restart the timer move its floor forward while they run.
        if context.workoutActive || context.mindfulSessionActive {
            next.sessionFloor = max(next.sessionFloor ?? nowSec, nowSec)
        }

        let ms = normalized(raw.filter { $0.start < nowSec })
        let baseline = sittingBaseline(ms, nowSec: nowSec)
        var classes = classify(ms, baseline: baseline)
        let stretches = notCarriedStretches(ms, baseline: baseline)
        // Minutes inside a not-carried stretch are unseen, whatever the phone said.
        if !stretches.isEmpty {
            for i in ms.indices where stretches.contains(where: { ms[i].start >= $0.start && ms[i].start < $0.end }) {
                classes[i] = .unobserved
            }
        }

        // Breaks: newest live one, merged into the persisted one (which may come from a reconcile).
        if let live = lastBreakEnd(ms, classes: classes) {
            next.lastBreakEnd = max(next.lastBreakEnd ?? live, live)
        }
        // A break after the last nudge answers it and clears the backoff.
        if let brk = next.lastBreakEnd, let nudged = next.lastNudgeAt, brk > nudged {
            next.awaitingBreakSince = nil
            next.ignoredStreak = 0
            next.backoffUntil = nil
        }

        // Suppression, in order of how the wearer would name it.
        let localMin = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
        if context.inSleepWindow { return done(.suppressed(.sleepWindow), nil, baseline) }
        if SedentaryDetector.windowContains(localMin, startMin: config.quietStartMin, endMin: config.quietEndMin) {
            return done(.suppressed(.quietHours), nil, baseline)
        }
        if context.workoutActive { return done(.suppressed(.workout), nil, baseline) }
        if context.mindfulSessionActive { return done(.suppressed(.mindfulSession), nil, baseline) }

        // Abstain when the phone cannot speak for the wearer right now.
        guard let newest = ms.last, newest.end >= nowSec - freshnessSeconds, newest.phoneObserved else {
            return done(.abstain(.noRecentPhoneData), nil, baseline)
        }
        if let s = stretches.last, s.end >= newest.end { return done(.abstain(.phoneNotWithWearer), nil, baseline) }

        // How long has it been low-movement, over minutes we actually saw?
        var since = observedSince(ms, classes: classes) ?? newest.start
        if let b = next.lastBreakEnd { since = max(since, b) }
        if let f = next.sessionFloor { since = max(since, f) }
        if let w = context.lastWakeAt { since = max(since, w) }
        if config.quietStartMin != config.quietEndMin {
            since = max(since, StrapCueClock.lastClockInstant(atOrBefore: nowSec, minuteOfDay: config.quietEndMin,
                                                              tzOffsetSec: tzOffsetSec))
        }
        let sitting = max(0, newest.end - since)

        // Waiting-type suppressions (the timer keeps running underneath them).
        if context.focusBlockActive { return done(.suppressed(.focusBlock), sitting, baseline) }
        if context.morningFlowActive { return done(.suppressed(.morningFlow), sitting, baseline) }
        if newest.phoneInCar { return done(.suppressed(.driving), sitting, baseline) }

        if let until = next.backoffUntil, nowSec < until { return done(.suppressed(.backoff), sitting, baseline) }
        if next.backoffUntil != nil { next.backoffUntil = nil }

        let interval = config.intervalMinutes * 60
        guard sitting >= interval else { return done(.accumulating(seconds: sitting), sitting, baseline) }

        if let pending = next.awaitingBreakSince {
            guard nowSec - pending >= renudgeMinutes * 60 else {
                return done(.awaitingBreak(since: pending), sitting, baseline)
            }
            // The pending nudge went unanswered for the whole re-nudge interval: it was ignored.
            next.awaitingBreakSince = nil
            next.ignoredStreak += 1
            if next.ignoredStreak >= maxIgnored {
                next.ignoredStreak = 0
                next.backoffUntil = nowSec + backoffMinutes * 60
                return done(.suppressed(.backoff), sitting, baseline)
            }
        }
        if let failed = next.lastUndeliveredAt, nowSec - failed < undeliveredRetrySeconds {
            return done(.retryLater(until: failed + undeliveredRetrySeconds), sitting, baseline)
        }
        return done(.nudge(sittingSeconds: sitting), sitting, baseline)
    }

    /// The state after a nudge REACHED the wearer (strap or phone fallback).
    public static func recordNudge(_ state: SittingBreakState, at nowSec: Int) -> SittingBreakState {
        var s = state
        s.lastNudgeAt = nowSec
        s.awaitingBreakSince = nowSec
        s.lastUndeliveredAt = nil
        return s
    }

    /// The state after a nudge could NOT be delivered. Not a nudge: it does not count as ignored.
    public static func recordUndelivered(_ state: SittingBreakState, at nowSec: Int) -> SittingBreakState {
        var s = state
        s.lastUndeliveredAt = nowSec
        return s
    }

    // MARK: Late correction from the strap offload

    /// Per-minute strap steps from cumulative counter samples (`StepSample.counter`). Negative deltas (a
    /// counter reset) and implausible jumps are dropped rather than guessed.
    public static func strapMinuteSteps(ts: [Int], counter: [Int]) -> [Int: Int] {
        guard ts.count == counter.count, ts.count >= 2 else { return [:] }
        let order = ts.indices.sorted { ts[$0] < ts[$1] }
        var out: [Int: Int] = [:]
        for k in 1..<order.count {
            let a = order[k - 1], b = order[k]
            let d = counter[b] - counter[a]
            let dt = ts[b] - ts[a]
            guard d > 0, dt > 0, dt <= 120, Double(d) / Double(dt) <= 5 else { continue }
            let minute = ts[b] - ((ts[b] % 60) + 60) % 60
            out[minute, default: 0] += d
        }
        return out
    }

    /// Reconcile with strap steps that arrived late. A strap break (same rule as the phone's pooled rule:
    /// ≥ `breakPooledSteps` in a `breakSpanMinutes` span, or ≥ `breakMovingMinutes` minutes at the moving
    /// cadence) moves `lastBreakEnd` later; one that happened in the interval before the last nudge marks
    /// that nudge a false alarm. It can only ever DELAY a nudge — it never causes one.
    public static func reconcile(_ state: SittingBreakState, strapMinuteSteps steps: [Int: Int],
                                 intervalMinutes: Int) -> (state: SittingBreakState, falseAlarmAt: Int?) {
        let ms = steps.keys.sorted().map { MovementMinute(start: $0, steps: steps[$0]) }
        let classes: [MinuteMovement] = ms.map { (($0.steps ?? 0) >= movingCadenceSpm) ? .moving(.cadence) : .still }
        var s = state
        var falseAlarm: Int?
        // Every strap break, not only the newest, so one inside the window before the nudge is seen.
        for i in ms.indices {
            guard let end = lastBreakEnd(Array(ms[i..<min(ms.count, i + breakSpanMinutes)]),
                                         classes: Array(classes[i..<min(classes.count, i + breakSpanMinutes)]))
            else { continue }
            s.lastBreakEnd = max(s.lastBreakEnd ?? end, end)
            if let n = state.lastNudgeAt, end <= n, end > n - intervalMinutes * 60, falseAlarm == nil {
                falseAlarm = n
            }
        }
        if falseAlarm != nil {
            s.falseAlarms += 1
            // A nudge that should not have happened is not judged: it can never count as ignored.
            s.awaitingBreakSince = nil
        }
        if let b = s.lastBreakEnd, let n = s.lastNudgeAt, b > n {
            s.awaitingBreakSince = nil
            s.ignoredStreak = 0
            s.backoffUntil = nil
        }
        return (s, falseAlarm)
    }
}

// MARK: - The sleep window, from the sleep anchor

/// One night of the sleep plan, reduced to what the cues need: lights-out and wake, local minute-of-day,
/// and whether lights-out falls on the evening BEFORE the wake day.
public struct StrapCueNight: Equatable, Sendable {
    public let bedtimeMin: Int
    public let wakeMin: Int
    public let bedtimeOnPreviousDay: Bool

    public init(bedtimeMin: Int, wakeMin: Int, bedtimeOnPreviousDay: Bool) {
        self.bedtimeMin = SleepClock.wrap(bedtimeMin)
        self.wakeMin = SleepClock.wrap(wakeMin)
        self.bedtimeOnPreviousDay = bedtimeOnPreviousDay
    }

    public init(_ plan: SleepSchedulePlan) {
        self.init(bedtimeMin: plan.bedtimeMin, wakeMin: plan.anchorMin,
                  bedtimeOnPreviousDay: plan.bedtimeDayShift < 0)
    }

    /// Inside the sleep window now? `endingToday` is the night whose wake day is today, `endingTomorrow`
    /// the one that starts this evening. Either may be nil (the anchor abstains — no plan, no window).
    public static func inSleepWindow(nowSec: Int, tzOffsetSec: Int, endingToday: StrapCueNight?,
                                     endingTomorrow: StrapCueNight?) -> Bool {
        let m = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
        if let n = endingToday, m < n.wakeMin, n.bedtimeOnPreviousDay || m >= n.bedtimeMin { return true }
        if let n = endingTomorrow, n.bedtimeOnPreviousDay, m >= n.bedtimeMin { return true }
        return false
    }

    /// Today's wake instant, when it has already passed.
    public static func lastWakeAt(nowSec: Int, tzOffsetSec: Int, endingToday: StrapCueNight?) -> Int? {
        guard let n = endingToday else { return nil }
        let m = SedentaryDetector.localMinuteOfDay(nowSec, tzOffsetSec: tzOffsetSec)
        guard m >= n.wakeMin else { return nil }
        return StrapCueClock.lastClockInstant(atOrBefore: nowSec, minuteOfDay: n.wakeMin, tzOffsetSec: tzOffsetSec)
    }
}
