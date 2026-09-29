import Foundation

// WindowVentilationAdvice.swift — when to open the windows, and when to shut them again.
//
// The room has a target for the part of the day it is in (`RoomClimateContext`: 20–22.5 °C to work in,
// 16–19.5 °C to sleep in) and the one lever that costs nothing is the window. Whether the window helps
// is a comparison the wearer cannot make from the tile as it stood: it showed the room's temperature and
// said "1.9 °C too warm for sleep — air it out", without saying whether the air outside was any cooler
// than the air in. At six in the evening in September it usually is not, and at nine it usually is.
//
// SO THIS IS THE CROSSING. The room reading comes from the Govee sensor; the outdoor curve comes from
// the forecast the coach already reads (`WeatherToday.hours` — Open-Meteo hourly, TODAY only). The advice
// is the first moment the outside air moves the room toward its band rather than away from it, and the
// moment after that when it stops doing so.
//
// WHAT THE FORECAST ACTUALLY CARRIES, because everything here is bounded by it:
//   · hourly temperature, weather code and precipitation probability, one point per hour, and (new here)
//     relative humidity and dew point;
//   · for ONE local day — `forecast_days=1`, so the series ends at 23:00 local and there is nothing
//     beyond midnight. After the last hour there is no curve, and after midnight the cached outlook is
//     yesterday's.
// Both limits are abstentions, never extrapolations: `Gap.forecastEnded` and `Gap.forecastIsNotToday`.
//
// THE HOURS ARE LOCAL TO THE FORECAST'S PLACE (Open-Meteo `timezone=auto` at the fixed Frankfurt
// coordinate — see `WeatherService`), and they are read against the DEVICE's calendar here. Those are the
// same zone for the wearer this is built for; a phone taken to another zone would read the curve an hour
// or two off, which is why the advice always states the two temperatures it compared rather than just a
// time.
//
// NOTHING IS INVENTED. No indoor reading, a reading too old to be the room now, no forecast, a forecast
// for another day, a forecast that has run out, or no crossing before it runs out — each is an explicit
// `noRecommendation` with its own reason. A guessed time here would be a number the wearer would open a
// window on.
//
// PURE: `now` and the calendar come in, so every case below is testable without a clock and without a
// network. `WindowAdvicePlan` at the foot is the app-side half that finds the schedule and the cache.

/// What to do with the windows, for the window of the day the room is in.
enum WindowAdvice: Equatable, Sendable {

    /// Open them. `at == nil` means now; `until` is when the air outside stops being able to take the
    /// room to its band, and is nil when the forecast never says it does.
    case open(at: Date?, until: Date?, reason: String, caveat: String?)

    /// Nothing to change — the room is already where this part of the day wants it.
    case settled(reason: String)

    /// No recommendation, and why. Never a time.
    case noRecommendation(Gap)

    /// Why there is nothing to say.
    enum Gap: Equatable, Sendable {
        /// No sensor reading at all.
        case noIndoorReading
        /// A reading older than `WindowVentilation.maxIndoorAge` — not the room now.
        case staleIndoorReading(age: TimeInterval)
        case noForecast
        /// The cached outlook is for another day (read just after midnight, typically).
        case forecastIsNotToday
        /// A forecast with no usable hourly temperatures.
        case forecastHasNoHours
        /// `now` is past the last hour the forecast carries.
        case forecastEnded(last: Date)
        /// The outside air never turns useful before the forecast runs out, at `through`.
        case noCrossing(through: Date)

        /// The line the screen shows in place of an advice.
        func sentence(calendar: Calendar = .current) -> String {
            switch self {
            case .noIndoorReading:
                return "No room reading yet — nothing to compare the air outside with."
            case .staleIndoorReading(let age):
                let minutes = Int((age / 60).rounded())
                return "The last room reading is \(minutes) min old — too old to say what the air outside would do."
            case .noForecast:
                return "No forecast — the outside temperature is unknown, so there is no window advice."
            case .forecastIsNotToday:
                return "The forecast on file is not today's — no window advice until it is refreshed."
            case .forecastHasNoHours:
                return "The forecast carries no hourly temperatures — no window advice."
            case .forecastEnded(let last):
                return "Today's forecast ends at \(WindowVentilation.clock(last, calendar)) — nothing to read past it."
            case .noCrossing(let through):
                return "The air outside never turns useful before the forecast runs out at "
                    + WindowVentilation.clock(through, calendar) + " — no window advice."
            }
        }
    }

    /// True when there is an actual instruction, as opposed to an abstention or "leave it".
    var isActionable: Bool {
        if case .open = self { return true }
        return false
    }

    /// True only when there is nothing to say and something is missing. A `settled` room is NOT this:
    /// "keep them shut" is an answer.
    var isAbstention: Bool {
        if case .noRecommendation = self { return true }
        return false
    }

    /// The line the Today tile and the climate screen show. One sentence, with the clock time AND how
    /// long from now — the tile is read at a glance and "23:10" alone makes the reader do the subtraction.
    func actionLine(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .open(let at, let until, _, _):
            var s: String
            if let at {
                s = "Open the windows at \(WindowVentilation.clock(at, calendar)) "
                    + "(\(WindowVentilation.minutesPhrase(from: now, to: at)))"
            } else {
                s = "Open the windows now"
            }
            if let until {
                s += " — shut them at \(WindowVentilation.clock(until, calendar)) "
                    + "(\(WindowVentilation.minutesPhrase(from: now, to: until)))"
            }
            return s + "."
        case .settled(let reason):
            return reason
        case .noRecommendation(let gap):
            return gap.sentence(calendar: calendar)
        }
    }

    /// The same thing in three or four words, for the chip under Today's date. Nil when there is nothing
    /// worth spending the width on.
    func chipPhrase(now: Date, calendar: Calendar = .current) -> String? {
        guard case .open(let at, let until, _, _) = self else { return nil }
        if let at {
            let mins = Int(at.timeIntervalSince(now) / 60)
            // Under an hour the countdown is the useful half; further out the clock time is.
            return mins > 0 && mins < 60
                ? "Open in \(mins) min"
                : "Open \(WindowVentilation.clock(at, calendar))"
        }
        if let until { return "Open now · shut \(WindowVentilation.clock(until, calendar))" }
        return "Open now"
    }

    /// The reasoning, for the screen that has room for it.
    var reason: String? {
        switch self {
        case .open(_, _, let reason, _): return reason
        case .settled(let reason): return reason
        case .noRecommendation: return nil
        }
    }

    /// A note that does not change the instruction: damp air, or an airing that would overshoot.
    var caveat: String? {
        if case .open(_, _, _, let caveat) = self { return caveat }
        return nil
    }
}

enum WindowVentilation {

    /// How much cooler (or warmer) the air outside has to be before opening the window is worth doing.
    /// Under a degree the exchange is inside the forecast's own error and inside the sensor's.
    static let usefulDeltaC = 1.0

    /// How much damper, in dew point, the air outside may be before a wet or foggy hour stops being a
    /// win. Dew point rather than relative humidity: 90 % at 10 °C outside is DRIER air in absolute terms
    /// than 50 % at 21 °C indoors, and opening the window on it dries the room out rather than damping it.
    static let dampMarginC = 1.0

    /// Minute resolution of a named time. The series is hourly and the crossing is interpolated between
    /// two of its points; a minute-exact figure would state precision the forecast does not have.
    static let timeGranularityMinutes = 5

    /// How old the room reading may be and still be called the room now. Past it the advice abstains:
    /// the sensor is read every ten minutes while the app runs, so an hour and a half means it has not
    /// been heard from.
    static let maxIndoorAge: TimeInterval = 90 * 60

    /// The advice for one room reading against one day's forecast.
    ///
    /// `targets` is the band of the window the room is in — the caller resolves it (`RoomClimatePlan`),
    /// because which window it is is a question about the wearer's night, not about the air.
    static func advise(indoor: ClimateReading?,
                       targets: RoomClimateTargets,
                       forecast: WeatherToday?,
                       now: Date,
                       calendar: Calendar = .current) -> WindowAdvice {
        guard let indoor else { return .noRecommendation(.noIndoorReading) }
        let age = now.timeIntervalSince(indoor.at)
        if age > maxIndoorAge { return .noRecommendation(.staleIndoorReading(age: age)) }

        // The curve, or the reason there is none. Resolved BEFORE the "the room is already there" answer,
        // because that answer does not depend on the forecast — withholding it for want of a weather
        // lookup would be an abstention with nothing missing.
        let (resolved, gap) = resolveSeries(forecast, now: now, calendar: calendar)
        let indoorC = indoor.temperatureC

        // THE ROOM IS ALREADY THERE. Said as a statement about the air too when the air is known, because
        // "nothing to do" and "shut them, you have got it" are different instructions.
        if targets.temp.contains(indoorC) {
            let band = bandText(targets.temp)
            var line = String(format: "%.1f °C in here is inside the %@ band — nothing to air out.",
                              indoorC, band)
            if let resolved, let outNow = value(at: now, in: resolved), outNow < targets.temp.lowerBound {
                line = String(format: "%.1f °C in here is inside the %@ band and it is %.0f °C outside — "
                              + "keep the windows shut to hold it.", indoorC, band, outNow)
            }
            return .settled(reason: line)
        }

        guard let series = resolved, let last = series.last else {
            return .noRecommendation(gap ?? .noForecast)
        }

        let cooling = indoorC > targets.temp.upperBound
        let openThreshold = cooling ? indoorC - usefulDeltaC : indoorC + usefulDeltaC
        // The band edge the incoming air has to stay the right side of for the room to REACH the band.
        let bandEdge = cooling ? targets.temp.upperBound : targets.temp.lowerBound

        // THE FIRST USEFUL MOMENT, skipping the hours where opening would be a trade rather than a win:
        // fog or likely rain carrying air damper than the room's own (see `dampMarginC`).
        let indoorDew = dewPointC(temperatureC: indoorC, relativeHumidityPct: indoor.humidityPct)
        var searchFrom = now
        var openAt: Date?
        var damp = false
        while true {
            guard let candidate = firstCrossing(series: series, from: searchFrom,
                                               threshold: openThreshold, wantBelow: cooling)
            else { break }
            let point = hour(at: candidate, in: series)
            if let point, isATrade(point, indoorDew: indoorDew) {
                // Try again from the next hourly point: this one's air is wet and no drier than the room.
                guard let next = series.first(where: { $0.t > candidate })?.t else { break }
                searchFrom = next
                damp = true
                continue
            }
            openAt = candidate
            if let point, isWet(point) { damp = true }
            break
        }

        guard let open = openAt else { return .noRecommendation(.noCrossing(through: last.t)) }

        // WHEN IT STOPS HELPING. Only when the air is the right side of the band edge at the open moment —
        // otherwise there is nothing to cross back over, and the honest note is that the airing takes the
        // edge off without reaching the band.
        let outdoorAtOpen = value(at: open, in: series) ?? openThreshold
        let reachesBand = cooling ? outdoorAtOpen < bandEdge : outdoorAtOpen > bandEdge
        var until: Date?
        if reachesBand, let next = series.first(where: { $0.t > open })?.t {
            until = firstCrossing(series: series, from: next, threshold: bandEdge, wantBelow: !cooling)
        }

        // Written out rather than as ternaries inside the format call: a `String(format:)` with seven
        // arguments, three of them conditional expressions, is the shape that has blown this project's
        // type-checker budget on CI before.
        let side: String = cooling ? "above" : "below"
        let band: String = bandText(targets.temp)
        let whenWord: String = open <= now ? "right now" : "at " + clock(open, calendar)
        let airWord: String = cooling ? "cooler" : "warmer"
        let verb: String = cooling ? "cools" : "warms"
        let reason = String(
            format: "%.1f °C in here, %@ the %@ band; %.0f °C outside %@ — %@ air %@ the room.",
            indoorC, side, band, outdoorAtOpen, whenWord, airWord, verb)

        var caveat: String?
        if !reachesBand {
            caveat = String(format: "At %.0f °C the air outside takes the edge off but will not bring the "
                            + "room into the %@ band on its own.", outdoorAtOpen, bandText(targets.temp))
        } else if cooling, outdoorAtOpen < targets.temp.lowerBound - 3 {
            caveat = String(format: "It is %.0f °C out — well under the band, so a short airing is enough.",
                            outdoorAtOpen)
        }
        if damp {
            let wet = "Wet or foggy air outside"
            caveat = caveat.map { "\(wet). \($0)" } ?? (wet + " — keep the airing short.")
        }

        return .open(at: open <= now ? nil : open, until: until, reason: reason, caveat: caveat)
    }

    // MARK: - The series

    /// One point on today's outdoor curve: the instant, the temperature, and the forecast hour it came
    /// from (for the rain / fog / dew-point checks).
    typealias Point = (t: Date, c: Double, h: WeatherToday.Hour)

    /// The curve to read, or the reason there is none. Exactly one of the two is non-nil.
    ///
    /// Everything that can be wrong with a cached outlook is decided here, in one place, so the caller's
    /// abstentions and its "nothing to air out" answer cannot disagree about whether a forecast was usable.
    static func resolveSeries(_ forecast: WeatherToday?, now: Date,
                              calendar: Calendar = .current) -> (series: [Point]?, gap: WindowAdvice.Gap?) {
        guard let forecast else { return (nil, .noForecast) }
        guard forecast.day == CoachClock.dayKey(now, timeZone: calendar.timeZone) else {
            return (nil, .forecastIsNotToday)
        }
        let series = hourlySeries(forecast, now: now, calendar: calendar)
        // Two points is the minimum a crossing can be read between; one is a reading, not a curve.
        guard let last = series.last, series.count >= 2 else { return (nil, .forecastHasNoHours) }
        guard now < last.t else { return (nil, .forecastEnded(last: last.t)) }
        return (series, nil)
    }

    /// Today's hourly outdoor temperatures as instants, ascending. An hour with no forecast temperature
    /// is dropped rather than filled — a hole in the curve is a hole, and the interpolation below spans it.
    static func hourlySeries(_ forecast: WeatherToday, now: Date,
                             calendar: Calendar = .current) -> [Point] {
        forecast.hours.compactMap { h -> Point? in
            guard let c = h.temperatureC, (0...23).contains(h.hour),
                  let t = calendar.date(bySettingHour: h.hour, minute: 0, second: 0, of: now)
            else { return nil }
            return (t, c, h)
        }
        .sorted { $0.t < $1.t }
    }

    /// The forecast temperature at `date`, linearly between the two hourly points either side. Nil
    /// outside the series.
    static func value(at date: Date, in series: [Point]) -> Double? {
        guard let first = series.first, let last = series.last, date >= first.t, date <= last.t else {
            return nil
        }
        for i in 1..<series.count {
            let a = series[i - 1], b = series[i]
            guard date <= b.t else { continue }
            let span = b.t.timeIntervalSince(a.t)
            guard span > 0 else { return b.c }
            let frac = date.timeIntervalSince(a.t) / span
            return a.c + (b.c - a.c) * frac
        }
        return last.c
    }

    /// The hourly point `date` falls in — the last one at or before it.
    static func hour(at date: Date, in series: [Point]) -> WeatherToday.Hour? {
        series.last(where: { $0.t <= date })?.h ?? series.first?.h
    }

    /// The first moment at or after `from` when the forecast temperature is at or past `threshold`, taken
    /// linearly between the hourly points and rounded to `timeGranularityMinutes`. Nil when it never is
    /// before the series ends.
    ///
    /// `wantBelow` picks the direction: true for "cool enough", false for "warm enough".
    static func firstCrossing(series: [Point], from: Date,
                              threshold: Double, wantBelow: Bool) -> Date? {
        func meets(_ v: Double) -> Bool { wantBelow ? v <= threshold : v >= threshold }
        if let vNow = value(at: from, in: series), meets(vNow) { return from }
        for i in 1..<max(series.count, 1) {
            let a = series[i - 1], b = series[i]
            guard b.t > from else { continue }
            guard meets(b.c) else { continue }
            let t0 = max(from, a.t)
            let v0 = value(at: t0, in: series) ?? a.c
            let span = b.t.timeIntervalSince(t0)
            if v0 == b.c || span <= 0 { return b.t }
            let frac = min(1, max(0, (threshold - v0) / (b.c - v0)))
            return roundedToGranularity(t0.addingTimeInterval(span * frac))
        }
        return nil
    }

    /// To the nearest `timeGranularityMinutes`, so a named time never claims minute precision. Not named
    /// `round`: a static member of that name shadows Foundation's `round(_:)` inside this type.
    static func roundedToGranularity(_ date: Date) -> Date {
        let step = Double(timeGranularityMinutes * 60)
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 / step).rounded() * step)
    }

    // MARK: - Humidity

    /// Whether an hour is wet enough that the air coming in is worth mentioning.
    static func isWet(_ h: WeatherToday.Hour) -> Bool {
        if let code = h.code, code == 45 || code == 48 { return true }   // WMO fog
        if let chance = h.rainChance, chance >= WeatherToday.likelyRainChance { return true }
        return false
    }

    /// Whether opening on this hour is a trade rather than a win: wet or foggy AND carrying air no drier
    /// than the room's own. Without a dew point from the forecast this is never asserted — a wet hour
    /// alone says nothing about absolute humidity, and it would be dishonest to withhold the advice on it.
    static func isATrade(_ h: WeatherToday.Hour, indoorDew: Double?) -> Bool {
        guard isWet(h), let indoorDew, let outdoorDew = h.dewPointC else { return false }
        return outdoorDew > indoorDew + dampMarginC
    }

    /// Dew point from temperature and relative humidity — Magnus/Tetens, the form the WMO publishes
    /// (a ≈ 17.62, b ≈ 243.12 °C over water). Nil for a humidity that cannot be one.
    static func dewPointC(temperatureC t: Double, relativeHumidityPct rh: Double) -> Double? {
        guard rh > 0, rh <= 100 else { return nil }
        let a = 17.62, b = 243.12
        let gamma = log(rh / 100) + (a * t) / (b + t)
        guard a - gamma != 0 else { return nil }
        return b * gamma / (a - gamma)
    }

    // MARK: - Words

    /// "23:10", in the calendar's own zone. Built from components rather than a `DateFormatter` so it is
    /// the same string in every locale and cannot drift to a 12-hour clock on one device.
    static func clock(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "now", "in 40 min", "in 2 h 10 min". The second half of every named time.
    static func minutesPhrase(from: Date, to: Date) -> String {
        let minutes = Int((to.timeIntervalSince(from) / 60).rounded())
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }

    /// "16–19.5 °C", the band written the way the tile writes it.
    static func bandText(_ range: ClosedRange<Double>) -> String {
        func n(_ v: Double) -> String {
            v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.1f", v)
        }
        return "\(n(range.lowerBound))–\(n(range.upperBound)) °C"
    }
}

// MARK: - The app's half

/// The advice for the room as the app knows it: the window of the day from `RoomClimatePlan`, the
/// outdoor curve from the forecast cache the coach already reads.
///
/// Separate from the pure half above for the same reason `RoomClimatePlan` is: this one touches defaults
/// and a cache, and nothing testable belongs on that side of the line.
@MainActor
enum WindowAdvicePlan {

    static func advice(for reading: ClimateReading?, now: Date = Date(),
                       asleepNow: Bool = false, calendar: Calendar = .current) -> WindowAdvice {
        let schedule = RoomClimatePlan.schedule(now: now, calendar: calendar)
        let mode = schedule.mode(at: now, asleepNow: asleepNow, calendar: calendar)
        return WindowVentilation.advise(indoor: reading,
                                       targets: RoomClimateTargets.forMode(mode),
                                       forecast: WeatherService.lastKnownForecast,
                                       now: now,
                                       calendar: calendar)
    }
}
