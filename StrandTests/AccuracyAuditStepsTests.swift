import XCTest
import StrandAnalytics
@testable import Strand

/// Audit item 1 + 10: the strap's @57 counter total was presented as a MEASURED step count while the
/// divisor it is produced with (`ProfileStore.stepTicksPerStep`) was an uncalibrated default of 1.0 — raw
/// tick pass-through — with no "est." marker, no confidence, no calibrate affordance and, unlike the motion
/// estimate path, no upper clamp. On a strap whose motion counter overcounts ~24× per step (this repo's own
/// note in `Profile.swift`) 8 000 real steps rendered as 192 000, as a measurement.
@MainActor
final class AccuracyAuditStepsTests: XCTestCase {

    // MARK: - The honesty matrix (pure)

    /// THE BUG. A counter total with no calibration behind it is an estimate, not a measurement.
    func testUncalibratedCounterTotalIsNotAMeasurement() {
        let source = TodayView.stepsTileSource(strapCounter: 192_000, counterCalibrated: false,
                                               phoneSameDay: nil, motionEstimate: nil)
        XCTAssertEqual(source, .uncalibratedCounter(StepsEstimateEngine.maxDailySteps),
                       "raw ticks are an estimate, and clamped like every other step estimate")
        XCTAssertEqual(source?.isMeasured, false)
    }

    /// Once the divisor HAS been calibrated the counter total is what it always claimed to be.
    func testCalibratedCounterTotalIsAMeasurement() {
        let source = TodayView.stepsTileSource(strapCounter: 8_000, counterCalibrated: true,
                                               phoneSameDay: nil, motionEstimate: nil)
        XCTAssertEqual(source, .measured(8_000))
        XCTAssertEqual(source?.isMeasured, true)
    }

    /// A real phone-counted total outranks an unfitted counter total: a measurement beats an estimate.
    /// A CALIBRATED counter still wins, as it always did.
    func testPhoneCountOutranksAnUncalibratedCounterButNotACalibratedOne() {
        XCTAssertEqual(TodayView.stepsTileSource(strapCounter: 192_000, counterCalibrated: false,
                                                 phoneSameDay: 8_123, motionEstimate: nil),
                       .measured(8_123))
        XCTAssertEqual(TodayView.stepsTileSource(strapCounter: 8_000, counterCalibrated: true,
                                                 phoneSameDay: 8_123, motionEstimate: nil),
                       .measured(8_000))
    }

    /// The motion estimate is the last resort and keeps its own "est." framing.
    func testMotionEstimateIsUsedOnlyWhenNothingElseExists() {
        XCTAssertEqual(TodayView.stepsTileSource(strapCounter: nil, counterCalibrated: false,
                                                 phoneSameDay: nil, motionEstimate: 4_400),
                       .motionEstimate(4_400))
        XCTAssertNil(TodayView.stepsTileSource(strapCounter: nil, counterCalibrated: false,
                                               phoneSameDay: nil, motionEstimate: nil))
    }

    /// THE MISSING CLAMP. `StepsEstimateEngine` bounded its estimate at 60 000 and the counter path bounded
    /// nothing, so only one of the two step paths could render an impossible day. Both do now.
    func testBothStepPathsShareTheSixtyThousandClamp() {
        XCTAssertEqual(TodayView.clampDaySteps(192_000), StepsEstimateEngine.maxDailySteps)
        XCTAssertEqual(TodayView.clampDaySteps(-5), 0)
        XCTAssertEqual(TodayView.clampDaySteps(8_000), 8_000)
        for calibrated in [true, false] {
            let s = TodayView.stepsTileSource(strapCounter: 5_000_000, counterCalibrated: calibrated,
                                              phoneSameDay: nil, motionEstimate: nil)
            XCTAssertEqual(s?.steps, StepsEstimateEngine.maxDailySteps)
        }
        XCTAssertEqual(TodayView.stepsTileSource(strapCounter: nil, counterCalibrated: false,
                                                 phoneSameDay: nil, motionEstimate: 5_000_000)?.steps,
                       StepsEstimateEngine.maxDailySteps)
    }

    /// The uncalibrated counter gets the SAME shape the estimate path uses: an "est." marker and a
    /// confidence word, never a bare number.
    func testUncalibratedCounterCaptionCarriesEstAndAConfidence() {
        let caption = TodayView.uncalibratedCounterCaption
        XCTAssertTrue(caption.contains("est."), caption)
        XCTAssertTrue(caption.contains(StepsEstimateEngine.ConfidenceTier.low.word), caption)
        XCTAssertTrue(caption.contains("not calibrated"), caption)
    }

    // MARK: - The divisor is optional, and "never calibrated" is not written down

    /// A profile that has never calibrated the counter reports nil, and — critically — persists nothing, so
    /// "never calibrated" can never be mistaken for "calibrated to 1.0". Compute still divides by 1.0, so no
    /// stored day moves.
    func testFreshProfileHasNoCounterCalibrationAndPersistsNone() throws {
        try withStepScaleDefaults {
            let profile = ProfileStore()
            XCTAssertNil(profile.stepTicksPerStepCalibration)
            XCTAssertFalse(profile.stepCounterCalibrated)
            XCTAssertEqual(profile.stepTicksPerStep, ProfileStore.uncalibratedStepDivisor,
                           "the compute-layer divisor is unchanged: raw pass-through")
            XCTAssertNil(UserDefaults.standard.object(forKey: "profile.stepTicksPerStep"),
                         "init must not seed the key — a stored 1.0 would read as a calibration")
        }
    }

    /// Setting the divisor (the walk tile's Apply, or the Settings stepper) IS a calibration, and clearing it
    /// returns to the honest unset state rather than to "calibrated to 1.0".
    func testAssigningTheDivisorCalibratesAndClearingUncalibrates() throws {
        try withStepScaleDefaults {
            let profile = ProfileStore()
            profile.stepTicksPerStep = 24.0
            XCTAssertEqual(profile.stepTicksPerStepCalibration, 24.0)
            XCTAssertTrue(profile.stepCounterCalibrated)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "profile.stepTicksPerStep") as? Double, 24.0)

            profile.clearStepTicksPerStepCalibration()
            XCTAssertNil(profile.stepTicksPerStepCalibration)
            XCTAssertFalse(profile.stepCounterCalibrated)
            XCTAssertEqual(profile.stepTicksPerStep, ProfileStore.uncalibratedStepDivisor)
            XCTAssertNil(UserDefaults.standard.object(forKey: "profile.stepTicksPerStep"))
        }
    }

    /// A stored divisor still loads (and is still clamped), so an existing calibration survives.
    func testStoredDivisorLoadsAndIsClamped() throws {
        try withStepScaleDefaults {
            UserDefaults.standard.set(999.0, forKey: "profile.stepTicksPerStep")
            let profile = ProfileStore()
            XCTAssertEqual(profile.stepTicksPerStepCalibration, ProfileStore.stepScaleRange.upperBound)
            XCTAssertTrue(profile.stepCounterCalibrated)
        }
    }

    // MARK: - Item 10: the TEMPORARY walk tile

    /// Its own file header has called it TEMPORARY since it landed, yet it shipped visible, and because the
    /// dismissal lives in `@AppStorage` a reinstall brought it back. It is opt-in now.
    func testWalkCalibrationTileIsHiddenByDefault() {
        XCTAssertFalse(StepCalibrationTile.visibleDefault)
    }

    /// The footer's "not calibrated" branch rests on the uncalibrated counter reporting NO usable parameter:
    /// `estimatedSteps` refuses a non-positive one, which is what routes the read-out to the honest copy
    /// instead of printing raw ticks ÷ 1.00 as "steps (NOOP)".
    func testUncalibratedCounterHasNoUsableWalkParameter() {
        XCTAssertNil(StepCalibrationMath.estimatedSteps(kind: .counter, raw: 5_000, parameter: 0))
        XCTAssertEqual(StepCalibrationMath.estimatedSteps(kind: .counter, raw: 4_800, parameter: 24), 200)
    }

    // MARK: - Helpers

    /// Runs `body` with the step-scale key removed from the shared domain, restoring it afterwards.
    private func withStepScaleDefaults(_ body: () throws -> Void) throws {
        let d = UserDefaults.standard
        let key = "profile.stepTicksPerStep"
        let saved = d.object(forKey: key)
        defer {
            if let saved { d.set(saved, forKey: key) } else { d.removeObject(forKey: key) }
        }
        d.removeObject(forKey: key)
        try body()
    }
}
