import Foundation
import StrandAnalytics

// DailyMission.swift — one thing to do today, written overnight.
//
// Swift twin of the Android `com.noop.ai.DailyMission` / `DailyMissionStore` / `DailyMissionWriter`.
// Once a day the coach reads the day's metrics and the wearer's goals and writes ONE mission. Not a
// plan, not a list — a single thing, because a list of five is a list nobody starts.
//
// IT CARRIES NO POINTS. An earlier cut had the model price each mission in XP. XP is gone: the level is
// measured from the body against a frozen scale, not awarded for finishing things, and a second
// currency running beside it would have been two different "levels" in one app. What a mission is worth
// is whether doing it moves the metrics — which the level then shows on its own, without being told.
//
// STORED AS ONE RECORD KEYED BY DAY, not appended to a history. Yesterday's mission is not a thing
// anyone re-reads, and keeping a log of them would make "today's mission" a query rather than a read.

/// One day's mission.
struct DailyMission: Equatable, Codable {
    let dayKey: String
    let text: String
    let createdAt: Date
    /// The measurable goal the mission ends on, as its `GOAL:` line stated it. Optional so a mission
    /// stored before goals still decodes.
    var goalMetric: String?
    var goalThreshold: Double?

    init(dayKey: String, text: String, createdAt: Date = Date(), goal: QuestGoal? = nil) {
        self.dayKey = dayKey
        self.text = text
        self.createdAt = createdAt
        self.goalMetric = goal?.metric.rawValue
        self.goalThreshold = goal?.threshold
    }

    var goal: QuestGoal? {
        guard let raw = goalMetric, let metric = QuestMetric(rawValue: raw), let t = goalThreshold else {
            return nil
        }
        return QuestGoal(metric: metric, threshold: t)
    }
}

enum DailyMissionStore {

    /// Same defaults key as the Android lane.
    static let key = "coach.dailyMission"

    /// Today's mission, or nil when none has been generated for today yet.
    static func today(_ now: Date = Date(), _ d: UserDefaults = .standard) -> DailyMission? {
        guard let stored = read(d), stored.dayKey == dayKey(now) else { return nil }
        return stored
    }

    /// The stored mission whatever day it is for.
    ///
    /// Separate from `today` because a mission from yesterday must NOT be shown as today's, but it is
    /// still the thing the generator would be replacing, and a caller deciding whether to generate
    /// needs to see it.
    static func read(_ d: UserDefaults = .standard) -> DailyMission? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DailyMission.self, from: data)
    }

    static func write(_ mission: DailyMission, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(mission) else { return }
        d.set(data, forKey: key)
    }

    static func clear(_ d: UserDefaults = .standard) {
        d.removeObject(forKey: key)
    }

    /// `yyyy-MM-dd` in the wearer's own zone, matching every other day key in the app.
    static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

enum DailyMissionWriter {

    /// The framing the mission is written under.
    ///
    /// One instruction, stated once: write the mission. An earlier version also asked for an XP line,
    /// which is gone with the currency — and removing it is a small mercy for a small local model,
    /// which now has one job in its output instead of a format to get right first.
    static func systemPrompt(grounding: String, defaults: UserDefaults = .standard) -> String {
        var s = ""
        s += "You are the user's coach: motivating, dryly sarcastic, aimed at the excuse and never "
        s += "at the person. You are writing TODAY'S MISSION — one single concrete thing to do "
        s += "today, chosen from their numbers and their goals. Not a list, not a plan for the "
        s += "week. It must be doable today and it must suit the state their data is in: do not "
        s += "prescribe a hard session on a wrecked night. Keep their stress in mind too: when stress is "
        s += "high, HRV is below baseline or a hard session is already done today, a calming mission "
        s += "(meditation, breathwork, NSDR / yoga nidra, restorative yoga, an earlier night) often beats "
        s += "more training.\n\n"
        s += "Answer with the mission itself, two or three sentences, then ONE final line stating "
        s += "the goal the app will check automatically — no heading, no preamble, no score.\n\n"
        // THE GOAL LINE. The quest closes itself when the data meets it, so the mission has to be
        // something the data can see: a named metric and a number, in a fixed shape a parser does not
        // have to interpret.
        s += "The goal line is exactly one of:\n"
        s += "GOAL: STEPS <number>\n"
        s += "GOAL: WORKOUT_MIN <minutes of training>\n"
        s += "GOAL: MEDITATION_MIN <minutes>\n"
        s += "GOAL: WATER_ML <millilitres>\n"
        s += "GOAL: STRAIN <WHOOP day strain, 0-21>\n"
        s += "GOAL: SLEEP_H <hours tonight>\n"
        s += "GOAL: BEDTIME_BY <HH:MM>\n"
        s += "GOAL: JOURNAL\n"
        s += "The mission must be about that one thing, and its number must match the sentence.\n\n"
        s += "Example:\n"
        s += "Bed by 22:30. Yes, that early. Your HRV has been filing complaints for three days "
        s += "and no amount of Zone 2 is going to out-train a 5-hour night.\n"
        s += "GOAL: BEDTIME_BY 22:30"
        s += "\n\n" + grounding
        if let routines = CoachRoutines.promptSection(defaults) { s += "\n\n" + routines }
        return s
    }

    /// What the model is asked, once the framing above is in place.
    static let question = "Write today's mission."

    /// Read a mission out of the model's answer.
    ///
    /// Returns nil only when there is no usable text at all. A stray `XP: 40` line is still stripped:
    /// the instruction no longer asks for one, but a model that saw thousands of them in training will
    /// occasionally volunteer one anyway, and it must not end up on the strip.
    static func parse(_ answer: String, dayKey: String) -> DailyMission? {
        let lines = answer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The GOAL line is read and then REMOVED: it is for the parser, and "GOAL: STEPS 9000" running
        // across the mission strip would read as a debug print.
        let goal = lines.lazy.compactMap { QuestGoal.parseLine($0) }.first
        let text = lines
            .filter { !isScoreLine($0) && QuestGoal.parseLine($0) == nil
                && !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("GOAL:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return DailyMission(dayKey: dayKey, text: text, goal: goal ?? QuestGoal.parse(text))
    }

    /// A leftover `XP: 40` line, with or without the colon or surrounding asterisks.
    private static let scoreLine = try? NSRegularExpression(
        pattern: #"^\s*\**xp\**\s*:?\s*\d{1,9}\s*\**\s*$"#,
        options: [.caseInsensitive])

    private static func isScoreLine(_ line: String) -> Bool {
        guard let re = scoreLine else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return re.firstMatch(in: line, options: [], range: range) != nil
    }
}
