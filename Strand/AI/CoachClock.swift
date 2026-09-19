import Foundation

// CoachClock.swift — the moment a coach request is asked in.
//
// A model has no clock. Without one it plans a morning run at nine in the evening, calls a Saturday
// "the start of the week" and suggests a lunchtime walk into a forecast downpour. So every request —
// the chat, the brief, the rituals, the mission, the quest names — carries the weekday, the local date
// and time, and today's forecast. See `AICoachEngine.requestSystemPrompt` for where it is attached.
//
// NOT BIOMETRIC DATA. The date, the time and the weather are the same for everyone in Frankfurt, so
// they go out whether or not the wearer granted data access.
//
// PURE. `now` and the time zone are arguments, so the lines are testable without a clock.

enum CoachClock {

    /// "NOW: Friday, 18 September 2026, 14:32 (local time, Europe/Berlin)."
    ///
    /// ENGLISH WEEKDAY AND MONTH whatever the device language — the prompt is English and a model is
    /// better at "Friday" than at "Freitag" mid-sentence — and a 24-hour clock, which cannot be misread.
    static func promptLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        return "NOW: \(f.string(from: now)) (local time, \(timeZone.identifier))."
    }

    /// The local calendar day of `now`, "yyyy-MM-dd" — the form Open-Meteo labels its forecast day with.
    static func dayKey(_ now: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }

    /// How old a current-conditions reading may be and still be called "now". Past it, the forecast
    /// speaks for the sky and the old reading is left out rather than stated as the present.
    static let currentWeatherMaxAge: TimeInterval = 3 * 60 * 60

    /// What the model is told to do with the block.
    static let instruction = """
    Use this moment: say "this morning", "tonight" or "tomorrow" by this clock and weekday, and never \
    plan for a part of today that has already passed. Place outdoor suggestions in the dry hours and in \
    daylight between sunrise and sunset; if rain is likeliest in a window, plan around it. If there is \
    no forecast line, say nothing about the weather rather than guessing.
    """

    /// The block appended to the system prompt of every request.
    ///
    /// A FORECAST FOR ANOTHER DAY IS DROPPED — yesterday's outlook, read from the cache just after
    /// midnight, would be stated as today's. So is a current reading older than `currentWeatherMaxAge`.
    static func situationBlock(now: Date = Date(), timeZone: TimeZone = .current,
                               weather: WeatherNow?, forecast: WeatherToday?) -> String {
        var lines = ["THE MOMENT (sent with every request):", promptLine(now: now, timeZone: timeZone)]
        if let weather, now.timeIntervalSince(weather.fetchedAt) < currentWeatherMaxAge {
            lines.append(weather.promptLine)
        }
        if let forecast, forecast.day == dayKey(now, timeZone: timeZone) {
            lines.append(forecast.promptLine)
        }
        lines.append(instruction)
        return lines.joined(separator: "\n")
    }
}
