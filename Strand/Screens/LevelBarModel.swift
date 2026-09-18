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
// ONE LEVEL A DAY. The headline figure is set at 06:40 and held until the next 06:40 — see
// `LevelDayFreeze`. The refresh counter still drives this, because the day has to be scored the first
// time its night arrives, but a refresh after that reads the frozen figure back rather than moving it.
//
// IT NEVER THROWS AND NEVER BLOCKS THE BAR. Every read is best-effort: a store that is not ready yet
// produces no snapshot, and the strip draws its empty state rather than a zero.

@MainActor
final class LevelBarModel: ObservableObject {

    @Published private(set) var trend: LevelTrendSnapshot?
    /// Every scored day over the span the timeline asked for, oldest first.
    @Published private(set) var history: [LevelPoint] = []
    @Published private(set) var loadingHistory = false
    /// The best each part reached over the span the timeline last loaded. Empty until it has.
    @Published private(set) var partBests: [LevelPart: Double] = [:]

    private var lastLoadedTick: Int = -1

    /// The series behind the last load, and the tick they were read at.
    ///
    /// PERF: reading them is a dozen full-history series reads plus the workout log, and `load()` and
    /// `loadHistory` each used to do their own — so opening the timeline read everything twice, and the
    /// strip on another tab a third time. They are the same reads for the same data, so they are kept
    /// until the data behind them changes.
    private var cachedSeries: (key: String, series: LevelSeries)?

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
        let byDay = LevelWiring.byDay(days)
        let baselines = LevelBaselineStore.resolve {
            LevelWiring.baselineHistory(days: days, series: series, calendar: calendar)
        }

        /// A day's level and its drivers, from the same frozen-day inputs.
        func score(_ key: String) -> (LevelBreakdown?, [LevelPart: LevelDriver]) {
            let inputs = LevelWiring.dayInputs(byDay: byDay, day: key, series: series, calendar: calendar)
            var drivers: [LevelPart: LevelDriver] = [:]
            for part in LevelPart.allCases {
                if let driver = LevelDrivers.driver(for: part, inputs: inputs, baselines: baselines) {
                    drivers[part] = driver
                }
            }
            return (LevelEngine.compute(inputs: inputs, baselines: baselines), drivers)
        }

        func shifted(_ key: String, by delta: Int) -> String? {
            guard let date = LevelWiring.date(from: key, calendar: calendar),
                  let moved = calendar.date(byAdding: .day, value: delta, to: date) else { return nil }
            return LevelWiring.key(from: moved, calendar: calendar)
        }

        // THE DAY WHOSE LEVEL IS CURRENT, and its frozen figure — computed and frozen the first time its
        // night is here, read back unchanged every time after that.
        let dayKey = LevelWiring.key(from: LevelDayFreeze.levelDay(), calendar: calendar)
        let shown: FrozenLevel?
        if let frozen = LevelDayFreeze.stored(), frozen.day == dayKey {
            shown = frozen
        } else if LevelWiring.nightLanded(days: days, day: dayKey), case let (b?, d) = score(dayKey) {
            let fresh = FrozenLevel(day: dayKey, breakdown: b, drivers: d)
            LevelDayFreeze.store(fresh)
            shown = fresh
        } else if let frozen = LevelDayFreeze.stored() {
            // The night has not landed yet: yesterday's level stays up rather than an empty one.
            shown = frozen
        } else if let previous = shifted(dayKey, by: -1), case let (b?, d) = score(previous) {
            // Nothing frozen ever, and no night yet today: score the last complete day and hold that.
            let fresh = FrozenLevel(day: previous, breakdown: b, drivers: d)
            LevelDayFreeze.store(fresh)
            shown = fresh
        } else {
            shown = nil
        }

        // The comparisons are measured from the day SHOWN, with the same inputs, so a delta compares a
        // frozen level with frozen levels rather than with live ones.
        let base = shown?.day ?? dayKey
        /// The mean level over the `span` days before `base`, or nil when fewer than `need` scored.
        func mean(over span: Int, need: Int) -> Double? {
            let levels = (1...span).compactMap { shifted(base, by: -$0).flatMap { score($0).0?.level } }
            guard levels.count >= need else { return nil }
            return levels.reduce(0, +) / Double(levels.count)
        }
        trend = LevelTrendSnapshot(
            now: shown?.breakdown,
            threeDaysAgo: shifted(base, by: -3).flatMap { score($0).0 },
            monthAgo: shifted(base, by: -30).flatMap { score($0).0 },
            threeDayMean: mean(over: 3, need: 2),
            monthMean: mean(over: 30, need: 10),
            drivers: shown?.drivers ?? [:]
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
        let byDay = LevelWiring.byDay(days)
        let baselines = LevelBaselineStore.resolve {
            LevelWiring.baselineHistory(days: days, series: series, calendar: calendar)
        }

        // The curve ends on the day whose level is current, and uses the same frozen-day inputs, so
        // its last point IS the headline rather than a live figure beside a frozen one.
        let frozen = LevelDayFreeze.stored()
        let today = frozen.flatMap { LevelWiring.date(from: $0.day, calendar: calendar) }
            ?? LevelDayFreeze.levelDay()
        let requested = calendar.date(byAdding: .day, value: -(spanDays - 1), to: today) ?? today
        let earliest = days.first.flatMap { LevelWiring.date(from: $0.day, calendar: calendar) }
        var cursor = (earliest.map { Swift.max($0, requested) }) ?? requested

        var out: [LevelPoint] = []
        var since = 0
        while cursor <= today {
            if Task.isCancelled { return }
            // A LONG SPAN LETS THE SCREEN DRAW. "All" is ten years of days, and running that as one
            // uninterrupted stretch on the main actor is what a hang looks like from outside.
            since += 1
            if since >= 40 {
                since = 0
                await Task.yield()
            }
            let key = LevelWiring.key(from: cursor, calendar: calendar)
            let inputs = LevelWiring.dayInputs(byDay: byDay, day: key, series: series, calendar: calendar)
            let computed = frozen?.day == key
                ? frozen?.breakdown
                : LevelEngine.compute(inputs: inputs, baselines: baselines)
            if let breakdown = computed {
                var parts: [LevelPart: Double] = [:]
                for component in breakdown.components {
                    if let score = component.score { parts[component.part] = score }
                }
                out.append(LevelPoint(day: key, level: breakdown.level, parts: parts))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        history = out
        // The best each part has reached over the span just walked. Taken from the SAME pass rather than
        // from a separate read: a personal best that disagreed with the curve under it would be worse
        // than no best at all.
        var best: [LevelPart: Double] = [:]
        for point in out {
            for (part, score) in point.parts {
                best[part] = Swift.max(best[part] ?? 0, score)
            }
        }
        partBests = best
    }

    /// ONE READ PER SERIES, for the whole span — see the note in `LevelWiring`.
    private func readSeries(repo: Repository) async -> LevelSeries {
        let key = "\(repo.refreshSeq)|\(repo.workoutsSeq)|\(repo.days.count)"
        if let cached = cachedSeries, cached.key == key { return cached.series }
        let series = await readSeriesUncached(repo: repo)
        cachedSeries = (key, series)
        return series
    }

    private func readSeriesUncached(repo: Repository) async -> LevelSeries {
        // NOOP's own training-based estimate first; the older weekly HR-ratio / non-exercise figure only
        // where there is none.
        var vo2 = await repo.series(key: Repository.noopVo2Key, source: "\(repo.deviceId)-noop", fullHistory: true)
        if vo2.isEmpty {
            vo2 = await repo.series(key: "vo2max_est", source: "\(repo.deviceId)-noop", fullHistory: true)
        }
        vo2.sort { $0.day < $1.day }
        let strength = await repo.series(key: StrengthIndex.key, source: "lifting", fullHistory: true)
            .sorted { $0.day < $1.day }

        var muscle: [String: Double] = [:]
        for group in MuscleGroup.allCases {
            let rows = await repo.series(key: group.volumeKey, source: "lifting", fullHistory: true)
            for row in rows { muscle[row.day, default: 0] += row.value }
        }

        // The level reads a 28-day share and baselines nothing off meditation, so it asks for months
        // rather than the whole log — the Focus card is the surface that wants the lifetime figure.
        let meditation = await repo.meditationMinutesByDay(days: 180)

        return LevelSeries(vo2max: vo2, muscleByDay: muscle, meditation: meditation,
                           sleepTimings: await repo.sleepTimingsByDay(),
                           daytimeRmssd: await repo.bankedDaytimeRmssd(),
                           strengthIndex: strength)
    }

}
