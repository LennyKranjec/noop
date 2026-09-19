import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// F5 — one HRmax resolution for every Effort path (`StrainScorer.effortHRmax`), and
/// F7 — a robust observed HRmax from per-workout peaks (`StrainScorer.robustObservedHRmax`).
final class HRmaxResolutionTests: XCTestCase {

    // MARK: - F5

    func testOverrideWinsOverTanaka() {
        XCTAssertEqual(StrainScorer.effortHRmax(overrideBpm: 195, age: 40), 195)
    }

    func testZeroOrMissingOverrideFallsBackToTanaka() {
        // 0 is the Settings "Auto" value, not a real HRmax.
        XCTAssertEqual(StrainScorer.effortHRmax(overrideBpm: 0, age: 40), StrainScorer.tanakaHRmax(age: 40))
        XCTAssertEqual(StrainScorer.effortHRmax(overrideBpm: nil, age: 40), StrainScorer.tanakaHRmax(age: 40))
    }

    func testNoOverrideAndNoAgeIsNil() {
        XCTAssertNil(StrainScorer.effortHRmax(overrideBpm: nil, age: 0))
    }

    /// The live recompute and the daily pass now resolve the SAME HRmax, so the same HR scores the same
    /// Effort — `effectiveEffort`'s max can no longer pick whichever HRmax was kinder.
    func testLiveAndDailyResolutionScoreIdentically() {
        let hr = (0..<1200).map { HRSample(ts: 1_000 + $0, bpm: 160) }
        let override = 175.0
        let daily = StrainScorer.strain(hr, maxHR: StrainScorer.effortHRmax(overrideBpm: override, age: 30),
                                        restingHR: 55)
        let live = StrainScorer.strain(hr, maxHR: StrainScorer.effortHRmax(overrideBpm: override, age: 30),
                                       restingHR: 55)
        XCTAssertEqual(daily, live)
        let tanakaOnly = StrainScorer.strain(hr, maxHR: StrainScorer.tanakaHRmax(age: 30), restingHR: 55)
        XCTAssertNotEqual(daily, tanakaOnly, "the override must actually change the scored Effort")
    }

    // MARK: - F7

    func testRunnerUpPeakAcrossEnoughWorkouts() {
        // The single highest peak (a likely artefact) is discarded; the runner-up is the observed max.
        XCTAssertEqual(StrainScorer.robustObservedHRmax(workoutPeaks: [171, 185, 192, 178, 188, 166]), 188)
    }

    func testImplausiblePeaksAreIgnored() {
        // 240 (spike) and 90 (never left rest) are dropped before the count and the ranking.
        XCTAssertEqual(StrainScorer.robustObservedHRmax(workoutPeaks: [240, 90, 181, 176, 183, 170, 179]), 181)
    }

    func testTooFewWorkoutsIsNil() {
        XCTAssertNil(StrainScorer.robustObservedHRmax(workoutPeaks: [181, 176, 183, 170]))
        // Five raw values, but only four plausible ones.
        XCTAssertNil(StrainScorer.robustObservedHRmax(workoutPeaks: [181, 176, 183, 170, 230]))
    }

    /// The bug: a peak list never reaches `estimateHRmax`'s dense-history gate, so it answered Tanaka.
    func testEstimateHRmaxAloneCouldNotSeeAPeakList() {
        let peaks: [Double] = [171, 185, 192, 178, 188, 166]
        XCTAssertEqual(StrainScorer.estimateHRmax(peaks, age: 40).1, "tanaka")
        XCTAssertNotNil(StrainScorer.robustObservedHRmax(workoutPeaks: peaks))
    }
}
