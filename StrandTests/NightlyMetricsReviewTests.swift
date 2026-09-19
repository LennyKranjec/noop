import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// Review fixes to the nightly-metrics rework that live in the engine rather than the analytics package:
///   S4 the personal sleep-HR baseline is taken PER NIGHT, as of that night, rounded to 1 bpm;
///   S5 a sleep edit follows its night by OVERLAP when a re-score moved the detected startTs;
///   S10 a Fitness Age "active day" is a workout or an Effort of at least 50.
/// Every vector is synthetic and says so.
///
/// `@MainActor`: `fitnessAgeRows` is main-actor-isolated, like the rest of `IntelligenceEngine`.
@MainActor
final class NightlyMetricsReviewTests: XCTestCase {

    private let h = 3_600
    private let d = 86_400

    // MARK: - S4

    /// Six nights ending 07:00 on days 0–5, resting HR 50, 52, 54, 60, 62, 64. Each scored day reads only
    /// the nights that ENDED before it began: day 3 → median(50, 52, 54) = 52; day 6 → median of all six =
    /// 57. Day 2 has only two prior nights → cold start (nil). A day more than 30 days after the last night
    /// has nothing in its horizon → nil.
    func testSleepHRBaselineIsAsOfEachNight() {
        let rhrs = [50, 52, 54, 60, 62, 64]
        let nights = rhrs.enumerated().map { k, r in
            IntelligenceEngine.SleepHRNight(start: k * d - h, end: k * d + 7 * h, restingHR: r)
        }
        XCTAssertEqual(IntelligenceEngine.asOfSleepHRBaseline(nights, before: 3 * d), 52)
        XCTAssertEqual(IntelligenceEngine.asOfSleepHRBaseline(nights, before: 6 * d), 57)
        XCTAssertNil(IntelligenceEngine.asOfSleepHRBaseline(nights, before: 2 * d), "cold start: two nights")
        XCTAssertNil(IntelligenceEngine.asOfSleepHRBaseline(nights, before: 40 * d), "outside the 30-day horizon")
    }

    /// Rounded to 1 bpm, so a half-bpm drift in the trailing nights does not re-key every cached night.
    func testSleepHRBaselineIsRoundedToOneBpm() {
        let nights = [54, 55, 56, 57].enumerated().map { k, r in
            IntelligenceEngine.SleepHRNight(start: k * d - h, end: k * d + 7 * h, restingHR: r)
        }
        // median(54, 55, 56, 57) = 55.5 → 56.
        XCTAssertEqual(IntelligenceEngine.asOfSleepHRBaseline(nights, before: 4 * d), 56)
    }

    // MARK: - S5

    private func row(_ start: Int, _ end: Int, edited: Bool = false, adjusted: Int? = nil) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: nil, avgHrv: nil,
                           stagesJSON: nil, userEdited: edited, startTsAdjusted: adjusted)
    }

    /// The night was edited when it was detected from 00:00 (bedtime corrected to 23:30); a re-score then
    /// trimmed its onset to 00:45. The edit must follow the night to its new startTs — not fall out as a
    /// separate "manual" block beside a fresh detected copy of the same night.
    func testEditFollowsItsNightByOverlap() {
        let edit = row(0, 8 * h, edited: true, adjusted: -30 * 60)
        let night = row(45 * 60, 8 * h)
        let nap = row(14 * h, 15 * h)
        let r = IntelligenceEngine.matchEditsToDetected([0: edit], detected: [night, nap])
        XCTAssertEqual(Set(r.edits.keys), [45 * 60])
        XCTAssertEqual(r.edits[45 * 60]?.startTsAdjusted, -30 * 60, "the edit's own corrected bedtime is kept")
        XCTAssertTrue(r.covered.isEmpty)
    }

    /// An exact twin keeps its key; a hand-logged block that overlaps nothing stays a manual block.
    func testExactTwinAndManualBlockAreUnchanged() {
        let edit = row(0, 8 * h, edited: true, adjusted: -30 * 60)
        let manual = row(18 * h, 19 * h, edited: true)
        let r = IntelligenceEngine.matchEditsToDetected([0: edit, 18 * h: manual], detected: [row(0, 8 * h)])
        XCTAssertEqual(Set(r.edits.keys), [0, 18 * h])
        XCTAssertTrue(r.covered.isEmpty)
    }

    /// The re-score split the edited night in two (00:45–03:00 and 03:20–08:00). The edit takes the fragment
    /// it overlaps most, and the other fragment — wholly inside the edited night — is marked covered so the
    /// night is not counted twice.
    func testSplitNightIsCoveredByTheEdit() {
        let edit = row(0, 8 * h, edited: true)
        let first = row(45 * 60, 3 * h)
        let second = row(3 * h + 20 * 60, 8 * h)
        let r = IntelligenceEngine.matchEditsToDetected([0: edit], detected: [first, second])
        XCTAssertEqual(Set(r.edits.keys), [3 * h + 20 * 60])
        XCTAssertEqual(r.covered, [45 * 60])
    }

    /// A small overlap (< half of the shorter span) is not a match: the edit stays where it was.
    func testGrazingOverlapIsNotAMatch() {
        let edit = row(0, 2 * h, edited: true)
        let later = row(2 * h - 10 * 60, 9 * h)
        let r = IntelligenceEngine.matchEditsToDetected([0: edit], detected: [later])
        XCTAssertEqual(Set(r.edits.keys), [0])
    }

    // MARK: - S10

    private func gate(strain: Double, workoutsOn: Set<Int> = []) -> [DailyMetric] {
        (0..<7).map { i in
            DailyMetric(day: String(format: "2026-08-%02d", 9 + i), totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 60,
                        avgHrv: nil, recovery: nil, strain: strain,
                        exerciseCount: workoutsOn.contains(i) ? 1 : 0)
        }
    }

    private func fitnessAge(_ days: [DailyMetric]) -> Double? {
        IntelligenceEngine.fitnessAgeRows(
            gateDays: days, age: 40, sex: "male", waistCm: 0, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-15"
        ).first { $0.key == "fitness_age" }?.value
    }

    /// Seven desk days at Effort 40 (the old `>= 30` rule counted all seven as active) are NOT active; three of
    /// them with a detected workout are. RHR 60 → the waking fallback 66 feeds Nes either way.
    func testActiveDayIsAWorkoutOrEffortFifty() throws {
        let desk = try XCTUnwrap(fitnessAge(gate(strain: 40)))
        XCTAssertEqual(desk, FitnessAgeEngine.fitnessAge(age: 40, sex: "male", restingHR: 66, paIndex: 0),
                       accuracy: 1e-6)
        let withWorkouts = try XCTUnwrap(fitnessAge(gate(strain: 40, workoutsOn: [0, 2, 4])))
        let pa3 = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 3, meanActiveStrain: 40)
        XCTAssertEqual(withWorkouts, FitnessAgeEngine.fitnessAge(age: 40, sex: "male", restingHR: 66, paIndex: pa3),
                       accuracy: 1e-6)
        let training = try XCTUnwrap(fitnessAge(gate(strain: 55)))
        let pa7 = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 55)
        XCTAssertEqual(training, FitnessAgeEngine.fitnessAge(age: 40, sex: "male", restingHR: 66, paIndex: pa7),
                       accuracy: 1e-6)
    }
}
