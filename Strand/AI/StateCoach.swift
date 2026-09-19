import Foundation
import StrandAnalytics

// StateCoach.swift — the pure half of Today's STATE tile: what a tap on a recommendation does, the
// "WORKOUTS TODAY" suggestions (the coach's JSON, read defensively, and the deterministic fallback used
// when the coach is not available), the training block the coach is grounded on, and the refresh
// throttle.
//
// NOTHING HERE TOUCHES A STORE OR A NETWORK. The controller (`StateCoachController`) gathers the inputs
// and calls the model; every decision worth testing lives here so `StateCoachTests` can pin it without
// a repository, a strap or a provider key.

// MARK: - Actions

/// What tapping a State recommendation does. Every case is an EXISTING destination — the tile routes into
/// the screens the app already has rather than growing its own copies of them.
enum StateAction: Equatable, Hashable {
    /// The water screen (log a drink).
    case hydration
    /// The breathing / calm session.
    case breathe
    /// The Sleep screen (tonight's plan lives there).
    case sleep
    /// The journal.
    case journal
    /// One metric's detail page, by catalog key.
    case metric(String)
    /// Start a live workout of this sport, optionally with the zone lock set to `zone`.
    case startWorkout(sport: String, zone: Int?)
    /// Open the start-workout picker with nothing preselected.
    case pickWorkout
    /// No in-app action fits: open the detail sheet (rationale + Ask coach).
    case detail
}

/// One tappable line on the State tile.
struct StateRecommendation: Identifiable, Equatable {
    let id: String
    let title: String
    /// Why the coach / the rule is raising it. Shown in the detail sheet and sent with "Ask coach".
    let rationale: String
    let action: StateAction

    /// The question "Ask coach" hands to the chat. Carries the line AND its reason, so the coach answers
    /// about this recommendation instead of starting from nothing.
    var askCoachPrompt: String {
        String(localized: "From my State card: \"\(title)\". \(rationale) What exactly should I do about this today, given my data?")
    }
}

enum StateActionMapper {

    /// The walking sport the step rules start. A catalogue name, never localised (see `WorkoutCatalog`).
    static let walkSport = "Walking"

    static func action(for kind: DayDeficit.Kind) -> StateAction {
        switch kind {
        case .hydration: return .hydration
        // A walk is the step deficit's answer. No zone lock: a brisk walk can sit under Zone 1, and a lock
        // would then buzz "speed up" at someone doing exactly what was asked.
        case .steps: return .startWorkout(sport: walkSport, zone: nil)
        // There is no food log to open; the sheet explains and offers the coach.
        case .protein: return .detail
        case .stress: return .breathe
        case .sleepDebt: return .sleep
        case .training: return .pickWorkout
        }
    }

    /// The mission's action, from the goal line the mission was written with.
    static func action(forGoal goal: QuestGoal?) -> StateAction {
        guard let metric = goal?.metric else { return .detail }
        switch metric {
        case .steps: return .startWorkout(sport: walkSport, zone: nil)
        case .workoutMinutes, .strain: return .pickWorkout
        case .meditationMinutes: return .breathe
        case .waterMl: return .hydration
        case .sleepHours, .bedtimeBy, .bedtimeEarlier: return .sleep
        case .journal: return .journal
        // `default` on purpose: QuestMetric is shared and grows; a new goal kind must fall back to the
        // detail sheet rather than break the build of a screen that never heard of it.
        default: return .detail
        }
    }

    static func rationale(for kind: DayDeficit.Kind) -> String {
        switch kind {
        case .hydration:
            return String(localized: "You are behind today's water goal. Logging a glass now keeps the day on track.")
        case .steps:
            return String(localized: "You are under today's step floor. A 15–20 minute walk closes most of the gap.")
        case .protein:
            return String(localized: "Protein is under about 1.6 g per kg of body mass so far today. A protein-rich meal or snack closes it.")
        case .stress:
            return String(localized: "A long stretch of non-exercise stress today. A few minutes of slow breathing lowers the load.")
        case .sleepDebt:
            return String(localized: "Sleep debt has built up over the last nights. An earlier night tonight is the direct fix.")
        case .training:
            return String(localized: "No counted training session for several days. A session today keeps your fitness moving.")
        }
    }

    static func recommendation(for deficit: DayDeficit) -> StateRecommendation {
        StateRecommendation(id: "deficit-" + deficit.id, title: deficit.text,
                            rationale: rationale(for: deficit.kind), action: action(for: deficit.kind))
    }

    static func recommendation(forMission text: String, goal: QuestGoal?) -> StateRecommendation {
        StateRecommendation(id: "mission", title: String(localized: "Today's mission"),
                            rationale: text, action: action(forGoal: goal))
    }
}

// MARK: - Workout suggestions

/// One further workout for today, as the tile shows it.
struct WorkoutSuggestion: Codable, Equatable, Identifiable {
    /// A `WorkoutCatalog` name when one matches, else the model's own label (free text is valid).
    var sport: String
    var minutes: Int
    /// Target heart-rate zone, 1...5, on the wearer's own (Karvonen) zones.
    var zone: Int
    /// Estimated Effort points (0–100 axis) the session adds to today. nil when not estimated.
    var effort: Double?
    /// Best time window, e.g. "17:00–19:00". Free text from the model; nil when not given.
    var window: String?
    /// One short sentence of why.
    var why: String

    var id: String { "\(sport)|\(minutes)|\(zone)|\(window ?? "")" }

    /// The zone the live workout should LOCK, or nil. Zone 1 is never locked: an easy walk or mobility
    /// block routinely sits under it, and the lock would buzz "speed up" through the whole session.
    var lockZone: Int? { (2...5).contains(zone) ? zone : nil }

    var askCoachPrompt: String {
        let win = window.map { " (\($0))" } ?? ""
        return String(localized: "You suggested this workout for today: \(sport), \(minutes) min in zone \(zone)\(win). Why this one, and how should I pace it given my data today?")
    }
}

/// Reads the coach's workout JSON. Tolerant of everything a chat model does to JSON in practice: code
/// fences, a sentence before or after, a bare array instead of the wrapper object, numbers as strings
/// ("40 min", "Z2"), alternative key names. Returns nil only when nothing usable is in the reply.
enum WorkoutSuggestionParser {

    static let maxCount = 3
    static let minutesRange = 5...180

    static func parse(_ raw: String) -> [WorkoutSuggestion]? {
        if let out = parseStrict(raw) { return out }
        // Second chance: typographic quotes, which some models emit for every quote in the object. Done
        // only after the plain read failed, because inside a valid "why" string they are just text.
        let normalised = raw
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        return normalised == raw ? nil : parseStrict(normalised)
    }

    private static func parseStrict(_ raw: String) -> [WorkoutSuggestion]? {
        guard let json = extractJSON(raw), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        let items: [Any]
        if let arr = obj as? [Any] {
            items = arr
        } else if let dict = obj as? [String: Any] {
            if let arr = (dict["workouts"] ?? dict["suggestions"] ?? dict["items"]) as? [Any] {
                items = arr
            } else {
                items = [dict]   // one bare suggestion object
            }
        } else {
            return nil
        }
        var out: [WorkoutSuggestion] = []
        for case let d as [String: Any] in items {
            guard let s = suggestion(from: d) else { continue }
            // The same sport at the same zone twice is one suggestion, not two.
            if out.contains(where: { $0.sport.caseInsensitiveCompare(s.sport) == .orderedSame && $0.zone == s.zone }) {
                continue
            }
            out.append(s)
            if out.count == maxCount { break }
        }
        return out.isEmpty ? nil : out
    }

    /// The first balanced JSON object or array in `raw`, string-aware so a brace inside a "why" does not
    /// end it early. nil when there is none.
    static func extractJSON(_ raw: String) -> String? {
        let chars = Array(raw)
        guard let start = chars.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]":
                depth -= 1
                if depth == 0 { return String(chars[start...i]) }
            default: break
            }
        }
        return nil
    }

    static func suggestion(from d: [String: Any]) -> WorkoutSuggestion? {
        guard let rawSport = string(d["sport"] ?? d["activity"] ?? d["type"]) else { return nil }
        let sport = canonicalSport(rawSport)
        guard !sport.isEmpty else { return nil }
        // Clamped BEFORE the Int conversion: Int(_:) traps on a huge or non-finite Double.
        let minutes = number(d["minutes"] ?? d["duration_min"] ?? d["duration"])
            .map { Int(Swift.min(Swift.max($0, 0), 1_000).rounded()) } ?? 30
        let zone = zoneNumber(d["zone"] ?? d["target_zone"] ?? d["hr_zone"]) ?? 2
        let effort = number(d["effort"] ?? d["effort_gain"] ?? d["effort_points"])
        let window = string(d["window"] ?? d["time"] ?? d["best_time"])
        let why = string(d["why"] ?? d["reason"] ?? d["rationale"]) ?? ""
        return WorkoutSuggestion(
            sport: String(sport.prefix(40)),
            minutes: Swift.min(Swift.max(minutes, minutesRange.lowerBound), minutesRange.upperBound),
            zone: Swift.min(Swift.max(zone, 1), 5),
            effort: effort.map { Swift.min(Swift.max($0, 0), 100) },
            window: window.map { String($0.prefix(32)) },
            why: String(why.prefix(220)))
    }

    /// The catalogue's own spelling when the label matches one (case-insensitively, or through a short
    /// alias list for the words models reach for), else the label as given.
    static func canonicalSport(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hit = WorkoutCatalog.sport(named: trimmed) { return hit.name }
        let aliases: [String: String] = [
            "run": "Running", "jog": "Running", "jogging": "Running",
            "walk": "Walking", "brisk walk": "Walking", "recovery walk": "Walking",
            "bike": "Cycling", "ride": "Cycling", "cycle": "Cycling", "bike ride": "Cycling",
            "swim": "Pool swim", "swimming": "Pool swim",
            "mobility": "Stretching", "stretch": "Stretching",
            "intervals": "HIIT", "interval training": "HIIT",
            "strength training": "Strength", "weights": "Weightlifting",
            "row": "Rowing", "hike": "Hiking",
        ]
        return aliases[trimmed.lowercased()] ?? trimmed
    }

    static func string(_ v: Any?) -> String? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// A number, or the FIRST number in a string ("40 min" → 40, "30-45" → 30).
    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        guard let s = v as? String else { return nil }
        var buf = ""
        for ch in s {
            if ch.isASCII && ch.isNumber {
                buf.append(ch)
            } else if ch == "." && !buf.isEmpty && !buf.contains(".") {
                buf.append(ch)
            } else if !buf.isEmpty {
                break
            }
        }
        if buf.hasSuffix(".") { buf.removeLast() }
        return Double(buf)
    }

    /// 1...5 from 2, "2", "Z2", "zone 2", "Z1-Z2" (the first zone named). nil otherwise.
    static func zoneNumber(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite, d >= 0.5, d < 5.5 else { return nil }
            return Int(d.rounded())
        }
        guard let s = v as? String else { return nil }
        for ch in s {
            if let digit = Int(String(ch)), (1...5).contains(digit) { return digit }
        }
        return nil
    }
}

// MARK: - Inputs

/// Today's figures the tile already shows, handed to the suggestions. All optional: nil is unmeasured.
struct StateTrainingFigures: Equatable {
    /// Charge / recovery, 0–100.
    var charge: Double?
    /// Today's Effort so far, 0–100.
    var effortNow: Double?
    /// The top of today's recommended Effort band, 0–100 — the SAME target mark the Effort ring shows.
    var effortTarget: Double?
    var sleepDebtMin: Double?
    /// The day's stress score, 0–3.
    var stress: Double?
    /// Last night's HRV against its 30-day median, in percent (+ is better).
    var hrvDeltaPct: Double?
    /// Last night's resting HR against its 30-day median, in bpm (+ is worse).
    var rhrDeltaBpm: Double?

    /// Effort still to go to today's target, or nil when either end is unknown.
    var remainingEffort: Double? {
        guard let target = effortTarget else { return nil }
        return Swift.max(0, target - (effortNow ?? 0))
    }
}

/// One workout, reduced to what the suggestions and the coach block read.
struct StateWorkoutFact: Equatable {
    let sport: String
    let start: Date
    let end: Date
    let durationMin: Double?
    let avgHr: Int?
    let maxHr: Int?
    /// Effort, 0–100.
    let effort: Double?
    /// Minutes in zones 1...5 (index 0 = Zone 1), nil when the window carries no heart rate.
    var zoneMinutes: [Double]?

    /// A session that took real intensity: ten minutes or more in zones 4–5, or an Effort of 60+.
    var isHard: Bool {
        let hi = zoneMinutes.map { $0.count >= 5 ? $0[3] + $0[4] : 0 } ?? 0
        return hi >= 10 || (effort ?? 0) >= 60
    }
}

// MARK: - Deterministic fallback

/// The suggestions when the coach is unavailable (no provider, no consent, a failed or unreadable reply).
/// Deliberately plain rules on the figures the tile already holds, so the section is never empty and
/// never guesses: low charge or a strained body → Zone 1–2 recovery; plenty of charge and a lot of target
/// left → Zone 2 endurance plus intervals; target reached → only an easy walk / mobility.
enum WorkoutSuggestionFallback {

    /// Rough Effort points per minute in each zone (0–100 axis). An ESTIMATE for sizing a session and for
    /// the "≈ +N" hint, not a score: the real Effort is measured from the heart rate afterwards.
    static func effortPerMinute(zone: Int) -> Double {
        let table = [0.15, 0.35, 0.6, 0.9, 1.2]
        return table[Swift.min(Swift.max(zone, 1), 5) - 1]
    }

    /// Minutes needed for `effort` points in `zone`, rounded to 5, clamped to `range`.
    static func minutes(for effort: Double, zone: Int, range: ClosedRange<Int>) -> Int {
        let raw = effort / effortPerMinute(zone: zone)
        let rounded = Int((raw / 5).rounded()) * 5
        return Swift.min(Swift.max(rounded, range.lowerBound), range.upperBound)
    }

    /// "HH:00–HH:00" starting at the next whole hour, but no earlier than `preferredStart`. Never past 22:00.
    static func window(hour: Int, preferredStart: Int, length: Int = 2) -> String {
        let start = Swift.min(Swift.max(hour + 1, preferredStart), 21)
        let end = Swift.min(start + length, 22)
        return String(format: "%02d:00–%02d:00", start, end)
    }

    /// Sports the fallback treats as the wearer's endurance choice when they are the most frequent.
    private static let notEndurance: Set<String> = [
        "other", "walking", "strength", "weightlifting", "bodybuilding", "powerlifting", "yoga", "pilates",
        "stretching", "meditation", "gaming", "golf", "bowling", "calisthenics",
    ]

    /// The wearer's own most frequent endurance sport over `recent`, else Running.
    static func preferredEnduranceSport(recent: [StateWorkoutFact]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for w in recent {
            guard let hit = WorkoutCatalog.sport(named: w.sport),
                  !notEndurance.contains(hit.name.lowercased()),
                  !WorkoutCatalog.isRecovery(hit.name) else { continue }
            if counts[hit.name] == nil { order.append(hit.name) }
            counts[hit.name, default: 0] += 1
        }
        // Ties go to the most recent (recent is newest first, so `order` is too).
        guard let best = counts.values.max() else { return "Running" }
        return order.first { counts[$0] == best } ?? "Running"
    }

    static func suggest(figures: StateTrainingFigures,
                        hour: Int,
                        today: [StateWorkoutFact],
                        recent: [StateWorkoutFact],
                        now: Date = Date()) -> [WorkoutSuggestion] {
        // LATE: only something that does not keep you up.
        if hour >= 21 {
            return [WorkoutSuggestion(
                sport: "Stretching", minutes: 10, zone: 1, effort: 1, window: nil,
                why: String(localized: "It's late: gentle mobility helps you wind down without adding load before sleep."))]
        }

        let remaining = figures.remainingEffort
        let charge = figures.charge
        let walkWindow = window(hour: hour, preferredStart: hour + 1)

        // TARGET REACHED: nothing that adds meaningful load.
        if let remaining, remaining <= 3 {
            return [
                WorkoutSuggestion(sport: "Walking", minutes: 20, zone: 1, effort: 3, window: walkWindow,
                                  why: String(localized: "Today's Effort target is reached. An easy walk aids recovery without adding real load.")),
                WorkoutSuggestion(sport: "Stretching", minutes: 15, zone: 1, effort: 2,
                                  window: window(hour: hour, preferredStart: 19),
                                  why: String(localized: "Mobility work loosens you up after today's load.")),
            ]
        }

        // LOW CHARGE OR A STRAINED BODY: recovery only.
        let lowCharge = (charge ?? 50) < 34
        let strained = (figures.sleepDebtMin ?? 0) >= 120
            || (figures.hrvDeltaPct ?? 0) <= -15
            || (figures.rhrDeltaBpm ?? 0) >= 5
            || (figures.stress ?? 0) >= 2.5
        if lowCharge || strained {
            let why = lowCharge
                ? String(localized: "Charge is low today: keep it in Zone 1 so recovery keeps going.")
                : String(localized: "Your body shows strain (sleep debt, HRV, resting HR or stress): easy movement only.")
            return [
                WorkoutSuggestion(sport: "Walking", minutes: 30, zone: 1, effort: 5, window: walkWindow, why: why),
                WorkoutSuggestion(sport: "Yoga", minutes: 20, zone: 1, effort: 3,
                                  window: window(hour: hour, preferredStart: 18),
                                  why: String(localized: "Calm mobility supports recovery and lowers stress.")),
            ]
        }

        let endurance = preferredEnduranceSport(recent: recent)
        let rem = remaining ?? 25
        let hardToday = today.contains { $0.isHard }
        // Yesterday's (or earlier today's) intensity counts: two interval days in a row is the classic mistake.
        let hardRecently = hardToday || recent.prefix(3).contains { w in
            w.isHard && now.timeIntervalSince(w.start) < 36 * 3600
        }
        var out: [WorkoutSuggestion] = []

        if (charge ?? 0) >= 67 && !hardRecently && rem >= 20 {
            let intervalMin = minutes(for: rem * 0.6, zone: 4, range: 20...45)
            out.append(WorkoutSuggestion(
                sport: endurance, minutes: intervalMin, zone: 4,
                effort: Swift.min(rem, Double(intervalMin) * effortPerMinute(zone: 4)).rounded(),
                window: window(hour: hour, preferredStart: 16),
                why: String(localized: "High charge and plenty of target left: intervals, e.g. 5 × 3 min in Zone 4 with easy recoveries.")))
            let z2 = minutes(for: rem, zone: 2, range: 30...75)
            out.append(WorkoutSuggestion(
                sport: endurance, minutes: z2, zone: 2,
                effort: Swift.min(rem, Double(z2) * effortPerMinute(zone: 2)).rounded(),
                window: window(hour: hour, preferredStart: 11),
                why: String(localized: "Or steady Zone 2 endurance: builds base with little recovery cost.")))
        } else {
            let z2 = minutes(for: rem, zone: 2, range: 20...60)
            out.append(WorkoutSuggestion(
                sport: endurance, minutes: z2, zone: 2,
                effort: Swift.min(rem, Double(z2) * effortPerMinute(zone: 2)).rounded(),
                window: window(hour: hour, preferredStart: 11),
                why: hardRecently
                    ? String(localized: "You already went hard recently: keep today aerobic in Zone 2.")
                    : String(localized: "Zone 2 endurance closes the gap to today's target at a sustainable cost.")))
        }
        out.append(WorkoutSuggestion(
            sport: "Walking", minutes: 25, zone: 1, effort: 4, window: walkWindow,
            why: String(localized: "An easy walk adds steps and aids recovery between sessions.")))
        return Array(out.prefix(WorkoutSuggestionParser.maxCount))
    }
}

// MARK: - The coach's grounding for the suggestions

enum StateTrainingContext {

    /// Latest value against the median of the ones before it (up to 30), when there are at least five.
    /// Input oldest → newest.
    static func latestVsBaseline(_ values: [Double]) -> (latest: Double, baseline: Double)? {
        guard values.count >= 5, let latest = values.last else { return nil }
        let prior = Array(values.dropLast().suffix(30)).sorted()
        guard !prior.isEmpty else { return nil }
        let n = prior.count
        let median = n % 2 == 1 ? prior[n / 2] : (prior[n / 2 - 1] + prior[n / 2]) / 2
        return (latest, median)
    }

    private static func clock(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func dayKey(_ d: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func line(_ w: StateWorkoutFact, withDate: Bool, _ cal: Calendar) -> String {
        var parts: [String] = []
        parts.append((withDate ? dayKey(w.start, cal) + " " : "") + clock(w.start, cal) + "–" + clock(w.end, cal)
                     + " " + w.sport)
        if let m = w.durationMin { parts.append("\(Int(m.rounded())) min") }
        if let hr = w.avgHr { parts.append("avg HR \(hr)") }
        if let hr = w.maxHr { parts.append("max HR \(hr)") }
        if let e = w.effort { parts.append("effort \(Int(e.rounded()))") }
        if let z = w.zoneMinutes, z.count >= 5 {
            let zs = (0..<5).map { "Z\($0 + 1) \(Int(z[$0].rounded()))m" }.joined(separator: " ")
            parts.append("zones " + zs)
        }
        return "  " + parts.joined(separator: ", ")
    }

    /// The block appended to the coach's full context for the State refresh: today's training state in
    /// the terms the suggestions are asked in. Weather, weekday and time already ride the system prompt
    /// (`AICoachEngine.requestSystemPrompt`), so they are not repeated here.
    static func block(figures: StateTrainingFigures,
                      zones: [HRZoneBPMRange],
                      today: [StateWorkoutFact],
                      recent: [StateWorkoutFact],
                      calendar: Calendar = .current) -> String {
        func n(_ v: Double?, _ fmt: String = "%.0f") -> String { v.map { String(format: fmt, $0) } ?? "—" }
        var s: [String] = ["TODAY'S TRAINING STATE (use this for the workout suggestions; Effort is NOOP's 0-100 scale):"]
        var effortLine = "Effort so far today: \(n(figures.effortNow)); today's recommended target (top of the band): \(n(figures.effortTarget))"
        if let r = figures.remainingEffort { effortLine += "; remaining to target: \(n(r))" }
        s.append(effortLine + ".")
        s.append("Charge: \(n(figures.charge)). Sleep debt: \(n(figures.sleepDebtMin.map { $0 / 60 }, "%.1f")) h. "
                 + "Stress score today: \(n(figures.stress, "%.1f")) of 3.")
        if let h = figures.hrvDeltaPct {
            s.append("HRV last night vs 30-day median: \(String(format: "%+.0f", h))%.")
        }
        if let r = figures.rhrDeltaBpm {
            s.append("Resting HR last night vs 30-day median: \(String(format: "%+.0f", r)) bpm.")
        }
        if !zones.isEmpty {
            s.append("The user's heart-rate zones (Karvonen, bpm): "
                     + zones.map { "Z\($0.zone) \($0.lower)-\($0.upper)" }.joined(separator: ", ") + ".")
        }
        if today.isEmpty {
            s.append("Workouts today: none yet.")
        } else {
            s.append("Workouts today (oldest first):")
            for w in today.sorted(by: { $0.start < $1.start }) { s.append(line(w, withDate: false, calendar)) }
        }
        if recent.isEmpty {
            s.append("Workouts in the previous 14 days: none recorded.")
        } else {
            s.append("Workouts in the previous 14 days (newest first):")
            for w in recent.prefix(20) { s.append(line(w, withDate: true, calendar)) }
            let hard = recent.filter(\.isHard)
            if let last = hard.first {
                s.append("Most recent hard session (>=10 min in Z4-5 or effort >= 60): \(dayKey(last.start, calendar)).")
            }
        }
        return s.joined(separator: "\n")
    }
}

/// The framing the workout suggestions are asked under.
enum WorkoutSuggestionWriter {

    static func systemPrompt(grounding: String) -> String {
        var s = "You are the user's training coach. Suggest 1 to 3 FURTHER workouts for the REST OF TODAY, "
        s += "chosen from their data: what they already did today, the last two weeks of training and its "
        s += "effort, today's Effort against the recommended target, charge, sleep debt, HRV and resting HR "
        s += "against baseline, stress, the time of day and the weather. Rules: never prescribe hard work on "
        s += "low charge or a strained body; if the target is already reached suggest only easy Zone 1 "
        s += "movement or mobility; do not repeat a hard session the day after one; time windows must lie "
        s += "later today than now. Prefer sports the user actually does.\n\n"
        s += "Answer with JSON ONLY, no prose and no code fence, exactly in this shape:\n"
        s += #"{"workouts":[{"sport":"Running","minutes":40,"zone":2,"effort":12,"window":"17:00-18:00","why":"one short sentence"}]}"#
        s += "\n"
        s += "sport: a plain sport name (Running, Walking, Cycling, Strength, Yoga, HIIT, Rowing, Stretching, ...). "
        s += "zone: the target heart-rate zone 1-5 on the user's zones listed below. "
        s += "effort: estimated Effort points (0-100 scale) the session adds today. "
        s += "why: one short sentence in the user's language.\n\n"
        s += grounding
        return s
    }

    static let question = "Suggest today's further workouts as JSON."
}

// MARK: - Cache

/// The coach's suggestions for one day, keyed by what they were generated from.
struct StoredWorkoutSuggestions: Codable, Equatable {
    let dayKey: String
    /// Changes when today's workouts change, so a finished session gets fresh suggestions once.
    let fingerprint: String
    let createdAt: Date
    let items: [WorkoutSuggestion]
}

enum WorkoutSuggestionStore {
    static let key = "state.workoutSuggestions"

    static func read(_ d: UserDefaults = .standard) -> StoredWorkoutSuggestions? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredWorkoutSuggestions.self, from: data)
    }

    static func write(_ v: StoredWorkoutSuggestions, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        d.set(data, forKey: key)
    }

    /// The stored suggestions when they are for `dayKey` and `fingerprint`, else nil.
    static func current(dayKey: String, fingerprint: String, _ d: UserDefaults = .standard) -> StoredWorkoutSuggestions? {
        guard let s = read(d), s.dayKey == dayKey, s.fingerprint == fingerprint else { return nil }
        return s
    }

    /// The fingerprint of today's workouts: how many, and when the latest started.
    static func fingerprint(today: [StateWorkoutFact]) -> String {
        let latest = today.map { Int($0.start.timeIntervalSince1970) }.max() ?? 0
        return "\(today.count)|\(latest)"
    }
}

// MARK: - Throttle

/// A minimum gap between manual refreshes, so a thumb hammering the button costs one request.
struct RefreshThrottle: Equatable {
    let minInterval: TimeInterval
    private(set) var lastStart: Date?

    init(minInterval: TimeInterval, lastStart: Date? = nil) {
        self.minInterval = minInterval
        self.lastStart = lastStart
    }

    /// Seconds until the next refresh is allowed; 0 when it is allowed now. A clock that moved BACKWARDS
    /// past the last start (timezone / manual change) allows it rather than locking the button for hours.
    func remaining(at now: Date) -> TimeInterval {
        guard let last = lastStart, now >= last else { return 0 }
        return Swift.max(0, minInterval - now.timeIntervalSince(last))
    }

    func allows(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// Claim a refresh at `now`. False (and nothing recorded) while throttled.
    mutating func tryStart(at now: Date) -> Bool {
        guard allows(at: now) else { return false }
        lastStart = now
        return true
    }
}
