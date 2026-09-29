import Foundation

// SleepRegularity.swift — ONE canonical regularity (HEALTH_V2 S2 §2.3).
//
// Four definitions existed: Rest's 1 − CV of durations (ignores timing), `SleepModel`'s onset SD, the
// streak's ±30 min, and the level's night-to-night drift. This file is the one the plan, the level's
// sleep part and the weekly review read. The Rest formula itself is untouched in 2.0.
//
//   · `wakeSdMin`, `onsetSdMin` — circular SD over the last 14 main sleeps, needs 7. The headline,
//     because it is directly actionable ("get up at the same time").
//   · `sri` — the Sleep Regularity Index (Phillips et al. 2017): −100 + 200 × P(same sleep/wake state at
//     t and t + 24 h), over minutes, from pairs of consecutive days that BOTH have ≥ 80 % wear coverage.
//     Needs 7 valid pairs. Shown as a trend only: published cut-points come from other devices and
//     populations, so none are shown.
//   · `socialJetlagMin` — |midsleep on Saturday/Sunday wake days − midsleep on weekday wake days|. Needs
//     2 free and 4 work nights.
//
// Absent ⇒ nil plus a typed reason. Pure and deterministic.

public enum SleepRegularity {

    public static let windowNights = 14
    public static let minNights = 7
    public static let sriWindowDays = 14
    public static let sriMinCoverage = 0.80
    public static let sriMinPairs = 7
    public static let jetlagMinFreeNights = 2
    public static let jetlagMinWorkNights = 4

    /// Why a figure is nil.
    public enum Reason: String, Equatable, Sendable {
        case tooFewNights
        case tooFewPairs
        case tooFewFreeNights
        case tooFewWorkNights
    }

    /// Everything at once, with the reasons for whatever is absent.
    public struct Result: Equatable, Sendable {
        public let wakeSdMin: Double?
        public let onsetSdMin: Double?
        public let sri: Double?
        public let socialJetlagMin: Double?
        public let nights: Int
        public let reasons: [Reason]
    }

    // MARK: - Timing spread

    /// Circular SD of wake times over the last 14 main sleeps; nil below 7.
    public static func wakeSdMin(_ nights: [SleepTimingNight]) -> Double? {
        let recent = SleepAnchor.recentNights(nights, window: windowNights)
        guard recent.count >= minNights else { return nil }
        return SleepClock.circularSD(recent.map(\.wakeMin))
    }

    /// Circular SD of onset times over the last 14 main sleeps; nil below 7.
    public static func onsetSdMin(_ nights: [SleepTimingNight]) -> Double? {
        let recent = SleepAnchor.recentNights(nights, window: windowNights)
        guard recent.count >= minNights else { return nil }
        return SleepClock.circularSD(recent.map(\.onsetMin))
    }

    // MARK: - Sleep Regularity Index

    /// One local day's minute-by-minute sleep state and how much of it the strap was worn for.
    public struct DayMinutes: Equatable, Sendable {
        /// `yyyy-MM-dd`.
        public let day: String
        /// One entry per minute of the local day from midnight, true = asleep. A DST day has 1380 or 1500.
        public let asleep: [Bool]
        /// Share of the day with heart-rate samples (the `NightCoverage` notion of wear), 0–1.
        public let coverage: Double

        public init(day: String, asleep: [Bool], coverage: Double) {
            self.day = day
            self.asleep = asleep
            self.coverage = coverage
        }
    }

    /// Build a day's minute states from sleep blocks given in minutes since that day's local midnight
    /// (a block may start before 0 or end after the day's length; it is clipped).
    public static func dayMinutes(day: String, minutesInDay: Int = SleepClock.minutesPerDay,
                                  sleepBlocks: [(start: Int, end: Int)], coverage: Double) -> DayMinutes {
        var states = [Bool](repeating: false, count: Swift.max(minutesInDay, 0))
        for b in sleepBlocks {
            let lo = Swift.max(0, b.start), hi = Swift.min(states.count, b.end)
            guard lo < hi else { continue }
            for i in lo..<hi { states[i] = true }
        }
        return DayMinutes(day: day, asleep: states, coverage: coverage)
    }

    /// The SRI over the last `sriWindowDays` days, or nil with fewer than `sriMinPairs` valid pairs.
    ///
    /// A pair is (d, d + 1 calendar day) with BOTH days at ≥ 80 % coverage; a low-coverage day breaks
    /// the two pairs it belongs to rather than being read as awake. Minute i of d is compared with minute
    /// i of d + 1 (the same clock minute: across a DST change that is 23 or 25 h, not 24 — the difference
    /// is one hour of one pair).
    public static func sri(_ days: [DayMinutes]) -> Double? {
        var byNumber: [Int: DayMinutes] = [:]
        for d in days {
            guard let n = SleepClock.dayNumber(d.day) else { continue }
            byNumber[n] = d
        }
        guard let newest = byNumber.keys.max() else { return nil }
        let oldestAllowed = newest - (sriWindowDays - 1)
        var same = 0, total = 0, pairs = 0
        for (n, a) in byNumber where n >= oldestAllowed {
            guard let b = byNumber[n + 1], a.coverage >= sriMinCoverage, b.coverage >= sriMinCoverage
            else { continue }
            let count = Swift.min(a.asleep.count, b.asleep.count)
            guard count > 0 else { continue }
            pairs += 1
            for i in 0..<count where a.asleep[i] == b.asleep[i] { same += 1 }
            total += count
        }
        guard pairs >= sriMinPairs, total > 0 else { return nil }
        return -100 + 200 * Double(same) / Double(total)
    }

    // MARK: - Social jet lag

    /// Mid-sleep of one night, minutes past midnight, in [0, 1440) — an onset before midnight and a
    /// wake after it (23:30 → 07:30) give 03:30, not 27:30.
    public static func midsleepMin(onsetMin: Int, wakeMin: Int) -> Double {
        let duration = SleepClock.wrap(wakeMin - onsetMin)
        let mid = Double(SleepClock.wrap(onsetMin)) + Double(duration) / 2
        return mid >= Double(SleepClock.minutesPerDay) ? mid - Double(SleepClock.minutesPerDay) : mid
    }

    /// |circular mean mid-sleep on Saturday/Sunday wake days − on weekday wake days|, or nil without 2
    /// free and 4 work nights in the last 14.
    public static func socialJetlagMin(_ nights: [SleepTimingNight]) -> Double? {
        let recent = SleepAnchor.recentNights(nights, window: windowNights)
        var free: [Int] = [], work: [Int] = []
        for n in recent {
            guard let wd = SleepClock.weekday(of: n.wakeDay) else { continue }
            let mid = Int(midsleepMin(onsetMin: n.onsetMin, wakeMin: n.wakeMin).rounded())
            if SleepClock.isWeekend(weekday: wd) { free.append(mid) } else { work.append(mid) }
        }
        guard free.count >= jetlagMinFreeNights, work.count >= jetlagMinWorkNights,
              let f = SleepClock.circularMean(free), let w = SleepClock.circularMean(work) else { return nil }
        return SleepClock.distance(f, w)
    }

    // MARK: - All of it

    public static func evaluate(nights: [SleepTimingNight], days: [DayMinutes] = []) -> Result {
        let wake = wakeSdMin(nights)
        let onset = onsetSdMin(nights)
        let index = sri(days)
        let jetlag = socialJetlagMin(nights)
        var reasons: [Reason] = []
        if wake == nil { reasons.append(.tooFewNights) }
        if index == nil { reasons.append(.tooFewPairs) }
        if jetlag == nil {
            let recent = SleepAnchor.recentNights(nights, window: windowNights)
            let freeCount = recent.filter {
                SleepClock.weekday(of: $0.wakeDay).map(SleepClock.isWeekend(weekday:)) ?? false
            }.count
            if freeCount < jetlagMinFreeNights { reasons.append(.tooFewFreeNights) }
            if recent.count - freeCount < jetlagMinWorkNights { reasons.append(.tooFewWorkNights) }
        }
        return Result(wakeSdMin: wake, onsetSdMin: onset, sri: index, socialJetlagMin: jetlag,
                      nights: SleepAnchor.recentNights(nights, window: windowNights).count, reasons: reasons)
    }

    /// "Wake time this week varied ±42 min" — the weekly line's wording, or nil without a figure.
    public static func wakeSpreadLine(_ sd: Double?) -> String? {
        guard let sd, sd.isFinite else { return nil }
        return "Wake time varied ±\(Int(sd.rounded())) min"
    }
}
