import XCTest
import StrandAnalytics
@testable import Strand

/// Telos 2.0 logic follow-ups: the legacy inactivity buzz standing down for the sitting-break nudge, the
/// week review's sleep inputs from the sleep anchor, and untimed breathing days in the habit ledger.
@MainActor
final class TelosLogicFollowUpsTests: XCTestCase {

    // MARK: - One movement nudge, not two

    func testTheLegacyInactivityBuzzStandsDownOnlyWhileTheSittingNudgeCanFire() {
        XCTAssertTrue(StrapCueEngine.supersedesLegacyInactivityBuzz(sittingBreakEnabled: true, engineRunning: true,
                                                                    motionAccess: .authorized))
        // Nudge switched off: the legacy buzz behaves exactly as before.
        XCTAssertFalse(StrapCueEngine.supersedesLegacyInactivityBuzz(sittingBreakEnabled: false, engineRunning: true,
                                                                     motionAccess: .authorized))
        // Engine not running (macOS never starts it): nothing would nudge, so the legacy buzz keeps going.
        XCTAssertFalse(StrapCueEngine.supersedesLegacyInactivityBuzz(sittingBreakEnabled: true, engineRunning: false,
                                                                     motionAccess: .authorized))
        // Without Motion & Fitness the nudge abstains by design: the legacy buzz keeps going.
        for access in [MotionAccess.notDetermined, .denied, .restricted, .unavailable] {
            XCTAssertFalse(StrapCueEngine.supersedesLegacyInactivityBuzz(sittingBreakEnabled: true, engineRunning: true,
                                                                         motionAccess: access), "\(access)")
        }
    }

    // MARK: - Week review sleep inputs

    /// `count` nights ending on consecutive days up to 2026-09-28, oldest first; `wake(i)` for night i.
    private func nights(_ count: Int, wake: (Int) -> Int) -> [SleepTimingNight] {
        (0..<count).map { i in
            SleepTimingNight(wakeDay: HabitDay.adding(i - count + 1, to: "2026-09-28")!, onsetMin: 23 * 60,
                             wakeMin: wake(i), asleepMin: 450, efficiency: 0.9)
        }
    }

    func testWakeRegularityAbstainsBelowSevenNights() {
        let r = SleepScheduleProvider.wakeRegularity(nights(6) { _ in 7 * 60 })
        XCTAssertNil(r.wakeSdMin)
        XCTAssertNil(r.usualWakeMinute)
        XCTAssertNil(SleepScheduleProvider.wakeRegularity([]).wakeSdMin)
    }

    func testUsualWakeIsTheCircularMedianRoundedToFive() throws {
        let steady = SleepScheduleProvider.wakeRegularity(nights(7) { _ in 7 * 60 + 3 })
        XCTAssertEqual(try XCTUnwrap(steady.wakeSdMin), 0, accuracy: 1e-6)
        XCTAssertEqual(steady.usualWakeMinute, 7 * 60 + 5)

        let wakes = [412, 433, 420, 412, 420, 433, 420]
        let mixed = SleepScheduleProvider.wakeRegularity(nights(7) { wakes[$0] })
        XCTAssertEqual(mixed.usualWakeMinute, 7 * 60)
        XCTAssertGreaterThan(try XCTUnwrap(mixed.wakeSdMin), 0)
    }

    func testUsualWakeTakesTheShortWayRoundMidnight() {
        // 23:58 and 00:02: the usual wake is midnight, never noon.
        let r = SleepScheduleProvider.wakeRegularity(nights(7) { $0 % 2 == 0 ? 23 * 60 + 58 : 2 })
        XCTAssertEqual(r.usualWakeMinute, 0)
        XCTAssertLessThan(r.wakeSdMin ?? .infinity, 10)
    }

    func testAScatteredScheduleKeepsItsSpreadButHasNoUsualWake() throws {
        let wakes = [0, 240, 480, 720, 960, 1200, 360]
        let r = SleepScheduleProvider.wakeRegularity(nights(7) { wakes[$0] })
        XCTAssertGreaterThan(try XCTUnwrap(r.wakeSdMin), SleepAnchor.irregularWakeSdMin)
        XCTAssertNil(r.usualWakeMinute)
    }

    func testOnlyTheLastFourteenNightsCount() throws {
        // Six old nights at 10:00, then fourteen at 07:00.
        let r = SleepScheduleProvider.wakeRegularity(nights(20) { $0 < 6 ? 10 * 60 : 7 * 60 })
        XCTAssertEqual(try XCTUnwrap(r.wakeSdMin), 0, accuracy: 1e-6)
        XCTAssertEqual(r.usualWakeMinute, 7 * 60)
    }

    private func suite() -> UserDefaults {
        let name = "logicfollowups.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTheProviderHandsTheReviewMeasuredFiguresAndTheQuestBedtime() throws {
        let provider = SleepScheduleProvider(defaults: suite())
        provider.apply(nights: nights(10) { _ in 7 * 60 }, needHours: nil, debtMin: nil)
        let inputs = provider.weekReviewSleepInputs
        XCTAssertEqual(try XCTUnwrap(inputs.wakeSdMin), 0, accuracy: 1e-6)
        XCTAssertEqual(inputs.typicalWakeMinute, 7 * 60)
        // The weekday asleep-by: the same figure the bedtime quest is judged against.
        let monday = try XCTUnwrap(provider.plans[2])
        XCTAssertEqual(inputs.bedtimeTargetMinute, monday.asleepByMin)

        // A target wake alone makes a plan (so a bedtime target) but is never reported as a measurement.
        let fresh = SleepScheduleProvider(defaults: suite())
        fresh.apply(nights: nights(3) { _ in 7 * 60 }, needHours: nil, debtMin: nil)
        XCTAssertNil(fresh.weekReviewSleepInputs.bedtimeTargetMinute, "calibrating: no plan, no target")
        fresh.targetWakeMinutes = 6 * 60 + 30
        let targeted = fresh.weekReviewSleepInputs
        XCTAssertNil(targeted.wakeSdMin)
        XCTAssertNil(targeted.typicalWakeMinute)
        XCTAssertNotNil(targeted.bedtimeTargetMinute)
    }

    // MARK: - Untimed breathing days

    func testUntimedBreathDaysAreOnlyPositiveRowsTheJsonLogCannotSee() {
        let series: [(day: String, value: Double)] = [("2026-09-20", 10), ("2026-09-21", 0), ("2026-09-22", .nan),
                                                      ("2026-09-23", 6)]
        let untimed = HabitLedgerSource.untimedBreathMinutes(series: series, timedDays: ["2026-09-23"])
        XCTAssertEqual(untimed, ["2026-09-20": 10])
    }

    func testAnUntimedDayCountsAsActiveOnlyWhenWhollyInsideTheWindow() {
        let evening = "2026-09-28"
        XCTAssertTrue(HabitLedgerSource.untimedBreathActive(["2026-09-27": 5], evening: evening))
        XCTAssertTrue(HabitLedgerSource.untimedBreathActive(["2026-09-15": 5], evening: evening), "evening - 13")
        XCTAssertFalse(HabitLedgerSource.untimedBreathActive(["2026-09-14": 5], evening: evening),
                       "evening - 14 may have ended before its 17:00")
        XCTAssertFalse(HabitLedgerSource.untimedBreathActive([evening: 5], evening: evening),
                       "the evening's own day may be after 17:00")
        XCTAssertFalse(HabitLedgerSource.untimedBreathActive([:], evening: evening))
    }

    func testAnUntimedDayWithdrawsANoItCouldHaveCoveredButNeverMakesAYes() {
        let evening = "2026-09-27", wake = "2026-09-28"
        XCTAssertTrue(HabitLedgerSource.untimedBreathMayCoverNight([evening: 10], evening: evening, wakeDay: wake,
                                                                   onsetAfterMidnight: false))
        XCTAssertFalse(HabitLedgerSource.untimedBreathMayCoverNight([evening: 4], evening: evening, wakeDay: wake,
                                                                    onsetAfterMidnight: false),
                       "under five minutes cannot hold a qualifying session")
        // The wake day only matters when the evening window ran past midnight.
        XCTAssertFalse(HabitLedgerSource.untimedBreathMayCoverNight([wake: 10], evening: evening, wakeDay: wake,
                                                                    onsetAfterMidnight: false))
        XCTAssertTrue(HabitLedgerSource.untimedBreathMayCoverNight([wake: 10], evening: evening, wakeDay: wake,
                                                                   onsetAfterMidnight: true))
    }
}
