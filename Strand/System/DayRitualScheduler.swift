import Foundation
import StrandAnalytics
#if canImport(UserNotifications)
import UserNotifications
#endif

// DayRitualScheduler.swift — when the three rituals fire, and what happens when one does.
//
// THREE REPEATING LOCAL NOTIFICATIONS, one per slot, at the wearer's own clock. Local because there is
// no server in this app and there is not going to be one: the figures never leave the device, so the
// thing that decides when to speak cannot live anywhere else.
//
// THE NOTIFICATION IS THE KNOCK, NOT THE CONTENT. iOS cannot run a generation to fill a notification
// body at delivery time — the model is a network round trip and the app is not running — so the
// notification says which ritual is ready and the text is generated when the wearer opens it. That is
// the honest shape: a body written hours in advance would be a briefing about a day that had not
// happened yet.
//
// EACH RITUAL RUNS AT MOST ONCE A DAY, keyed on (day, slot). A phone woken three times before lunch
// must not produce three morning briefings, and a wearer who opens the app at 06:45 and again at 08:00
// should see the same briefing rather than a second opinion.
//
// A MISSED SLOT IS CAUGHT UP, ONCE. Opening the app at ten with an un-run 06:40 briefing runs it then,
// because a briefing read at ten is still worth reading; a slot whose own day has passed is not.

@MainActor
enum DayRitualScheduler {

    private static let enabledKey = "rituals.enabled"
    private static let requestPrefix = "ritual-"
    static let notificationCategoryId = "day-ritual"

    /// Default ON. The three slots are the app's own rhythm rather than an added feature, and a system
    /// that only ever speaks when spoken to is a search box.
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func setEnabled(_ on: Bool) async {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { await schedule() } else { cancel() }
    }

    /// The last day each slot produced something, so a repeat open does not re-run it.
    private static func lastRunKey(_ ritual: DayRitual) -> String { "rituals.lastRun.\(ritual.rawValue)" }

    static func lastRunDay(_ ritual: DayRitual) -> String? {
        UserDefaults.standard.string(forKey: lastRunKey(ritual))
    }

    /// The text each slot last produced, so opening the notification shows what was written rather than
    /// writing it again.
    private static func textKey(_ ritual: DayRitual) -> String { "rituals.text.\(ritual.rawValue)" }

    static func storedText(_ ritual: DayRitual) -> String? {
        guard lastRunDay(ritual) == DailyMissionStore.dayKey() else { return nil }
        return UserDefaults.standard.string(forKey: textKey(ritual))
    }

    // MARK: - Scheduling

    /// Register the three repeating notifications. Safe to call on every launch: the identifiers are
    /// stable, so re-adding replaces rather than stacks.
    static func schedule() async {
        #if canImport(UserNotifications)
        guard isEnabled else { return }
        let centre = UNUserNotificationCenter.current()
        guard let granted = try? await centre.requestAuthorization(options: [.alert, .sound, .badge]),
              granted
        else { return }

        for ritual in DayRitual.allCases {
            let content = UNMutableNotificationContent()
            content.title = ritual.title
            // ONE LINE, AND NOT THE BRIEFING. See the note at the top on why the body cannot be the
            // generated text. What it can honestly say is what is waiting.
            content.body = knockText(ritual)
            content.sound = .default
            content.categoryIdentifier = notificationCategoryId
            content.userInfo = ["ritual": ritual.rawValue]

            var when = DateComponents()
            when.hour = ritual.minutes / 60
            when.minute = ritual.minutes % 60

            let request = UNNotificationRequest(
                identifier: requestPrefix + ritual.rawValue,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
            try? await centre.add(request)
        }
        #endif
    }

    static func cancel() {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: DayRitual.allCases.map { requestPrefix + $0.rawValue })
        #endif
    }

    private static func knockText(_ ritual: DayRitual) -> String {
        switch ritual {
        case .morning: return "Last night is scored. Your day's directive is waiting."
        case .midday: return "Half the day is in. One correction still fits."
        case .evening: return "Close the day out — and tell me one thing the data cannot."
        }
    }

    // MARK: - Running one

    /// Run `ritual` if its day has not already produced it. Returns what it produced, or nil.
    ///
    /// THE GENERATION HAPPENS HERE, on open, not at delivery — see the note at the top.
    @discardableResult
    static func runIfDue(_ ritual: DayRitual,
                         repo: Repository,
                         coach: AICoachEngine,
                         grounding: RitualGrounding) async -> RitualResult? {
        let today = DailyMissionStore.dayKey()
        guard lastRunDay(ritual) != today else {
            // Already run. Hand back what it said rather than nothing: the wearer may be opening the
            // notification for the second time, and a blank screen would read as a failure.
            guard let text = storedText(ritual) else { return nil }
            return RitualResult(ritual: ritual, text: text, quest: nil)
        }
        guard coach.isConfigured, coach.dataConsent else { return nil }

        let block = grounding.text
        guard let prose = await coach.generateOneShot(
            systemPrompt: ritual.systemPrompt(grounding: block),
            question: ritual.question)
        else { return nil }

        // MARKED RUN ONLY ONCE THERE IS SOMETHING TO SHOW. Marking before the round trip would turn a
        // dead network into a slot that silently never fires again today.
        UserDefaults.standard.set(today, forKey: lastRunKey(ritual))
        UserDefaults.standard.set(prose, forKey: textKey(ritual))

        var raised: Quest?
        if let kind = ritual.questKind, QuestStore.shared.offered == nil {
            raised = await raiseQuest(kind: kind, ritual: ritual, coach: coach,
                                      grounding: block, dayKey: today)
        }
        return RitualResult(ritual: ritual, text: prose, quest: raised)
    }

    /// Ask for this slot's quest and offer it.
    ///
    /// A failed or unparseable answer raises NOTHING. The other quest paths fall back to a stock name
    /// over a trigger-chosen directive; here the model is choosing the directive itself, so there is no
    /// directive to fall back onto — and a stock quest attached to a day it was not written for is
    /// worse than the slot staying quiet.
    private static func raiseQuest(kind: QuestKind, ritual: DayRitual, coach: AICoachEngine,
                                   grounding: String, dayKey: String) async -> Quest? {
        guard let answer = await coach.generateOneShot(
            systemPrompt: ritual.questSystemPrompt(grounding: grounding),
            question: "Set the directive."),
            let written = DayRitualWriter.parseQuest(answer),
            // NO GOAL, NO QUEST. It would be a directive nothing can close, and quests are no longer
            // closed by the wearer saying so.
            let goal = written.goal
        else { return nil }

        let quest = Quest(
            kind: kind,
            title: written.title,
            taunt: written.taunt,
            target: written.target,
            rewards: QuestNaming.rewards(forDirective: written.target),
            xp: kind == .daily ? 60 : 40,
            dayKey: dayKey,
            createdAtMs: nowMs(),
            // The midday quest expires with the day rather than 24 hours later: an afternoon
            // correction that could still be met at noon tomorrow is not a correction.
            expiresAtMs: endOfDayMs(),
            goal: goal)
        QuestStore.shared.upsert(quest)
        return quest
    }

    /// Local midnight tonight, in epoch milliseconds.
    private static func endOfDayMs() -> Int64 {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86_400)
        return Int64(end.timeIntervalSince1970 * 1000)
    }

    /// Every slot whose time has passed today and which has not run yet, oldest first.
    ///
    /// ONLY TODAY'S. A briefing read at ten is still worth reading; yesterday's is history, and running
    /// it would write yesterday's directive onto today.
    static func dueRituals(now: Date = Date()) -> [DayRitual] {
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let today = DailyMissionStore.dayKey(now)
        return DayRitual.allCases
            .filter { $0.minutes <= minutes && lastRunDay($0) != today }
            .sorted { $0.minutes < $1.minutes }
    }
}
