import Foundation

// LevelEngine.swift — the level.
//
// iOS lane. The Android `LevelEngine` is unchanged and no longer matches this one: on iOS the level was
// rebuilt to have NO CEILING, at the wearer's request.
//
// WHAT 100 MEANS. Every input is scored against the wearer's own frozen baseline: 50 is their average
// day, 100 is their own 95th-percentile day in the good direction (see `Baseline.score`). A day on which
// every part sits at its own 95th percentile, with no step penalty, is a level of 100. Beyond that the
// level keeps rising — nothing is clipped, anywhere — and a bad enough day falls below 0. The only
// ceiling left is the body's.
//
// A LEVEL OF STATE, NOT OF THE WEEK'S TREND. Every physiological input is a 7-day mean, strength is a
// twelve-week best, training load is a 42-day chronic figure, and meditation is a 28-day share — so a bad
// night, a deload week or one missed session barely moves the level, and months of real progress do.
//
//   · SLEEP  (30 %) — deep + REM minutes (0.60), night HRV (0.25), bedtime/wake regularity (0.15, lower
//                     is better). 7-night means.
//   · MUSCLE (24 %) — strength (0.60: the estimated-1RM index) and chronic training load (0.40).
//   · HEART  (23 %) — HRV (0.5) and resting HR (0.5, lower is better). 7-day means.
//   · LUNGS  (12 %) — VO₂max (0.75) and respiratory rate (0.25, lower is better, 7-day mean).
//   · FOCUS  (11 %) — daytime calm (0.75, 7-day mean) and meditation (0.25).
//
// MEDITATION is the one input not scored against a baseline — it has no biological ceiling. It is the
// share of the last 28 days on which the wearer meditated at least `meditationMinMinutes`, the newest
// days weighted most (e^(−days ago / 14)), times 100. A missed day costs a little; nothing resets.
//
// EVERY INPUT IS MEASURED. A component with no data is EXCLUDED and its weight redistributed over the
// ones that do; inside a part, a missing sub-metric is redistributed the same way. `coverage` says how
// much of the weight was real.
//
// STEPS ARE A PENALTY, NOT A COMPONENT: the 7-day average against `stepsFloor`, by at most
// `stepsMaxPenalty`.

/// Everything the level is computed from, already extracted from the stores.
///
/// The wiring hands over figures that are already averaged over their windows.
public struct LevelInputs: Equatable, Sendable {
    /// Deep + REM minutes a night, 7-night mean.
    public var restorativeMin: Double?
    /// Night HRV, 7-night mean.
    public var sleepHrv: Double?
    /// Minutes bedtime and wake time moved against the night before, 7-night mean.
    public var regularityMin: Double?
    /// HRV, 7-day mean.
    public var hrv: Double?
    /// Resting HR, 7-day mean.
    public var rhr: Double?
    public var vo2max: Double?
    /// Respiratory rate, 7-day mean.
    public var respRate: Double?
    /// The estimated-1RM strength index as of the day.
    public var strengthIndex: Double?
    /// Chronic training load as of the day.
    public var chronicLoad: Double?
    /// Daytime calm, 7-day mean.
    public var daytimeRmssd: Double?
    /// The weighted share of the last 28 days meditated, 0–1.
    public var meditationShare: Double
    /// Average daily steps over the last 7 days. Nil when steps are not being recorded at all.
    public var steps: Int?

    public init(
        restorativeMin: Double? = nil,
        sleepHrv: Double? = nil,
        regularityMin: Double? = nil,
        hrv: Double? = nil,
        rhr: Double? = nil,
        vo2max: Double? = nil,
        respRate: Double? = nil,
        strengthIndex: Double? = nil,
        chronicLoad: Double? = nil,
        daytimeRmssd: Double? = nil,
        meditationShare: Double = 0,
        steps: Int? = nil
    ) {
        self.restorativeMin = restorativeMin
        self.sleepHrv = sleepHrv
        self.regularityMin = regularityMin
        self.hrv = hrv
        self.rhr = rhr
        self.vo2max = vo2max
        self.respRate = respRate
        self.strengthIndex = strengthIndex
        self.chronicLoad = chronicLoad
        self.daytimeRmssd = daytimeRmssd
        self.meditationShare = meditationShare
        self.steps = steps
    }
}

/// The five weighted parts. Steps is deliberately absent: it penalises, it does not score.
public enum LevelPart: String, CaseIterable, Sendable, Codable {
    case sleep
    case heart
    case lungs
    case muscle
    case focus

    public var weight: Double {
        switch self {
        case .sleep: return 0.30
        case .heart: return 0.23
        case .lungs: return 0.12
        case .muscle: return 0.24
        case .focus: return 0.11
        }
    }
}

/// One weighted part of the level.
public struct LevelComponent: Equatable, Sendable {
    public let part: LevelPart
    /// Unbounded: 50 is the wearer's average, 100 their own 95th percentile. Nil when there was no data.
    public let score: Double?
    /// The weight it carried in THIS calculation, after redistribution. Zero when it had no data.
    public let effectiveWeight: Double

    public init(part: LevelPart, score: Double?, effectiveWeight: Double) {
        self.part = part
        self.score = score
        self.effectiveWeight = effectiveWeight
    }

    /// Points of level between today's score and the wearer's own 95th-percentile (100) for this part.
    /// Zero once the part is at or above it — past that there is still more to gain, but no longer a
    /// gap to close.
    public var headroom: Double { score.map { Swift.max(0, 100 - $0) * effectiveWeight } ?? 0 }

    /// Points of level this component currently contributes.
    public var contribution: Double { (score ?? 0) * effectiveWeight }
}

/// A computed level, with everything needed to explain it.
public struct LevelBreakdown: Equatable, Sendable {
    public let components: [LevelComponent]
    /// Before the step penalty.
    public let raw: Double
    /// The multiplier steps applied, 1.0 when at or above the floor or not recorded.
    public let stepPenalty: Double
    /// The level itself. Unbounded.
    public let level: Double
    /// How much of the total weight had data behind it, 0–1.
    public let coverage: Double

    public init(components: [LevelComponent], raw: Double, stepPenalty: Double, level: Double, coverage: Double) {
        self.components = components
        self.raw = raw
        self.stepPenalty = stepPenalty
        self.level = level
        self.coverage = coverage
    }

    /// The components most worth improving, best first: ranked by HEADROOM (weight × distance to the
    /// wearer's own 100), stable on ties.
    public func levers() -> [LevelComponent] {
        components
            .enumerated()
            .filter { $0.element.score != nil && $0.element.effectiveWeight > 0 }
            .sorted { lhs, rhs in
                lhs.element.headroom == rhs.element.headroom
                    ? lhs.offset < rhs.offset
                    : lhs.element.headroom > rhs.element.headroom
            }
            .map(\.element)
    }
}

public enum LevelEngine {

    /// Steps at or above this add nothing; below it they scale the whole score down.
    public static let stepsFloor = 6000

    /// The most the step penalty can take away, at zero steps.
    public static let stepsMaxPenalty: Double = 0.15

    /// Chronic training load's time constant, in days (the Banister "fitness" constant).
    public static let chronicLoadDays: Double = 42

    /// The meditation share's window and its recency constant, in days.
    public static let meditationWindowDays = 28
    public static let meditationDecayDays: Double = 14
    /// The minutes a day needs to count as a meditated day.
    public static let meditationMinMinutes: Double = 5

    /// How many of the last N days a rolling mean needs before it is a reading.
    public static let rollingDays = 7
    public static let rollingMinDays = 3

    /// The shares inside each part.
    public static let sleepShares = (restorative: 0.60, hrv: 0.25, regularity: 0.15)
    public static let heartShares = (hrv: 0.5, rhr: 0.5)
    public static let lungsShares = (vo2max: 0.75, respRate: 0.25)
    public static let muscleShares = (strength: 0.60, load: 0.40)
    public static let focusShares = (calm: 0.75, meditation: 0.25)

    /// Weighted average over the sub-scores that are present, their shares re-normalised.
    static func blend(_ parts: [(score: Double?, share: Double)]) -> Double? {
        let present = parts.compactMap { p in p.score.map { ($0, p.share) } }
        let total = present.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return present.reduce(0) { $0 + $1.0 * $1.1 } / total
    }

    static func scored(_ value: Double?, _ metric: LevelMetric, _ baselines: [LevelMetric: Baseline],
                       higherIsBetter: Bool) -> Double? {
        guard let value, let b = baselines[metric] ?? LevelBaselines.table[metric] else { return nil }
        return b.score(value, higherIsBetter: higherIsBetter)
    }

    /// The weighted share of meditated days in the last 28, given whether each day (index 0 = the scored
    /// day, 1 = the day before …) was meditated. Days beyond the array count as not meditated.
    public static func meditationShare(meditated: [Bool]) -> Double {
        var num = 0.0, den = 0.0
        for k in 0..<meditationWindowDays {
            let w = exp(-Double(k) / meditationDecayDays)
            den += w
            if k < meditated.count, meditated[k] { num += w }
        }
        return den > 0 ? num / den : 0
    }

    // MARK: - Sub-scores, exposed for the drivers and the coach

    public static func sleepSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.restorativeSleep, scored(i.restorativeMin, .restorativeMin, b, higherIsBetter: true), sleepShares.restorative),
            (.sleepHrv, scored(i.sleepHrv, .hrv, b, higherIsBetter: true), sleepShares.hrv),
            (.sleepRegularity, scored(i.regularityMin, .sleepRegularityMin, b, higherIsBetter: false), sleepShares.regularity),
        ]
    }

    public static func heartSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.hrv, scored(i.hrv, .hrv, b, higherIsBetter: true), heartShares.hrv),
            (.rhr, scored(i.rhr, .rhr, b, higherIsBetter: false), heartShares.rhr),
        ]
    }

    public static func lungsSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.vo2max, scored(i.vo2max, .vo2max, b, higherIsBetter: true), lungsShares.vo2max),
            (.respRate, scored(i.respRate, .respRate, b, higherIsBetter: false), lungsShares.respRate),
        ]
    }

    public static func muscleSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.strength, scored(i.strengthIndex, .strengthIndex, b, higherIsBetter: true), muscleShares.strength),
            (.trainingLoad, scored(i.chronicLoad, .chronicLoad, b, higherIsBetter: true), muscleShares.load),
        ]
    }

    public static func focusSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.daytimeCalm, scored(i.daytimeRmssd, .daytimeRmssd, b, higherIsBetter: true), focusShares.calm),
            // Always present: not meditating is a measured zero, not a missing reading.
            (.meditation, 100 * min(max(i.meditationShare, 0), 1), focusShares.meditation),
        ]
    }

    static func part(_ subs: [(LevelDriver, Double?, Double)]) -> Double? {
        blend(subs.map { ($0.1, $0.2) })
    }

    /// What steps do to the score. Nil steps is "not recorded", which must not be punished.
    public static func stepPenalty(_ steps: Int?) -> Double {
        guard let steps, steps < stepsFloor else { return 1 }
        let shortfall = Double(stepsFloor - steps) / Double(stepsFloor)
        return Swift.max(1 - stepsMaxPenalty * shortfall, 1 - stepsMaxPenalty)
    }

    /// The level. Weights redistributed over the parts that have data; nothing clamped.
    public static func compute(
        inputs: LevelInputs,
        baselines: [LevelMetric: Baseline] = LevelBaselines.table
    ) -> LevelBreakdown? {
        let scores: [LevelPart: Double?] = [
            .sleep: part(sleepSubScores(inputs, baselines)),
            .heart: part(heartSubScores(inputs, baselines)),
            .lungs: part(lungsSubScores(inputs, baselines)),
            .muscle: part(muscleSubScores(inputs, baselines)),
            .focus: part(focusSubScores(inputs, baselines)),
        ]
        let presentWeight = LevelPart.allCases.reduce(0.0) { acc, part in
            acc + ((scores[part] ?? nil) != nil ? part.weight : 0)
        }
        guard presentWeight > 0 else { return nil }

        let components = LevelPart.allCases.map { part -> LevelComponent in
            let score = scores[part] ?? nil
            return LevelComponent(part: part, score: score,
                                  effectiveWeight: score != nil ? part.weight / presentWeight : 0)
        }
        let raw = components.reduce(0) { $0 + $1.contribution }
        let penalty = stepPenalty(inputs.steps)
        return LevelBreakdown(components: components, raw: raw, stepPenalty: penalty,
                              level: raw * penalty, coverage: presentWeight)
    }
}
