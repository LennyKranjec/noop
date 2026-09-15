import Foundation

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

    init(dayKey: String, text: String, createdAt: Date = Date()) {
        self.dayKey = dayKey
        self.text = text
        self.createdAt = createdAt
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
        s += "prescribe a hard session on a wrecked night.\n\n"
        s += "Answer with the mission itself, two or three sentences, and nothing else — no heading, "
        s += "no preamble, no score.\n\n"
        s += "Example:\n"
        s += "Bed by 22:30. Yes, that early. Your HRV has been filing complaints for three days "
        s += "and no amount of Zone 2 is going to out-train a 5-hour night."
        s += "\n\n" + grounding
        if let goals = CoachGoals.promptSection(defaults) { s += "\n\n" + goals }
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
        let text = answer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isScoreLine(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return DailyMission(dayKey: dayKey, text: text)
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
