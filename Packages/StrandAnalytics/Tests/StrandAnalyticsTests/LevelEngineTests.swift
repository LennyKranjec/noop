import XCTest
@testable import StrandAnalytics

/// The level, and the two things about it that are easy to get quietly wrong.
///
/// A MISSING COMPONENT MUST NOT SCORE ZERO. Weight is redistributed over the parts that have data, so a
/// wearer with no VO2max is scored on what was recorded rather than marked down for a sensor they do
/// not own. Every variation of getting that wrong produces a plausible, lower number that nothing on
/// screen contradicts.
///
/// THE SCALE IS FROZEN, and these pin the arithmetic that rests on it: population SD, interpolated
/// percentiles, clipped z. A one-sample disagreement with the Android lane would be permanent, because
/// the baselines are derived once and never re-derived.
final class LevelEngineTests: XCTestCase {

    private let baselines = LevelBaselines.table

    // MARK: - redistribution

    func testAMissingComponentIsExcludedRatherThanScoredZero() throws {
        // Sleep alone, at 80. With redistribution the level IS 80: sleep carries the whole weight
        // because it is the only thing measured. Scored as zeroes elsewhere it would read 24.
        let inputs = LevelInputs(sleepScores: [80])
        let breakdown = try XCTUnwrap(LevelEngine.compute(inputs: inputs, baselines: baselines))
        XCTAssertEqual(breakdown.level, 80, accuracy: 1e-9)
        XCTAssertEqual(breakdown.coverage, LevelPart.sleep.weight, accuracy: 1e-9)
    }

    func testNothingMeasuredIsNilNotZero() {
        // A zero would read as "you are in terrible shape" when it means "nothing was recorded".
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(), baselines: baselines))
    }

    func testEveryPartIsListedEvenWhenUnmeasured() throws {
        let breakdown = try XCTUnwrap(LevelEngine.compute(inputs: LevelInputs(sleepScores: [50]), baselines: baselines))
        XCTAssertEqual(breakdown.components.count, LevelPart.allCases.count)
        let lungs = try XCTUnwrap(breakdown.components.first { $0.part == .lungs })
        XCTAssertNil(lungs.score)
        XCTAssertEqual(lungs.effectiveWeight, 0, accuracy: 1e-9)
    }

    // MARK: - the parts

    func testConsistencyMissingIsNotConsistencyZero() {
        // Scored on its own score alone, rather than marked down for a measurement never taken.
        XCTAssertEqual(LevelEngine.sleep(scores: [70], consistency: []), 70)
        // With a reading it is the documented 80/20 blend.
        XCTAssertEqual(LevelEngine.sleep(scores: [70], consistency: [20]), 0.8 * 70 + 0.2 * 20)
    }

    func testAHighRespiratoryRateIsTheBadDirection() throws {
        // Inverted on purpose: fast breathing is worse, and a naive scale would reward it.
        let fast = try XCTUnwrap(LevelEngine.lungs(vo2max: nil, respRate: 22, baselines: baselines))
        let slow = try XCTUnwrap(LevelEngine.lungs(vo2max: nil, respRate: 12, baselines: baselines))
        XCTAssertLessThan(fast, slow)
    }

    func testTodaysSessionOutweighsAnOlderOne() throws {
        let base = Baseline(mean: 4000, sd: 1000, min: 0, max: 8000)
        let today = try XCTUnwrap(LevelEngine.muscle(sessions: [(load: 8000, daysAgo: 0)], baseline: base))
        let old = try XCTUnwrap(LevelEngine.muscle(sessions: [(load: 8000, daysAgo: 4)], baseline: base))
        // A single session is its own weighted mean whatever its age, so the DECAY shows when an old
        // heavy day competes with a recent light one.
        XCTAssertEqual(today, old, accuracy: 1e-9)
        let mixed = try XCTUnwrap(
            LevelEngine.muscle(
                sessions: [(load: 8000, daysAgo: 4), (load: 0, daysAgo: 0)],
                baseline: base
            )
        )
        XCTAssertLessThan(mixed, 50, "today's rest should dominate a session four days old")
    }

    func testMeditationLiftsFocusAndIsCappedAtThreeDays() throws {
        let none = try XCTUnwrap(LevelEngine.focus(stressScores: [20], meditationDays: 0))
        let three = try XCTUnwrap(LevelEngine.focus(stressScores: [20], meditationDays: 3))
        let ten = try XCTUnwrap(LevelEngine.focus(stressScores: [20], meditationDays: 10))
        XCTAssertLessThan(none, three)
        XCTAssertEqual(three, ten, accuracy: 1e-9, "the bonus is capped at three days")
    }

    // MARK: - the step penalty

    func testStepsAtOrAboveTheFloorTakeNothingAway() {
        XCTAssertEqual(LevelEngine.stepPenalty(LevelEngine.stepsFloor), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.stepPenalty(20_000), 1, accuracy: 1e-9)
    }

    func testUnrecordedStepsAreNotPunished() {
        // The wearer cannot fix a sensor they do not have, and a still day and a missing pedometer are
        // different statements.
        XCTAssertEqual(LevelEngine.stepPenalty(nil), 1, accuracy: 1e-9)
    }

    func testTheWorstStepPenaltyIsBounded() {
        XCTAssertEqual(LevelEngine.stepPenalty(0), 1 - LevelEngine.stepsMaxPenalty, accuracy: 1e-9)
    }

    func testThereIsNoCliffAtTheFloor() {
        // An earlier draft scored steps as a component, which put a 72-point cliff between 5,999 and
        // 6,000. The penalty is continuous, so the step across the floor is a rounding error.
        let below = LevelEngine.stepPenalty(LevelEngine.stepsFloor - 1)
        let at = LevelEngine.stepPenalty(LevelEngine.stepsFloor)
        XCTAssertEqual(below, at, accuracy: 1e-4)
    }

    // MARK: - levers

    func testLeversRankByWhatTheyAreWorthNotByTheLowestScore() throws {
        // Lungs 20 looks worse than sleep 60, and is worth a third as much level. Ranking by the low
        // score would keep pointing at the metric that matters least.
        let inputs = LevelInputs(
            sleepScores: [60],
            consistencyScores: [60],
            vo2max: 20,
            respRate: 16
        )
        let breakdown = try XCTUnwrap(LevelEngine.compute(inputs: inputs, baselines: baselines))
        XCTAssertEqual(breakdown.levers().first?.part, .sleep)
    }

    func testAnUnmeasuredPartIsNeverALever() throws {
        let breakdown = try XCTUnwrap(LevelEngine.compute(inputs: LevelInputs(sleepScores: [50]), baselines: baselines))
        XCTAssertEqual(breakdown.levers().map(\.part), [.sleep])
    }

    // MARK: - the frozen scale

    func testTooLittleHistoryFallsBackToTheTable() {
        let thin = LevelBaselines.derive(.hrv, history: Array(repeating: 55, count: LevelBaselines.minSamples - 1))
        XCTAssertEqual(thin, LevelBaselines.table[.hrv])
    }

    func testTheSpreadIsThePopulationForm() {
        // Divide by n, not n−1. The sample form would put the two platforms a fraction apart on every
        // score, which is exactly the drift the parity contract exists to catch.
        let xs = Array(repeating: 40.0, count: 10) + Array(repeating: 60.0, count: 10)
        let derived = LevelBaselines.derive(.hrv, history: xs)
        XCTAssertEqual(derived.mean, 50, accuracy: 1e-9)
        XCTAssertEqual(derived.sd, 10, accuracy: 1e-9)
    }

    func testPercentilesAreInterpolatedNotNearestRank() {
        // With the result frozen, a one-sample disagreement between platforms would be permanent.
        let sorted: [Double] = [0, 10, 20, 30, 40]
        XCTAssertEqual(LevelBaselines.percentile(sorted, 50), 20, accuracy: 1e-9)
        XCTAssertEqual(LevelBaselines.percentile(sorted, 25), 10, accuracy: 1e-9)
        XCTAssertEqual(LevelBaselines.percentile(sorted, 10), 4, accuracy: 1e-9)
    }

    func testZIsClippedSoOneFreakReadingCannotDominate() {
        let base = Baseline(mean: 50, sd: 10, min: 30, max: 70)
        XCTAssertEqual(LevelEngine.z(1_000, base), LevelEngine.zClip, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.z(-1_000, base), -LevelEngine.zClip, accuracy: 1e-9)
    }

    func testPositionClipsToTheFrozenRange() {
        // The range is fixed; readings are not. A season past the frozen top is still 100.
        let base = Baseline(mean: 50, sd: 10, min: 0, max: 100)
        XCTAssertEqual(base.position(150), 100, accuracy: 1e-9)
        XCTAssertEqual(base.position(-50), 0, accuracy: 1e-9)
    }

    func testADegenerateSpreadDoesNotDivideByZero() {
        let flat = Baseline(mean: 50, sd: 0, min: 50, max: 50)
        XCTAssertEqual(flat.safeSd, 1, accuracy: 1e-9)
        XCTAssertEqual(flat.safeSpan, 1, accuracy: 1e-9)
        XCTAssertTrue(LevelEngine.z(60, flat).isFinite)
    }
}
