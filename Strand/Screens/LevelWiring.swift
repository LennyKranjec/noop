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
struct LevelPoint: Equatable, Sendable {
    let day: String
    let level: Double
}

/// Every per-day series the level needs, read once over a whole span.
struct LevelSeries {
    /// Stress 0–100 by day.
    let stress: [String: Double]
    /// VO2max estimates by day, oldest first; the newest at-or-before a day wins.
    let vo2max: [(day: String, value: Double)]
    /// Total muscle volume load by day, summed across groups.
    let muscleByDay: [String: Double]
    /// Minutes meditated by day.
    let meditation: [String: Double]

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
        // Oldest first, matching the Android lane: the engine reads the LAST three.
        return out.sorted { $0.daysAgo > $1.daysAgo }
    }

    /// Days with a meditation in the three ending `asOf`.
    func meditationDays(asOf: String, calendar: Calendar) -> Int {
        guard let asOfDate = LevelWiring.date(from: asOf, calendar: calendar) else { return 0 }
        var count = 0
        for back in 0..<3 {
            guard let date = calendar.date(byAdding: .day, value: -back, to: asOfDate) else { continue }
            if (meditation[LevelWiring.key(from: date, calendar: calendar)] ?? 0) > 0 { count += 1 }
        }
        return count
    }

    /// The three stress readings ending `asOf`, oldest first.
    func stressWindow(asOf: String, calendar: Calendar) -> [Double] {
        guard let asOfDate = LevelWiring.date(from: asOf, calendar: calendar) else { return [] }
        var out: [Double] = []
        for back in stride(from: 2, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: asOfDate) else { continue }
            if let v = stress[LevelWiring.key(from: date, calendar: calendar)] { out.append(v) }
        }
        return out
    }
}

enum LevelWiring {

    /// The stress series is stored 0–3 (WHOOP's own scale); the formula wants 0–100.
    static let stressSeriesMax: Double = 3

    /// The window the muscle term reads sessions from.
    static let muscleWindowDays = 7

    /// How many nights the sleep-consistency figure is measured over.
    static let consistencyWindowNights = 28

    /// Build the engine's inputs as of `asOf`, from prefetched series.
    ///
    /// `days` is the merged daily history, oldest first. Passing it in rather than reading it here lets
    /// one read serve today, three days ago and a month ago.
    static func inputs(
        days: [DailyMetric],
        asOf: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        let upTo = days.filter { $0.day <= asOf }
        let window = Array(upTo.suffix(3))

        // Sleep consistency needs a longer run than the three days it is averaged over: it IS the
        // spread of the last few weeks, so it is computed per day from the 28 nights before it.
        var consistency: [Double] = []
        for day in window {
            guard let idx = upTo.firstIndex(where: { $0.day == day.day }) else { continue }
            let from = Swift.max(0, idx - (consistencyWindowNights - 1))
            let nights = upTo[from...idx].compactMap { $0.totalSleepMin.map { $0 / 60 } }
            if let c = VitalityEngine.sleepConsistency(nightlyHours: nights) {
                consistency.append(c * 100)
            }
        }

        let today = upTo.last
        return LevelInputs(
            sleepScores: window.compactMap { AnalyticsEngine.Rest.composite(daily: $0) },
            consistencyScores: consistency,
            hrv: today?.avgHrv,
            rhr: today?.restingHr.map(Double.init),
            vo2max: series.vo2maxAsOf(asOf),
            respRate: today?.respRateBpm,
            muscleSessions: series.muscleSessions(asOf: asOf, windowDays: muscleWindowDays, calendar: calendar),
            stressScores: series.stressWindow(asOf: asOf, calendar: calendar),
            meditationDays: series.meditationDays(asOf: asOf, calendar: calendar),
            stepsToday: today?.steps
        )
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

    /// The whole-history readings each baseline is derived from, ONCE.
    ///
    /// Everything available is used: the wider the history, the better the permanent yardstick.
    static func baselineHistory(
        days: [DailyMetric],
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> [LevelMetric: [Double]] {
        var consistencyRun: [Double] = []
        for i in days.indices {
            let from = Swift.max(0, i - (consistencyWindowNights - 1))
            let run = days[from...i].compactMap { $0.totalSleepMin.map { $0 / 60 } }
            if let c = VitalityEngine.sleepConsistency(nightlyHours: run) {
                consistencyRun.append(c * 100)
            }
        }
        return [
            .sleepScore: days.compactMap { AnalyticsEngine.Rest.composite(daily: $0) },
            .sleepConsistency: consistencyRun,
            .hrv: days.compactMap(\.avgHrv),
            .rhr: days.compactMap { $0.restingHr.map(Double.init) },
            .vo2max: series.vo2max.map(\.value),
            .respRate: days.compactMap(\.respRateBpm),
            .muscleLoad: Array(series.muscleByDay.values),
            .stress: Array(series.stress.values),
        ]
    }
}
