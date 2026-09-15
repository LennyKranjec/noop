import Foundation
import WhoopStore

// Streaks.swift — how many days in a row a thing has held.
//
// Pure + deterministic so it is unit-testable without a strap or an app target, and so the output is
// byte-identical to the Android twin `com.noop.analytics.Streaks` (the cross-platform parity
// contract). Reads only `DailyMetric` fields that already live on-device, plus a caller-supplied map
// of banked stress minutes; no new egress.
//
// EVERY STREAK HERE IS COMPUTED FROM A MEASURED FIGURE, never from an intention. Consistency is the
// spread of actual sleep onsets over four weeks; debt is the rolling ledger; stress time is minutes
// the day read as autonomically loaded while the wearer was still. A streak the app awards for
// opening the app would look identical on screen and mean nothing.
//
// A DAY WITH NO DATA BREAKS NOTHING AND EXTENDS NOTHING. The strap comes off, the phone dies, a sync
// fails. Counting a missing day as a failure punishes the wearer for the app's gaps; counting it as a
// success invents a day that was never measured. So it is skipped, and the streak spans it.

/// What a streak measures.
///
/// Three, and nothing else. Each is a rule the wearer named, each is a threshold on a figure the app
/// already computes, and none can be satisfied by using the app. A fourth would dilute the row: three
/// flames fit across a thin strip, and three things are the most anybody actually holds in mind.
public enum StreakKind: String, Equatable, Codable, CaseIterable, Sendable {
    /// Sleep CONSISTENCY at or above 80 %: the spread of four weeks of nights, not one night.
    case sleepConsistency
    /// Sleep DEBT under an hour: the rolling ledger, not a single short night.
    case sleepDebt
    /// Under six hours of high stress that was NOT exercise.
    case stressTime
}

/// One streak: what it measures, how long it is running, and whether today is already secured.
public struct Streak: Equatable, Sendable {
    public let kind: StreakKind
    public let days: Int
    /// True when today's own reading already satisfies the rule — the flame is lit, not at risk.
    public let todaySecured: Bool

    public init(kind: StreakKind, days: Int, todaySecured: Bool) {
        self.kind = kind
        self.days = days
        self.todaySecured = todaySecured
    }
}

public enum Streaks {

    /// Consistency at or above this holds the streak, on the 0–100 scale `VitalityEngine` produces.
    public static let consistencyTargetPct: Double = 80

    /// How many nights the consistency figure is measured over. Four weeks, as everywhere else here.
    public static let consistencyWindowNights = 28

    /// Debt below this holds the streak. An hour is a late film, not a deficit worth acting on.
    public static let debtLimitMin: Double = 60

    /// Nightly need the debt balance is measured against.
    ///
    /// The same seven hours the rest of the app treats as the adult floor. Held here rather than read
    /// from a profile because a personal need the wearer has never set would be a default wearing a
    /// personal label.
    public static let sleepNeedHours: Double = 7

    /// High stress below this many minutes holds the streak.
    ///
    /// NON-ACTIVITY by construction, not by subtraction: `DaytimeStress` masks ambulatory hours as
    /// exertion and leaves them unscored, so the minutes counted here are already only the ones where
    /// the wearer was still and the autonomic load was high anyway. A hard session does not spend this
    /// budget, which is the whole point of the rule.
    public static let stressLimitMin: Double = 6 * 60

    /// A year. Past this the number stops being motivating and starts being decoration.
    private static let maxLookbackDays = 365

    private static let minutesPerDay: Double = 1440

    /// The fewest nights a rolling debt balance means anything over.
    private static let minNightsForDebt = 3

    /// Every streak worth showing, in a FIXED ORDER.
    ///
    /// - Parameters:
    ///   - days: recent days, oldest→newest, as the metrics cache returns them.
    ///   - stressMinutesByDay: minutes of NON-ACTIVITY high stress per local day (`yyyy-MM-dd`), as
    ///     the stress read banked them. Supplied rather than derived: the figure costs a whole day of
    ///     heart rate and R-R to compute, so recomputing it across a year of history inside a card is
    ///     not an option. A day with no banked row is unmeasured, which neither breaks nor extends.
    ///   - today: the local day being judged.
    ///
    /// Not sorted by length: the strip is three fixed columns and the wearer learns which flame is
    /// which by position. Re-ordering them as the numbers move would make the row unreadable at a
    /// glance, which is the only way it is ever read.
    public static func evaluate(
        days: [DailyMetric],
        stressMinutesByDay: [String: Double] = [:],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [Streak] {
        guard !days.isEmpty else { return [] }
        let todayKey = dayKey(today, calendar: calendar)
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        var index: [String: Int] = [:]
        for (i, d) in days.enumerated() { index[d.day] = i }

        return [
            consistency(days: days, index: index, byDay: byDay, todayKey: todayKey, calendar: calendar),
            debt(days: days, index: index, byDay: byDay, todayKey: todayKey, calendar: calendar),
            stressTime(byDay: byDay, stressMinutesByDay: stressMinutesByDay, todayKey: todayKey, calendar: calendar),
        ]
    }

    /// Sleep consistency at or above 80 %.
    ///
    /// The figure for a day is the spread of the `consistencyWindowNights` nights ENDING on it, which
    /// is how the level's own sleep term reads it — so the streak and the level cannot disagree about
    /// whether a stretch was regular. A day with too few nights behind it is unmeasured rather than a
    /// failure: consistency over two nights is not a number.
    private static func consistency(
        days: [DailyMetric],
        index: [String: Int],
        byDay: [String: DailyMetric],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let i = index[metric.day] else { return nil }
            let from = Swift.max(0, i - (consistencyWindowNights - 1))
            let window = days[from...i].compactMap { $0.totalSleepMin.map { $0 / 60 } }
            guard let c = VitalityEngine.sleepConsistency(nightlyHours: window) else { return nil }
            return c * 100 >= consistencyTargetPct
        }
        return Streak(kind: .sleepConsistency, days: count, todaySecured: secured)
    }

    /// Sleep debt under an hour.
    ///
    /// Read as the balance stood ON each day — the rolling shortfall of the fortnight before it, not
    /// today's balance applied backwards. A streak computed from one current figure would light or
    /// break every day at once, which is not a streak.
    ///
    /// Only the SHORTFALL counts. Surplus nights do not repay debt hour for hour in any model worth
    /// quoting, so a balance that nets positive reads as no debt rather than as credit.
    private static func debt(
        days: [DailyMetric],
        index: [String: Int],
        byDay: [String: DailyMetric],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let i = index[metric.day] else { return nil }
            let from = Swift.max(0, i - (SleepDebt.defaultWindowNights - 1))
            let slept = days[from...i].compactMap { night -> Double? in
                guard let m = night.totalSleepMin, m > 0 else { return nil }
                return m
            }
            guard slept.count >= minNightsForDebt else { return nil }
            let needMin = sleepNeedHours * 60
            let balance = slept.reduce(0) { $0 + ($1 - needMin) }
            return (balance < 0 ? -balance : 0) < debtLimitMin
        }
        return Streak(kind: .sleepDebt, days: count, todaySecured: secured)
    }

    /// Under six hours of high stress that was not exercise.
    private static func stressTime(
        byDay: [String: DailyMetric],
        stressMinutesByDay: [String: Double],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let minutes = stressMinutesByDay[metric.day] else { return nil }
            return minutes < stressLimitMin
        }
        return Streak(kind: .stressTime, days: count, todaySecured: secured)
    }

    /// Walk backwards from today counting days that satisfy `holds`, stopping at the first that does not.
    ///
    /// `holds` returns nil for "not measured", which neither breaks nor extends — see the note at the
    /// top of this file. Today itself is allowed to be unsatisfied without breaking the streak: the day
    /// is not over, and a streak that reads zero every morning until you have moved is a streak that
    /// feels broken all day. The returned flag is what says whether today is banked or still at risk.
    private static func countBack(
        byDay: [String: DailyMetric],
        todayKey: String,
        calendar: Calendar,
        holds: (DailyMetric) -> Bool?
    ) -> (Int, Bool) {
        let todaysVerdict = byDay[todayKey].flatMap(holds)
        guard var cursor = calendar.date(from: dayComponents(todayKey, calendar: calendar)) else {
            return (0, todaysVerdict == true)
        }
        // Start at today when today already qualifies, otherwise at yesterday: an unfinished day must
        // not be counted as a failure.
        if todaysVerdict != true {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        for _ in 0..<maxLookbackDays {
            let key = dayKey(cursor, calendar: calendar)
            switch byDay[key].flatMap(holds) {
            case .some(true): count += 1
            case .some(false): return (count, todaysVerdict == true)
            case .none: break  // unmeasured: span it
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (count, todaysVerdict == true)
    }

    /// Distance between two minute-of-day values, THE SHORT WAY ROUND THE CLOCK.
    ///
    /// 23:50 and 00:10 are twenty minutes apart, not 1,420. Every naive version of this gets that
    /// wrong, and it gets it wrong precisely for the people whose bedtime sits near midnight — which
    /// is most of them. Kept public because the sleep screens quote the same distance.
    public static func clockDistance(_ a: Int, _ b: Int) -> Double {
        let raw = Double(abs(a - b))
        return min(raw, minutesPerDay - raw)
    }

    // MARK: - Day keys
    //
    // `yyyy-MM-dd` in the wearer's own zone, matching the `day` column the metrics cache is keyed on.
    // Built with an explicit format so the key cannot shift under a Gregorian alternative calendar or
    // a locale that formats dates differently — the same reason the Android twin pins `Locale.US`.

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayComponents(_ key: String, calendar: Calendar) -> DateComponents {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        guard parts.count == 3 else { return c }
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        return c
    }
}
