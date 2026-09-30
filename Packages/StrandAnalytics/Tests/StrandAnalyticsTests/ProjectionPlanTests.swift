import XCTest
@testable import StrandAnalytics

/// The "if you follow the plan" scenario (DESIGN_V2 decision 13, built on HEALTH_V2 S3). Pinned here:
///   * the wearer's OWN dose-response is used first when there is enough of it;
///   * otherwise a published typical response — labelled as such — with a WIDER band than the trend's;
///   * no prior and no own data (HRV, the Level) ⇒ the scenario abstains with the count still needed;
///   * aerobic minutes / steps follow the plan's own ramp (`WeekPlanEngine`), steps only with a step plan;
///   * a plan that adds no dose, and figures the plan does not move, equal the trend — said plainly;
///   * the Level plan scenario is never clamped.
final class ProjectionPlanTests: XCTestCase {

    private let currentWeek = "2026-09-28"
    private let today = "2026-09-30"

    private func week(_ x: Int) -> String { WeeklyDigestEngine.addDays(currentWeek, 7 * x) }
    private func alt(_ i: Int) -> Double { i % 2 == 0 ? 0.5 : -0.5 }

    /// Weekly values for x = −n … −1.
    private func weekly(_ ys: [Double]) -> [WeeklyValue] {
        let n = ys.count
        return ys.enumerated().map { WeeklyValue(weekStart: week(-n + $0.offset), value: $0.element, readings: 7) }
    }

    private func flat(_ level: Double, n: Int = 12) -> [WeeklyValue] { weekly((0..<n).map { level + alt($0) }) }

    /// Dose in blocks of 4 weeks alternating low/high, oldest first, ending with a LOW block.
    private func blockDose(n: Int, low: Double, high: Double) -> [Double] {
        (0..<n).map { i in
            let blockFromEnd = (n - 1 - i) / 4
            return blockFromEnd % 2 == 0 ? low : high
        }
    }

    // MARK: Paths

    func testAerobicPathFollowsThePlanRamp() {
        let path = PlanScenario.aerobicPath(recent: [60, 60, 60, 60], thisWeekTarget: 80)
        XCTAssertEqual(path.count, 13)
        XCTAssertEqual(path[0], 80)
        XCTAssertEqual(path[1], WeekPlanEngine.buildAerobicTarget(b: 65))
        for i in 1..<path.count {
            XCTAssertGreaterThanOrEqual(path[i], path[i - 1])
            XCTAssertLessThanOrEqual(path[i], WeekPlanEngine.whoHigh)
        }
        // At/above the top of the range the plan holds (it never pushes past what the wearer does).
        XCTAssertEqual(PlanScenario.aerobicPath(recent: [400, 400, 400, 400], thisWeekTarget: nil, weeks: 3),
                       [400, 400, 400, 400])
    }

    func testStepsPathRampsToThePlateauAndHolds() {
        XCTAssertEqual(PlanScenario.stepsPath(thisWeekTarget: 6000, plateau: 8000, weeks: 4),
                       [6000, 7000, 8000, 8000, 8000])
    }

    // MARK: Own response first

    func testOwnResponseIsUsedWhenThereIsEnough() {
        let n = 20
        let dose = blockDose(n: n + 4, low: 0, high: 150)
        let doseHistory = weekly(dose)
        let lagged = PlanScenario.laggedDose(doseHistory)
        // Resting HR responds to the 4-week dose at −0.02 bpm per weekly minute (+ tiny alternation).
        let metric = (0..<n).map { i -> WeeklyValue in
            let wk = week(-n + i)
            return WeeklyValue(weekStart: wk, value: 65 - 0.02 * (lagged[wk] ?? 0) + 0.1 * alt(i), readings: 7)
        }
        let trend = ProjectionEngine.trend(metric: .restingHR, weekly: metric, asOf: today)
        let path = PlanScenario.aerobicPath(recent: Array(dose.suffix(4)), thisWeekTarget: nil)
        let plan = PlanScenario.project(metric: .restingHR, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: metric, doseHistory: doseHistory,
                                                                   planPath: path))
        guard let p = plan.projection else { return XCTFail("expected a plan projection: \(plan)") }
        guard case .ownResponse(let pairs, let slope) = p.basis else { return XCTFail("expected own response, got \(p.basis)") }
        XCTAssertGreaterThanOrEqual(pairs, PlanScenario.minPairs)
        XCTAssertEqual(slope, -0.02, accuracy: 0.01)
        XCTAssertFalse(p.basis.isPrior)
    }

    // MARK: Prior fallback, wider band

    func testFallsBackToThePublishedPriorWithAWiderBand() {
        let metric = flat(60)
        let doseHistory = weekly(Array(repeating: 60, count: 16))   // never varied → no own response
        let trend = ProjectionEngine.trend(metric: .restingHR, weekly: metric, asOf: today)
        let path = PlanScenario.aerobicPath(recent: [60, 60, 60, 60], thisWeekTarget: 80)
        let plan = PlanScenario.project(metric: .restingHR, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: metric, doseHistory: doseHistory,
                                                                   planPath: path))
        guard let p = plan.projection, let t = trend.projection else { return XCTFail("expected projections") }
        XCTAssertTrue(p.basis.isPrior)
        XCTAssertTrue(p.basis.label.contains("Typical response, not yours yet"))
        for h in [4, 8, 12] {
            guard let pb = p.band(weeksAhead: h), let tb = t.band(weeksAhead: h) else { return XCTFail("h=\(h)") }
            XCTAssertLessThan(pb.center, tb.center, "more aerobic dose ⇒ typical resting-HR drop")
            XCTAssertGreaterThan(pb.halfWidth, tb.halfWidth, "a prior widens the band")
        }
    }

    func testVO2PriorKeepsTheOuterErrorBand() {
        let metric = weekly((0..<12).map { 40 + alt($0) })
        let trend = ProjectionEngine.trend(metric: .vo2max, weekly: metric, asOf: today)
        let plan = PlanScenario.project(metric: .vo2max, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: metric,
                                                                   doseHistory: weekly(Array(repeating: 30, count: 12)),
                                                                   planPath: PlanScenario.aerobicPath(recent: [30, 30, 30, 30], thisWeekTarget: nil)))
        guard let b = plan.projection?.band(weeksAhead: 8) else { return XCTFail("expected a band") }
        XCTAssertEqual(b.outerHigh ?? 0, b.high + 5, accuracy: 1e-9)
        XCTAssertGreaterThan(b.center, 40)
    }

    func testNoPriorAndNoOwnDataAbstainsWithTheCountNeeded() {
        for metric in [ProjectionMetricID.hrv, .level] {
            let series = flat(55)
            let trend = ProjectionEngine.trend(metric: metric, weekly: series, asOf: today)
            let plan = PlanScenario.project(metric: metric, trend: trend,
                                            inputs: PlanScenarioInputs(metricWeekly: series,
                                                                       doseHistory: weekly(Array(repeating: 60, count: 16)),
                                                                       planPath: PlanScenario.aerobicPath(recent: [60, 60, 60, 60], thisWeekTarget: 80)))
            guard case .abstained(let why) = plan else { return XCTFail("\(metric.id) should abstain") }
            XCTAssertTrue(why.contains("needs your own response"), why)
            XCTAssertTrue(why.contains("vary by at least 60"), why)
        }
    }

    // MARK: Plan targets, holds, not modelled

    func testAerobicMinutesFollowThePlanTargets() {
        let series = flat(100)
        let trend = ProjectionEngine.trend(metric: .aerobicMinutes, weekly: series, asOf: today)
        let path = PlanScenario.aerobicPath(recent: [100, 100, 100, 100], thisWeekTarget: 120)
        let plan = PlanScenario.project(metric: .aerobicMinutes, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: series, doseHistory: series, planPath: path))
        guard let p = plan.projection else { return XCTFail("expected plan targets") }
        XCTAssertEqual(p.basis, .planTargets)
        XCTAssertEqual(p.band(weeksAhead: 4)?.center, path[4])
    }

    func testStepsWithoutAStepPlanAbstain() {
        let series = flat(7000)
        let trend = ProjectionEngine.trend(metric: .steps, weekly: series, asOf: today)
        let plan = PlanScenario.project(metric: .steps, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: series, doseHistory: [], planPath: []))
        guard case .abstained(let why) = plan else { return XCTFail("steps without a gate must abstain") }
        XCTAssertTrue(why.contains("not calibrated"))
    }

    func testAPlanThatAddsNoDoseEqualsTheTrend() {
        let series = flat(58)
        let trend = ProjectionEngine.trend(metric: .restingHR, weekly: series, asOf: today)
        let plan = PlanScenario.project(metric: .restingHR, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: series,
                                                                   doseHistory: weekly(Array(repeating: 300, count: 8)),
                                                                   planPath: Array(repeating: 300, count: 13)))
        XCTAssertEqual(plan.projection?.basis, .holdsDose)
        XCTAssertEqual(plan.projection?.bands, trend.projection?.bands)
    }

    func testFiguresThePlanDoesNotMoveEqualTheTrend() {
        let series = flat(70)
        let trend = ProjectionEngine.trend(metric: .part(.sleep), weekly: series, asOf: today)
        let plan = PlanScenario.project(metric: .part(.sleep), trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: series, doseHistory: [],
                                                                   planPath: [80, 90, 100]))
        XCTAssertEqual(plan.projection?.basis, .notModelled)
        XCTAssertEqual(plan.projection?.bands, trend.projection?.bands)
    }

    func testTrendAbstentionCarriesOver() {
        let short = flat(60, n: 4)
        let trend = ProjectionEngine.trend(metric: .restingHR, weekly: short, asOf: today)
        let plan = PlanScenario.project(metric: .restingHR, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: short, doseHistory: [], planPath: [80, 90]))
        guard case .abstained(let why) = plan else { return XCTFail("expected abstention") }
        XCTAssertTrue(why.contains("4 of 6"))
    }

    // MARK: Unbounded Level

    func testLevelPlanScenarioIsNeverClamped() {
        let n = 20
        let dose = blockDose(n: n + 4, low: 0, high: 150)
        let doseHistory = weekly(dose)
        let lagged = PlanScenario.laggedDose(doseHistory)
        let metric = (0..<n).map { i -> WeeklyValue in
            let wk = week(-n + i)
            return WeeklyValue(weekStart: wk, value: 100 + 0.1 * (lagged[wk] ?? 0) + 0.2 * alt(i), readings: 7)
        }
        let trend = ProjectionEngine.trend(metric: .level, weekly: metric, asOf: today)
        let path = PlanScenario.aerobicPath(recent: Array(dose.suffix(4)), thisWeekTarget: nil)
        let plan = PlanScenario.project(metric: .level, trend: trend,
                                        inputs: PlanScenarioInputs(metricWeekly: metric, doseHistory: doseHistory,
                                                                   planPath: path))
        guard let p = plan.projection, let t = trend.projection,
              let pb = p.band(weeksAhead: 8), let tb = t.band(weeksAhead: 8) else {
            return XCTFail("expected projections: \(plan)")
        }
        guard case .ownResponse = p.basis else { return XCTFail("expected own response, got \(p.basis)") }
        XCTAssertGreaterThan(pb.center, tb.center)
        XCTAssertGreaterThan(pb.center, 100, "100 is the wearer's own 95th percentile, not a maximum")
        XCTAssertGreaterThan(pb.high, pb.center)
    }
}
