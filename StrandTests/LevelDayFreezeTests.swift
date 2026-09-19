import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The day's level is set when the morning flow runs and held. Two claims are pinned: which day is current at a given
/// minute, and that the frozen day reads a finished night plus the last COMPLETE day's activity — so a
/// morning with 300 steps does not lock the full step penalty in for twenty-four hours.
final class LevelDayFreezeTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private static let suite = "LevelDayFreezeTests"

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let d = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        d.removePersistentDomain(forName: Self.suite)
        return d
    }

    private func level(_ day: String) -> FrozenLevel {
        FrozenLevel(day: day,
                    breakdown: LevelBreakdown(components: [LevelComponent(part: .sleep, score: 60, effectiveWeight: 1)],
                                              raw: 60, stepPenalty: 1, level: 60, coverage: 1),
                    drivers: [:], computedAt: Date(timeIntervalSince1970: 1_789_000_000))
    }

    func testTheDayTurnsWhenTheMorningFlowRunsNotOnTheClock() throws {
        let d = try defaults()
        // Late morning, flow not yet run: still yesterday's level, and the morning is due.
        let before = LevelDayFreeze.levelDay(now: at(16, 11, 0), calendar: calendar, d)
        XCTAssertEqual(LevelWiring.key(from: before, calendar: calendar), "2026-09-15")
        XCTAssertTrue(LevelDayFreeze.morningDue(now: at(16, 11, 0), calendar: calendar, d))
        // An open at three in the morning is still the night before.
        XCTAssertFalse(LevelDayFreeze.morningDue(now: at(16, 3, 0), calendar: calendar, d))
        // The flow runs: today's level from here on, and the morning is no longer due.
        LevelDayFreeze.beginDay(now: at(16, 11, 0), calendar: calendar, d)
        let after = LevelDayFreeze.levelDay(now: at(16, 11, 1), calendar: calendar, d)
        XCTAssertEqual(LevelWiring.key(from: after, calendar: calendar), "2026-09-16")
        XCTAssertFalse(LevelDayFreeze.morningDue(now: at(16, 12, 0), calendar: calendar, d))
    }

    func testADayCannotBeginBeforeFourAndRemembersWhenItBegan() throws {
        let d = try defaults()
        // A flow put up in the small hours does not begin the day.
        LevelDayFreeze.beginDay(now: at(16, 3, 0), calendar: calendar, d)
        XCTAssertEqual(LevelWiring.key(from: LevelDayFreeze.levelDay(now: at(16, 3, 1), calendar: calendar, d),
                                       calendar: calendar), "2026-09-15")
        XCTAssertNil(LevelDayFreeze.beganAt("2026-09-16", d))
        // Begun at 08:00: the deadline counts from then, and a second begin the same day does not move it.
        LevelDayFreeze.beginDay(now: at(16, 8, 0), calendar: calendar, d)
        XCTAssertEqual(LevelDayFreeze.beganAt("2026-09-16", d), at(16, 8, 0))
        LevelDayFreeze.beginDay(now: at(16, 10, 0), calendar: calendar, d)
        XCTAssertEqual(LevelDayFreeze.beganAt("2026-09-16", d), at(16, 8, 0))
        // A flow presented at 23:59 whose work runs after midnight begins the day it was presented on.
        LevelDayFreeze.beginDay(now: at(17, 23, 59), calendar: calendar, d)
        XCTAssertEqual(LevelWiring.key(from: LevelDayFreeze.levelDay(now: at(17, 23, 59), calendar: calendar, d),
                                       calendar: calendar), "2026-09-17")
    }

    func testTheLevelIsPendingUntilTodaysEntryIsWrittenAfterTheMorningFlow() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        ledger.write(level("2026-09-15"))
        // Before the morning flow the level day is yesterday: its entry is written, but it is not this
        // morning's number.
        XCTAssertTrue(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(16, 9, 0), calendar: calendar, d))
        // The flow runs: today is the level day, and it is pending until its entry is written.
        LevelDayFreeze.beginDay(now: at(16, 9, 0), calendar: calendar, d)
        XCTAssertTrue(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(16, 9, 1), calendar: calendar, d))
        ledger.write(level("2026-09-16"))
        XCTAssertFalse(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(16, 9, 2), calendar: calendar, d))
        // After midnight, before the next flow: the level day is still the 16th, which is no longer today.
        XCTAssertTrue(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(17, 2, 0), calendar: calendar, d))
    }

    func testAFrozenLevelRoundTripsExactly() {
        let breakdown = LevelBreakdown(
            components: [LevelComponent(part: .sleep, score: 71, effectiveWeight: 0.3),
                         LevelComponent(part: .lungs, score: nil, effectiveWeight: 0)],
            raw: 64.2, stepPenalty: 0.97, level: 62.3, coverage: 0.93)
        let frozen = FrozenLevel(day: "2026-09-16", breakdown: breakdown, drivers: [.sleep: .restorativeSleep],
                                 missing: [.vo2max, .strength], partial: true, backfilled: false,
                                 computedAt: Date(timeIntervalSince1970: 1_789_000_000))
        let data = try! JSONEncoder().encode(frozen)
        let back = try! JSONDecoder().decode(FrozenLevel.self, from: data)
        XCTAssertEqual(back, frozen)
        XCTAssertEqual(back.breakdown, breakdown)
        XCTAssertEqual(back.missingInputs, [.vo2max, .strength])
        XCTAssertTrue(back.partial)
    }

    func testTheFrozenDayReadsTheLastCompleteDaysActivityAndThisMorningsNight() {
        func row(_ day: Int, steps: Int?, hrv: Double?) -> DailyMetric {
            DailyMetric(day: String(format: "2026-09-%02d", day), totalSleepMin: 450, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 55,
                        avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil, steps: steps)
        }
        // Eight days of 10,000 steps, then a morning with 300.
        var days = (8...15).map { row($0, steps: 10_000, hrv: 60) }
        days.append(row(16, steps: 300, hrv: 90))
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:])
        let inputs = LevelWiring.dayInputs(days: days, day: "2026-09-16", series: series, calendar: calendar)
        // The step average is the previous complete week's, not this morning's partial count.
        XCTAssertEqual(inputs.steps, 10_000)
        // The HRV mean includes this morning's night (seven days: six at 60, one at 90).
        XCTAssertEqual(inputs.hrv ?? 0, (6 * 60.0 + 90) / 7, accuracy: 1e-9)
        // A night with HRV, resting HR and sleep but no stages has not fully landed; no row at all has not either.
        let byDay = LevelWiring.byDay(days)
        XCTAssertFalse(LevelLedger.isReady(day: "2026-09-16", byDay: byDay, series: series, calendar: calendar))
        XCTAssertFalse(LevelLedger.isReady(day: "2026-09-17", byDay: byDay, series: series, calendar: calendar))
    }

    func testTheMeditationShareIsNotResetByOneMissedDay() {
        var minutes: [String: Double] = [:]
        for d in 1...28 where d != 20 { minutes[String(format: "2026-09-%02d", d)] = 10 }
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: minutes)
        let share = LevelWiring.meditationShare("2026-09-28", series, calendar)
        XCTAssertGreaterThan(share, 0.9)
    }
}
