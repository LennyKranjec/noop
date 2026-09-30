import Foundation
import StrandAnalytics

// MeditationPractice.swift — the view-side shape of the meditation history (DESIGN_V2 coordinator
// decisions 10 + 12). PURE: built from the existing meditation log (`Repository.meditationMinutesByDay`,
// `meditationSessions`) and the set of days the wearer's data covers, so it can be tested with no store.
// No new storage, and no rule of its own:
//   • a day is DONE by `MeditationLog.isDayDone(minutes:day:)` — the date-effective minimum (5 min before
//     2026-09-29, 10 min from it) the level and the quest floor read;
//   • the ERA starts on the first day with logged minutes (`LevelEngine`'s era rule). Days before it are
//     "not tracked yet", never "missed";
//   • a MISSED day is in the era, covered by data (a day row exists) and under its minimum — exactly the
//     day the level's deduction counts (`LevelWiring.meditationMissedDays`). A day without data is "not
//     measured", never missed. Today stays OPEN until it is done.

enum MeditationDayState: Equatable, Sendable {
    /// Before the first logged session: the practice did not exist yet.
    case beforeEra
    /// Met that day's minimum.
    case done
    /// In the era, measured, under the minimum — the level deducts for it.
    case missed
    /// In the era but no day row — "not measured" is never "missed".
    case notMeasured
    /// Today, not done yet.
    case open
}

struct MeditationDay: Identifiable, Equatable, Sendable {
    let day: String
    let date: Date
    let minutes: Double
    /// The minimum in force THAT day.
    let minimum: Double
    let state: MeditationDayState
    var id: String { day }
}

struct MeditationWeek: Identifiable, Equatable, Sendable {
    /// Monday of the week.
    let start: Date
    let minutes: Double
    /// The sum of the minimums of the week's era days up to today (0 for a week wholly before the era).
    let minimumSum: Double
    let doneDays: Int
    let eraDays: Int
    var id: Date { start }
    var isBeforeEra: Bool { eraDays == 0 }
}

struct MeditationMonth: Identifiable, Equatable, Sendable {
    /// The first of the month.
    let first: Date
    /// Monday-first cells; nil = a leading blank before the 1st.
    let cells: [MeditationDay?]
    var id: Date { first }
}

struct MeditationPractice: Equatable, Sendable {
    static let windowDays = 28
    static let weekCount = 12

    let today: String
    let eraStart: String?
    /// The last 28 days, oldest first.
    let window: [MeditationDay]
    /// The last 12 Monday-first weeks, oldest first.
    let weeks: [MeditationWeek]
    let totalMinutes: Double
    let sessionCount: Int
    /// Done days in the last 28.
    let daysInWindow: Int
    let currentStreak: Int
    let bestStreak: Int
    let averageSessionMinutes: Double?
    let longestSessionMinutes: Double?
    /// Sessions started 05–11, 11–17, 17–22, 22–05 (local).
    let timeOfDay: [Int]
    /// Missed days in the level's 7-day window ending today (nil outside the era).
    let missedInLevelWindow: Int?
    let todayMinutes: Double
    let todayMinimum: Double
    /// Every era day, oldest first (for the month grids and the streaks).
    let eraDays: [MeditationDay]

    var hasSessions: Bool { sessionCount > 0 || totalMinutes > 0 }

    static func build(byDay: [String: Double],
                      sessions: [(start: Date, minutes: Double)],
                      measuredDays: Set<String>,
                      now: Date = Date(),
                      calendar: Calendar = .current,
                      dayKey: (Date) -> String = { Repository.localDayKey($0) }) -> MeditationPractice {
        let today = dayKey(now)
        let startOfToday = calendar.startOfDay(for: now)
        let eraStart = byDay.filter { $0.value > 0 }.keys.min()

        func day(_ date: Date) -> MeditationDay {
            let key = dayKey(date)
            let minutes = byDay[key] ?? 0
            let minimum = LevelEngine.meditationMinMinutes(on: key)
            let state: MeditationDayState
            if MeditationLog.isDayDone(minutes: minutes, day: key) {
                state = .done
            } else if eraStart == nil || key < (eraStart ?? key) {
                state = .beforeEra
            } else if key == today {
                state = .open
            } else if measuredDays.contains(key) {
                state = .missed
            } else {
                state = .notMeasured
            }
            return MeditationDay(day: key, date: date, minutes: minutes, minimum: minimum, state: state)
        }
        func back(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: startOfToday) ?? startOfToday }

        let window = (0..<windowDays).reversed().map { day(back($0)) }

        // The era, oldest first (bounded: the log is read over at most ~11 years).
        var era: [MeditationDay] = []
        if let eraStart, eraStart <= today {
            var n = 0
            var cursor = startOfToday
            while n < 4200 {
                let d = day(cursor)
                if d.day < eraStart { break }
                era.append(d)
                n += 1
                cursor = back(n)
            }
            era.reverse()
        }

        // Streaks: consecutive done days. Today still open does not break the current one.
        var best = 0
        var run = 0
        for d in era {
            if d.state == .done { run += 1; best = max(best, run) } else if d.state != .open { run = 0 }
        }
        var current = 0
        for d in era.reversed() {
            if d.state == .done { current += 1 } else if d.state == .open && d.day == today { continue } else { break }
        }

        // Weeks (Monday first).
        var mondayCal = calendar
        mondayCal.firstWeekday = 2
        let thisMonday = mondayCal.dateInterval(of: .weekOfYear, for: startOfToday)?.start ?? startOfToday
        var weeks: [MeditationWeek] = []
        for w in (0..<weekCount).reversed() {
            guard let monday = calendar.date(byAdding: .day, value: -7 * w, to: thisMonday) else { continue }
            var minutes: Double = 0
            var minimumSum: Double = 0
            var done = 0
            var eraCount = 0
            for i in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: i, to: monday), date <= startOfToday else { continue }
                let d = day(date)
                minutes += d.minutes
                if d.state != .beforeEra {
                    eraCount += 1
                    minimumSum += d.minimum
                    if d.state == .done { done += 1 }
                }
            }
            weeks.append(MeditationWeek(start: monday, minutes: minutes, minimumSum: minimumSum,
                                        doneDays: done, eraDays: eraCount))
        }

        // Sessions.
        let durations = sessions.map(\.minutes).filter { $0.isFinite && $0 > 0 }
        var buckets = [0, 0, 0, 0]
        for s in sessions {
            let h = calendar.component(.hour, from: s.start)
            switch h {
            case 5..<11: buckets[0] += 1
            case 11..<17: buckets[1] += 1
            case 17..<22: buckets[2] += 1
            default: buckets[3] += 1
            }
        }

        // The level's rule, over its own 7-day window ending today.
        var missed: Int? = nil
        if let eraStart {
            let keys = (0..<LevelEngine.meditationPenaltyWindowDays).map { dayKey(back($0)) }
            let eligible = keys.filter { $0 >= eraStart && measuredDays.contains($0) }
            if !eligible.isEmpty {
                missed = eligible.filter { !MeditationLog.isDayDone(minutes: byDay[$0] ?? 0, day: $0) }.count
            }
        }

        let todayMinutes = byDay[today] ?? 0
        return MeditationPractice(
            today: today,
            eraStart: eraStart,
            window: window,
            weeks: weeks,
            totalMinutes: byDay.values.filter { $0.isFinite }.reduce(0, +),
            sessionCount: sessions.count,
            daysInWindow: window.filter { $0.state == .done }.count,
            currentStreak: current,
            bestStreak: best,
            averageSessionMinutes: durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count),
            longestSessionMinutes: durations.max(),
            timeOfDay: buckets,
            missedInLevelWindow: missed,
            todayMinutes: todayMinutes,
            todayMinimum: LevelEngine.meditationMinMinutes(on: today),
            eraDays: era)
    }

    /// The era as Monday-first month grids, oldest month first.
    func months(calendar: Calendar = .current) -> [MeditationMonth] {
        guard let first = eraDays.first else { return [] }
        let byDay = Dictionary(eraDays.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [MeditationMonth] = []
        guard var month = calendar.dateInterval(of: .month, for: first.date)?.start,
              let last = eraDays.last?.date else { return [] }
        var guardCount = 0
        while month <= last, guardCount < 140 {
            guardCount += 1
            guard let range = calendar.range(of: .day, in: .month, for: month) else { break }
            // Leading blanks so the 1st sits under its weekday (Monday = column 0).
            let weekday = calendar.component(.weekday, from: month)   // 1 = Sunday
            let lead = (weekday + 5) % 7
            var cells: [MeditationDay?] = Array(repeating: nil, count: lead)
            for d in range {
                guard let date = calendar.date(byAdding: .day, value: d - 1, to: month) else { continue }
                let key = Repository.localDayKey(date)
                if let known = byDay[key] {
                    cells.append(known)
                } else if date > last {
                    cells.append(nil)
                } else {
                    cells.append(MeditationDay(day: key, date: date, minutes: 0,
                                               minimum: LevelEngine.meditationMinMinutes(on: key), state: .beforeEra))
                }
            }
            out.append(MeditationMonth(first: month, cells: cells))
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return out
    }
}
