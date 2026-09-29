import XCTest
@testable import StrandAnalytics

/// Audit item 5 (the analytics half): `VO2MaxEstimator.hrRatio` — Uth 2004, `15.3 · HRmax / RHR` — had no
/// plausibility clamp, unlike both of its siblings (`fromSession` and `activityModel` each refuse a result
/// outside 15…90). It is monotone in a single measured number, so a low resting HR walked the answer straight
/// off the human scale: a waking RHR of 26 bpm passes the `> 25` guard and yields a figure well past 90, and
/// 30 bpm yields 76.5 for a wearer who has recorded no exercise at all.
final class VO2MaxPlausibilityTests: XCTestCase {

    /// THE BUG. A resting HR just past the guard produced an impossible VO₂max and returned it.
    func testHrRatioRefusesAnImplausiblyHighResult() {
        let hrMax = 187.0   // Tanaka at age 30
        let raw = 15.3 * hrMax / 26.0
        XCTAssertGreaterThan(raw, VO2MaxEstimator.plausible.upperBound,
                             "the fixture reproduces the report: the formula's own answer is off the scale")
        XCTAssertNil(VO2MaxEstimator.hrRatio(restingHr: 26, hrMax: hrMax))
    }

    /// The LOWER bound is unreachable here, and that is worth pinning rather than faking.
    ///
    /// `15.3 · HRmax / RHR` is below 15 only when `HRmax / RHR < 0.98`, i.e. only when HRmax is BELOW the
    /// resting HR — which the guard above already refuses. So the clamp's floor can never fire on this
    /// estimator, and the smallest value it can return is just over 15.3. The first version of this test
    /// asserted nil for `(200, 220)` from a comment that had divided by 120 instead of 220; the estimator
    /// was right to return 16.83. Kept as a boundary test so the floor is not "fixed" into rejecting real
    /// low-fitness readings.
    func testHrRatioFloorIsStructurallyUnreachableSoALowReadingStillEstimates() throws {
        let v = try XCTUnwrap(VO2MaxEstimator.hrRatio(restingHr: 200, hrMax: 220))
        XCTAssertEqual(v, 15.3 * 220 / 200, accuracy: 1e-9)
        XCTAssertTrue(VO2MaxEstimator.plausible.contains(v))
        XCTAssertGreaterThan(v, VO2MaxEstimator.plausible.lowerBound)
    }

    /// A plausible pair still estimates, byte-for-byte as before.
    func testHrRatioStillEstimatesInsideTheHumanRange() throws {
        let v = try XCTUnwrap(VO2MaxEstimator.hrRatio(restingHr: 60, hrMax: 187))
        XCTAssertEqual(v, 15.3 * 187 / 60, accuracy: 1e-9)
        XCTAssertTrue(VO2MaxEstimator.plausible.contains(v))
    }

    /// The pre-existing guards are unchanged.
    func testExistingGuardsAreUntouched() {
        XCTAssertNil(VO2MaxEstimator.hrRatio(restingHr: 25, hrMax: 187), "> 25 guard")
        XCTAssertNil(VO2MaxEstimator.hrRatio(restingHr: 190, hrMax: 180), "HRmax must exceed resting")
    }

    /// The whole-estimator path inherits the refusal: with no usable session and no activity model, an
    /// implausible ratio yields NO estimate rather than an off-scale one.
    func testEstimateYieldsNothingWhenTheRatioIsImplausible() {
        XCTAssertNil(VO2MaxEstimator.estimate(sessions: [], restingHr: 26, hrMax: 187, activityModel: nil))
    }

    /// And where a ratio IS plausible it is still reported, tagged `.hrRatio` with zero sessions — which is
    /// what the app layer refuses to BANK (see `Repository.isBankableVo2Max`).
    func testEstimateStillReportsAPlausibleRatioAsHrRatioWithZeroSessions() throws {
        let e = try XCTUnwrap(VO2MaxEstimator.estimate(sessions: [], restingHr: 60, hrMax: 187,
                                                       activityModel: nil))
        XCTAssertEqual(e.method, .hrRatio)
        XCTAssertEqual(e.sessions, 0)
    }
}
