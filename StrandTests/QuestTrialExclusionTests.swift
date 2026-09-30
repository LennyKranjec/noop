import XCTest
import StrandAnalytics
@testable import Strand

/// A running trial's conflicting metrics are kept off the day's plan on BOTH of the composer's branches:
/// the gear's own plan, and the plan the week-plan bridge bounds. The bridge only maps and drops targets,
/// so a metric excluded before it can never come back after it.
final class QuestTrialExclusionTests: XCTestCase {

    private let day = "2026-09-30"

    private func baseline(bedtime: Int? = 22 * 60 + 30) -> QuestBaseline {
        QuestBaseline(medianSteps: 8000, medianTrainingMinutes: 60, sleepNeedHours: 7.5,
                      effortBand21: 8...14, bedtimeTargetMin: bedtime)
    }

    private func metrics(_ t: [QuestPlanTarget]) -> Set<QuestMetric> { Set(t.map(\.goal.metric)) }

    func testTheGearsOwnPlanHonoursTheExclusion() {
        let t = QuestPlanComposer.targets(baseline: baseline(), difficulty: .relentless, focus: nil, day: day,
                                          guidance: nil, charge: nil, excluding: [.bedtimeBy, .bedtimeEarlier])
        XCTAssertFalse(metrics(t).contains(.bedtimeBy))
        XCTAssertTrue(metrics(t).contains(.steps))
    }

    func testTheBridgedPlanHonoursTheExclusion() {
        let guidance = DayGuidance(day: day, kind: .easy, notes: [], hrvNights: 20, charge: 60)
        let t = QuestPlanComposer.targets(baseline: baseline(), difficulty: .push, focus: nil, day: day,
                                          guidance: guidance, charge: 60, excluding: [.steps])
        XCTAssertFalse(metrics(t).contains(.steps))
        XCTAssertFalse(t.isEmpty)
    }

    func testNoExclusionIsTheSameComposition() {
        let b = baseline()
        XCTAssertEqual(QuestPlanComposer.targets(baseline: b, difficulty: .push, focus: nil, day: day,
                                                 guidance: nil, charge: nil),
                       QuestPlanComposer.targets(baseline: b, difficulty: .push, focus: nil, day: day,
                                                 guidance: nil, charge: nil, excluding: []))
    }
}
