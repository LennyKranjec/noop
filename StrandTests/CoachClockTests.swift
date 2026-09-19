import XCTest
@testable import Strand

/// The moment every coach request is asked in: the weekday/date/time line, today's forecast line, and
/// the block that carries both. All pure — a fixed Date, a fixed TimeZone, a fixed forecast.
final class CoachClockTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// Friday 18 September 2026, 14:32 in Berlin (12:32 UTC).
    private var fridayAfternoon: Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = berlin
        return cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 14, minute: 32))!
    }

    // MARK: - The clock line

    func testClockLineIsEnglishWeekdayDateAnd24HourTime() {
        XCTAssertEqual(CoachClock.promptLine(now: fridayAfternoon, timeZone: berlin),
                       "NOW: Friday, 18 September 2026, 14:32 (local time, Europe/Berlin).")
    }

    func testClockLineFollowsTheTimeZoneAcrossMidnight() {
        // The same instant is already Saturday in Auckland (UTC+12 before NZ daylight time starts).
        let auckland = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(CoachClock.promptLine(now: fridayAfternoon, timeZone: auckland),
                       "NOW: Saturday, 19 September 2026, 00:32 (local time, Pacific/Auckland).")
        XCTAssertEqual(CoachClock.dayKey(fridayAfternoon, timeZone: auckland), "2026-09-19")
        XCTAssertEqual(CoachClock.dayKey(fridayAfternoon, timeZone: berlin), "2026-09-18")
    }

    // MARK: - The forecast line

    private func hour(_ h: Int, _ temp: Double, _ code: Int, _ rain: Int) -> WeatherToday.Hour {
        WeatherToday.Hour(hour: h, temperatureC: temp, code: code, rainChance: rain)
    }

    /// A dry morning, rain from 16:00 into the evening, clearing late.
    private var wetAfternoon: WeatherToday {
        var hours: [WeatherToday.Hour] = []
        for h in 0..<6 { hours.append(hour(h, 13, 0, 0)) }
        for h in 6..<12 { hours.append(hour(h, 15, 2, 10)) }
        for h in 12..<16 { hours.append(hour(h, 21, 3, 20)) }
        for h in 16..<18 { hours.append(hour(h, 21, 61, 60)) }
        for h in 18..<21 { hours.append(hour(h, 17, 61, 70)) }
        for h in 21..<24 { hours.append(hour(h, 17, 3, 40)) }
        return WeatherToday(day: "2026-09-18", highC: 22, lowC: 13, rainChanceMax: 70, rainSumMm: 4.2,
                            uvMax: 5, sunrise: "07:12", sunset: "19:28", hours: hours,
                            fetchedAt: fridayAfternoon)
    }

    func testForecastLineCarriesRangeWindowsRainWindowDaylightAndUV() {
        XCTAssertEqual(
            wetAfternoon.promptLine,
            "TODAY'S FORECAST (Frankfurt am Main, 2026-09-18): 13–22 °C. "
            + "Morning partly cloudy 15 °C, afternoon rain 21 °C (rain 60%), evening rain 17 °C (rain 70%). "
            + "Rain chance up to 70% (4.2 mm), likeliest 16:00–21:00. "
            + "Sunrise 07:12. Sunset 19:28. UV max 5.")
    }

    func testForecastLineLeavesOutWhatWasNotForecast() {
        let sparse = WeatherToday(day: "2026-09-18", highC: 22, lowC: 13, rainChanceMax: 10, rainSumMm: 0,
                                  uvMax: nil, sunrise: nil, sunset: nil, hours: [], fetchedAt: fridayAfternoon)
        XCTAssertEqual(sparse.promptLine,
                       "TODAY'S FORECAST (Frankfurt am Main, 2026-09-18): 13–22 °C. Dry: rain chance 10%.")
    }

    // MARK: - The block every request carries

    func testSituationBlockCarriesClockForecastAndInstruction() {
        let now = WeatherNow(temperatureC: 20, code: 3, uvIndex: 3, uvPeak: 5,
                             fetchedAt: fridayAfternoon.addingTimeInterval(-10 * 60))
        let block = CoachClock.situationBlock(now: fridayAfternoon, timeZone: berlin,
                                              weather: now, forecast: wetAfternoon)
        XCTAssertTrue(block.contains("NOW: Friday, 18 September 2026, 14:32"))
        XCTAssertTrue(block.contains(now.promptLine))
        XCTAssertTrue(block.contains(wetAfternoon.promptLine))
        XCTAssertTrue(block.contains(CoachClock.instruction))
    }

    func testSituationBlockDropsYesterdaysForecastAndAnOldReading() {
        let old = WeatherNow(temperatureC: 9, code: 0, uvIndex: 0, uvPeak: 5,
                             fetchedAt: fridayAfternoon.addingTimeInterval(-5 * 60 * 60))
        let block = CoachClock.situationBlock(now: fridayAfternoon.addingTimeInterval(24 * 60 * 60),
                                              timeZone: berlin, weather: old, forecast: wetAfternoon)
        XCTAssertTrue(block.contains("NOW: Saturday, 19 September 2026, 14:32"))
        XCTAssertFalse(block.contains("TODAY'S FORECAST"))
        XCTAssertFalse(block.contains("WEATHER"))
    }

    // MARK: - Parsing the Open-Meteo response

    func testParseTodayReadsDailyAndHourlyKeepingNullsInLine() throws {
        let json = """
        {"daily": {"time": ["2026-09-18"], "temperature_2m_max": [22.4], "temperature_2m_min": [13.1],
                   "precipitation_probability_max": [70], "precipitation_sum": [4.2], "uv_index_max": [5.05],
                   "sunrise": ["2026-09-18T07:12"], "sunset": ["2026-09-18T19:28"]},
         "hourly": {"time": ["2026-09-18T00:00", "2026-09-18T01:00"],
                    "temperature_2m": [13.0, null], "weather_code": [0, 3],
                    "precipitation_probability": [null, 20]}}
        """
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let today = try XCTUnwrap(WeatherService.parseToday(root, fetchedAt: fridayAfternoon))
        XCTAssertEqual(today.day, "2026-09-18")
        XCTAssertEqual(today.highC, 22.4)
        XCTAssertEqual(today.lowC, 13.1)
        XCTAssertEqual(today.rainChanceMax, 70)
        XCTAssertEqual(today.rainSumMm, 4.2)
        XCTAssertEqual(today.sunrise, "07:12")
        XCTAssertEqual(today.sunset, "19:28")
        XCTAssertEqual(today.hours, [
            WeatherToday.Hour(hour: 0, temperatureC: 13.0, code: 0, rainChance: nil),
            WeatherToday.Hour(hour: 1, temperatureC: nil, code: 3, rainChance: 20),
        ])
    }

    func testParseTodayIsNilWithoutADailyBlock() {
        XCTAssertNil(WeatherService.parseToday(["current": ["temperature_2m": 20]], fetchedAt: fridayAfternoon))
    }
}
