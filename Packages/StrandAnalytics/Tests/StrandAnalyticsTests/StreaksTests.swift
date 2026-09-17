import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Parity pin for the streak counts. The same inputs MUST produce the same numbers as the Android
/// twin `com.noop.analytics.StreaksTest`. Cross-platform parity is the contract; if you change a
/// threshold or a counting rule here, change it there in the same PR.
///
/// WHAT MATTERS HERE IS THE GAP RULE. A day with no data neither breaks a streak nor extends it — the
/// strap comes off, a sync fails, the phone dies. Counting a missing day as a failure punishes the
/// wearer for the app's own gaps; counting it as a success invents a day nobody measured. Nearly every
/// bug this file could have is a variation on getting that wrong, so most of these are about absence.
///
/// The second thing is that TODAY IS NOT YET A FAILURE. A streak that reads zero every morning until
/// the day is secured is a streak that feels broken all day, so an unsatisfied today is simply not
/// counted, and `todaySecured` is what says whether it is banked.
final class StreaksTests: XCTestCase {

    /// A fixed calendar and a fixed "today" so the counts cannot drift with the wall clock or the
    /// machine's zone — the same reason the Kotlin twin runs under a pinned locale and timezone.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
    }

    private func key(_ daysAgo: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func day(_ daysAgo: Int, sleepMin: Double?) -> DailyMetric {
        DailyMetric(
            day: key(daysAgo),
            totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil, steps: nil
        )
    }

    /// `n` days ending today, oldest first, every night the same length.
    private func steady(_ n: Int, _ hours: Double) -> [DailyMetric] {
        (0..<n).reversed().map { day($0, sleepMin: hours * 60) }
    }

    private func of(_ streaks: [Streak], _ kind: StreakKind) -> Streak {
        streaks.first { $0.kind == kind }!
    }

    // MARK: - what is offered at all

    func testExactlyTheFourRulesAreOfferedAndAlwaysInTheSameOrder() {
        // The strip is four fixed columns and the wearer learns which flame is which by POSITION.
        // Sorting by length — which the previous cut did — makes the row unreadable at a glance, which
        // is the only way it is ever read.
        let expected: [StreakKind] = [.sleepConsistency, .sleepDebt, .stressTime, .journal]
        XCTAssertEqual(Streaks.evaluate(days: steady(30, 8), today: today, calendar: calendar).map(\.kind), expected)
        XCTAssertEqual(Streaks.evaluate(days: steady(3, 4), today: today, calendar: calendar).map(\.kind), expected)
    }

    func testNoDaysAtAllOffersNothing() {
        XCTAssertTrue(Streaks.evaluate(days: [], today: today, calendar: calendar).isEmpty)
    }

    // MARK: - bed and wake within 30 min of the night before

    private func timings(_ pairs: [(onset: Int, wake: Int)]) -> [String: SleepTiming] {
        // pairs[0] is today, pairs[1] yesterday, and so on back.
        var out: [String: SleepTiming] = [:]
        for (back, p) in pairs.enumerated() {
            out[key(back)] = SleepTiming(onsetMinute: p.onset, wakeMinute: p.wake)
        }
        return out
    }

    private func regularity(_ pairs: [(onset: Int, wake: Int)], days n: Int = 10) -> Streak {
        of(Streaks.evaluate(days: steady(n, 8), sleepTimesByDay: timings(pairs),
                            today: today, calendar: calendar), .sleepConsistency)
    }

    func testTheSameBedAndWakeTimeEveryNightHoldsTheStreak() {
        let s = regularity(Array(repeating: (onset: 23 * 60, wake: 7 * 60), count: 6))
        // Six nights of timing make five comparisons; the oldest has no night before it and is
        // unmeasured rather than a failure.
        XCTAssertEqual(s.days, 5)
        XCTAssertTrue(s.todaySecured)
    }

    func testThirtyMinutesEitherWayOnEitherEndStillHolds() {
        let s = regularity([(onset: 23 * 60 + 30, wake: 6 * 60 + 30), (onset: 23 * 60, wake: 7 * 60)])
        XCTAssertEqual(s.days, 1)
        XCTAssertTrue(s.todaySecured)
    }

    func testADriftOnOnlyOneEndBreaksIt() {
        // In bed on time and up two hours late is not a regular night — both ends are held.
        let lateWake = regularity([(onset: 23 * 60, wake: 9 * 60), (onset: 23 * 60, wake: 7 * 60)])
        XCTAssertEqual(lateWake.days, 0)
        XCTAssertFalse(lateWake.todaySecured)

        let lateBed = regularity([(onset: 0, wake: 7 * 60), (onset: 23 * 60, wake: 7 * 60)])
        XCTAssertEqual(lateBed.days, 0)
        XCTAssertFalse(lateBed.todaySecured)
    }

    func testMidnightIsTwentyMinutesFromTenToNotAWholeDay() {
        // 23:50 and 00:10 are twenty minutes apart. A naive difference makes it 1,420 and breaks the
        // streak of everybody whose bedtime sits near midnight.
        let s = regularity([(onset: 10, wake: 7 * 60), (onset: 23 * 60 + 50, wake: 7 * 60)])
        XCTAssertEqual(s.days, 1)
    }

    func testANightWithNoTimingIsUnmeasuredAndIsNotComparedAcrossTheGap() {
        // Yesterday has no timing. Today is not compared with the day before yesterday — a two-night
        // drift would otherwise be held to a one-night tolerance — so today is unmeasured, and the
        // streak behind the gap still counts.
        var t = timings([(onset: 23 * 60, wake: 7 * 60)])
        t[key(2)] = SleepTiming(onsetMinute: 23 * 60, wakeMinute: 7 * 60)
        t[key(3)] = SleepTiming(onsetMinute: 23 * 60, wakeMinute: 7 * 60)
        let s = of(Streaks.evaluate(days: steady(10, 8), sleepTimesByDay: t,
                                    today: today, calendar: calendar), .sleepConsistency)
        XCTAssertFalse(s.todaySecured)
        XCTAssertEqual(s.days, 1)
    }

    func testNoTimingsAtAllIsNoStreakRatherThanABrokenOne() {
        let s = of(Streaks.evaluate(days: steady(30, 8), today: today, calendar: calendar), .sleepConsistency)
        XCTAssertEqual(s.days, 0)
        XCTAssertFalse(s.todaySecured)
    }

    // MARK: - sleep debt < 1h

    private func debts(_ minutes: [Double]) -> [String: Double] {
        // minutes[0] is today, minutes[1] yesterday, and so on back.
        Dictionary(uniqueKeysWithValues: minutes.enumerated().map { (key($0.offset), $0.element) })
    }

    func testTheDebtStreakReadsTheDebtFigureItIsGiven() {
        let s = of(Streaks.evaluate(days: steady(10, 8), sleepDebtMinByDay: debts([20, 35, 0, 50]),
                                    today: today, calendar: calendar), .sleepDebt)
        XCTAssertEqual(s.days, 4)
        XCTAssertTrue(s.todaySecured)
    }

    func testElevenDaysOverAnHourHoldNothing() {
        // The reported bug: eleven days of more than an hour of debt, and the flame was lit. A long
        // night in the middle does not change what the debt figure SAYS for those days.
        let s = of(Streaks.evaluate(days: steady(12, 8), sleepDebtMinByDay: debts(Array(repeating: 95, count: 11)),
                                    today: today, calendar: calendar), .sleepDebt)
        XCTAssertEqual(s.days, 0)
        XCTAssertFalse(s.todaySecured)
    }

    func testExactlyAnHourOfDebtIsNotUnderAnHour() {
        let s = of(Streaks.evaluate(days: steady(4, 8), sleepDebtMinByDay: debts([60, 60]),
                                    today: today, calendar: calendar), .sleepDebt)
        XCTAssertEqual(s.days, 0)
    }

    func testADayWithNoDebtFigureIsUnmeasured() {
        var d = debts([10, 10])
        d[key(3)] = 15
        let s = of(Streaks.evaluate(days: steady(6, 8), sleepDebtMinByDay: d,
                                    today: today, calendar: calendar), .sleepDebt)
        XCTAssertEqual(s.days, 3, "day 2 has no figure and spans")
    }

    // MARK: - stress score under 1

    private func stress(_ scores: [Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: scores.enumerated().map { (key($0.offset), $0.element) })
    }

    func testCalmDaysHoldTheStressStreak() {
        let s = of(Streaks.evaluate(days: steady(10, 8), stressScoreByDay: stress(Array(repeating: 0.6, count: 10)),
                                    today: today, calendar: calendar), .stressTime)
        XCTAssertEqual(s.days, 10)
        XCTAssertTrue(s.todaySecured)
    }

    func testAScoreOfOneBreaksIt() {
        // "Under 1". One is the top of the low band, not inside it.
        let s = of(Streaks.evaluate(days: steady(10, 8), stressScoreByDay: stress([0.4, 0.9, 1.0, 0.2]),
                                    today: today, calendar: calendar), .stressTime)
        XCTAssertEqual(s.days, 2)
    }

    func testDaysWithNoStressScoreNeitherBreakNorExtend() {
        let s = of(Streaks.evaluate(days: steady(10, 8), stressScoreByDay: [key(0): 0.5, key(9): 0.5],
                                    today: today, calendar: calendar), .stressTime)
        XCTAssertEqual(s.days, 2)
        XCTAssertTrue(s.todaySecured)
    }

    // MARK: - today is not yet a failure

    func testAnUnsecuredTodayDoesNotBreakYesterdaysStreak() {
        var scores = stress(Array(repeating: 0.5, count: 6))
        scores[key(0)] = 2.4
        let s = of(Streaks.evaluate(days: steady(6, 8), stressScoreByDay: scores,
                                    today: today, calendar: calendar), .stressTime)
        XCTAssertEqual(s.days, 5)
        XCTAssertFalse(s.todaySecured, "today is not banked")
    }

    // MARK: - the journal

    func testTheJournalStreakCountsWrittenDaysAndSpansNothing() {
        // Unlike the three above it, a MISSING day here is a genuine miss rather than an unmeasured
        // gap: the wearer either wrote or did not, and the app always knows which.
        let days = steady(6, 8)
        let written: Swift.Set<String> = [key(0), key(1), key(2), key(4)]
        let s = of(Streaks.evaluate(days: days, journalDays: written, today: today, calendar: calendar),
                   .journal)
        XCTAssertEqual(s.days, 3, "the gap on day 3 ends it")
        XCTAssertTrue(s.todaySecured)
    }

    func testAnUnwrittenTodayDoesNotBreakTheJournalStreak() {
        let days = steady(6, 8)
        let written: Swift.Set<String> = [key(1), key(2), key(3)]
        let s = of(Streaks.evaluate(days: days, journalDays: written, today: today, calendar: calendar),
                   .journal)
        XCTAssertEqual(s.days, 3, "the day is not over")
        XCTAssertFalse(s.todaySecured)
    }

    // MARK: - midnight

    func testMidnightIsNotAWall() {
        // 23:50 = 1430, 00:10 = 10. Twenty minutes apart, not 1,420.
        XCTAssertEqual(Streaks.clockDistance(1430, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Streaks.clockDistance(10, 1430), 20, accuracy: 0.001)
        XCTAssertEqual(Streaks.clockDistance(600, 600), 0, accuracy: 0.001)
        // The furthest two clock times can be is twelve hours.
        XCTAssertEqual(Streaks.clockDistance(0, 720), 720, accuracy: 0.001)
    }
}
