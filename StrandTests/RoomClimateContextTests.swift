import XCTest
@testable import Strand

/// The bedroom judged for focus by day and for sleep from the wind-down on: the windows, across
/// midnight, and the scoring.
final class RoomClimateContextTests: XCTestCase {

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// 2026-03-10 (no DST change nearby) at hh:mm local.
    private func at(_ h: Int, _ m: Int = 0, day: Int = 10) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 3, day: day, hour: h, minute: m))!
    }

    // MARK: - Windows

    func testFallbackIsTenThirtyToSeven() {
        let s = RoomClimateSchedule.fallback
        XCTAssertEqual(s.bedtimeMinute, 22 * 60 + 30)
        XCTAssertEqual(s.wakeMinute, 7 * 60)
        XCTAssertEqual(s.sleepStartMinute, 21 * 60)       // 22:30 − 90 min
        XCTAssertEqual(s.focusStartMinute, 7 * 60 + 30)   // 07:00 + 30 min
    }

    func testModesThroughAnOrdinaryDay() {
        let s = RoomClimateSchedule.fallback
        XCTAssertEqual(s.mode(atMinute: 6 * 60 + 59), .sleep)
        XCTAssertEqual(s.mode(atMinute: 7 * 60), .morning)
        XCTAssertEqual(s.mode(atMinute: 7 * 60 + 29), .morning)
        XCTAssertEqual(s.mode(atMinute: 7 * 60 + 30), .focus)
        XCTAssertEqual(s.mode(atMinute: 14 * 60), .focus)
        XCTAssertEqual(s.mode(atMinute: 20 * 60 + 59), .focus)
        XCTAssertEqual(s.mode(atMinute: 21 * 60), .sleep)
        XCTAssertEqual(s.mode(atMinute: 23 * 60 + 59), .sleep)
        XCTAssertEqual(s.mode(atMinute: 0), .sleep)
        XCTAssertEqual(s.mode(atMinute: 3 * 60), .sleep)
    }

    func testASleepWindowThatOpensAfterMidnight() {
        // Bedtime 02:00, wake 10:00 → the sleep window opens at 00:30.
        let s = RoomClimateSchedule(bedtimeMinute: 2 * 60, wakeMinute: 10 * 60, source: .history)
        XCTAssertEqual(s.sleepStartMinute, 30)
        XCTAssertEqual(s.mode(atMinute: 23 * 60 + 30), .focus)
        XCTAssertEqual(s.mode(atMinute: 0), .focus)
        XCTAssertEqual(s.mode(atMinute: 30), .sleep)
        XCTAssertEqual(s.mode(atMinute: 9 * 60 + 59), .sleep)
        XCTAssertEqual(s.mode(atMinute: 10 * 60), .morning)
        XCTAssertEqual(s.mode(atMinute: 10 * 60 + 30), .focus)
    }

    func testAWindDownThatWrapsBackOverMidnight() {
        // Bedtime 00:30 → the window opens at 23:00 the evening before.
        let s = RoomClimateSchedule(bedtimeMinute: 30, wakeMinute: 8 * 60, source: .plan)
        XCTAssertEqual(s.sleepStartMinute, 23 * 60)
        XCTAssertEqual(s.mode(atMinute: 22 * 60 + 59), .focus)
        XCTAssertEqual(s.mode(atMinute: 23 * 60), .sleep)
        XCTAssertEqual(s.mode(atMinute: 1 * 60), .sleep)
    }

    func testANegativeBedtimeFromThePlanWraps() {
        // Wake 06:00 minus nine hours of need is −180 → 21:00.
        let s = RoomClimateSchedule(bedtimeMinute: 6 * 60 - 9 * 60, wakeMinute: 6 * 60, source: .plan)
        XCTAssertEqual(s.bedtimeMinute, 21 * 60)
        XCTAssertEqual(s.sleepStartMinute, 19 * 60 + 30)
    }

    func testADetectedSleepIsTheSleepWindowWhateverTheClock() {
        XCTAssertEqual(RoomClimateSchedule.fallback.mode(atMinute: 14 * 60, asleepNow: true), .sleep)
    }

    func testTheNextWindowFromTheAfternoonIsTonightsSleep() {
        let s = RoomClimateSchedule.fallback
        let next = s.nextWindow(after: at(14), calendar: cal)
        XCTAssertEqual(next.mode, .sleep)
        XCTAssertEqual(next.start, at(21))
    }

    func testTheNextWindowFromLateEveningIsTomorrowsFocus() {
        let s = RoomClimateSchedule.fallback
        let next = s.nextWindow(after: at(23, 15), calendar: cal)
        XCTAssertEqual(next.mode, .focus)
        XCTAssertEqual(next.start, at(7, 30, day: 11))
    }

    func testTheNextWindowFromTheSmallHoursIsThisMorningsFocus() {
        let s = RoomClimateSchedule.fallback
        let next = s.nextWindow(after: at(2), calendar: cal)
        XCTAssertEqual(next.mode, .focus)
        XCTAssertEqual(next.start, at(7, 30))
    }

    func testTheNextWindowAcrossMidnightForALateSleeper() {
        // Window opens at 00:30: from 23:30 it is tomorrow's date, half an hour after midnight.
        let s = RoomClimateSchedule(bedtimeMinute: 2 * 60, wakeMinute: 10 * 60, source: .history)
        let next = s.nextWindow(after: at(23, 30), calendar: cal)
        XCTAssertEqual(next.mode, .sleep)
        XCTAssertEqual(next.start, at(0, 30, day: 11))
    }

    func testTheTypicalNightIsTheMedianTheShortWayRound() {
        XCTAssertEqual(RoomClimateSchedule.circularMedianMinute([23 * 60 + 50, 10, 20]), 10)
        XCTAssertEqual(RoomClimateSchedule.circularMedianMinute([22 * 60, 23 * 60, 22 * 60 + 30]), 22 * 60 + 30)
        XCTAssertEqual(RoomClimateSchedule.circularMedianMinute([7 * 60, 6 * 60 + 30, 7 * 60 + 15]), 7 * 60)
        XCTAssertNil(RoomClimateSchedule.circularMedianMinute([]))
    }

    // MARK: - Scoring

    func testTwentyOneDegreesIsIdealForFocusAndTooWarmForSleep() {
        let s = RoomClimateSchedule.fallback
        let day = RoomClimateContext.evaluate(temperatureC: 21, humidityPct: 47.5, schedule: s, now: at(14), calendar: cal)
        XCTAssertEqual(day.mode, .focus)
        XCTAssertTrue(day.isGood)
        XCTAssertEqual(day.score, 100)
        XCTAssertEqual(day.hint, "A good room for focused work.")
        XCTAssertEqual(day.nextMode, .sleep)

        let night = RoomClimateContext.evaluate(temperatureC: 21, humidityPct: 47.5, schedule: s, now: at(22), calendar: cal)
        XCTAssertEqual(night.mode, .sleep)
        XCTAssertFalse(night.isGood)
        XCTAssertEqual(night.temperature.status, .high)
        XCTAssertEqual(night.temperature.deviation, 1.5, accuracy: 0.001)
        XCTAssertTrue(night.hint.hasPrefix("1.5 °C too warm for sleep"))
    }

    func testTooWarmForFocusNamesTheGapFromTheBandsEdge() {
        let ctx = RoomClimateContext.evaluate(temperatureC: 24.6, humidityPct: 50, schedule: .fallback,
                                              now: at(15), calendar: cal)
        XCTAssertEqual(ctx.temperature.status, .high)
        XCTAssertEqual(ctx.temperature.deviation, 2.1, accuracy: 0.001)
        XCTAssertTrue(ctx.hint.hasPrefix("2.1 °C too warm for focus"), ctx.hint)
        XCTAssertEqual(ctx.temperature.score, 43)   // 85 − 20 × 2.1
        XCTAssertEqual(ctx.score, 43)
    }

    func testTheMorningIsJudgedForFocus() {
        let ctx = RoomClimateContext.evaluate(temperatureC: 18, humidityPct: 50, schedule: .fallback,
                                              now: at(7, 10), calendar: cal)
        XCTAssertEqual(ctx.mode, .morning)
        XCTAssertEqual(ctx.targets, RoomClimateTargets.focus)
        XCTAssertEqual(ctx.temperature.status, .low)
        XCTAssertEqual(ctx.nextMode, .focus)
        XCTAssertEqual(ctx.nextStart, at(7, 30))
    }

    func testScoresInsideTheBandRunFromTheOptimumToTheEdge() {
        let optimum = ClimateDimension(value: 21, range: 20...22.5, optimum: 21, penaltyPerUnit: 20)
        let edge = ClimateDimension(value: 22.5, range: 20...22.5, optimum: 21, penaltyPerUnit: 20)
        let lowEdge = ClimateDimension(value: 20, range: 20...22.5, optimum: 21, penaltyPerUnit: 20)
        XCTAssertEqual(optimum.score, 100)
        XCTAssertEqual(edge.score, 85)
        XCTAssertEqual(lowEdge.score, 85)
        XCTAssertEqual(edge.status, .good)
    }

    func testScoresFloorAtZero() {
        let d = ClimateDimension(value: 35, range: 20...22.5, optimum: 21, penaltyPerUnit: 20)
        XCTAssertEqual(d.score, 0)
        XCTAssertEqual(d.status, .high)
    }

    func testTheWorseProblemLeads() {
        // 22.8 °C is 0.3 over (score 79); 30 % is 10 under (score 55): the dry air leads.
        let ctx = RoomClimateContext.evaluate(temperatureC: 22.8, humidityPct: 30, schedule: .fallback,
                                              now: at(11), calendar: cal)
        XCTAssertEqual(ctx.issues.count, 2)
        XCTAssertTrue(ctx.hint.hasPrefix("Dry air at 30 %"), ctx.hint)
        XCTAssertEqual(ctx.score, 55)
    }

    func testTheSleepTargetsAreTheEveningAdvicesBand() {
        XCTAssertEqual(RoomClimateTargets.sleep.temp, ClimateAdvice.tempLowC...ClimateAdvice.tempHighC)
        XCTAssertEqual(RoomClimateTargets.sleep.humidity, ClimateAdvice.humidityLow...ClimateAdvice.humidityHigh)
    }
}
