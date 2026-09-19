import Foundation
@preconcurrency import WhoopStore

// RestComponents.swift — the per-night INPUTS of the Rest composite, as plottable per-day values.
//
// `AnalyticsEngine.Rest.composite` scores a night from four sub-scores: duration against the personal
// need (50%), efficiency (20%), the restorative deep+REM share with its deep-adequacy factor (20%) and
// regularity (10%). The engine computed every one of those on each pass and kept only the weighted sum,
// so a strap-only wearer could see their Rest move without any way to chart WHY — "Hours vs Needed",
// the biggest term, existed in Explore only for a WHOOP CSV import.
//
// These are the SAME quantities the composite reads, from the same `DailyMetric` fields and the same
// need/regularity the pass scored with, so a charted component can never disagree with the Rest it
// explains. Pure: no store, no defaults, no clock. Nothing here changes a score — the composite does not
// call into this file.

extension AnalyticsEngine.Rest {

    /// The metricSeries keys the components are persisted under (the computed "-noop" source) and read
    /// back through Explore. They are the SAME keys the WHOOP export importer writes, on purpose: an
    /// imported figure outranks the computed one per day in `exploreSeries`, exactly as for every other
    /// metric, so an import user's history is unchanged and a strap-only user's gap is filled.
    public enum ComponentKey {
        /// Asleep time as a percentage of the personal need (the composite's duration term, unclamped).
        public static let hoursVsNeededPct = "hours_vs_needed_pct"
        /// The personal sleep need (minutes) the night was scored against.
        public static let sleepNeedMin = "sleep_need_min"
        /// The regularity (0–100) the night was scored with. Pass-wide, like the composite's own input.
        public static let consistencyPct = "sleep_consistency"
        /// (deep + REM) / asleep, in percent.
        public static let restorativePct = "restorative_pct"
        /// deep + REM, in minutes.
        public static let restorativeMin = "restorative_min"
        /// deep / asleep, in percent — what the composite's deep-adequacy factor reads.
        public static let deepPct = "sleep_deep_pct"

        /// Every key `componentPoints` may emit, in emission order.
        public static let persisted: [String] = [
            hoursVsNeededPct, sleepNeedMin, consistencyPct, restorativePct, restorativeMin, deepPct,
        ]
    }

    /// Asleep minutes as a percentage of `needHours`. Unclamped (a long night reads above 100 — the
    /// composite clamps its sub-score, but the chart should show the real ratio). nil without sleep.
    public static func hoursVsNeededPct(asleepMin: Double?, needHours: Double) -> Double? {
        guard let asleep = asleepMin, asleep > 0, needHours > 0, asleep.isFinite, needHours.isFinite else {
            return nil
        }
        return asleep / (needHours * 60.0) * 100.0
    }

    /// deep + REM minutes. Both stages are required: an unstaged night (a total with no split) has no
    /// restorative figure rather than a fabricated zero. nil without sleep.
    public static func restorativeMin(daily d: DailyMetric) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0, let deep = d.deepMin, let rem = d.remMin else {
            return nil
        }
        return deep + rem
    }

    /// (deep + REM) / asleep, in percent. Same staging requirement as `restorativeMin`.
    public static func restorativePct(daily d: DailyMetric) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0, let minutes = restorativeMin(daily: d) else { return nil }
        return minutes / asleep * 100.0
    }

    /// deep / asleep, in percent. nil when the night carries no deep figure.
    public static func deepPct(daily d: DailyMetric) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0, let deep = d.deepMin else { return nil }
        return deep / asleep * 100.0
    }

    /// One component's value for a night, scored with `needHours` / `consistency` (0–1, nil = none).
    /// nil for an unknown key, a night without sleep, or a component the night cannot supply.
    public static func componentValue(key: String, daily d: DailyMetric,
                                      needHours: Double, consistency: Double?) -> Double? {
        guard let asleep = d.totalSleepMin, asleep > 0 else { return nil }
        switch key {
        case ComponentKey.hoursVsNeededPct: return hoursVsNeededPct(asleepMin: asleep, needHours: needHours)
        case ComponentKey.sleepNeedMin:     return needHours > 0 && needHours.isFinite ? needHours * 60.0 : nil
        case ComponentKey.consistencyPct:   return consistency.map { max(0, min(1, $0)) * 100.0 }
        case ComponentKey.restorativePct:   return restorativePct(daily: d)
        case ComponentKey.restorativeMin:   return restorativeMin(daily: d)
        case ComponentKey.deepPct:          return deepPct(daily: d)
        default:                            return nil
        }
    }

    /// The night's component points, in `ComponentKey.persisted` order, for the analysis pass to persist
    /// beside `sleep_performance` with the SAME need/regularity it scored Rest with. Empty without sleep.
    public static func componentPoints(daily d: DailyMetric, needHours: Double,
                                       consistency: Double?) -> [MetricPoint] {
        ComponentKey.persisted.compactMap { key in
            componentValue(key: key, daily: d, needHours: needHours, consistency: consistency)
                .map { MetricPoint(day: d.day, key: key, value: $0) }
        }
    }
}
