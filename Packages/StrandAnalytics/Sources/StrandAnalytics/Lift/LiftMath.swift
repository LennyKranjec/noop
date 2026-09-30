import Foundation

// LiftMath.swift — the small, exact pieces of arithmetic the logger shows on every row: the estimated
// one-rep max, the wearer's own weight increment per exercise, and the rest timer.

// MARK: - e1RM

/// Epley, `w × (1 + r / 30)`, for 1…12 reps — and "—" (nil) outside that window.
///
/// PARITY TWIN of `StrandImport.StrengthIndex.e1rm` (which `StrengthProgression.epley` delegates to). This
/// package cannot import StrandImport, so the formula is restated here with the SAME window and the SAME
/// guards; `StrandTests/LiftParityTests` asserts the two agree over the whole 1…12 × weight grid so a change to
/// one without the other fails a test instead of putting two different "e1RM" figures for one set on screen
/// (the duplicated-values failure `StrengthProgression`'s header describes).
///
/// ABSTAINS rather than extrapolating: 0 reps, 13+ reps, no load, or a load that is weight ADDED to
/// bodyweight (the absolute load is unknown) all return nil.
public enum LiftE1RM {
    public static let minReps = 1
    public static let maxReps = 12

    public static func epley(weightKg: Double?, reps: Int?, addedToBodyweight: Bool = false) -> Double? {
        guard !addedToBodyweight, let weightKg, let reps,
              weightKg > 0, weightKg.isFinite, reps >= minReps, reps <= maxReps else { return nil }
        return weightKg * (1 + Double(reps) / 30)
    }
}

// MARK: - Increment

/// The step the weight stepper and wheel move by, per exercise, from the wearer's own history.
///
/// THE RULE: the smallest gap between two DISTINCT weights the wearer has actually used on this exercise,
/// among gaps in [`minKg`, `maxKg`]. Weights are rounded to the hundredth first so a pound-converted 74.9997
/// and 75.0 are one weight.
///
/// WHY THE UPPER BOUND IS 10 kg HERE AND 5 kg IN `StrengthProgression`. Decision 16 names machines that step
/// in 8 kg plates. `StrengthProgression.maxIncrementKg` (5) is a bound on what it will SUGGEST adding in one
/// go, and it rejects an 8 kg stack step — which is right for a suggestion and wrong for a stepper: a stepper
/// that moves 2.5 kg on an 8 kg stack offers weights the machine cannot be set to. So the stepper infers
/// with a wider bound; the progression proposal still comes from `StrengthProgression` unchanged, and on such
/// a machine past the top of the rep range it honestly says it has no step to suggest.
///
/// DEFAULT 2.5 kg ONLY WITHOUT HISTORY, and flagged (`observed == false`) so the screen labels it "default".
public enum LiftIncrement {
    public static let minKg = 0.5
    public static let maxKg = 10.0
    public static let defaultKg = 2.5

    public struct Resolved: Equatable, Sendable, Codable {
        public let kg: Double
        /// true = inferred from this wearer's history; false = the labelled 2.5 kg default.
        public let observed: Bool

        public init(kg: Double, observed: Bool) {
            self.kg = kg
            self.observed = observed
        }
    }

    public static func infer(weightsKg: [Double]) -> Double? {
        let weights = Set(weightsKg.filter { $0 > 0 && $0.isFinite }.map { ($0 * 100).rounded() / 100 }).sorted()
        guard weights.count >= 2 else { return nil }
        var smallest: Double?
        for i in 1..<weights.count {
            let gap = ((weights[i] - weights[i - 1]) * 100).rounded() / 100
            guard gap >= minKg, gap <= maxKg else { continue }
            smallest = min(smallest ?? gap, gap)
        }
        return smallest
    }

    public static func resolve(weightsKg: [Double]) -> Resolved {
        if let kg = infer(weightsKg: weightsKg) { return Resolved(kg: kg, observed: true) }
        return Resolved(kg: defaultKg, observed: false)
    }

    /// One stepper press. The grid is anchored at the CURRENT weight (a machine stack at 27.5 kg with a 5 kg
    /// step goes 32.5, 37.5 — not 30, 35), never below zero. From no weight at all, `+` lands on one step.
    public static func step(_ weightKg: Double?, by steps: Int, incrementKg: Double) -> Double? {
        guard incrementKg > 0 else { return weightKg }
        guard let w = weightKg else { return steps > 0 ? round2(incrementKg * Double(steps)) : nil }
        let next = round2(w + incrementKg * Double(steps))
        return next > 0 ? next : nil
    }

    /// The wheel's choices: `count` steps either side of the anchor (or of one step when there is none),
    /// positive values only, ascending.
    public static func wheelValues(around anchor: Double?, incrementKg: Double, count: Int = 40) -> [Double] {
        guard incrementKg > 0 else { return anchor.map { [$0] } ?? [] }
        let centre = anchor ?? incrementKg
        var out: [Double] = []
        for k in -count...count {
            let v = round2(centre + Double(k) * incrementKg)
            if v > 0 { out.append(v) }
        }
        return out
    }

    static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

// MARK: - Rest timer

/// The rest timer as a TARGET DATE, never a ticking counter.
///
/// A counter decremented by a timer stops when iOS suspends the app, so a rest started before the phone went
/// into the pocket would read 2:26 again when it came out. A target date is right whenever it is read: the
/// remaining time is `endsAt − now`, background or not. The ticking on screen is only a `TimelineView`
/// redrawing that difference.
public struct LiftRestTimer: Codable, Equatable, Sendable {
    /// 2:30 (decision 16).
    public static let defaultSeconds = 150
    /// The on-the-fly adjustment (decision 16).
    public static let adjustStepSeconds = 15
    /// How late a zero may be noticed and still be cued. A strap buzz 40 s after the rest ended (the app was
    /// suspended and the backup notification already fired) is not a cue, it is noise — so past this grace
    /// the strap stays silent and the expiry is only recorded.
    public static let lateCueGraceSeconds: TimeInterval = 10

    public private(set) var startedAt: Date?
    public private(set) var endsAt: Date?

    public init(startedAt: Date? = nil, endsAt: Date? = nil) {
        self.startedAt = startedAt
        self.endsAt = endsAt
    }

    /// The duration for an exercise: its own override, else the wearer's global default. Never negative.
    public static func duration(exerciseRestSeconds: Int?, globalDefaultSeconds: Int) -> Int {
        max(0, exerciseRestSeconds ?? globalDefaultSeconds)
    }

    public mutating func start(now: Date, seconds: Int) {
        startedAt = now
        endsAt = now.addingTimeInterval(TimeInterval(max(0, seconds)))
    }

    public mutating func stop() {
        startedAt = nil
        endsAt = nil
    }

    /// ±15 s while resting. Moves the TARGET; a cut past "now" ends the rest now rather than going negative.
    public mutating func adjust(bySeconds delta: Int, now: Date) {
        guard let end = endsAt else { return }
        let moved = end.addingTimeInterval(TimeInterval(delta))
        endsAt = max(moved, now)
    }

    public func isRunning(at now: Date) -> Bool {
        guard let endsAt else { return false }
        return endsAt > now
    }

    /// Seconds left, 0 when not running or expired.
    public func remaining(at now: Date) -> TimeInterval {
        guard let endsAt else { return 0 }
        return max(0, endsAt.timeIntervalSince(now))
    }

    /// Elapsed share of the planned rest, 0…1 (1 when expired), nil when no rest is running.
    public func fractionElapsed(at now: Date) -> Double? {
        guard let startedAt, let endsAt else { return nil }
        let total = endsAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(startedAt) / total))
    }

    public enum Expiry: Equatable, Sendable {
        case idle
        case running(remaining: TimeInterval)
        /// Reached zero within the grace: cue now (strap + a foreground haptic).
        case dueNow
        /// Reached zero long ago (the app was suspended): do not cue late; the local notification covered it.
        case late(by: TimeInterval)
    }

    public func expiry(at now: Date) -> Expiry {
        guard let endsAt else { return .idle }
        let delta = now.timeIntervalSince(endsAt)
        if delta < 0 { return .running(remaining: -delta) }
        if delta <= Self.lateCueGraceSeconds { return .dueNow }
        return .late(by: delta)
    }

    /// "2:26" — minutes and zero-padded seconds, rounded UP so a timer never shows 0:00 while running.
    public static func clock(_ remaining: TimeInterval) -> String {
        let s = max(0, Int(remaining.rounded(.up)))
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}
