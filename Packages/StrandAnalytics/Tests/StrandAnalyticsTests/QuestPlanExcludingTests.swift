import Foundation
import XCTest
@testable import StrandAnalytics

/// A running n-of-1 trial never gets a day-plan quest that pushes its own behaviour (HEALTH_V2 S1-B.7).
///
/// `QuestDayPlan.plan(…, excluding:)` removes the trial's conflicting metrics BEFORE the gear's count is
/// cut, so the next directive takes the freed slot and the gear still carries what it promised whenever the
/// baseline has enough other directives. With nothing excluded the plan is exactly what it always was.
final class QuestPlanExcludingTests: XCTestCase {

    private let day = "2026-09-29"

    private var full: QuestBaseline {
        QuestBaseline(medianSteps: 9_000, hydrationGoalMl: 3_400, medianTrainingMinutes: 40,
                      medianMeditationMinutes: 8, sleepNeedHours: 7.6,
                      medianSleepOnsetMinute: 23 * 60 + 20, effortBand21: 10...14)
    }

    private func metrics(_ targets: [QuestPlanTarget]) -> Set<QuestMetric> {
        Set(targets.map(\.goal.metric))
    }

    func testNothingExcludedIsTheSamePlan() {
        for gear in QuestDifficulty.allCases {
            XCTAssertEqual(QuestDayPlan.plan(baseline: full, difficulty: gear, day: day, excluding: []),
                           QuestDayPlan.plan(baseline: full, difficulty: gear, day: day))
        }
    }

    func testAnExcludedMetricIsNeverIssuedAndItsSlotIsRefilled() {
        for gear in QuestDifficulty.allCases {
            let plain = QuestDayPlan.plan(baseline: full, difficulty: gear, day: day)
            for metric in metrics(plain) where metric != .journal {
                let cut = QuestDayPlan.plan(baseline: full, difficulty: gear, day: day, excluding: [metric])
                XCTAssertFalse(metrics(cut).contains(metric), "\(gear) still issued \(metric)")
                let measured = cut.filter { $0.goal.metric != .journal }
                XCTAssertEqual(measured.count, gear.questCount,
                               "\(gear) lost a slot instead of refilling it when \(metric) was excluded")
            }
        }
    }

    func testTheCatalogsConflictsKeepATrialsBehaviourOffThePlan() throws {
        for id in ["screensOff60", "caffeineCutoff14", "walkAfterDinner10", "breathing10"] {
            let conflicts = try XCTUnwrap(HabitTrialCatalog.entry(id)).conflictingMetrics
            for gear in QuestDifficulty.allCases {
                let plan = QuestDayPlan.plan(baseline: full, difficulty: gear, day: day, excluding: conflicts)
                XCTAssertTrue(metrics(plan).isDisjoint(with: conflicts), "\(gear) plan conflicts with \(id)")
            }
        }
    }

    /// Excluding never invents a directive: a thin baseline with its only metric excluded is an empty day,
    /// not a padded one.
    func testExcludingTheOnlyDirectiveLeavesAnEmptyDay() {
        let thin = QuestBaseline(medianSteps: 9_000)
        XCTAssertTrue(QuestDayPlan.plan(baseline: thin, difficulty: .relentless, day: day,
                                        excluding: [.steps]).isEmpty)
    }
}
