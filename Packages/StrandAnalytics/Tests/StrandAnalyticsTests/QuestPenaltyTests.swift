import Foundation
import XCTest
@testable import StrandAnalytics

/// Unmet quests cost XP now. What is pinned here:
///
///   * THE ARITHMETIC: cost = xp × gear factor × shortfall × escalation, rounded, at least 1 — per gear and
///     per shortfall, so Relentless risks more than Steady and 90 % of the steps costs less than 20 %.
///   * ESCALATION: a second miss of the same metric inside the window costs ×1.5, a third ×2.0, no more.
///   * NOT MEASURED IS NEVER PUNISHED, and a quest whose data lands late is judged on that data.
///   * ONE MISS, ONE PENALTY: re-judging is a no-op, and two quests on one metric-day are charged once.
///   * MAKE-UPS: capped, never raising sleep or training, and nothing added on a low-Charge day.
///   * CLEARING A MAKE-UP GIVES BACK HALF, and a completed quest always keeps its reward.
///   * THE PINNED BOARD AND THE 30-DAY HISTORY.
///   * THE LEVEL IS NOT HERE: the ledger has no path to it (checked structurally below).
final class QuestPenaltyTests: XCTestCase {

    private let day = "2026-09-28"
    private let today = "2026-09-29"
    private let now: Int64 = 1_790_000_000_000

    private var goodDay: QuestDebtContext { QuestDebtContext(today: today, charge: 70, effortBand21: 10...14) }
    private var lowDay: QuestDebtContext { QuestDebtContext(today: today, charge: 20, effortBand21: 4...8) }

    private func subject(_ id: String = "q1", kind: QuestKind = .side, day: String? = nil,
                         metric: QuestMetric = .steps, threshold: Double = 10_000, xp: Int = 70,
                         gear: QuestDifficulty? = .relentless, judgeAfter: Int64? = nil) -> QuestJudgementSubject {
        QuestJudgementSubject(questId: id, kind: kind, dayKey: day ?? self.day, title: "T-\(id)",
                              target: "target-\(id)", goal: QuestGoal(metric: metric, threshold: threshold),
                              xp: xp, gear: gear, judgeAfterMs: judgeAfter ?? (now - 1))
    }

    private func judged(_ r: QuestLedger.JudgeResult) -> QuestJudgement? {
        if case .judged(let j) = r { return j }
        return nil
    }

    // MARK: - Arithmetic

    func testAFullMissCostsMoreTheHarderTheGear() {
        // Each gear's own XP (35 / 50 / 70) × its factor (0.50 / 0.75 / 1.00).
        XCTAssertEqual(QuestPenalty.cost(xp: 35, gear: .steady, shortfall: 1, priorMisses: 0), 18)
        XCTAssertEqual(QuestPenalty.cost(xp: 50, gear: .push, shortfall: 1, priorMisses: 0), 38)
        XCTAssertEqual(QuestPenalty.cost(xp: 70, gear: .relentless, shortfall: 1, priorMisses: 0), 70)
        // The same quest, the same miss: the gear alone moves the price.
        let steady = QuestPenalty.cost(xp: 50, gear: .steady, shortfall: 1, priorMisses: 0)
        let push = QuestPenalty.cost(xp: 50, gear: .push, shortfall: 1, priorMisses: 0)
        let hard = QuestPenalty.cost(xp: 50, gear: .relentless, shortfall: 1, priorMisses: 0)
        XCTAssertLessThan(steady, push)
        XCTAssertLessThan(push, hard)
        // A quest no gear scaled (the daily, a side quest) sits in the middle.
        XCTAssertEqual(QuestPenalty.cost(xp: 60, gear: nil, shortfall: 1, priorMisses: 0), 45)
    }

    func testPartialCompletionCostsProportionallyLess() {
        // 90 % of the steps is 10 % short; 20 % of the steps is 80 % short.
        XCTAssertEqual(QuestPenalty.cost(xp: 70, gear: .relentless, shortfall: 0.1, priorMisses: 0), 7)
        XCTAssertEqual(QuestPenalty.cost(xp: 70, gear: .relentless, shortfall: 0.8, priorMisses: 0), 56)
        // Never free for a real miss, however close.
        XCTAssertEqual(QuestPenalty.cost(xp: 35, gear: .steady, shortfall: 0.001, priorMisses: 0), 1)
        // Nothing missed, nothing charged.
        XCTAssertEqual(QuestPenalty.cost(xp: 70, gear: .relentless, shortfall: 0, priorMisses: 3), 0)
    }

    func testShortfallAgreesWithIsMetAndIsMeasured() {
        let steps = QuestGoal(metric: .steps, threshold: 10_000)
        XCTAssertNil(steps.shortfall(QuestEvidence()))
        XCTAssertEqual(steps.shortfall(QuestEvidence(steps: 10_000)), 0)
        XCTAssertEqual(steps.shortfall(QuestEvidence(steps: 9_000))!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(steps.shortfall(QuestEvidence(steps: 0)), 1)
        // A bedtime: 30 minutes late of a 120-minute full miss.
        let bed = QuestGoal(metric: .bedtimeBy, threshold: Double(22 * 60 + 30))
        XCTAssertEqual(bed.shortfall(QuestEvidence(nextSleepOnsetMinute: 23 * 60))!, 0.25, accuracy: 1e-9)
        XCTAssertEqual(bed.shortfall(QuestEvidence(nextSleepOnsetMinute: 22 * 60)), 0)
        XCTAssertEqual(bed.shortfall(QuestEvidence(nextSleepOnsetMinute: 2 * 60)), 1)
        // The journal is all or nothing, and unknown is unknown.
        let journal = QuestGoal(metric: .journal, threshold: 1)
        XCTAssertEqual(journal.shortfall(QuestEvidence(journaled: false)), 1)
        XCTAssertNil(journal.shortfall(QuestEvidence()))
    }

    func testEscalationStepsUpAndStopsAtTheCap() {
        XCTAssertEqual(QuestPenalty.escalation(priorMisses: 0), 1.0)
        XCTAssertEqual(QuestPenalty.escalation(priorMisses: 1), 1.5)
        XCTAssertEqual(QuestPenalty.escalation(priorMisses: 2), 2.0)
        XCTAssertEqual(QuestPenalty.escalation(priorMisses: 9), 2.0)
        XCTAssertEqual(QuestPenalty.cost(xp: 70, gear: .relentless, shortfall: 1, priorMisses: 1), 105)
    }

    // MARK: - Judging

    func testAMeasuredMissIsChargedWithItsReading() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject(threshold: 10_000))
        let j = judged(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 7_000), nowMs: now,
                                    context: goodDay))
        XCTAssertEqual(j?.outcome, .penalised)
        XCTAssertEqual(j?.nominalCost, 21)          // 70 × 1.0 × 0.3
        XCTAssertEqual(j?.applied, -21)
        XCTAssertEqual(ledger.balance, -21)          // the balance may go negative
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    func testASecondConsecutiveMissOfTheSameMetricEscalates() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject("a", day: "2026-09-27"))
        _ = ledger.judge(questId: "a", evidence: QuestEvidence(steps: 0), nowMs: now,
                         context: QuestDebtContext(today: "2026-09-28", charge: 70))
        _ = ledger.enqueue(subject("b", day: day))
        let second = judged(ledger.judge(questId: "b", evidence: QuestEvidence(steps: 0), nowMs: now,
                                         context: goodDay))
        XCTAssertEqual(second?.priorMisses, 1)
        XCTAssertEqual(second?.nominalCost, 105)
        // A different metric does not escalate.
        _ = ledger.enqueue(subject("c", day: day, metric: .waterMl, threshold: 3_000))
        let water = judged(ledger.judge(questId: "c", evidence: QuestEvidence(waterMl: 0), nowMs: now,
                                        context: goodDay))
        XCTAssertEqual(water?.priorMisses, 0)
        // A miss outside the window does not count.
        XCTAssertEqual(ledger.priorMisses(metric: .steps, day: "2026-10-20", excluding: "x"), 0)
    }

    func testNotMeasuredIsNeverPunished() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject())
        // Inside the grace: it waits for the data.
        XCTAssertEqual(ledger.judge(questId: "q1", evidence: QuestEvidence(), nowMs: now, context: goodDay),
                       .awaitingData)
        XCTAssertEqual(ledger.balance, 0)
        // Past the grace: closed as not measured, at no cost.
        let late = now + QuestPenaltyRules.lateDataGraceMs
        let j = judged(ledger.judge(questId: "q1", evidence: QuestEvidence(), nowMs: late, context: goodDay))
        XCTAssertEqual(j?.outcome, .notMeasured)
        XCTAssertEqual(j?.applied, 0)
        XCTAssertEqual(j?.costText, "No penalty")
        XCTAssertEqual(ledger.balance, 0)
        // A read that failed outright is the same as no data.
        var other = QuestLedger()
        _ = other.enqueue(subject())
        XCTAssertEqual(other.judge(questId: "q1", evidence: nil, nowMs: now, context: goodDay), .awaitingData)
    }

    func testLateDataIsJudgedOnTheDataNotTheClock() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject())
        XCTAssertEqual(ledger.judge(questId: "q1", evidence: QuestEvidence(), nowMs: now, context: goodDay),
                       .awaitingData)
        // The strap synced overnight and the steps were there after all.
        XCTAssertEqual(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 12_000), nowMs: now + 1,
                                    context: goodDay), .met)
        XCTAssertEqual(ledger.balance, 0)
        XCTAssertEqual(ledger.credit(questId: "q1", kind: .side, xp: 70), 70)
    }

    func testAPenaltyContradictedByLaterDataIsRefundedInFull() {
        var ledger = QuestLedger()
        _ = ledger.credit(questId: "d0", kind: .daily, xp: 60)
        _ = ledger.enqueue(subject("d1", kind: .daily, gear: nil, judgeAfter: now - 1))
        _ = ledger.judge(questId: "d1", evidence: QuestEvidence(steps: 1_000), nowMs: now, context: goodDay)
        XCTAssertEqual(ledger.streak, 0)
        let (refund, withdrawn) = ledger.void(questId: "d1")
        XCTAssertGreaterThan(refund, 0)
        XCTAssertNotNil(withdrawn)
        XCTAssertEqual(ledger.balance, 60)
        XCTAssertEqual(ledger.streak, 1)            // the broken streak comes back
        XCTAssertEqual(ledger.judgements.first?.outcome, .metLate)
    }

    func testAQuestIsNeverPenalisedTwice() {
        var ledger = QuestLedger()
        XCTAssertTrue(ledger.enqueue(subject()))
        _ = ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now, context: goodDay)
        // Re-queued and re-judged by a later sweep: refused, and nothing further is charged.
        XCTAssertFalse(ledger.enqueue(subject()))
        XCTAssertEqual(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay), .notDue)
        XCTAssertEqual(ledger.balance, -70)
    }

    func testTwoQuestsOnOneMetricDayAreChargedAsOneMiss() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject("plan", threshold: 10_000, xp: 70, gear: .relentless))
        _ = ledger.enqueue(subject("daily", kind: .daily, threshold: 8_000, xp: 60, gear: nil))
        let a = judged(ledger.judge(questId: "plan", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay))
        let b = judged(ledger.judge(questId: "daily", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay))
        XCTAssertEqual(a?.applied, -70)
        XCTAssertEqual(b?.applied, 0)                // 45 < 70: already covered
        XCTAssertEqual(b?.overlapOf, "plan")
        XCTAssertNil(b?.debt)                        // and no second make-up
        XCTAssertEqual(ledger.balance, -70)
    }

    func testMissingTheDailyBreaksTheStreak() {
        var ledger = QuestLedger()
        for i in 0..<5 { ledger.credit(questId: "d\(i)", kind: .daily, xp: 60) }
        XCTAssertEqual(ledger.streak, 5)
        _ = ledger.enqueue(subject("miss", kind: .daily, gear: nil))
        let j = judged(ledger.judge(questId: "miss", evidence: QuestEvidence(steps: 100), nowMs: now,
                                    context: goodDay))
        XCTAssertEqual(ledger.streak, 0)
        XCTAssertEqual(ledger.bestStreak, 5)
        XCTAssertEqual(j?.streakBroken, 5)
        XCTAssertEqual(j?.streakText, "Daily streak broken · was 5")
        // An unmeasured daily does not break it.
        ledger.credit(questId: "d9", kind: .daily, xp: 60)
        _ = ledger.enqueue(subject("blind", kind: .daily, gear: nil))
        _ = ledger.judge(questId: "blind", evidence: QuestEvidence(), nowMs: now + QuestPenaltyRules.lateDataGraceMs,
                         context: goodDay)
        XCTAssertEqual(ledger.streak, 1)
    }

    func testACompletedQuestKeepsItsRewardAndIsPaidOnce() {
        var ledger = QuestLedger()
        XCTAssertEqual(ledger.credit(questId: "q1", kind: .side, xp: 70), 70)
        XCTAssertEqual(ledger.credit(questId: "q1", kind: .side, xp: 70), 0)
        XCTAssertFalse(ledger.enqueue(subject()))    // a paid quest is never judged
        XCTAssertEqual(ledger.balance, 70)
    }

    func testTheBalanceStopsAtTheFloor() {
        var ledger = QuestLedger()
        for i in 0..<10 {
            _ = ledger.enqueue(subject("m\(i)", metric: i % 2 == 0 ? .steps : .waterMl, threshold: 5_000, xp: 150))
            _ = ledger.judge(questId: "m\(i)", evidence: QuestEvidence(steps: 0, waterMl: 0), nowMs: now,
                             context: goodDay)
        }
        XCTAssertEqual(ledger.balance, QuestPenaltyRules.balanceFloor)
        XCTAssertEqual(ledger.balanceText, "IN THE RED · \u{2212}300 XP")
    }

    func testTooOldToReadIsNotMeasured() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject(day: "2026-09-20"))
        let j = judged(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay))
        XCTAssertEqual(j?.outcome, .notMeasured)
        XCTAssertEqual(ledger.balance, 0)
    }

    // MARK: - Behaviour, never physiology

    func testEveryMetricIsClassifiedExplicitly() {
        let table: [QuestMetric: QuestPenaltyClass] = [
            .steps: .behaviour, .waterMl: .behaviour, .workoutMinutes: .behaviour,
            .meditationMinutes: .behaviour, .journal: .behaviour,
            .bedtimeBy: .behaviour, .bedtimeEarlier: .behaviour,
            .sleepHours: .physiology,
            .strain: .effort,
        ]
        // Every case is in the table: a new metric has to be classified here as well as in the switch.
        XCTAssertEqual(Set(QuestMetric.allCases), Set(table.keys))
        for metric in QuestMetric.allCases {
            XCTAssertEqual(metric.penaltyClass, table[metric], "\(metric)")
        }
        XCTAssertFalse(QuestMetric.sleepHours.isBehaviour)
        XCTAssertTrue(QuestMetric.bedtimeBy.isBehaviour)
    }

    func testAMissedSleepDurationIsReportedNeverCharged() {
        var ledger = QuestLedger()
        for i in 0..<3 { ledger.credit(questId: "d\(i)", kind: .daily, xp: 60) }
        let before = ledger.balance
        _ = ledger.enqueue(subject("sleep", kind: .daily, metric: .sleepHours, threshold: 8, gear: nil))
        let j = judged(ledger.judge(questId: "sleep", evidence: QuestEvidence(nextSleepHours: 5), nowMs: now,
                                    context: goodDay))
        XCTAssertEqual(j?.outcome, .reported)
        XCTAssertEqual(j?.applied, 0)
        XCTAssertNil(j?.debt)
        XCTAssertNil(j?.streakText)
        XCTAssertEqual(j?.costText, "No penalty")
        XCTAssertTrue(j?.detailText.hasPrefix("Missed, no penalty.") == true)
        XCTAssertEqual(ledger.balance, before)
        XCTAssertEqual(ledger.streak, 3)                  // the streak is not the body's to break
        XCTAssertEqual(ledger.pinned(today: today).map(\.questId), ["sleep"])   // still shown plainly
        XCTAssertTrue(ledger.missCounts(today: today).isEmpty)
    }

    func testStrainIsChargedOnlyWhenThereWasNoTrainingAtAll() {
        func strainMiss(_ id: String, minutes: Double?) -> QuestJudgement? {
            var ledger = QuestLedger()
            _ = ledger.enqueue(subject(id, metric: .strain, threshold: 12, xp: 50, gear: .push))
            return judged(ledger.judge(questId: id, evidence: QuestEvidence(workoutMinutes: minutes, strain: 6),
                                       nowMs: now, context: goodDay))
        }
        // Trained, but the body produced less strain than the band's point: reported, not charged.
        XCTAssertEqual(strainMiss("trained", minutes: 40)?.outcome, .reported)
        // Whether they trained is unknown: not charged either.
        XCTAssertEqual(strainMiss("unknown", minutes: nil)?.outcome, .reported)
        // Did not train at all: charged as a total miss (50 × 0.75 × 1), never "50 % short of a number".
        let idle = strainMiss("idle", minutes: 0)
        XCTAssertEqual(idle?.outcome, .penalised)
        XCTAssertEqual(idle?.shortfall, 1)
        XCTAssertEqual(idle?.applied, -38)
    }

    func testTrialQuestsAreNeverJudged() {
        var ledger = QuestLedger()
        XCTAssertFalse(ledger.enqueue(subject("trial-caffeine-a")))
        XCTAssertFalse(QuestPenaltyRules.isPenalisable(kind: .side, questId: "trial-x"))
        XCTAssertTrue(QuestPenaltyRules.isPenalisable(kind: .side, questId: "plan-x"))
        XCTAssertTrue(ledger.pending.isEmpty)
    }

    // MARK: - Make-ups

    func testAStepsMakeUpAddsTheShortfallCapped() {
        let goal = QuestGoal(metric: .steps, threshold: 12_000)
        // 1,000 short: all of it added.
        if case .issue(let g, _) = QuestDebtPolicy.decide(goal: goal, shortfall: 1_000 / 12_000, kind: .side,
                                                           questId: "q", missedDay: day, context: goodDay) {
            XCTAssertEqual(g.threshold, 13_000)
        } else { XCTFail("expected a make-up") }
        // 7,000 short: capped at 25 % — 15,000, not 19,000.
        if case .issue(let g, _) = QuestDebtPolicy.decide(goal: goal, shortfall: 7_000 / 12_000, kind: .side,
                                                           questId: "q", missedDay: day, context: goodDay) {
            XCTAssertEqual(g.threshold, 15_000)
        } else { XCTFail("expected a make-up") }
        // And never past the absolute ceiling.
        if case .issue(let g, _) = QuestDebtPolicy.decide(goal: QuestGoal(metric: .steps, threshold: 24_000),
                                                           shortfall: 1, kind: .side, questId: "q",
                                                           missedDay: day, context: goodDay) {
            XCTAssertEqual(g.threshold, QuestPenaltyRules.debtStepsCeiling)
        } else { XCTFail("expected a make-up") }
    }

    func testSleepAndTrainingMakeUpsAreNeverRaised() {
        for goal in [QuestGoal(metric: .sleepHours, threshold: 8),
                     QuestGoal(metric: .bedtimeBy, threshold: Double(22 * 60 + 30)),
                     QuestGoal(metric: .workoutMinutes, threshold: 45),
                     QuestGoal(metric: .waterMl, threshold: 3_000)] {
            guard case .issue(let g, _) = QuestDebtPolicy.decide(goal: goal, shortfall: 1, kind: .side,
                                                                  questId: "q", missedDay: day,
                                                                  context: goodDay) else {
                XCTFail("expected a make-up for \(goal.metric)")
                continue
            }
            XCTAssertEqual(g, goal, "\(goal.metric) must be repeated, not raised")
        }
    }

    func testALowChargeDayGetsNoTrainingLoad() {
        for metric in [QuestMetric.workoutMinutes, .strain] {
            let d = QuestDebtPolicy.decide(goal: QuestGoal(metric: metric, threshold: 12), shortfall: 0.5,
                                           kind: .side, questId: "q", missedDay: day, context: lowDay)
            guard case .none = d else { return XCTFail("\(metric) must not add load on a low-Charge day") }
            // Unknown Charge is treated as low.
            let unknown = QuestDebtPolicy.decide(goal: QuestGoal(metric: metric, threshold: 12), shortfall: 0.5,
                                                 kind: .side, questId: "q", missedDay: day,
                                                 context: QuestDebtContext(today: today))
            guard case .none = unknown else { return XCTFail("\(metric) must not add load on an unknown Charge") }
        }
        // Strain on a good day stays inside today's band.
        if case .issue(let g, _) = QuestDebtPolicy.decide(goal: QuestGoal(metric: .strain, threshold: 17),
                                                           shortfall: 0.5, kind: .side, questId: "q",
                                                           missedDay: day, context: goodDay) {
            XCTAssertEqual(g.threshold, 14)
        } else { XCTFail("expected a strain make-up inside the band") }
    }

    func testAMissedMakeUpDoesNotRollOverAgain() {
        let d = QuestDebtPolicy.decide(goal: QuestGoal(metric: .steps, threshold: 10_000), shortfall: 1,
                                       kind: .side, questId: QuestDebt.questId(day: day, metric: .steps),
                                       missedDay: day, context: goodDay)
        guard case .none = d else { return XCTFail("a make-up must not chain") }
    }

    func testClearingAMakeUpRestoresHalfOfWhatWasLost() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject(threshold: 10_000))
        let j = judged(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay))
        guard let debt = j?.debt else { return XCTFail("expected a make-up") }
        XCTAssertEqual(debt.dayKey, today)
        XCTAssertEqual(debt.restoreXp, 35)
        XCTAssertEqual(ledger.balance, -70)
        // Completing the make-up quest clears it: half comes back, and the make-up's own XP does not.
        XCTAssertEqual(ledger.credit(questId: debt.questId, kind: .side, xp: 150), 35)
        XCTAssertEqual(ledger.balance, -35)
        XCTAssertEqual(ledger.credit(questId: debt.questId, kind: .side, xp: 150), 0)
        XCTAssertEqual(ledger.judgements.first?.netCost, 35)
    }

    func testALapsedMakeUpLeavesThePenaltyAndChargesNothingMore() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject())
        let j = judged(ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: goodDay))
        ledger.lapseDebt(debtQuestId: j!.debt!.questId)
        XCTAssertEqual(ledger.balance, -70)
        XCTAssertEqual(ledger.judgements.first?.debt?.state, .lapsed)
        XCTAssertTrue(ledger.openDebts.isEmpty)
    }

    // MARK: - The board and the history

    func testThePinnedBoardShowsWhatWasMissedAndWhatItCost() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject("steps", threshold: 10_000))
        _ = ledger.judge(questId: "steps", evidence: QuestEvidence(steps: 6_900), nowMs: now, context: goodDay)
        _ = ledger.enqueue(subject("water", metric: .waterMl, threshold: 3_000))
        _ = ledger.judge(questId: "water", evidence: QuestEvidence(), nowMs: now + QuestPenaltyRules.lateDataGraceMs,
                         context: goodDay)
        let pinned = ledger.pinned(today: today)
        XCTAssertEqual(pinned.map(\.questId).sorted(), ["steps", "water"])
        let steps = pinned.first { $0.questId == "steps" }!
        XCTAssertEqual(steps.costText, "\u{2212}22 XP")            // 70 × 1.0 × 0.31 = 21.7
        XCTAssertEqual(steps.reasonText, "31 % short · Relentless ×1.0")
        XCTAssertTrue(steps.debtText?.hasPrefix("Make-up open: ") == true)
        XCTAssertTrue(steps.debtText?.hasSuffix("clears +11 XP back") == true)
        XCTAssertEqual(QuestPenaltyText.when(steps.dayKey, today: today), "Yesterday")
        let water = pinned.first { $0.questId == "water" }!
        XCTAssertEqual(water.costText, "No penalty")
        XCTAssertTrue(water.detailText.hasPrefix("Not measured, no penalty."))
    }

    func testTheBoardDropsClearedAndAgedOutItemsButKeepsOpenDebts() {
        var ledger = QuestLedger()
        _ = ledger.enqueue(subject("old", day: "2026-09-27"))
        let j = judged(ledger.judge(questId: "old", evidence: QuestEvidence(steps: 0), nowMs: now,
                                    context: QuestDebtContext(today: "2026-09-28", charge: 70)))
        XCTAssertEqual(ledger.pinned(today: "2026-09-30").count, 1)
        // Four days on, it has aged out — unless its make-up were still open.
        ledger.lapseDebt(debtQuestId: j!.debt!.questId)
        XCTAssertEqual(ledger.pinned(today: "2026-10-01").count, 0)
        // A cleared one leaves the board at once, and stays in the history.
        var cleared = QuestLedger()
        _ = cleared.enqueue(subject())
        let k = judged(cleared.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now, context: goodDay))
        cleared.credit(questId: k!.debt!.questId, kind: .side, xp: 10)
        XCTAssertTrue(cleared.pinned(today: today).isEmpty)
        XCTAssertEqual(cleared.history(today: today).count, 1)
        XCTAssertEqual(cleared.restored(today: today), 35)
    }

    func testTheHistoryKeepsThirtyDaysAndRanksTheMostMissedMetric() {
        var ledger = QuestLedger()
        let days = (0..<40).map { i -> String in
            let base = QuestDayMath.ordinal("2026-09-29")! - i
            let date = Date(timeIntervalSince1970: TimeInterval(base) * 86_400)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let c = cal.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        for (i, d) in days.enumerated() {
            let metric: QuestMetric = i % 3 == 0 ? .waterMl : .steps
            _ = ledger.enqueue(subject("h\(i)", day: d, metric: metric))
            // Judge each on its own "next day" so every one is readable.
            let next = QuestDayMath.days(from: d, to: "2026-09-29")! >= 1 ? days[max(0, i - 1)] : d
            _ = ledger.judge(questId: "h\(i)", evidence: QuestEvidence(steps: 0, waterMl: 0), nowMs: now,
                             context: QuestDebtContext(today: next, charge: 10))
        }
        ledger.prune(today: "2026-09-29")
        let history = ledger.history(today: "2026-09-29")
        XCTAssertEqual(history.count, 31)                  // today and the 30 days before it
        XCTAssertEqual(history.first?.dayKey, "2026-09-29")
        let counts = ledger.missCounts(today: "2026-09-29")
        XCTAssertEqual(counts.first?.metric, .steps)
        XCTAssertGreaterThan(counts.first?.count ?? 0, counts.last?.count ?? 0)
    }

    // MARK: - The day card

    func testTheDayCardNamesEachMissAndItsPenalty() {
        var ledger = QuestLedger()
        let hard = [subject("s", metric: .steps, threshold: 12_000), subject("w", metric: .waterMl, threshold: 3_000),
                    subject("m", metric: .meditationMinutes, threshold: 20)]
        for s in hard { _ = ledger.enqueue(s) }
        _ = ledger.judge(questId: "s", evidence: QuestEvidence(steps: 8_400), nowMs: now, context: goodDay)
        _ = ledger.judge(questId: "w", evidence: QuestEvidence(), nowMs: now + QuestPenaltyRules.lateDataGraceMs,
                         context: goodDay)
        let report = QuestPlanDayReport(day: day, difficulty: .relentless, lines: [
            QuestPlanLine(target: "target-s", outcome: .short, reading: "8,400 steps"),
            QuestPlanLine(target: "target-w", outcome: .notMeasured),
            QuestPlanLine(target: "target-m", outcome: .met),
        ])
        let card = QuestPenaltyDayCard.make(report: report, judgements: ledger.judgements)
        XCTAssertEqual(card.overline, "DIRECTIVES FAILED")
        XCTAssertEqual(card.totalCost, 21)                 // 70 × 0.3
        XCTAssertEqual(card.title, "\u{2212}21 XP")
        XCTAssertTrue(card.message.contains("\u{2212}21 XP (30 % short · Relentless ×1.0)"))
        XCTAssertTrue(card.message.contains("Not measured · target-w — no penalty"))
        XCTAssertTrue(card.message.contains("Met · target-m"))
        XCTAssertTrue(card.message.contains("never changes it"))
    }

    func testADayWithNothingChargedIsNotCalledAFailure() {
        let report = QuestPlanDayReport(day: day, difficulty: .steady, lines: [
            QuestPlanLine(target: "a", outcome: .notMeasured), QuestPlanLine(target: "b", outcome: .met),
        ])
        let card = QuestPenaltyDayCard.make(report: report, judgements: [])
        XCTAssertEqual(card.overline, "DAY CLOSED")
        XCTAssertEqual(card.totalCost, 0)
        XCTAssertEqual(card.title, report.headline)
    }

    // MARK: - Storage

    func testTheLedgerRoundTripsAndToleratesMissingFields() throws {
        var ledger = QuestLedger()
        ledger.credit(questId: "a", kind: .daily, xp: 60)
        _ = ledger.enqueue(subject())
        _ = ledger.judge(questId: "q1", evidence: QuestEvidence(steps: 0), nowMs: now, context: goodDay)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(QuestLedger.self, from: data), ledger)
        let partial = try JSONDecoder().decode(QuestLedger.self, from: Data(#"{"balance": 12}"#.utf8))
        XCTAssertEqual(partial.balance, 12)
        XCTAssertTrue(partial.judgements.isEmpty)
    }
}
