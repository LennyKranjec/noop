import Foundation
import WhoopStore

// Streaks.swift — how many days in a row a habit has held.
//
// Pure + deterministic so it is unit-testable without a strap or an app target, and so the output is
// byte-identical to the Android twin `com.noop.analytics.Streaks` (the cross-platform parity
// contract). Reads only `DailyMetric` fields that already live on-device, plus a caller-supplied map
// of sleep onsets; no new egress.
//
// EVERY STREAK IS COMPUTED FROM A MEASURED FIGURE, never from an intention. "Bed on time" is the
// spread of actual sleep onsets, not a bedtime the user once typed in; "moved" is step counts. A
// streak awarded for opening the app would look identical on screen and mean nothing.
//
// A DAY WITH NO DATA BREAKS NOTHING AND EXTENDS NOTHING. The strap comes off, the phone dies, a sync
// fails. Counting a missing day as a failure punishes the user for the app's gaps; counting it as a
// success invents a day that was never measured. So it is skipped, and the streak spans it.

/// What a streak measures.
public enum StreakKind: String, Equatable, Codable, CaseIterable, Sendable {
    /// Falling asleep at a consistent hour. The single best predictor of how the rest reads.
    case sleepRegularity
    /// Seven hours or more, actually slept.
    case sleepDuration
    /// A day that involved moving.
    case movement
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

    /// Sleep onsets within this many minutes of the user's own median count as "on time".
    public static let regularityToleranceMin: Double = 60

    /// The duration bar, in hours. Not eight: eight is a slogan, seven is the floor most adults need.
    public static let durationTargetHours: Double = 7

    /// Steps that make a day count as moved. Low on purpose — this is a floor, not a goal.
    public static let movementTargetSteps: Int = 5_000

    /// A logged effort that counts as movement regardless of step count.
    private static let movementStrain: Double = 8

    /// A year. Past this the number stops being motivating and starts being decoration.
    private static let maxLookbackDays = 365

    private static let minutesPerDay: Double = 1440

    /// Three nights is the minimum from which "their usual bedtime" means anything.
    private static let minNightsForRegularity = 3

    /// Every streak worth showing, longest first.
    ///
    /// - Parameters:
    ///   - days: recent days, oldest→newest, as the metrics cache returns them.
    ///   - onsetByDay: sleep ONSET as minutes since midnight, keyed by the local day (`yyyy-MM-dd`)
    ///     the night is credited to. Not on `DailyMetric` — the schema stores durations, not
    ///     timestamps — so the caller reads it from the sleep sessions. Absent, the regularity streak
    ///     is not offered at all: an onset guessed from a duration would be a fabricated figure.
    ///   - today: the local day being judged.
    public static func evaluate(
        days: [DailyMetric],
        onsetByDay: [String: Int] = [:],
        today: Date = Date(),
        calendar: Calendar = .current
    ) -> [Streak] {
        guard !days.isEmpty else { return [] }
        let todayKey = dayKey(today, calendar: calendar)
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })

        var out: [Streak] = []
        if let regularity = regularity(byDay: byDay, onsetByDay: onsetByDay, todayKey: todayKey, calendar: calendar) {
            out.append(regularity)
        }
        out.append(duration(byDay: byDay, todayKey: todayKey, calendar: calendar))
        out.append(movement(byDay: byDay, todayKey: todayKey, calendar: calendar))
        // Sorted by length, and STABLY. Swift's `sorted(by:)` gives no stability guarantee while
        // Kotlin's `sortedByDescending` does, so ties are broken by the original index to keep the two
        // platforms in the same order — and to stop two equal-length streaks swapping places between
        // renders on this one.
        return out.enumerated()
            .sorted { lhs, rhs in
                lhs.element.days == rhs.element.days
                    ? lhs.offset < rhs.offset
                    : lhs.element.days > rhs.element.days
            }
            .map(\.element)
    }

    /// Bed at a consistent hour.
    ///
    /// Measured against the user's OWN median onset over the window, not a clock time someone else
    /// chose: a shift worker with a rock-solid 03:00 bedtime is regular, and telling them otherwise
    /// would be the app imposing a lifestyle rather than reading one.
    private static func regularity(
        byDay: [String: DailyMetric],
        onsetByDay: [String: Int],
        todayKey: String,
        calendar: Calendar
    ) -> Streak? {
        guard onsetByDay.count >= minNightsForRegularity else { return nil }
        let sorted = onsetByDay.values.sorted()
        let median = sorted[sorted.count / 2]
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let onset = onsetByDay[metric.day] else { return nil }
            return clockDistance(onset, median) <= regularityToleranceMin
        }
        return Streak(kind: .sleepRegularity, days: count, todaySecured: secured)
    }

    private static func duration(byDay: [String: DailyMetric], todayKey: String, calendar: Calendar) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            guard let minutes = metric.totalSleepMin else { return nil }
            return minutes / 60 >= durationTargetHours
        }
        return Streak(kind: .sleepDuration, days: count, todaySecured: secured)
    }

    private static func movement(byDay: [String: DailyMetric], todayKey: String, calendar: Calendar) -> Streak {
        let (count, secured) = countBack(byDay: byDay, todayKey: todayKey, calendar: calendar) { metric in
            // Steps OR a logged effort: a two-hour ride puts up almost no steps and is obviously not a
            // sedentary day, and a streak that says otherwise is one the user stops believing.
            let stepped = metric.steps.map { $0 >= movementTargetSteps }
            let trained = metric.strain.map { $0 >= movementStrain }
            if stepped == true || trained == true { return true }
            if stepped == nil && trained == nil { return nil }
            return false
        }
        return Streak(kind: .movement, days: count, todaySecured: secured)
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
    /// is most of them.
    public static func clockDistance(_ a: Int, _ b: Int) -> Double {
        let raw = Double(abs(a - b))
        return min(raw, minutesPerDay - raw)
    }

    // MARK: - Day keys
    //
    // `yyyy-MM-dd` in the user's own zone, matching the `day` column the metrics cache is keyed on.
    // Built with a fixed POSIX locale and an explicit format so the key cannot shift under a Gregorian
    // alternative calendar or a locale that formats dates differently — the same reason the Android
    // twin pins `Locale.US`.

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
