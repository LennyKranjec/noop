import XCTest
import StrandAnalytics
@testable import Strand

/// A chosen-difficulty day closes in ONE card, not one per directive. What is pinned here:
///
///   * N UNMET PLAN DIRECTIVES PRODUCE NO RED CARDS OF THEIR OWN. They are still cancelled when their
///     window closes — a commitment does not quietly vanish — but the day is summarised once instead of
///     handing the wearer four punishments for aiming high.
///   * ORDINARY SIDE QUESTS AND THE DAILY ARE UNTOUCHED: each still gets its own card, one at a time.
///   * A COMPLETED PLAN DIRECTIVE IS NEVER SWEPT. It keeps its completion, and its XP with it.
///   * THE SUMMARY SHOWS ONCE, ACROSS A RELAUNCH. The guard is on disk and is spent only when a card is
///     actually shown.
@MainActor
final class QuestPlanSummaryTests: XCTestCase {

    private let day = "2026-09-29"

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "questplan.test.\(UUID().uuidString)")!
    }

    /// A day's worth of plan quests, all accepted, all issued yesterday so their window has closed.
    private func planQuest(_ metric: QuestMetric, threshold: Double, state: QuestState = .active,
                           createdAt: Int64) -> Quest {
        Quest(id: QuestDayPlan.questId(day: day, metric: metric),
              kind: .side,
              title: "Directive",
              taunt: "",
              target: "\(Int(threshold)) of \(metric.rawValue)",
              rewards: [.heart],
              xp: 70,
              state: state,
              dayKey: day,
              createdAtMs: createdAt,
              goal: QuestGoal(metric: metric, threshold: threshold))
    }

    private func sideQuest(_ id: String, createdAt: Int64) -> Quest {
        Quest(id: id, kind: .side, title: "Side", taunt: "", target: "8000 steps", rewards: [.heart],
              xp: 40, state: .active, dayKey: day, createdAtMs: createdAt,
              goal: QuestGoal(metric: .steps, threshold: 8_000))
    }

    /// Yesterday morning, as milliseconds — so every window below has closed by `now`.
    private var yesterdayMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) - 30 * 3_600_000 }

    // MARK: - The sweep

    func testFourUnmetPlanDirectivesQueueNoRedCardsOfTheirOwn() {
        let store = QuestStore(defaults: suite())
        let created = yesterdayMs
        for (i, metric) in [QuestMetric.steps, .waterMl, .workoutMinutes, .meditationMinutes].enumerated() {
            store.upsert(planQuest(metric, threshold: 100, createdAt: created + Int64(i)))
        }
        store.sweepExpired()
        // Cancelled, as any expired commitment is...
        XCTAssertEqual(store.forDay(day).filter { $0.state == .declined }.count, 4)
        // ...but with nothing queued. The day is summarised once instead.
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testAnOrdinarySideQuestStillGetsItsOwnCard() {
        let store = QuestStore(defaults: suite())
        let created = yesterdayMs
        store.upsert(sideQuest("side-one", createdAt: created))
        store.upsert(sideQuest("side-two", createdAt: created + 1))
        store.upsert(planQuest(.steps, threshold: 100, createdAt: created + 2))
        store.sweepExpired()
        // Two cards for the two triggered quests, and none for the plan directive beside them.
        XCTAssertEqual(store.failures.count, 2)
        XCTAssertEqual(Set(store.failures.map(\.quest.id)), ["side-one", "side-two"])
    }

    func testACompletedPlanDirectiveIsNeverSweptIntoTheSummaryAsAFailure() {
        let store = QuestStore(defaults: suite())
        let created = yesterdayMs
        store.upsert(planQuest(.steps, threshold: 100, state: .completed, createdAt: created))
        store.upsert(planQuest(.waterMl, threshold: 100, createdAt: created + 1))
        store.sweepExpired()
        let steps = store.quests.first { $0.id == QuestDayPlan.questId(day: day, metric: .steps) }
        XCTAssertEqual(steps?.state, .completed)
        XCTAssertTrue(store.failures.isEmpty)
    }

    func testAnOfferedPlanDirectiveThatWasNeverAcceptedIsStillWithdrawnSilently() {
        let store = QuestStore(defaults: suite())
        store.upsert(planQuest(.steps, threshold: 100, state: .offered, createdAt: yesterdayMs))
        store.sweepExpired()
        XCTAssertEqual(store.forDay(day).first?.state, .declined)
        XCTAssertTrue(store.failures.isEmpty)
    }

    // MARK: - Showing the summary once

    private func report() -> QuestPlanDayReport {
        QuestPlanDayReport(day: day, difficulty: .relentless, lines: [
            QuestPlanLine(target: "12250 steps", outcome: .short, reading: "8,400 of 12,250."),
            QuestPlanLine(target: "A day strain of 14", outcome: .notMeasured),
        ])
    }

    func testTheSummaryIsPresentedOnce() {
        let store = QuestStore(defaults: suite())
        XCTAssertTrue(store.presentPlanReport(report()))
        XCTAssertEqual(store.planReport?.day, day)
        // A second pass in the same session finds it already up and does nothing.
        XCTAssertFalse(store.presentPlanReport(report()))
        store.dismissPlanReport()
        XCTAssertNil(store.planReport)
        // And once dismissed it does not come back.
        XCTAssertFalse(store.presentPlanReport(report()))
    }

    func testTheSummaryDoesNotComeBackAfterARelaunch() {
        let defaults = suite()
        XCTAssertTrue(QuestStore(defaults: defaults).presentPlanReport(report()))
        let relaunched = QuestStore(defaults: defaults)
        XCTAssertNil(relaunched.planReport)
        XCTAssertTrue(relaunched.planDayReported(day))
        XCTAssertFalse(relaunched.presentPlanReport(report()))
    }

    func testADayClosedWithNoCardIsStillNotLookedAtAgain() {
        // The "nothing to summarise" paths — no difficulty was ever chosen, or every directive was met.
        let store = QuestStore(defaults: suite())
        XCTAssertFalse(store.planDayReported(day))
        store.notePlanDayReported(day)
        XCTAssertTrue(store.planDayReported(day))
        XCTAssertFalse(store.presentPlanReport(report()))
        XCTAssertNil(store.planReport)
    }

    func testEachDayIsClosedOnItsOwn() {
        let store = QuestStore(defaults: suite())
        store.notePlanDayReported(day)
        XCTAssertFalse(store.planDayReported("2026-09-30"))
        XCTAssertTrue(store.presentPlanReport(
            QuestPlanDayReport(day: "2026-09-30", difficulty: .steady,
                               lines: [QuestPlanLine(target: "x", outcome: .short, reading: "y")])))
    }

    func testOnlyTheLastMonthOfClosedDaysIsRemembered() {
        let store = QuestStore(defaults: suite())
        for d in 1...(QuestStore.reportedKept + 4) {
            store.notePlanDayReported(String(format: "2026-09-%02d", d))
        }
        // The oldest fall off; a day that old is long past being news either way.
        XCTAssertFalse(store.planDayReported("2026-09-01"))
        XCTAssertTrue(store.planDayReported(String(format: "2026-09-%02d", QuestStore.reportedKept + 4)))
    }
}

/// The quest strip's review presenter must outlive the row it is opened from.
///
/// WHAT IS AND IS NOT TESTABLE HERE. That the `.sheet` sits on the strip's root rather than inside the
/// branch that draws the chips is STRUCTURAL — proving it would need a view-hierarchy snapshot, which this
/// suite has no machinery for. What IS pure, and what the defect turned on, is the content rule: the
/// strip's row can legitimately have nothing to draw, so any presenter hung off the row is one the row's
/// own actions can tear down. These pin that the rule really does go empty (so the hazard is real and not
/// theoretical), and that resolving the last quest is not the same thing as the strip having nothing to
/// say when a gear was picked.
@MainActor
final class QuestStripContentTests: XCTestCase {

    func testTheRowHasNothingToDrawOnADayWithNoGearAndNoQuests() {
        // The case the presenter was being torn down by: resolving the last active quest from the review
        // sheet, on a day the wearer was never asked about, empties the row underneath it.
        XCTAssertFalse(QuestStripView.hasContent(mode: nil, activeCount: 0))
        XCTAssertTrue(QuestStripView.hasContent(mode: nil, activeCount: 1))
    }

    func testAPickedGearKeepsTheStripAfterTheLastQuestResolves() {
        // Not an empty card and not a blank row: the gear the wearer chose is still worth saying.
        for difficulty in QuestDifficulty.allCases {
            XCTAssertTrue(QuestStripView.hasContent(mode: difficulty, activeCount: 0))
            XCTAssertTrue(QuestStripView.hasContent(mode: difficulty, activeCount: 3))
        }
    }
}
