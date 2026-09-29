import XCTest
import StrandAnalytics
@testable import Strand

/// The quest store and the game layer's books, wired together. What is pinned here:
///
///   * A COMPLETION PAYS, ONCE. The XP goes on the books when the quest closes, and a second report of
///     the same completion pays nothing.
///   * AN ACCEPTED QUEST THAT RUNS OUT IS QUEUED FOR JUDGEMENT, not charged by the clock — the data decides
///     (`QuestPenaltyAssessor`). A plan quest carries its day's gear; nothing else does.
///   * ABANDONING IS CONCEDING: an accepted quest given up is still judged at its own deadline.
///   * A MAKE-UP THAT RUNS OUT LAPSES: no red card, no second penalty for the same miss.
///   * THE DAY'S CARD WAITS FOR THE DAY'S JUDGEMENTS, and the fire-once guard is not spent while it waits.
///   * THE PINNED BOARD shows only when there is something on it.
///   * The existing single-card-per-day and per-quest failure behaviour is untouched (see
///     `QuestPlanSummaryTests`, which runs these stores without the books).
@MainActor
final class QuestPenaltyStoreTests: XCTestCase {

    /// Yesterday, relative to the real clock: the ledger only judges days it can still read reliably
    /// (`QuestPenaltyRules.judgeableMaxAgeDays`), so a fixed date would start failing once it aged out.
    private let day = DailyMissionStore.dayKey(Date().addingTimeInterval(-86_400))

    private func stores() -> (QuestStore, QuestPenaltyStore, QuestModeStore) {
        let defaults = UserDefaults(suiteName: "questpenalty.test.\(UUID().uuidString)")!
        let modes = QuestModeStore(defaults: defaults)
        let penalties = QuestPenaltyStore(defaults: defaults, modes: modes)
        return (QuestStore(defaults: defaults, penalties: penalties), penalties, modes)
    }

    /// Thirty hours ago, so a one-day window has closed by now.
    private var yesterdayMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) - 30 * 3_600_000 }

    private func quest(_ id: String, kind: QuestKind = .side, state: QuestState = .active,
                       createdAt: Int64? = nil, xp: Int = 40,
                       goal: QuestGoal? = QuestGoal(metric: .steps, threshold: 8_000)) -> Quest {
        Quest(id: id, kind: kind, title: "Q-\(id)", taunt: "", target: "target-\(id)", rewards: [.heart],
              xp: xp, state: state, dayKey: day, createdAtMs: createdAt ?? yesterdayMs, goal: goal)
    }

    // MARK: - Paying

    func testACompletionPaysOnce() {
        let (store, penalties, _) = stores()
        let q = quest("done", createdAt: Int64(Date().timeIntervalSince1970 * 1000))
        store.upsert(q)
        store.complete(q, summary: "met")
        XCTAssertEqual(penalties.ledger.balance, 40)
        store.complete(q, summary: "met")       // already completed: ignored
        penalties.credit(q)                     // and a stray second credit pays nothing
        XCTAssertEqual(penalties.ledger.balance, 40)
    }

    func testEarlierCompletionsArePaidInOnce() {
        let defaults = UserDefaults(suiteName: "questpenalty.seed.\(UUID().uuidString)")!
        let plain = QuestStore(defaults: defaults)
        plain.upsert(quest("old", state: .completed, xp: 60))
        let penalties = QuestPenaltyStore(defaults: defaults, modes: QuestModeStore(defaults: defaults))
        _ = QuestStore(defaults: defaults, penalties: penalties)
        _ = QuestStore(defaults: defaults, penalties: penalties)
        XCTAssertEqual(penalties.ledger.balance, 60)
        XCTAssertTrue(penalties.ledger.seeded)
    }

    // MARK: - Queueing for judgement

    func testAnExpiredAcceptedQuestIsQueuedNotCharged() {
        let (store, penalties, _) = stores()
        store.upsert(quest("late"))
        store.sweepExpired()
        XCTAssertTrue(penalties.isPending("late"))
        XCTAssertEqual(penalties.ledger.balance, 0)      // nothing charged by the clock
        store.sweepExpired()
        XCTAssertEqual(penalties.ledger.pending.count, 1)
        // Its own red card is still queued, exactly as before.
        XCTAssertEqual(store.failures.map(\.quest.id), ["late"])
    }

    func testAnOfferedQuestThatRunsOutIsNotJudged() {
        let (store, penalties, _) = stores()
        store.upsert(quest("never-accepted", state: .offered))
        store.sweepExpired()
        XCTAssertFalse(penalties.isPending("never-accepted"))
    }

    func testAQuestWithNothingToMeasureIsNeverQueued() {
        let (store, penalties, _) = stores()
        store.upsert(quest("vibes", kind: .custom, goal: nil))
        store.sweepExpired()
        XCTAssertTrue(penalties.ledger.pending.isEmpty)
    }

    func testAPlanQuestCarriesItsDaysGearAndNothingElseDoes() {
        let (store, penalties, modes) = stores()
        modes.set(.relentless, for: day)
        store.upsert(quest(QuestDayPlan.questId(day: day, metric: .steps)))
        store.upsert(quest("side"))
        store.sweepExpired()
        let planId = QuestDayPlan.questId(day: day, metric: .steps)
        XCTAssertEqual(penalties.ledger.pending.first { $0.questId == planId }?.gear, .relentless)
        XCTAssertNil(penalties.ledger.pending.first { $0.questId == "side" }?.gear)
    }

    func testAbandoningAnAcceptedQuestStillQueuesItAtItsDeadline() {
        let (store, penalties, _) = stores()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let q = quest("quit", createdAt: now)
        store.upsert(q)
        store.abandon(id: "quit")
        XCTAssertEqual(store.quests.first { $0.id == "quit" }?.state, .declined)
        XCTAssertEqual(penalties.ledger.pending.first?.judgeAfterMs, q.checkableUntilMs())
        // Turning down an OFFER promised nothing, and is not judged.
        store.upsert(quest("offer", state: .offered, createdAt: now))
        store.abandon(id: "offer")
        XCTAssertFalse(penalties.isPending("offer"))
    }

    // MARK: - Make-ups

    private func judgedWithDebt(_ penalties: QuestPenaltyStore, store: QuestStore) -> QuestDebt? {
        let today = DailyMissionStore.dayKey()
        let missed = quest("missed", createdAt: yesterdayMs)
        store.upsert(missed)
        store.sweepExpired()
        let result = penalties.judge(questId: "missed", evidence: QuestEvidence(steps: 2_000),
                                     nowMs: Int64(Date().timeIntervalSince1970 * 1000) + 1,
                                     context: QuestDebtContext(today: today, charge: 70))
        guard case .judged(let judgement) = result else { return nil }
        return judgement.debt
    }

    func testAnExpiredMakeUpLapsesWithoutACardOrASecondPenalty() {
        let (store, penalties, _) = stores()
        guard let debt = judgedWithDebt(penalties, store: store) else {
            return XCTFail("expected a make-up")
        }
        let charged = penalties.ledger.balance
        XCTAssertLessThan(charged, 0)
        let failuresBefore = store.failures.count
        store.issueDebt(Quest(id: debt.questId, kind: .side, title: "Make-Up", taunt: "", target: debt.target,
                              rewards: debt.rewards, xp: 10, state: .active, dayKey: debt.dayKey,
                              createdAtMs: yesterdayMs, goal: debt.goal))
        store.sweepExpired()
        XCTAssertEqual(store.failures.count, failuresBefore)         // no red card for a make-up
        XCTAssertEqual(penalties.ledger.balance, charged)            // and nothing more charged
        XCTAssertTrue(penalties.ledger.openDebts.isEmpty)
    }

    func testCompletingAMakeUpRestoresHalfOfTheLoss() {
        let (store, penalties, _) = stores()
        guard let debt = judgedWithDebt(penalties, store: store) else {
            return XCTFail("expected a make-up")
        }
        let charged = penalties.ledger.balance
        let makeUp = Quest(id: debt.questId, kind: .side, title: "Make-Up", taunt: "", target: debt.target,
                           rewards: debt.rewards, xp: 150, state: .active, dayKey: debt.dayKey,
                           createdAtMs: Int64(Date().timeIntervalSince1970 * 1000), goal: debt.goal)
        store.issueDebt(makeUp)
        store.complete(makeUp, summary: "met")
        XCTAssertEqual(penalties.ledger.balance, charged + debt.restoreXp)    // not + 150
        XCTAssertEqual(penalties.ledger.judgements.first?.debt?.state, .cleared)
    }

    func testTheMakeUpQuestIsDueByTheEndOfItsDay() {
        let debt = QuestDebt(questId: QuestDebt.questId(day: "2026-09-29", metric: .steps), dayKey: "2026-09-29",
                             metric: .steps, threshold: 12_000, target: "12000 steps today", restoreXp: 20)
        let judgement = QuestJudgement(questId: "q", kind: .side, dayKey: "2026-09-28", title: "Ground Covered",
                                       target: "t", metric: .steps, threshold: 10_000, gear: .push,
                                       judgedAtMs: 0, outcome: .penalised, reading: "", applied: -40, debt: debt)
        let q = QuestPenaltyAssessor.debtQuest(debt, for: judgement, nowMs: 0)
        XCTAssertEqual(q.state, .active)
        XCTAssertEqual(q.goal, debt.goal)
        XCTAssertTrue(QuestDebt.isDebtQuest(q.id))
        XCTAssertFalse(QuestDayPlan.isPlanQuest(q))       // never mistaken for part of a day's plan
        let end = Calendar.current.date(byAdding: .day, value: 1,
                                        to: Calendar.current.startOfDay(for: LocalDay.date("2026-09-29")))!
        XCTAssertEqual(q.expiresAtMs, Int64(end.timeIntervalSince1970 * 1000))
    }

    // MARK: - The day's card

    func testTheDaysCardWaitsForItsJudgementsWithoutSpendingTheGuard() {
        let (store, penalties, _) = stores()
        let planId = QuestDayPlan.questId(day: day, metric: .steps)
        store.upsert(quest(planId))
        store.sweepExpired()
        XCTAssertTrue(penalties.hasPendingPlanJudgement(day: day))
        let report = QuestPlanDayReport(day: day, difficulty: .push, lines: [
            QuestPlanLine(target: "target-\(planId)", outcome: .short, reading: "2,000 steps"),
        ])
        XCTAssertFalse(store.presentPlanReport(report))
        XCTAssertFalse(store.planDayReported(day))           // the guard is not spent while it waits
        _ = penalties.judge(questId: planId, evidence: QuestEvidence(steps: 2_000),
                            nowMs: Int64(Date().timeIntervalSince1970 * 1000) + 1,
                            context: QuestDebtContext(today: DailyMissionStore.dayKey(), charge: 70))
        XCTAssertTrue(store.presentPlanReport(report))
        XCTAssertFalse(store.presentPlanReport(report))      // and still once
    }

    // MARK: - The pinned board

    func testThePinnedBoardShowsOnlyWhenThereIsSomethingOnIt() {
        let today = DailyMissionStore.dayKey()
        XCTAssertFalse(QuestPenaltyBoard.hasContent(ledger: QuestLedger(), today: today))
        let (store, penalties, _) = stores()
        store.upsert(quest("late"))
        store.sweepExpired()
        // Waiting on its data is already worth pinning: the wearer sees it has not been let go.
        XCTAssertTrue(QuestPenaltyBoard.hasContent(ledger: penalties.ledger, today: today))
    }

    func testTheXPChipKeepsTheStripUpOnItsOwn() {
        XCTAssertFalse(QuestStripView.hasContent(mode: nil, activeCount: 0, ledgerChip: false))
        XCTAssertTrue(QuestStripView.hasContent(mode: nil, activeCount: 0, ledgerChip: true))
    }
}

/// Local midnight of a day key — what the make-up's deadline is measured from.
private enum LocalDay {
    static func date(_ key: String) -> Date {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }
}
