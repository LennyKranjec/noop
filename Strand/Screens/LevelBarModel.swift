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
// ONE LEVEL A DAY, AND EVERY DAY FROM THE LEDGER. A day's level is written to `LevelLedger` once its night
// has landed (or at its deadline) and read back unchanged every time after that — see `LevelDayFreeze`
// and `LevelLedger`. The refresh counter still drives this, because a day has to be written the first
// time its night arrives, but nothing shown here is ever computed on the spot: the headline, the arrows,
// the means and the timeline all read the ledger, and a day missing from it is a gap.
//
// ONE MODEL FOR THE WHOLE APP. The shell's strip and the Health tab used to own an instance each, and
// both raced to freeze the same morning from their own snapshot of the store. There is one now,
// `LevelBarModel.shared`, and one load at a time: a load that a newer one has overtaken stops where it is.
//
// IT NEVER THROWS AND NEVER BLOCKS THE BAR. Every read is best-effort: a store that is not ready yet
// produces no snapshot, and the strip draws its empty state rather than a zero.

/// One input the level was computed WITHOUT, and what would bring it in.
///
/// The engine hands a missing metric's weight to the ones that have data, which is honest arithmetic but
/// invisible: a level missing VO₂max and strength reads exactly like one that has them. The sheet names
/// what is absent so the wearer can tell a level that is low from one that is merely partial.
enum LevelMissingInput: String, CaseIterable, Identifiable {
    case restorativeSleep, hrv, regularity, rhr, vo2max, respRate, strength, trainingLoad, daytimeCalm, steps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .restorativeSleep: return "Deep + REM sleep"
        case .hrv: return "Night HRV"
        case .regularity: return "Sleep regularity"
        case .rhr: return "Resting heart rate"
        case .vo2max: return "VO₂max"
        case .respRate: return "Respiratory rate"
        case .strength: return "Strength"
        case .trainingLoad: return "Training load"
        case .daytimeCalm: return "Daytime calm"
        case .steps: return "Steps"
        }
    }

    var hint: String {
        switch self {
        case .restorativeSleep: return "No staged night in the last 7 days."
        case .hrv: return "No night HRV in the last 7 days."
        case .regularity: return "Needs two nights in a row with bed and wake times."
        case .rhr: return "No resting heart rate in the last 7 days."
        case .vo2max: return "No estimate yet: record runs or brisk walks with GPS, or add your waist in the profile."
        case .respRate: return "No respiratory rate in the last 7 days."
        case .strength: return "No lifting in the last 12 weeks: import your lifting log."
        case .trainingLoad: return "No lifting volume logged in the last 6 months."
        case .daytimeCalm: return "Wear the strap during the day so calm hours can be scored."
        case .steps: return "No step count, so the step multiplier is not applied."
        }
    }

    /// What `inputs` is missing. Meditation is never listed: a day without one is a zero, not a gap.
    static func from(_ inputs: LevelInputs) -> [LevelMissingInput] {
        var out: [LevelMissingInput] = []
        if inputs.restorativeMin == nil { out.append(.restorativeSleep) }
        if inputs.hrv == nil && inputs.sleepHrv == nil { out.append(.hrv) }
        if inputs.regularityMin == nil { out.append(.regularity) }
        if inputs.rhr == nil { out.append(.rhr) }
        if inputs.vo2max == nil { out.append(.vo2max) }
        if inputs.respRate == nil { out.append(.respRate) }
        if inputs.strengthIndex == nil { out.append(.strength) }
        if inputs.chronicLoad == nil { out.append(.trainingLoad) }
        if inputs.daytimeRmssd == nil { out.append(.daytimeCalm) }
        if inputs.steps == nil { out.append(.steps) }
        return out
    }
}

@MainActor
final class LevelBarModel: ObservableObject {

    /// The one instance: the shell's strip, the Health tab and the morning brief all read this.
    static let shared = LevelBarModel()

    @Published private(set) var trend: LevelTrendSnapshot?
    /// Every scored day over the span the timeline asked for, oldest first.
    @Published private(set) var history: [LevelPoint] = []
    @Published private(set) var loadingHistory = false
    /// The best each part reached over the span the timeline last loaded. Empty until it has.
    @Published private(set) var partBests: [LevelPart: Double] = [:]
    /// The inputs the shown day's level was computed without.
    @Published private(set) var missing: [LevelMissingInput] = [] {
        didSet { Self.lastMissing = missing }
    }
    /// The latest `missing`, for the coach's context.
    static var lastMissing: [LevelMissingInput] = []

    private let ledger: LevelLedger

    private var lastLoadedTick: Int = -1
    /// Bumped by every load. A load that finds it moved on after an await has been overtaken and stops.
    private var generation = 0
    /// The span the timeline last asked for, so a load that writes new days can redraw it.
    private var historySpan: Int?

    /// The series behind the last load, and the tick they were read at.
    ///
    /// PERF: reading them is a dozen full-history series reads plus the workout log, and they are the
    /// same reads for the same data, so they are kept until the data behind them changes.
    private var cachedSeries: (key: String, series: LevelSeries)?

    init(ledger: LevelLedger = .shared) {
        self.ledger = ledger
    }

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
        generation += 1
        let gen = generation
        guard !repo.days.isEmpty else {
            trend = nil
            return
        }
        let calendar = Calendar.current
        let series = await readSeries(repo: repo)
        guard gen == generation else { return }
        await settlePending(repo: repo, series: series, calendar: calendar, generation: gen)
        guard gen == generation else { return }
        publish(calendar: calendar)
        if let span = historySpan { rebuildHistory(spanDays: span, calendar: calendar) }
    }

    /// Write every day that is due and not yet in the ledger, oldest first.
    ///
    /// THE FIRST RUN WRITES THE PAST. Days from before the ledger existed are scored once, now, with the
    /// engine and baselines as they stand, marked `backfilled` — and never again. After that the same
    /// walk only finds the days the app was not opened on, and today once its night is in.
    ///
    /// THE STORE IS READ AFTER THE AWAITS, NOT BEFORE. The day rows are taken fresh here, and again after
    /// every yield, so a day is never written from a snapshot older than the sync that just finished.
    private func settlePending(repo: Repository, series: LevelSeries, calendar: Calendar,
                               generation gen: Int) async {
        let now = Date()
        let levelDate = LevelDayFreeze.levelDay(now: now, calendar: calendar)
        let levelKey = LevelWiring.key(from: levelDate, calendar: calendar)
        var days = repo.days
        guard let firstKey = days.lazy.map(\.day).min(),
              let firstDate = LevelWiring.date(from: firstKey, calendar: calendar) else { return }
        let floor = calendar.date(byAdding: .day, value: -(LevelLedger.maxDays - 1), to: levelDate) ?? levelDate
        var cursor = Swift.max(firstDate, floor)
        // NOTHING IS WRITTEN UNTIL THE NIGHTS HAVE BEEN RE-SCORED. The one-shot full-history pass
        // (`IntelligenceEngine.runNightlyMetricsRescoreIfNeeded`) re-derives every night's resting HR,
        // HRV, breathing and sleep window with the current methods; a day frozen before it finished would
        // be frozen on the old figures for good. Until the flag is set the strip shows what is there and
        // writes nothing.
        guard UserDefaults.standard.bool(forKey: IntelligenceEngine.nightlyMetricsRescoreFlagKey) else { return }
        let backfilling = !ledger.hasBackfilled
        // The first backfill starts from an empty ledger: whatever was carried over from the old single
        // frozen day was scored on the pre-rescore figures, and keeping it would freeze exactly the value
        // the rescore exists to correct.
        // Once only, keyed on its own flag: a backfill interrupted by a newer load must resume from what
        // it wrote, not start over.
        let resetKey = "level.ledger.postRescoreReset.v1"
        if backfilling, !UserDefaults.standard.bool(forKey: resetKey) {
            ledger.resetAll()
            UserDefaults.standard.set(true, forKey: resetKey)
        }

        var byDay = LevelWiring.byDay(days)
        let baselines = LevelBaselineStore.resolve {
            LevelWiring.baselineHistory(days: days, series: series, calendar: calendar)
        }

        var batch: [LevelSettlement] = []
        var since = 0
        while cursor <= levelDate {
            let key = LevelWiring.key(from: cursor, calendar: calendar)
            if !ledger.isSettled(key) {
                let due = LevelLedger.deadlinePassed(day: key, levelDay: levelKey, now: now, calendar: calendar)
                if let s = LevelLedger.settle(day: key, byDay: byDay, series: series, baselines: baselines,
                                              calendar: calendar, deadlinePassed: due,
                                              backfilled: backfilling && key < levelKey, now: now) {
                    batch.append(s)
                }
            }
            // A LONG BACKFILL LETS THE SCREEN DRAW. Two years of days scored as one uninterrupted stretch on
            // the main actor is what a hang looks like from outside — so every forty days what is done is
            // written, the screen gets a turn, and the walk carries on from fresh rows.
            since += 1
            if since >= 40 {
                since = 0
                ledger.commit(batch)
                batch = []
                await Task.yield()
                guard gen == generation, !Task.isCancelled else { return }
                if repo.days.count != days.count || repo.days.last != days.last {
                    days = repo.days
                    byDay = LevelWiring.byDay(days)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        ledger.commit(batch)
        if backfilling { ledger.markBackfilled() }
    }

    /// The snapshot the strip draws — every figure in it read from the ledger.
    private func publish(calendar: Calendar) {
        let levelKey = LevelWiring.key(from: LevelDayFreeze.levelDay(calendar: calendar), calendar: calendar)
        // THE DAY WHOSE LEVEL IS CURRENT, if it is written. If its night has not landed yet, the last
        // written day stays up — marked pending, so nothing presents it as today's.
        let today = ledger.entry(levelKey)
        let shown = today ?? ledger.latest(onOrBefore: levelKey)

        // The comparisons are measured from the day SHOWN, and are ledger values too: a delta compares a
        // written level with written levels, never with a live recomputation.
        let base = shown?.day ?? levelKey
        missing = shown?.missingInputs ?? []
        func written(_ delta: Int) -> FrozenLevel? {
            LevelWiring.shift(base, delta, calendar).flatMap { ledger.entry($0) }
        }
        /// The mean level over the `span` days before `base`, or nil when fewer than `need` are written.
        func mean(over span: Int, need: Int) -> Double? {
            let levels = (1...span).compactMap { written(-$0)?.level }
            guard levels.count >= need else { return nil }
            return levels.reduce(0, +) / Double(levels.count)
        }
        trend = LevelTrendSnapshot(
            now: shown?.breakdown,
            threeDaysAgo: written(-3)?.breakdown,
            monthAgo: written(-30)?.breakdown,
            threeDayMean: mean(over: 3, need: 2),
            monthMean: mean(over: 30, need: 10),
            yesterdayLevel: written(-1)?.level,
            drivers: shown?.drivers ?? [:],
            pendingToday: today == nil
        )
    }

    /// Every written day over `spanDays`, for the timeline — straight from the ledger.
    ///
    /// NOTHING IS SCORED HERE. The timeline used to run the formula over every day of the span against
    /// today's store, which is exactly how a past day came to read differently from what it had shown.
    func loadHistory(repo: Repository, spanDays: Int) async {
        loadingHistory = true
        defer { loadingHistory = false }
        historySpan = spanDays
        rebuildHistory(spanDays: spanDays, calendar: Calendar.current)
    }

    private func rebuildHistory(spanDays: Int, calendar: Calendar) {
        // The curve ends on the day the headline shows, so its last point IS the headline.
        let levelKey = LevelWiring.key(from: LevelDayFreeze.levelDay(calendar: calendar), calendar: calendar)
        let end = ledger.entry(levelKey)?.day ?? ledger.latest(onOrBefore: levelKey)?.day ?? levelKey
        let start = LevelWiring.shift(end, -(Swift.max(spanDays, 1) - 1), calendar) ?? end
        let out: [LevelPoint] = ledger.entries(from: start, through: end).map { entry in
            var parts: [LevelPart: Double] = [:]
            for part in entry.parts {
                if let score = part.score { parts[part.part] = score }
            }
            return LevelPoint(day: entry.day, level: entry.level, parts: parts)
        }
        history = out
        // The best each part has reached over the span just drawn. Taken from the SAME entries rather than
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
