import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Accuracy audit: the daily Stress score and the banked daytime-calm figure must abstain rather than
/// present the shape of an empty baseline as a reading.
///
/// Two separate bugs with one cause — a guard that checked whether a mean EXISTED rather than whether it
/// was a baseline:
///   * `StressMath.std` returns 0 for n <= 1 and `rawScore` DROPS a term whose spread is ~0, so one
///     baseline night dropped both terms and `squash(0)` = exactly 1.5 was shown as "1.5 MEDIUM" under a
///     "vs 30-day baseline" header. Two nights kept the (then population-divisor) σ so small that a
///     3 bpm move saturated the other end of the curve to HIGH.
///   * `bankDaytimeRmssd` persisted a day's "daytime calm" from a single hour of R-R, a quantity the
///     scoring path holds out of the live score entirely because it is artefact-dominated.
final class StressBaselineHonestyTests: XCTestCase {

    private func day(_ d: String, rhr: Int?, hrv: Double?) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    // MARK: - The daily score

    func testOneBaselineNightDoesNotReadAsAConfidentMedium() {
        // The audit's first case: with a single baseline night both z terms drop out and `squash(0)` is
        // exactly 1.5 — the midpoint of the 0–3 curve, shown as "1.5 MEDIUM". The old gate passed
        // because `meanRHR != nil`, which one night satisfies.
        let days = [day("2026-07-01", rhr: 58, hrv: 60),
                    day("2026-07-02", rhr: 62, hrv: 50)]
        XCTAssertNil(StressModel(days: days, stored: []),
                     "one baseline night is not a baseline — abstain, don't hand back the midpoint")
    }

    func testTwoBaselineNightsDoNotSaturateToHigh() {
        // The audit's second case: baseline 58, 59 → mean 58.5, and today's 62 came out at z ≈ 7, so
        // `squash` saturated to ~2.997 HIGH with the copy "Resting heart rate is running high versus
        // your norm" — a norm built from two nights.
        let days = [day("2026-07-01", rhr: 58, hrv: nil),
                    day("2026-07-02", rhr: 59, hrv: nil),
                    day("2026-07-03", rhr: 62, hrv: nil)]
        XCTAssertNil(StressModel(days: days, stored: []),
                     "two nights cannot put today at the top of the curve")
    }

    func testEnoughNightsWithRealSpreadStillScore() {
        // The gate is a minimum, not a new silence: at `Baselines.minNightsSeed` baseline nights with a
        // genuine spread the score comes back, and it is a real reading rather than the midpoint.
        var days = (1...Baselines.minNightsSeed).map {
            day(String(format: "2026-07-%02d", $0), rhr: 56 + $0 % 3, hrv: nil)
        }
        days.append(day("2026-07-20", rhr: 70, hrv: nil))
        let model = StressModel(days: days, stored: [])
        XCTAssertNotNil(model)
        XCTAssertGreaterThan(model?.score ?? 0, 1.5, "a genuinely elevated RHR should read above neutral")
        XCTAssertNotNil(model?.rhrDelta, "with a real baseline the marker delta is honest to show")
    }

    func testFlatBaselineWithEnoughNightsStillAbstains() {
        // BOTH halves of the gate are load-bearing. Four identical nights clear the night count but
        // have no spread, so `rawScore` drops the term and `squash(0)` is the midpoint again.
        var days = (1...Baselines.minNightsSeed).map {
            day(String(format: "2026-07-%02d", $0), rhr: 58, hrv: nil)
        }
        days.append(day("2026-07-20", rhr: 70, hrv: nil))
        XCTAssertNil(StressModel(days: days, stored: []),
                     "a zero-spread baseline divides nothing — abstain")
    }

    func testThinBaselineAlsoWithholdsTheVsBaselineDelta() {
        // "+4 vs 30-day baseline" needs a 30-day baseline. A stored value still scores the day, but the
        // marker tiles (and `explanation`, which quotes the delta back) must not label a two-night mean
        // a baseline.
        let days = [day("2026-07-01", rhr: 58, hrv: 60),
                    day("2026-07-02", rhr: 62, hrv: 50)]
        let model = StressModel(days: days, stored: [(day: "2026-07-02", value: 2.5)])
        XCTAssertEqual(model?.score ?? -1, 2.5, accuracy: 1e-9, "a stored value is still honoured")
        XCTAssertNil(model?.rhrDelta)
        XCTAssertNil(model?.hrvDelta)
    }

    func testThinBaselineDoesNotChartAFlatMidpointTrend() {
        // The same weak gate governed the trend line, so every charted day fell to `squash(0)` = 1.5 —
        // a flat fabricated line the eye reads as "consistently moderate".
        let days = [day("2026-07-01", rhr: 58, hrv: 60),
                    day("2026-07-02", rhr: 62, hrv: 50)]
        let model = StressModel(days: days, stored: [(day: "2026-07-02", value: 2.5)])
        XCTAssertEqual(model?.fullTrend.map(\.value), [2.5],
                       "only the stored day may be charted without a usable baseline")
    }

    // MARK: - StressMath.std

    func testStdUsesTheSampleDivisorItsGuardImplies() {
        // ddof = 1, pairing with the `count > 1` guard and matching every other spread estimator in the
        // tree. The population divisor understated σ by 30 % at n = 2 and inflated z by 1.41×, which is
        // what carried 58/59/62 to the top of the curve above.
        XCTAssertEqual(StressMath.std([58, 62], mean: 60), 2.828427, accuracy: 1e-6)
        XCTAssertEqual(StressMath.std([58, 59, 62], mean: 59.0 + 2.0 / 3.0), 2.081666, accuracy: 1e-5)
        XCTAssertEqual(StressMath.std([60], mean: 60), 0, accuracy: 1e-12)
        XCTAssertEqual(StressMath.std([], mean: nil), 0, accuracy: 1e-12)
        // Its twin `DaytimeStress.std` carries the identical change and is pinned on the same literals
        // from inside the analytics package (`DaytimeStressTests`), which is the only target that can
        // see it — so the hourly and daily lenses cannot drift apart on the divisor.
    }

    // MARK: - Banking the day's daytime calm

    private func hour(_ h: Int, rmssd: Double?, scored: Bool = true) -> DaytimeStress.HourPoint {
        DaytimeStress.HourPoint(hour: h, startTs: h * 3_600, level: scored ? 1.0 : nil,
                                meanHR: 62, rmssd: rmssd)
    }

    func testDaytimeRmssdIsNotBankedFromOneOrTwoHours() {
        // `!values.isEmpty` was the only guard, so ONE hour — as little as twenty clean beats — was
        // persisted as the whole day's daytime calm and read back by the level's focus part as if it
        // were the day. The scoring path treats the same quantity as artefact-dominated.
        XCTAssertNil(StressDailyLog.daytimeRmssdMean(hours: [hour(9, rmssd: 120)]))
        XCTAssertNil(StressDailyLog.daytimeRmssdMean(hours: (9...11).map { hour($0, rmssd: 40) }),
                     "three hours is still under the gate the fold applies to the same quantity")
        XCTAssertNil(StressDailyLog.daytimeRmssdMean(hours: []))
    }

    func testDaytimeRmssdBanksOverStillScoredHoursOnly() {
        // At the gate it banks, and only over hours that were both SCORED (not masked as exertion, not
        // unscored) and actually carried R-R.
        let day = (9...12).map { hour($0, rmssd: 40) }
            + [hour(13, rmssd: nil),                      // scored, no R-R
               hour(14, rmssd: 999, scored: false)]       // masked/unscored — must not count
        XCTAssertEqual(StressDailyLog.daytimeRmssdMean(hours: day) ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(StressDailyLog.minRmssdHours, Baselines.minNightsSeed,
                       "the banking gate is the fold's gate, not a second number")
    }
}
