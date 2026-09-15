import Foundation
import StrandAnalytics
import StrandImport
import SwiftUI
import WhoopStore

// LevelBarModel.swift — what the level strip reads.
//
// The one place the shell asks for a level. It reads the repository's already-loaded days, the four
// series the formula needs, and the frozen baselines, and produces the snapshot the bar renders.
//
// RECOMPUTED WHEN THE DATA MOVES, NOT ON A TIMER. The level moves on the day's data, not on the
// second's, so this is keyed on the repository's own refresh counter — there is nothing to poll.
//
// IT NEVER THROWS AND NEVER BLOCKS THE BAR. Every read is best-effort: a store that is not ready yet
// produces no snapshot, and the strip draws its empty state rather than a zero.

@MainActor
final class LevelBarModel: ObservableObject {

    @Published private(set) var trend: LevelTrendSnapshot?
    /// Every scored day over the span the timeline asked for, oldest first.
    @Published private(set) var history: [LevelPoint] = []
    @Published private(set) var loadingHistory = false

    private var lastLoadedTick: Int = -1

    /// Load today's level and the two comparison points, unless nothing has changed since last time.
    func refresh(repo: Repository, tick: Int) async {
        guard tick != lastLoadedTick else { return }
        lastLoadedTick = tick
        await load(repo: repo)
    }

    /// Force a reload — used when a screen knows the underlying data changed.
    func reload(repo: Repository) async {
        await load(repo: repo)
    }

    private func load(repo: Repository) async {
        let days = repo.days
        guard !days.isEmpty else {
            trend = nil
            return
        }
        let calendar = Calendar.current
        let series = await readSeries(repo: repo)
        let baselines = LevelBaselineStore.resolve {
            LevelWiring.baselineHistory(days: days, series: series, calendar: calendar)
        }

        func level(daysBack: Int) -> LevelBreakdown? {
            guard let date = calendar.date(byAdding: .day, value: -daysBack, to: Date()) else { return nil }
            let key = LevelWiring.key(from: date, calendar: calendar)
            let inputs = LevelWiring.inputs(days: days, asOf: key, series: series, calendar: calendar)
            return LevelEngine.compute(inputs: inputs, baselines: baselines)
        }

        let todayKey = LevelWiring.key(from: Date(), calendar: calendar)
        let todayInputs = LevelWiring.inputs(days: days, asOf: todayKey, series: series, calendar: calendar)
        var drivers: [LevelPart: LevelDriver] = [:]
        for part in LevelPart.allCases {
            if let driver = LevelDrivers.driver(for: part, inputs: todayInputs, baselines: baselines) {
                drivers[part] = driver
            }
        }

        trend = LevelTrendSnapshot(
            now: LevelEngine.compute(inputs: todayInputs, baselines: baselines),
            threeDaysAgo: level(daysBack: 3),
            monthAgo: level(daysBack: 30),
            drivers: drivers
        )
    }

    /// Every scored day over `spanDays`, for the timeline.
    ///
    /// The span is CLAMPED to the data that actually exists: asking for a year when the store holds
    /// three months would run the formula over nine months of certain nulls.
    func loadHistory(repo: Repository, spanDays: Int) async {
        loadingHistory = true
        defer { loadingHistory = false }

        let days = repo.days
        guard !days.isEmpty else {
            history = []
            return
        }
        let calendar = Calendar.current
        let series = await readSeries(repo: repo)
        let baselines = LevelBaselineStore.resolve {
            LevelWiring.baselineHistory(days: days, series: series, calendar: calendar)
        }

        let today = Date()
        let requested = calendar.date(byAdding: .day, value: -(spanDays - 1), to: today) ?? today
        let earliest = days.first.flatMap { LevelWiring.date(from: $0.day, calendar: calendar) }
        var cursor = (earliest.map { Swift.max($0, requested) }) ?? requested

        var out: [LevelPoint] = []
        while cursor <= today {
            let key = LevelWiring.key(from: cursor, calendar: calendar)
            let inputs = LevelWiring.inputs(days: days, asOf: key, series: series, calendar: calendar)
            if let breakdown = LevelEngine.compute(inputs: inputs, baselines: baselines) {
                out.append(LevelPoint(day: key, level: breakdown.level))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        history = out
    }

    /// ONE READ PER SERIES, for the whole span — see the note in `LevelWiring`.
    private func readSeries(repo: Repository) async -> LevelSeries {
        let stressRows = await repo.series(key: "stress", source: "my-whoop", fullHistory: true)
        var stress: [String: Double] = [:]
        for row in stressRows {
            stress[row.day] = Swift.min(Swift.max(row.value / LevelWiring.stressSeriesMax * 100, 0), 100)
        }

        let vo2 = await repo.series(key: "vo2max_est", source: "\(repo.deviceId)-noop", fullHistory: true)
            .sorted { $0.day < $1.day }

        var muscle: [String: Double] = [:]
        for group in MuscleGroup.allCases {
            let rows = await repo.series(key: group.volumeKey, source: "lifting", fullHistory: true)
            for row in rows { muscle[row.day, default: 0] += row.value }
        }

        var meditation: [String: Double] = [:]
        for row in await repo.series(key: MeditationLog.key, source: MeditationLog.source, fullHistory: true) {
            meditation[row.day] = row.value
        }

        return LevelSeries(stress: stress, vo2max: vo2, muscleByDay: muscle, meditation: meditation)
    }
}
