import Foundation
import StrandAnalytics
import WhoopStore

// WizDailyRecord.swift — whether the WiZ wind-down actually dimmed the lights before sleep, per evening.
//
// HEALTH_V2 §S1-A.8. The automation keeps only "last ran" strings, so there was no usage history. This keeps
// a small record and writes, per evening day D (metricSeries `wiz_winddown_ran`, source `noop-habits`):
//
//   1        the wind-down fired on D before that night's onset
//   0        the automation was enabled on D (with bulbs) and had not fired by onset
//   no row   the automation was disabled — the evening is not an observation at all
//
// A day is written once, the morning after (when the night's onset is known), and never rewritten.
// "Enabled on D" is what the app observed on D (any refresh that day); an automation switched on and off
// again between two refreshes is not seen, which can only make a day absent, never a false "no".

@MainActor
enum WizDailyRecord {

    static let source = "noop-habits"
    static let key = "wiz_winddown_ran"
    private static let firedKey = "habits.wiz.firedAt.v1"
    private static let enabledKey = "habits.wiz.enabledDays.v1"
    static let keepDays = 21

    /// Hook target: the wind-down automation fired on `day` at `at`.
    static func markRan(day: String, at: Date = Date(), defaults: UserDefaults = .standard) {
        var fired = defaults.dictionary(forKey: firedKey) as? [String: Double] ?? [:]
        if fired[day] == nil { fired[day] = at.timeIntervalSince1970 }
        defaults.set(prune(fired, today: day), forKey: firedKey)
        noteEnabled(day: day, defaults: defaults)
    }

    /// Record that the automation is enabled (with bulbs) today. Called on every refresh.
    static func noteEnabledState(now: Date = Date(), defaults: UserDefaults = .standard) {
        let store = WizLightStore.shared
        guard store.windDownOn, !store.bulbs.isEmpty else { return }
        noteEnabled(day: Repository.localDayKey(now), defaults: defaults)
    }

    private static func noteEnabled(day: String, defaults: UserDefaults) {
        var days = Set(defaults.stringArray(forKey: enabledKey) ?? [])
        guard !days.contains(day) else { return }
        days.insert(day)
        let floor = HabitDay.adding(-keepDays, to: day) ?? day
        defaults.set(days.filter { $0 >= floor }.sorted(), forKey: enabledKey)
    }

    private static func prune(_ fired: [String: Double], today: String) -> [String: Double] {
        let floor = HabitDay.adding(-keepDays, to: today) ?? today
        return fired.filter { $0.key >= floor }
    }

    /// Pure: the value for evening `day`, or nil for no row.
    nonisolated static func value(enabled: Bool, firedAt: Date?, onset: Date?) -> Double? {
        if let firedAt {
            guard let onset else { return 1 }
            return firedAt <= onset ? 1 : (enabled ? 0 : nil)
        }
        return enabled ? 0 : nil
    }

    /// Write every finished evening of the retained window that has no row yet.
    static func finalise(repo: Repository, timings: [String: SleepTiming], now: Date = Date(),
                         defaults: UserDefaults = .standard, calendar: Calendar = .current) async {
        let today = Repository.localDayKey(now)
        guard let from = HabitDay.adding(-keepDays, to: today), let store = await repo.storeHandle() else { return }
        let fired = defaults.dictionary(forKey: firedKey) as? [String: Double] ?? [:]
        let enabled = Set(defaults.stringArray(forKey: enabledKey) ?? [])
        let existing = Set(await repo.series(key: key, source: source, from: from, to: today).map { $0.day })
        var rows: [MetricPoint] = []
        for day in enabled.union(fired.keys) where day >= from && day < today && !existing.contains(day) {
            guard let wakeDay = HabitDay.adding(1, to: day) else { continue }
            // Wait for the night to be scored (its timing present), unless it is clearly over without one.
            let timing = timings[wakeDay]
            if timing == nil, wakeDay >= today { continue }
            let onset = timing.flatMap { HabitLedgerSource.onsetDate(wakeDay: wakeDay, timing: $0, calendar: calendar) }
            let firedAt = fired[day].map { Date(timeIntervalSince1970: $0) }
            guard let v = value(enabled: enabled.contains(day), firedAt: firedAt, onset: onset) else { continue }
            rows.append(MetricPoint(day: day, key: key, value: v))
        }
        guard !rows.isEmpty else { return }
        _ = try? await store.upsertMetricSeries(rows, deviceId: source)
    }
}
