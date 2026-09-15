import Foundation

// LevelEngine.swift — the level.
//
// Swift twin of the Android `com.noop.analytics.LevelEngine` (the cross-platform parity contract):
// same weights, same clipping, same decay, same redistribution, so the two platforms cannot disagree
// about a wearer's level.
//
// One number, 0–100, for how the wearer is doing. It replaced an XP system entirely: XP was a
// placeholder that measured nothing, and a level derived from the body's own metrics is the thing that
// was always meant to be there.
//
// EVERY INPUT IS MEASURED. Nothing is awarded for using the app, and nothing is invented when a metric
// is missing — a component with no data is EXCLUDED and its weight redistributed over the ones that
// do, so a wearer with no VO2max reading is scored on what was actually recorded rather than against a
// guess. `coverage` says how much of the weight was real.
//
// NORMALISED AGAINST THE WEARER, AND THEN FROZEN. Each raw metric becomes a z-score against that
// wearer's own mean and spread — an HRV of 65 ms is excellent for one person and unremarkable for
// another, and a fixed table would be scoring them against a stranger. But the scale is derived ONCE
// and never moves: see `LevelBaselines` for the full argument and its cost.
//
// STEPS ARE A PENALTY, NOT A COMPONENT. At or above `stepsFloor` they add nothing, and below it they
// scale the whole score down. An earlier draft also scored them, which put a 72-point cliff between
// 5,999 and 6,000 steps; there is no score curve here, so there is no cliff.

/// Everything the level is computed from, already extracted from the stores.
///
/// Three-day figures are arrays so the engine can average them itself and report how many days it
/// actually had — a "3-day mean" over one day is not the same claim, and the UI says so.
public struct LevelInputs: Equatable, Sendable {
    /// Sleep score 0–100, newest last, up to 3 entries.
    public var sleepScores: [Double]
    /// Sleep consistency 0–100, newest last, up to 3 entries.
    public var consistencyScores: [Double]
    public var hrv: Double?
    public var rhr: Double?
    public var vo2max: Double?
    public var respRate: Double?
    /// Recent training sessions as (raw volume load, days ago). Only the last 3 are read.
    public var muscleSessions: [(load: Double, daysAgo: Int)]
    /// Stress 0–100, newest last, up to 3 entries.
    public var stressScores: [Double]
    /// Days with a logged meditation in the last three, 0–3.
    public var meditationDays: Int
    /// Today's step count. Nil when steps are not being recorded at all.
    public var stepsToday: Int?

    public init(
        sleepScores: [Double] = [],
        consistencyScores: [Double] = [],
        hrv: Double? = nil,
        rhr: Double? = nil,
        vo2max: Double? = nil,
        respRate: Double? = nil,
        muscleSessions: [(load: Double, daysAgo: Int)] = [],
        stressScores: [Double] = [],
        meditationDays: Int = 0,
        stepsToday: Int? = nil
    ) {
        self.sleepScores = sleepScores
        self.consistencyScores = consistencyScores
        self.hrv = hrv
        self.rhr = rhr
        self.vo2max = vo2max
        self.respRate = respRate
        self.muscleSessions = muscleSessions
        self.stressScores = stressScores
        self.meditationDays = meditationDays
        self.stepsToday = stepsToday
    }

    public static func == (lhs: LevelInputs, rhs: LevelInputs) -> Bool {
        lhs.sleepScores == rhs.sleepScores
            && lhs.consistencyScores == rhs.consistencyScores
            && lhs.hrv == rhs.hrv
            && lhs.rhr == rhs.rhr
            && lhs.vo2max == rhs.vo2max
            && lhs.respRate == rhs.respRate
            && lhs.muscleSessions.map(\.load) == rhs.muscleSessions.map(\.load)
            && lhs.muscleSessions.map(\.daysAgo) == rhs.muscleSessions.map(\.daysAgo)
            && lhs.stressScores == rhs.stressScores
            && lhs.meditationDays == rhs.meditationDays
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

/// One weighted part of the level, and how much room it has left.
public struct LevelComponent: Equatable, Sendable {
    public let part: LevelPart
    /// 0–100, or nil when there was no data for it.
    public let score: Double?
    /// The weight it carried in THIS calculation, after redistribution. Zero when it had no data.
    public let effectiveWeight: Double

    public init(part: LevelPart, score: Double?, effectiveWeight: Double) {
        self.part = part
        self.score = score
        self.effectiveWeight = effectiveWeight
    }

    /// Points of final level that would be gained by taking this component to 100.
    public var headroom: Double { score.map { (100 - $0) * effectiveWeight } ?? 0 }

    /// Points of final level this component currently contributes.
    public var contribution: Double { (score ?? 0) * effectiveWeight }
}

/// A computed level, with everything needed to explain it.
public struct LevelBreakdown: Equatable, Sendable {
    public let components: [LevelComponent]
    /// Before the step penalty.
    public let raw: Double
    /// The multiplier steps applied, 1.0 when at or above the floor or not recorded.
    public let stepPenalty: Double
    /// The level itself, 0–100.
    public let level: Double
    /// How much of the total weight had data behind it, 0–1.
    public let coverage: Double

    public init(
        components: [LevelComponent],
        raw: Double,
        stepPenalty: Double,
        level: Double,
        coverage: Double
    ) {
        self.components = components
        self.raw = raw
        self.stepPenalty = stepPenalty
        self.level = level
        self.coverage = coverage
    }

    /// The components most worth improving, best first.
    ///
    /// Ranked by HEADROOM — weight times the distance to 100 — not by how low the score is. A lungs
    /// score of 20 is a worse number than a sleep score of 60, but at a weight of 0.07 against 0.30
    /// fixing sleep is worth more than twice as much level. Ranking by the low score would keep
    /// pointing at the metric that matters least.
    ///
    /// Sorted STABLY: Swift's `sorted(by:)` gives no stability guarantee while Kotlin's
    /// `sortedByDescending` does, so ties break on the original index to keep the platforms in step.
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

    /// z is clipped to this many SDs before scaling, so one freak reading cannot dominate.
    public static let zClip: Double = 3

    /// How fast an older training session stops counting, per day.
    public static let muscleDecay: Double = 0.3

    /// Meditation's share of the focus score: 0.5 with none, 1.01 with three days.
    public static let meditationBonusPerDay: Double = 0.17

    public static func z(_ value: Double, _ baseline: Baseline) -> Double {
        let raw = (value - baseline.mean) / baseline.safeSd
        return Swift.min(Swift.max(raw, -zClip), zClip)
    }

    public static func toScale(_ z: Double) -> Double {
        Swift.min(Swift.max(50 + 25 * z, 0), 100)
    }

    /// Sleep: mostly the score itself, with consistency as a modifier.
    ///
    /// Both are already 0–100 and are used RAW, not z-scored — the metrics that get normalised are the
    /// ones with no natural scale, and a sleep score already is one.
    public static func sleep(scores: [Double], consistency: [Double]) -> Double? {
        let s = Array(scores.suffix(3))
        guard !s.isEmpty else { return nil }
        let c = Array(consistency.suffix(3))
        let sMean = s.reduce(0, +) / Double(s.count)
        // Consistency missing is not consistency zero: with no reading, sleep is scored on its score
        // alone rather than being marked down for a measurement that was never taken.
        guard !c.isEmpty else { return sMean }
        return 0.8 * sMean + 0.2 * (c.reduce(0, +) / Double(c.count))
    }

    /// Heart: HRV above baseline and RHR below it, as one figure.
    public static func heart(hrv: Double?, rhr: Double?, baselines: [LevelMetric: Baseline]) -> Double? {
        guard let hrv, let rhr,
              let hrvBase = baselines[.hrv], let rhrBase = baselines[.rhr] else { return nil }
        return toScale(z(hrv, hrvBase) - z(rhr, rhrBase))
    }

    /// Lungs: VO2max, plus a slow respiratory rate.
    public static func lungs(vo2max: Double?, respRate: Double?, baselines: [LevelMetric: Baseline]) -> Double? {
        if vo2max == nil && respRate == nil { return nil }
        let sVo2 = vo2max.flatMap { v in baselines[.vo2max].map { toScale(z(v, $0)) } }
        // Inverted: a HIGH respiratory rate is the bad direction, so its scale is flipped.
        let sRr = respRate.flatMap { r in baselines[.respRate].map { 100 - toScale(z(r, $0)) } }
        switch (sVo2, sRr) {
        case let (v?, r?): return 0.6 * v + 0.4 * r
        case let (v?, nil): return v
        case let (nil, r?): return r
        default: return nil
        }
    }

    /// Muscle: the last three sessions, weighted so today's counts most.
    ///
    /// Exponential decay rather than a flat mean, because a hard session four days ago is not the same
    /// evidence of current training load as one this morning.
    ///
    /// STANDARDISED BY RANGE, NOT BY DEVIATION. The other metrics are z-scored against a mean, which
    /// asks "how unusual is this for you". Volume load has no meaningful centre to deviate from — a
    /// zero is a rest day, not an abnormal reading, and half the distribution sits at or near it. The
    /// frozen min and max answer the question that does apply: where does this session sit between the
    /// lightest and heaviest the wearer actually does.
    public static func muscle(sessions: [(load: Double, daysAgo: Int)], baseline: Baseline) -> Double? {
        let recent = Array(sessions.suffix(3))
        guard !recent.isEmpty else { return nil }
        var num: Double = 0
        var den: Double = 0
        for session in recent {
            let w = exp(-muscleDecay * Double(session.daysAgo))
            num += baseline.position(session.load) * w
            den += w
        }
        return den > 0 ? num / den : nil
    }

    /// Focus: low stress, lifted by having meditated.
    ///
    /// The bonus runs 0.5 to 1.01, so three days of meditation roughly doubles the score a calm day
    /// earns.
    public static func focus(stressScores: [Double], meditationDays: Int) -> Double? {
        let s = Array(stressScores.suffix(3))
        guard !s.isEmpty else { return nil }
        let days = Swift.min(Swift.max(meditationDays, 0), 3)
        let bonus = 0.5 + meditationBonusPerDay * Double(days)
        let value = (100 - (s.reduce(0, +) / Double(s.count))) * bonus
        return Swift.min(Swift.max(value, 0), 100)
    }

    /// What steps do to the score.
    ///
    /// A multiplier, never a component. Nil steps means steps are not being recorded, which must not be
    /// punished as a still day — the wearer cannot fix a sensor they do not have.
    public static func stepPenalty(_ steps: Int?) -> Double {
        guard let steps, steps < stepsFloor else { return 1 }
        let shortfall = Double(stepsFloor - steps) / Double(stepsFloor)
        return Swift.max(1 - stepsMaxPenalty * shortfall, 1 - stepsMaxPenalty)
    }

    /// The level.
    ///
    /// Weights are redistributed over the components that have data, so a missing VO2max does not drag
    /// the level down as if lungs scored zero. With NOTHING measured the level is nil rather than 0: a
    /// zero would read as "you are in terrible shape" when it means "nothing was recorded".
    public static func compute(
        inputs: LevelInputs,
        baselines: [LevelMetric: Baseline] = LevelBaselines.table
    ) -> LevelBreakdown? {
        let muscleBaseline = baselines[.muscleLoad] ?? LevelBaselines.table[.muscleLoad]!
        let scores: [LevelPart: Double?] = [
            .sleep: sleep(scores: inputs.sleepScores, consistency: inputs.consistencyScores),
            .heart: heart(hrv: inputs.hrv, rhr: inputs.rhr, baselines: baselines),
            .lungs: lungs(vo2max: inputs.vo2max, respRate: inputs.respRate, baselines: baselines),
            .muscle: muscle(sessions: inputs.muscleSessions, baseline: muscleBaseline),
            .focus: focus(stressScores: inputs.stressScores, meditationDays: inputs.meditationDays),
        ]
        let presentWeight = LevelPart.allCases.reduce(0.0) { acc, part in
            acc + ((scores[part] ?? nil) != nil ? part.weight : 0)
        }
        guard presentWeight > 0 else { return nil }

        let components = LevelPart.allCases.map { part -> LevelComponent in
            let score = scores[part] ?? nil
            return LevelComponent(
                part: part,
                score: score,
                effectiveWeight: score != nil ? part.weight / presentWeight : 0
            )
        }
        let raw = components.reduce(0) { $0 + $1.contribution }
        let penalty = stepPenalty(inputs.stepsToday)
        return LevelBreakdown(
            components: components,
            raw: raw,
            stepPenalty: penalty,
            level: Swift.min(Swift.max(raw * penalty, 0), 100),
            coverage: presentWeight
        )
    }
}
