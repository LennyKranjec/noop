import XCTest
import StrandAnalytics
@testable import Strand

/// The issuing rules in `QuestGenerator.swift` that decide WHICH quests go out. What is pinned here:
///
///   * EVERY PAST DAY GETS ITS CARD. The plan reporter picks the earliest day not yet reported; it used to
///     stop at the oldest day outright, which is usually already reported, so no later card was shown.
///   * MAKE-UPS DO NOT SPEND THE SIDE BUDGET, and a metric a make-up is still open on is taken.
///   * A GEAR ONLY GOES UP once the day's plan is out; a downward re-pick keeps the higher gear.
///   * THE WEEK PLAN BOUNDS THE GEAR'S PLAN, applied once and not twice, and an illness heads-up makes the
///     day a rest day whatever the week plan said.
final class QuestIssuingRulesTests: XCTestCase {

    private let day = "2026-09-30"

    private func quest(id: String, metric: QuestMetric, state: QuestState = .active,
                       dayKey: String = "2026-09-30") -> Quest {
        Quest(id: id, kind: .side, title: "T", taunt: "", target: "x", rewards: [], xp: 10, state: state,
              dayKey: dayKey, createdAtMs: 0, goal: QuestGoal(metric: metric, threshold: 1))
    }

    // MARK: - The plan reporter

    func testTheEarliestUnreportedDayIsReportedEvenWhenTheOldestIsAlreadyReported() {
        let days = ["2026-09-26", "2026-09-26", "2026-09-27", "2026-09-28"]
        let reported: Set<String> = ["2026-09-26"]
        XCTAssertEqual(QuestPlanReporter.nextDayToReport(planDays: days, isReported: { reported.contains($0) }),
                       "2026-09-27")
    }

    func testNothingIsDueWhenEveryDayIsReported() {
        let days = ["2026-09-26", "2026-09-27"]
        XCTAssertNil(QuestPlanReporter.nextDayToReport(planDays: days, isReported: { _ in true }))
        XCTAssertNil(QuestPlanReporter.nextDayToReport(planDays: [], isReported: { _ in false }))
    }

    // MARK: - The side-quest budget

    func testMakeUpsAndPlanQuestsDoNotSpendTheSideBudget() {
        let plan = quest(id: QuestDayPlan.questId(day: day, metric: .steps), metric: .steps)
        let makeUp = quest(id: QuestDebt.questId(day: day, metric: .waterMl), metric: .waterMl)
        let triggered = quest(id: "side-1", metric: .meditationMinutes)
        let budget = QuestIssuer.sideBudgetQuests([plan, makeUp, triggered])
        XCTAssertEqual(budget.map(\.id), ["side-1"])
    }

    func testAnOpenMakeUpsMetricIsTakenAndAClosedOneIsNot() {
        let plan = quest(id: QuestDayPlan.questId(day: day, metric: .steps), metric: .steps)
        let declinedPlan = quest(id: QuestDayPlan.questId(day: day, metric: .strain), metric: .strain,
                                 state: .declined)
        // A make-up issued for an earlier day is still open: its metric is taken today too.
        let openMakeUp = quest(id: QuestDebt.questId(day: "2026-09-29", metric: .waterMl), metric: .waterMl,
                               dayKey: "2026-09-29")
        let lapsedMakeUp = quest(id: QuestDebt.questId(day: day, metric: .sleepHours), metric: .sleepHours,
                                 state: .declined)
        let today = [plan, declinedPlan, lapsedMakeUp]
        let taken = QuestIssuer.takenMetrics(existingToday: today, all: today + [openMakeUp])
        XCTAssertEqual(taken, [.steps, .waterMl])
    }

    // MARK: - The gear floor

    private func suite() -> UserDefaults {
        let name = "QuestIssuingRulesTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testAGearOnlyGoesUpOnceTheDayIsIssued() {
        XCTAssertEqual(QuestGearFloor.effective(picked: .steady, issued: nil), .steady)
        XCTAssertEqual(QuestGearFloor.effective(picked: .relentless, issued: .push), .relentless)
        XCTAssertEqual(QuestGearFloor.effective(picked: .steady, issued: .relentless), .relentless)
        XCTAssertEqual(QuestGearFloor.effective(picked: .push, issued: .push), .push)
    }

    func testTheStoredGearIsTheHighestIssuedAndIsPerDay() {
        let d = suite()
        QuestGearFloor.note(.relentless, for: day, d)
        QuestGearFloor.note(.steady, for: day, d)
        XCTAssertEqual(QuestGearFloor.issued(for: day, d), .relentless)
        XCTAssertNil(QuestGearFloor.issued(for: "2026-10-01", d))
        for i in 1...(QuestGearFloor.kept + 3) {
            QuestGearFloor.note(.push, for: String(format: "2026-08-%02d", i), d)
        }
        XCTAssertLessThanOrEqual((d.dictionary(forKey: QuestGearFloor.key) ?? [:]).count, QuestGearFloor.kept)
    }

    func testADownwardRePickSaysTheHigherGearStands() {
        let note = QuestGearFloor.downgradeNote(picked: .steady, held: .relentless)
        XCTAssertNotNil(note)
        XCTAssertTrue(note?.contains("Relentless") == true, note ?? "")
        XCTAssertNil(QuestGearFloor.downgradeNote(picked: .relentless, held: .push))
        XCTAssertNil(QuestGearFloor.downgradeNote(picked: .push, held: .push))
    }

    // MARK: - The week plan bounds the gear's plan

    private func baseline(dayState: QuestDayState? = nil, bedtime: Int? = nil) -> QuestBaseline {
        QuestBaseline(medianSteps: 8000, medianTrainingMinutes: 60, effortBand21: 8...14,
                      bedtimeTargetMin: bedtime, dayState: dayState)
    }

    private func guidance(_ kind: DayGuidance.Kind) -> DayGuidance {
        DayGuidance(day: day, kind: kind, notes: [], hrvNights: 20, charge: 60)
    }

    private func threshold(_ targets: [QuestPlanTarget], _ metric: QuestMetric) -> Double? {
        targets.first { $0.goal.metric == metric }?.goal.threshold
    }

    /// THE STATE IS APPLIED ONCE. The bridge undoes the gear's training factor, so it must get the plan at
    /// the gear's own factors: Relentless's 80 minutes back to a usual of ~62, at Steady's 0.75 → 45. Had the
    /// plan already applied moveHard (factor capped at 1.0 → 60 min), the bridge would cut it again to 35.
    func testAMoveHardDayIsBoundedOnceNotTwice() {
        let t = QuestPlanComposer.targets(baseline: baseline(), difficulty: .relentless, focus: nil, day: day,
                                          guidance: guidance(.moveHard), charge: 60)
        XCTAssertEqual(threshold(t, .workoutMinutes), 45)
        XCTAssertNil(threshold(t, .strain), "no strain directive on a day hard sessions move off")
        XCTAssertNotNil(threshold(t, .steps), "steps are never touched")
    }

    func testWithNoGuidanceAndNoChargeThePlanIsTheGearsOwn() {
        let b = baseline()
        let t = QuestPlanComposer.targets(baseline: b, difficulty: .push, focus: nil, day: day,
                                          guidance: nil, charge: nil)
        XCTAssertEqual(t, QuestDayPlan.plan(baseline: b, difficulty: .push, day: day))
    }

    func testAnAsPlannedDayLeavesThePlanAlone() {
        let b = baseline()
        let t = QuestPlanComposer.targets(baseline: b, difficulty: .relentless, focus: nil, day: day,
                                          guidance: guidance(.asPlanned), charge: 80)
        XCTAssertEqual(t, QuestDayPlan.plan(baseline: b, difficulty: .relentless, day: day))
    }

    func testAKnownLowChargeWithNoPlanStillCapsTrainingAtEasyMovement() {
        let t = QuestPlanComposer.targets(baseline: baseline(), difficulty: .relentless, focus: nil, day: day,
                                          guidance: nil, charge: 20)
        XCTAssertLessThanOrEqual(threshold(t, .workoutMinutes) ?? 0, WeekPlanQuestBridge.easyMovementCapMin)
        XCTAssertNil(threshold(t, .strain))
    }

    func testAnIllnessHeadsUpIsARestDayWhateverTheWeekPlanSaid() {
        let t = QuestPlanComposer.targets(baseline: baseline(dayState: .rest), difficulty: .relentless,
                                          focus: nil, day: day, guidance: guidance(.asPlanned), charge: 80)
        XCTAssertNil(threshold(t, .workoutMinutes))
        XCTAssertNil(threshold(t, .strain))
        XCTAssertNotNil(threshold(t, .steps))
    }

    func testTheAnchoredBedtimeSurvivesTheBridge() {
        let t = QuestPlanComposer.targets(baseline: baseline(bedtime: 22 * 60 + 30), difficulty: .push,
                                          focus: nil, day: day, guidance: guidance(.easy), charge: 60)
        XCTAssertEqual(threshold(t, .bedtimeBy), Double(22 * 60 + 30))
    }
}
