import Foundation
import StrandAnalytics
import WhoopStore

// BedroomNightSummary.swift — the bedroom's temperature and humidity over the first 90 minutes of each night.
//
// HEALTH_V2 §S1-A.8. `ClimateHistory` keeps 14 days of 5-minute readings, not keyed to nights and never
// related to sleep. After a night is scored this writes, keyed by the WAKE day (the night key):
//
//   `bedroom_temp_sleep90`  mean °C over [onset, onset + 90 min)
//   `bedroom_rh_sleep90`    mean %RH over the same window
//
// Source `noop-habits`. NOTHING is written below 60 % slot coverage (fewer than 11 of the 18 five-minute
// slots holding a reading): a mean over a few stray points is not the night's room. Existing rows are never
// rewritten, so a night's value is fixed once it has been computed from the full window.

@MainActor
enum BedroomNightSummary {

    static let source = "noop-habits"
    static let tempKey = "bedroom_temp_sleep90"
    static let humidityKey = "bedroom_rh_sleep90"
    static let windowMinutes = 90
    static let slotMinutes = 5

    /// The window's means, or nil below the coverage floor.
    struct Night: Equatable {
        let meanC: Double
        let meanRH: Double
        let coverage: Double
    }

    /// Pure: summarise `points` over the 90 minutes after `onset`.
    nonisolated static func summarise(points: [(at: Date, temperatureC: Double, humidityPct: Double)],
                                      onset: Date) -> Night? {
        let slots = windowMinutes / slotMinutes
        let end = onset.addingTimeInterval(Double(windowMinutes) * 60)
        var filled = Set<Int>()
        var tSum = 0.0, hSum = 0.0, n = 0
        for p in points where p.at >= onset && p.at < end {
            guard p.temperatureC.isFinite, p.humidityPct.isFinite else { continue }
            let slot = Int(p.at.timeIntervalSince(onset) / Double(slotMinutes * 60))
            filled.insert(Swift.min(slots - 1, Swift.max(0, slot)))
            tSum += p.temperatureC
            hSum += p.humidityPct
            n += 1
        }
        let coverage = Double(filled.count) / Double(slots)
        guard n > 0, coverage >= HabitRules.climateMinCoverage else { return nil }
        return Night(meanC: tSum / Double(n), meanRH: hSum / Double(n), coverage: coverage)
    }

    /// Write every scored night of the retained climate window that has no row yet.
    static func writeIfDue(repo: Repository, timings: [String: SleepTiming], now: Date = Date(),
                           calendar: Calendar = .current) async {
        let history = ClimateHistory.all()
        guard let first = history.first?.at, let store = await repo.storeHandle() else { return }
        let points = history.map { (at: $0.at, temperatureC: $0.temperatureC, humidityPct: $0.humidityPct) }
        let today = Repository.localDayKey(now)
        guard let from = HabitDay.adding(-ClimateHistory.keepDays, to: today) else { return }
        let existing = Set(await repo.series(key: tempKey, source: source, from: from, to: today).map { $0.day })
        var rows: [MetricPoint] = []
        for (wakeDay, timing) in timings where wakeDay >= from && wakeDay <= today && !existing.contains(wakeDay) {
            guard let onset = HabitLedgerSource.onsetDate(wakeDay: wakeDay, timing: timing, calendar: calendar),
                  onset >= first,
                  onset.addingTimeInterval(Double(windowMinutes) * 60) <= now,
                  let night = summarise(points: points, onset: onset) else { continue }
            rows.append(MetricPoint(day: wakeDay, key: tempKey, value: night.meanC))
            rows.append(MetricPoint(day: wakeDay, key: humidityKey, value: night.meanRH))
        }
        guard !rows.isEmpty else { return }
        _ = try? await store.upsertMetricSeries(rows, deviceId: source)
    }
}
