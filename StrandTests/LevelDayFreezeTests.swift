import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The day's level is set at 06:40 and held. Two claims are pinned: which day is current at a given
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

    func testTheDayTurnsAtSixForty() {
        let before = LevelDayFreeze.levelDay(now: at(16, 6, 39), calendar: calendar)
        let after = LevelDayFreeze.levelDay(now: at(16, 6, 40), calendar: calendar)
        XCTAssertEqual(LevelWiring.key(from: before, calendar: calendar), "2026-09-15")
        XCTAssertEqual(LevelWiring.key(from: after, calendar: calendar), "2026-09-16")
    }

    func testAFrozenLevelRoundTripsExactly() {
        let breakdown = LevelBreakdown(
            components: [LevelComponent(part: .sleep, score: 71, effectiveWeight: 0.3),
                         LevelComponent(part: .lungs, score: nil, effectiveWeight: 0)],
            raw: 64.2, stepPenalty: 0.97, level: 62.3, coverage: 0.93)
        let frozen = FrozenLevel(day: "2026-09-16", breakdown: breakdown, drivers: [.sleep: .restorativeSleep])
        let data = try! JSONEncoder().encode(frozen)
        let back = try! JSONDecoder().decode(FrozenLevel.self, from: data)
        XCTAssertEqual(back, frozen)
        XCTAssertEqual(back.breakdown, breakdown)
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
        XCTAssertTrue(LevelWiring.nightLanded(days: days, day: "2026-09-16"))
        XCTAssertFalse(LevelWiring.nightLanded(days: days, day: "2026-09-17"))
    }

    func testTheMeditationShareIsNotResetByOneMissedDay() {
        var minutes: [String: Double] = [:]
        for d in 1...28 where d != 20 { minutes[String(format: "2026-09-%02d", d)] = 10 }
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: minutes)
        let share = LevelWiring.meditationShare("2026-09-28", series, calendar)
        XCTAssertGreaterThan(share, 0.9)
    }
}
