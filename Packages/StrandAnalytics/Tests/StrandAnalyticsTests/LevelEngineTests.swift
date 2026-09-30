import XCTest
@testable import StrandAnalytics

/// The level, iOS lane: no ceiling, 50 = your average, 100 = your own 95th-percentile, built from state
/// rather than the week's trend. Epoch 4 (HEALTH_V2 H6 + the owner's 2026-09-29 decisions): HRV counted
/// once, sleep duration in the sleep part, focus = daytime calm, meditation only ever a deduction.
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

    func testTheSharesInsideEveryPartSumToOne() {
        let s = LevelEngine.sleepShares
        XCTAssertEqual(s.duration + s.regularity + s.restorative, 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.heartShares.hrv + LevelEngine.heartShares.rhr, 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.focusShares.calm, 1, accuracy: 1e-9)
    }

    // MARK: - the level

    private func atBest() -> LevelInputs {
        LevelInputs(
            restorativeMin: 100, sleepHrv: 100, regularityMin: 0, sleepDurationRatio: 100,
            hrv: 100, rhr: 0, vo2max: 100, respRate: 0,
            strengthIndex: 100, chronicLoad: 100,
            daytimeRmssd: 100, steps: 10_000)
    }

    func testEveryPartAtItsOwnHundredIsALevelOfAHundred() throws {
        let b = try XCTUnwrap(LevelEngine.compute(inputs: atBest(), baselines: allUnit))
        XCTAssertEqual(b.level, 100, accuracy: 1e-9)
        XCTAssertEqual(b.meditationPenalty, 0, accuracy: 1e-9)
    }

    func testBeyondYourBestTheLevelKeepsRising() throws {
        var better = atBest()
        better.strengthIndex = 160
        let b = try XCTUnwrap(LevelEngine.compute(inputs: better, baselines: allUnit))
        XCTAssertGreaterThan(b.level, 100)
    }

    /// Owner decision: no bound other than physiology. A very high but real reading on every input —
    /// including the chronic training load HEALTH_V2 H6 had proposed capping — is scored as far above 100
    /// as it is, with nothing clipped anywhere.
    func testVeryHighRealInputsGiveALevelAboveOneHundredWithNoClipping() throws {
        var high = atBest()
        high.chronicLoad = 400
        high.hrv = 250
        high.sleepDurationRatio = 180
        high.daytimeRmssd = 220
        let b = try XCTUnwrap(LevelEngine.compute(inputs: high, baselines: allUnit))
        let muscle = try XCTUnwrap(b.components.first { $0.part == .muscle }?.score)
        XCTAssertEqual(muscle, 0.6 * 100 + 0.4 * 400, accuracy: 1e-9, "the load term is not capped")
        let sleepPart: Double = 0.30 * (0.5 * 180 + 0.3 * 100 + 0.2 * 100)
        let heartPart: Double = 0.23 * (0.5 * 250 + 0.5 * 100)
        let lungsPart: Double = 0.12 * 100
        let musclePart: Double = 0.24 * muscle
        let focusPart: Double = 0.11 * 220
        let expected: Double = sleepPart + heartPart + lungsPart + musclePart + focusPart
        XCTAssertEqual(b.level, expected, accuracy: 1e-9)
        XCTAssertGreaterThan(b.level, 150)
    }

    func testMuscleIsStrengthAndChronicLoadSixtyForty() {
        let m = LevelEngine.part(LevelEngine.muscleSubScores(LevelInputs(strengthIndex: 100, chronicLoad: 50), allUnit))
        XCTAssertEqual(m ?? 0, 0.6 * 100 + 0.4 * 50, accuracy: 1e-9)
    }

    func testFocusIsDaytimeCalmAlone() {
        let f = LevelEngine.part(LevelEngine.focusSubScores(LevelInputs(daytimeRmssd: 64), allUnit))
        XCTAssertEqual(f ?? 0, 64, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.focusSubScores(LevelInputs(daytimeRmssd: 64), allUnit).map { $0.0 }, [.daytimeCalm])
    }

    func testAMissingSubMetricIsRedistributedInsideItsPart() {
        let s = LevelEngine.part(LevelEngine.sleepSubScores(LevelInputs(restorativeMin: 75), allUnit))
        XCTAssertEqual(s ?? 0, 75, accuracy: 1e-9)
    }

    // MARK: - HEALTH_V2 H6: HRV once, duration in, sleep = 0.50 / 0.30 / 0.20

    func testHRVIsCountedInExactlyOnePart() throws {
        let all = LevelEngine.sleepSubScores(atBest(), allUnit) + LevelEngine.heartSubScores(atBest(), allUnit)
            + LevelEngine.lungsSubScores(atBest(), allUnit) + LevelEngine.muscleSubScores(atBest(), allUnit)
            + LevelEngine.focusSubScores(atBest(), allUnit)
        let hrvDrivers = all.map { $0.0 }.filter { $0 == .hrv || $0 == .sleepHrv }
        XCTAssertEqual(hrvDrivers, [.hrv])
        // Night HRV no longer moves the level at all.
        var low = atBest(); low.sleepHrv = 0
        var high = atBest(); high.sleepHrv = 500
        let a = try XCTUnwrap(LevelEngine.compute(inputs: low, baselines: allUnit))
        let b = try XCTUnwrap(LevelEngine.compute(inputs: high, baselines: allUnit))
        XCTAssertEqual(a.level, b.level, accuracy: 1e-12)
    }

    func testTheSleepPartIsDurationRegularityAndRestorative() {
        let s = LevelEngine.part(LevelEngine.sleepSubScores(
            LevelInputs(restorativeMin: 40, regularityMin: 20, sleepDurationRatio: 90), allUnit))
        // regularity is lower-is-better: 20 min on this scale scores 80.
        XCTAssertEqual(s ?? 0, 0.50 * 90 + 0.30 * 80 + 0.20 * 40, accuracy: 1e-9)
    }

    func testAShortNightLowersSleepThroughDurationEvenWithoutStaging() throws {
        // No staging at all (restorative nil): duration alone still reads the short week.
        let table = LevelBaselines.table
        let rested = try XCTUnwrap(LevelEngine.part(LevelEngine.sleepSubScores(
            LevelInputs(regularityMin: 30, sleepDurationRatio: 1.0), table)))
        let short = try XCTUnwrap(LevelEngine.part(LevelEngine.sleepSubScores(
            LevelInputs(regularityMin: 30, sleepDurationRatio: 0.75), table)))
        XCTAssertLessThan(short, rested)
    }

    // MARK: - Meditation: a date-effective minimum, and a deduction only

    func testTheMeditationMinimumIsFiveBeforeTheChangeoverAndTenFromIt() {
        XCTAssertEqual(LevelEngine.meditationMinChangeoverDay, "2026-09-29")
        XCTAssertEqual(LevelEngine.meditationMinMinutes(on: "2026-08-14"), 5, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationMinMinutes(on: "2026-09-28"), 5, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationMinMinutes(on: "2026-09-29"), 10, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationMinMinutes(on: "2027-01-01"), 10, accuracy: 1e-9)
        // Six minutes in August met the rule in force then; six minutes now do not.
        XCTAssertTrue(LevelEngine.isMeditationDay(minutes: 6, on: "2026-08-14"))
        XCTAssertFalse(LevelEngine.isMeditationDay(minutes: 6, on: "2026-09-30"))
        XCTAssertEqual(LevelEngine.meditationMinMinutes, LevelEngine.meditationMinMinutes(on: "2026-09-29"))
    }

    func testMeditationNeverAddsToTheLevel() throws {
        var none = atBest(); none.meditationMissedDays = nil
        var met = atBest(); met.meditationMissedDays = 0
        let a = try XCTUnwrap(LevelEngine.compute(inputs: none, baselines: allUnit))
        let b = try XCTUnwrap(LevelEngine.compute(inputs: met, baselines: allUnit))
        XCTAssertEqual(a.level, b.level, accuracy: 1e-12, "a met meditation era equals no meditation term")
    }

    func testEachMissedEraDayCostsExactlyTheDocumentedPenalty() throws {
        var met = atBest(); met.meditationMissedDays = 0
        var oneMiss = atBest(); oneMiss.meditationMissedDays = 1
        var week = atBest(); week.meditationMissedDays = 7
        let m = try XCTUnwrap(LevelEngine.compute(inputs: met, baselines: allUnit))
        let o = try XCTUnwrap(LevelEngine.compute(inputs: oneMiss, baselines: allUnit))
        let w = try XCTUnwrap(LevelEngine.compute(inputs: week, baselines: allUnit))
        XCTAssertEqual(m.level - o.level, LevelEngine.meditationMissPenaltyPoints, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationMissPenaltyPoints, 1.0, accuracy: 1e-12)
        XCTAssertEqual(m.level - w.level, 7, accuracy: 1e-9)
        XCTAssertEqual(o.meditationPenalty, 1, accuracy: 1e-9)
        XCTAssertEqual(w.meditationPenalty, 7, accuracy: 1e-9)
        // After the step multiplier, not scaled by it.
        var walkedLittle = oneMiss; walkedLittle.steps = 0
        let s = try XCTUnwrap(LevelEngine.compute(inputs: walkedLittle, baselines: allUnit))
        XCTAssertEqual(s.level, s.raw * s.stepPenalty - 1, accuracy: 1e-9)
    }

    func testTheDeductionIsNotACapTheLevelStillGoesAboveOneHundred() throws {
        var high = atBest()
        high.hrv = 300
        high.meditationMissedDays = 7
        let b = try XCTUnwrap(LevelEngine.compute(inputs: high, baselines: allUnit))
        XCTAssertGreaterThan(b.level, 100)
    }

    func testTheFocusCardsShareFunctionStillCounts() {
        XCTAssertEqual(LevelEngine.meditationShare(meditated: Array(repeating: true, count: 28)), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationShare(meditated: []), 0, accuracy: 1e-9)
    }

    // MARK: - absent inputs

    /// Regression (epoch 3): a meditation reading could make a level out of nothing. It no longer scores
    /// at all, so it cannot.
    func testMeditationAloneIsNeverALevel() {
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(meditationMissedDays: 0), baselines: allUnit))
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(meditationMissedDays: 7), baselines: allUnit))
        XCTAssertNil(LevelEngine.part(LevelEngine.focusSubScores(LevelInputs(meditationMissedDays: 0), allUnit)))
    }

    /// Regression: day one of a fresh install — nothing but a sliver of the formula must not be a level.
    func testALevelBuiltFromAlmostNothingAbstainsInsteadOfScoringZero() {
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(), baselines: allUnit))
        // Focus alone is 11 % of the formula. That is not a level.
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(daytimeRmssd: 0), baselines: allUnit))
        // Nor is sleep alone, at 30 %.
        XCTAssertNil(LevelEngine.compute(inputs: LevelInputs(restorativeMin: 50), baselines: allUnit))
    }

    func testSleepAndHeartClearTheFloorAndTheLevelSaysHowMuchOfItWasMeasured() throws {
        let b = try XCTUnwrap(LevelEngine.compute(
            inputs: LevelInputs(restorativeMin: 50, sleepHrv: 50, hrv: 50, rhr: 50), baselines: allUnit))
        XCTAssertEqual(b.coverage, LevelPart.sleep.weight + LevelPart.heart.weight, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(b.coverage, LevelEngine.minCoverage)
        XCTAssertEqual(b.coveragePercent, 53)
        XCTAssertTrue(b.isPartialCoverage)
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
        let inputs = LevelInputs(restorativeMin: 95, regularityMin: 50, sleepDurationRatio: 40)
        // duration: (100 − 40) × 0.50 = 30 of room, the most in the part.
        XCTAssertEqual(LevelDrivers.driver(for: .sleep, inputs: inputs, baselines: allUnit), .sleepDuration)
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

    func testEveryMetricHasATableEntryIncludingSleepDuration() {
        for metric in LevelMetric.allCases {
            XCTAssertNotNil(LevelBaselines.table[metric], metric.rawValue)
        }
        XCTAssertEqual(LevelBaselines.table[.sleepDurationRatio]?.mean ?? 0, 0.95, accuracy: 1e-9)
    }

    /// Regression: a scale was frozen — permanently — from 14 readings, and a reading is a 7-day rolling
    /// mean taken once per calendar day, so consecutive ones share six of their seven days.
    func testAScaleIsNotFrozenFromTwoOverlappingWeeks() {
        XCTAssertFalse(LevelBaselines.isDerivable(Array(repeating: 55.0, count: 14)))
        XCTAssertGreaterThanOrEqual(LevelBaselines.minSamples / LevelEngine.rollingDays, 5,
                                    "fewer than five independent weeks behind a frozen percentile")
        XCTAssertTrue(LevelBaselines.isDerivable((0..<LevelBaselines.minSamples).map(Double.init)))
    }

    /// Regression: `safeSd` was a hard-coded 1 on metrics that do not share a unit.
    func testADegenerateSpanFallsBackToTheMetricsOwnScaleNotToOne() {
        let strength = Baseline(mean: 1.0, sd: 0, min: 1.0, max: 1.0)
        XCTAssertEqual(strength.safeSd, 0.5, accuracy: 1e-9)
        XCTAssertGreaterThan(strength.score(2.0, higherIsBetter: true), 100)

        let load = Baseline(mean: 3000, sd: 0, min: 3000, max: 3000)
        XCTAssertEqual(load.safeSd, 1500, accuracy: 1e-9)
        XCTAssertEqual(load.score(3010, higherIsBetter: true), 50, accuracy: 0.5)

        XCTAssertEqual(Baseline(mean: 0, sd: 0, min: 0, max: 0).safeSd, 1, accuracy: 1e-9)
    }
}
