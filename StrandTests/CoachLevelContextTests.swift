import XCTest
import StrandAnalytics
@testable import Strand

/// The coach's level section (`CoachLevelContext`). Pinned:
///
///   * H5: the level is a lens, never the objective. The old "primary objective is to raise this score"
///     wording is gone, and the section opens with the health objective and its three prohibitions.
///   * THE RECIPE IS THE ENGINE'S (epoch 4): the weights and shares are read from `LevelEngine`, focus is
///     daytime calm only, meditation is deduction-only with its date-effective minimum.
final class CoachLevelContextTests: XCTestCase {

    func testTheSectionOpensWithTheHealthObjective() {
        let s = CoachLevelContext.promptSection()
        XCTAssertTrue(s.hasPrefix("THE LEVEL. The level is one lens on long-term trends."), s)
        XCTAssertTrue(s.contains("Your objective is the wearer's health."), s)
        XCTAssertTrue(s.contains("Never advise more training load, less sleep or skipping recovery to raise the level."), s)
        XCTAssertFalse(s.uppercased().contains("PRIMARY OBJECTIVE"), s)
    }

    func testTheRecipeIsTheEnginesOwn() {
        let r = CoachLevelContext.recipe()
        for part in LevelPart.allCases {
            XCTAssertTrue(r.contains("\(part.rawValue) \(Int((part.weight * 100).rounded()))%"), r)
        }
        XCTAssertTrue(r.contains("sleep = 0.60 × deep+REM"), r)
        XCTAssertTrue(r.contains("0.25 × night HRV"), r)
        XCTAssertTrue(r.contains("0.15 × bed/wake regularity"), r)
        XCTAssertTrue(r.contains("heart = 0.50 × HRV + 0.50 × resting HR"), r)
        XCTAssertTrue(r.contains("lungs = 0.75 × VO2max"), r)
        XCTAssertTrue(r.contains("muscle = 0.60 × strength"), r)
        XCTAssertTrue(r.contains("focus = daytime calm only"), r)
    }

    func testMeditationOnlyDeductsWithTheDateEffectiveMinimum() {
        let r = CoachLevelContext.recipe()
        XCTAssertTrue(r.contains("meditation only deducts: 1 point per missed day"), r)
        XCTAssertTrue(r.contains("5 min before \(LevelEngine.meditationMinChangeoverDay) and 10 min from it"), r)
        XCTAssertFalse(r.contains("28-day share"), r)
        XCTAssertFalse(r.contains("steps, calm, meditation"), "meditation is not an activity input any more: \(r)")
    }

    func testTheCoachIsNotToldToChaseTheLevelInTheStateTile() {
        XCTAssertTrue(WorkoutSuggestionWriter.levelObjective.hasSuffix(CoachLevelContext.objective))
        XCTAssertFalse(WorkoutSuggestionWriter.levelObjective.contains("focus short → meditation"))
    }
}
