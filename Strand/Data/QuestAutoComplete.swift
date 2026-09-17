import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// QuestAutoComplete.swift — quests close themselves.
//
// A quest used to end with a button: "mark it done", on the wearer's word. The system that issued it
// had already read the step count, the workout log and last night's sleep to decide the quest was
// needed — and then asked the wearer whether they had done it, which is a question it could answer
// itself and which invites the easy answer rather than the true one.
//
// So every open quest is checked against its goal whenever the day's data is re-read, and the moment
// the data meets it the quest is closed and the completion pop-up says what was measured.
//
// READ-ONLY AND IDEMPOTENT. It reads the same stores every screen reads and changes nothing but the
// quest's state, so running it on every refresh costs a handful of reads and can never close a quest
// twice (`QuestStore.complete` ignores one that is already closed).
//
// AN UNMEASURED GOAL IS NOT MET. No step count is not zero steps and not eight thousand: the quest
// stays open and runs out on its own clock.

@MainActor
enum QuestAutoComplete {

    /// Check every open quest and close the ones whose goal the data has met.
    static func run(repo: Repository) async {
        let store = QuestStore.shared
        let now = nowMs()
        let open = store.quests.filter { $0.state == .active || $0.state == .offered }
        guard !open.isEmpty else { return }

        // One gather per DAY, not per quest: two quests from the same day read the same evidence.
        var evidenceByDay: [String: QuestEvidence] = [:]
        for quest in open {
            guard let goal = quest.effectiveGoal, now <= quest.checkableUntilMs() else { continue }
            let evidence: QuestEvidence
            if let cached = evidenceByDay[quest.dayKey] {
                evidence = cached
            } else {
                evidence = await gather(repo: repo, day: quest.dayKey)
                evidenceByDay[quest.dayKey] = evidence
            }
            if goal.isMet(by: evidence) {
                store.complete(quest, summary: goal.summary(evidence))
            }
        }
    }

    /// Everything a goal can be checked against, for one local day.
    ///
    /// Each figure comes from the same place the screen that shows it reads, so the quest can never
    /// close on a number the wearer cannot find: steps off the day row, training off the workout list,
    /// water off the hydration store, meditation off its own series, strain off WHOOP's cloud row.
    static func gather(repo: Repository, day: String) async -> QuestEvidence {
        let calendar = Calendar.current
        var e = QuestEvidence()

        let row = repo.days.first { $0.day == day }
        e.steps = row?.steps.map(Double.init)

        // Training minutes: every workout that STARTED on the day, whatever its source.
        let workouts = await repo.workoutRows(days: 4)
        let minutes = workouts
            .filter { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval($0.startTs))) == day }
            .reduce(0.0) { $0 + (($1.durationS ?? Double(max(0, $1.endTs - $1.startTs))) / 60) }
        e.workoutMinutes = minutes

        e.meditationMinutes = await repo.meditationMinutesByDay(days: 4)[day] ?? 0
        e.waterMl = await repo.hydrationTotal(day: day)
        e.journaled = await repo.journalDays(days: 5).contains(day)

        // WHOOP's own day strain, on its own 0–21. Nothing else stands in for it: a quest that names a
        // strain names WHOOP's.
        e.strain = await repo.whoopCloudDay(day)?.strain

        // The nights either side of the day. `sleepTimingsByDay` keys a night by the day it ENDED on,
        // so the day's own key is "last night" and the next day's key is the night the quest asked for.
        if let date = WhoopCloudApi.localDayDate(day),
           let next = calendar.date(byAdding: .day, value: 1, to: date) {
            let nextKey = Repository.localDayKey(next)
            let timings = await repo.sleepTimingsByDay(days: 5)
            e.previousSleepOnsetMinute = timings[day]?.onsetMinute
            e.nextSleepOnsetMinute = timings[nextKey]?.onsetMinute
            e.nextSleepHours = repo.days.first { $0.day == nextKey }?.totalSleepMin.map { $0 / 60 }
        }
        return e
    }
}
