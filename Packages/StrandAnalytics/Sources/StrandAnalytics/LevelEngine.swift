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
// NO BOUNDED PROXIES. A score that is itself a percentage has a ceiling baked in: a sleep score cannot
// pass 100 %, a stress score cannot fall below 0, three days of meditation cannot become four. So the
// parts are built from the measured quantities underneath, which only biology bounds:
//
//   · SLEEP  — deep + REM minutes (0.60), HRV through the night (0.25), and how far bedtime and wake
//              time moved against the night before (0.15, lower is better).
//   · HEART  — HRV (0.5) and resting heart rate (0.5, lower is better).
//   · LUNGS  — VO₂max (0.6) and respiratory rate (0.4, lower is better).
//   · MUSCLE — the last three sessions' volume load, weighted by how recent they were.
//   · FOCUS  — daytime calm, the RMSSD of the still waking hours (0.5), and meditation (0.5).
//
// MEDITATION IS THE ONE EXCEPTION, AND THE EXCEPTION IS DELIBERATE. It has no biological ceiling — an
// hour a day would simply out-score everything else — so it is not scored against a baseline at all.
// It is the minutes meditated over the UNBROKEN run of consecutive days, approaching 100 along
// 100 × (1 − e^(−minutes / τ)). A single missed day resets the run to zero, which is what makes the
// daily habit the point rather than the minutes: ten minutes a day for a month is worth far more than
// two hours once.
//
// EVERY INPUT IS MEASURED. A component with no data is EXCLUDED and its weight redistributed over the
// ones that do; inside a part, a missing sub-metric is redistributed the same way. `coverage` says how
// much of the weight was real.
//
// STEPS ARE A PENALTY, NOT A COMPONENT. At or above `stepsFloor` they add nothing; below it they scale
// the whole level down, by at most `stepsMaxPenalty`.

/// Everything the level is computed from, already extracted from the stores.
///
/// Three-day figures are arrays, newest last; the engine averages the last three it is given.
public struct LevelInputs: Equatable, Sendable {
    /// Deep + REM minutes per night.
    public var restorativeMin: [Double]
    /// HRV through the night, per night.
    public var sleepHrv: [Double]
    /// Minutes bedtime and wake time moved against the night before, per night (mean of the two ends).
    public var regularityMin: [Double]
    public var hrv: Double?
    public var rhr: Double?
    public var vo2max: Double?
    public var respRate: Double?
    /// Recent training sessions as (raw volume load, days ago). Only the last 3 are read.
    public var muscleSessions: [(load: Double, daysAgo: Int)]
    /// Daytime calm: mean RMSSD over the still, scored waking hours, per day.
    public var daytimeRmssd: [Double]
    /// Minutes meditated across the unbroken run of consecutive days ending on the scored day.
    public var meditationStreakMin: Double
    /// The day's step count. Nil when steps are not being recorded at all.
    public var stepsToday: Int?

    public init(
        restorativeMin: [Double] = [],
        sleepHrv: [Double] = [],
        regularityMin: [Double] = [],
        hrv: Double? = nil,
        rhr: Double? = nil,
        vo2max: Double? = nil,
        respRate: Double? = nil,
        muscleSessions: [(load: Double, daysAgo: Int)] = [],
        daytimeRmssd: [Double] = [],
        meditationStreakMin: Double = 0,
        stepsToday: Int? = nil
    ) {
        self.restorativeMin = restorativeMin
        self.sleepHrv = sleepHrv
        self.regularityMin = regularityMin
        self.hrv = hrv
        self.rhr = rhr
        self.vo2max = vo2max
        self.respRate = respRate
        self.muscleSessions = muscleSessions
        self.daytimeRmssd = daytimeRmssd
        self.meditationStreakMin = meditationStreakMin
        self.stepsToday = stepsToday
    }

    public static func == (lhs: LevelInputs, rhs: LevelInputs) -> Bool {
        lhs.restorativeMin == rhs.restorativeMin
            && lhs.sleepHrv == rhs.sleepHrv
            && lhs.regularityMin == rhs.regularityMin
            && lhs.hrv == rhs.hrv
            && lhs.rhr == rhs.rhr
            && lhs.vo2max == rhs.vo2max
            && lhs.respRate == rhs.respRate
            && lhs.muscleSessions.map(\.load) == rhs.muscleSessions.map(\.load)
            && lhs.muscleSessions.map(\.daysAgo) == rhs.muscleSessions.map(\.daysAgo)
            && lhs.daytimeRmssd == rhs.daytimeRmssd
            && lhs.meditationStreakMin == rhs.meditationStreakMin
            && lhs.stepsToday == rhs.stepsToday
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
        case .lungs: return 0.07
        case .muscle: return 0.24
        case .focus: return 0.16
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

    /// How fast an older training session stops counting, per day.
    public static let muscleDecay: Double = 0.3

    /// The meditation curve's time constant, in minutes of an unbroken daily run.
    ///
    /// 100 minutes: ten minutes a day reaches 50 after a week, 95 after a month; twenty a day reaches
    /// 94 after two weeks. A single long session on a broken run cannot get there.
    public static let meditationTauMin: Double = 100

    /// The shares inside each part.
    public static let sleepShares = (restorative: 0.60, hrv: 0.25, regularity: 0.15)
    public static let heartShares = (hrv: 0.5, rhr: 0.5)
    public static let lungsShares = (vo2max: 0.6, respRate: 0.4)
    public static let focusShares = (calm: 0.5, meditation: 0.5)

    /// The mean of the last three values, or nil when there are none.
    static func mean3(_ xs: [Double]) -> Double? {
        let s = Array(xs.filter(\.isFinite).suffix(3))
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

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

    /// The meditation sub-score: 100 × (1 − e^(−minutes / τ)) over an unbroken daily run.
    public static func meditationScore(streakMinutes: Double) -> Double {
        100 * (1 - exp(-Swift.max(streakMinutes, 0) / meditationTauMin))
    }

    // MARK: - Sub-scores, exposed for the drivers and the coach

    public static func sleepSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.restorativeSleep, scored(mean3(i.restorativeMin), .restorativeMin, b, higherIsBetter: true), sleepShares.restorative),
            (.sleepHrv, scored(mean3(i.sleepHrv), .hrv, b, higherIsBetter: true), sleepShares.hrv),
            (.sleepRegularity, scored(mean3(i.regularityMin), .sleepRegularityMin, b, higherIsBetter: false), sleepShares.regularity),
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

    public static func focusSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.daytimeCalm, scored(mean3(i.daytimeRmssd), .daytimeRmssd, b, higherIsBetter: true), focusShares.calm),
            // Always present: not meditating is a measured zero, not a missing reading.
            (.meditation, meditationScore(streakMinutes: i.meditationStreakMin), focusShares.meditation),
        ]
    }

    // MARK: - Parts

    public static func sleep(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> Double? {
        blend(sleepSubScores(i, b).map { ($0.1, $0.2) })
    }

    public static func heart(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> Double? {
        blend(heartSubScores(i, b).map { ($0.1, $0.2) })
    }

    public static func lungs(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> Double? {
        blend(lungsSubScores(i, b).map { ($0.1, $0.2) })
    }

    /// The last three sessions' volume load, each scored against the wearer's baseline, weighted by
    /// e^(−decay × days ago).
    public static func muscle(sessions: [(load: Double, daysAgo: Int)], baseline: Baseline) -> Double? {
        let recent = Array(sessions.suffix(3))
        guard !recent.isEmpty else { return nil }
        var num: Double = 0
        var den: Double = 0
        for session in recent {
            let w = exp(-muscleDecay * Double(session.daysAgo))
            num += baseline.score(session.load, higherIsBetter: true) * w
            den += w
        }
        return den > 0 ? num / den : nil
    }

    public static func focus(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> Double? {
        blend(focusSubScores(i, b).map { ($0.1, $0.2) })
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
        let muscleBaseline = baselines[.muscleLoad] ?? LevelBaselines.table[.muscleLoad]!
        let scores: [LevelPart: Double?] = [
            .sleep: sleep(inputs, baselines),
            .heart: heart(inputs, baselines),
            .lungs: lungs(inputs, baselines),
            .muscle: muscle(sessions: inputs.muscleSessions, baseline: muscleBaseline),
            .focus: focus(inputs, baselines),
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
        let penalty = stepPenalty(inputs.stepsToday)
        return LevelBreakdown(components: components, raw: raw, stepPenalty: penalty,
                              level: raw * penalty, coverage: presentWeight)
    }
}
