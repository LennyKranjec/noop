import Foundation
import StrandAnalytics
import WhoopStore

// CaffeineDailySummary.swift — caffeine history that outlives the 48-hour intake log.
//
// HEALTH_V2 §S1-A.8. `CaffeineLogStore` keeps intakes for 48 hours only (enough for the active-caffeine
// estimate), so no caffeine history existed to analyse. This writes one small daily summary into the
// metric series whenever the intakes change:
//
//   `caffeine_last_min`  minutes after local midnight of the day's LAST intake. An intake before 04:00 is
//                        the previous evening's (00:30 → 1470 on the previous day), so "last intake of day D"
//                        means the last one before that night's sleep (`HabitNightKey.caffeineDay`).
//   `caffeine_mg_day`    the day's total mg — written ONLY when every intake that day carried mg, so an
//                        unknown dose is never summed as zero.
//
// Source `noop-habits`. A day with no intake logged gets NO row: "no coffee" and "didn't log" look the same,
// so the habit model treats that day as absent (`HabitRules.lateCaffeine`).
//
// ONLY COMPLETE DAYS ARE (RE)WRITTEN: the current summary day and the one before it. The intake list is
// pruned to 48 h on load, so an older day may be only partly present; rewriting it would under-report. Those
// two days always fall wholly inside the retained window (their 04:00 start is at most 45 h ago).

@MainActor
enum CaffeineDailySummary {

    static let source = "noop-habits"
    static let lastMinuteKey = "caffeine_last_min"
    static let mgKey = "caffeine_mg_day"

    /// One summary day.
    struct Day: Equatable {
        let day: String
        let lastMinute: Int
        /// Nil unless every intake that day carried mg.
        let totalMg: Double?
    }

    /// The repository to write through, attached by `HealthV2Refresh` once the app model exists.
    static weak var repo: Repository?
    /// Intakes that changed before a repository was attached; flushed on attach.
    private static var pending: [CaffeineIntake]?

    /// Pure: the per-day summaries of `intakes`, keyed by the summary day.
    nonisolated static func summarise(_ intakes: [CaffeineIntake], calendar: Calendar = .current) -> [String: Day] {
        var byDay: [String: (last: Int, mg: Double, allMg: Bool)] = [:]
        for intake in intakes {
            let comps = calendar.dateComponents([.hour, .minute], from: intake.at)
            let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            let localDay = Repository.localDayKey(intake.at)
            guard let s = HabitNightKey.caffeineDay(localDay: localDay, localMinute: minute) else { continue }
            var cur = byDay[s.day] ?? (last: -1, mg: 0, allMg: true)
            cur.last = Swift.max(cur.last, s.minute)
            if let mg = intake.mg, mg.isFinite, mg > 0 { cur.mg += mg } else { cur.allMg = false }
            byDay[s.day] = cur
        }
        var out: [String: Day] = [:]
        for (day, v) in byDay where v.last >= 0 {
            out[day] = Day(day: day, lastMinute: v.last, totalMg: v.allMg ? v.mg : nil)
        }
        return out
    }

    /// The summary days that are complete in a 48-hour list at `now`: the current one and the one before.
    nonisolated static func completeDays(now: Date, calendar: Calendar = .current) -> [String] {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard let today = HabitNightKey.caffeineDay(localDay: Repository.localDayKey(now), localMinute: minute)?.day,
              let yesterday = HabitDay.adding(-1, to: today) else { return [] }
        return [yesterday, today]
    }

    /// Hook target: `CaffeineLogStore.intakes` changed. Cheap; the write happens asynchronously.
    static func intakesChanged(_ intakes: [CaffeineIntake]) {
        guard let repo else {
            pending = intakes
            return
        }
        Task { await record(intakes, repo: repo) }
    }

    /// Called by `HealthV2Refresh` once it has a repository.
    static func attach(_ repository: Repository) {
        repo = repository
        let p = pending ?? CaffeineLogStore.shared.intakes
        pending = nil
        Task { await record(p, repo: repository) }
    }

    /// Write (or clear) the complete days' summaries.
    static func record(_ intakes: [CaffeineIntake], repo: Repository, now: Date = Date()) async {
        guard let store = await repo.storeHandle() else { return }
        let summaries = summarise(intakes)
        for day in completeDays(now: now) {
            if let s = summaries[day] {
                var points = [MetricPoint(day: day, key: lastMinuteKey, value: Double(s.lastMinute))]
                if let mg = s.totalMg { points.append(MetricPoint(day: day, key: mgKey, value: mg)) }
                _ = try? await store.upsertMetricSeries(points, deviceId: source)
                if s.totalMg == nil {
                    _ = try? await store.deleteMetricSeriesPoint(deviceId: source, day: day, key: mgKey)
                }
            } else {
                // Every intake of a complete day was removed: the day is absent again, not "no caffeine".
                _ = try? await store.deleteMetricSeriesPoint(deviceId: source, day: day, key: lastMinuteKey)
                _ = try? await store.deleteMetricSeriesPoint(deviceId: source, day: day, key: mgKey)
            }
        }
    }
}
