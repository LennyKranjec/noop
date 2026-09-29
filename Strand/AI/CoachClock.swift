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

// MARK: - Which day each figure belongs to

/// The frame every figure in the data context is read in: which day is today, and what each KIND of number
/// is a property of.
///
/// THE BUG THIS EXISTS FOR. The context lists dated rows — `2026-09-29: charge 62, effort 41, rest 7.2h` —
/// and nothing anywhere said what those dates MEANT. So a model asked "what is due tomorrow" answered with
/// today's charge: nothing told it that a charge is a property of one specific morning, that today's row is
/// still incomplete, or that for tomorrow there is no charge at all yet. A model has no clock (which
/// `CoachClock` fixes) and it also has no idea of the temporal validity of a physiological figure, which is
/// what this fixes.
///
/// PURE. `now` and the time zone are arguments; every line is derived from them, so the block is testable
/// without a clock and without a store.
enum CoachDayFrame {

    /// "2026-09-29" in the wearer's own zone, the same spelling every day key in the app uses.
    static func key(_ date: Date, timeZone: TimeZone = .current) -> String {
        CoachClock.dayKey(date, timeZone: timeZone)
    }

    /// The English weekday of `date`, whatever the device language — the prompt is English.
    static func weekday(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    /// What each kind of figure is a property of. Stated once, as rules rather than as examples, so a
    /// figure the block below does not happen to mention is still read correctly.
    static let validityRules = """
    WHAT EACH FIGURE IS A PROPERTY OF (every number below carries a date; read it by these rules):
    - Charge / recovery: the state of ONE MORNING — the morning of its date, computed from the night that \
    ended then. It expires with that day. It says NOTHING about any later day.
    - Effort / strain: CUMULATIVE for its named day, local midnight to local midnight. For today it is \
    "so far", not a final figure.
    - Rest / sleep hours, sleep stages, sleep efficiency, night HRV, night resting HR: the NIGHT THAT \
    ENDED on the morning of its date.
    - Steps, water, meditation minutes, stress: totals for the named day — complete for a past day, \
    "so far" for today.
    - The level and its parts: FROZEN on the morning of its date from the night before and the previous \
    full day's activity. What they do today shows up in TOMORROW's level.
    - Workouts, sessions and journal entries: the day they were recorded on.
    - A dash (—) means NOT MEASURED. It never means zero, and never means "bad".
    """

    /// The rule for a question about a day that has not happened yet.
    static let futureRule = """
    A QUESTION ABOUT A FUTURE DAY. Nothing is measured for tomorrow or any later day: there is no charge, \
    no recovery, no sleep score, no effort and no level for it, and today's figures do NOT carry over. \
    Never restate today's charge, recovery or effort as if it applied to another day. Answer from trends \
    over the recent days, from their plan and routines, and from the schedule — and say plainly which \
    parts cannot be known yet (for example: what tomorrow's charge will be depends on tonight's sleep, \
    which has not happened).
    """

    /// The last line of the data context, just before the question.
    ///
    /// The frame at the top of a long context is the part a model is most likely to lose; this is the same
    /// rule again where recency makes it stick, and it is deliberately three sentences rather than a repeat
    /// of the whole block.
    static let closingRule = """
    BEFORE YOU ANSWER: name the DATE of every figure you cite ("your charge on the morning of <date>"), \
    never a bare "today" for a row that is not today's. If the question is about a day that has not \
    happened yet, do not restate today's figures for it — reason from the trends and the plan, and say \
    which parts cannot be known yet.
    """

    /// The block prepended to the data context.
    ///
    /// Named days rather than the words "today" and "yesterday" alone: the rows are labelled with dates, so
    /// the mapping has to be spelled out or the model has to infer it — and inferring it is what it got
    /// wrong.
    static func block(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let day = 86_400.0
        let today = key(now, timeZone: timeZone)
        // Day arithmetic in the LOCAL calendar, not by adding 86,400 s: a DST boundary makes a day 23 or 25
        // hours long, and on those two mornings a seconds-offset "yesterday" is today or the day before.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let yesterdayDate = cal.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-day)
        let tomorrowDate = cal.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(day)
        var s = "THE DAYS. TODAY is \(today), a \(weekday(now, timeZone: timeZone)). "
        s += "YESTERDAY was \(key(yesterdayDate, timeZone: timeZone)) (\(weekday(yesterdayDate, timeZone: timeZone))). "
        s += "TOMORROW is \(key(tomorrowDate, timeZone: timeZone)) (\(weekday(tomorrowDate, timeZone: timeZone))). "
        s += "Today (\(today)) is still INCOMPLETE — every figure for it is \"so far\".\n\n"
        s += validityRules + "\n\n" + futureRule
        return s
    }
}
