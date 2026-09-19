import XCTest
import StrandAnalytics
@testable import Strand

/// The wearer's own tasks in `QuestStore`: added active, persisted with the quests, ticked off by hand,
/// removed outright, and expired the same way every quest is.
@MainActor
final class CustomTaskStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CustomTaskStoreTests-\(UUID().uuidString)")
    }

    private func task(_ title: String, now: Date = Date(), dueInMs: Int64? = nil) -> Quest {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        return CustomTaskParser.makeQuest(
            CustomTaskDraft(title: title, dueAtMs: dueInMs.map { nowMs + $0 }), now: now)
    }

    func testAnAddedTaskIsActiveAndSurvivesARelaunch() {
        let store = QuestStore(defaults: defaults)
        let added = store.addCustom(task("Stretch Break"))
        XCTAssertEqual(added.state, .active)
        XCTAssertEqual(store.active.map(\.id), [added.id], "on Today's strip at once")

        let relaunched = QuestStore(defaults: defaults)
        XCTAssertEqual(relaunched.customTasks.map(\.id), [added.id])
        XCTAssertEqual(relaunched.customTasks.first?.kind, .custom)
    }

    func testCustomTasksAreListedNewestFirstAndOnlyCustom() {
        let store = QuestStore(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let older = store.addCustom(task("Older", now: t0))
        let newer = store.addCustom(task("Newer", now: t0.addingTimeInterval(60)))
        store.upsert(Quest(kind: .side, title: "System", taunt: "", target: "8000 steps", rewards: [],
                           xp: 40, state: .active, dayKey: "2027-01-15",
                           createdAtMs: Int64(t0.timeIntervalSince1970 * 1000) + 120_000))
        XCTAssertEqual(store.customTasks.map(\.id), [newer.id, older.id])
    }

    func testCheckingOffCompletesAndQueuesTheCompletion() {
        let store = QuestStore(defaults: defaults)
        let added = store.addCustom(task("Call mum"))
        store.checkOff(id: added.id)
        XCTAssertEqual(store.customTasks.first?.state, .completed)
        XCTAssertEqual(store.completions.map(\.id), [added.id])
        // Twice is still once.
        store.checkOff(id: added.id)
        XCTAssertEqual(store.completions.count, 1)
    }

    func testASystemQuestCannotBeCheckedOffOrRemovedThisWay() {
        let store = QuestStore(defaults: defaults)
        let system = Quest(kind: .side, title: "System", taunt: "", target: "8000 steps", rewards: [],
                           xp: 40, state: .active, dayKey: "2026-09-19",
                           createdAtMs: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsert(system)
        store.checkOff(id: system.id)
        store.removeCustom(id: system.id)
        XCTAssertEqual(store.quests.first?.state, .active)
        XCTAssertTrue(store.completions.isEmpty)
    }

    func testRemovingDeletesItFromStorage() {
        let store = QuestStore(defaults: defaults)
        let added = store.addCustom(task("Gone soon"))
        store.removeCustom(id: added.id)
        XCTAssertTrue(store.customTasks.isEmpty)
        XCTAssertTrue(QuestStore(defaults: defaults).customTasks.isEmpty)
    }

    func testAnUnfinishedTaskExpiresInRedLikeAnyQuest() {
        let store = QuestStore(defaults: defaults)
        let now = Date()
        let added = store.addCustom(task("Due soon", now: now, dueInMs: 10 * 60 * 1000))
        store.sweepExpired(now: now.addingTimeInterval(11 * 60))
        XCTAssertEqual(store.customTasks.first?.state, .declined)
        XCTAssertEqual(store.failures.map(\.id), [added.id])
    }
}
