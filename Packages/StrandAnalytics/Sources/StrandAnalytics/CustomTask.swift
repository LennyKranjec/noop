import Foundation

// CustomTask.swift — tasks the wearer asks for, turned into quests.
//
// Everything else on the quest strip is the SYSTEM's idea: a trigger read the data and decided the day
// needed a directive. A custom task is the opposite way round — the wearer describes what they want in
// the coach ("walk 8000 steps today", "remind me to stretch after lunch"), the coach turns the sentence
// into a structured task, and it rides the same strip, the same clock and the same completion and
// failure pop-ups as any other quest (`QuestKind.custom`).
//
// THE MODEL ANSWERS IN JSON, AND THE PARSE TRUSTS NONE OF IT. The title is capped, the metric must be
// one the quest system can already check (`QuestMetric`), the number must be inside a sane range for
// that metric, and a deadline must be in the future and inside a week. Anything that fails a check is
// dropped rather than failing the task: a task with no measurable goal is simply ticked off by hand.
//
// IT NEVER FAILS TO ADD. No provider, no network, or an answer that is not JSON at all: the wearer's
// own words become the task (`fallback`). They asked for something; silence is not an answer.

/// What the coach made of the wearer's request, before it is added. Editable in the preview.
public struct CustomTaskDraft: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// The deadline, epoch ms. Nil = the default quest window (`Quest.defaultWindowMs`).
    public var dueAtMs: Int64?
    /// A goal the data can close it on. Nil = ticked off by hand.
    public var goal: QuestGoal?
    /// Whether the coach wrote it (true) or it is the wearer's words verbatim because it could not (false).
    public var fromCoach: Bool

    public init(title: String, detail: String = "", dueAtMs: Int64? = nil, goal: QuestGoal? = nil,
                fromCoach: Bool = true) {
        self.title = title
        self.detail = detail
        self.dueAtMs = dueAtMs
        self.goal = goal
        self.fromCoach = fromCoach
    }
}

public enum CustomTaskParser {

    /// A detail line longer than this is rambling, and the chip and sheet only have room for a sentence.
    public static let maxDetailChars = 180
    /// A deadline closer than this is already over by the time the card is read.
    public static let minLeadMs: Int64 = 5 * 60 * 1000
    /// A deadline further out than this is not a task for Today.
    public static let maxWindowMs: Int64 = 7 * 24 * 60 * 60 * 1000
    /// What a custom task is worth. Fixed and modest: the wearer set the bar themselves.
    public static let xp = 20

    /// The answer format, as the model is told it. Kept beside the parser so the two cannot drift.
    public static let responseFormat: String = """
    Reply with ONLY one JSON object, no prose, no markdown fences:
    {"title": "<2-6 words>", "detail": "<one plain sentence, at most 25 words>", \
    "due": "<HH:MM local 24h time, or null>", "metric": "<one of STEPS, WORKOUT_MIN, MEDITATION_MIN, \
    WATER_ML, STRAIN, SLEEP_H, BEDTIME_BY, BEDTIME_EARLIER, JOURNAL, or null>", \
    "target": <a number, "HH:MM" for BEDTIME_BY, or null>}
    """

    // MARK: - Reading the answer

    /// The draft the model's answer describes, or nil when the answer holds no JSON object at all.
    public static func parse(_ answer: String, userText: String, now: Date,
                             calendar: Calendar = .current) -> CustomTaskDraft? {
        guard let o = jsonObject(in: answer) else { return nil }
        let rawTitle = clean(o["title"] as? String ?? "")
        let title = rawTitle.isEmpty ? titleFromUserText(userText) : cap(rawTitle, QuestNaming.maxTitleChars)
        guard !title.isEmpty else { return nil }
        return CustomTaskDraft(
            title: title,
            detail: cap(clean(o["detail"] as? String ?? ""), maxDetailChars),
            dueAtMs: dueMs(o["due"], now: now, calendar: calendar),
            goal: goal(metric: o["metric"], target: o["target"]),
            fromCoach: true)
    }

    /// The wearer's own words as a task, for when there is no usable answer.
    ///
    /// A goal is read out of the sentence only when it names a quantity unambiguously. The general
    /// "N minutes" pattern is NOT trusted here: "stretch for 10 minutes" is not ten minutes of logged
    /// training, and a task tied to the wrong metric would never close itself.
    public static func fallback(userText: String) -> CustomTaskDraft {
        let text = clean(userText)
        let parsed = QuestGoal.parse(text)
        let goal = parsed.flatMap { $0.metric == .workoutMinutes ? nil : $0 }
        return CustomTaskDraft(
            title: titleFromUserText(text),
            detail: text.count > QuestNaming.maxTitleChars ? cap(text, maxDetailChars) : "",
            dueAtMs: nil,
            goal: goal,
            fromCoach: false)
    }

    /// The model's answer if it is usable, otherwise the fallback. Never nil.
    public static func resolve(answer: String?, userText: String, now: Date,
                               calendar: Calendar = .current) -> CustomTaskDraft {
        if let answer = answer, let draft = parse(answer, userText: userText, now: now, calendar: calendar) {
            return draft
        }
        return fallback(userText: userText)
    }

    // MARK: - Building the quest

    /// The quest a confirmed draft becomes: accepted already (the wearer asked for it), on today's key.
    ///
    /// The deadline is re-checked here because the preview can sit open: a due time that was ten minutes
    /// away when written may be in the past by the time "Add" is tapped, and then the default window
    /// applies rather than a task that is born failed.
    public static func makeQuest(_ draft: CustomTaskDraft, now: Date, calendar: Calendar = .current,
                                 id: String = UUID().uuidString) -> Quest {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let title = cap(clean(draft.title), QuestNaming.maxTitleChars)
        let safeTitle = title.isEmpty ? "Task" : title
        let detail = cap(clean(draft.detail), maxDetailChars)
        let due = draft.dueAtMs.flatMap { isAcceptableDue($0, nowMs: nowMs) ? $0 : nil }
        return Quest(
            id: id,
            kind: .custom,
            title: safeTitle,
            taunt: "",
            target: detail.isEmpty ? safeTitle : detail,
            rewards: QuestNaming.rewards(forDirective: safeTitle + " " + detail),
            xp: xp,
            state: .active,
            dayKey: dayKey(now, calendar: calendar),
            createdAtMs: nowMs,
            expiresAtMs: due,
            goal: draft.goal)
    }

    // MARK: - Pieces

    /// A title made of the wearer's sentence: first line, first letter up, capped at a word boundary.
    static func titleFromUserText(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let line = clean(firstLine)
        guard let first = line.first else { return "" }
        return cap(first.uppercased() + line.dropFirst(), QuestNaming.maxTitleChars)
    }

    /// Whitespace collapsed and trimmed, surrounding quotes dropped.
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„ "))
    }

    /// At most `limit` characters, cut at a word where there is one, with an ellipsis.
    static func cap(_ s: String, _ limit: Int) -> String {
        guard s.count > limit, limit > 1 else { return s }
        let head = String(s.prefix(limit - 1))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space]) + "…"
        }
        return head + "…"
    }

    static func isAcceptableDue(_ ms: Int64, nowMs: Int64) -> Bool {
        ms >= nowMs + minLeadMs && ms <= nowMs + maxWindowMs
    }

    /// A deadline out of "HH:MM" (the next time the clock shows it) or an ISO-8601 date-time.
    static func dueMs(_ raw: Any?, now: Date, calendar: Calendar) -> Int64? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              s.lowercased() != "null" else { return nil }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var date: Date?
        if let hm = clock(s) {
            var c = calendar.dateComponents([.year, .month, .day], from: now)
            c.hour = hm.0
            c.minute = hm.1
            if let today = calendar.date(from: c) {
                // A time already gone today means the next one: "13:30" asked at 15:00 is tomorrow's.
                if Int64(today.timeIntervalSince1970 * 1000) < nowMs + minLeadMs {
                    date = calendar.date(byAdding: .day, value: 1, to: today)
                } else {
                    date = today
                }
            }
        } else {
            date = isoDate(s, calendar: calendar)
        }
        guard let date = date else { return nil }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return isAcceptableDue(ms, nowMs: nowMs) ? ms : nil
    }

    /// "HH:MM" or "H.MM", as hour and minute.
    static func clock(_ s: String) -> (Int, Int)? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count == 2, parts.allSatisfy({ $0.count <= 2 && !$0.isEmpty }),
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m)
        else { return nil }
        return (h, m)
    }

    private static func isoDate(_ s: String, calendar: Calendar) -> Date? {
        let withZone = ISO8601DateFormatter()
        if let d = withZone.date(from: s) { return d }
        // No zone written: the wearer's own clock, which is what the model was told the time in.
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    /// A goal from the answer's metric and target, when both are usable and the number is plausible.
    static func goal(metric rawMetric: Any?, target rawTarget: Any?) -> QuestGoal? {
        guard let name = (rawMetric as? String)?.trimmingCharacters(in: .whitespaces).uppercased(),
              let metric = QuestMetric(rawValue: name) else { return nil }
        if metric == .journal { return QuestGoal(metric: .journal, threshold: 1) }

        if metric == .bedtimeBy {
            if let s = rawTarget as? String, let hm = clock(s.trimmingCharacters(in: .whitespaces)) {
                return QuestGoal(metric: metric, threshold: Double(hm.0 * 60 + hm.1))
            }
            // Minutes past midnight, if it wrote a number.
            if let v = number(rawTarget), v >= 0, v < 1440 { return QuestGoal(metric: metric, threshold: v.rounded()) }
            return nil
        }

        guard var v = number(rawTarget), v > 0 else { return nil }
        // Water in litres is the common slip: "2.5" is not two and a half millilitres.
        if metric == .waterMl, v <= 10 { v *= 1000 }
        guard v <= upperBound(metric) else { return nil }
        return QuestGoal(metric: metric, threshold: v)
    }

    /// The most a goal on `metric` may ask for. Past this it is a typo or an invention.
    static func upperBound(_ metric: QuestMetric) -> Double {
        switch metric {
        case .steps: return 100_000
        case .workoutMinutes, .meditationMinutes: return 600
        case .waterMl: return 10_000
        case .strain: return 21
        case .sleepHours: return 16
        case .bedtimeEarlier: return 240
        case .bedtimeBy: return 1439
        case .journal: return 1
        }
    }

    private static func number(_ raw: Any?) -> Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        guard let s = raw as? String else { return nil }
        let digits = s.filter { $0.isNumber || $0 == "." || $0 == "," }
            .replacingOccurrences(of: ",", with: "")
        return Double(digits)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Finding the JSON

    /// The JSON object in a model's answer, wherever it put it.
    ///
    /// Fences, a sentence before it, a reasoning block with braces of its own: every balanced `{…}` is
    /// tried, strings and escapes respected, and the LAST one that parses to an object with a title wins
    /// (a reasoning model thinks first and answers last). Failing that, the last object that parses.
    static func jsonObject(in text: String) -> [String: Any]? {
        let chars = Array(text)
        var best: [String: Any]?
        var withTitle: [String: Any]?
        var i = 0
        while i < chars.count {
            guard chars[i] == "{", let end = balancedEnd(chars, from: i) else { i += 1; continue }
            let slice = String(chars[i...end])
            if let data = slice.data(using: .utf8),
               let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                best = o
                if o["title"] != nil { withTitle = o }
                i = end + 1
            } else {
                i += 1
            }
        }
        return withTitle ?? best
    }

    private static func balancedEnd(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var j = start
        while j < chars.count {
            let c = chars[j]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }
}
