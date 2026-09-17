import Foundation
import WhoopStore

// Streaks.swift — how many days in a row a thing has held.
//
// Pure + deterministic so it is unit-testable without a strap or an app target, and so the output is
// byte-identical to the Android twin `com.noop.analytics.Streaks` (the cross-platform parity
// contract). Reads only `DailyMetric` fields that already live on-device, plus a caller-supplied map
// of banked stress minutes; no new egress.
//
// EVERY STREAK HERE IS COMPUTED FROM A MEASURED FIGURE, never from an intention. Regularity is the
// actual clock time of falling asleep and waking, night against night; debt is the rolling ledger;
// stress is the day's own stress score. A streak the app awards for
// opening the app would look identical on screen and mean nothing.
//
// A DAY WITH NO DATA BREAKS NOTHING AND EXTENDS NOTHING. The strap comes off, the phone dies, a sync
// fails. Counting a missing day as a failure punishes the wearer for the app's gaps; counting it as a
// success invents a day that was never measured. So it is skipped, and the streak spans it.

/// What a streak measures.
///
/// Four, and nothing else. Three are thresholds on figures the app computes from the body, and none of
/// those can be satisfied by using the app. The fourth is the journal, which is the opposite case and
/// earns its place for the opposite reason: it is the only one the app cannot see for itself.
///
/// A fifth would dilute the row. Four flames still fit across a thin strip; the moment they stop being
/// readable at a glance the strip has stopped doing its job, because a glance is the only way it is
/// ever read.
public enum StreakKind: String, Equatable, Codable, CaseIterable, Sendable {
    /// Went to sleep AND woke within half an hour of the night before.
    ///
    /// The raw value is still `sleepConsistency`: it is a persisted and cross-platform key, and the
    /// flame keeps its column. What it MEASURES changed — see `regularity`.
    case sleepConsistency
    /// Sleep DEBT under an hour, as the app's own debt figure states it for the day.
    case sleepDebt
    /// The day's stress score under 1 on the 0–3 scale. The raw value is still `stressTime` — a
    /// persisted key — though what it measures changed; see `stress`.
    case stressTime
    /// A day with something written in the journal.
    ///
    /// The one streak here that is not a threshold on a measured figure, and it earns its place for the
    /// opposite reason to the others: it is the only thing the app cannot see for itself. Everything
    /// else on this row is read off the body; this is the wearer telling it something.
    case journal
}

/// When one night began and ended, as minutes past local midnight.
///
/// Minutes of the day rather than instants, because the rule compares CLOCK TIMES across different
/// dates — and minute 1,430 (23:50) against minute 10 (00:10) is twenty minutes, which is what
/// `Streaks.clockDistance` measures the short way round.
public struct SleepTiming: Equatable, Sendable {
    public let onsetMinute: Int
    public let wakeMinute: Int

    public init(onsetMinute: Int, wakeMinute: Int) {
        self.onsetMinute = onsetMinute
        self.wakeMinute = wakeMinute
    }
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

    /// How far tonight's bedtime, and separately tomorrow's wake time, may drift from the night before
    /// and still hold the regularity streak. Half an hour, each way, on each end.
    public static let timingToleranceMin: Double = 30

    /// The shortest sleep that counts as a NIGHT for the regularity streak. Below this a block is a
    /// nap, and a nap's onset compared with a real bedtime would break the streak for sleeping twice.
    public static let minNightMinutes: Double = 3 * 60

    /// Debt below this holds the streak. An hour is a late film, not a deficit worth acting on.
    public static let debtLimitMin: Double = 60

    /// Nightly need the debt balance is measured against.
    ///
    /// The same seven hours the rest of the app treats as the adult floor. Held here rather than read
    /// from a profile because a personal need the wearer has never set would be a default wearing a
    /// personal label.
    public static let sleepNeedHours: Double = 7

    /// A day's stress score below this holds the streak, on the 0–3 scale the Stress screen shows.
    ///
    /// One is the top of the "low" band. The previous rule counted minutes of high stress against a
    /// six-hour budget, and it had no data at all: nothing ever wrote the minutes it read, so the flame
    /// could never light. The day's score is what every stress surface already computes and shows.
    public static let stressScoreLimit: Double = 1

    /// A year. Past this the number stops being motivating and starts being decoration.
    private static let maxLookbackDays = 365

    private static let minutesPerDay: Double = 1440


    /// Every streak worth showing, in a FIXED ORDER.
    ///
    /// - Parameters:
    ///   - days: recent days, oldest→newest, as the metrics cache returns them.
    ///   - stressScoreByDay: the day's stress score, 0–3, per local day (`yyyy-MM-dd`) — the same
    ///     figure the Stress screen shows for that day. A day with no score is unmeasured.
    ///   - sleepDebtMinByDay: the sleep debt that stood on each day, in minutes — the same figure the
    ///     Sleep screen shows, WHOOP's own where it exists. A day with no figure is unmeasured.
    ///   - journalDays: the local days that carry a journal entry. Its own input rather than a field on
    ///     `DailyMetric`, for the reason given on the journal walk below.
    ///   - sleepTimesByDay: when each night began and ended, keyed by the local day it ENDED on. Its own
    ///     input because `DailyMetric` carries how long a night was and not when it was.
    ///   - today: the local day being judged.
    ///
    /// Not sorted by length: the strip is four fixed columns and the wearer learns which flame is
    /// which by position. Re-ordering them as the numbers move would make the row unreadable at a
    /// glance, which is the only way it is ever read.
    public static func evaluate(
        days: [DailyMetric],
        stressScoreByDay: [String: Double] = [:],
        journalDays: Swift.Set<String> = [],
        sleepTimesByDay: [String: SleepTiming] = [:],
        sleepDebtMinByDay: [String: Double] = [:],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [Streak] {
        guard !days.isEmpty else { return [] }
        let todayKey = dayKey(today, calendar: calendar)
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        var index: [String: Int] = [:]
        for (i, d) in days.enumerated() { index[d.day] = i }

        return [
            regularity(byDay: byDay, sleepTimesByDay: sleepTimesByDay, todayKey: todayKey, calendar: calendar),
            debt(byDay: byDay, sleepDebtMinByDay: sleepDebtMinByDay, todayKey: todayKey, calendar: calendar),
            stress(byDay: byDay, stressScoreByDay: stressScoreByDay, todayKey: todayKey, calendar: calendar),
            journal(journalDays: journalDays, todayKey: todayKey, calendar: calendar),
        ]
    }

    /// A day with something written in it.
    ///
    /// Counted off the SET of days that carry an entry rather than off `days`, because a journal entry
    /// is not a strap reading: a day the wearer wrote on but wore nothing still counts, and a day with
    /// a strap reading and no entry is a genuine miss rather than an unmeasured gap. That is the one
    /// place this streak's rules differ from the three above it, and it is why it has its own walk.
    private static func journal(journalDays: Swift.Set<String>, todayKey: String,
                                calendar: Calendar) -> Streak {
        let todaySecured = journalDays.contains(todayKey)
        guard var cursor = calendar.date(from: dayComponents(todayKey, calendar: calendar)) else {
            return Streak(kind: .journal, days: 0, todaySecured: todaySecured)
        }
        // Today not being written yet is not a break — the day is not over. Same rule as every other
        // streak here.
        if !todaySecured {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        for _ in 0..<maxLookbackDays {
            guard journalDays.contains(dayKey(cursor, calendar: calendar)) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return Streak(kind: .journal, days: count, todaySecured: todaySecured)
    }

    /// Fell asleep AND woke within `timingToleranceMin` of the night before.
    ///
    /// WHY THIS REPLACED "CONSISTENCY > 80 %". That figure is one minus the spread of four weeks of
    /// sleep DURATIONS. It says nothing about WHEN: seven hours from 23:00 and seven hours from 03:00
    /// are perfectly "consistent" by it, and a single ragged week moves a four-week figure so little
    /// that the flame could not break when the wearer actually broke the habit. Nor could anyone act on
    /// it — "raise your coefficient of variation" is not a thing a person does at bedtime.
    ///
    /// Bedtime and wake time are. Both ends are held separately, because either one drifting is the
    /// habit going: in bed on time and up two hours late is not a regular night.
    ///
    /// Each day is judged against the CALENDAR day before, not the last night that happened to be
    /// recorded. A night with no timing on either side is unmeasured, which neither breaks nor extends —
    /// the same gap rule as every other streak here. Comparing across a gap would hold a two-night
    /// drift to a one-night tolerance.
    private static func regularity(
        byDay: [String: DailyMetric],
        sleepTimesByDay: [String: SleepTiming],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let tonight = sleepTimesByDay[metric.day],
                  let date = calendar.date(from: dayComponents(metric.day, calendar: calendar)),
                  let previousDate = calendar.date(byAdding: .day, value: -1, to: date),
                  let lastNight = sleepTimesByDay[dayKey(previousDate, calendar: calendar)]
            else { return nil }
            return clockDistance(tonight.onsetMinute, lastNight.onsetMinute) <= timingToleranceMin
                && clockDistance(tonight.wakeMinute, lastNight.wakeMinute) <= timingToleranceMin
        }
        return Streak(kind: .sleepConsistency, days: count, todaySecured: secured)
    }

    /// Sleep debt under an hour, as the debt figure stood ON each day.
    ///
    /// READ, NOT RECOMPUTED. This used to keep its own ledger: the fortnight's nights summed against a
    /// seven-hour need, surplus included. So a nine-hour night cancelled two six-hour ones, and the
    /// flame stayed lit through eleven days the Sleep screen — and WHOOP — both called over an hour of
    /// debt. The streak now reads the same per-day debt the Sleep screen draws (WHOOP's own where the
    /// cloud states it, the recency-weighted ledger where it does not), so the two cannot disagree.
    private static func debt(
        byDay: [String: DailyMetric],
        sleepDebtMinByDay: [String: Double],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let debt = sleepDebtMinByDay[metric.day] else { return nil }
            return debt < debtLimitMin
        }
        return Streak(kind: .sleepDebt, days: count, todaySecured: secured)
    }

    /// The day's stress score under 1.
    private static func stress(
        byDay: [String: DailyMetric],
        stressScoreByDay: [String: Double],
        todayKey: String,
        calendar: Calendar
    ) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let score = stressScoreByDay[metric.day] else { return nil }
            return score < stressScoreLimit
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
