import XCTest
@testable import StrandAnalytics

/// The current-trend projection (DESIGN_V2 decision 13). Pinned here:
///   * a known slope is recovered, pure noise reads "no clear trend" (and is drawn FLAT), and outliers do
///     not swing the Theil–Sen line;
///   * the prediction interval widens with the horizon and covers ≈ 80 % of simulated futures;
///   * abstention below 6 weekly values ("n of 6 weeks"), never a line from 2 points;
///   * the horizon cap rule (band ≤ 2.5 × the scatter-only band): 6 weeks → 4-week horizon only,
///     8 → up to 8, 10+ → 12;
///   * the Level is unbounded both ways; only non-negative-by-definition figures get a floor at 0;
///   * VO₂max carries its ±5 outer band.
/// Expected numbers were computed with an independent re-implementation over the same SplitMix64 stream.
final class ProjectionEngineTests: XCTestCase {

    /// A Monday (the current week).
    private let currentWeek = "2026-09-28"
    /// Wednesday of that week.
    private let today = "2026-09-30"

    private func week(_ x: Int) -> String { WeeklyDigestEngine.addDays(currentWeek, 7 * x) }

    /// n complete weeks before the current one: start + slope·x + sd·N(0,1), x = −n … −1.
    private func series(seed: UInt64, n: Int, slope: Double, sd: Double, start: Double = 50)
        -> (weekly: [WeeklyValue], rng: DeterministicRNG) {
        var rng = DeterministicRNG(seed: seed)
        var out: [WeeklyValue] = []
        for i in 0..<n {
            let x = -n + i
            out.append(WeeklyValue(weekStart: week(x), value: start + slope * Double(x) + sd * rng.nextGaussian(),
                                   readings: 7))
        }
        return (out, rng)
    }

    private func values(_ ys: [Double]) -> [WeeklyValue] {
        let n = ys.count
        return ys.enumerated().map { WeeklyValue(weekStart: week(-n + $0.offset), value: $0.element, readings: 7) }
    }

    private func alt(_ i: Int) -> Double { i % 2 == 0 ? 0.5 : -0.5 }

    private func projected(_ t: MetricTrend, file: StaticString = #filePath, line: UInt = #line) -> TrendProjection? {
        guard let p = t.projection else {
            XCTFail("expected a projection, got \(String(describing: t.abstention))", file: file, line: line)
            return nil
        }
        return p
    }

    // MARK: Trend estimation

    func testKnownSlopeIsRecovered() {
        let s = series(seed: 42, n: 12, slope: 0.5, sd: 0.3)
        guard let p = projected(ProjectionEngine.trend(metric: .restingHR, weekly: s.weekly, asOf: today)) else { return }
        XCTAssertEqual(p.fit.slopePerWeek, 0.5, accuracy: 0.1)
        XCTAssertEqual(p.verdict, .rising)
        XCTAssertEqual(p.fit.n, 12)
    }

    func testExactLineIsExact() {
        let ys = (0..<12).map { 80 + Double(-12 + $0) + alt($0) }
        guard let p = projected(ProjectionEngine.trend(metric: .level, weekly: values(ys), asOf: today)) else { return }
        XCTAssertEqual(p.fit.slopePerWeek, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p.fit.interceptAtCurrentWeek, 80, accuracy: 1e-9)
        XCTAssertEqual(p.band(weeksAhead: 8)?.center ?? 0, 88, accuracy: 1e-9)
    }

    func testPureNoiseIsNoClearTrendAndDrawnFlat() {
        let s = series(seed: 99, n: 12, slope: 0, sd: 1)
        guard let p = projected(ProjectionEngine.trend(metric: .hrv, weekly: s.weekly, asOf: today)) else { return }
        XCTAssertEqual(p.verdict, .noClearTrend)
        let c4 = p.band(weeksAhead: 4)?.center
        let c12 = p.band(weeksAhead: 12)?.center
        XCTAssertNotNil(c4)
        XCTAssertEqual(c4, c12, "no clear trend ⇒ flat projection, never a sloped line")
        XCTAssertEqual(c4 ?? 0, p.fit.flatLevel, accuracy: 1e-12)
        XCTAssertTrue(p.trendLine.contains("No clear trend"))
    }

    func testFalseTrendRateOnNoiseIsLow() {
        var trends = 0
        for s in 1...200 {
            let ser = series(seed: 1000 + UInt64(s), n: 12, slope: 0, sd: 1)
            if ProjectionEngine.trend(metric: .hrv, weekly: ser.weekly, asOf: today).projection?.verdict != .noClearTrend {
                trends += 1
            }
        }
        // Nominal 5 %; the reference implementation finds 6 of 200.
        XCTAssertLessThanOrEqual(trends, 20)
    }

    func testOutliersDoNotSwingTheTrend() {
        let clean = series(seed: 7, n: 12, slope: 0.5, sd: 0.3).weekly
        var dirty = clean
        dirty[5] = WeeklyValue(weekStart: clean[5].weekStart, value: clean[5].value + 20, readings: 7)
        dirty[9] = WeeklyValue(weekStart: clean[9].weekStart, value: clean[9].value - 15, readings: 7)
        guard let a = projected(ProjectionEngine.trend(metric: .level, weekly: clean, asOf: today)),
              let b = projected(ProjectionEngine.trend(metric: .level, weekly: dirty, asOf: today)) else { return }
        XCTAssertEqual(a.fit.slopePerWeek, b.fit.slopePerWeek, accuracy: 0.1)
        XCTAssertEqual(b.verdict, .rising)
        // The gross outliers are kept out of the scatter estimate only.
        XCTAssertLessThan(b.fit.k, b.fit.n)
    }

    // MARK: Interval

    func testIntervalWidensWithHorizon() {
        for seed: UInt64 in [42, 99] {
            let s = series(seed: seed, n: 12, slope: seed == 42 ? 0.5 : 0, sd: seed == 42 ? 0.3 : 1)
            guard let p = projected(ProjectionEngine.trend(metric: .level, weekly: s.weekly, asOf: today)) else { return }
            let w = [4, 8, 12].compactMap { p.band(weeksAhead: $0)?.halfWidth }
            XCTAssertEqual(w.count, 3)
            XCTAssertLessThan(w[0], w[1])
            XCTAssertLessThan(w[1], w[2])
            for b in p.bands { XCTAssertLessThanOrEqual(b.low, b.center); XCTAssertGreaterThanOrEqual(b.high, b.center) }
        }
    }

    func testCoverageOnSimulatedTrendingSeries() {
        for h in [4, 8, 12] {
            var covered = 0
            let n = 400
            for s in 0..<n {
                var ser = series(seed: 77_000 + UInt64(s), n: 12, slope: 1.0, sd: 1.0)
                guard let p = ProjectionEngine.trend(metric: .level, weekly: ser.weekly, asOf: today).projection,
                      let b = p.band(weeksAhead: h) else { XCTFail("no band"); return }
                let truth = 50 + 1.0 * Double(h) + ser.rng.nextGaussian()
                if b.contains(truth) { covered += 1 }
            }
            let rate = Double(covered) / Double(n)
            // Nominal 80 %; reference: 0.81 / 0.80 / 0.79.
            XCTAssertGreaterThanOrEqual(rate, 0.72, "h=\(h)")
            XCTAssertLessThanOrEqual(rate, 0.88, "h=\(h)")
        }
    }

    func testCoverageOnSimulatedFlatSeriesIsNotBelowNominal() {
        var covered = 0
        let n = 400
        for s in 0..<n {
            var ser = series(seed: 88_000 + UInt64(s), n: 12, slope: 0, sd: 1.0)
            guard let p = ProjectionEngine.trend(metric: .level, weekly: ser.weekly, asOf: today).projection,
                  let b = p.band(weeksAhead: 4) else { XCTFail("no band"); return }
            if b.contains(50 + ser.rng.nextGaussian()) { covered += 1 }
        }
        // The flat band keeps the discarded slope as a bias term, so it is conservative (reference 0.91).
        XCTAssertGreaterThanOrEqual(Double(covered) / Double(n), 0.80)
    }

    // MARK: Abstention and horizon cap

    func testAbstainsBelowSixWeeks() {
        let five = values([60, 61, 59, 62, 60])
        let t = ProjectionEngine.trend(metric: .restingHR, weekly: five, asOf: today)
        XCTAssertEqual(t.abstention, .notEnoughHistory(have: 5, need: 6))
        XCTAssertTrue(t.abstention?.text.contains("5 of 6 weeks") ?? false)
        let two = values([60, 70])
        XCTAssertNil(ProjectionEngine.trend(metric: .restingHR, weekly: two, asOf: today).projection,
                     "never a line from 2 points")
    }

    func testWeeksOutsideTheWindowDoNotCount() {
        // Six weeks, but two of them older than the 12-week window.
        var ws = values([60, 61, 59, 62])
        ws.append(WeeklyValue(weekStart: week(-13), value: 60, readings: 7))
        ws.append(WeeklyValue(weekStart: week(-20), value: 60, readings: 7))
        XCTAssertEqual(ProjectionEngine.trend(metric: .restingHR, weekly: ws, asOf: today).abstention,
                       .notEnoughHistory(have: 4, need: 6))
    }

    func testHorizonCapGrowsWithHistory() {
        func cap(_ n: Int) -> [Int] {
            let ys = (0..<n).map { Double(-n + $0) + 0.3 * Double(($0 % 3) - 1) }
            return ProjectionEngine.trend(metric: .level, weekly: values(ys), asOf: today).projection?.shownHorizons ?? []
        }
        XCTAssertEqual(cap(6), [4])
        XCTAssertEqual(cap(8), [4, 8])
        XCTAssertEqual(cap(10), [4, 8, 12])
        XCTAssertEqual(cap(12), [4, 8, 12])
    }

    func testCapRuleIsTheStatedFactor() {
        let ys = (0..<6).map { Double(-6 + $0) + 0.3 * Double(($0 % 3) - 1) }
        guard let p = projected(ProjectionEngine.trend(metric: .level, weekly: values(ys), asOf: today)) else { return }
        XCTAssertLessThanOrEqual(ProjectionEngine.extrapolationFactor(p.fit, weeksAhead: p.horizonCap), 2.5)
        if p.horizonCap < ProjectionEngine.maxHorizon {
            XCTAssertGreaterThan(ProjectionEngine.extrapolationFactor(p.fit, weeksAhead: p.horizonCap + 1), 2.5)
        }
        XCTAssertNil(p.band(weeksAhead: p.horizonCap + 1))
    }

    // MARK: No clamps

    func testLevelIsUnboundedAboveAndBelow() {
        let rising = (0..<12).map { 120 + 2 * Double(-12 + $0) + alt($0) }
        guard let up = projected(ProjectionEngine.trend(metric: .level, weekly: values(rising), asOf: today)) else { return }
        XCTAssertEqual(up.band(weeksAhead: 12)?.center ?? 0, 144, accuracy: 1e-9)
        XCTAssertGreaterThan(up.band(weeksAhead: 12)?.high ?? 0, 144)

        let falling = (0..<12).map { 10 - 3 * Double($0) + alt($0) }   // 10 → −23, still falling
        guard let down = projected(ProjectionEngine.trend(metric: .part(.sleep), weekly: values(falling), asOf: today))
        else { return }
        XCTAssertLessThan(down.band(weeksAhead: 4)?.low ?? 0, 0, "the Level and its parts are never floored")
    }

    func testNonNegativeQuantitiesAreFlooredAtZeroOnly() {
        let falling = (0..<12).map { 3000 - 250 * Double($0) + 50 * alt($0) }
        guard let p = projected(ProjectionEngine.trend(metric: .steps, weekly: values(falling), asOf: today)) else { return }
        for b in p.bands { XCTAssertGreaterThanOrEqual(b.low, 0); XCTAssertGreaterThanOrEqual(b.center, 0) }
    }

    func testVO2HasItsFivePointOuterBand() {
        let ys = (0..<12).map { 42 + 0.1 * Double(-12 + $0) + alt($0) }
        guard let p = projected(ProjectionEngine.trend(metric: .vo2max, weekly: values(ys), asOf: today)),
              let b = p.band(weeksAhead: 4) else { return }
        XCTAssertEqual(b.outerLow ?? 0, b.low - 5, accuracy: 1e-9)
        XCTAssertEqual(b.outerHigh ?? 0, b.high + 5, accuracy: 1e-9)
        XCTAssertNil(ProjectionEngine.trend(metric: .level, weekly: values(ys), asOf: today).projection?
            .band(weeksAhead: 4)?.outerLow)
    }

    // MARK: Weekly aggregation

    func testWeeklyAggregationUsesCompleteWeeksAndLeavesGaps() {
        var daily: [DatedValue] = []
        // Last week: 7 days of 10 minutes (sum 70). The week before: only 3 days (a gap for a sum metric).
        for i in 0..<7 { daily.append(DatedValue(day: WeeklyDigestEngine.addDays(week(-1), i), value: 10)) }
        for i in 0..<3 { daily.append(DatedValue(day: WeeklyDigestEngine.addDays(week(-2), i), value: 10)) }
        // This week (in progress) is never used.
        daily.append(DatedValue(day: currentWeek, value: 500))
        let w = ProjectionEngine.weekly(daily, asOf: today, aggregation: .sum, minReadings: 5)
        XCTAssertEqual(w, [WeeklyValue(weekStart: week(-1), value: 70, readings: 7)])
        let med = ProjectionEngine.weekly(daily, asOf: today, aggregation: .median, minReadings: 3)
        XCTAssertEqual(med.map(\.weekStart), [week(-2), week(-1)])
    }

    func testCompactLineSaysProjectionNeverYouWill() {
        let ys = (0..<12).map { 80 + Double(-12 + $0) + alt($0) }
        let line = ProjectionEngine.compactLine(ProjectionEngine.trend(metric: .level, weekly: values(ys), asOf: today))
        XCTAssertTrue(line.contains("projection"))
        XCTAssertFalse(line.lowercased().contains("you will"))
        XCTAssertTrue(ProjectionEngine.compactLine(.abstained(.notEnoughHistory(have: 3, need: 6))).contains("3 of 6"))
    }
}
