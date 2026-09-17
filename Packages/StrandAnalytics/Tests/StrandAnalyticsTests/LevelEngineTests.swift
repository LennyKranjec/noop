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
}
