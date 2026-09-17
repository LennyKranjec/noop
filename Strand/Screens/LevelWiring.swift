import Foundation
import StrandAnalytics
import WhoopStore

// LevelWiring.swift — assembling the level's inputs from the store.
//
// SwiftUI-side twin of the Android `LevelRepository`. The engine is pure and knows nothing about where
// a figure came from; this is the half that reads the store, converts each metric into the unit the
// formula expects, and can do it AS OF an earlier day so the trend arrows have something honest to
// compare against.
//
// AS-OF IS REAL, NOT A CACHED NUMBER. Asking for the level three days ago re-runs the formula over the
// data as it stood then, against the SAME frozen baselines. That is the only way a comparison means
// anything: a level from a cache would have been computed against whatever scale existed that day.
//
// ONE READ PER SERIES, NOT ONE PER DAY. Building a day's inputs touches the stress series, the newest
// VO2max, the meditation log and thirteen muscle-group series — about sixteen reads. That is nothing
// for the three days a trend scores and is nearly six thousand for a year of timeline, so the timeline
// prefetches each series once across the whole span and the arithmetic is unchanged.
//
// A MISSING METRIC STAYS MISSING. Every read returns nil rather than a stand-in, because the engine
// redistributes weight around absent components and a zero would be scored as a bad reading.

/// One day's level, for the timeline.
///
/// The PARTS come with it, not as a second series read separately. The expandable breakdown graphs the
/// same five components the level was computed from, and re-deriving them per part would walk the whole
/// history five more times to arrive at numbers this pass already had in hand.
struct LevelPoint: Equatable, Sendable {
    let day: String
    let level: Double
    var parts: [LevelPart: Double] = [:]
}

/// Every per-day series the level needs, read once over a whole span.
struct LevelSeries {
    /// VO2max estimates by day, oldest first; the newest at-or-before a day wins.
    let vo2max: [(day: String, value: Double)]
    /// Total muscle volume load by day, summed across groups.
    let muscleByDay: [String: Double]
    /// Minutes meditated by day.
    let meditation: [String: Double]
    /// When each night began and ended, keyed by the day it ended on.
    var sleepTimings: [String: SleepTiming] = [:]
    /// Daytime calm (mean RMSSD over the still, scored waking hours) by day.
    var daytimeRmssd: [String: Double] = [:]

    /// The newest VO2max at or before `day`, or nil when none was recorded by then.
    func vo2maxAsOf(_ day: String) -> Double? {
        vo2max.last { $0.day <= day }?.value
    }

    /// Muscle sessions in the window ending `asOf`, as (volume, days ago).
    func muscleSessions(asOf: String, windowDays: Int, calendar: Calendar) -> [(load: Double, daysAgo: Int)] {
        guard let asOfDate = LevelWiring.date(from: asOf, calendar: calendar) else { return [] }
        var out: [(load: Double, daysAgo: Int)] = []
        for (day, load) in muscleByDay {
            guard let date = LevelWiring.date(from: day, calendar: calendar) else { continue }
            let ago = calendar.dateComponents([.day], from: date, to: asOfDate).day ?? 0
            guard ago >= 0, ago <= windowDays else { continue }
            out.append((load: load, daysAgo: ago))
        }
        return out.sorted { $0.daysAgo > $1.daysAgo }
    }

    /// Minutes meditated over the UNBROKEN run of consecutive days ending on `asOf`. A day without
    /// meditation ends the run, which is what makes the daily habit the point.
    func meditationStreakMinutes(asOf: String, calendar: Calendar) -> Double {
        guard var cursor = LevelWiring.date(from: asOf, calendar: calendar) else { return 0 }
        var total = 0.0
        for _ in 0..<400 {
            guard let minutes = meditation[LevelWiring.key(from: cursor, calendar: calendar)], minutes > 0
            else { break }
            total += minutes
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return total
    }

    /// How far bedtime and wake time moved against the night before, in minutes (the mean of the two
    /// ends), for the night that ended on `day`. Nil unless both nights have a timing.
    func regularityMinutes(day: String, calendar: Calendar) -> Double? {
        guard let tonight = sleepTimings[day],
              let date = LevelWiring.date(from: day, calendar: calendar),
              let prev = calendar.date(byAdding: .day, value: -1, to: date),
              let lastNight = sleepTimings[LevelWiring.key(from: prev, calendar: calendar)]
        else { return nil }
        return (Streaks.clockDistance(tonight.onsetMinute, lastNight.onsetMinute)
                + Streaks.clockDistance(tonight.wakeMinute, lastNight.wakeMinute)) / 2
    }

    /// The daytime-calm readings of the three days ending `asOf`, oldest first.
    func daytimeRmssdWindow(asOf: String, calendar: Calendar) -> [Double] {
        guard let asOfDate = LevelWiring.date(from: asOf, calendar: calendar) else { return [] }
        var out: [Double] = []
        for back in stride(from: 2, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: asOfDate) else { continue }
            if let v = daytimeRmssd[LevelWiring.key(from: date, calendar: calendar)] { out.append(v) }
        }
        return out
    }
}

enum LevelWiring {

    /// The window the muscle term reads sessions from.
    static let muscleWindowDays = 7

    static func baselineHistory(
        days: [DailyMetric],
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> [LevelMetric: [Double]] {
        [
            .restorativeMin: days.compactMap(restorative),
            .sleepRegularityMin: days.compactMap { series.regularityMinutes(day: $0.day, calendar: calendar) },
            .hrv: days.compactMap(\.avgHrv),
            .rhr: days.compactMap { $0.restingHr.map(Double.init) },
            .vo2max: series.vo2max.map(\.value),
            .respRate: days.compactMap(\.respRateBpm),
            .muscleLoad: Array(series.muscleByDay.values),
            .daytimeRmssd: Array(series.daytimeRmssd.values),
        ]
    }

    /// Deep + REM minutes for a night, or nil when the night was not staged.
    static func restorative(_ d: DailyMetric) -> Double? {
        switch (d.deepMin, d.remMin) {
        case let (deep?, rem?): return deep + rem
        default: return nil
        }
    }

    /// Build the engine's inputs as of `asOf`, from prefetched series.
    static func inputs(
        days: [DailyMetric],
        asOf: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        let upTo = days.filter { $0.day <= asOf }
        let window = Array(upTo.suffix(3))
        let today = upTo.last
        return LevelInputs(
            restorativeMin: window.compactMap(restorative),
            sleepHrv: window.compactMap(\.avgHrv),
            regularityMin: window.compactMap { series.regularityMinutes(day: $0.day, calendar: calendar) },
            hrv: today?.avgHrv,
            rhr: today?.restingHr.map(Double.init),
            vo2max: series.vo2maxAsOf(asOf),
            respRate: today?.respRateBpm,
            muscleSessions: series.muscleSessions(asOf: asOf, windowDays: muscleWindowDays, calendar: calendar),
            daytimeRmssd: series.daytimeRmssdWindow(asOf: asOf, calendar: calendar),
            meditationStreakMin: series.meditationStreakMinutes(asOf: asOf, calendar: calendar),
            stepsToday: today?.steps
        )
    }

    /// The inputs for a day's FROZEN level: the night that ended on `day`, and the activity of the
    /// last complete day before it.
    ///
    /// See `LevelDayFreeze` for why. In short: the level is set at 06:40, when the day's own steps,
    /// stress and training have barely begun, and freezing those partial figures would lock the step
    /// penalty in for the whole day. The night is finished by then and so is yesterday; both are facts
    /// that will not move, which is what lets the number stand until the next morning.
    static func dayInputs(
        days: [DailyMetric],
        day: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        var inputs = self.inputs(days: days, asOf: day, series: series, calendar: calendar)
        guard let date = self.date(from: day, calendar: calendar),
              let previousDate = calendar.date(byAdding: .day, value: -1, to: date)
        else { return inputs }
        let previous = self.inputs(days: days, asOf: key(from: previousDate, calendar: calendar),
                                   series: series, calendar: calendar)
        inputs.stepsToday = previous.stepsToday
        inputs.daytimeRmssd = previous.daytimeRmssd
        inputs.meditationStreakMin = previous.meditationStreakMin
        inputs.muscleSessions = previous.muscleSessions
        return inputs
    }

    /// Whether the night that ended on `day` has arrived — the half of a day's level that comes from
    /// that morning. Until it has, the day cannot be scored and must not be frozen.
    static func nightLanded(days: [DailyMetric], day: String) -> Bool {
        days.contains { $0.day == day && ($0.avgHrv != nil || $0.restingHr != nil || $0.totalSleepMin != nil) }
    }

    /// `yyyy-MM-dd`, in the calendar's own zone, matching every other day key in the app.
    static func key(from date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }

}
