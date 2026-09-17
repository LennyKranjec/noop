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
        let frozen = FrozenLevel(day: "2026-09-16", breakdown: breakdown, drivers: [.sleep: .sleepScore])
        let data = try! JSONEncoder().encode(frozen)
        let back = try! JSONDecoder().decode(FrozenLevel.self, from: data)
        XCTAssertEqual(back, frozen)
        XCTAssertEqual(back.breakdown, breakdown)
    }

    func testTheFrozenDayReadsYesterdaysStepsNotThisMorningsPartialCount() {
        func row(_ day: String, steps: Int?, sleep: Double?) -> DailyMetric {
            DailyMetric(day: day, totalSleepMin: sleep, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: 55, avgHrv: 60, recovery: nil,
                        strain: nil, exerciseCount: nil, steps: steps)
        }
        let days = [row("2026-09-15", steps: 11_400, sleep: 420), row("2026-09-16", steps: 300, sleep: 450)]
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: ["2026-09-14": 10, "2026-09-15": 12, "2026-09-16": 30])
        let inputs = LevelWiring.dayInputs(days: days, day: "2026-09-16", series: series, calendar: calendar)
        XCTAssertEqual(inputs.stepsToday, 11_400)
        // The meditation run is also the previous complete day's: 10 + 12 minutes, not today's 30.
        XCTAssertEqual(inputs.meditationStreakMin, 22, accuracy: 1e-9)
        // The night is this morning's.
        XCTAssertEqual(inputs.hrv, 60)
        XCTAssertTrue(LevelWiring.nightLanded(days: days, day: "2026-09-16"))
        XCTAssertFalse(LevelWiring.nightLanded(days: days, day: "2026-09-17"))
    }
}
