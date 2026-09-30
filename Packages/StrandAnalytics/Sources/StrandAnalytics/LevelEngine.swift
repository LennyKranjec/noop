import Foundation

// LevelEngine.swift — the level.
//
// iOS lane. The Android `LevelEngine` is unchanged and no longer matches this one: on iOS the level was
// rebuilt to have NO CEILING, at the wearer's request. (HEALTH_V2 H6 and the owner's recipe decisions of
// 2026-09-29 below diverge from Android further; the PR says so.)
//
// WHAT 100 MEANS. Every input is scored against the wearer's own frozen baseline: 50 is their average
// day, 100 is their own 95th-percentile day in the good direction (see `Baseline.score`). A day on which
// every part sits at its own 95th percentile, with no step penalty and no meditation deduction, is a
// level of 100. Beyond that the level keeps rising — nothing is clipped, anywhere: no part has a ceiling
// and no input is capped (owner decision, 2026-09-29: "no bound other than my physiology") — and a bad
// enough day falls below 0. The only ceiling left is the body's.
//
// A LEVEL OF STATE, NOT OF THE WEEK'S TREND. Every physiological input is a 7-day mean (regularity a
// 14-night spread), strength is a twelve-week best and training load a 42-day chronic figure — so a bad
// night, a deload week or one missed session barely moves the level, and months of real progress do.
//
// THE RECIPE (ledger epoch 4, `LevelLedger.currentEpoch`) — ONE RECIPE FOR THE WHOLE HISTORY. Every
// scored input is something the strap, the WHOOP data or the workout log carried in January as it does
// now, so a day in January and a day today are scored the same way and can be compared:
//
//   · SLEEP  (30 %) — deep + REM minutes (0.60), night HRV (0.25), bedtime/wake regularity (0.15:
//                     the night-to-night drift, lower is better). 7-night means. EPOCH 5 RESTORED THIS:
//                     epoch 4 had swapped in duration-vs-need and a 14-night wake SD, which the owner
//                     found flattened the level ("my best days had the best scores; now everything is
//                     flattened out"). Only the owner's two decisions stay: no ceiling, and meditation
//                     only as a deduction.
//   · MUSCLE (24 %) — strength (0.60: the estimated-1RM index) and chronic training load (0.40).
//   · HEART  (23 %) — HRV (0.5) and resting HR (0.5, lower is better). 7-day means.
//   · LUNGS  (12 %) — VO₂max (0.75) and respiratory rate (0.25, lower is better, 7-day mean).
//   · FOCUS  (11 %) — daytime calm only (7-day mean RMSSD over the still, scored waking hours).
//
// MEDITATION IS NOT A PLUS ANY MORE — ONLY A DEDUCTION, AND ONLY IN ITS ERA. (Owner decision, 2026-09-29:
// meditation did not exist in the app in January, so it must not lift today's level over January's.) It
// is the ONE place a behaviour touches the measured level, and only because the owner asked for it by
// name; every other quest penalty stays on the game layer (XP, streaks, debt quests).
//   · The era starts on the wearer's first logged meditation. Before it there is no meditation term at
//     all — no bonus, no penalty — so January is untouched.
//   · In the era, each day of the level's 7-day window that has data behind it (a day row exists) and
//     whose logged minutes are under the minimum in force THAT day (`meditationMinMinutes(on:)`: 5 min
//     before 2026-09-29, 10 min from it) is a miss and costs `meditationMissPenaltyPoints` (1.0) level
//     point, subtracted after the step multiplier. A fully missed week costs 7 points; a met day costs
//     nothing; a day with no data at all is not a miss — "not measured" is never "missed".
//   · It is a deduction, not a cap: the level stays unbounded above.
//
// EVERY INPUT IS MEASURED. A component with no data is EXCLUDED and its weight redistributed over the
// ones that do; inside a part, a missing sub-metric is redistributed the same way. `coverage` says how
// much of the weight was real — and below `minCoverage` there is no level at all, because redistributing
// the whole formula onto a tenth of it produces a confident number that measured almost nothing.
//
// STEPS ARE A PENALTY, NOT A COMPONENT: the 7-day average against `stepsFloor`, by at most
// `stepsMaxPenalty`.
//
// A FINDING FOR THE OWNER, NOT A BOUND: the chronic-training-load term measures training DONE, not
// adaptation. Left uncapped (owner decision), the muscle part can rise from volume alone before any
// physiological change shows in strength, HRV or resting HR. The honest fix, if wanted, is a different
// input (load-normalised strength, HR at a fixed pace), not a cap.

/// Everything the level is computed from, already extracted from the stores.
///
/// The wiring hands over figures that are already averaged over their windows.
public struct LevelInputs: Equatable, Sendable {
    /// Deep + REM minutes a night, 7-night mean.
    public var restorativeMin: Double?
    /// Night HRV, 7-night mean. NOT SCORED since epoch 4 (HRV is counted once, in heart); kept so the
    /// missing-input list can still say whether a night carried HRV.
    public var sleepHrv: Double?
    /// Wake-time regularity: the circular SD of wake times over the last 14 nights, in minutes
    /// (`SleepRegularity.wakeSdMin`, needs 7). Lower is better.
    public var regularityMin: Double?
    /// Sleep duration against need: the 7-night mean of asleep ÷ need. Not capped (see the header).
    public var sleepDurationRatio: Double?
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
    /// Meditation-era days in the level's 7-day window that had data and fell under that day's minimum —
    /// or NIL outside the meditation era (no log at all, or every window day before the first one), where
    /// there is no meditation term whatsoever. 0 is a real reading: in the era, nothing missed.
    ///
    /// NEVER A PLUS. Meditation only ever deducts (see the header), so nil and 0 score identically.
    public var meditationMissedDays: Int?
    /// Average daily steps over the last 7 days. Nil when steps are not being recorded at all.
    public var steps: Int?

    public init(
        restorativeMin: Double? = nil,
        sleepHrv: Double? = nil,
        regularityMin: Double? = nil,
        sleepDurationRatio: Double? = nil,
        hrv: Double? = nil,
        rhr: Double? = nil,
        vo2max: Double? = nil,
        respRate: Double? = nil,
        strengthIndex: Double? = nil,
        chronicLoad: Double? = nil,
        daytimeRmssd: Double? = nil,
        meditationMissedDays: Int? = nil,
        steps: Int? = nil
    ) {
        self.restorativeMin = restorativeMin
        self.sleepHrv = sleepHrv
        self.regularityMin = regularityMin
        self.sleepDurationRatio = sleepDurationRatio
        self.hrv = hrv
        self.rhr = rhr
        self.vo2max = vo2max
        self.respRate = respRate
        self.strengthIndex = strengthIndex
        self.chronicLoad = chronicLoad
        self.daytimeRmssd = daytimeRmssd
        self.meditationMissedDays = meditationMissedDays
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
    /// How much of the total weight had data behind it, 0–1. Never below `LevelEngine.minCoverage`:
    /// a thinner day has no level, not a low one.
    public let coverage: Double

    public init(components: [LevelComponent], raw: Double, stepPenalty: Double, level: Double, coverage: Double) {
        self.components = components
        self.raw = raw
        self.stepPenalty = stepPenalty
        self.level = level
        self.coverage = coverage
    }

    /// Level points the meditation term deducted (0 outside the meditation era or with nothing missed).
    /// DERIVED from the stored figures — `raw × stepPenalty − level` — so a breakdown rebuilt from the
    /// ledger (`FrozenLevel.breakdown`) carries it without a new stored field.
    public var meditationPenalty: Double { Swift.max(0, raw * stepPenalty - level) }

    /// `coverage` as whole per cent — the figure the breakdown puts on screen beside the level, so a
    /// level built from half the formula cannot read like one built from all of it.
    public var coveragePercent: Int { Int((Swift.min(Swift.max(coverage, 0), 1) * 100).rounded()) }

    /// Whether some of the formula had no data behind it, so its weight was shared out over the rest.
    /// Honest arithmetic, but invisible without saying so.
    public var isPartialCoverage: Bool { coverage < 0.999 }

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

    /// The Focus card's 28-day meditation window and its recency constant. Not part of the level since
    /// epoch 4; kept for the card and `meditationShare(meditated:)`.
    public static let meditationWindowDays = 28
    public static let meditationDecayDays: Double = 14

    // MARK: - The meditation minimum (date-effective)

    /// THE MEDITATION MINIMUM IS DATE-EFFECTIVE (owner decision, 2026-09-29: "raise it to 10 minutes").
    /// Days before this are judged by the rule in force then (5 min), days from it on by the new one
    /// (10 min), so a recompute never re-labels a past day that met its own rule as a miss. Everything
    /// that asks "was this a meditation day" reads `meditationMinMinutes(on:)`: the level's deduction, the
    /// Focus card's circles and badge (`MeditationLog.isDayDone`) and the quest floor (`QuestDayPlan`).
    public static let meditationMinChangeoverDay = "2026-09-29"
    /// The minimum before the changeover.
    public static let meditationMinMinutesBeforeChangeover: Double = 5
    /// The minimum in force from the changeover on — the CURRENT rule, for copy that names today's line.
    /// A dated question must use `meditationMinMinutes(on:)`.
    public static let meditationMinMinutes: Double = 10

    /// The minutes `day` (`yyyy-MM-dd`) needed to count as a meditated day.
    public static func meditationMinMinutes(on day: String) -> Double {
        day < meditationMinChangeoverDay ? meditationMinMinutesBeforeChangeover : meditationMinMinutes
    }

    /// Whether `minutes` logged on `day` meet that day's rule.
    public static func isMeditationDay(minutes: Double, on day: String) -> Bool {
        minutes.isFinite && minutes >= meditationMinMinutes(on: day)
    }

    /// Level points each missed meditation-era day in the 7-day window deducts. A fully missed week is
    /// 7 points — about the step multiplier's worst case at a level of 50 (15 % of 50 = 7.5): meaningful
    /// against a typical day's ~50 without dominating it.
    public static let meditationMissPenaltyPoints: Double = 1.0
    /// The window misses are counted over: the level's own rolling window.
    public static let meditationPenaltyWindowDays = rollingDays

    /// Points deducted for `missedDays`. Nil (outside the era) deducts nothing.
    public static func meditationPenalty(missedDays: Int?) -> Double {
        Double(Swift.max(0, missedDays ?? 0)) * meditationMissPenaltyPoints
    }

    /// The least of the level's weight that has to have real data behind it before there is a level.
    ///
    /// WHY THERE IS A FLOOR AT ALL. Redistributing an absent part's weight over the parts that remain is
    /// the right arithmetic, but it has no lower limit: with one part of five measured the engine would
    /// scale that part up to the whole formula and hand back a number indistinguishable from a fully
    /// measured one. On a fresh install that is exactly what happened — a level of 0.0 at 11 % coverage,
    /// frozen for the day and then dragged through the 3- and 30-day means for a month.
    ///
    /// 0.40 is deliberately below the 0.53 a band-only wearer reaches with sleep and heart alone on their
    /// first week, and above the 0.35 that any two of the small parts can reach between them. Below it
    /// `compute` returns nil, the headline reads "–", and the day settles as a gap rather than as a score.
    public static let minCoverage: Double = 0.40

    /// How many of the last N days a rolling mean needs before it is a reading.
    public static let rollingDays = 7
    public static let rollingMinDays = 3

    /// The shares inside each part. HRV is in exactly one of them (heart); focus is daytime calm alone.
    public static let sleepShares = (restorative: 0.60, hrv: 0.25, regularity: 0.15)
    public static let heartShares = (hrv: 0.5, rhr: 0.5)
    public static let lungsShares = (vo2max: 0.75, respRate: 0.25)
    public static let muscleShares = (strength: 0.60, load: 0.40)
    public static let focusShares = (calm: 1.0, meditation: 0.0)

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
    /// day, 1 = the day before …) was meditated. Days beyond the array count as not meditated. Not part
    /// of the level since epoch 4.
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

    /// Daytime calm only. Meditation left the positive side of the formula at epoch 4 (see the header):
    /// it is a deduction in `compute`, never a sub-score.
    public static func focusSubScores(_ i: LevelInputs, _ b: [LevelMetric: Baseline]) -> [(LevelDriver, Double?, Double)] {
        [
            (.daytimeCalm, scored(i.daytimeRmssd, .daytimeRmssd, b, higherIsBetter: true), focusShares.calm),
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

    /// The level. Weights redistributed over the parts that have data; nothing clamped. The meditation
    /// deduction (meditation era only) is subtracted after the step multiplier.
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
        // NOT `> 0`. See `minCoverage`: a level from almost nothing is not a low level, it is no level.
        guard presentWeight >= minCoverage else { return nil }

        let components = LevelPart.allCases.map { part -> LevelComponent in
            let score = scores[part] ?? nil
            return LevelComponent(part: part, score: score,
                                  effectiveWeight: score != nil ? part.weight / presentWeight : 0)
        }
        let raw = components.reduce(0) { $0 + $1.contribution }
        let penalty = stepPenalty(inputs.steps)
        let meditation = meditationPenalty(missedDays: inputs.meditationMissedDays)
        return LevelBreakdown(components: components, raw: raw, stepPenalty: penalty,
                              level: raw * penalty - meditation, coverage: presentWeight)
    }
}
