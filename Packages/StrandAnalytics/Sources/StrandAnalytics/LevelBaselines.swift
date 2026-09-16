import Foundation

// LevelBaselines.swift — the baselines, and why they are frozen.
//
// Swift twin of the Android `com.noop.analytics.LevelBaselines` (the cross-platform parity contract):
// same constants, same percentile interpolation, same population SD, so a level computed on one
// platform equals the level computed on the other.
//
// Each metric's centre, spread and range, derived ONCE from whatever history the wearer had when the
// level first ran, and then never touched again.
//
// THIS IS THE WHOLE POINT. A rolling baseline makes you run to stand still: improve, and your own mean
// rises with you, your z-score falls back toward zero, and the level hands the gain straight back. Two
// people with identical bodies would also sit at different levels because they had different months
// behind them, and the same wearer's level 70 would mean one thing in March and another in December.
// Frozen, a level is a fixed yardstick — the number moves only when the body does.
//
// THE COST, STATED PLAINLY. A frozen scale drifts out of date. Someone who trains for two years will
// press against the top of a range set when they were unfit, and the level stops discriminating at the
// high end. That is the trade, and it is the right one for a score meant to be compared with itself
// over time — but it is a real cost, and `needsRefresh` exists so a deliberate re-derivation is
// possible without the scale silently sliding.
//
// OUTLIERS MATTER MORE HERE, NOT LESS. Because the range is permanent, one corrupt reading at freeze
// time would define the scale forever. The range therefore comes from percentiles rather than the
// literal smallest and largest samples.

/// One metric's frozen reference: where its middle is, how far it usually swings, and the ends of its
/// useful range.
///
/// `mean` and `sd` drive the z-score path used by HRV, RHR, VO2max and respiratory rate. `min` and
/// `max` drive the range path used by muscle load, whose raw unit (kilograms of volume load) has no
/// meaningful centre to deviate from — a wearer's zero is a rest day, not a bad reading.
public struct Baseline: Equatable, Sendable {
    public let mean: Double
    public let sd: Double
    public let min: Double
    public let max: Double

    public init(mean: Double, sd: Double, min: Double, max: Double) {
        self.mean = mean
        self.sd = sd
        self.min = min
        self.max = max
    }

    /// Guards a degenerate spread: a wearer whose readings never move would otherwise divide by zero.
    public var safeSd: Double { sd > 1e-6 ? sd : 1 }

    /// Guards a degenerate range, for the same reason.
    public var safeSpan: Double {
        let span = max - min
        return span > 1e-6 ? span : 1
    }

    /// Where `value` sits in the frozen range, 0–100. Clipped: the range is fixed, readings are not.
    public func position(_ value: Double) -> Double {
        Swift.min(Swift.max(((value - min) / safeSpan) * 100, 0), 100)
    }
}

/// Which metrics the level reads. Named so a missing one can be reported by name.
public enum LevelMetric: String, CaseIterable, Sendable, Codable {
    case sleepScore
    case sleepConsistency
    case hrv
    case rhr
    case vo2max
    case respRate
    case muscleLoad
    case stress
}

public enum LevelBaselines {

    /// How many readings a metric needs before its own history is used instead of the table.
    ///
    /// Two weeks. Below that a mean is dominated by whichever fortnight happened to be sampled, and a
    /// spread estimated from a handful of nights makes every reading look extreme — and since the
    /// result is FROZEN, a bad estimate here is permanent.
    public static let minSamples = 14

    /// The percentiles that define a metric's range.
    ///
    /// Not the literal min and max: the range is frozen forever, so one corrupt reading on the day it
    /// is derived would set the scale for good. The 5th and 95th cut the tails while still spanning
    /// what the wearer actually does.
    public static let rangeLowPct: Double = 5
    public static let rangeHighPct: Double = 95

    /// The fallback table. Used ONLY for a metric with too little history at freeze time; its range is
    /// taken as ±2 SD, which is where the z-score path saturates anyway.
    public static let table: [LevelMetric: Baseline] = [
        .sleepScore: entry(mean: 75, sd: 12),
        .sleepConsistency: entry(mean: 70, sd: 15),
        .hrv: entry(mean: 50, sd: 15),
        .rhr: entry(mean: 60, sd: 10),
        .vo2max: entry(mean: 45, sd: 8),
        .respRate: entry(mean: 16, sd: 3),
        .muscleLoad: entry(mean: 50, sd: 20),
        .stress: entry(mean: 40, sd: 15),
    ]

    private static func entry(mean: Double, sd: Double) -> Baseline {
        Baseline(mean: mean, sd: sd, min: mean - 2 * sd, max: mean + 2 * sd)
    }

    /// Derive one metric's baseline from the readings available at freeze time.
    ///
    /// The SD is the POPULATION form (divide by n), matching the Android twin — the sample form would
    /// put the two platforms a fraction apart on every score, which is exactly the drift the parity
    /// contract exists to catch.
    public static func derive(_ metric: LevelMetric, history: [Double]) -> Baseline {
        let xs = history.filter { $0.isFinite }.sorted()
        guard xs.count >= minSamples else { return table[metric] ?? entry(mean: 50, sd: 15) }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let variance = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
        return Baseline(
            mean: mean,
            sd: variance.squareRoot(),
            min: percentile(xs, rangeLowPct),
            max: percentile(xs, rangeHighPct)
        )
    }

    /// The metrics that must have real history before a scale is worth freezing.
    ///
    /// Sleep and the heart pair carry 53 % of the level between them. A scale frozen before these have
    /// data is a scale made of TABLE ENTRIES — and because it is frozen forever, the wearer is then
    /// measured against a stranger's numbers for good.
    ///
    /// This is not hypothetical. The iOS app derived its baselines on the first level it computed, which
    /// happened before the WHOOP cloud sync had landed any history: HRV fell back to 50 ± 15 and resting
    /// HR to 60 ± 10, and a wearer whose real HRV is well above 50 and resting HR well below 60 scored a
    /// heart component far higher than the same data scored on Android, where the freeze had a year
    /// behind it. Same formula, same import, different yardstick.
    public static let freezeRequires: [LevelMetric] = [.sleepScore, .hrv, .rhr]

    /// Whether `history` is deep enough that freezing it means something.
    ///
    /// A caller that gets `false` should still SCORE — the table gives a usable number today — but must
    /// not write the result down, so the real scale is taken once the history arrives.
    public static func isDerivable(history: [LevelMetric: [Double]]) -> Bool {
        freezeRequires.allSatisfy { (history[$0] ?? []).filter(\.isFinite).count >= minSamples }
    }

    /// Derive every metric at once. What a caller does exactly once, and then stores.
    ///
    /// A metric absent from `history` keeps the table entry rather than being dropped: the set has to
    /// be complete, or a component would silently stop scoring the day a sensor came online.
    public static func deriveAll(history: [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        var out: [LevelMetric: Baseline] = [:]
        for metric in LevelMetric.allCases {
            out[metric] = derive(metric, history: history[metric] ?? [])
        }
        return out
    }

    /// Linear-interpolated percentile over an ALREADY SORTED array.
    ///
    /// Interpolated rather than nearest-rank so the two platforms cannot land on different samples at
    /// the same percentile — with the result frozen, a one-sample disagreement would be permanent.
    public static func percentile(_ sorted: [Double], _ pct: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = (pct / 100) * Double(sorted.count - 1)
        let lo = Int(rank)
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    /// Whether a frozen set is thin enough to be worth re-deriving.
    ///
    /// NOT automatic. A caller may OFFER a re-derivation; nothing here does it on its own, because a
    /// scale that moves by itself is the thing this whole file exists to prevent.
    public static func needsRefresh(_ frozen: [LevelMetric: Baseline]) -> Bool {
        let defaulted = LevelMetric.allCases.filter { frozen[$0] == table[$0] }.count
        return defaulted >= LevelMetric.allCases.count / 2
    }
}
