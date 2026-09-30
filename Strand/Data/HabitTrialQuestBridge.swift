import Foundation
import StrandAnalytics

// HabitTrialQuestBridge.swift — a running trial's daily assignment, delivered as a quest.
//
// HEALTH_V2 §S1-B.7. One trial quest per day, in BOTH arms (the OFF card is half the experiment):
//   · `kind: .custom`, id `trial-<trialId>-<day>` (`HabitTrialQuestId`, the penalty system's own exemption
//     prefix), no `QuestGoal` — so `QuestAutoComplete` never touches it and `QuestCodec` needs no new case;
//   · the same XP for ANY answer (`HabitTrialQuestId.loggingXp`), so XP can neither reward a false "did it"
//     nor make ON days more attractive to report; a custom-kind credit never moves the daily streak;
//   · never penalised, never a red card (`QuestStore.showsAsFailure` / `QuestPenaltyRules.isPenalisable`).
// The trial store, not the 40-quest list, is the source of truth for adherence. Past days' unanswered trial
// quests are withdrawn here (the day simply stays `unknown` in the store).

@MainActor
final class HabitTrialQuestBridge: ObservableObject {

    static let shared = HabitTrialQuestBridge()

    /// A trial quest the generic strip tried to tick off without an answer; Today presents the
    /// two-answer card for it.
    @Published var pendingAnswerQuestId: String?

    static func isTrialQuest(_ id: String) -> Bool { HabitTrialQuestId.isTrialQuest(id) }

    /// Quest metrics the day plan must not direct while the running trial lasts (the trial's behaviour or its
    /// primary outcome's obvious lever). Empty when no trial runs.
    static func conflictingMetrics(store: HabitTrialStore = .shared) -> Set<QuestMetric> {
        store.running?.entry?.conflictingMetrics ?? []
    }

    /// Upsert today's trial quest and withdraw unanswered ones from earlier days.
    func sync(now: Date = Date(), trials: HabitTrialStore = .shared, quests: QuestStore = .shared) {
        let today = Repository.localDayKey(now)
        for q in quests.quests where HabitTrialQuestId.isTrialQuest(q.id) && q.state != .completed {
            if let day = HabitTrialQuestId.day(of: q.id), day < today { quests.withdraw(id: q.id) }
        }
        guard let assignment = trials.todayAssignment(today: today), let entry = assignment.record.entry else { return }
        let rec = assignment.record
        let on = assignment.on
        let id = HabitTrialQuestId.make(trialId: rec.id, day: today)
        guard !quests.quests.contains(where: { $0.id == id }) else { return }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        // Open until the end of tomorrow: the answer for an evening habit often comes the next morning, and
        // this sync withdraws it at the following day roll anyway.
        let startOfDay = Calendar.current.startOfDay(for: now)
        let expires = Int64(startOfDay.addingTimeInterval(48 * 3600).timeIntervalSince1970 * 1000)
        let reward: QuestReward = [HabitOutcome.nightHrvLn, HabitOutcome.nightRhr].contains(entry.primaryOutcome) ? .heart : .sleep
        let quest = Quest(
            id: id, kind: .custom,
            title: on ? "Trial: \(entry.title)" : "Trial: normal evening",
            taunt: on ? "Today is an ON day." : "Today is an OFF day — half of the experiment.",
            target: on ? entry.onInstruction : "Normal evening — nothing to change",
            rewards: [reward], xp: HabitTrialQuestId.loggingXp, state: .active, dayKey: today,
            createdAtMs: nowMs, expiresAtMs: expires, goal: nil)
        quests.addCustom(quest)
    }

    /// The wearer's answer from the trial card. `did`: ON → "Did it", OFF → "Did it anyway". Any answer
    /// completes the quest for the same XP.
    func answer(questId: String, did: Bool, trials: HabitTrialStore = .shared, quests: QuestStore = .shared) {
        guard let day = HabitTrialQuestId.day(of: questId), let rec = trials.running,
              questId == HabitTrialQuestId.make(trialId: rec.id, day: day) else { return }
        trials.recordAnswer(trialId: rec.id, day: day, did: did)
        if let q = quests.quests.first(where: { $0.id == questId }), q.state != .completed {
            quests.complete(q, summary: "Logged — every answer counts the same, and both kinds of day matter.")
        }
        if pendingAnswerQuestId == questId { pendingAnswerQuestId = nil }
    }

    /// Hook target for `QuestStore.checkOff`: a bare check-off carries no answer, so ask for one.
    func handleCheckOff(questId: String) {
        pendingAnswerQuestId = questId
    }
}
