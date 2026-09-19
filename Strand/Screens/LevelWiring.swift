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

    /// `count` day keys ending on `key`, newest first.
    ///
    /// PERF: every window in here used to be built by calling `shift` once per day, and each `shift`
    /// parsed the key back into a date and formatted the result again. One day scored walked about five
    /// hundred of those, a year of timeline walked hundreds of thousands, and all of it on the main
    /// actor — which is what made the app stutter and then get killed for not drawing. The window is now
    /// parsed ONCE and stepped, and `key`/`date` no longer build a formatter at all.
    static func keysBack(_ key: String, _ count: Int, _ calendar: Calendar) -> [String] {
        guard count > 0, let base = date(from: key, calendar: calendar) else { return [] }
        var out: [String] = []
        out.reserveCapacity(count)
        for k in 0..<count {
            guard let d = k == 0 ? base : calendar.date(byAdding: .day, value: -k, to: base) else { continue }
            out.append(self.key(from: d, calendar: calendar))
        }
        return out
    }

    /// The mean of `value` over the 7 days ending `key`, or nil with fewer than `rollingMinDays` readings.
    static func rolling(_ key: String, _ calendar: Calendar, _ value: (String) -> Double?) -> Double? {
        rolling(window: keysBack(key, LevelEngine.rollingDays, calendar), value)
    }

    /// The same mean over a window that has already been built — the form every caller that reads more
    /// than one metric for a day uses, so the seven keys are built once rather than once per metric.
    static func rolling(window: [String], _ value: (String) -> Double?) -> Double? {
        var xs: [Double] = []
        for d in window {
            guard let v = value(d), v.isFinite else { continue }
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
        // WALKED OVER THE TRAINING DAYS, not over the window. The sum is the same — every day in the
        // window without a session contributes nothing — but a wearer has tens of sessions in half a
        // year, not a hundred and eighty days of them.
        guard let base = date(from: key, calendar: calendar),
              let floor = calendar.date(byAdding: .day, value: -(chronicLookbackDays - 1), to: base)
        else { return nil }
        let floorKey = self.key(from: floor, calendar: calendar)
        var total = 0.0
        for (day, load) in series.muscleByDay where day <= key && day >= floorKey {
            guard let d = date(from: day, calendar: calendar),
                  let k = calendar.dateComponents([.day], from: d, to: base).day, k >= 0 else { continue }
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
        let window = keysBack(key, LevelEngine.meditationWindowDays, calendar)
        let flags = window.map { (series.meditation[$0] ?? 0) >= LevelEngine.meditationMinMinutes }
        return LevelEngine.meditationShare(meditated: flags)
    }

    // MARK: - Inputs

    static func inputs(
        days: [DailyMetric],
        asOf: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        inputs(byDay: byDay(days), asOf: asOf, series: series, calendar: calendar)
    }

    /// The day rows keyed by day. Built ONCE by a caller that scores more than one day — this used to be
    /// rebuilt inside every `inputs` call, which made a year of timeline quadratic in the history.
    static func byDay(_ days: [DailyMetric]) -> [String: DailyMetric] {
        Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
    }

    static func inputs(
        byDay: [String: DailyMetric],
        asOf: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        // The seven-day window, built once and read by all eight rolling metrics.
        let window = keysBack(asOf, LevelEngine.rollingDays, calendar)
        return LevelInputs(
            restorativeMin: rolling(window: window) { byDay[$0].flatMap(restorative) },
            sleepHrv: rolling(window: window) { byDay[$0]?.avgHrv },
            regularityMin: rolling(window: window) { regularity($0, series, calendar) },
            hrv: rolling(window: window) { byDay[$0]?.avgHrv },
            rhr: rolling(window: window) { byDay[$0]?.restingHr.map(Double.init) },
            vo2max: series.vo2max.last { $0.day <= asOf }?.value,
            respRate: rolling(window: window) { byDay[$0]?.respRateBpm },
            strengthIndex: strength(asOf, series, calendar),
            chronicLoad: chronicLoad(asOf, series, calendar),
            daytimeRmssd: rolling(window: window) { series.daytimeRmssd[$0] },
            meditationShare: meditationShare(asOf, series, calendar),
            steps: rolling(window: window) { byDay[$0]?.steps.map(Double.init) }.map { Int($0.rounded()) }
        )
    }

    /// Every metric's history AS THE LEVEL READS IT — 7-day means as 7-day means — for the baselines.
    static func baselineHistory(
        days: [DailyMetric],
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> [LevelMetric: [Double]] {
        let byDay = byDay(days)
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
        dayInputs(byDay: byDay(days), day: day, series: series, calendar: calendar)
    }

    static func dayInputs(
        byDay: [String: DailyMetric],
        day: String,
        series: LevelSeries,
        calendar: Calendar = .current
    ) -> LevelInputs {
        var inputs = self.inputs(byDay: byDay, asOf: day, series: series, calendar: calendar)
        guard let date = self.date(from: day, calendar: calendar),
              let previousDate = calendar.date(byAdding: .day, value: -1, to: date)
        else { return inputs }
        let previous = self.inputs(byDay: byDay, asOf: key(from: previousDate, calendar: calendar),
                                   series: series, calendar: calendar)
        inputs.steps = previous.steps
        inputs.daytimeRmssd = previous.daytimeRmssd
        inputs.meditationShare = previous.meditationShare
        inputs.chronicLoad = previous.chronicLoad
        inputs.strengthIndex = previous.strengthIndex
        return inputs
    }

    /// `yyyy-MM-dd`, in the calendar's own zone, matching every other day key in the app.
    ///
    /// BUILT FROM COMPONENTS, not by a `DateFormatter`. These two are the hottest functions in the level
    /// by a wide margin, and a formatter is one of the most expensive objects Foundation makes — this
    /// pair used to construct one on every single call. The result is byte-identical: the calendar's own
    /// year / month / day, zero-padded, in its own zone.
    static func key(from date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return pad(c.year ?? 0, 4) + "-" + pad(c.month ?? 0, 2) + "-" + pad(c.day ?? 0, 2)
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c)
    }

    /// Zero-padded decimal, the one piece of a date format this needs.
    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

}
