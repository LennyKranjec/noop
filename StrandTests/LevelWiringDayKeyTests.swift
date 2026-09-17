import XCTest
import StrandAnalytics
@testable import Strand

/// The level's day arithmetic, which every part of the formula walks hundreds of times.
///
/// It used to build a `DateFormatter` per call, which is what made scoring a year of history block the
/// main thread for seconds. These tests pin the CHEAP implementation to the formatter's own answers, so
/// the speed-up cannot quietly change a single key.
final class LevelWiringDayKeyTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    private func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    func testTheKeyIsTheFormattersOwnAnswerAcrossAYearAndADstChange() {
        let f = formatter(calendar)
        // From a day before Europe's spring change, so the walk crosses both switches.
        var date = calendar.date(from: DateComponents(year: 2026, month: 3, day: 27, hour: 12))!
        for _ in 0..<400 {
            XCTAssertEqual(LevelWiring.key(from: date, calendar: calendar), f.string(from: date))
            date = calendar.date(byAdding: .day, value: 1, to: date)!
        }
    }

    func testAKeyParsesBackToTheSameMidnightTheFormatterGives() {
        let f = formatter(calendar)
        for key in ["2026-01-01", "2026-03-29", "2026-10-25", "2026-12-31"] {
            XCTAssertEqual(LevelWiring.date(from: key, calendar: calendar), f.date(from: key), key)
        }
        XCTAssertNil(LevelWiring.date(from: "not-a-day", calendar: calendar))
        XCTAssertNil(LevelWiring.date(from: "2026-01", calendar: calendar))
    }

    func testAWindowIsTheSameDaysStepBackWouldGive() {
        let keys = LevelWiring.keysBack("2026-03-30", 5, calendar)
        XCTAssertEqual(keys, ["2026-03-30", "2026-03-29", "2026-03-28", "2026-03-27", "2026-03-26"])
        XCTAssertEqual(keys.first, "2026-03-30")
        XCTAssertEqual(LevelWiring.keysBack("2026-03-30", 0, calendar), [])
        XCTAssertEqual(LevelWiring.keysBack("nope", 5, calendar), [])
    }

    func testTheChronicLoadSumsTheTrainingDaysInsideTheWindowAndNothingOlder() throws {
        let tau = LevelEngine.chronicLoadDays
        let gain = 1 - exp(-1 / tau)
        let series = LevelSeries(
            vo2max: [],
            muscleByDay: ["2026-09-16": 100, "2026-09-10": 50, "2026-01-01": 900],
            meditation: [:])
        let load = try XCTUnwrap(LevelWiring.chronicLoad("2026-09-16", series, calendar))
        // Six days apart, and the January session is past the 180-day window.
        XCTAssertEqual(load, 100 * gain + 50 * gain * exp(-6 / tau), accuracy: 1e-9)
        // Nothing lifted on or before the day is no load at all, not zero load.
        XCTAssertNil(LevelWiring.chronicLoad("2025-12-31", series, calendar))
    }
}
