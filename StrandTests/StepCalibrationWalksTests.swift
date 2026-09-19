import XCTest
@testable import Strand

final class StepCalibrationWalksTests: XCTestCase {
    private typealias M = StepCalibrationMath

    private func walk(_ kind: StepCalibrationKind, raw: Double, counted: Int, estimated: Int? = nil) -> StepCalibrationWalk {
        M.makeWalk(kind: kind, raw: raw, estimated: estimated, counted: counted,
                   date: Date(timeIntervalSince1970: 0))!
    }

    // MARK: estimate (same arithmetic as the day totals)

    func testCounterEstimateDividesByTicksPerStepLikeAnalyticsEngine() {
        XCTAssertEqual(M.estimatedSteps(kind: .counter, raw: 2_400, parameter: 1.0), 2_400)
        XCTAssertEqual(M.estimatedSteps(kind: .counter, raw: 2_400, parameter: 2.4), 1_000)
        // AnalyticsEngine floors the divisor at 0.5.
        XCTAssertEqual(M.estimatedSteps(kind: .counter, raw: 100, parameter: 0.1), 200)
    }

    func testMotionEstimateMultipliesByK() {
        XCTAssertEqual(M.estimatedSteps(kind: .motion, raw: 12.5, parameter: 80), 1_000)
        XCTAssertNil(M.estimatedSteps(kind: .motion, raw: 12.5, parameter: 0), "uncalibrated 4.0 has no estimate")
    }

    // MARK: implied parameter + guards

    func testImpliedParameterPerKind() {
        XCTAssertEqual(M.impliedParameter(kind: .counter, raw: 2_400, counted: 1_000)!, 2.4, accuracy: 1e-12)
        XCTAssertEqual(M.impliedParameter(kind: .motion, raw: 12.5, counted: 1_000)!, 80, accuracy: 1e-12)
    }

    func testRejectsTooFewCountedStepsOrNoMovement() {
        XCTAssertNil(M.impliedParameter(kind: .counter, raw: 100, counted: 49))
        XCTAssertNotNil(M.impliedParameter(kind: .counter, raw: 100, counted: 50))
        XCTAssertNil(M.impliedParameter(kind: .motion, raw: 0, counted: 500))
        XCTAssertNil(M.makeWalk(kind: .motion, raw: .nan, estimated: nil, counted: 500))
    }

    func testApplyingTheImpliedParameterReproducesTheCountedSteps() {
        // The whole point: after calibrating on a walk, NOOP's count for that walk equals what was counted.
        let c = walk(.counter, raw: 7_321, counted: 1_013)
        XCTAssertEqual(M.estimatedSteps(kind: .counter, raw: 7_321, parameter: c.implied), 1_013)
        let m = walk(.motion, raw: 17.3, counted: 1_013)
        XCTAssertEqual(M.estimatedSteps(kind: .motion, raw: 17.3, parameter: m.implied), 1_013)
    }

    func testFactorIsCountedOverEstimated() {
        XCTAssertEqual(walk(.counter, raw: 2_000, counted: 1_000, estimated: 2_000).factor!, 0.5, accuracy: 1e-12)
        XCTAssertNil(walk(.motion, raw: 10, counted: 1_000, estimated: nil).factor)
    }

    // MARK: combination

    func testSingleWalkCombinesToItsOwnValue() {
        XCTAssertEqual(M.combinedParameter([walk(.counter, raw: 3_000, counted: 1_000)], kind: .counter)!,
                       3.0, accuracy: 1e-12)
    }

    func testCombinationIsWeightedMedianByCountedSteps() {
        // A long 2,000-step walk at 2.0 outvotes two short walks at 4.0 and 6.0.
        let walks = [walk(.counter, raw: 4_000, counted: 2_000),   // 2.0, weight 2000
                     walk(.counter, raw: 400, counted: 100),       // 4.0, weight 100
                     walk(.counter, raw: 600, counted: 100)]       // 6.0, weight 100
        XCTAssertEqual(M.combinedParameter(walks, kind: .counter)!, 2.0, accuracy: 1e-12)
    }

    func testEqualWeightsGiveTheOrdinaryMedian() {
        let walks = [walk(.counter, raw: 1_000, counted: 500),   // 2
                     walk(.counter, raw: 1_500, counted: 500)]   // 3
        XCTAssertEqual(M.combinedParameter(walks, kind: .counter)!, 2.5, accuracy: 1e-12)
    }

    func testCombinationIgnoresOtherKind() {
        let walks = [walk(.counter, raw: 3_000, counted: 1_000), walk(.motion, raw: 10, counted: 1_000)]
        XCTAssertEqual(M.combinedParameter(walks, kind: .motion)!, 100, accuracy: 1e-12)
        XCTAssertNil(M.combinedParameter([walk(.counter, raw: 3_000, counted: 1_000)], kind: .motion))
    }

    // MARK: bounds

    @MainActor
    func testCounterRangeMatchesProfileStoreRange() {
        XCTAssertEqual(M.ticksPerStepRange, ProfileStore.stepScaleRange)
    }

    func testCounterIsClampedToTheDivisorRange() {
        // 40 ticks per step is beyond the 30 ceiling; 0.2 below the 0.5 floor.
        XCTAssertEqual(M.combinedParameter([walk(.counter, raw: 40_000, counted: 1_000)], kind: .counter), 30)
        XCTAssertEqual(M.combinedParameter([walk(.counter, raw: 200, counted: 1_000)], kind: .counter), 0.5)
        // A real 5/MG overcount (~24x) is NOT squeezed by the 0.5-2.0 relative bound.
        XCTAssertEqual(M.combinedParameter([walk(.counter, raw: 24_000, counted: 1_000)], kind: .counter)!,
                       24, accuracy: 1e-12)
    }

    func testMotionIsBoundedRelativeToThePhoneFit() {
        let w = [walk(.motion, raw: 10, counted: 1_000)]   // k = 100
        XCTAssertEqual(M.combinedParameter(w, kind: .motion, referenceK: 40)!, 80, accuracy: 1e-12)   // 2x cap
        XCTAssertEqual(M.combinedParameter(w, kind: .motion, referenceK: 250)!, 125, accuracy: 1e-12)  // 0.5x floor
        XCTAssertEqual(M.combinedParameter(w, kind: .motion, referenceK: 90)!, 100, accuracy: 1e-12)   // inside
        XCTAssertEqual(M.combinedParameter(w, kind: .motion, referenceK: nil)!, 100, accuracy: 1e-12)  // no fit
    }

    func testMotionAbsoluteRange() {
        XCTAssertEqual(M.combinedParameter([walk(.motion, raw: 0.01, counted: 1_000)], kind: .motion),
                       M.motionCoefficientRange.upperBound)
    }

    func testWeightedMedianEdgeCases() {
        XCTAssertEqual(M.weightedMedian([], weights: []), 0)
        XCTAssertEqual(M.weightedMedian([3, 1, 2], weights: [1, 1, 1]), 2)
        XCTAssertEqual(M.weightedMedian([1, 2, 3], weights: [0, 0, 0]), 2)
        XCTAssertEqual(M.weightedMedian([1, 2, 3], weights: []), 2)
    }

    // MARK: session

    func testSessionAccumulatesSegmentsAcrossResume() {
        var s = StepCalibrationSession()
        s.start(now: 100)
        XCTAssertEqual(s.elapsed(now: 160), 60)
        s.pause(now: 160)
        XCTAssertFalse(s.isRunning)
        s.start(now: 1_000)
        s.pause(now: 1_030)
        XCTAssertEqual(s.segments, [.init(start: 100, end: 160), .init(start: 1_000, end: 1_030)])
        XCTAssertEqual(s.elapsed(now: 5_000), 90)
        s.start(now: 2_000)
        XCTAssertEqual(s.allSegments(now: 2_010).last, StepCalibrationSession.Segment(start: 2_000, end: 2_010))
    }

    func testStateRoundTripsThroughDefaults() {
        let d = UserDefaults(suiteName: "StepCalibrationWalksTests")!
        d.removePersistentDomain(forName: "StepCalibrationWalksTests")
        var st = StepCalibrationState()
        st.walks = [walk(.counter, raw: 3_000, counted: 1_000, estimated: 3_000)]
        st.originalTicksPerStep = 1.0
        st.save(d)
        XCTAssertEqual(StepCalibrationState.load(d), st)
        d.removePersistentDomain(forName: "StepCalibrationWalksTests")
    }
}
