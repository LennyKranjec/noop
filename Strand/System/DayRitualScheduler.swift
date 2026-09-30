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

    /// The single switch before HEALTH_V2 H4. Read once, by `migrateLegacy`, and then removed.
    static let legacyEnabledKey = "rituals.enabled"
    private static let requestPrefix = "ritual-"
    static let notificationCategoryId = "day-ritual"

    /// ONE SWITCH PER SLOT (HEALTH_V2 H4): `rituals.enabled.{morning,midday,evening}`.
    static func enabledKey(_ slot: DayRitual) -> String { "rituals.enabled.\(slot.rawValue)" }

    /// The morning ON, midday and evening OFF. The morning briefing is the app's own rhythm; three knocks a
    /// day by default was more than most wearers asked for.
    ///
    /// ON IS NOT PERMISSION, and it is not a reason to speak either: `schedule()` additionally requires
    /// notification authorization the user has already granted somewhere they asked for it, and a day
    /// that has actually been scored. A default-ON preference that could by itself raise a permission
    /// dialog and then schedule daily claims about an empty install is what this used to be.
    nonisolated static func defaultEnabled(_ slot: DayRitual) -> Bool { slot == .morning }

    /// Whether `slot` is on.
    static func isEnabled(slot: DayRitual, _ d: UserDefaults = .standard) -> Bool {
        migrateLegacy(d)
        return (d.object(forKey: enabledKey(slot)) as? Bool) ?? defaultEnabled(slot)
    }

    /// Whether any slot is on.
    static var isEnabled: Bool { DayRitual.allCases.contains { isEnabled(slot: $0) } }

    /// A wearer who had switched the rituals OFF keeps them off: every slot not yet set explicitly is
    /// written off. A legacy ON (the old default) says nothing about which slots were wanted, so the
    /// per-slot defaults apply. The legacy key is removed either way, so this runs once.
    static func migrateLegacy(_ d: UserDefaults = .standard) {
        guard let legacy = d.object(forKey: legacyEnabledKey) as? Bool else { return }
        if !legacy {
            for slot in DayRitual.allCases where d.object(forKey: enabledKey(slot)) == nil {
                d.set(false, forKey: enabledKey(slot))
            }
        }
        d.removeObject(forKey: legacyEnabledKey)
    }

    /// Switch one slot, registering or cancelling just that slot's notification.
    static func setEnabled(_ on: Bool, slot: DayRitual) async {
        migrateLegacy()
        UserDefaults.standard.set(on, forKey: enabledKey(slot))
        if on { await schedule() } else { cancel([slot]) }
    }

    /// Switch every slot at once.
    static func setEnabled(_ on: Bool) async {
        migrateLegacy()
        for slot in DayRitual.allCases { UserDefaults.standard.set(on, forKey: enabledKey(slot)) }
        if on { await schedule() } else { cancel() }
    }

    /// When `ritual` runs, in minutes past local midnight: the morning at the sleep anchor + 15 minutes
    /// when there is one (`SleepScheduleProvider.morningRitualMinute`), its own default time otherwise;
    /// the other slots at their fixed times. Pure.
    nonisolated static func minute(_ ritual: DayRitual, morningAnchorMinute: Int?) -> Int {
        guard ritual == .morning, let anchored = morningAnchorMinute else { return ritual.minutes }
        return ((anchored % 1440) + 1440) % 1440
    }

    /// The morning ritual's minute for the day `date` falls on.
    static func morningMinute(on date: Date) -> Int {
        minute(.morning, morningAnchorMinute: SleepScheduleProvider.shared.morningRitualMinute(on: date))
    }

    /// The next date on or after `now` that falls on `weekday` (1 = Sunday ... 7 = Saturday). Pure.
    nonisolated static func nextDate(weekday: Int, from now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.component(.weekday, from: now)
        let ahead = ((weekday - today) % 7 + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: now) ?? now
    }

    /// Every notification identifier a slot may have registered. The morning is one per weekday (the
    /// anchor differs at weekends); the bare `ritual-morning` is the pre-H4 daily one, cancelled with it.
    nonisolated static func requestIds(_ ritual: DayRitual) -> [String] {
        let base = requestPrefix + ritual.rawValue
        guard ritual == .morning else { return [base] }
        return [base] + (1...7).map { "\(base)-\($0)" }
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

    /// Whether NOOP has ever SCORED a day — a level written to the ledger, not merely a day that turned.
    ///
    /// The morning knock says "Last night is scored." On a fresh install with no strap paired, nothing
    /// has been scored and nothing is going to be, so registering that trigger schedules a daily claim
    /// about data that does not exist. `LevelLedger.latest` returns a WRITTEN level or nil; a day settled
    /// as a gap is not an entry, so an install that has only ever recorded empty nights still reads false.
    /// Read-only — this asks the ledger a question, it does not touch it.
    static var hasScoredDay: Bool {
        LevelLedger.shared.latest(onOrBefore: DailyMissionStore.dayKey()) != nil
    }

    /// The whole gate, as one pure decision — so what `schedule()` refuses on is pinned by a test rather
    /// than buried inside an async call nothing can drive.
    ///
    /// `status` is READ, never requested: `.notDetermined` means nobody has asked yet, and this is not
    /// the place that asks.
    static func mayRegister(enabled: Bool, hasScoredDay: Bool, status: UNAuthorizationStatus) -> Bool {
        enabled && hasScoredDay && NotificationPermission.delivers(status)
    }

    /// Register the three repeating notifications. Safe to call on every launch: the identifiers are
    /// stable, so re-adding replaces rather than stacks.
    ///
    /// IT NEVER RAISES THE SYSTEM DIALOG. This used to call `requestAuthorization` cold, from a `.task`
    /// on the Today screen that runs at launch — BEHIND the onboarding wizard and the un-accepted Terms
    /// gate. It was the only cold prompt in the app (every other site reads `getNotificationSettings`
    /// first), it fired before the user had agreed to anything, and it made the wizard's own Notifications
    /// step decorative: by the time that step asked, iOS had already spent the one dialog it ever shows.
    /// Permission is now asked for ONLY where a user action asks for it — the wizard's Notifications step,
    /// and the alarm toggles that need it — and this registers against the answer rather than demanding it.
    ///
    /// AND IT REGISTERS NOTHING UNTIL A DAY HAS BEEN SCORED. `knockText(.morning)` says "Last night is
    /// scored"; on an install with no strap that was a daily notification asserting something that had
    /// never happened. `schedule()` is called on every Today appearance, so the triggers appear by
    /// themselves on the first morning there is genuinely something to say.
    static func schedule() async {
        #if canImport(UserNotifications)
        guard mayRegister(enabled: isEnabled,
                          hasScoredDay: hasScoredDay,
                          status: await NotificationPermission.status()) else { return }
        let centre = UNUserNotificationCenter.current()
        let now = Date()

        for ritual in DayRitual.allCases {
            // PER SLOT: a slot switched off has its own requests withdrawn, the others are untouched.
            guard isEnabled(slot: ritual) else {
                cancel([ritual])
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = ritual.title
            // ONE LINE, AND NOT THE BRIEFING. See the note at the top on why the body cannot be the
            // generated text. What it can honestly say is what is waiting.
            content.body = knockText(ritual)
            content.sound = .default
            content.categoryIdentifier = notificationCategoryId
            content.userInfo = ["ritual": ritual.rawValue]

            if ritual == .morning {
                // ONE PER WEEKDAY, at that weekday's anchor + 15 (the weekend offset makes them differ).
                // The pre-H4 single daily request is withdrawn so the morning never knocks twice.
                let base = requestPrefix + ritual.rawValue
                centre.removePendingNotificationRequests(withIdentifiers: [base])
                for weekday in 1...7 {
                    let minute = morningMinute(on: nextDate(weekday: weekday, from: now))
                    var when = DateComponents()
                    when.weekday = weekday
                    when.hour = minute / 60
                    when.minute = minute % 60
                    let request = UNNotificationRequest(
                        identifier: "\(base)-\(weekday)",
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true))
                    try? await centre.add(request)
                }
                continue
            }

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

    /// Withdraw the notifications of `slots` (every slot by default).
    static func cancel(_ slots: [DayRitual] = DayRitual.allCases) {
        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: slots.flatMap { requestIds($0) })
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

        var block = grounding.text
        // THE EVENING READS THE JOURNAL. What the wearer logged today — the coffee at four, the drink
        // with dinner, the late screen — is the half of the day the data cannot see, and the revisit is
        // the one slot that is ABOUT the day as a whole. Handed over as logged, never summarised.
        if ritual == .evening, let journal = await journalBlock(repo: repo, day: today) {
            block += "\n\n" + journal
        }
        guard let prose = await coach.generateOneShot(
            systemPrompt: ritual.systemPrompt(grounding: block),
            question: ritual.question,
            budget: .ritual)
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

    /// The day's own journal entries, as lines the model can cite. Nil when nothing was logged.
    static func journalBlock(repo: Repository, day: String) async -> String? {
        let answers = await repo.nativeJournalAnswers(day: day)
        let numeric = await repo.nativeJournalNumeric(day: day)
        var lines: [String] = []
        for (question, yes) in answers.sorted(by: { $0.key < $1.key }) {
            lines.append("- \(question): \(yes ? "yes" : "no")")
        }
        for (question, value) in numeric.sorted(by: { $0.key < $1.key }) {
            let shown = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
            lines.append("- \(question): \(shown)")
        }
        guard !lines.isEmpty else { return nil }
        return "TODAY'S JOURNAL (logged by the wearer; connect it to the figures where it explains "
            + "them, and never invent an entry):\n" + lines.joined(separator: "\n")
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
            question: "Set the directive.",
            budget: .ritual),
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
    ///
    /// ONLY ENABLED SLOTS (H4): a slot switched off is not run on open either, and the morning is due at
    /// its anchored time.
    static func dueRituals(now: Date = Date()) -> [DayRitual] {
        due(now: now,
            morningAnchorMinute: SleepScheduleProvider.shared.morningRitualMinute(on: now),
            enabled: { isEnabled(slot: $0) },
            lastRun: { lastRunDay($0) })
    }

    /// `dueRituals`, with every read handed in. Pure.
    nonisolated static func due(now: Date, calendar: Calendar = .current, morningAnchorMinute: Int?,
                                enabled: (DayRitual) -> Bool,
                                lastRun: (DayRitual) -> String?) -> [DayRitual] {
        let minutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let today = DailyMissionStore.dayKey(now, calendar: calendar)
        func at(_ r: DayRitual) -> Int { minute(r, morningAnchorMinute: morningAnchorMinute) }
        return DayRitual.allCases
            .filter { enabled($0) && at($0) <= minutes && lastRun($0) != today }
            .sorted { at($0) < at($1) }
    }
}
