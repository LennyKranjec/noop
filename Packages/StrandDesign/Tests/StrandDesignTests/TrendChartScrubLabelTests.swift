import XCTest
@testable import StrandDesign

/// The scrub callout's date on statistics charts, whose points are "yyyy-MM-dd" day keys parsed at UTC
/// midnight. The label must name the weekday and stay on the point's own day in every time zone.
final class TrendChartScrubLabelTests: XCTestCase {

    /// 2026-09-18 00:00 UTC — a Friday.
    private let friday18Sep: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 18
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    func testGermanLabelCarriesWeekdayDayAndMonth() {
        let s = TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(s.contains("Fr"), s)
        XCTAssertTrue(s.contains("18"), s)
        XCTAssertTrue(s.contains("Sep"), s)
    }

    func testEnglishLabelCarriesWeekdayDayAndMonth() {
        let s = TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(s.contains("Fri"), s)
        XCTAssertTrue(s.contains("18"), s)
        XCTAssertTrue(s.contains("Sep"), s)
    }

    /// Formatted in UTC, so a UTC-midnight point never slips to the previous day (Thursday the 17th), which
    /// the local-zone default does anywhere west of Greenwich.
    func testLabelIsTheDayKeysOwnDayRegardlessOfZone() {
        let s = TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_US"))
        XCTAssertFalse(s.contains("17"), s)
        XCTAssertFalse(s.contains("Thu"), s)
    }

    func testDefaultLocaleOverloadIsNonEmpty() {
        XCTAssertFalse(TrendChart.dayKeyDateString(friday18Sep).isEmpty)
    }
}
