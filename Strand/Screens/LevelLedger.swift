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
// times, with the wake at least half an hour past. Freezing on the first of those used to lock in a level
// scored from half a night.
//
// OR AT THE DEADLINE, WHATEVER HAS ARRIVED. A night that never fully syncs cannot hold the day open
// forever: at 14:00 on the day — or two hours after that day's morning flow began, if that is later — the
// day is written with what exists, marked PARTIAL and with the list of what it went without. A day that
// is already in the past by the calendar is written at its deadline only once a sync or analysis pass has
// COMPLETED after that deadline: a day the app was not opened on is otherwise written at launch, seconds
// before the sync that carries its night.
//
// ONE WRITER, AND IT NEVER OVERWRITES. Every write goes through `commit`, which re-checks under the lock
// that the day is not already there. The one way entries leave is `resetAll`, which only a new recipe
// epoch calls (see `currentEpoch`).

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

    /// How long after the morning flow began on a day its night is still given to land. An app first
    /// opened at 23:00 would otherwise write the day on the spot, before the sync the open started.
    static let beginGrace: TimeInterval = 2 * 60 * 60

    /// How long a night has to have been over before it counts as landed: the last half hour of sleep is
    /// still being scored when the first figures for it arrive.
    static let wakeSettle: TimeInterval = 30 * 60

    /// How long past its deadline a day with NO ROW AT ALL is waited for — and only once a later day has
    /// one. A missing row is far more often a night that has not synced yet than a night not recorded.
    static let absentNightGrace: TimeInterval = 48 * 60 * 60

    /// THE RECIPE EPOCH, stored inside the ledger file itself. 1 = the nightly-metrics re-score v1
    /// (`IntelligenceEngine.nightlyMetricsRescoreFlagKey`) has finished. A ledger below the current epoch
    /// was written from nights scored the old way, so it is emptied once — in the same save that stamps the
    /// new epoch, so the two cannot disagree after a crash — and the baselines are frozen again from the
    /// re-scored history. BUMP IT whenever a recipe change must reach the days already written.
    static let currentEpoch = 2

    private struct Stored: Codable {
        var entries: [String: FrozenLevel]
        var empty: [String]
        var backfilled: Bool
        var epoch: Int
        /// Every day from `settledFrom` through `settledThrough` is settled, so a walk can start after it.
        var settledFrom: String?
        var settledThrough: String?
        /// Entries that would not decode. Never written back.
        var dropped = 0

        private enum CodingKeys: String, CodingKey {
            case entries, empty, backfilled, epoch, settledFrom, settledThrough
        }

        init(entries: [String: FrozenLevel], empty: [String], backfilled: Bool, epoch: Int,
             settledFrom: String?, settledThrough: String?) {
            self.entries = entries
            self.empty = empty
            self.backfilled = backfilled
            self.epoch = epoch
            self.settledFrom = settledFrom
            self.settledThrough = settledThrough
        }

        /// ONE BAD ENTRY COSTS ONE DAY, NOT THE LEDGER. Each entry is decoded on its own; one that will
        /// not is counted and left out, and every other day loads as written. A file with no epoch is
        /// from before there was one, which is epoch 0.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try c.decodeIfPresent([String: LossyLevel].self, forKey: .entries) ?? [:]
            var entries: [String: FrozenLevel] = [:]
            var dropped = 0
            for (day, box) in raw {
                if let level = box.value, level.day == day { entries[day] = level } else { dropped += 1 }
            }
            self.entries = entries
            self.dropped = dropped
            empty = (try? c.decodeIfPresent([String].self, forKey: .empty)) ?? []
            backfilled = (try? c.decodeIfPresent(Bool.self, forKey: .backfilled)) ?? false
            epoch = (try? c.decodeIfPresent(Int.self, forKey: .epoch)) ?? 0
            settledFrom = (try? c.decodeIfPresent(String.self, forKey: .settledFrom)) ?? nil
            settledThrough = (try? c.decodeIfPresent(String.self, forKey: .settledThrough)) ?? nil
        }
    }

    /// An entry that decodes to nil rather than failing the whole file.
    private struct LossyLevel: Decodable {
        let value: FrozenLevel?
        init(from decoder: Decoder) throws { value = try? FrozenLevel(from: decoder) }
    }

    /// Whether the file on disk has been read. NOTHING IS WRITTEN UNTIL IT HAS: a ledger that could not
    /// be read and was then saved from an empty memory would wipe every day it held.
    private enum LoadState {
        case loaded
        /// The file exists but could not be read (a locked device's file protection, an I/O error). It is
        /// left exactly where it is and read again on the next `retryLoadIfNeeded`.
        case unreadable
        /// The file was read but is not a ledger. Moved aside; read-only until the next launch.
        case corrupt
    }

    private let lock = NSLock()
    private let url: URL?
    private var state: LoadState = .loaded
    private var levels: [String: FrozenLevel] = [:]
    /// Days whose entry would not encode even after cleaning. Kept for the life of the process so the day
    /// is not recomputed on every refresh, but not written to disk.
    private var memoryOnly: [String: FrozenLevel] = [:]
    private var empty: Set<String> = []
    private var backfilled = false
    private var storedEpoch = 0
    private var settledFrom: String?
    private var settledThrough: String?

    /// `fileURL` nil keeps the ledger in memory only (tests). `legacy` is where the old single frozen day
    /// is carried over from, the first time the ledger file does not exist yet.
    init(fileURL: URL? = LevelLedger.defaultURL, legacy: UserDefaults = .standard) {
        url = fileURL
        guard let url else { return }
        // THE FIRST-RUN PATH IS TAKEN ONLY WHEN THERE IS NO FILE. A file that exists but will not read is
        // not a first run, and treating it as one used to overwrite the whole ledger with an empty one.
        if FileManager.default.fileExists(atPath: url.path) {
            loadLocked(from: url)
            return
        }
        // FIRST RUN: the day the old freeze held is the one figure the wearer has already seen, so it is
        // the first entry — carried over as it was, not recomputed.
        if let data = legacy.data(forKey: LevelDayFreeze.legacyKey),
           let old = try? JSONDecoder().decode(FrozenLevel.self, from: data) {
            levels[old.day] = old
        }
        // The old key goes only once the ledger that now holds its day is safely on disk.
        if persistLocked() {
            legacy.removeObject(forKey: LevelDayFreeze.legacyKey)
        }
    }

    static var defaultURL: URL? {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        return base?.appendingPathComponent("level_ledger.json")
    }

    /// Read the file into memory. Called from `init`, or with the lock held.
    private func loadLocked(from url: URL) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            NSLog("LevelLedger: the ledger could not be read, read-only until it can: %@",
                  String(describing: error))
            state = .unreadable
            return
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            NSLog("LevelLedger: the ledger file is not a ledger; moved aside, read-only until the next launch")
            state = .corrupt
            putAside(url, copy: false)
            return
        }
        levels = stored.entries
        empty = Set(stored.empty)
        backfilled = stored.backfilled
        storedEpoch = stored.epoch
        settledFrom = stored.settledFrom
        settledThrough = stored.settledThrough
        state = .loaded
        if stored.dropped > 0 {
            // The file as it was is kept beside the ledger, because the next save leaves those days out.
            NSLog("LevelLedger: %d entries would not decode and were left out", stored.dropped)
            putAside(url, copy: true)
        }
    }

    /// The name a bad ledger file is put aside under: beside it, dated.
    static func asideURL(for url: URL, stamp: Int) -> URL {
        let ext = url.pathExtension.isEmpty ? "json" : url.pathExtension
        return url.deletingPathExtension().appendingPathExtension("corrupt-\(stamp)").appendingPathExtension(ext)
    }

    /// Put the file aside — moved when it is unusable, copied when only some of its entries were.
    private func putAside(_ url: URL, copy: Bool) {
        let aside = Self.asideURL(for: url, stamp: Int(Date().timeIntervalSince1970))
        do {
            if copy {
                try FileManager.default.copyItem(at: url, to: aside)
            } else {
                try FileManager.default.moveItem(at: url, to: aside)
            }
        } catch {
            NSLog("LevelLedger: could not put the ledger file aside: %@", String(describing: error))
        }
    }

    /// Read the file again if it could not be read at launch — a device unlocked since, say.
    func retryLoadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard state == .unreadable, let url, FileManager.default.fileExists(atPath: url.path) else { return }
        loadLocked(from: url)
    }

    /// Whether anything may be written: the file on disk has been read, or there was none.
    var isWritable: Bool {
        lock.lock(); defer { lock.unlock() }
        return state == .loaded
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

    /// The recipe epoch the entries were written under — see `currentEpoch`.
    var epoch: Int {
        lock.lock(); defer { lock.unlock() }
        return storedEpoch
    }

    /// The span known to be settled end to end, so a walk can start the day after it.
    var settledSpan: (from: String, through: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let settledFrom, let settledThrough else { return nil }
        return (settledFrom, settledThrough)
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
        guard state == .loaded else { return 0 }
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
        guard state == .loaded, !backfilled else { return }
        backfilled = true
        persistLocked()
    }

    /// Record that every day from `start` through `end` is settled. The end only ever moves forward; the
    /// start moves back when older history arrived and was walked.
    func markSettled(from start: String, through end: String) {
        lock.lock(); defer { lock.unlock() }
        guard state == .loaded, start <= end else { return }
        let newThrough = Swift.max(end, settledThrough ?? end)
        guard start != settledFrom || newThrough != settledThrough else { return }
        settledFrom = start
        settledThrough = newThrough
        persistLocked()
    }

    /// Forget every day, and stamp `epoch` when one is given — in the SAME save, so a ledger emptied for
    /// a new recipe can never be read back as the old one, nor the old entries under the new epoch.
    func resetAll(epoch newEpoch: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard state == .loaded else { return }
        levels = [:]
        memoryOnly = [:]
        empty = []
        backfilled = false
        settledFrom = nil
        settledThrough = nil
        if let newEpoch { storedEpoch = newEpoch }
        persistLocked()
    }

    /// Move a ledger written under an older recipe to the current one: `beforeReset` (freezing the
    /// baselines again from the re-scored history) runs first, then the ledger is emptied and stamped in
    /// one save. Only once the nights have been re-scored, and only once — a ledger already on the current
    /// epoch is left alone. True when it reset.
    @discardableResult
    func adoptCurrentEpochIfNeeded(rescoreDone: Bool, beforeReset: () -> Void) -> Bool {
        guard rescoreDone, isWritable, epoch < Self.currentEpoch else { return false }
        beforeReset()
        resetAll(epoch: Self.currentEpoch)
        return true
    }

    private func pruneLocked() {
        let all = Set(levels.keys).union(memoryOnly.keys).union(empty)
        guard all.count > Self.maxDays else { return }
        let cutoff = all.sorted()[all.count - Self.maxDays]
        levels = levels.filter { $0.key >= cutoff }
        memoryOnly = memoryOnly.filter { $0.key >= cutoff }
        empty = empty.filter { $0 >= cutoff }
    }

    /// Save to disk. True when there is nowhere to save to, or the save succeeded.
    @discardableResult
    private func persistLocked() -> Bool {
        guard let url else { return true }
        guard state == .loaded else { return false }
        let stored = Stored(entries: levels, empty: empty.sorted(), backfilled: backfilled, epoch: storedEpoch,
                            settledFrom: settledFrom, settledThrough: settledThrough)
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("LevelLedger: could not save the ledger: %@", String(describing: error))
            return false
        }
    }

    // MARK: - When a day may be written

    /// Whether anything may be settled right now: the nights have been re-scored, and nothing — an
    /// import, a strap offload, an analysis pass — is writing to the store. A day written mid-import is
    /// written from a store that is half there.
    static func maySettle(rescoreDone: Bool, dataInFlight: Bool) -> Bool {
        rescoreDone && !dataInFlight
    }

    /// When the night that ended on `day` ended, from its wake time. Nil without one.
    static func wakeTime(day: String, series: LevelSeries, calendar: Calendar) -> Date? {
        guard let timing = series.sleepTimings[day],
              let start = LevelWiring.date(from: day, calendar: calendar) else { return nil }
        let minute = Swift.min(Swift.max(timing.wakeMinute, 0), 24 * 60 - 1)
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start)
    }

    /// What the night that ended on `day` is still missing before the day may be written on time.
    /// Empty means the night has landed.
    ///
    /// THE BREATHING RATE IS ASKED FOR ONLY WHERE IT IS NORMALLY THERE. Plenty of sources never record
    /// one; demanding it of them would push every one of their days to the deadline.
    ///
    /// WITH `now`, THE NIGHT MUST ALSO BE OVER BY HALF AN HOUR: every figure can be present for a night
    /// whose last stretch is still being scored.
    static func nightMissing(day: String, byDay: [String: DailyMetric], series: LevelSeries,
                             calendar: Calendar, now: Date? = nil) -> [String] {
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
        if let now, let wake = wakeTime(day: day, series: series, calendar: calendar),
           now < wake.addingTimeInterval(wakeSettle) {
            out.append("wakeSettling")
        }
        return out
    }

    /// The longest a load books its next look ahead. A reload every three hours at most is cheap, and it
    /// bounds the damage of a clock change or a wake time that moves under a late sync.
    static let maxSettleCheckDelay: TimeInterval = 3 * 60 * 60

    /// A few seconds past the boundary, so the reload's own `now` is on the far side of it.
    static let settleCheckSlack: TimeInterval = 5

    /// When an UNSETTLED `day` next becomes writable without anything else happening: the earlier of its
    /// wake + `wakeSettle` (the night is over) and its deadline — whichever are still ahead of `now`. Nil
    /// when neither is: then only new data (a sync, an analysis pass) can change the answer, and those
    /// reload the level themselves.
    ///
    /// WHY THIS EXISTS. Nothing reloaded the level at those two moments. A night that had fully landed at
    /// 07:10 with a 07:00 wake stayed "settling" until something else happened to reload — and the brief's
    /// ten-minute poll could end first — so the day could sit pending until the afternoon.
    static func nextSettleCheck(day: String, series: LevelSeries, beganAt: Date?,
                                calendar: Calendar, now: Date) -> Date? {
        var candidates: [Date] = []
        if let wake = wakeTime(day: day, series: series, calendar: calendar) {
            let settled = wake.addingTimeInterval(wakeSettle)
            if settled > now { candidates.append(settled) }
        }
        if let due = deadline(day: day, beganAt: beganAt, calendar: calendar), due > now {
            candidates.append(due)
        }
        return candidates.min()
    }

    /// How long to wait for a look booked at `at`: just past it, never more than `maxSettleCheckDelay`.
    static func settleCheckDelay(at: Date, now: Date) -> TimeInterval {
        Swift.min(Swift.max(at.timeIntervalSince(now), 0) + settleCheckSlack, maxSettleCheckDelay)
    }

    static func isReady(day: String, byDay: [String: DailyMetric], series: LevelSeries,
                        calendar: Calendar, now: Date? = nil) -> Bool {
        nightMissing(day: day, byDay: byDay, series: series, calendar: calendar, now: now).isEmpty
    }

    /// The moment `day` is written whatever has arrived: 14:00 on it — set on the clock, so a DST change
    /// that morning does not move it an hour — or two hours after that day's morning flow began, if later.
    static func deadline(day: String, beganAt: Date? = nil, calendar: Calendar) -> Date? {
        guard let start = LevelWiring.date(from: day, calendar: calendar),
              let afternoon = calendar.date(bySettingHour: deadlineHour, minute: 0, second: 0, of: start)
        else { return nil }
        guard let beganAt else { return afternoon }
        return Swift.max(afternoon, beganAt.addingTimeInterval(beginGrace))
    }

    /// Whether `day` must be written now whatever has arrived.
    ///
    /// The current day: once its deadline has passed. A day ALREADY IN THE PAST — before the level day, or
    /// before today on the calendar — additionally waits for a sync or analysis pass to have COMPLETED
    /// after its deadline (`lastCompletedPass`): at launch after days away, those days' deadlines have all
    /// passed, but their nights are still on the strap or in the cloud.
    static func deadlinePassed(day: String, levelDay: String, now: Date, calendar: Calendar,
                               beganAt: Date? = nil, lastCompletedPass: Date? = nil) -> Bool {
        guard let deadline = deadline(day: day, beganAt: beganAt, calendar: calendar), now >= deadline
        else { return false }
        let past = day < levelDay || day < LevelWiring.key(from: now, calendar: calendar)
        guard past else { return true }
        guard let pass = lastCompletedPass else { return false }
        return pass >= deadline
    }

    /// Whether a day with NO ROW may be closed at its deadline — written as a level from the days around
    /// it, or as a gap. Only once a LATER day has a row (so the sync has moved past it) and 48 hours have
    /// passed since its deadline. A day with a row is not held back by this.
    static func absentNightMayClose(hasRow: Bool, newestRowDay: String?, day: String, deadline: Date?,
                                    now: Date) -> Bool {
        if hasRow { return true }
        guard let deadline, now >= deadline.addingTimeInterval(absentNightGrace),
              let newest = newestRowDay else { return false }
        return newest > day
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
    ///
    /// `absentNightMayClose` false holds a deadline write back for a day with no row at all — see
    /// `absentNightMayClose(hasRow:newestRowDay:day:deadline:now:)`.
    static func settle(
        day: String,
        byDay: [String: DailyMetric],
        series: LevelSeries,
        baselines: [LevelMetric: Baseline],
        calendar: Calendar,
        deadlinePassed: Bool,
        backfilled: Bool = false,
        now: Date = Date(),
        absentNightMayClose: Bool = true
    ) -> LevelSettlement? {
        let ready = isReady(day: day, byDay: byDay, series: series, calendar: calendar, now: now)
        guard ready || (deadlinePassed && absentNightMayClose) else { return nil }
        let inputs = sanitized(LevelWiring.dayInputs(byDay: byDay, day: day, series: series, calendar: calendar))
        guard let breakdown = LevelEngine.compute(inputs: inputs, baselines: baselines) else {
            return deadlinePassed && absentNightMayClose ? .empty(day) : nil
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
