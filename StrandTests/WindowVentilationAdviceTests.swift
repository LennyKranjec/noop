import XCTest
@testable import Strand

// WindowVentilationAdviceTests.swift — the window advice, pinned.
//
// Everything here runs against a fixed Berlin calendar and a hand-written hourly series, so the crossing
// times are arithmetic rather than weather. What is being pinned is the honesty of the thing: it names a
// time only when the forecast it has actually crosses, and says "no recommendation" — with the reason —
// every other time.
final class WindowVentilationAdviceTests: XCTestCase {

    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = berlin
        return c
    }

    /// 2026-09-18 at `h:m` local.
    private func at(_ h: Int, _ m: Int = 0) -> Date {
        calendar.date(from: DateComponents(timeZone: berlin, year: 2026, month: 9, day: 18,
                                          hour: h, minute: m))!
    }

    private let today = "2026-09-18"

    private func room(_ c: Double, rh: Double = 50, at when: Date) -> ClimateReading {
        ClimateReading(temperatureC: c, humidityPct: rh, battery: 80,
                       deviceName: "Govee H5075", source: "govee-ble", at: when)
    }

    /// A forecast carrying only the hours given, as (hour, °C) — plus optional code / rain / dew point.
    private func forecast(day: String? = nil,
                          _ hours: [(Int, Double)],
                          codes: [Int: Int] = [:],
                          rain: [Int: Int] = [:],
                          dew: [Int: Double] = [:]) -> WeatherToday {
        WeatherToday(
            day: day ?? today, highC: nil, lowC: nil, rainChanceMax: nil, rainSumMm: nil, uvMax: nil,
            sunrise: nil, sunset: nil,
            hours: hours.map { WeatherToday.Hour(hour: $0.0, temperatureC: $0.1, code: codes[$0.0],
                                                 rainChance: rain[$0.0], humidityPct: nil,
                                                 dewPointC: dew[$0.0]) },
            fetchedAt: at(12))
    }

    private func advise(indoor: ClimateReading?, targets: RoomClimateTargets = .sleep,
                        forecast: WeatherToday?, now: Date) -> WindowAdvice {
        WindowVentilation.advise(indoor: indoor, targets: targets, forecast: forecast,
                                 now: now, calendar: calendar)
    }

    // MARK: - A crossing ahead

    /// The evening case the feature exists for: 20 °C in the room against a 16–19.5 °C sleep band, the air
    /// outside dropping through the room's temperature between 19:00 and 20:00 and climbing back through
    /// the band's top between 21:00 and 22:00. Both times are interpolated between the hourly points.
    func testNamesTheOpenAndShutTimesFromTheHourlyCurve() {
        let now = at(19)
        let advice = advise(indoor: room(20.0, at: now),
                            forecast: forecast([(19, 21.0), (20, 17.0), (21, 16.0), (22, 21.0), (23, 22.0)]),
                            now: now)
        guard case .open(let open, let until, let reason, let caveat) = advice else {
            return XCTFail("expected an open instruction, got \(advice)")
        }
        // 21 → 17 over the hour crosses 19.0 (20.0 indoors less the 1.0 useful delta) exactly halfway.
        XCTAssertEqual(open, at(19, 30))
        // 16 → 21 over 21:00–22:00 crosses the band's 19.5 top at 21:42, rounded to the nearest five.
        XCTAssertEqual(until, at(21, 40))
        XCTAssertNil(caveat)
        XCTAssertTrue(reason.contains("20.0 °C in here"))
        XCTAssertTrue(reason.contains("above the 16–19.5 °C band"))
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar),
                       "Open the windows at 19:30 (in 30 min) — shut them at 21:40 (in 2 h 40 min).")
        XCTAssertEqual(advice.chipPhrase(now: now, calendar: calendar), "Open in 30 min")
        XCTAssertTrue(advice.isActionable)
    }

    /// The crossing is already behind us: the air outside is useful right now, so the instruction is "now"
    /// and not a time. And with the air never climbing back to the band's top, there is no shut time —
    /// which is a nil, not a guess.
    func testAlreadyUsefulSaysNowAndWithholdsAShutTimeItCannotSee() {
        let now = at(20)
        let advice = advise(indoor: room(21.0, at: now),
                            forecast: forecast([(20, 15.0), (21, 14.0), (22, 13.5), (23, 13.5)]),
                            now: now)
        guard case .open(let open, let until, _, _) = advice else {
            return XCTFail("expected an open instruction, got \(advice)")
        }
        XCTAssertNil(open, "the air outside is already cooler than the room")
        XCTAssertNil(until, "nothing in today's forecast says when it stops being cooler")
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar), "Open the windows now.")
        XCTAssertEqual(advice.chipPhrase(now: now, calendar: calendar), "Open now")
    }

    /// The mirror: a room below its band in the morning, with the air outside warming past it later.
    func testMorningMirrorOpensWhenTheAirOutsideTurnsWarmer() {
        let now = at(8)
        let advice = advise(indoor: room(18.0, at: now), targets: .focus,
                            forecast: forecast([(8, 12.0), (9, 16.0), (10, 22.0), (11, 24.0)]),
                            now: now)
        guard case .open(let open, _, let reason, _) = advice else {
            return XCTFail("expected an open instruction, got \(advice)")
        }
        // 16 → 22 over 09:00–10:00 crosses 19.0 (18.0 plus the delta) at 09:30.
        XCTAssertEqual(open, at(9, 30))
        XCTAssertTrue(reason.contains("below the 20–22.5 °C band"))
        XCTAssertTrue(reason.contains("warms the room"))
    }

    // MARK: - No crossing, and a curve that runs out

    func testNoCrossingInTheHorizonIsAnExplicitAbstentionNamingWhereItRunsOut() {
        let now = at(18)
        let advice = advise(indoor: room(21.0, at: now),
                            forecast: forecast([(18, 24.0), (19, 25.0), (20, 24.0), (21, 23.0), (22, 23.0),
                                                (23, 23.0)]),
                            now: now)
        XCTAssertEqual(advice, .noRecommendation(.noCrossing(through: at(23))))
        XCTAssertFalse(advice.isActionable)
        XCTAssertTrue(advice.isAbstention)
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar),
                       "The air outside never turns useful before the forecast runs out at 23:00 — "
                       + "no window advice.")
        XCTAssertNil(advice.chipPhrase(now: now, calendar: calendar))
    }

    /// `forecast_days=1`: the series stops at the last hour it carries and there is nothing past it. Asked
    /// after that, the advice says so rather than extrapolating the curve it had.
    func testASeriesThatEndsBeforeNowAbstains() {
        let now = at(23, 30)
        let advice = advise(indoor: room(21.0, at: now),
                            forecast: forecast([(20, 18.0), (21, 17.0), (22, 16.0), (23, 15.0)]),
                            now: now)
        XCTAssertEqual(advice, .noRecommendation(.forecastEnded(last: at(23))))
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar),
                       "Today's forecast ends at 23:00 — nothing to read past it.")
    }

    func testASingleHourIsNotACurve() {
        let now = at(19)
        XCTAssertEqual(advise(indoor: room(21.0, at: now), forecast: forecast([(20, 15.0)]), now: now),
                       .noRecommendation(.forecastHasNoHours))
        // An hour whose temperature the service had no forecast for is dropped, not filled.
        let holes = WeatherToday(day: today, highC: nil, lowC: nil, rainChanceMax: nil, rainSumMm: nil,
                                 uvMax: nil, sunrise: nil, sunset: nil,
                                 hours: [WeatherToday.Hour(hour: 20, temperatureC: nil, code: nil,
                                                           rainChance: nil),
                                         WeatherToday.Hour(hour: 21, temperatureC: nil, code: nil,
                                                           rainChance: nil)],
                                 fetchedAt: at(12))
        XCTAssertEqual(advise(indoor: room(21.0, at: now), forecast: holes, now: now),
                       .noRecommendation(.forecastHasNoHours))
    }

    // MARK: - The other abstentions

    func testAbstainsWithoutAnIndoorReading() {
        let now = at(19)
        XCTAssertEqual(advise(indoor: nil, forecast: forecast([(19, 12.0), (20, 11.0)]), now: now),
                       .noRecommendation(.noIndoorReading))
    }

    func testAbstainsOnAnIndoorReadingTooOldToBeTheRoomNow() {
        let now = at(19)
        let old = room(21.0, at: now.addingTimeInterval(-3 * 3600))
        let advice = advise(indoor: old, forecast: forecast([(19, 12.0), (20, 11.0)]), now: now)
        XCTAssertEqual(advice, .noRecommendation(.staleIndoorReading(age: 3 * 3600)))
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar),
                       "The last room reading is 180 min old — too old to say what the air outside "
                       + "would do.")
    }

    func testAbstainsWithoutAForecastAndOnAForecastForAnotherDay() {
        let now = at(19)
        XCTAssertEqual(advise(indoor: room(21.0, at: now), forecast: nil, now: now),
                       .noRecommendation(.noForecast))
        // Read just after midnight, the cached outlook is yesterday's. It is dropped, never restated.
        XCTAssertEqual(advise(indoor: room(21.0, at: now),
                              forecast: forecast(day: "2026-09-17", [(19, 12.0), (20, 11.0)]), now: now),
                       .noRecommendation(.forecastIsNotToday))
    }

    // MARK: - The room already where it should be

    func testARoomInsideItsBandIsSettledAndSaysToHoldIt() {
        let now = at(22)
        let advice = advise(indoor: room(18.0, at: now),
                            forecast: forecast([(22, 9.0), (23, 8.0)]), now: now)
        XCTAssertFalse(advice.isActionable)
        // A settled room is not an abstention: "keep them shut" is an answer, and the screen must not
        // badge it "NO RECOMMENDATION".
        XCTAssertFalse(advice.isAbstention)
        XCTAssertEqual(advice.actionLine(now: now, calendar: calendar),
                       "18.0 °C in here is inside the 16–19.5 °C band and it is 9 °C outside — "
                       + "keep the windows shut to hold it.")
    }

    /// "The room is fine" needs no weather, so a missing forecast must not turn it into an abstention.
    func testASettledRoomIsAnsweredWithoutAForecast() {
        let now = at(22)
        let advice = advise(indoor: room(18.0, at: now), forecast: nil, now: now)
        XCTAssertEqual(advice, .settled(reason: "18.0 °C in here is inside the 16–19.5 °C band — "
                                        + "nothing to air out."))
    }

    // MARK: - Humidity

    /// A foggy hour carrying air damper than the room's own is not a win: it is skipped, and the advice
    /// lands on the next hour that is. The dew point is what decides it — 90 % outside at 9 °C is drier
    /// air than 50 % at 21 °C in.
    func testAFoggyHourDamperThanTheRoomIsSkipped() {
        let now = at(19)
        let series = forecast([(19, 15.0), (20, 14.0), (21, 13.0)],
                              codes: [19: 45], dew: [19: 14.0, 20: 5.0, 21: 4.0])
        let advice = advise(indoor: room(21.0, rh: 40, at: now), forecast: series, now: now)
        guard case .open(let open, _, _, let caveat) = advice else {
            return XCTFail("expected an open instruction, got \(advice)")
        }
        XCTAssertEqual(open, at(20), "19:00 is fog carrying air damper than the room — skipped")
        XCTAssertEqual(caveat, "Wet or foggy air outside — keep the airing short.")
    }

    /// The same fog with no dew point in the forecast: nothing is asserted about absolute humidity, so the
    /// advice is not withheld. A wet hour alone does not say whether the air is damper than the room's.
    func testFogWithoutADewPointDoesNotWithholdTheAdvice() {
        let now = at(19)
        let series = forecast([(19, 15.0), (20, 14.0), (21, 13.0)], codes: [19: 45])
        let advice = advise(indoor: room(21.0, rh: 40, at: now), forecast: series, now: now)
        guard case .open(let open, _, _, let caveat) = advice else {
            return XCTFail("expected an open instruction, got \(advice)")
        }
        XCTAssertNil(open, "the air outside is already cooler, so the instruction is now")
        XCTAssertEqual(caveat, "Wet or foggy air outside — keep the airing short.")
    }

    func testDewPointIsTheMagnusFormula() {
        // 21 °C at 50 % RH → about 10.2 °C; 21 °C at 40 % → about 6.9 °C. Drier room, lower dew point.
        XCTAssertEqual(WindowVentilation.dewPointC(temperatureC: 21, relativeHumidityPct: 50) ?? 0,
                       10.2, accuracy: 0.15)
        XCTAssertEqual(WindowVentilation.dewPointC(temperatureC: 21, relativeHumidityPct: 40) ?? 0,
                       6.9, accuracy: 0.15)
        XCTAssertNil(WindowVentilation.dewPointC(temperatureC: 21, relativeHumidityPct: 0))
        XCTAssertNil(WindowVentilation.dewPointC(temperatureC: 21, relativeHumidityPct: 140))
    }

    // MARK: - The words

    func testMinutesPhrase() {
        let base = at(19)
        XCTAssertEqual(WindowVentilation.minutesPhrase(from: base, to: base), "now")
        XCTAssertEqual(WindowVentilation.minutesPhrase(from: base, to: base.addingTimeInterval(-600)), "now")
        XCTAssertEqual(WindowVentilation.minutesPhrase(from: base, to: at(19, 40)), "in 40 min")
        XCTAssertEqual(WindowVentilation.minutesPhrase(from: base, to: at(20)), "in 1 h")
        XCTAssertEqual(WindowVentilation.minutesPhrase(from: base, to: at(21, 10)), "in 2 h 10 min")
    }

    /// A 24-hour clock built from calendar components, so the line reads the same in every locale.
    func testClockAndBandText() {
        XCTAssertEqual(WindowVentilation.clock(at(23, 5), calendar), "23:05")
        XCTAssertEqual(WindowVentilation.clock(at(0, 0), calendar), "00:00")
        XCTAssertEqual(WindowVentilation.bandText(16...19.5), "16–19.5 °C")
        XCTAssertEqual(WindowVentilation.bandText(20...22.5), "20–22.5 °C")
    }

    /// Past an hour out, the chip gives the clock time rather than a three-digit countdown.
    func testChipPhraseSwitchesFromCountdownToClock() {
        let now = at(18)
        let advice = WindowAdvice.open(at: at(21, 15), until: nil, reason: "", caveat: nil)
        XCTAssertEqual(advice.chipPhrase(now: now, calendar: calendar), "Open 21:15")
        XCTAssertEqual(WindowAdvice.open(at: nil, until: at(23), reason: "", caveat: nil)
                        .chipPhrase(now: now, calendar: calendar), "Open now · shut 23:00")
    }

    // MARK: - Interpolation

    func testTemperatureIsReadLinearlyBetweenTheHourlyPoints() {
        let now = at(19)
        let series = WindowVentilation.hourlySeries(forecast([(19, 20.0), (20, 16.0)]),
                                                   now: now, calendar: calendar)
        XCTAssertEqual(WindowVentilation.value(at: at(19), in: series) ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(WindowVentilation.value(at: at(19, 15), in: series) ?? 0, 19.0, accuracy: 0.001)
        XCTAssertEqual(WindowVentilation.value(at: at(20), in: series) ?? 0, 16.0, accuracy: 0.001)
        XCTAssertNil(WindowVentilation.value(at: at(21), in: series), "outside the series is no value")
        XCTAssertNil(WindowVentilation.value(at: at(18), in: series))
    }
}
