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

    /// The contrast that makes the UTC formatter load-bearing rather than decorative: rendering the SAME
    /// instant in a western zone genuinely names the previous day, so a scrub callout built on the device's
    /// own zone would tell a Los Angeles reader their Friday HRV was Thursday's. `dayKeyDateString` carries
    /// its own UTC zone, so the callout is correct in every zone the device can be in.
    func testAWesternZoneWouldNameThePreviousDayWhichIsWhyTheLabelIsFormattedInUTC() {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US")
        local.timeZone = TimeZone(identifier: "America/Los_Angeles")
        local.setLocalizedDateFormatFromTemplate("EEE d MMM")
        let westward = local.string(from: friday18Sep)
        XCTAssertTrue(westward.contains("17"), westward)   // the zone really does shift the day
        XCTAssertNotEqual(westward, TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_US")))
        XCTAssertTrue(TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_US")).contains("18"))
    }

    /// An eastern zone shifts nothing for a UTC-midnight point, but the label must still be the day key's
    /// own day — the same one, from the same formatter, with no zone-dependent branch anywhere.
    func testLabelIsStableAcrossRepeatedCallsAndLocales() {
        let a = TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_GB"))
        let b = TrendChart.dayKeyDateString(friday18Sep, locale: Locale(identifier: "en_GB"))
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains("18"), a)
        XCTAssertTrue(a.contains("Fri"), a)
    }
}
