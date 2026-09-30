import XCTest
import StrandAnalytics
@testable import Strand

/// Telos 2.0 (SLEEP) — the "Tonight" card / evening panel place every step of the sleep anchor on its own
/// local day with the plan's clock-minute rule, in clock order, and light the first step still ahead.
final class TonightScheduleTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    /// Wake 07:00, need 8 h, no payback: lights out 22:45, wind-down 21:45.
    private func plan(anchor: Int = 7 * 60, need: Int = 480, payback: Int = 0) -> SleepSchedulePlan {
        SleepSchedulePlan(wakeWeekday: 5, anchorMin: anchor, anchorSource: .userTarget, weekendOffsetMin: 0,
                          needMin: need, needIsPopulationDefault: false, debtMin: nil, paybackMin: payback,
                          insomniaGuard: false, nightsUsed: 14, confidence: .solid,
                          bedtimeLeadMin: need + SleepAnchor.onsetBufferMin + payback)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testStepsLandOnTheirOwnDaysInClockOrder() {
        let p = plan()
        let wake = date(2026, 10, 1, 9, 0)
        let steps = TonightSchedule.steps(plan: p, wakeDate: wake, calendar: calendar)
        XCTAssertEqual(steps.map(\.kind), [.caffeine, .windDown, .lightsOut, .wake])

        XCTAssertEqual(steps[3].date, date(2026, 10, 1, 7, 0))
        XCTAssertEqual(steps[2].date, date(2026, 9, 30, 22, 45))
        XCTAssertEqual(steps[1].date, date(2026, 9, 30, 21, 45))

        let cutoff = CaffeineDecay.cutoffMinutesSinceMidnight(bedtimeMinutes: p.bedtimeMin)
        XCTAssertEqual(steps[0].date, date(2026, 9, 30, cutoff / 60, cutoff % 60))
    }

    func testAPastMidnightBedtimeStaysOnTheWakeDay() {
        // Wake 09:00 with a 7 h need: lights out 01:45 on the wake day itself.
        let p = plan(anchor: 9 * 60, need: 420)
        let steps = TonightSchedule.steps(plan: p, wakeDate: date(2026, 10, 1, 12, 0), calendar: calendar)
        let lightsOut = steps.first { $0.kind == .lightsOut }?.date
        XCTAssertEqual(lightsOut, date(2026, 10, 1, 1, 45))
    }

    func testNextIsTheFirstStepStillAhead() {
        let steps = TonightSchedule.steps(plan: plan(), wakeDate: date(2026, 10, 1, 9, 0), calendar: calendar)
        XCTAssertEqual(TonightSchedule.next(steps, now: date(2026, 9, 30, 22, 0)), .lightsOut)
        XCTAssertEqual(TonightSchedule.next(steps, now: date(2026, 9, 30, 23, 30)), .wake)
        XCTAssertNil(TonightSchedule.next(steps, now: date(2026, 10, 1, 7, 30)))
    }

    func testAsleepByIsLightsOutPlusTheOnsetBuffer() {
        let steps = TonightSchedule.steps(plan: plan(), wakeDate: date(2026, 10, 1, 9, 0), calendar: calendar)
        XCTAssertEqual(TonightSchedule.asleepBy(steps), date(2026, 9, 30, 23, 0))
    }

    func testPaybackMovesLightsOutEarlierNeverTheWake() {
        let steps = TonightSchedule.steps(plan: plan(payback: 20), wakeDate: date(2026, 10, 1, 9, 0),
                                          calendar: calendar)
        XCTAssertEqual(steps.first { $0.kind == .lightsOut }?.date, date(2026, 9, 30, 22, 25))
        XCTAssertEqual(steps.first { $0.kind == .wake }?.date, date(2026, 10, 1, 7, 0))
    }
}
