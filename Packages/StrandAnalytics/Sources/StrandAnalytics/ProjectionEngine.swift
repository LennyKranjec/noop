import Foundation

// ProjectionEngine.swift — "Look ahead": the CURRENT-TREND projection (DESIGN_V2 coordinator decision 13).
//
// THE WHOLE DESIGN PROBLEM IS HONESTY, so every step below is a stated statistical choice:
//
// 1. WEEKLY VALUES, NOT DAYS. Daily physiology is autocorrelated and noisy; one value per Monday–Sunday
//    week (median for physiology, sum/mean for behaviour — `ProjectionMetricID.aggregation`) is the unit
//    the trend is fitted on. Only COMPLETE weeks count (the week in progress is never extrapolated from).
//
// 2. A ROBUST TREND over the last `maxWeeks` (12) weeks: the Theil–Sen slope — the median of every
//    pairwise slope (Theil 1950; Sen 1968) — with a median intercept. One wild week moves a median of
//    66 pairwise slopes by very little, so an outlier cannot swing the line (tested).
//
// 3. IS IT A TREND AT ALL? The Mann–Kendall test (Mann 1945; Kendall 1975) — the rank test that goes with
//    Theil–Sen — with the tie-corrected variance and continuity correction, two-sided at 5 % (|Z| > 1.96).
//    Not significant ⇒ verdict "no clear trend" and the projection is FLAT at the window's median — never a
//    sloped line drawn through noise. Caveat stated here, not hidden: weekly aggregation reduces but does
//    not remove autocorrelation, which makes the test somewhat liberal; the false-trend rate on pure noise
//    is pinned by test (≈ 5 %, asserted ≤ 10 % over 200 seeded series).
//
// 4. A PREDICTION INTERVAL THAT WIDENS WITH THE HORIZON. For horizon h weeks (x = h, the current week is
//    x = 0, past weeks negative):
//        half-width(h) = t₀.₉₀,ₖ₋₂ · √( σ²·(1 + (π/2)/k) + Var(b)·(h − x̄)² )          (trend)
//        half-width(h) = t₀.₉₀,ₖ₋₂ · √( σ²·(1 + (π/2)/k) + (h − x̄)²·(b² + Var(b)) )     (flat)
//    σ = RMS residual about the Theil–Sen line on k − 2 degrees of freedom, with only gross outliers
//    (|r| > 5 × 1.4826·MAD) left out of σ; Var(b) = 1.1·σ²/Sxx (Theil–Sen's ≈ 0.91 asymptotic efficiency
//    against least squares under normal errors, Sen 1968); π/2 is the variance of a median intercept
//    relative to a mean. In the FLAT case the slope that was set to zero is not forgotten: its square
//    enters as a bias term (a mean-squared-error band), so drawing the line flat never narrows the band.
//    Nominal coverage 80 %; simulated coverage on linear + Gaussian series is pinned by test.
//
// 5. THE HORIZON IS CAPPED WHERE THE BAND STOPS BEING INFORMATIVE. Rule: a horizon h is shown only while
//    the extrapolation factor √(1 + (π/2)/k + 1.1·(h − x̄)²/Sxx) ≤ 2.5, i.e. while the band at h is at
//    most 2.5× as wide as the band from week-to-week scatter alone. The factor depends only on WHICH weeks
//    have data, never on their values, so the cap cannot be gamed by a lucky series. In practice: 6 weeks
//    of history → up to 4 weeks ahead, 8 → 8, 10+ → 12. Never beyond 12.
//
// 6. ABSTENTION. Fewer than `minWeeks` (6) weekly values in the window ⇒ "not enough history to project
//    (n of 6 weeks)". Never a line from 2 points.
//
// 7. NO CLAMPS. The Level and its parts are unbounded both ways (decision 9); no physiological ceiling or
//    floor exists anywhere here. The only bound applied is ARITHMETIC: a quantity that cannot be negative
//    by definition (minutes, steps, kg, ms) never has its lower edge drawn below 0.
//
// Copy produced here says "projection", never "you will".
//
// Pure, deterministic, `yyyy-MM-dd` strings, integer calendar math. Swift-only; Kotlin twin can follow.

// MARK: - Values

/// One dated reading (a day's value, or a session's estimate on its day).
public struct DatedValue: Codable, Equatable, Sendable {
    public let day: String
    public let value: Double
    public init(day: String, value: Double) {
        self.day = day
        self.value = value
    }
}

/// One Monday–Sunday week's single value.
public struct WeeklyValue: Codable, Equatable, Sendable {
    /// Monday, `yyyy-MM-dd`.
    public let weekStart: String
    public let value: Double
    /// Readings the value was made from.
    public let readings: Int
    public init(weekStart: String, value: Double, readings: Int) {
        self.weekStart = weekStart
        self.value = value
        self.readings = readings
    }
}

/// Why a metric has no projection.
public enum ProjectionAbstention: Equatable, Sendable {
    /// Fewer weekly values than needed. The count is shown ("n of 6 weeks").
    case notEnoughHistory(have: Int, need: Int)
    /// The input is not a measurement (e.g. uncalibrated steps). The reason is shown.
    case notMeasured(String)

    public var text: String {
        switch self {
        case .notEnoughHistory(let have, let need):
            return "Not enough history to project (\(have) of \(need) weeks)"
        case .notMeasured(let why):
            return why
        }
    }
}

public enum TrendVerdict: String, Codable, Equatable, Sendable {
    case rising, falling, noClearTrend

    public var text: String {
        switch self {
        case .rising: return "rising"
        case .falling: return "falling"
        case .noClearTrend: return "no clear trend"
        }
    }
}

/// The fitted trend over the window.
public struct TrendFit: Equatable, Sendable {
    /// Weekly values in the window.
    public let n: Int
    /// Values that entered σ (gross outliers left out of the scatter estimate only).
    public let k: Int
    /// Theil–Sen slope, units per week.
    public let slopePerWeek: Double
    /// Line value at the CURRENT week (x = 0).
    public let interceptAtCurrentWeek: Double
    /// Residual scale (RMS on k − 2 df).
    public let sigma: Double
    /// Mann–Kendall Z (continuity- and tie-corrected).
    public let mkZ: Double
    public let significant: Bool
    /// Mean x (weeks relative to the current week, ≤ −1) and Σ(x − x̄)² over the σ set.
    public let xMean: Double
    public let sxx: Double
    /// Median of the window's weekly values (the flat projection's level).
    public let flatLevel: Double
    /// The newest weekly value and its week.
    public let latest: WeeklyValue

    public var verdict: TrendVerdict {
        guard significant else { return .noClearTrend }
        return slopePerWeek > 0 ? .rising : (slopePerWeek < 0 ? .falling : .noClearTrend)
    }
}

/// The band at one horizon.
public struct ProjectionBand: Codable, Equatable, Sendable {
    public let weeksAhead: Int
    /// Monday of the projected week.
    public let weekStart: String
    public let center: Double
    public let low: Double
    public let high: Double
    /// Outer band including the estimate's own error (VO₂max ±5), nil for other metrics.
    public let outerLow: Double?
    public let outerHigh: Double?

    public init(weeksAhead: Int, weekStart: String, center: Double, low: Double, high: Double,
                outerLow: Double? = nil, outerHigh: Double? = nil) {
        self.weeksAhead = weeksAhead
        self.weekStart = weekStart
        self.center = center
        self.low = low
        self.high = high
        self.outerLow = outerLow
        self.outerHigh = outerHigh
    }

    public var halfWidth: Double { (high - low) / 2 }
    public func contains(_ v: Double) -> Bool { v >= low && v <= high }
}

/// A current-trend projection for one metric.
public struct TrendProjection: Equatable, Sendable {
    public let metric: ProjectionMetricID
    /// Monday of the current (in-progress) week; horizon h is h weeks after it.
    public let currentWeek: String
    public let fit: TrendFit
    public let window: [WeeklyValue]
    /// Bands for h = 1 … horizonCap.
    public let bands: [ProjectionBand]
    /// The last informative horizon (rule 5). ≥ 1 whenever a projection exists.
    public let horizonCap: Int

    public var verdict: TrendVerdict { fit.verdict }

    /// The standard horizons (4 / 8 / 12) that pass the cap.
    public var shownHorizons: [Int] { ProjectionEngine.horizons.filter { $0 <= horizonCap } }

    public func band(weeksAhead h: Int) -> ProjectionBand? { bands.first { $0.weeksAhead == h } }

    /// The band for the week containing `day`, nil beyond the cap or in the past.
    public func band(onDay day: String) -> ProjectionBand? {
        guard let h = ProjectionEngine.weeksAhead(of: day, currentWeek: currentWeek), h >= 1 else { return nil }
        return band(weeksAhead: h)
    }

    /// "Rising 0.4 bpm/wk" / "no clear trend" — for the row and the coach.
    public var trendLine: String {
        switch verdict {
        case .noClearTrend:
            return "No clear trend over \(fit.n) weeks — flat projection with its band"
        case .rising, .falling:
            let word = verdict == .rising ? "Rising" : "Falling"
            return word + " " + metric.formatRate(fit.slopePerWeek) + " over \(fit.n) weeks"
        }
    }
}

/// The outcome for one metric: a projection, or an honest abstention.
public enum MetricTrend: Equatable, Sendable {
    case projected(TrendProjection)
    case abstained(ProjectionAbstention)

    public var projection: TrendProjection? {
        if case .projected(let p) = self { return p }
        return nil
    }
    public var abstention: ProjectionAbstention? {
        if case .abstained(let a) = self { return a }
        return nil
    }
}

// MARK: - Statistics

/// The small, pure statistics the projections use. Public for tests.
public enum ProjectionStats {

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Theil–Sen: median pairwise slope and the median intercept at x = 0. nil below 2 distinct x.
    public static func theilSen(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double)? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(xs.count * (xs.count - 1) / 2)
        for i in 0..<xs.count {
            for j in (i + 1)..<xs.count where xs[j] != xs[i] {
                slopes.append((ys[j] - ys[i]) / (xs[j] - xs[i]))
            }
        }
        guard let b = median(slopes) else { return nil }
        var offsets: [Double] = []
        for i in 0..<xs.count { offsets.append(ys[i] - b * xs[i]) }
        guard let a = median(offsets) else { return nil }
        return (b, a)
    }

    /// Mann–Kendall Z for values in time order: S = Σ sign(yⱼ − yᵢ), tie-corrected variance, continuity
    /// correction. 0 when S = 0 or the variance is 0.
    public static func mannKendallZ(_ ys: [Double]) -> Double {
        let n = ys.count
        guard n >= 3 else { return 0 }
        var s = 0
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = ys[j] - ys[i]
                if d > 0 { s += 1 } else if d < 0 { s -= 1 }
            }
        }
        var counts: [Double: Int] = [:]
        for y in ys { counts[y, default: 0] += 1 }
        var tieTerm = 0.0
        for (_, t) in counts where t > 1 {
            let td = Double(t)
            tieTerm += td * (td - 1) * (2 * td + 5)
        }
        let nd = Double(n)
        let variance = (nd * (nd - 1) * (2 * nd + 5) - tieTerm) / 18
        guard s != 0, variance > 0 else { return 0 }
        let corrected = Double(s) - (s > 0 ? 1 : -1)
        return corrected / variance.squareRoot()
    }

    /// Student t quantile at 0.90 (two-sided 80 %). Table values; df ≤ 0 → nil.
    public static func t80(df: Int) -> Double? {
        guard df >= 1 else { return nil }
        let table: [Double] = [3.078, 1.886, 1.638, 1.533, 1.476, 1.440, 1.415, 1.397, 1.383, 1.372,
                               1.363, 1.356, 1.350, 1.345, 1.341, 1.337, 1.333, 1.330, 1.328, 1.325]
        if df <= table.count { return table[df - 1] }
        if df <= 25 { return 1.316 }
        if df <= 30 { return 1.310 }
        if df <= 40 { return 1.303 }
        if df <= 60 { return 1.296 }
        if df <= 120 { return 1.289 }
        return 1.2816
    }

    /// Standard normal 0.90 quantile (the prior bands' multiplier).
    public static let z80: Double = 1.2816

    /// Day number (Julian day) for a `yyyy-MM-dd` string.
    public static func dayNumber(_ day: String) -> Int? {
        guard let (y, m, d) = WeeklyDigestEngine.parseYMD(day) else { return nil }
        return WeeklyDigestEngine.julianDayNumber(y, m, d)
    }
}

// MARK: - Engine

public enum ProjectionEngine {

    /// Weekly values needed before anything is projected.
    public static let minWeeks = 6
    /// The window the trend is fitted on.
    public static let maxWeeks = 12
    /// The horizons Look ahead offers.
    public static let horizons = [4, 8, 12]
    public static let maxHorizon = 12
    /// Two-sided 5 % Mann–Kendall.
    public static let significanceZ = 1.96
    /// Rule 5: the band may be at most this many times as wide as week-to-week scatter alone.
    public static let maxExtrapolationFactor = 2.5
    /// Variance of a median intercept relative to a mean (normal errors).
    public static let medianLevelVariance = Double.pi / 2
    /// Theil–Sen slope variance relative to least squares (≈ 1 / 0.91).
    public static let theilSenSlopeVariance = 1.1
    /// Residuals beyond this many robust SDs are left out of σ (gross outliers only).
    public static let grossOutlierCut = 5.0

    // MARK: Calendar

    /// Monday of the week containing `day`.
    public static func monday(of day: String) -> String? { WeeklyDigestEngine.mondayOfWeek(containing: day) }

    /// Whole weeks from `currentWeek` (a Monday) to the week containing `day` (negative for the past).
    public static func weeksAhead(of day: String, currentWeek: String) -> Int? {
        guard let mon = monday(of: day), let a = ProjectionStats.dayNumber(mon),
              let b = ProjectionStats.dayNumber(currentWeek) else { return nil }
        return (a - b) / 7
    }

    /// Exact (fractional) weeks between two days.
    public static func weeksBetween(_ from: String, _ to: String) -> Double? {
        guard let a = ProjectionStats.dayNumber(from), let b = ProjectionStats.dayNumber(to) else { return nil }
        return Double(b - a) / 7
    }

    // MARK: Weekly aggregation

    /// One value per COMPLETE Monday–Sunday week before the week of `asOf`, oldest first. A week with fewer
    /// than `minReadings` readings has no value (it is a gap, never a zero).
    public static func weekly(_ daily: [DatedValue], asOf: String, aggregation: WeeklyAggregation,
                              minReadings: Int) -> [WeeklyValue] {
        guard let current = monday(of: asOf) else { return [] }
        var byWeek: [String: [Double]] = [:]
        var lastPerDay: [String: Double] = [:]
        for d in daily where d.value.isFinite { lastPerDay[d.day] = d.value }
        for (day, v) in lastPerDay {
            guard let m = monday(of: day), m < current else { continue }
            byWeek[m, default: []].append(v)
        }
        var out: [WeeklyValue] = []
        for (week, xs) in byWeek where xs.count >= max(1, minReadings) {
            let v: Double
            switch aggregation {
            case .median: v = ProjectionStats.median(xs) ?? 0
            case .sum: v = xs.reduce(0, +)
            case .mean: v = xs.reduce(0, +) / Double(xs.count)
            }
            out.append(WeeklyValue(weekStart: week, value: v, readings: xs.count))
        }
        return out.sorted { $0.weekStart < $1.weekStart }
    }

    /// The window: complete weeks within the `maxWeeks` before the current week.
    public static func window(_ weekly: [WeeklyValue], currentWeek: String) -> [WeeklyValue] {
        let floor = WeeklyDigestEngine.addDays(currentWeek, -7 * maxWeeks)
        return weekly.filter { $0.weekStart >= floor && $0.weekStart < currentWeek && $0.value.isFinite }
            .sorted { $0.weekStart < $1.weekStart }
    }

    // MARK: Fit

    /// Fit the window. nil below `minWeeks` (the caller abstains) or on unparseable days.
    public static func fit(_ window: [WeeklyValue], currentWeek: String) -> TrendFit? {
        guard window.count >= minWeeks, let cur = ProjectionStats.dayNumber(currentWeek) else { return nil }
        var xs: [Double] = []
        var ys: [Double] = []
        for w in window {
            guard let d = ProjectionStats.dayNumber(w.weekStart) else { return nil }
            xs.append(Double(d - cur) / 7)
            ys.append(w.value)
        }
        guard let ts = ProjectionStats.theilSen(xs: xs, ys: ys) else { return nil }
        let b = ts.slope
        let a = ts.intercept
        var resid: [Double] = []
        for i in 0..<xs.count { resid.append(ys[i] - (a + b * xs[i])) }
        let robust = 1.4826 * (ProjectionStats.median(resid.map { abs($0) }) ?? 0)
        var keptIdx: [Int] = []
        for (i, r) in resid.enumerated() where robust == 0 || abs(r) <= grossOutlierCut * robust {
            keptIdx.append(i)
        }
        let k = keptIdx.count
        guard k >= 3 else { return nil }
        let ss = keptIdx.reduce(0.0) { $0 + resid[$1] * resid[$1] }
        let sigma = (ss / Double(k - 2)).squareRoot()
        let kx = keptIdx.map { xs[$0] }
        let xMean = kx.reduce(0, +) / Double(k)
        let sxx = kx.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        guard sxx > 0 else { return nil }
        let z = ProjectionStats.mannKendallZ(ys)
        return TrendFit(n: window.count, k: k, slopePerWeek: b, interceptAtCurrentWeek: a, sigma: sigma,
                        mkZ: z, significant: abs(z) > significanceZ, xMean: xMean, sxx: sxx,
                        flatLevel: ProjectionStats.median(ys) ?? a, latest: window[window.count - 1])
    }

    /// Rule 5's factor at horizon h. Data-independent (only the weeks that have values enter it).
    public static func extrapolationFactor(_ f: TrendFit, weeksAhead h: Int) -> Double {
        let dx = Double(h) - f.xMean
        return (1 + medianLevelVariance / Double(f.k) + theilSenSlopeVariance * dx * dx / f.sxx).squareRoot()
    }

    /// Center and half-width at horizon h (before any arithmetic floor).
    public static func centerAndHalfWidth(_ f: TrendFit, weeksAhead h: Int) -> (center: Double, halfWidth: Double) {
        let t = ProjectionStats.t80(df: f.k - 2) ?? ProjectionStats.z80
        let dx = Double(h) - f.xMean
        let varB = theilSenSlopeVariance * f.sigma * f.sigma / f.sxx
        let level = f.sigma * f.sigma * (1 + medianLevelVariance / Double(f.k))
        if f.verdict == .noClearTrend {
            let v = level + dx * dx * (f.slopePerWeek * f.slopePerWeek + varB)
            return (f.flatLevel, t * v.squareRoot())
        }
        let v = level + varB * dx * dx
        return (f.interceptAtCurrentWeek + f.slopePerWeek * Double(h), t * v.squareRoot())
    }

    /// The last horizon (1 … 12) inside rule 5. 0 when not even next week is informative.
    public static func horizonCap(_ f: TrendFit) -> Int {
        var cap = 0
        for h in 1...maxHorizon where extrapolationFactor(f, weeksAhead: h) <= maxExtrapolationFactor { cap = h }
        return cap
    }

    /// Build a band, applying only the arithmetic floor for non-negative quantities and the estimate's
    /// own error as the outer band.
    public static func makeBand(metric: ProjectionMetricID, currentWeek: String, weeksAhead h: Int,
                                center: Double, halfWidth: Double) -> ProjectionBand {
        var c = center
        var lo = center - halfWidth
        let hi = center + halfWidth
        var oLo: Double? = nil
        var oHi: Double? = nil
        if let e = metric.measurementError {
            oLo = lo - e
            oHi = hi + e
        }
        if metric.nonNegative {
            c = max(0, c)
            lo = max(0, lo)
            if let o = oLo { oLo = max(0, o) }
        }
        return ProjectionBand(weeksAhead: h, weekStart: WeeklyDigestEngine.addDays(currentWeek, 7 * h),
                              center: c, low: lo, high: hi, outerLow: oLo, outerHigh: oHi)
    }

    // MARK: Entry points

    /// The current-trend projection from weekly values.
    public static func trend(metric: ProjectionMetricID, weekly: [WeeklyValue], asOf: String) -> MetricTrend {
        guard let current = monday(of: asOf) else { return .abstained(.notEnoughHistory(have: 0, need: minWeeks)) }
        let win = window(weekly, currentWeek: current)
        guard win.count >= minWeeks, let f = fit(win, currentWeek: current) else {
            return .abstained(.notEnoughHistory(have: win.count, need: minWeeks))
        }
        let cap = horizonCap(f)
        guard cap >= 1 else { return .abstained(.notEnoughHistory(have: win.count, need: minWeeks)) }
        var bands: [ProjectionBand] = []
        for h in 1...cap {
            let ch = centerAndHalfWidth(f, weeksAhead: h)
            bands.append(makeBand(metric: metric, currentWeek: current, weeksAhead: h,
                                  center: ch.center, halfWidth: ch.halfWidth))
        }
        return .projected(TrendProjection(metric: metric, currentWeek: current, fit: f, window: win,
                                          bands: bands, horizonCap: cap))
    }

    /// The same from daily readings (aggregated per the metric's rule first).
    public static func trend(metric: ProjectionMetricID, daily: [DatedValue], asOf: String) -> MetricTrend {
        let w = weekly(daily, asOf: asOf, aggregation: metric.aggregation, minReadings: metric.minReadingsPerWeek)
        return trend(metric: metric, weekly: w, asOf: asOf)
    }

    /// "In 8 weeks: projection 104–118 (on your current trend)" — the compact Level-breakdown line.
    /// nil when the 8-week horizon is not informative or the metric abstained (the caller shows the reason).
    public static func compactLine(_ t: MetricTrend, weeks: Int = 8) -> String {
        switch t {
        case .abstained(let a):
            return a.text
        case .projected(let p):
            guard let b = p.band(weeksAhead: weeks) else {
                return "No \(weeks)-week projection: the band is too wide beyond \(p.horizonCap) weeks"
            }
            let m = p.metric
            return "In \(weeks) weeks: projection \(m.format(b.low))–\(m.format(b.high))"
                + (m.unit.isEmpty ? "" : " " + m.unit) + " (current trend, 80 % band)"
        }
    }
}
