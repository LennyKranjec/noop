import XCTest
import StrandAnalytics
@testable import Strand

/// HEALTH_V2 H7 / H8 — what the illness engine is fed, and what it may push.
///
///   * An imported night stores ABSOLUTE wrist °C in `skinTempDevC`; ~33 °C / 0.3 was a z of ~110 and a
///     heads-up out of nothing. Absolute °C never produces a skin signal.
///   * Confounders match on exact starter-question identity: "ill" no longer matches "pill".
///   * A hard or late workout comes from the workout table.
///   * Only the `raised` level pushes, titled "Body off baseline"; `alreadyUnwell` never pushes.
final class IllnessSkinTempFilterTests: XCTestCase {

    // MARK: - H7a: skin temperature

    /// The reproduction: two imported nights of absolute wrist temperature.
    func testAbsoluteImportedCelsiusNeverProducesASkinSignal() {
        let imported: [Double?] = [33.4, 33.1]
        // The old arithmetic, for the record: this is the z ≈ 110 false alarm.
        XCTAssertGreaterThan((33.4 + 33.1) / 2 / 0.3, 100)
        XCTAssertNil(IllnessInputFilter.skinZ(recent: imported))
        XCTAssertNil(IllnessInputFilter.recentSkinDeviation(recent: imported))
        // And through the engine: with RHR and HRV quiet, absolute °C cannot raise anything.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: IllnessSignalEngine.SignalReading(zIllnessward: 0.2),
            skinTemp: IllnessInputFilter.skinZ(recent: imported).map { IllnessSignalEngine.SignalReading(zIllnessward: $0) },
            hrv: IllnessSignalEngine.SignalReading(zIllnessward: 0.1),
            respiration: nil)
        XCTAssertNil(inputs.skinTemp)
        let result = IllnessSignalEngine.evaluate(inputs, context: IllnessSignalEngine.Context(), firedLabels: [:])
        XCTAssertNotEqual(result.level, .raised)
    }

    func testAMixOfAbsoluteAndDeviationKeepsOnlyTheDeviation() throws {
        let z = try XCTUnwrap(IllnessInputFilter.skinZ(recent: [33.2, 0.6]))
        XCTAssertEqual(z, 0.6 / 0.3, accuracy: 1e-9)
        XCTAssertEqual(IllnessInputFilter.skinDeviations([nil, Double.nan, 0.4, -0.2, 34]), [0.4, -0.2])
    }

    func testARealDeviationStillReads() throws {
        XCTAssertEqual(try XCTUnwrap(IllnessInputFilter.skinZ(recent: [0.6, 0.6])), 2, accuracy: 1e-9)
    }

    // MARK: - H7b: confounders

    func testConfoundersMatchTheStarterQuestionsExactlyNotBySubstring() {
        let pill = IllnessInputFilter.journalFlags([(question: "Did you take a sleeping pill?", answeredYes: true),
                                                    (question: "Did you drink enough water?", answeredYes: true)])
        XCTAssertEqual(pill, IllnessInputFilter.JournalFlags(), "\"pill\" is not \"ill\", water is not alcohol")
        let flags = IllnessInputFilter.journalFlags([
            (question: "Did you drink any alcohol?", answeredYes: true),
            (question: "did you feel  STRESSED?", answeredYes: true),   // normalised like the catalog
            (question: "Did you use a sauna?", answeredYes: true),
            (question: "Did you feel sick or ill?", answeredYes: false),
        ])
        XCTAssertTrue(flags.alcohol)
        XCTAssertTrue(flags.stress)
        XCTAssertTrue(flags.sauna)
        XCTAssertFalse(flags.alreadyUnwell, "a logged NO is not unwell")
    }

    func testTheConfounderQuestionsAreStarterQuestions() {
        for q in [IllnessInputFilter.alcoholQuestion, IllnessInputFilter.stressQuestion,
                  IllnessInputFilter.saunaQuestion, IllnessInputFilter.unwellQuestion] {
            XCTAssertTrue(JournalCatalogStore.starterQuestions.contains(q), q)
        }
    }

    func testAHardOrLateWorkoutComesFromTheWorkoutTable() {
        let onset = 1_800_000_000
        // Ended 2 h before sleep: late.
        XCTAssertTrue(IllnessInputFilter.hardOrLateWorkout(
            workouts: [(endTs: onset - 2 * 3600, effort: 10)], historyEfforts: [], nightOnsets: [onset]))
        // Ended 5 h before, ordinary effort: neither.
        let history = [20.0, 30, 35, 40, 45, 50, 55, 60, 65, 70]
        XCTAssertFalse(IllnessInputFilter.hardOrLateWorkout(
            workouts: [(endTs: onset - 5 * 3600, effort: 30)], historyEfforts: history, nightOnsets: [onset]))
        // Ended 5 h before, top quartile of the wearer's own sessions: hard.
        XCTAssertTrue(IllnessInputFilter.hardOrLateWorkout(
            workouts: [(endTs: onset - 5 * 3600, effort: 68)], historyEfforts: history, nightOnsets: [onset]))
        // Too few sessions for a quartile: only the timing rule applies.
        XCTAssertFalse(IllnessInputFilter.hardOrLateWorkout(
            workouts: [(endTs: onset - 5 * 3600, effort: 99)], historyEfforts: [99, 10], nightOnsets: [onset]))
    }

    // MARK: - H7c / H8: the push

    private func result(_ level: IllnessSignalEngine.Level) -> IllnessSignalEngine.Result {
        IllnessSignalEngine.Result(score: 3, level: level, firedSignals: ["RHR +6", "HRV −18%"],
                                   suppressedBy: [], signalCount: 2, copy: "copy")
    }

    func testOnlyARaisedHeadsUpPushesAndItIsTitledBodyOffBaseline() throws {
        let raised = try XCTUnwrap(IllnessNotifier.content(for: result(.raised)))
        XCTAssertEqual(raised.title, "Body off baseline")
        XCTAssertFalse(raised.title.contains("Early warning"))
        XCTAssertTrue(raised.subtitle.contains("not a diagnosis"))
        XCTAssertTrue(raised.body.contains("RHR +6"))
        XCTAssertTrue(raised.body.contains("HRV −18%"))
        XCTAssertNil(IllnessNotifier.content(for: result(.alreadyUnwell)), "no push on the alreadyUnwell path")
        XCTAssertNil(IllnessNotifier.content(for: result(.suppressed)))
        XCTAssertNil(IllnessNotifier.content(for: result(.mild)))
    }
}
