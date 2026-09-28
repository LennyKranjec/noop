import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

@MainActor
final class DayCycleRecoveryTests: XCTestCase {
    private enum ReadFailure: Error { case injected }

    func testApplyingCycleStepsPreservesUnrelatedDailyColumns() {
        let daily = DailyMetric(
            day: "2026-09-04", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 10, activeKcalEst: nil, skinTempC: 34.2, sleepHrOnly: true)
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: [daily.day: 42], strainByWakeDay: [daily.day: 61],
            caloriesByWakeDay: [daily.day: 1_840], workoutCountByWakeDay: [daily.day: 2],
            onsetByWakeDay: [:], firstWakeDay: daily.day,
            markerUpdate: .preserve)

        let updated = DayCycleIntelligenceIntegration.applying(result, to: daily)

        XCTAssertEqual(updated.steps, 42)
        XCTAssertEqual(updated.strain, 61)
        XCTAssertEqual(updated.activeKcalEst, 1_840)
        XCTAssertEqual(updated.exerciseCount, 2)
        XCTAssertEqual(updated.skinTempC, 34.2)
        XCTAssertEqual(updated.sleepHrOnly, true)
    }

    /// The "my pulse syncs but my steps stopped" regression. `established` covers every day from the first
    /// resolved cycle onwards, but the per-day maps only carry the days the cycle loop produced a figure
    /// for — it skips a day with no main-sleep boundary, no owner segment or fewer than two counter samples.
    /// Reading the maps straight through wrote nil over a measured calendar-day total, and
    /// `upsertDailyMetrics` persists `steps = excluded.steps`, so the number was deleted from the row.
    func testApplyingKeepsCalendarDayFiguresForADayTheCycleEngineSkipped() {
        let daily = DailyMetric(
            day: "2026-09-05", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: 44, exerciseCount: 1, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 9_120, activeKcalEst: 2_100, skinTempC: nil, sleepHrOnly: true)
        // A cycle WAS established (an earlier day), but this day is absent from every map.
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: ["2026-09-04": 42], strainByWakeDay: [:], caloriesByWakeDay: [:],
            workoutCountByWakeDay: [:], onsetByWakeDay: [:], firstWakeDay: "2026-09-04",
            markerUpdate: .preserve)

        let updated = DayCycleIntelligenceIntegration.applying(result, to: daily)

        XCTAssertEqual(updated.steps, 9_120, "a skipped day must keep its measured calendar-day steps")
        XCTAssertEqual(updated.strain, 44)
        XCTAssertEqual(updated.activeKcalEst, 2_100)
        XCTAssertEqual(updated.exerciseCount, 1)
    }

    /// The substitution itself must still win wherever the cycle engine DID resolve a figure — including a
    /// cycle figure that is lower than the calendar-day one, which the `??` fallback must not swallow.
    func testApplyingStillPrefersTheCycleFigureOverTheCalendarDayOne() {
        let daily = DailyMetric(
            day: "2026-09-05", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: 44, exerciseCount: 3, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 9_120, activeKcalEst: 2_100, skinTempC: nil, sleepHrOnly: true)
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: [daily.day: 7_004], strainByWakeDay: [daily.day: 12],
            caloriesByWakeDay: [daily.day: 1_500], workoutCountByWakeDay: [daily.day: 0],
            onsetByWakeDay: [:], firstWakeDay: "2026-09-04", markerUpdate: .preserve)

        let updated = DayCycleIntelligenceIntegration.applying(result, to: daily)

        XCTAssertEqual(updated.steps, 7_004)
        XCTAssertEqual(updated.strain, 12)
        XCTAssertEqual(updated.activeKcalEst, 1_500)
        XCTAssertEqual(updated.exerciseCount, 0)
    }

    /// Before the first resolved cycle nothing is substituted, as before.
    func testApplyingLeavesDaysBeforeTheFirstCycleAlone() {
        let daily = DailyMetric(
            day: "2026-09-01", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
            steps: 5_000, activeKcalEst: nil, skinTempC: nil, sleepHrOnly: false)
        let result = DayCycleIntelligenceIntegration.Result(
            stepsByWakeDay: ["2026-09-04": 42], strainByWakeDay: [:], caloriesByWakeDay: [:],
            workoutCountByWakeDay: [:], onsetByWakeDay: [:], firstWakeDay: "2026-09-04",
            markerUpdate: .preserve)

        XCTAssertEqual(DayCycleIntelligenceIntegration.applying(result, to: daily).steps, 5_000)
    }

    func testBoundaryRecoveryPropagatesSessionReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
            // Expected: callers can distinguish an unread namespace from an authoritative empty one.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testBoundaryRecoveryPropagatesMarkerReadFailure() async {
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in [] },
            markers: { _, _, _ in throw ReadFailure.injected })

        do {
            _ = try await DayCycleIntelligenceIntegration.recover(
                candidates: [(owner: "strap", priority: 0)], reader: reader,
                claimedDays: [], windowStart: 1_700_000_000, now: 1_700_086_400,
                offsetSec: 0, habitualMidsleepSec: nil)
            XCTFail("expected recovery to fail closed")
        } catch ReadFailure.injected {
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testComputePreservesMarkersWhenRecoveryCannotBeRead() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = DayCycleIntelligenceIntegration.BoundaryRecoveryReader(
            sleepSessions: { _, _, _ in throw ReadFailure.injected },
            markers: { _, _, _ in XCTFail("marker read must not follow a failed session read"); return [] })

        let result = await DayCycleIntelligenceIntegration.compute(
            nights: [], editedRows: [], store: store,
            candidates: [(owner: "strap", priority: 0)],
            physiologyOwners: ["strap"], workouts: [],
            windowStart: 1_700_000_000, now: 1_700_086_400, offsetSec: 0,
            habitualMidsleepSec: nil, ticksPerStep: 1, mode: .sleepOnset,
            cache: DayCycleIntelligenceIntegration.Cache(), profile: UserProfile(),
            maxHROverride: nil, effortMethod: .edwards, recoveryReader: reader)

        guard case .preserve = result.markerUpdate else {
            return XCTFail("an unread marker namespace must never become an authoritative replacement")
        }
        XCTAssertTrue(result.stepsByWakeDay.isEmpty)
        XCTAssertTrue(result.onsetByWakeDay.isEmpty)
    }

    func testPass2SkinTempDeviationBeforeRecoveryScoring() throws {
        let daily = recoveryDailyFixture()
        let baselines = AnalyticsEngine.ProfileBaselines(
            hrv: recoveryBaseline(50, spread: 6), skinTemp: recoveryBaseline(34.5, spread: 0.4))
        let withoutSkin = expectedRecovery(daily, baselines: baselines, skinDev: nil)

        for (nightly, deviation) in [(34.804, 0.3), (34.196, -0.3)] {
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                daily, nightlySkinTempC: nightly, baselines: baselines)
            let expected = try XCTUnwrap(expectedRecovery(daily, baselines: baselines, skinDev: deviation))
            XCTAssertNotEqual(expected, withoutSkin)
            XCTAssertEqual(result.recovery, expected)
            XCTAssertEqual(result.skinTempDevC, deviation)
            XCTAssertEqual(result.skinTempC, nightly)
            // Undo only the three intended substitutions; every other daily field must survive.
            XCTAssertEqual(result.with(recovery: daily.recovery, skinTempDevC: daily.skinTempDevC,
                                       skinTempC: daily.skinTempC), daily)
        }
    }

    func testPass2MissingOrUnusableSkinBaselineClearsStaleDeviation() {
        let daily = recoveryDailyFixture().with(recovery: 99, skinTempDevC: 9, skinTempC: 36)
        let usable = recoveryBaseline(34.5, spread: 0.4)
        let cases: [(Double?, BaselineState?)] = [
            (nil, usable), (34.8, nil),
            (34.8, recoveryBaseline(34.5, spread: 0.4, status: .calibrating)),
            (34.8, recoveryBaseline(34.5, spread: 0.4, status: .stale))
        ]
        for (nightly, skinBaseline) in cases {
            let baselines = AnalyticsEngine.ProfileBaselines(
                hrv: recoveryBaseline(50, spread: 6), skinTemp: skinBaseline)
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                daily, nightlySkinTempC: nightly, baselines: baselines)
            XCTAssertNil(result.skinTempDevC)
            XCTAssertEqual(result.skinTempC, nightly)
            XCTAssertEqual(result.recovery, expectedRecovery(daily, baselines: baselines, skinDev: nil))
        }
    }

    func testPass2SkinTemperatureDoesNotBypassHrvColdStart() {
        let hrvBaselines: [BaselineState?] = [nil, recoveryBaseline(50, spread: 6, status: .calibrating)]
        for hrv in hrvBaselines {
            let result = IntelligenceEngine.recomputeRecoveryDaily(
                recoveryDailyFixture(), nightlySkinTempC: 34.8,
                baselines: AnalyticsEngine.ProfileBaselines(
                    hrv: hrv, skinTemp: recoveryBaseline(34.5, spread: 0.4)))
            XCTAssertNil(result.recovery)
            XCTAssertEqual(result.skinTempDevC, 0.3)
        }
    }

    private func recoveryBaseline(_ mean: Double, spread: Double,
                                  status: BaselineStatus = .trusted) -> BaselineState {
        BaselineState(baseline: mean, spread: spread,
                      nValid: status == .calibrating ? 3 : 14, nightsSinceUpdate: status == .stale ? 15 : 0,
                      status: status)
    }

    private func recoveryDailyFixture() -> DailyMetric {
        DailyMetric(day: "2026-09-09", totalSleepMin: 420, efficiency: 0.85,
                    deepMin: 80, remMin: 90, lightMin: 250, disturbances: 2,
                    restingHr: 58, avgHrv: 48, recovery: 99, strain: 61, exerciseCount: 2,
                    spo2Pct: 97, skinTempDevC: nil, respRateBpm: 15, steps: 42, activeKcalEst: 1_840,
                    spo2Red: 100, spo2Ir: 200, avgSdnn: 44, skinTempC: nil, sleepHrOnly: true)
    }

    private func expectedRecovery(_ daily: DailyMetric, baselines: AnalyticsEngine.ProfileBaselines,
                                  skinDev: Double?) -> Double? {
        RecoveryScorer.recovery(
            hrv: 48, rhr: 58, resp: 15, hrvBaseline: baselines.hrv!, rhrBaseline: nil,
            respBaseline: nil,
            sleepPerf: AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency,
            skinTempDev: skinDev)
    }
}
