import Foundation
import XCTest
@testable import StrandAnalytics
import WhoopStore

/// Parity pin for the streak counts. The same inputs MUST produce the same numbers as the Android
/// twin `com.noop.analytics.StreaksTest`. Cross-platform parity is the contract; if you change a
/// threshold or a counting rule here, change it there in the same PR.
///
/// Two rules carry the whole file, and both are the kind that are easy to get wrong in a way nobody
/// notices until a real user complains:
///
///   * A DAY WITH NO DATA neither breaks nor extends. The strap comes off; that is the app's gap, not
///     the user's failure, and it is also not a day that can be credited.
///   * MIDNIGHT IS NOT A WALL. 23:50 and 00:10 are twenty minutes apart. Get that wrong and the
///     regularity streak breaks nightly for exactly the people whose bedtime sits near midnight.
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

    private func metric(
        _ daysAgo: Int,
        sleepMin: Double? = nil,
        steps: Int? = nil,
        strain: Double? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: key(daysAgo),
            totalSleepMin: sleepMin, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: strain,
            exerciseCount: nil, steps: steps
        )
    }

    private func streak(_ kind: StreakKind, _ days: [DailyMetric], onsets: [String: Int] = [:]) -> Streak? {
        Streaks.evaluate(days: days, onsetByDay: onsets, today: today, calendar: calendar)
            .first { $0.kind == kind }
    }

    func testMidnightIsNotAWall() {
        // 23:50 = 1430, 00:10 = 10. Twenty minutes apart, not 1,420.
        XCTAssertEqual(Streaks.clockDistance(1430, 10), 20, accuracy: 0.001)
        XCTAssertEqual(Streaks.clockDistance(10, 1430), 20, accuracy: 0.001)
        XCTAssertEqual(Streaks.clockDistance(600, 600), 0, accuracy: 0.001)
        // The furthest two clock times can be is twelve hours.
        XCTAssertEqual(Streaks.clockDistance(0, 720), 720, accuracy: 0.001)
    }

    func testConsecutiveGoodNightsCount() {
        let days = (0...4).map { metric($0, sleepMin: 8 * 60) }
        let s = streak(.sleepDuration, days)
        XCTAssertEqual(s?.days, 5)
        XCTAssertEqual(s?.todaySecured, true)
    }

    func testAShortNightEndsIt() {
        let days = [
            metric(0, sleepMin: 8 * 60),
            metric(1, sleepMin: 8 * 60),
            metric(2, sleepMin: 5 * 60),   // the break
            metric(3, sleepMin: 8 * 60),
        ]
        XCTAssertEqual(streak(.sleepDuration, days)?.days, 2)
    }

    func testADayWithNoDataIsSpannedRatherThanCountedEitherWay() {
        let days = [
            metric(0, sleepMin: 8 * 60),
            metric(1),                      // strap was off: no reading at all
            metric(2, sleepMin: 8 * 60),
        ]
        // Two measured nights, and the gap between them did not reset the count.
        XCTAssertEqual(streak(.sleepDuration, days)?.days, 2)
    }

    func testTodayNotBeingDoneYetDoesNotReadAsABrokenStreak() {
        // At 09:00 nobody has hit their step count. A streak that reads zero every morning is one that
        // feels broken all day, so an unfinished today is excluded rather than failed.
        let days = [
            metric(0, steps: 200),
            metric(1, steps: 9_000),
            metric(2, steps: 9_000),
        ]
        let s = streak(.movement, days)
        XCTAssertEqual(s?.days, 2)
        // …but it is honest about today not being banked.
        XCTAssertEqual(s?.todaySecured, false)
    }

    func testAHardSessionCountsAsMovementEvenWithAlmostNoSteps() {
        // Two hours on a bike puts up no steps. A movement streak that breaks on a ride is one the
        // user stops believing.
        let days = [
            metric(0, steps: 400, strain: 15),
            metric(1, steps: 9_000),
        ]
        XCTAssertEqual(streak(.movement, days)?.days, 2)
    }

    func testRegularityIsMeasuredAgainstTheirOwnMedianBedtime() {
        let days = (0...4).map { metric($0, sleepMin: 7.5 * 60) }
        // A rock-solid 03:00 sleeper is REGULAR. Judging them against a bedtime someone else picked
        // would be the app imposing a lifestyle rather than reading one.
        let onsets = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 3 * 60) })
        XCTAssertEqual(streak(.sleepRegularity, days, onsets: onsets)?.days, 5)
    }

    func testRegularityIsNotOfferedWithoutEnoughNightsToHaveAUsualBedtime() {
        let days = (0...4).map { metric($0, sleepMin: 7.5 * 60) }
        // Two nights is not a habit. A zero would imply a rule was broken; absence is the honest state.
        let onsets = [days[0].day: 1380, days[1].day: 1380]
        XCTAssertNil(streak(.sleepRegularity, days, onsets: onsets))
    }

    func testAWildlyDifferentNightBreaksRegularity() {
        let days = (0...4).map { metric($0, sleepMin: 7.5 * 60) }
        var onsets = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 1380) })  // 23:00 every night
        onsets[days[2].day] = 240                                                    // except one 04:00
        XCTAssertEqual(streak(.sleepRegularity, days, onsets: onsets)?.days, 2)
    }

    func testNoDaysMeansNoStreaks() {
        XCTAssertTrue(Streaks.evaluate(days: [], today: today, calendar: calendar).isEmpty)
    }

    func testTiesKeepAStableOrderAcrossPlatforms() {
        // All three at zero. The order must match the Android twin's stable sort — regularity,
        // duration, movement — or the two platforms draw the flames in a different order.
        let days = (0...4).map { metric($0, sleepMin: 4 * 60, steps: 10) }
        let onsets = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 1380) })
        let kinds = Streaks.evaluate(days: days, onsetByDay: onsets, today: today, calendar: calendar)
            .map(\.kind)
        XCTAssertEqual(kinds, [.sleepRegularity, .sleepDuration, .movement])
    }
}
