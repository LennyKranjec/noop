import Foundation

// LevelBaselines.swift — the baselines, and why they are frozen.
//
// iOS lane. This scale no longer matches the Android `LevelBaselines`: the level was rebuilt on iOS to
// have no ceiling (see `LevelEngine`), and the Android lane was deliberately left as it is.
//
// Each metric's centre, spread and useful range, derived from the wearer's own history and then never
// touched again.
//
// THIS IS THE WHOLE POINT. A rolling baseline makes you run to stand still: improve, and your own mean
// rises with you, your score falls back toward the middle, and the level hands the gain straight back.
// Frozen, a level is a fixed yardstick — the number moves only when the body does. And with no ceiling
// on the scale, a body that outgrows its old range keeps scoring above 100 rather than pressing against
// a cap.
//
// THE RANGE IS THE 5th AND 95th PERCENTILE, not the literal smallest and largest samples. The top of the
// range is what a score of 100 MEANS — "your own 95th-percentile day" — and one corrupt reading at
// freeze time would otherwise define 100 for good, somewhere the wearer can never reach again.

/// One metric's frozen reference.
///
/// `mean` is where a score of 50 sits. `max` (the 95th percentile) is 100 for a metric where higher is
/// better; `min` (the 5th) is 100 where lower is better. Nothing is clipped: a reading beyond the range
/// scores beyond 100, and one far below the mean scores below 0.
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

    /// The score of `value`: 50 at the mean, 100 at the wearer's 95th-percentile day in the good
    /// direction, linear either side, and UNBOUNDED both ways.
    ///
    /// When the good end of the range sits on the mean — a metric that barely moved at freeze time —
    /// the distance is taken as 1.645 SD instead, which is where the 95th percentile of a normal spread
    /// would be, so the scale still has a sensible slope.
    public func score(_ value: Double, higherIsBetter: Bool) -> Double {
        let best = higherIsBetter ? max : min
        var span = best - mean
        if abs(span) < 1e-6 { span = (higherIsBetter ? 1 : -1) * 1.645 * safeSd }
        return 50 + 50 * (value - mean) / span
    }
}

/// Which metrics the level reads. Named so a missing one can be reported by name.
public enum LevelMetric: String, CaseIterable, Sendable, Codable {
    /// Deep + REM minutes a night.
    case restorativeMin
    /// How far bedtime and wake time moved against the night before, in minutes (lower is better).
    case sleepRegularityMin
    case hrv
    case rhr
    case vo2max
    case respRate
    case muscleLoad
    /// Mean RMSSD over the day's still, scored waking hours — daytime calm.
    case daytimeRmssd
}

public enum LevelBaselines {

    /// How many readings a metric needs before its own history is used instead of the table.
    ///
    /// Two weeks. Below that a mean is dominated by whichever fortnight happened to be sampled — and
    /// since the result is FROZEN, a bad estimate here would be permanent.
    public static let minSamples = 14

    public static let rangeLowPct: Double = 5
    public static let rangeHighPct: Double = 95

    /// The fallback table, for a metric with too little history YET. Never frozen — see
    /// `LevelBaselineStore`: a metric on the table is re-derived on every load until its own history
    /// is deep enough, and frozen then.
    public static let table: [LevelMetric: Baseline] = [
        .restorativeMin: entry(mean: 170, sd: 40),
        .sleepRegularityMin: entry(mean: 45, sd: 25),
        .hrv: entry(mean: 50, sd: 15),
        .rhr: entry(mean: 60, sd: 10),
        .vo2max: entry(mean: 45, sd: 8),
        .respRate: entry(mean: 16, sd: 3),
        .muscleLoad: entry(mean: 5000, sd: 2500),
        .daytimeRmssd: entry(mean: 35, sd: 12),
    ]

    private static func entry(mean: Double, sd: Double) -> Baseline {
        Baseline(mean: mean, sd: sd, min: mean - 1.645 * sd, max: mean + 1.645 * sd)
    }

    /// Whether `history` is deep enough to freeze this metric.
    public static func isDerivable(_ history: [Double]) -> Bool {
        history.filter(\.isFinite).count >= minSamples
    }

    /// Derive one metric's baseline, or its table entry when the history is too thin.
    ///
    /// The SD is the POPULATION form (divide by n).
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

    public static func deriveAll(history: [LevelMetric: [Double]]) -> [LevelMetric: Baseline] {
        var out: [LevelMetric: Baseline] = [:]
        for metric in LevelMetric.allCases {
            out[metric] = derive(metric, history: history[metric] ?? [])
        }
        return out
    }

    /// Linear-interpolated percentile over an ALREADY SORTED array.
    public static func percentile(_ sorted: [Double], _ pct: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = (pct / 100) * Double(sorted.count - 1)
        let lo = Int(rank)
        let hi = Swift.min(lo + 1, sorted.count - 1)
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}
