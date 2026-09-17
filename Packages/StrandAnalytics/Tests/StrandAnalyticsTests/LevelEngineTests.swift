import XCTest
@testable import StrandAnalytics

/// The level, iOS lane: no ceiling, 50 = your average, 100 = your own 95th-percentile day.
///
/// What these pin:
///   · THE SCALE. Mean → 50, the good-end percentile → 100, linear and unbounded both ways.
///   · ALL FIVE PARTS AT THEIR OWN 100, NO STEP PENALTY, IS A LEVEL OF 100 — and more is more.
///   · A MISSING COMPONENT IS EXCLUDED, NOT SCORED ZERO, at the part level and inside a part.
///   · MEDITATION approaches 100 along an e-curve over an unbroken daily run, and not meditating is a
///     measured zero.
final class LevelEngineTests: XCTestCase {

    /// A baseline with mean 50 and a 95th-percentile best of 100 (5th percentile 0), so scores read off
    /// directly: 50 → 50, 100 → 100, 150 → 150.
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
        // Resting HR: mean 60, 5th percentile 50. 50 bpm is your 100; 45 bpm is above it.
        let rhr = Baseline(mean: 60, sd: 6, min: 50, max: 70)
        XCTAssertEqual(rhr.score(60, higherIsBetter: false), 50, accuracy: 1e-9)
        XCTAssertEqual(rhr.score(50, higherIsBetter: false), 100, accuracy: 1e-9)
        XCTAssertEqual(rhr.score(45, higherIsBetter: false), 125, accuracy: 1e-9)
        XCTAssertEqual(rhr.score(70, higherIsBetter: false), 0, accuracy: 1e-9)
    }

    func testADegenerateRangeStillHasASlope() {
        let flat = Baseline(mean: 50, sd: 0, min: 50, max: 50)
        XCTAssertTrue(flat.score(60, higherIsBetter: true).isFinite)
        XCTAssertGreaterThan(flat.score(60, higherIsBetter: true), 50)
    }

    // MARK: - the level

    private func atBest(meditationMinutes: Double = .infinity) -> LevelInputs {
        LevelInputs(
            restorativeMin: [100], sleepHrv: [100], regularityMin: [0],
            hrv: 100, rhr: 0, vo2max: 100, respRate: 0,
            muscleSessions: [(load: 100, daysAgo: 0)],
            daytimeRmssd: [100],
            meditationStreakMin: meditationMinutes,
            stepsToday: 10_000)
    }

    func testEveryPartAtItsOwnHundredIsALevelOfAHundred() throws {
        // Meditation approaches 100 but never reaches it on a finite run, so the exact-100 case is
        // pinned with an unbounded run.
        let b = try XCTUnwrap(LevelEngine.compute(inputs: atBest(), baselines: allUnit))
        XCTAssertEqual(b.level, 100, accuracy: 1e-6)
        for c in b.components { XCTAssertEqual(c.score ?? 0, 100, accuracy: 1e-6) }
    }

    func testBeyondYourBestTheLevelKeepsRising() throws {
        var better = atBest()
        better.hrv = 160
        better.rhr = -30
        let b = try XCTUnwrap(LevelEngine.compute(inputs: better, baselines: allUnit))
        XCTAssertGreaterThan(b.level, 100)
    }

    func testABadEnoughDayGoesBelowZero() throws {
        let awful = LevelInputs(hrv: -200, rhr: 300)
        let b = try XCTUnwrap(LevelEngine.compute(inputs: awful, baselines: allUnit))
        XCTAssertLessThan(b.level, 0)
    }

    func testAMissingComponentIsExcludedRatherThanScoredZero() throws {
        let b = try XCTUnwrap(LevelEngine.compute(inputs: LevelInputs(hrv: 80, rhr: 20), baselines: allUnit))
        // Heart alone at 80 — and meditation, which is always measured, at 0. Focus therefore scores 0
        // and the level is heart and focus blended by their weights, not dragged by three empty parts.
        let heart = 0.23 / (0.23 + 0.16)
        XCTAssertEqual(b.level, 80 * heart, accuracy: 1e-6)
        XCTAssertNil(b.components.first { $0.part == .sleep }?.score)
    }

    func testAMissingSubMetricIsRedistributedInsideItsPart() {
        // Only deep+REM minutes measured: sleep IS that sub-score.
        let s = LevelEngine.sleep(LevelInputs(restorativeMin: [75]), allUnit)
        XCTAssertEqual(s ?? 0, 75, accuracy: 1e-9)
    }

    func testTheSleepSharesAreSixtyTwentyFiveFifteen() {
        let s = LevelEngine.sleep(LevelInputs(restorativeMin: [100], sleepHrv: [50], regularityMin: [50]), allUnit)
        XCTAssertEqual(s ?? 0, 0.60 * 100 + 0.25 * 50 + 0.15 * 50, accuracy: 1e-9)
    }

    // MARK: - meditation

    func testMeditationFollowsTheECurveAndStartsAtZero() {
        XCTAssertEqual(LevelEngine.meditationScore(streakMinutes: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.meditationScore(streakMinutes: LevelEngine.meditationTauMin),
                       100 * (1 - exp(-1)), accuracy: 1e-9)
        XCTAssertLessThan(LevelEngine.meditationScore(streakMinutes: 10_000), 100.0001)
        // Ten minutes a day for a month is past 95.
        XCTAssertGreaterThan(LevelEngine.meditationScore(streakMinutes: 300), 95)
    }

    // MARK: - muscle

    func testRecentSessionsCountMoreThanOldOnes() throws {
        let today = try XCTUnwrap(LevelEngine.muscle(sessions: [(load: 30, daysAgo: 4), (load: 90, daysAgo: 0)], baseline: unit))
        let old = try XCTUnwrap(LevelEngine.muscle(sessions: [(load: 90, daysAgo: 4), (load: 30, daysAgo: 0)], baseline: unit))
        XCTAssertGreaterThan(today, old)
    }

    // MARK: - the step penalty

    func testStepsAtOrAboveTheFloorTakeNothingAway() {
        XCTAssertEqual(LevelEngine.stepPenalty(LevelEngine.stepsFloor), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.stepPenalty(nil), 1, accuracy: 1e-9)
        XCTAssertEqual(LevelEngine.stepPenalty(0), 1 - LevelEngine.stepsMaxPenalty, accuracy: 1e-9)
    }

    // MARK: - levers and drivers

    func testLeversRankByWhatTheyAreWorth() throws {
        let inputs = LevelInputs(restorativeMin: [60], vo2max: 20, respRate: 50)
        let b = try XCTUnwrap(LevelEngine.compute(inputs: inputs, baselines: allUnit))
        // Focus (meditation 0) and sleep both have room; lungs has little weight.
        XCTAssertNotEqual(b.levers().first?.part, .lungs)
    }

    func testTheDriverIsTheSubMetricWithTheMostRoom() {
        let inputs = LevelInputs(restorativeMin: [95], sleepHrv: [40], regularityMin: [50])
        // Restorative 95 → room 5 × 0.60 = 3; HRV 40 → 60 × 0.25 = 15; regularity 50 (lower is better,
        // mean 50) → 50 × 0.15 = 7.5.
        XCTAssertEqual(LevelDrivers.driver(for: .sleep, inputs: inputs, baselines: allUnit), .sleepHrv)
    }

    func testPastEveryHundredTheLowestSubMetricIsStillNamed() {
        let inputs = LevelInputs(hrv: 140, rhr: -10)
        // HRV 140; RHR −10 on a lower-is-better scale with mean 50 and best 0 scores 110.
        XCTAssertEqual(LevelDrivers.driver(for: .heart, inputs: inputs, baselines: allUnit), .rhr)
    }

    // MARK: - baselines

    func testTooLittleHistoryFallsBackToTheTable() {
        let thin = LevelBaselines.derive(.hrv, history: Array(repeating: 55, count: LevelBaselines.minSamples - 1))
        XCTAssertEqual(thin, LevelBaselines.table[.hrv])
    }

    func testTheRangeIsTheFifthToNinetyFifthPercentile() {
        let xs = (0...100).map(Double.init)
        let b = LevelBaselines.derive(.hrv, history: xs)
        XCTAssertEqual(b.mean, 50, accuracy: 1e-9)
        XCTAssertEqual(b.min, 5, accuracy: 1e-9)
        XCTAssertEqual(b.max, 95, accuracy: 1e-9)
    }

    func testPercentilesAreInterpolatedNotNearestRank() {
        let sorted: [Double] = [0, 10, 20, 30, 40]
        XCTAssertEqual(LevelBaselines.percentile(sorted, 50), 20, accuracy: 1e-9)
        XCTAssertEqual(LevelBaselines.percentile(sorted, 10), 4, accuracy: 1e-9)
    }
}
