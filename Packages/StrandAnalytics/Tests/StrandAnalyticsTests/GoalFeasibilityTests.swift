import XCTest
@testable import StrandAnalytics

/// Goal feasibility verdicts (DESIGN_V2 decision 14). Pinned here: every verdict, the numbers behind it,
/// the realistic-date / realistic-value computation, the unbounded Level, the VO₂max error caveat, the
/// passed-date review (never a penalty), the plausible-rate arithmetic and Codable round-trips.
final class GoalFeasibilityTests: XCTestCase {

    private let currentWeek = "2026-09-28"
    /// Wednesday.
    private let today = "2026-09-30"
    /// Monday 8 weeks ahead (weeksLeft from today = 54 / 7).
    private let in8 = "2026-11-23"

    private func week(_ x: Int) -> String { WeeklyDigestEngine.addDays(currentWeek, 7 * x) }
    private func alt(_ i: Int) -> Double { i % 2 == 0 ? 0.5 : -0.5 }
    private func weekly(_ ys: [Double]) -> [WeeklyValue] {
        let n = ys.count
        return ys.enumerated().map { WeeklyValue(weekStart: week(-n + $0.offset), value: $0.element, readings: 7) }
    }

    /// 80 ± 0.5, no trend. Band at 8 weeks: 80 ± 1.246 (reference implementation).
    private var flatSeries: [WeeklyValue] { weekly((0..<12).map { 80 + alt($0) }) }
    /// 80 + x ± 0.5: rising 1/week, line value 80 at the current week, 88 at +8.
    private var risingSeries: [WeeklyValue] { weekly((0..<12).map { 80 + Double(-12 + $0) + alt($0) }) }

    private func goal(_ metric: ProjectionMetricID = .level, target: Double, date: String, start: Double? = nil,
                      direction: GoalDirection = .increase) -> Goal {
        Goal(id: "g1", metric: metric, target: target, targetDate: date, createdOn: "2026-09-01",
             startValue: start, direction: direction)
    }

    private func assess(_ g: Goal, _ series: [WeeklyValue], plausible: PlausibleRate? = nil) -> GoalAssessment {
        let trend = ProjectionEngine.trend(metric: g.metric, weekly: series, asOf: today)
        return GoalFeasibility.assess(goal: g, current: series.last, trend: trend, plausible: plausible, today: today)
    }

    // MARK: Verdicts

    func testOnTrack() {
        let a = assess(goal(target: 87, date: in8), risingSeries)
        XCTAssertEqual(a.verdict, .onTrack)
        XCTAssertEqual(a.projectedAtDate?.center ?? 0, 88, accuracy: 1e-9)
        XCTAssertEqual(a.current, 78.5)   // x = −1: 79 − 0.5
        XCTAssertEqual(a.requiredPerWeek ?? 0, (87 - 78.5) / (54.0 / 7), accuracy: 1e-9)
        XCTAssertTrue(a.numbersLine.contains("target 87"))
        XCTAssertTrue(a.numbersLine.contains("projected"))
    }

    func testAmbitiousButPlausibleFromTheBandEdge() {
        // Centre 80 misses 81; the band's upper edge (≈ 81.25) reaches it.
        let a = assess(goal(target: 81, date: in8), flatSeries)
        XCTAssertEqual(a.verdict, .ambitiousButPlausible)
    }

    func testAmbitiousButPlausibleFromTheDocumentedRate() {
        // 79.5 → 83: 3.5 at 0.5/week needs 7 weeks; 7.71 are left.
        let a = assess(goal(target: 83, date: in8), flatSeries,
                       plausible: PlausibleRate(rate: .perWeek(0.5), basis: .literature("test")))
        XCTAssertEqual(a.verdict, .ambitiousButPlausible)
        XCTAssertEqual(a.plausiblePerWeek, 0.5)
    }

    func testUnrealisticGivesARealisticDateAndValue() {
        let rate = PlausibleRate(rate: .perWeek(0.25), basis: .literature("test"))
        let a = assess(goal(target: 83, date: in8), flatSeries, plausible: rate)
        XCTAssertEqual(a.verdict, .unrealistic)
        // 3.5 / 0.25 = 14 weeks = 98 days from today.
        XCTAssertEqual(a.realisticDate, WeeklyDigestEngine.addDays(today, 98))
        XCTAssertEqual(a.realisticValue ?? 0, 79.5 + 0.25 * 54.0 / 7, accuracy: 1e-9)
        XCTAssertTrue(a.verdictLine.contains("A realistic date"))
        XCTAssertTrue(a.verdictLine.contains("A realistic value"))
    }

    func testCantJudgeWithoutHistoryOrRate() {
        let short = weekly([80, 81, 79, 80, 81])
        let a = assess(goal(target: 85, date: in8), short)
        XCTAssertEqual(a.verdict, .cantJudgeYet)
        XCTAssertTrue(a.verdictLine.contains("5 of 6"))
        // No current reading at all.
        let none = GoalFeasibility.assess(goal: goal(target: 85, date: in8), current: nil, trend: nil,
                                          plausible: nil, today: today)
        XCTAssertEqual(none.verdict, .cantJudgeYet)
        XCTAssertNil(none.requiredPerWeek)
    }

    func testDocumentedRateAloneCanOnlySayUnrealisticNeverOnTrack() {
        let short = weekly([80, 81, 79, 80, 81])
        let slow = PlausibleRate(rate: .perWeek(0.1), basis: .literature("test"))
        XCTAssertEqual(assess(goal(target: 85, date: in8), short, plausible: slow).verdict, .unrealistic)
        let fast = PlausibleRate(rate: .perWeek(5), basis: .literature("test"))
        XCTAssertEqual(assess(goal(target: 85, date: in8), short, plausible: fast).verdict, .cantJudgeYet)
    }

    func testBeyondTheInformativeHorizonHasNoBand() {
        // Six weeks of history cap the horizon at 5; a date 20 weeks out has no band.
        let six = weekly((0..<6).map { 80 + Double(-6 + $0) + 0.3 * Double(($0 % 3) - 1) })
        let far = WeeklyDigestEngine.addDays(currentWeek, 140)
        let a = assess(goal(target: 200, date: far), six)
        XCTAssertNil(a.projectedAtDate)
        XCTAssertTrue(a.noBandReason?.contains("horizon") ?? false)
    }

    func testReached() {
        let a = assess(goal(target: 78, date: in8), risingSeries)
        XCTAssertEqual(a.verdict, .reached)
    }

    func testDecreaseGoal() {
        // Resting HR falling 0.5/week: 60 at the current week, 56 at +8.
        let falling = weekly((0..<12).map { 60 - 0.5 * Double(-12 + $0) + 0.1 * alt($0) })
        let a = assess(goal(.restingHR, target: 57, date: in8, direction: .decrease), falling)
        XCTAssertEqual(a.verdict, .onTrack)
        XCTAssertLessThan(a.requiredPerWeek ?? 0, 0)
    }

    func testPassedDateIsAnHonestReviewNotAPenalty() {
        let g = goal(target: 90, date: "2026-09-15", start: 70)
        let a = GoalFeasibility.assess(goal: g, current: WeeklyValue(weekStart: week(-1), value: 85, readings: 7),
                                       trend: nil, plausible: nil, today: today, finalValue: 85)
        XCTAssertEqual(a.verdict, .datePassed)
        guard let r = a.review else { return XCTFail("review expected") }
        XCTAssertEqual(r.fractionCovered ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertTrue(r.text.contains("No penalty"))
        XCTAssertTrue(r.text.contains("5 short"))
        XCTAssertTrue(r.text.contains("75 %"))
    }

    // MARK: Unbounded Level

    func testLevelGoalAboveOneHundredIsJudgedWithoutAnyCap() {
        // Rising 2/week from a line value of 120 at the current week.
        let series = weekly((0..<12).map { 120 + 2 * Double(-12 + $0) + alt($0) })
        let reachable = assess(goal(target: 135, date: in8), series)
        XCTAssertEqual(reachable.verdict, .onTrack)
        XCTAssertGreaterThan(reachable.projectedAtDate?.high ?? 0, 135)
        let far = assess(goal(target: 140, date: in8), series)
        XCTAssertEqual(far.verdict, .unrealistic)
        // No plausible rate for the Level here → the realistic date comes from the wearer's own trend:
        // gap 140 − 117.5 = 22.5 at 2/week = 11.25 weeks.
        XCTAssertEqual(far.realisticDate, WeeklyDigestEngine.addDays(today, Int((11.25 * 7).rounded(.up))))
        XCTAssertGreaterThan(far.realisticValue ?? 0, 100)
    }

    // MARK: Caveats and rates

    func testVO2GoalInsideTheEstimateErrorCarriesACaveat() {
        let series = weekly((0..<12).map { 42 + alt($0) })
        let a = assess(goal(.vo2max, target: 44, date: in8), series)
        XCTAssertFalse(a.caveats.isEmpty)
        XCTAssertTrue(a.caveats[0].contains("±5"))
    }

    func testPlausibleRateArithmetic() {
        let per = PlausibleRate(rate: .perWeek(2), basis: .ownHistory)
        XCTAssertEqual(per.weeksNeeded(from: 10, gap: 8) ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(per.reachable(from: 10, weeks: 3, direction: -1) ?? 0, 4, accuracy: 1e-12)

        let rel = PlausibleRate(rate: .relativePerWeek(0.02), basis: .ownHistory)
        let w = rel.weeksNeeded(from: 100, gap: 10) ?? 0
        XCTAssertEqual(rel.reachable(from: 100, weeks: w, direction: 1) ?? 0, 110, accuracy: 1e-9)

        // Aerobic ramp: 100 → 130 → 169 (30 %/week); reaching 150 takes 1 + 20/39 weeks.
        let ramp = PlausibleRate(rate: .compounding(fraction: 0.3, floor: 20), basis: .ownHistory)
        XCTAssertEqual(ramp.weeksNeeded(from: 100, gap: 50) ?? 0, 1 + 20.0 / 39.0, accuracy: 1e-9)
        // From 0 the +20 floor applies.
        XCTAssertEqual(ramp.weeksNeeded(from: 0, gap: 40) ?? 0, 2, accuracy: 1e-9)

        XCTAssertNil(PlausibleRate(rate: .unlimited, basis: .ownHistory).weeksNeeded(from: 1, gap: 5))
    }

    func testOwnFastestFourWeekChange() {
        // Steady +1/week, one 4-week span with +8.
        var ys = (0..<10).map { Double($0) }
        ys[9] = ys[5] + 8
        let r = PlausibleRates.ownFastest(weekly(ys), direction: 1)
        XCTAssertEqual(r ?? 0, 2, accuracy: 1e-12)
        XCTAssertNil(PlausibleRates.ownFastest(weekly(Array(ys.prefix(7))), direction: 1), "needs 8 weeks")
        XCTAssertNil(PlausibleRates.ownFastest(weekly(ys), direction: -1), "never fell over 4 weeks")
    }

    func testEveryMetricKindHasAStatedBasisOrNone() {
        for kind in ProjectionMetricKind.allCases {
            let id = ProjectionMetricID(kind: kind, qualifier: kind == .levelPart ? "heart" : (kind == .e1rm ? "Squat" : nil))
            for dir in [1.0, -1.0] {
                if let r = PlausibleRates.rate(for: id, direction: dir, weekly: [], trainingAge: .novice) {
                    XCTAssertFalse(r.basisText.isEmpty)
                }
            }
        }
        // The Level has no literature rate: without own history there is none at all.
        XCTAssertNil(PlausibleRates.rate(for: .level, direction: 1, weekly: [], trainingAge: nil))
    }

    // MARK: Model

    func testGoalCodableRoundTripAndTolerantDecoding() throws {
        let g = Goal(id: "a", metric: .e1rm(lift: "Bench Press"), target: 100, targetDate: "2026-12-31",
                     startDate: "2026-10-01", createdOn: "2026-09-30", startValue: 90, direction: .increase)
        let data = try JSONEncoder().encode(g)
        XCTAssertEqual(try JSONDecoder().decode(Goal.self, from: data), g)
        let old = #"{"id":"b","metric":{"kind":"restingHR"},"target":55,"targetDate":"2026-12-01","createdOn":"2026-09-30"}"#
        let decoded = try JSONDecoder().decode(Goal.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.direction, .decrease)
        XCTAssertFalse(decoded.archived)
        XCTAssertNil(decoded.startValue)
    }

    func testDirectionFromCurrentValue() {
        XCTAssertEqual(Goal.direction(metric: .restingHR, current: 50, target: 55), .increase)
        XCTAssertEqual(Goal.direction(metric: .level, current: 120, target: 110), .decrease)
        XCTAssertEqual(Goal.direction(metric: .sleepRegularity, current: nil, target: 20), .decrease)
    }
}
