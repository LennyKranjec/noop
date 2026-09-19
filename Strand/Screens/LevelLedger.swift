import Foundation
import StrandAnalytics
import WhoopStore

// LevelLedger.swift — every day's level, written once and never again.
//
// A PAST LEVEL IS A FACT, NOT A FORMULA. The level used to keep one frozen day and recompute every other
// one — yesterday, three days ago, the month's mean, the whole timeline — from whatever the store held at
// the moment of looking. The store does not hold still: a seven-day mean gains a late night, the WHOOP
// cloud rewrites a row, a baseline freezes a week later, the day before gets its last workout synced. So
// yesterday's level rose after the fact, and the morning's number moved three times before breakfast.
//
// SO EACH DAY IS WRITTEN DOWN ONCE, HERE, and everything that shows a level reads it back from here: the
// headline, the arrows, the means, the timeline, the coach. A day that is not in the ledger is a gap, not
// a number worked out on the spot.
//
// A DAY IS WRITTEN WHEN ITS NIGHT HAS LANDED — all of it, not the first figure to arrive. HRV, resting HR,
// total sleep, deep and REM, the breathing rate where this wearer's history has one, and the bed and wake
// times. Freezing on the first of those used to lock in a level scored from half a night.
//
// OR AT THE DEADLINE, WHATEVER HAS ARRIVED. A night that never fully syncs cannot hold the day open
// forever: at 14:00 on the day — or as soon as the next morning's flow begins — the day is written with
// what exists, marked PARTIAL and with the list of what it went without.
//
// ONE WRITER, AND IT NEVER OVERWRITES. Every write goes through `commit`, which re-checks under the lock
// that the day is not already there. The one way an entry leaves is `resetAll`, which nothing calls yet.

/// One row of the ledger's work for a day: a level to keep, or a day settled as having none.
enum LevelSettlement: Equatable {
    case level(FrozenLevel)
    /// The deadline passed and nothing could be scored: a gap, kept as one so it is not retried forever.
    case empty(String)

    var day: String {
        switch self {
        case .level(let l): return l.day
        case .empty(let d): return d
        }
    }
}

final class LevelLedger: @unchecked Sendable {

    static let shared = LevelLedger()

    /// A little over two years. Older days fall off the far end; they are never recomputed.
    static let maxDays = 800

    /// The hour on the day after which a night that never fully landed is written down as it stands.
    static let deadlineHour = 14

    private struct Stored: Codable {
        var entries: [String: FrozenLevel]
        var empty: [String]
        var backfilled: Bool
    }

    private let lock = NSLock()
    private let url: URL?
    private var levels: [String: FrozenLevel] = [:]
    /// Days whose entry would not encode even after cleaning. Kept for the life of the process so the day
    /// is not recomputed on every refresh, but not written to disk.
    private var memoryOnly: [String: FrozenLevel] = [:]
    private var empty: Set<String> = []
    private var backfilled = false

    /// `fileURL` nil keeps the ledger in memory only (tests). `legacy` is where the old single frozen day
    /// is carried over from, the first time the ledger file does not exist yet.
    init(fileURL: URL? = LevelLedger.defaultURL, legacy: UserDefaults = .standard) {
        url = fileURL
        if let url, let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            levels = stored.entries
            empty = Set(stored.empty)
            backfilled = stored.backfilled
            return
        }
        // FIRST RUN: the day the old freeze held is the one figure the wearer has already seen, so it is
        // the first entry — carried over as it was, not recomputed.
        if let data = legacy.data(forKey: LevelDayFreeze.legacyKey),
           let old = try? JSONDecoder().decode(FrozenLevel.self, from: data) {
            levels[old.day] = old
        }
        persistLocked()
        legacy.removeObject(forKey: LevelDayFreeze.legacyKey)
    }

    static var defaultURL: URL? {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return base?.appendingPathComponent("level_ledger.json")
    }

    // MARK: - Reading

    func entry(_ day: String) -> FrozenLevel? {
        lock.lock(); defer { lock.unlock() }
        return levels[day] ?? memoryOnly[day]
    }

    /// Whether the day is done with: a level written, or settled as a gap.
    func isSettled(_ day: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return levels[day] != nil || memoryOnly[day] != nil || empty.contains(day)
    }

    /// The newest entry on or before `day`.
    func latest(onOrBefore day: String) -> FrozenLevel? {
        lock.lock(); defer { lock.unlock() }
        let best = (levels.keys.filter { $0 <= day } + memoryOnly.keys.filter { $0 <= day }).max()
        return best.flatMap { levels[$0] ?? memoryOnly[$0] }
    }

    /// Every entry from `start` through `end`, oldest first.
    func entries(from start: String, through end: String) -> [FrozenLevel] {
        lock.lock(); defer { lock.unlock() }
        var out = levels.filter { $0.key >= start && $0.key <= end }
        for (k, v) in memoryOnly where k >= start && k <= end && out[k] == nil { out[k] = v }
        return out.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Whether the one-off backfill of days from before the ledger has run.
    var hasBackfilled: Bool {
        lock.lock(); defer { lock.unlock() }
        return backfilled
    }

    // MARK: - Writing

    /// Write one day. False when the day was already settled — the entry there is left exactly as it was.
    @discardableResult
    func write(_ level: FrozenLevel) -> Bool {
        commit([.level(level)]) == 1
    }

    /// Write every settlement whose day is not already settled, and save once. Returns how many were new.
    @discardableResult
    func commit(_ settlements: [LevelSettlement]) -> Int {
        guard !settlements.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var added = 0
        for s in settlements {
            let day = s.day
            // THE GATE. Re-checked here, under the lock, right before the write — whoever computed this
            // settlement, and from whatever snapshot, a day already in the ledger stays as it is.
            guard levels[day] == nil, memoryOnly[day] == nil, !empty.contains(day) else { continue }
            switch s {
            case .level(let l):
                if (try? JSONEncoder().encode(l)) != nil {
                    levels[day] = l
                } else {
                    NSLog("LevelLedger: the level for %@ does not encode; kept in memory only", day)
                    memoryOnly[day] = l
                }
            case .empty(let d):
                empty.insert(d)
            }
            added += 1
        }
        if added > 0 {
            pruneLocked()
            persistLocked()
        }
        return added
    }

    func markBackfilled() {
        lock.lock(); defer { lock.unlock() }
        guard !backfilled else { return }
        backfilled = true
        persistLocked()
    }

    /// Forget every day. The only way an entry is ever removed — for a future "start over" in Settings.
    func resetAll() {
        lock.lock(); defer { lock.unlock() }
        levels = [:]
        memoryOnly = [:]
        empty = []
        backfilled = false
        persistLocked()
    }

    private func pruneLocked() {
        let all = Set(levels.keys).union(memoryOnly.keys).union(empty)
        guard all.count > Self.maxDays else { return }
        let cutoff = all.sorted()[all.count - Self.maxDays]
        levels = levels.filter { $0.key >= cutoff }
        memoryOnly = memoryOnly.filter { $0.key >= cutoff }
        empty = empty.filter { $0 >= cutoff }
    }

    private func persistLocked() {
        guard let url else { return }
        let stored = Stored(entries: levels, empty: empty.sorted(), backfilled: backfilled)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("LevelLedger: could not save the ledger: %@", String(describing: error))
        }
    }

    // MARK: - When a day may be written

    /// What the night that ended on `day` is still missing before the day may be written on time.
    /// Empty means the night has landed.
    ///
    /// THE BREATHING RATE IS ASKED FOR ONLY WHERE IT IS NORMALLY THERE. Plenty of sources never record
    /// one; demanding it of them would push every one of their days to the deadline.
    static func nightMissing(day: String, byDay: [String: DailyMetric], series: LevelSeries,
                             calendar: Calendar) -> [String] {
        func has(_ x: Double?) -> Bool { x.map { $0.isFinite } ?? false }
        var out: [String] = []
        let row = byDay[day]
        if !has(row?.avgHrv) { out.append("hrv") }
        if row?.restingHr == nil { out.append("restingHr") }
        if !has(row?.totalSleepMin) { out.append("totalSleep") }
        if !has(row?.deepMin) { out.append("deep") }
        if !has(row?.remMin) { out.append("rem") }
        let week = LevelWiring.keysBack(day, LevelEngine.rollingDays + 1, calendar).dropFirst()
        let usuallyHasResp = week.contains { byDay[$0]?.respRateBpm != nil }
        if usuallyHasResp, !has(row?.respRateBpm) { out.append("respRate") }
        if series.sleepTimings[day] == nil { out.append("sleepTiming") }
        return out
    }

    static func isReady(day: String, byDay: [String: DailyMetric], series: LevelSeries,
                        calendar: Calendar) -> Bool {
        nightMissing(day: day, byDay: byDay, series: series, calendar: calendar).isEmpty
    }

    /// Whether `day` must be written now whatever has arrived: 14:00 on it has passed, or it is no longer
    /// the current level day because the next morning's flow has begun.
    static func deadlinePassed(day: String, levelDay: String, now: Date, calendar: Calendar) -> Bool {
        if day < levelDay { return true }
        guard let start = LevelWiring.date(from: day, calendar: calendar),
              let deadline = calendar.date(byAdding: .hour, value: deadlineHour, to: start) else { return false }
        return now >= deadline
    }

    /// Every Double of the inputs finite, or gone. A NaN VO₂max is no VO₂max, and is listed as missing.
    static func sanitized(_ inputs: LevelInputs) -> LevelInputs {
        var i = inputs
        i.restorativeMin = FrozenLevel.finite(i.restorativeMin)
        i.sleepHrv = FrozenLevel.finite(i.sleepHrv)
        i.regularityMin = FrozenLevel.finite(i.regularityMin)
        i.hrv = FrozenLevel.finite(i.hrv)
        i.rhr = FrozenLevel.finite(i.rhr)
        i.vo2max = FrozenLevel.finite(i.vo2max)
        i.respRate = FrozenLevel.finite(i.respRate)
        i.strengthIndex = FrozenLevel.finite(i.strengthIndex)
        i.chronicLoad = FrozenLevel.finite(i.chronicLoad)
        i.daytimeRmssd = FrozenLevel.finite(i.daytimeRmssd)
        i.meditationShare = FrozenLevel.finite(i.meditationShare) ?? 0
        return i
    }

    /// What to write for `day` now, or nil to wait for its night.
    static func settle(
        day: String,
        byDay: [String: DailyMetric],
        series: LevelSeries,
        baselines: [LevelMetric: Baseline],
        calendar: Calendar,
        deadlinePassed: Bool,
        backfilled: Bool = false,
        now: Date = Date()
    ) -> LevelSettlement? {
        let ready = isReady(day: day, byDay: byDay, series: series, calendar: calendar)
        guard ready || deadlinePassed else { return nil }
        let inputs = sanitized(LevelWiring.dayInputs(byDay: byDay, day: day, series: series, calendar: calendar))
        guard let breakdown = LevelEngine.compute(inputs: inputs, baselines: baselines) else {
            return deadlinePassed ? .empty(day) : nil
        }
        var drivers: [LevelPart: LevelDriver] = [:]
        for part in LevelPart.allCases {
            if let driver = LevelDrivers.driver(for: part, inputs: inputs, baselines: baselines) {
                drivers[part] = driver
            }
        }
        return .level(FrozenLevel(day: day, breakdown: breakdown, drivers: drivers,
                                  missing: LevelMissingInput.from(inputs), partial: !ready,
                                  backfilled: backfilled, computedAt: now))
    }
}
