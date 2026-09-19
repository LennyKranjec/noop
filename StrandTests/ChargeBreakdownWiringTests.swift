import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Swift twin of the Android `RecoveryDriversUiTest` wiring cases.
///
/// This suite could not exist before: the derivation lived as a private method inside `TodayView` (and a
/// byte-identical copy inside `CoupledView`), reachable only by rendering the view, so the iOS end of the
/// "What shaped it" path had no test at all while Android's did. `ChargeBreakdownWiring.breakdown` is that
/// derivation lifted out unchanged.
///
/// Case mapping against the Kotlin suite, stated so the gap is legible rather than implied:
///   * `rhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable` - twinned below.
///   * `coldStartHistoryProducesNoRows` - twinned below.
///   * `scoredDayProducesDriverRows` - twinned below, and it carries the confidence assertion too, since
///     this API returns the tier in the same tuple where Kotlin has a separate `chargeConfidenceTier`.
///   * `nullDayProducesNoRows` - deliberately NOT twinned. This API takes a non-optional row, so the
///     nil-row guard stays in the view where it belongs; there is nothing here to assert.
final class ChargeBreakdownWiringTests: XCTestCase {

    private func day(_ d: String, hrv: Double? = 55, rhr: Int? = 55, recovery: Double? = nil) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 450, efficiency: 0.9, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: nil,
                    exerciseCount: nil)
    }

    /// A history with no banked resting HR folds to `foldHistory`'s synthetic midpoint (about 75 bpm),
    /// which is nobody's resting HR, so the row must be absent. The HRV row still stands, since that
    /// baseline is real. The display day itself carries a reading, so this pins the BASELINE being
    /// unusable rather than the reading being missing.
    ///
    /// The gate is not in this file: `RecoveryScorer.chargeDrivers` applies it (#1990). This pins the end
    /// of the path, the surface a user actually sees.
    func testRhrRowIsAbsentWhenTheRestingHrBaselineIsNotUsable() {
        let history = (1...6).map { day(String(format: "2026-01-%02d", $0), rhr: nil) }
        let today = day("2026-01-07", rhr: 55)
        let out = ChargeBreakdownWiring.breakdown(days: history + [today], row: today, sleepPerfPercent: 85)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"),
                      "the HRV baseline is real, so its row must still be there: \(labels)")
        XCTAssertFalse(labels.contains("Resting heart rate"),
                       "no usable resting-HR baseline, so no RHR row: \(labels)")
    }

    /// Two nights only: the HRV baseline is not usable yet, so there are no honest drivers and the sheet
    /// hides rather than showing fabricated rows.
    func testColdStartHistoryProducesNoBreakdown() {
        let days = [day("2026-01-01"), day("2026-01-02")]
        XCTAssertNil(ChargeBreakdownWiring.breakdown(days: days, row: days[1], sleepPerfPercent: 85))
    }

    /// The usable-baseline half of the pair: a real history banks both baselines, so both rows appear and
    /// the surfaced tier is past calibrating.
    func testAScoredDayProducesDriverRowsAndATier() {
        let past = (1...10).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-20", hrv: 62, rhr: 51, recovery: 64)
        let out = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85)
        XCTAssertNotNil(out)
        let labels = (out?.drivers ?? []).map(\.label)
        XCTAssertTrue(labels.contains("Heart rate variability"), "\(labels)")
        XCTAssertTrue(labels.contains("Resting heart rate"), "\(labels)")
        XCTAssertNotEqual(out?.confidence, .calibrating)
    }

    /// E7: the breakdown honours the SAME recalibration epoch as the headline. A Recalibrate on 01-09
    /// leaves one night on or after it before 01-10, so the headline's HRV baseline is calibrating again —
    /// and the sheet must hide rather than score rows against the baseline the headline threw away.
    func testBreakdownHonoursTheHrvRecalibrationEpoch() {
        let past = (1...9).map { day(String(format: "2026-01-%02d", $0), hrv: 50 + Double($0 % 3)) }
        let today = day("2026-01-10", hrv: 62, rhr: 51, recovery: 64)
        let noEpoch = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85,
                                                      hrvEpoch: 0, recoveryEpoch: 0, respEraEpoch: 0)
        XCTAssertNotNil(noEpoch, "nine nights: usable without a recalibration")
        let jan9 = 1_767_916_800.0   // 2026-01-09T00:00:00Z
        let recalibrated = ChargeBreakdownWiring.breakdown(days: past + [today], row: today,
                                                           sleepPerfPercent: 85,
                                                           hrvEpoch: jan9, recoveryEpoch: jan9, respEraEpoch: 0)
        XCTAssertNil(recalibrated, "after the recalibration only one night counts: calibrating, no rows")
    }

    /// E6: the sheet scores its rows against the SAME exact ln(RMSSD) baseline the headline does — the
    /// history folded over `Baselines.lnHRV` with `Baselines.hrvLnCfg` — not the delta-method view of the
    /// ms fold. On a skewed history the two differ, so the rows must equal the ln-baseline scoring.
    func testBreakdownUsesTheExactLnHrvBaseline() {
        let hrvs: [Double] = [30, 32, 90, 35, 31, 88, 33, 34, 95, 36]
        let past = hrvs.enumerated().map { day(String(format: "2026-01-%02d", $0.offset + 1), hrv: $0.element) }
        let today = day("2026-01-20", hrv: 45, rhr: 52, recovery: 60)
        guard let out = ChargeBreakdownWiring.breakdown(days: past + [today], row: today, sleepPerfPercent: 85,
                                                        hrvEpoch: 0, recoveryEpoch: 0, respEraEpoch: 0) else {
            return XCTFail("a ten-night history must score")
        }
        let keys = past.map(\.day)
        func fold(_ values: [Double?], _ cfg: MetricCfg) -> BaselineState {
            Baselines.foldHistoryAsOf(values, dayKeys: keys, cfg: cfg, baselineEpoch: 0, asOf: [today.day])[today.day]
                ?? Baselines.foldHistory(values, cfg: cfg)
        }
        let hrvBase = fold(past.map(\.avgHrv), Baselines.hrvCfg)
        let rhrBase = fold(past.map { $0.restingHr.map(Double.init) }, Baselines.restingHRCfg)
        let expected = RecoveryScorer.chargeDrivers(
            hrv: 45, rhr: 52, resp: nil, hrvBaseline: hrvBase,
            rhrBaseline: rhrBase.usable ? rhrBase : nil, respBaseline: nil, sleepPerf: 0.85,
            skinTempDev: nil,
            hrvLnBaseline: fold(Baselines.lnHRV(past.map(\.avgHrv)), Baselines.hrvLnCfg))
        XCTAssertEqual(out.drivers, expected)
    }
}
