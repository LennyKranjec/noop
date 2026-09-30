import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// QuestPenaltyAssessor.swift — judging closed quests on their data.
//
// `QuestStore.sweepExpired` runs off a clock and has no repository, so all it can do when a window shuts
// is cancel the quest and queue it. This is the half that has the evidence: it reads the quest's day
// through the SAME gather `QuestAutoComplete` closes quests with (`QuestAutoComplete.gather`), so a
// penalty can never quote a different number from the one the completion check saw, and hands it to the
// ledger (`QuestLedger.judge`), which owns every rule.
//
// WHAT IT DOES, EACH PASS:
//   1. Lapses make-ups whose quest ran out, and prunes history past 30 days.
//   2. Judges every queued quest whose time has come: met late → completed and paid; measured and short
//      → charged, and a make-up issued for today if the rules allow one; nothing measured → waits for
//      late data, then closes as "not measured, no penalty".
//   3. Revisits recent penalties: if later data shows the quest met after all, the penalty is refunded
//      in full and its make-up withdrawn.
//   4. Lets the day's plan card through, now that its lines have prices on them.
//
// GAME LAYER ONLY: it moves XP, the streak and make-ups. It never touches the measured Level.
//
// READ-MOSTLY AND IDEMPOTENT. Every write is keyed by a quest id in the ledger, so running it on every
// refresh is safe: a quest is judged once, paid once, refunded once.

@MainActor
enum QuestPenaltyAssessor {

    /// One pass at a time. The strip and the shell both drive this; a second caller arriving while a
    /// pass is suspended on a read skips rather than queues — the next tick catches anything it missed.
    /// Cleared in a `defer`, so no early return or cancelled await can leave it stuck on.
    private static var running = false

    static func run(repo: Repository, now: Date = Date()) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let penalties = QuestPenaltyStore.shared
        let store = QuestStore.shared
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let today = DailyMissionStore.dayKey(now)

        penalties.prune(today: today)

        // 1 · Make-ups whose quest is gone or ran out.
        for debt in penalties.ledger.openDebts {
            if let quest = store.quests.first(where: { $0.id == debt.questId }) {
                if quest.state == .completed { penalties.credit(quest) }        // idempotent: clears it
                else if quest.state == .declined { penalties.lapseDebt(debt.questId) }
            } else if debt.dayKey < today {
                penalties.lapseDebt(debt.questId)
            }
        }

        let due = penalties.ledger.pending.filter { nowMs >= $0.judgeAfterMs }
        let revisit = penalties.ledger.judgements.filter {
            $0.outcome == .penalised
                && (QuestDayMath.days(from: $0.dayKey, to: today) ?? Int.max) <= QuestPenaltyRules.judgeableMaxAgeDays
        }
        guard !due.isEmpty || !revisit.isEmpty else {
            await QuestPlanReporter.reportIfDue(repo: repo, now: now)
            return
        }

        let context = await debtContext(repo: repo, today: today)
        var evidenceByDay: [String: QuestEvidence] = [:]
        func evidence(_ day: String) async -> QuestEvidence {
            if let cached = evidenceByDay[day] { return cached }
            let e = await honestEvidence(repo: repo, day: day)
            evidenceByDay[day] = e
            return e
        }

        // 2 · Judge what is due.
        for subject in due {
            let e = await evidence(subject.dayKey)
            switch penalties.judge(questId: subject.questId, evidence: e, nowMs: nowMs, context: context) {
            case .met:
                let summary = subject.goal?.summary(e) ?? "The data met it."
                if !store.completeLate(id: subject.questId, summary: summary) {
                    // The quest has aged out of the list; pay it from its own record.
                    penalties.credit(Quest(id: subject.questId, kind: subject.kind, title: subject.title,
                                           taunt: "", target: subject.target, rewards: [], xp: subject.xp,
                                           state: .completed, dayKey: subject.dayKey, createdAtMs: nowMs))
                }
            case .judged(let judgement):
                if let debt = judgement.debt, debt.state == .open {
                    store.issueDebt(debtQuest(debt, for: judgement, nowMs: nowMs))
                }
            case .notDue, .awaitingData:
                break
            }
        }

        // 3 · Later data can only ever help: a penalty the data now contradicts is refunded in full.
        for judgement in revisit {
            guard let goal = judgement.goal else { continue }
            let e = await evidence(judgement.dayKey)
            guard goal.shortfall(e) == 0 else { continue }
            let (_, withdrawn) = penalties.void(questId: judgement.questId)
            if let withdrawn { store.withdraw(id: withdrawn) }
            if !store.completeLate(id: judgement.questId, summary: goal.summary(e)) {
                penalties.credit(Quest(id: judgement.questId, kind: judgement.kind, title: judgement.title,
                                       taunt: "", target: judgement.target, rewards: [], xp: 0,
                                       state: .completed, dayKey: judgement.dayKey, createdAtMs: nowMs))
            }
        }

        // 4 · The day's plan card waited for these judgements; let it through now.
        await QuestPlanReporter.reportIfDue(repo: repo, now: now)
    }

    /// The day's evidence, with one more honesty rule than the completion check needs.
    ///
    /// `QuestAutoComplete.gather` sums the workout list, so a day with no workouts reads as 0 minutes of
    /// training — right for closing a quest (0 never meets a goal), wrong for PUNISHING one when the day
    /// has no wear data at all: an empty workout list on a day the strap never synced is "not measured",
    /// not "did nothing". So when the day has no metric row with anything in it, a zero training figure
    /// is withdrawn and the quest is judged as unmeasured.
    static func honestEvidence(repo: Repository, day: String) async -> QuestEvidence {
        var e = await QuestAutoComplete.gather(repo: repo, day: day)
        let row = repo.days.first { $0.day == day }
        let wore = row.map {
            $0.steps != nil || $0.strain != nil || $0.recovery != nil || $0.totalSleepMin != nil
        } ?? false
        if !wore, e.workoutMinutes == 0 { e.workoutMinutes = nil }
        return e
    }

    /// Today's Charge and recommended band — what a make-up has to respect. Each abstains on its own; an
    /// unknown Charge adds no training load (`QuestDebtContext.trainingAllowed`).
    static func debtContext(repo: Repository, today: String) async -> QuestDebtContext {
        let row = repo.days.first { $0.day == today }
        let charge = await repo.whoopCloudDay(today)?.recovery ?? row?.recovery
        let band = await repo.todayEffortTarget()?.band
        // HD: whether each missed day's training was owed, as the week plan decided that morning. The plan
        // itself is refreshed by `HealthV2Refresh` (not here), so this only reads its archive.
        return QuestDebtContext(today: today, charge: charge, effortBand21: band,
                                trainingChargeableByDay: WeekPlanSource.shared.trainingChargeableByDay)
    }

    /// The make-up as a quest on the strip: active, closing on its own goal like any other, due by the
    /// end of its day.
    static func debtQuest(_ debt: QuestDebt, for judgement: QuestJudgement, nowMs: Int64) -> Quest {
        let calendar = Calendar.current
        let end: Int64? = WhoopCloudApi.localDayDate(debt.dayKey)
            .flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
            .map { Int64($0.timeIntervalSince1970 * 1000) }
        return Quest(
            id: debt.questId,
            kind: .side,
            title: "Make-Up: \(judgement.title)",
            taunt: "You came up short \(QuestPenaltyText.when(judgement.dayKey, today: debt.dayKey).lowercased()) "
                + "and it cost \(QuestPenaltyText.signed(judgement.applied)) XP. Clear this and "
                + "\(debt.restoreXp) comes back.",
            target: debt.target,
            rewards: debt.rewards,
            // What the card shows; the ledger pays the restore amount, never this (see `QuestLedger.credit`).
            xp: min(QuestCodec.maxXp, max(QuestCodec.minXp, debt.restoreXp)),
            state: .active,
            dayKey: debt.dayKey,
            createdAtMs: nowMs,
            expiresAtMs: end.map { max($0, nowMs + 60_000) },
            goal: debt.goal)
    }
}
