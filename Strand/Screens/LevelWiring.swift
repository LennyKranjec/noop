import Foundation
import StrandAnalytics
import StrandImport
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
    /// VO₂max estimates by day, oldest first; the newest at-or-before a day wins.
    let vo2max: [(day: String, value: Double)]
    /// Total volume load by day, summed across muscle groups — the chronic load is built from it.
    let muscleByDay: [String: Double]
    /// Minutes meditated by day.
    let meditation: [String: Double]
    /// When each night began and ended, keyed by the day it ended on.
    var sleepTimings: [String: SleepTiming] = [:]
    /// Daytime calm (mean RMSSD over the still, scored waking hours) by day.
    var daytimeRmssd: [String: Double] = [:]
    /// The estimated-1RM strength index by day, oldest first.
    var strengthIndex: [(day: String, value: Double)] = []
}

enum LevelWiring {

    /// How far back the chronic load sums, in days. Past ~4 time constants a session contributes nothing.
    static let chronicLookbackDays = 180

    // MARK: - Day arithmetic

    static func shift(_ key: String, _ delta: Int, _ calendar: Calendar) -> String? {
        guard let d = date(from: key, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: delta, to: d) else { return nil }
        return self.key(from: moved, calendar: calendar)
    }

    /// The mean of `value` over the 7 days ending `key`, or nil with fewer than `rollingMinDays` readings.
    static func rolling(_ key: String, _ calendar: Calendar, _ value: (String) -> Double?) -> Double? {
        var xs: [Double] = []
        for k in 0..<LevelEngine.rollingDays {
            guard let d = shift(key, -k, calendar), let v = value(d), v.isFinite else { continue }
            xs.append(v)
        }
        guard xs.count >= LevelEngine.rollingMinDays else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Deep + REM minutes for a night, or nil when the night was not staged.
    static func restorative(_ d: DailyMetric) -> Double? {
        switch (d.deepMin, d.remMin) {
        case let (deep?, rem?): return deep + rem
        default: return nil
        }
    }

    /// Minutes bedtime and wake time moved against the night before (mean of the two ends).
    static func regularity(_ key: String, _ series: LevelSeries, _ calendar: Calendar) -> Double? {
        guard let tonight = series.sleepTimings[key], let prev = shift(key, -1, calendar),
              let lastNight = series.sleepTimings[prev] else { return nil }
        return (Streaks.clockDistance(tonight.onsetMinute, lastNight.onsetMinute)
                + Streaks.clockDistance(tonight.wakeMinute, lastNight.wakeMinute)) / 2
    }

    /// Chronic training load on `key`: Σ load × (1 − e^(−1/τ)) × e^(−days ago / τ). Nil when nothing was
    /// ever lifted on or before the day.
    static func chronicLoad(_ key: String, _ series: LevelSeries, _ calendar: Calendar) -> Double? {
        guard series.muscleByDay.keys.contains(where: { $0 <= key }) else { return nil }
        let tau = LevelEngine.chronicLoadDays
        let gain = 1 - exp(-1 / tau)
        var total = 0.0
        for k in 0..<chronicLookbackDays {
            guard let d = shift(key, -k, calendar), let load = series.muscleByDay[d] else { continue }
            total += load * gain * exp(-Double(k) / tau)
        }
        return total
    }

    /// The newest strength index on or before `key`, while it is still inside its twelve-week window.
    static func strength(_ key: String, _ series: LevelSeries, _ calendar: Calendar) -> Double? {
        guard let last = series.strengthIndex.last(where: { $0.day <= key }),
              let floor = shift(key, -StrengthIndex.windowDays, calendar), last.day > floor
        else { return nil }
        return last.value
    }

    static func meditationShare(_ key: String, _ series: LevelSeries, _ calendar: Calendar) -> Double {
        let flags = (0..<LevelEngine.meditationWindowDays).map { k -> Bool in
            guard let d = shift(key, -k, calendar) else { return false }
            return (series.meditation[d] ?? 0) >= LevelEngine.meditationMinMinutes
        }
        return LevelEngine.meditationShare(meditated: flags)
    }

    // MARK: - Inputs

    static func inputs(
        days: [DailyMetric],
        asOf: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return LevelInputs(
            restorativeMin: rolling(asOf, calendar) { byDay[$0].flatMap(restorative) },
            sleepHrv: rolling(asOf, calendar) { byDay[$0]?.avgHrv },
            regularityMin: rolling(asOf, calendar) { regularity($0, series, calendar) },
            hrv: rolling(asOf, calendar) { byDay[$0]?.avgHrv },
            rhr: rolling(asOf, calendar) { byDay[$0]?.restingHr.map(Double.init) },
            vo2max: series.vo2max.last { $0.day <= asOf }?.value,
            respRate: rolling(asOf, calendar) { byDay[$0]?.respRateBpm },
            strengthIndex: strength(asOf, series, calendar),
            chronicLoad: chronicLoad(asOf, series, calendar),
            daytimeRmssd: rolling(asOf, calendar) { series.daytimeRmssd[$0] },
            meditationShare: meditationShare(asOf, series, calendar),
            steps: rolling(asOf, calendar) { byDay[$0]?.steps.map(Double.init) }.map { Int($0.rounded()) }
        )
    }

    /// Every metric's history AS THE LEVEL READS IT — 7-day means as 7-day means — for the baselines.
    static func baselineHistory(
        days: [DailyMetric],
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> [LevelMetric: [Double]] {
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let keys = days.map(\.day)
        func each(_ f: (String) -> Double?) -> [Double] { keys.compactMap(f) }
        return [
            .restorativeMin: each { k in rolling(k, calendar) { byDay[$0].flatMap(restorative) } },
            .sleepRegularityMin: each { k in rolling(k, calendar) { regularity($0, series, calendar) } },
            .hrv: each { k in rolling(k, calendar) { byDay[$0]?.avgHrv } },
            .rhr: each { k in rolling(k, calendar) { byDay[$0]?.restingHr.map(Double.init) } },
            .vo2max: series.vo2max.map(\.value),
            .respRate: each { k in rolling(k, calendar) { byDay[$0]?.respRateBpm } },
            .strengthIndex: series.strengthIndex.map(\.value),
            .chronicLoad: each { chronicLoad($0, series, calendar) },
            .daytimeRmssd: each { k in rolling(k, calendar) { series.daytimeRmssd[$0] } },
        ]
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
        inputs.steps = previous.steps
        inputs.daytimeRmssd = previous.daytimeRmssd
        inputs.meditationShare = previous.meditationShare
        inputs.chronicLoad = previous.chronicLoad
        inputs.strengthIndex = previous.strengthIndex
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
