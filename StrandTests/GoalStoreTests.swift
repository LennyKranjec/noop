import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Goal persistence (DESIGN_V2 decision 14): goals survive a relaunch in `goals.json`, an unreadable file is
/// set aside rather than overwritten, a reached goal raises its full-screen moment exactly once (queued
/// until FRAME's presenter is wired), a passed date is marked reviewed and never produces a moment, and the
/// archive stays bounded without ever dropping an active goal.
@MainActor
final class GoalStoreTests: XCTestCase {

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("goalstore-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private var url: URL { dir.appendingPathComponent(GoalStore.fileName) }

    private func assessment(_ g: Goal, _ verdict: GoalVerdict, current: Double?) -> GoalAssessment {
        GoalAssessment(goal: g, verdict: verdict, current: current, currentWeek: "2026-09-21", weeksLeft: 4,
                       requiredPerWeek: nil, projectedAtDate: nil, noBandReason: nil, plausible: nil,
                       plausiblePerWeek: nil, realisticDate: nil, realisticValue: nil, review: nil, caveats: [])
    }

    func testGoalsPersistAcrossInstances() {
        let a = GoalStore(fileURL: url)
        let g = a.add(metric: .restingHR, target: 52, targetDate: "2026-12-20", startDate: "2026-10-01",
                      current: 58, today: "2026-09-30")
        XCTAssertEqual(g.direction, .decrease)
        a.add(metric: .e1rm(lift: "Squat"), target: 140, targetDate: "2027-01-31", current: 120, today: "2026-09-30")
        let b = GoalStore(fileURL: url)
        XCTAssertEqual(b.goals.count, 2)
        XCTAssertEqual(b.goals.first { $0.id == g.id }, g)
        XCTAssertEqual(b.goals.first { $0.metric.kind == .e1rm }?.metric.qualifier, "Squat")

        b.update(id: g.id, target: 50, targetDate: "2027-01-10", startDate: nil, current: 57)
        let c = GoalStore(fileURL: url)
        XCTAssertEqual(c.goals.first { $0.id == g.id }?.target, 50)
        XCTAssertNil(c.goals.first { $0.id == g.id }?.startDate)

        c.archive(id: g.id)
        XCTAssertEqual(GoalStore(fileURL: url).activeGoals.count, 1)
        c.remove(id: g.id)
        XCTAssertEqual(GoalStore(fileURL: url).goals.count, 1)
    }

    func testUnreadableFileIsSetAsideNotOverwritten() throws {
        try Data("not json".utf8).write(to: url)
        let s = GoalStore(fileURL: url)
        XCTAssertTrue(s.goals.isEmpty)
        let aside = dir.appendingPathComponent("goals.unreadable.json")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "not json")
    }

    func testReachedRaisesTheMomentOnceAndQueuesUntilThePresenterExists() {
        let s = GoalStore(fileURL: url)
        let g = s.add(metric: .level, target: 110, targetDate: "2026-12-01", current: 96, today: "2026-09-30")
        s.noteAssessments([assessment(g, .reached, current: 112)], today: "2026-10-05")
        XCTAssertEqual(s.pendingMoments.count, 1)
        XCTAssertEqual(s.pendingMoments.first?.id, "goal.reached.\(g.id)")
        // Fire-once: the same verdict again raises nothing.
        s.noteAssessments([assessment(g, .reached, current: 113)], today: "2026-10-06")
        XCTAssertEqual(s.pendingMoments.count, 1)
        XCTAssertEqual(GoalStore(fileURL: url).goals.first?.reachedOn, "2026-10-05")

        var delivered: [TelosMoment] = []
        s.momentSink = { delivered.append($0) }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertTrue(s.pendingMoments.isEmpty)
    }

    func testReachedMomentCarriesTheExactFiguresAndAnUnclampedFill() {
        let g = Goal(id: "x", metric: .level, target: 110, targetDate: "2026-12-01", createdOn: "2026-09-01",
                     startValue: 90, direction: .increase)
        let m = GoalStore.reachedMoment(assessment(g, .reached, current: 130), today: "2026-10-05")
        XCTAssertEqual(m.figures.map(\.value), ["110", "130", "90"])
        XCTAssertEqual(m.fill ?? 0, 2.0, accuracy: 1e-12, "above 1 is drawn honestly, never clamped")
        XCTAssertEqual(m.tone, .positive)
    }

    func testPassedDateIsReviewedWithoutAMoment() {
        let s = GoalStore(fileURL: url)
        let g = s.add(metric: .steps, target: 9000, targetDate: "2026-09-15", current: 7000, today: "2026-08-01")
        s.noteAssessments([assessment(g, .datePassed, current: 8200)], today: "2026-09-30")
        XCTAssertTrue(s.pendingMoments.isEmpty)
        XCTAssertEqual(GoalStore(fileURL: url).goals.first?.reviewedOn, "2026-09-30")
    }

    func testBoundedKeepsEveryActiveGoal() {
        var goals: [Goal] = []
        for i in 0..<(GoalStore.maxGoals + 30) {
            goals.append(Goal(id: "g\(i)", metric: .level, target: 100, targetDate: "2027-01-01",
                              createdOn: String(format: "2026-%02d-%02d", 1 + i % 12, 1 + i % 28),
                              startValue: nil, direction: .increase, archived: i >= 20))
        }
        let kept = GoalStore.bounded(goals)
        XCTAssertEqual(kept.count, GoalStore.maxGoals)
        XCTAssertEqual(kept.filter { !$0.archived }.count, 20)
    }
}
