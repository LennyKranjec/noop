import Foundation
import StrandAnalytics
import WhoopStore

// QuestGenerator.swift — naming a quest, and deciding when one is raised.
//
// Swift twin of the Android `com.noop.ai.QuestGenerator` plus the issuing half of `QuestTrigger`.
//
// The trigger already decided there is a problem and what the directive is. This asks the model for the
// two parts that should never be the same twice: a TITLE and a TAUNT.
//
// WHY THOSE TWO AND NOTHING ELSE. A generated target is a fabricated number, and a generated trigger is
// a model inventing a reason to nag. Both are things this app does not do. A generated NAME costs
// nothing if it is silly and is the difference between "Step goal" and something the wearer actually
// looks at. The parse is written so a model that ignores the format entirely still produces a usable
// quest: the target and the XP were never its to decide.
//
// IT NEVER FAILS TO ISSUE. If the model is unavailable — no provider, no consent, a dead network — the
// quest is still issued under a written fallback name. A system that stays silent because its writer
// was busy is a system that misses the day it was needed.

enum QuestGenerator {

    /// The model's answer, capped. Two short lines; anything longer is rambling.
    private static let maxAnswerChars = 260

    /// Turn `trigger` into a quest, naming it with the coach.
    static func fromTrigger(_ trigger: QuestTrigger, coach: AICoachEngine, dayKey: String) async -> Quest {
        let written = await write(
            coach: coach,
            reason: trigger.observation,
            directive: trigger.target)
        return Quest(
            kind: .side,
            title: written?.title ?? QuestNaming.fallbackTitle(triggerId: trigger.id),
            taunt: written?.taunt ?? QuestNaming.fallbackTaunt(triggerId: trigger.id),
            target: trigger.target,
            rewards: trigger.rewards,
            xp: trigger.xp,
            dayKey: dayKey,
            createdAtMs: nowMs(),
            goal: trigger.goal)
    }

    /// The day's main quest, from the mission the coach already wrote.
    ///
    /// The mission IS the directive here — it was generated from the day's metrics and the wearer's
    /// goals — so this only needs a name for it. Its own sarcastic text becomes the taunt: a second one
    /// would be two jokes about the same thing.
    static func fromMission(_ mission: DailyMission, coach: AICoachEngine) async -> Quest {
        let written = await write(
            coach: coach,
            reason: "Today's directive for them is: \(mission.text)",
            directive: mission.text)
        return Quest(
            kind: .daily,
            title: written?.title ?? QuestNaming.fallbackTitle(triggerId: "daily"),
            taunt: String(mission.text.prefix(QuestNaming.maxTauntChars)),
            target: mission.text,
            rewards: QuestNaming.rewards(forDirective: mission.text),
            xp: dailyXp,
            dayKey: mission.dayKey,
            createdAtMs: nowMs(),
            goal: mission.goal ?? QuestGoal.parse(mission.text))
    }

    /// What the day's own quest is worth. Fixed, because the daily is always the same commitment.
    private static let dailyXp = 60

    private static func write(coach: AICoachEngine, reason: String, directive: String) async -> QuestNaming.Written? {
        let answer = await coach.generateOneShot(
            systemPrompt: systemPrompt(),
            question: "Situation: \(reason)\nDirective: \(directive)\nName it.")
        guard let answer else { return nil }
        return QuestNaming.parse(String(answer.prefix(maxAnswerChars)))
    }

    static func systemPrompt(_ defaults: UserDefaults = .standard) -> String {
        var s = ""
        s += "You are THE SYSTEM naming a quest for the Player. Cold, theatrical, savagely funny. "
        s += "You are given a situation and a directive. You do NOT change the directive and you do "
        s += "NOT invent numbers.\n\n"
        s += "Answer in EXACTLY two lines and nothing else:\n"
        s += "TITLE: <a quest name, 2-5 words, no quotation marks>\n"
        s += "TAUNT: <one sentence, at most 25 words, mocking the SITUATION and never the person>\n\n"
        s += "Example:\n"
        s += "TITLE: The Horizontal Hours\n"
        s += "TAUNT: Eleven hundred steps. Impressive — most furniture manages that only when moved.\n\n"
        s += "Never mock their body or their weight. If the situation involves pain, injury or "
        s += "illness, drop the theatre and write both lines plainly."
        if let routines = CoachRoutines.promptSection(defaults) { s += "\n\n" + routines }
        return s
    }
}

// MARK: - Issuing
//
// The half that decides whether today should be interrupted at all.
//
// ONE OFFERED AT A TIME. `QuestStore.offered` is what the pop-up reads, and two stacked pop-ups is a
// dialog fight — so nothing new is raised while one is still waiting to be answered.
//
// THE DAILY FIRST, THEN AT MOST ONE SIDE QUEST. The daily is the mission promoted; a side quest is the
// data noticing something. Raising both at once means the second is answered without being read.

@MainActor
enum QuestIssuer {

    /// Raise whatever today has earned, if anything. Safe to call on every appearance of Today.
    static func issueIfDue(repo: Repository, coach: AICoachEngine) async {
        let store = QuestStore.shared
        // Something is already waiting to be answered. Anything raised now would stack behind it and be
        // dismissed unread.
        guard store.offered == nil else { return }

        let dayKey = DailyMissionStore.dayKey()
        let existingToday = store.forDay(dayKey)

        // 1 · The day's own quest, from the mission, once per day.
        if !existingToday.contains(where: { $0.kind == .daily }),
           let mission = await coach.ensureDailyMission() {
            store.upsert(await QuestGenerator.fromMission(mission, coach: coach))
            return
        }

        // 2 · At most one side quest, and only for a condition not already on today's list.
        let days = repo.days
        guard let trigger = QuestTriggers.next(
            today: days.last,
            recent: Array(days.suffix(14)),
            existingToday: existingToday)
        else { return }
        store.upsert(await QuestGenerator.fromTrigger(trigger, coach: coach, dayKey: dayKey))
    }
}
