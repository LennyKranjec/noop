import XCTest
@testable import Strand

/// WHY THIS FILE EXISTS. The wearer's report was: "he can't tell which day it is — asked what's due
/// tomorrow, he tells me today's charge." The data context has always listed DATED rows, and nothing
/// anywhere said what those dates meant: that a charge is the state of one specific morning, that today's
/// row is still incomplete, or that for tomorrow there is no charge at all yet. `CoachDayFrame` is the block
/// that says so, and these pin the parts a future edit could quietly drop.
final class CoachDayFrameTests: XCTestCase {

    /// 2026-09-29 12:00 local in Berlin (CEST, UTC+2) — a Tuesday.
    private let noon = Date(timeIntervalSince1970: 1_790_676_000)
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    func testItNamesTodayyesterdayAndTomorrowByDate() {
        let s = CoachDayFrame.block(now: noon, timeZone: berlin)
        XCTAssertTrue(s.contains("TODAY is 2026-09-29"), s)
        XCTAssertTrue(s.contains("YESTERDAY was 2026-09-28"), s)
        XCTAssertTrue(s.contains("TOMORROW is 2026-09-30"), s)
    }

    /// The weekday is ENGLISH whatever the device language: the prompt is English, and a model reads
    /// "Tuesday" mid-sentence better than "Dienstag".
    func testTheWeekdayIsEnglish() {
        XCTAssertEqual(CoachDayFrame.weekday(noon, timeZone: berlin), "Tuesday")
        XCTAssertTrue(CoachDayFrame.block(now: noon, timeZone: berlin).contains("a Tuesday"))
    }

    /// Today is called incomplete. Without this the model presents a half-finished day's effort as the
    /// day's total and then tells the wearer they are short.
    func testTodayIsStatedToBeIncomplete() {
        let s = CoachDayFrame.block(now: noon, timeZone: berlin)
        XCTAssertTrue(s.contains("INCOMPLETE"), s)
        XCTAssertTrue(s.lowercased().contains("so far"), s)
    }

    /// THE CORE OF THE REPORT. Charge must be stated as a property of one morning that says nothing about a
    /// later day, and the future rule must forbid restating it.
    func testChargeIsBoundToOneMorningAndMayNotBeCarriedForward() {
        let rules = CoachDayFrame.validityRules
        XCTAssertTrue(rules.contains("Charge / recovery: the state of ONE MORNING"), rules)
        XCTAssertTrue(rules.contains("NOTHING about any later day"), rules)
        let future = CoachDayFrame.futureRule
        XCTAssertTrue(future.contains("Never restate today's charge"), future)
        XCTAssertTrue(future.lowercased().contains("cannot be known"), future)
    }

    /// Each KIND of figure gets its validity stated, not just charge: effort is cumulative for its day, the
    /// sleep figures belong to the night that ENDED on that date, and the level is frozen in the morning.
    func testEveryKindOfFigureCarriesItsValidity() {
        let rules = CoachDayFrame.validityRules
        XCTAssertTrue(rules.contains("CUMULATIVE for its named day"), rules)
        XCTAssertTrue(rules.contains("NIGHT THAT ENDED"), rules)
        XCTAssertTrue(rules.contains("FROZEN on the morning"), rules)
        XCTAssertTrue(rules.contains("TOMORROW's level"), rules)
    }

    /// A dash is not a zero. The repo's own most-violated rule, restated where the model reads the table.
    func testADashIsSaidToMeanNotMeasured() {
        XCTAssertTrue(CoachDayFrame.validityRules.contains("NOT MEASURED"))
        XCTAssertTrue(CoachDayFrame.validityRules.contains("never means zero"))
    }

    /// The closing rule is the same frame again where recency makes it stick — the top of a long context is
    /// the part a model loses first.
    func testTheClosingRuleAsksForTheDateOfEveryFigureCited() {
        let closing = CoachDayFrame.closingRule
        XCTAssertTrue(closing.contains("name the DATE of every figure"), closing)
        XCTAssertTrue(closing.contains("has not happened yet"), closing)
        XCTAssertTrue(closing.contains("cannot be known yet"), closing)
    }

    /// DAY ARITHMETIC IN THE CALENDAR, not by adding 86,400 seconds. On the two DST mornings a day is 23 or
    /// 25 hours long, and a seconds-offset "yesterday" lands on today or the day before. 2026-10-25 is the
    /// European autumn change; 03:00 local that morning is 25 hours after 02:00 on the 24th.
    func testYesterdayIsCorrectAcrossADaylightSavingBoundary() {
        // 2026-10-25 03:00 Berlin (CET, UTC+1 after the change) = 2026-10-25T02:00Z.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 25; comps.hour = 3
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        let morningAfterTheChange = cal.date(from: comps)!
        let s = CoachDayFrame.block(now: morningAfterTheChange, timeZone: berlin)
        XCTAssertTrue(s.contains("TODAY is 2026-10-25"), s)
        XCTAssertTrue(s.contains("YESTERDAY was 2026-10-24"), s)
        XCTAssertTrue(s.contains("TOMORROW is 2026-10-26"), s)
    }
}
