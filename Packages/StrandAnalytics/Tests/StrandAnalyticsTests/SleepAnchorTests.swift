import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 S2 §2.5 — one wake anchor, one bedtime. What is pinned:
///
///   * a user target overrides the median; the median is circular (23:50 and 00:10 are 00:00);
///   * payback is 0 below 60 min of debt, a third of it above, never more than 30, and ZERO under the
///     insomnia guard — debt is paid with an earlier bedtime, never a later wake;
///   * no target plus a wake spread over two hours abstains; so does no target with under 7 nights;
///   * the need is labelled as the adult recommendation until there are 7 scored nights;
///   * every time is clock-minute arithmetic, so a DST night cannot move anything by an hour.
final class SleepAnchorTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// `count` consecutive day keys ending on `end`, oldest first.
    private func keys(_ count: Int, endingOn end: String = "2026-09-28") -> [String] {
        let parts = end.split(separator: "-").map { Int($0)! }
        let last = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return (0..<count).reversed().map { back in
            let d = utc.date(byAdding: .day, value: -back, to: last)!
            let c = utc.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
    }

    private func nights(_ wakes: [Int], onset: Int = 23 * 60, asleep: Double? = 450,
                        efficiency: Double? = 0.9, endingOn end: String = "2026-09-28") -> [SleepTimingNight] {
        zip(keys(wakes.count, endingOn: end), wakes).map {
            SleepTimingNight(wakeDay: $0.0, onsetMin: onset, wakeMin: $0.1, asleepMin: asleep, efficiency: efficiency)
        }
    }

    private let monday = 2

    // MARK: - The anchor

    func testAUserTargetOverridesTheMedian() throws {
        let inputs = SleepAnchor.Inputs(nights: nights(Array(repeating: 7 * 60 + 30, count: 10)),
                                        targetWakeMin: 6 * 60 + 45)
        let plan = try XCTUnwrap(SleepAnchor.plan(inputs, wakeWeekday: monday).plan)
        XCTAssertEqual(plan.anchorSource, .userTarget)
        XCTAssertEqual(plan.anchorMin, 6 * 60 + 45)
        // 06:45 − 8 h (population need, no engine need) − 15 min buffer = 22:30.
        XCTAssertEqual(plan.bedtimeMin, 22 * 60 + 30)
        XCTAssertEqual(plan.asleepByMin, 22 * 60 + 45)
    }

    func testTheCircularMedianAcrossMidnightIsMidnightNotNoon() throws {
        XCTAssertEqual(SleepClock.circularMedian([23 * 60 + 50, 10]), 0)
        let wakes = [23 * 60 + 50, 10, 23 * 60 + 50, 10, 23 * 60 + 50, 10, 0]
        let plan = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(wakes)), wakeWeekday: monday).plan)
        XCTAssertEqual(plan.anchorSource, .medianWake)
        XCTAssertEqual(plan.anchorMin, 0)
    }

    func testTheMedianIsRoundedToFiveMinutes() throws {
        let wakes = [7 * 60 + 2, 7 * 60 + 3, 7 * 60 + 1, 7 * 60 + 4, 7 * 60 + 2, 7 * 60 + 3, 7 * 60 + 2]
        let plan = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(wakes)), wakeWeekday: monday).plan)
        XCTAssertEqual(plan.anchorMin, 7 * 60)
    }

    func testAnOnsetAfterMidnightAndAnEarlyBedtimeLandOnTheRightDay() throws {
        // Wake at 09:30 with an 8 h need: bedtime 01:15, the SAME day as the wake.
        let late = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(Array(repeating: 9 * 60 + 30, count: 7),
                                                                         onset: 30)),
                                                   wakeWeekday: monday).plan)
        XCTAssertEqual(late.bedtimeMin, 1 * 60 + 15)
        XCTAssertEqual(late.bedtimeDayShift, 0)
        // Wake at 06:00: bedtime 21:45 the evening BEFORE.
        let early = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(Array(repeating: 6 * 60, count: 7))),
                                                    wakeWeekday: monday).plan)
        XCTAssertEqual(early.bedtimeMin, 21 * 60 + 45)
        XCTAssertEqual(early.bedtimeDayShift, -1)
        XCTAssertEqual(early.windDownDayShift, -1)
    }

    func testTheEveningTimesAreDerivedFromTheOneBedtime() throws {
        let plan = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(Array(repeating: 7 * 60, count: 8))),
                                                   wakeWeekday: monday).plan)
        XCTAssertEqual(plan.windDownStartMin, SleepClock.wrap(plan.bedtimeMin - 60))
        XCTAssertEqual(plan.lightsDimMin, SleepClock.wrap(plan.bedtimeMin - 120))
        XCTAssertEqual(plan.morningLightMin, plan.anchorMin)
        XCTAssertEqual(plan.roomSleepWindowStartMin, plan.windDownStartMin)
        XCTAssertEqual(plan.roomSleepWindowEndMin, plan.anchorMin)
    }

    // MARK: - Payback

    func testPaybackIsZeroBelowAnHourOfDebtAThirdAboveAndCappedAtThirty() {
        XCTAssertEqual(SleepAnchor.payback(debtMin: nil), 0)
        XCTAssertEqual(SleepAnchor.payback(debtMin: 59), 0)
        XCTAssertEqual(SleepAnchor.payback(debtMin: 60), 20)
        XCTAssertEqual(SleepAnchor.payback(debtMin: 75), 25)
        XCTAssertEqual(SleepAnchor.payback(debtMin: 90), 30)
        XCTAssertEqual(SleepAnchor.payback(debtMin: 400), 30)
    }

    func testDebtMovesTheBedtimeEarlierAndNeverTheWake() throws {
        let base = SleepAnchor.Inputs(nights: nights(Array(repeating: 7 * 60, count: 10)))
        var owed = base
        owed.debtMin = 90
        let without = try XCTUnwrap(SleepAnchor.plan(base, wakeWeekday: monday).plan)
        let with = try XCTUnwrap(SleepAnchor.plan(owed, wakeWeekday: monday).plan)
        XCTAssertEqual(with.anchorMin, without.anchorMin, "the wake anchor never moves for debt")
        XCTAssertEqual(SleepClock.wrap(without.bedtimeMin - with.bedtimeMin), 30)
        XCTAssertNotNil(with.paybackLine)
        XCTAssertNil(without.paybackLine)
    }

    func testTheInsomniaGuardZeroesPayback() throws {
        // Efficiency under 80 % on 4 of the last 7 nights (one of them stored as a percentage).
        var ns = nights(Array(repeating: 7 * 60, count: 7))
        ns = ns.enumerated().map { i, n in
            SleepTimingNight(wakeDay: n.wakeDay, onsetMin: n.onsetMin, wakeMin: n.wakeMin, asleepMin: n.asleepMin,
                             efficiency: i < 3 ? 0.70 : (i == 3 ? 72 : 0.92))
        }
        let plan = try XCTUnwrap(SleepAnchor.plan(.init(nights: ns, debtMin: 120), wakeWeekday: monday).plan)
        XCTAssertTrue(plan.insomniaGuard)
        XCTAssertEqual(plan.paybackMin, 0)
        XCTAssertEqual(plan.insomniaLine, SleepAnchor.insomniaNote)
    }

    // MARK: - Abstention

    func testNoTargetAndFewerThanSevenNightsIsCalibrating() {
        let result = SleepAnchor.plan(.init(nights: nights(Array(repeating: 7 * 60, count: 5))), wakeWeekday: monday)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.abstention, .calibrating(nights: 5, needed: 7))
        XCTAssertTrue(result.abstention?.reason.contains("5 of 7") == true)
    }

    func testAWakeSpreadOverTwoHoursWithNoTargetAbstains() {
        let scattered = [4 * 60, 8 * 60, 12 * 60, 16 * 60, 6 * 60, 10 * 60, 14 * 60, 20 * 60]
        let result = SleepAnchor.plan(.init(nights: nights(scattered)), wakeWeekday: monday)
        guard case .abstain(.scheduleTooIrregular(let sd)) = result else {
            return XCTFail("expected scheduleTooIrregular, got \(result)")
        }
        XCTAssertGreaterThan(sd, SleepAnchor.irregularWakeSdMin)
        // A target gives the wearer an anchor anyway.
        XCTAssertNotNil(SleepAnchor.plan(.init(nights: nights(scattered), targetWakeMin: 7 * 60),
                                         wakeWeekday: monday).plan)
    }

    // MARK: - Need

    func testTheNeedIsLabelledAsTheAdultRecommendationBelowSevenNights() throws {
        let few = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(Array(repeating: 7 * 60, count: 3)),
                                                        needHours: 8.25, targetWakeMin: 7 * 60),
                                                  wakeWeekday: monday).plan)
        XCTAssertTrue(few.needIsPopulationDefault)
        XCTAssertEqual(few.needMin, 480)
        XCTAssertTrue(few.needLine.contains("adult recommendation"))
        let enough = try XCTUnwrap(SleepAnchor.plan(.init(nights: nights(Array(repeating: 7 * 60, count: 10)),
                                                           needHours: 8.25),
                                                     wakeWeekday: monday).plan)
        XCTAssertFalse(enough.needIsPopulationDefault)
        XCTAssertEqual(enough.needMin, 495)
        XCTAssertTrue(enough.needLine.contains("~8 h 15 m"))
    }

    // MARK: - Weekend, confidence, DST

    func testTheWeekendOffsetMovesOnlySaturdayAndSundayAndIsCapped() throws {
        let inputs = SleepAnchor.Inputs(nights: nights(Array(repeating: 7 * 60, count: 8)), weekendOffsetMin: 45)
        XCTAssertEqual(SleepAnchor.plan(inputs, wakeWeekday: 7).plan?.anchorMin, 7 * 60 + 45)
        XCTAssertEqual(SleepAnchor.plan(inputs, wakeWeekday: 1).plan?.anchorMin, 7 * 60 + 45)
        XCTAssertEqual(SleepAnchor.plan(inputs, wakeWeekday: monday).plan?.anchorMin, 7 * 60)
        var big = inputs
        big.weekendOffsetMin = 150
        XCTAssertEqual(SleepAnchor.plan(big, wakeWeekday: 7).plan?.anchorMin, 8 * 60)
    }

    func testConfidenceIsBuildingBelowFourteenNightsAndSolidAtFourteen() {
        XCTAssertEqual(SleepAnchor.plan(.init(nights: nights(Array(repeating: 420, count: 9))),
                                        wakeWeekday: monday).plan?.confidence, .building)
        XCTAssertEqual(SleepAnchor.plan(.init(nights: nights(Array(repeating: 420, count: 14))),
                                        wakeWeekday: monday).plan?.confidence, .solid)
    }

    func testADSTNightIsClockMinutesNotSeconds() throws {
        // Nights either side of the EU spring change (2026-03-29): the wake stays 07:00 on the clock, and
        // the bedtime is the same clock minute on the day of the change as on any other.
        let dst = nights(Array(repeating: 7 * 60, count: 8), endingOn: "2026-03-30")
        let weekday = try XCTUnwrap(SleepClock.weekday(of: "2026-03-29"))
        XCTAssertEqual(weekday, 1)   // a Sunday
        let plan = try XCTUnwrap(SleepAnchor.plan(.init(nights: dst), wakeWeekday: weekday).plan)
        XCTAssertEqual(plan.anchorMin, 7 * 60)
        XCTAssertEqual(plan.bedtimeMin, 22 * 60 + 45)
    }

    func testIntegerCalendarMathMatchesFoundation() {
        for key in keys(400, endingOn: "2026-12-31") {
            let parts = key.split(separator: "-").map { Int($0)! }
            let d = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
            XCTAssertEqual(SleepClock.weekday(of: key), utc.component(.weekday, from: d), key)
            XCTAssertEqual(SleepClock.dayNumber(key), Int(d.timeIntervalSince1970 / 86_400), key)
        }
        XCTAssertNil(SleepClock.dayNumber("2026-13-01"))
    }
}
