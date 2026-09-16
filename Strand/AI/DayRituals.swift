import Foundation
import StrandAnalytics

// DayRituals.swift — the three times a day the system speaks first.
//
// Not notifications with text in them. Each slot is a GENERATION with its own framing, its own question
// and its own consequence, run against the day's real figures:
//
//   · 06:40 THE MORNING BRIEFING, and the day's quest. What the night did, what that means for today,
//     and one thing to commit to. The quest is raised here because a directive issued at breakfast has
//     a whole day to be met; one issued in the evening is a reproach.
//   · 13:30 THE MIDDAY REFRESH, and a side quest. How the day has actually gone against how it was
//     meant to go, and one correction that still fits in the afternoon.
//   · 19:00 THE REVISIT. No quest. The day is over as far as changing it goes, so this is analysis, a
//     few lines of journal, and a short questionnaire — the things that make TOMORROW's briefing
//     better rather than trying to salvage today.
//
// THE EVENING RAISES NOTHING, and that is the point of having three rather than three of the same. A
// quest at seven in the evening is a commitment the wearer either breaks or stays up to keep, and both
// of those are worse than the quest not existing.
//
// THE FIGURES ARE HANDED OVER, NEVER INFERRED. Every slot's prompt carries recovery, sleep, strain,
// stress, the day's deficits and the weather as already-computed numbers. A model asked to read a day
// and set a target will invent both; its job here is the sentence and the name.
//
// EACH SLOT RUNS AT MOST ONCE A DAY, keyed on the local day and the slot. A phone woken three times
// before lunch must not produce three morning briefings.

enum DayRitual: String, CaseIterable, Identifiable, Sendable {
    case morning
    case midday
    case evening

    var id: String { rawValue }

    /// Minutes since local midnight.
    var minutes: Int {
        switch self {
        case .morning: return 6 * 60 + 40
        case .midday: return 13 * 60 + 30
        case .evening: return 19 * 60
        }
    }

    var title: String {
        switch self {
        case .morning: return "Morning briefing"
        case .midday: return "Midday refresh"
        case .evening: return "Evening revisit"
        }
    }

    /// Whether this slot raises a quest, and of which kind.
    var questKind: QuestKind? {
        switch self {
        case .morning: return .daily
        case .midday: return .side
        case .evening: return nil   // see the note at the top
        }
    }

    /// What the model is asked, once the framing is in place.
    var question: String {
        switch self {
        case .morning:
            return "Give me this morning's briefing."
        case .midday:
            return "How is the day actually going, and what is the one correction worth making now?"
        case .evening:
            return "Close out the day: what happened, and what should I take into tomorrow?"
        }
    }

    /// The framing. One paragraph of instruction, then the day's figures.
    ///
    /// The TONE is the app's own throughout — cold, precise, dryly funny, contempt for the excuse and
    /// never for the person — because a system that changes voice three times a day is three systems.
    func systemPrompt(grounding: String, defaults: UserDefaults = .standard) -> String {
        var s = "You are THE SYSTEM, reading this human's own data. Cold, precise, dryly funny; your "
        s += "contempt is for the EXCUSE and never for the person. Never invent a number: every figure "
        s += "you may use is below.\n\n"

        switch self {
        case .morning:
            s += "This is the MORNING BRIEFING. In three short parts, under 120 words total: "
            s += "(1) what last night did, citing recovery and sleep; "
            s += "(2) what that means for today's training — do not prescribe a hard session on a "
            s += "wrecked night; "
            s += "(3) the one thing that would most improve tonight.\n"
        case .midday:
            s += "This is the MIDDAY REFRESH. Under 80 words. Compare how the day has ACTUALLY gone "
            s += "with how it was meant to go, and name ONE correction that still fits in the "
            s += "afternoon. If the day is on track, say so plainly rather than inventing a problem.\n"
        case .evening:
            s += "This is the EVENING REVISIT. The day cannot be changed now, so do not prescribe "
            s += "anything for it. Under 100 words: what actually happened, what it cost, and the one "
            s += "thing worth carrying into tomorrow. End with a single short question for them to "
            s += "answer in their journal — something only they can tell you, not something in the "
            s += "data.\n"
        }

        s += "\nNo heading, no preamble, no markdown, no lists.\n\n"
        s += grounding
        if let goals = CoachGoals.promptSection(defaults) { s += "\n\n" + goals }
        return s
    }

    /// The framing for this slot's QUEST, when it raises one.
    ///
    /// Separate from the briefing's: the briefing is prose the wearer reads, and a quest is a NAME and a
    /// TAUNT over a directive the app has already decided. Asking for both in one answer produced a
    /// briefing with a title bolted onto it.
    func questSystemPrompt(grounding: String, defaults: UserDefaults = .standard) -> String {
        var s = "You are THE SYSTEM setting this human ONE directive. Cold, theatrical, savagely funny; "
        s += "your contempt is for the EXCUSE and never for the person.\n\n"
        switch self {
        case .morning:
            s += "It is the morning. The directive is for TODAY and must be doable today, and it must "
            s += "suit the state their data is in.\n"
        case .midday:
            s += "It is the middle of the afternoon. The directive must fit in what is LEFT of the day "
            s += "— an hour or two, not a training block.\n"
        case .evening:
            s += ""
        }
        s += "Answer in EXACTLY four lines and nothing else:\n"
        s += "TITLE: <a quest name, 2-5 words, no quotation marks>\n"
        s += "TARGET: <the directive itself, one sentence, with its number in it>\n"
        s += "TAUNT: <one sentence, at most 25 words, mocking the SITUATION and never the person>\n"
        // The quest closes ITSELF when the data meets this, so the directive has to be one the data
        // can see. Anything else — "stretch your hamstrings", "call a friend" — is not a quest here.
        s += "GOAL: <exactly one of: STEPS <n> | WORKOUT_MIN <n> | MEDITATION_MIN <n> | WATER_ML <n> | "
        s += "STRAIN <0-21> | SLEEP_H <n> | BEDTIME_BY <HH:MM> | JOURNAL>\n\n"
        s += "The directive MUST be something that goal measures, with the same number.\n\n"
        s += "Example:\n"
        s += "TITLE: The Horizontal Hour\n"
        s += "TARGET: 15 minutes of slow breathing after the gym, before you touch a screen.\n"
        s += "TAUNT: Your stress has been flat out since ten. Lying still is not a reward, it is "
        s += "maintenance.\n"
        s += "GOAL: MEDITATION_MIN 15\n\n"
        s += "Ground the directive in the figures below — a low recovery earns rest, a high one earns "
        s += "work, a wet forecast rules out anything outdoors. NEVER invent a number.\n\n"
        s += grounding
        if let goals = CoachGoals.promptSection(defaults) { s += "\n\n" + goals }
        return s
    }
}

// MARK: - The day's figures, as one block
//
// Every slot's prompt and every quest's prompt is grounded in this. Built in one place so the three
// cannot drift into disagreeing about the same day, and so a figure that is MISSING is stated as
// missing rather than silently omitted — a model that cannot see a recovery score will assume one.

struct RitualGrounding {
    var recovery: Double?
    var sleepScore: Double?
    var strain: Double?
    var energy: EnergyBalance?
    var deficits: [DayDeficit] = []
    var weather: WeatherNow?
    var streaks: [Streak] = []

    /// The block handed to the model.
    var text: String {
        var lines: [String] = ["TODAY'S FIGURES:"]
        lines.append("- Recovery: " + (recovery.map { "\(Int($0.rounded()))%" } ?? "not scored yet"))
        lines.append("- Sleep score: " + (sleepScore.map { "\(Int($0.rounded()))%" } ?? "not scored yet"))
        lines.append("- Strain so far: "
                     + (strain.map { String(format: "%.1f of 21", $0) } ?? "not scored yet"))
        if let energy {
            lines.append(String(
                format: "- Energy bank: %d of the %d it opened with (%@) — %d spent on strain, %d on stress",
                Int(energy.balance.rounded()), Int(energy.opening.rounded()),
                EnergyBank.state(energy.balance),
                Int(energy.strainSpend.rounded()), Int(energy.stressSpend.rounded())))
        }
        if let line = DayDeficits.promptLine(deficits) { lines.append("- " + line) }
        if let weather { lines.append("- " + weather.promptLine) }
        if !streaks.isEmpty {
            let running = streaks.filter { $0.days > 0 }
                .map { "\(streakName($0.kind)) \($0.days)d" }
                .joined(separator: ", ")
            if !running.isEmpty { lines.append("- Streaks running: " + running) }
        }
        return lines.joined(separator: "\n")
    }

    private func streakName(_ kind: StreakKind) -> String {
        switch kind {
        case .sleepConsistency: return "bed and wake time within 30 minutes of the night before"
        case .sleepDebt: return "sleep debt"
        case .stressTime: return "stress time"
        case .journal: return "journal"
        }
    }
}

// MARK: - What a slot produced

/// One ritual's output: the prose, and the quest it raised.
///
/// `Identifiable` so it can drive a `.sheet(item:)` — the id is the slot and the day, so the same
/// ritual cannot present twice.
struct RitualResult: Identifiable {
    var id: String { ritual.rawValue + "-" + DailyMissionStore.dayKey() }

    let ritual: DayRitual
    let text: String
    let quest: Quest?
}

enum DayRitualWriter {

    /// The three lines a quest answer carries.
    struct WrittenQuest: Equatable {
        let title: String
        let target: String
        let taunt: String
        /// What closes it. Nil when neither the GOAL line nor the directive states anything measurable.
        let goal: QuestGoal?
    }

    /// Read a quest out of the model's answer.
    ///
    /// The TARGET is required here, unlike the naming-only path elsewhere: in a ritual the model is
    /// choosing what the directive IS, so an answer without one is not a quest at all. Better no quest
    /// than a stock one attached to a title the model made up for a different directive.
    static func parseQuest(_ answer: String) -> WrittenQuest? {
        func field(_ label: String) -> String? {
            for raw in answer.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                let lower = line.lowercased()
                    .replacingOccurrences(of: "*", with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard lower.hasPrefix(label.lowercased()) else { continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "*\"“”"))
                if !value.isEmpty { return value }
            }
            return nil
        }
        guard let title = field("title"), let target = field("target") else { return nil }
        let goal = answer.split(whereSeparator: \.isNewline).lazy
            .compactMap { QuestGoal.parseLine(String($0)) }.first
        return WrittenQuest(title: String(title.prefix(QuestNaming.maxTitleChars)),
                            target: target,
                            taunt: String((field("taunt") ?? "").prefix(QuestNaming.maxTauntChars)),
                            goal: goal ?? QuestGoal.parse(target))
    }
}
