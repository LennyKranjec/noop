import Foundation

// QuestGoal.swift — what a quest can be checked against.
//
// A quest used to be finished by the wearer saying so: a "mark it done" button, and the XP on trust.
// That is the one part of the system that did not read the body. A directive that says "8,000 steps"
// and then asks whether you did them is asking a question the phone already knows the answer to — and
// asking it invites the answer that is easiest rather than the one that is true.
//
// SO A QUEST CARRIES A GOAL: one measured quantity, one threshold, checked against the day's own data,
// and the quest closes itself the moment the data says it is done.
//
// ONE METRIC, NOT A RULE LANGUAGE. Every directive the system issues is one of a handful of things a
// wearable or the app itself measures. A general expression format would let a language model write
// goals nothing can evaluate, which is the exact failure this replaces.
//
// A GOAL THE DATA CANNOT SEE IS NOT MET. No step count recorded is not zero steps and it is not eight
// thousand either: an unmeasured goal simply stays open, and the quest runs out on its own clock.

/// The quantities a quest can be checked against.
public enum QuestMetric: String, Equatable, Codable, CaseIterable, Sendable {
    /// Steps on the quest's day, at least `threshold`.
    case steps = "STEPS"
    /// Minutes of logged workouts on the quest's day, at least `threshold`.
    case workoutMinutes = "WORKOUT_MIN"
    /// Minutes of meditation or slow breathing on the quest's day, at least `threshold`.
    case meditationMinutes = "MEDITATION_MIN"
    /// Millilitres of water on the quest's day, at least `threshold`.
    case waterMl = "WATER_ML"
    /// WHOOP day strain (0–21) on the quest's day, at least `threshold`.
    case strain = "STRAIN"
    /// Hours of sleep in the NIGHT AFTER the quest's day, at least `threshold`.
    case sleepHours = "SLEEP_H"
    /// Asleep by `threshold` (minutes past midnight) in the night after the quest's day.
    case bedtimeBy = "BEDTIME_BY"
    /// Asleep at least `threshold` minutes earlier than the night before.
    case bedtimeEarlier = "BEDTIME_EARLIER"
    /// Anything written in the journal on the quest's day. `threshold` is ignored.
    case journal = "JOURNAL"

    /// Whether the evidence for this goal only exists the morning AFTER the quest's day.
    ///
    /// A bedtime is checked against a night that has not happened yet when the quest is issued, so its
    /// deadline is extended to the following morning — or every sleep quest would expire at the very
    /// moment it became checkable.
    public var resolvesNextMorning: Bool {
        switch self {
        case .sleepHours, .bedtimeBy, .bedtimeEarlier: return true
        default: return false
        }
    }
}

/// One measured target.
public struct QuestGoal: Equatable, Sendable {
    public let metric: QuestMetric
    public let threshold: Double

    public init(metric: QuestMetric, threshold: Double) {
        self.metric = metric
        self.threshold = threshold
    }
}

/// What the data says about the quest's day, for every metric a goal can name.
///
/// All optional: nil is "not measured", and an unmeasured goal is never met.
public struct QuestEvidence: Equatable, Sendable {
    public var steps: Double?
    public var workoutMinutes: Double?
    public var meditationMinutes: Double?
    public var waterMl: Double?
    public var strain: Double?
    public var journaled: Bool?
    /// The night AFTER the quest's day.
    public var nextSleepHours: Double?
    public var nextSleepOnsetMinute: Int?
    /// The night that ENDED on the quest's day — "last night" to the quest.
    public var previousSleepOnsetMinute: Int?

    public init(
        steps: Double? = nil,
        workoutMinutes: Double? = nil,
        meditationMinutes: Double? = nil,
        waterMl: Double? = nil,
        strain: Double? = nil,
        journaled: Bool? = nil,
        nextSleepHours: Double? = nil,
        nextSleepOnsetMinute: Int? = nil,
        previousSleepOnsetMinute: Int? = nil
    ) {
        self.steps = steps
        self.workoutMinutes = workoutMinutes
        self.meditationMinutes = meditationMinutes
        self.waterMl = waterMl
        self.strain = strain
        self.journaled = journaled
        self.nextSleepHours = nextSleepHours
        self.nextSleepOnsetMinute = nextSleepOnsetMinute
        self.previousSleepOnsetMinute = previousSleepOnsetMinute
    }
}

extension QuestGoal {

    /// Whether the evidence meets the goal. False — never nil — when the evidence is missing.
    public func isMet(by e: QuestEvidence) -> Bool {
        switch metric {
        case .steps: return (e.steps ?? -1) >= threshold
        case .workoutMinutes: return (e.workoutMinutes ?? -1) >= threshold
        case .meditationMinutes: return (e.meditationMinutes ?? -1) >= threshold
        case .waterMl: return (e.waterMl ?? -1) >= threshold
        case .strain: return (e.strain ?? -1) >= threshold
        case .sleepHours: return (e.nextSleepHours ?? -1) >= threshold
        case .journal: return e.journaled == true
        case .bedtimeBy:
            guard let onset = e.nextSleepOnsetMinute else { return false }
            return Self.minutesPast(onset, deadline: Int(threshold)) <= 0
        case .bedtimeEarlier:
            guard let tonight = e.nextSleepOnsetMinute, let before = e.previousSleepOnsetMinute else {
                return false
            }
            // Signed, on the evening clock: how much EARLIER tonight was than last night.
            return Double(-Self.minutesPast(tonight, deadline: before)) >= threshold
        }
    }

    /// A short statement of what was measured against what was asked, for the completion card.
    ///
    /// Written from the same evidence `isMet` used, so the card can never describe a different number
    /// from the one that closed the quest.
    public func summary(_ e: QuestEvidence) -> String {
        func n(_ v: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = v < 100 ? 1 : 0
            return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
        }
        func clock(_ m: Int) -> String {
            let w = ((m % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", w / 60, w % 60)
        }
        switch metric {
        case .steps:
            return "\(n(e.steps ?? 0)) steps against the \(n(threshold)) asked for."
        case .workoutMinutes:
            return "\(n(e.workoutMinutes ?? 0)) minutes of training logged against \(n(threshold))."
        case .meditationMinutes:
            return "\(n(e.meditationMinutes ?? 0)) minutes of meditation against \(n(threshold))."
        case .waterMl:
            return "\(n((e.waterMl ?? 0) / 1000)) L of water against \(n(threshold / 1000)) L."
        case .strain:
            return "A day strain of \(n(e.strain ?? 0)) against \(n(threshold))."
        case .sleepHours:
            return "\(n(e.nextSleepHours ?? 0)) hours asleep against \(n(threshold))."
        case .bedtimeBy:
            return "Asleep at \(e.nextSleepOnsetMinute.map(clock) ?? "—"), inside the \(clock(Int(threshold))) deadline."
        case .bedtimeEarlier:
            return "Asleep at \(e.nextSleepOnsetMinute.map(clock) ?? "—"), "
                + "\(n(threshold)) minutes or more ahead of the night before."
        case .journal:
            return "An entry in the journal, as asked."
        }
    }

    /// Minutes by which `onset` is later than `deadline` on the EVENING clock — negative when earlier.
    ///
    /// Bedtimes straddle midnight, so the comparison is anchored at NOON rather than midnight: 00:30 is
    /// thirty minutes after 00:00 and ninety after 23:00, not twenty-two and a half hours before it.
    static func minutesPast(_ onset: Int, deadline: Int) -> Int {
        func evening(_ m: Int) -> Int {
            let w = ((m % 1440) + 1440) % 1440
            return w < 12 * 60 ? w + 1440 : w
        }
        return evening(onset) - evening(deadline)
    }
}

// MARK: - Reading a goal out of a sentence

extension QuestGoal {

    /// The goal a directive states, when it states exactly one the app can measure.
    ///
    /// For the daily quest, whose directive a model wrote. It is asked to state its goal on a line of
    /// its own (see `parseLine`); this is the fallback for when it wrote the number into the sentence
    /// instead, and for quests stored before goals existed. English and German, because the wearer
    /// writes goals in both.
    ///
    /// Ordered from the most specific pattern to the most general, so "10 minutes of meditation" is
    /// meditation and not a workout, and "bed by 22:30" is a bedtime and not a strain of 22.
    public static func parse(_ text: String) -> QuestGoal? {
        let t = text.lowercased()

        if let m = match(#"(?:bed|lights out|asleep|schlafen|ins bett|licht aus)[^0-9]{0,24}(\d{1,2})[:.](\d{2})"#, t),
           let h = Int(m[0]), let mm = Int(m[1]), h < 24, mm < 60 {
            return QuestGoal(metric: .bedtimeBy, threshold: Double(h * 60 + mm))
        }
        if let m = match(#"(\d{1,3})\s*(?:min|minutes|minuten)[^.]{0,20}(?:earlier|früher)"#, t),
           let v = Double(m[0]) {
            return QuestGoal(metric: .bedtimeEarlier, threshold: v)
        }
        if let m = match(#"(\d{1,2}(?:[.,]\d)?)\s*(?:h|hours|hrs|stunden)\b[^.]{0,12}(?:sleep|schlaf)"#, t),
           let v = number(m[0]) {
            return QuestGoal(metric: .sleepHours, threshold: v)
        }
        if let m = match(#"(\d{1,3})\s*(?:min|minutes|minuten)[^.]{0,30}(?:meditat|breath|breathing|atem|atmung)"#, t),
           let v = Double(m[0]) {
            return QuestGoal(metric: .meditationMinutes, threshold: v)
        }
        if let m = match(#"(\d{1,3}(?:[.,]\d{3})+|\d+(?:[.,]\d)?\s*k|\d{3,6})\s*(?:steps|schritte)"#, t),
           let v = steps(m[0]) {
            return QuestGoal(metric: .steps, threshold: v)
        }
        if let m = match(#"(\d{3,4})\s*ml"#, t), let v = Double(m[0]) {
            return QuestGoal(metric: .waterMl, threshold: v)
        }
        if let m = match(#"(\d(?:[.,]\d{1,2})?)\s*(?:l|liter|litre|liters|litres)\b"#, t), let v = number(m[0]) {
            return QuestGoal(metric: .waterMl, threshold: v * 1000)
        }
        if let m = match(#"strain[^0-9]{0,16}(\d{1,2}(?:[.,]\d)?)"#, t), let v = number(m[0]), v <= 21 {
            return QuestGoal(metric: .strain, threshold: v)
        }
        if let m = match(#"(\d{1,3})\s*(?:-\s*)?(?:min|minutes|minuten|minute)\b"#, t), let v = Double(m[0]) {
            return QuestGoal(metric: .workoutMinutes, threshold: v)
        }
        if t.contains("journal") || t.contains("tagebuch") {
            return QuestGoal(metric: .journal, threshold: 1)
        }
        return nil
    }

    /// A goal stated on its own line: `GOAL: STEPS 9000`, `GOAL: BEDTIME_BY 22:30`, `GOAL: JOURNAL`.
    ///
    /// The format the daily mission is asked to end with, because a named metric and a bare number is
    /// something a model gets right far more reliably than a sentence a parser has to interpret.
    public static func parseLine(_ line: String) -> QuestGoal? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_` "))
        guard trimmed.uppercased().hasPrefix("GOAL") else { return nil }
        let body = trimmed.dropFirst(4).drop { $0 == ":" || $0 == " " }
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        guard let first = parts.first, let metric = QuestMetric(rawValue: first.uppercased()) else {
            return nil
        }
        if metric == .journal { return QuestGoal(metric: .journal, threshold: 1) }
        guard parts.count == 2 else { return nil }
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        if metric == .bedtimeBy {
            let hm = value.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
            guard hm.count == 2, hm[0] < 24, hm[1] < 60 else { return nil }
            return QuestGoal(metric: metric, threshold: Double(hm[0] * 60 + hm[1]))
        }
        guard let v = number(value.filter { !$0.isWhitespace && $0 != "," }), v > 0 else { return nil }
        return QuestGoal(metric: metric, threshold: v)
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    private static func number(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    /// "8,000" / "8.000" / "8k" / "8.5k" / "9000" as a step count.
    private static func steps(_ raw: String) -> Double? {
        let s = raw.replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("k") {
            return number(String(s.dropLast())).map { $0 * 1000 }
        }
        return Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: ""))
    }
}
