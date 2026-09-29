import XCTest
@testable import StrandAnalytics

/// The level, iOS lane: no ceiling, 50 = your average, 100 = your own 95th-percentile, built from state
/// rather than the week's trend.
final class LevelEngineTests: XCTestCase {

    /// Mean 50, 95th percentile 100, 5th percentile 0 — scores read off directly.
    private let unit = Baseline(mean: 50, sd: 30, min: 0, max: 100)

    private var allUnit: [LevelMetric: Baseline] {
        Dictionary(uniqueKeysWithValues: LevelMetric.allCases.map { ($0, unit) })
    }

    // MARK: - the scale

    func testTheMeanIsFiftyAndTheGoodEndIsAHundredWithNoCapEitherWay() {
        XCTAssertEqual(unit.score(50, higherIsBetter: true), 50, accuracy: 1e-9)
        XCTAssertEqual(unit.score(100, higherIsBetter: true), 100, accuracy: 1e-9)
        XCTAssertEqual(unit.score(150, higherIsBetter: true), 150, accuracy: 1e-9)
        XCTAssertEqual(unit.score(-50, higherIsBetter: true), -50, accuracy: 1e-9)
    }

    func testLowerIsBetterScoresAgainstTheBottomOfTheRange() {
        let rhr = Baseline(mean: 60, sd: 6, min: 50, max: 70)
        XCTAssertEqual(rhr.score(50, higherIsBetter: false), 100, accuracy: 1e-9)
        XCTAssertEqual(rhr.score(45, higherIsBetter: false), 125, accuracy: 1e-9)
    }

    // MARK: - the weights

    func testTheWeightsSumToOneWithLungsUpAndFocusDown() {
        XCTAssertEqual(LevelPart.allCases.reduce(0) { $0 + $1.weight }, 1, accuracy: 1e-9)
        XCTAssertEqual(LevelPart.lungs.weight, 0.12, accuracy: 1e-9)
        XCTAssertEqual(LevelPart.focus.weight, 0.11, accuracy: 1e-9)
    }

    // MARK: - the level

    private func atBest() -> LevelInputs {
        LevelInputs(
            restorativeMin: 100, sleepHrv: 100, regularityMin: 0,
            hrv: 100, rhr: 0, vo2max: 100, respRate: 0,
            strengthIndex: 100, chronicLoad: 100,
            daytimeRmssd: 100, meditationShare: 1, steps: 10_000)
    }

    func testEveryPartAtItsOwnHundredIsALevelOfAHundred() throws {
        let b = try XCTUnwrap(LevelEngine.compute(inputs: atBest(), baselines: allUnit))
        XCTAssertEqual(b.level, 100, accuracy: 1e-9)
    }

    func testBeyondYourBestTheLevelKeepsRising() throws {
        var better = atBest()
        better.strengthIndex = 160
        let b = try XCTUnwrap(LevelEngine.compute(inputs: better, baselines: allUnit))
        XCTAssertGreaterThan(b.level, 100)
    }

    func testMuscleIsStrengthAndChronicLoadSixtyForty() {
        let m = LevelEngine.part(LevelEngine.muscleSubScores(LevelInputs(strengthIndex: 100, chronicLoad: 50), allUnit))
        XCTAssertEqual(m ?? 0, 0.6 * 100 + 0.4 * 50, accuracy: 1e-9)
    }

    func testFocusIsCalmSeventyFiveAndMeditationTwentyFive() {
        let f = LevelEngine.part(LevelEngine.focusSubScores(LevelInputs(daytimeRmssd: 50, meditationShare: 1), allUnit))
        XCTAssertEqual(f ?? 0, 0.75 * 50 + 0.25 * 100, accuracy: 1e-9)
    }

    func testAMissingSubMetricIsRedistributedInsideItsPart() {
        let s = LevelEngine.part(LevelEngine.sleepSubScores(LevelInputs(restorativeMin: 75), allUnit))
        XCTAssertEqual(s ?? 0, 75, accuracy: 1e-9)
    }

    // MARK: - meditation

    func testEveryDayMeditatedIsAFullShareAndOneMissedDayCostsOnlyALittle() {
        XCTAssertEqual(LevelEngine.meditationShare(meditated: Array(repeating: true, count: 28)), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationShare(meditated: []), 0, accuracy: 1e-9)
        var missedYesterday = Array(repeating: true, count: 28)
        missedYesterday[1] = false
        let share = LevelEngine.meditationShare(meditated: missedYesterday)
        XCTAssertGreaterThan(share, 0.9, "one missed day does not reset anything")
        XCTAssertLessThan(share, 1)
    }

    func testRecentDaysWeighMoreThanOldOnes() {
        var recent = Array(repeating: false, count: 28); recent[0] = true
        var old = Array(repeating: false, count: 28); old[27] = true
        XCTAssertGreaterThan(LevelEngine.meditationShare(meditated: recent),
                             LevelEngine.meditationShare(meditated: old))
    }

    // MARK: - absent inputs

    /// Regression: the meditation sub-score was the one input that could never be missing — a plain
    /// `Double` defaulting to 0, so `part(.focus)` was never nil and `compute` never returned nil.
    func testMeditationWithNoLogIsAbsentNotAMeasuredZero() {
        // Nothing logged at all: focus has no reading, and its weight goes to the parts that do.
        XCTAssertNil(LevelEngine.part(LevelEngine.focusSubScores(LevelInputs(), allUnit)))
        // A log that exists and says nought is still a measured zero, and still scores as one.
        XCTAssertEqual(LevelEngine.part(LevelEngine.focusSubScores(LevelInputs(meditationShare: 0), allUnit)) ?? -1,
                       0, accuracy: 1e-9)
    }

    /// Regression: day one of a fresh install. Every rolling metric is still under its 3-of-7-day
    /// minimum, so the only sub-score with a value was the fabricated meditation zero — the level came
    /// out a confident 0.0 at 11 % coverage, was frozen for the day, and then polluted the 3-day mean for
    /// three days and the 30-day mean for a month.
    func testALevelBuiltFromAlmostNothingAbstainsInsteadOfScoringZero() {
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(), baselines: allUnit))
        // Even with a meditation log, focus alone is 11 % of the formula. That is not a level.
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(meditationShare: 0), baselines: allUnit))
        // Nor is sleep alone, at 30 %.
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(restorativeMin: 50), baselines: allUnit))
    }

    func testSleepAndHeartClearTheFloorAndTheLevelSaysHowMuchOfItWasMeasured() throws {
        let b = try XCTUnwrap(LevelEngine.compute(
            inputs: LevelInputs(restorativeMin: 50, sleepHrv: 50, hrv: 50, rhr: 50), baselines: allUnit))
        XCTAssertEqual(b.coverage, LevelPart.sleep.weight + LevelPart.heart.weight, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(b.coverage, LevelEngine.minCoverage)
        // The figure the breakdown shows, so a thin level cannot look like a solid one.
        XCTAssertEqual(b.coveragePercent, 53)
        XCTAssertTrue(b.isPartialCoverage)
        // A fully measured day says nothing, because there is nothing to say.
        let full = try XCTUnwrap(LevelEngine.compute(inputs: atBest(), baselines: allUnit))
        XCTAssertEqual(full.coveragePercent, 100)
        XCTAssertFalse(full.isPartialCoverage)
    }

    // MARK: - steps

    func testStepsAtOrAboveTheFloorTakeNothingAway() {
        XCTAssertEqual(LevelEngine.stepPenalty(LevelEngine.stepsFloor), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.stepPenalty(nil), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.stepPenalty(0), 1 - LevelEngine.stepsMaxPenalty, accuracy: 1e-9)
    }

    // MARK: - drivers

    func testTheDriverIsTheSubMetricWithTheMostRoom() {
        let inputs = LevelInputs(restorativeMin: 95, sleepHrv: 40, regularityMin: 50)
        XCTAssertEqual(LevelDrivers.driver(for: .sleep, inputs: inputs, baselines: allUnit), .sleepHrv)
        XCTAssertEqual(LevelDrivers.driver(for: .muscle, inputs: LevelInputs(strengthIndex: 40, chronicLoad: 90),
                                           baselines: allUnit), .strength)
    }

    // MARK: - baselines

    func testTheRangeIsTheFifthToNinetyFifthPercentile() {
        let b = LevelBaselines.derive(.hrv, history: (0...100).map(Double.init))
        XCTAssertEqual(b.min, 5, accuracy: 1e-9)
        XCTAssertEqual(b.max, 95, accuracy: 1e-9)
    }

    func testTooLittleHistoryFallsBackToTheTable() {
        let thin = LevelBaselines.derive(.hrv, history: Array(repeating: 55, count: LevelBaselines.minSamples - 1))
        XCTAssertEqual(thin, LevelBaselines.table[.hrv])
    }

    /// Regression: a scale was frozen — permanently — from 14 readings, and a reading is a 7-day rolling
    /// mean taken once per calendar day, so consecutive ones share six of their seven days. Fourteen of
    /// them is about two independent weeks, and the 5th/95th percentiles of two weeks are what 0 and 100
    /// then meant for that wearer for good.
    func testAScaleIsNotFrozenFromTwoOverlappingWeeks() {
        XCTAssertFalse(LevelBaselines.isDerivable(Array(repeating: 55.0, count: 14)))
        XCTAssertGreaterThanOrEqual(LevelBaselines.minSamples / LevelEngine.rollingDays, 5,
                                    "fewer than five independent weeks behind a frozen percentile")
        XCTAssertTrue(LevelBaselines.isDerivable((0..<LevelBaselines.minSamples).map(Double.init)))
    }

    /// Regression: `safeSd` was a hard-coded 1 on metrics that do not share a unit. Reached through
    /// `score`'s degenerate-span branch, which fires whenever `max == mean` — the ordinary case for a
    /// flat `strengthIndex`. `MuscleBaselines` fixed exactly this; the comment there explains why.
    func testADegenerateSpanFallsBackToTheMetricsOwnScaleNotToOne() {
        // `strengthIndex` lives around 1.0. With an SD of 1 the span was 1.645 and a DOUBLED one-rep max
        // scored 80 — it could never reach the wearer's own 100.
        let strength = Baseline(mean: 1.0, sd: 0, min: 1.0, max: 1.0)
        XCTAssertEqual(strength.safeSd, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(strength.score(2.0, higherIsBetter: true), 100)

        // `chronicLoad` lives around 3,000. With an SD of 1 a load ten kilograms above the mean scored
        // 354 — and `score` is unbounded, so nothing clipped it.
        let load = Baseline(mean: 3000, sd: 0, min: 3000, max: 3000)
        XCTAssertEqual(load.safeSd, 1500, accuracy: 1e-9)
        XCTAssertEqual(load.score(3010, higherIsBetter: true), 50, accuracy: 0.5)

        // No spread AND no scale: there is nothing to be relative to, so the literal 1 stays.
        XCTAssertEqual(Baseline(mean: 0, sd: 0, min: 0, max: 0).safeSd, 1, accuracy: 1e-9)
    }
}
