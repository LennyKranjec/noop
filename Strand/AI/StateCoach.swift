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
    /// A recovery variant the catalogue has no sport for ("NSDR", "Restorative yoga", "Breathwork" — a
    /// `StateWorkoutChoices.variants` key). `sport` then holds the activity it is RECORDED as (Meditation /
    /// Yoga), so a tap starts that activity. nil for a plain sport. Optional so stored lists still decode.
    var label: String? = nil
    /// The wearer asked for this one themselves, through the "+" in the section header. It is pinned for
    /// the rest of the day, marked "by you", and the allowed-workouts selection does not apply to it —
    /// an explicitly requested session is always allowed.
    var byUser: Bool = false

    var id: String { "\(sport)|\(minutes)|\(zone)|\(window ?? "")|\(label ?? "")" }

    /// The zone the live workout should LOCK, or nil. Zone 1 is never locked: an easy walk or mobility
    /// block routinely sits under it, and the lock would buzz "speed up" through the whole session.
    var lockZone: Int? { (2...5).contains(zone) ? zone : nil }

    /// The key this suggestion is allowed / excluded under in the wearer's workout selection.
    var choiceKey: String { StateWorkoutChoices.key(for: self) }

    /// A down-regulation session (meditation, breathwork, NSDR, restorative yoga, stretching …) rather
    /// than training load.
    var isRecovery: Bool { label != nil || WorkoutCatalog.isRecovery(sport) }

    var askCoachPrompt: String {
        let win = window.map { " (\($0))" } ?? ""
        let name = label ?? sport
        return String(localized: "You suggested this workout for today: \(name), \(minutes) min in zone \(zone)\(win). Why this one, and how should I pace it given my data today?")
    }
}

extension WorkoutSuggestion {

    private enum CodingKeys: String, CodingKey {
        case sport, minutes, zone, effort, window, why, label, byUser
    }

    /// Hand-written, and in an extension so the memberwise init survives: a list stored before `byUser`
    /// existed must still decode. The synthesised reader would throw on the missing key and take the
    /// whole day's cached suggestions down with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sport = try c.decode(String.self, forKey: .sport)
        minutes = try c.decode(Int.self, forKey: .minutes)
        zone = try c.decode(Int.self, forKey: .zone)
        effort = try c.decodeIfPresent(Double.self, forKey: .effort)
        window = try c.decodeIfPresent(String.self, forKey: .window)
        why = try c.decode(String.self, forKey: .why)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        byUser = try c.decodeIfPresent(Bool.self, forKey: .byUser) ?? false
    }

    /// Written out by hand as well, so the two sides cannot drift apart from each other.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sport, forKey: .sport)
        try c.encode(minutes, forKey: .minutes)
        try c.encode(zone, forKey: .zone)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(window, forKey: .window)
        try c.encode(why, forKey: .why)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(byUser, forKey: .byUser)
    }
}

// MARK: - The wearer's workout selection

/// Which workouts the STATE tile may suggest. Stored as the set the wearer UNTICKED, so the default is
/// "everything" and a sport added to the catalogue later starts out allowed.
///
/// Keys are `WorkoutCatalog` names, plus three recovery VARIANTS the catalogue has no sport for. Each
/// variant is recorded as an existing activity — NSDR / yoga nidra and breathwork as a Meditation session
/// (a guided lie-down or a breathing practice is exactly what that activity measures: heart rate settling
/// at rest), restorative yoga as Yoga — so starting one is the same recording as the meditation card's
/// play button, and nothing new is written into the cross-platform sport column.
struct StateWorkoutChoices: Equatable {

    struct Option: Identifiable, Hashable {
        /// The selection / prompt key.
        let key: String
        /// The catalogue sport a session of it is recorded as.
        let sport: String
        var id: String { key }
        var isVariant: Bool { key != sport }
    }

    /// Keys the wearer unticked.
    var excluded: Set<String>

    init(excluded: Set<String> = []) { self.excluded = excluded }

    static let all = StateWorkoutChoices()

    static let breathworkKey = "Breathwork"
    static let nsdrKey = "NSDR"
    static let restorativeYogaKey = "Restorative yoga"

    static let variants: [Option] = [
        Option(key: breathworkKey, sport: "Meditation"),
        Option(key: nsdrKey, sport: "Meditation"),
        Option(key: restorativeYogaKey, sport: "Yoga"),
    ]

    /// The recovery & calm group, shown first in the settings list.
    static let recoveryKeys = ["Meditation", StateWorkoutChoices.breathworkKey, StateWorkoutChoices.nsdrKey, "Yoga",
                               StateWorkoutChoices.restorativeYogaKey, "Stretching", "Walking"]

    /// Catalogue entries that are not a suggestion (the generic bucket).
    private static let hiddenSports: Set<String> = ["Other"]

    static let recoveryOptions: [Option] = StateWorkoutChoices.recoveryKeys.map { key in
        StateWorkoutChoices.variants.first { $0.key == key } ?? Option(key: key, sport: key)
    }

    static let sportOptions: [Option] = WorkoutCatalog.all.map(\.name)
        .filter { !StateWorkoutChoices.recoveryKeys.contains($0) && !StateWorkoutChoices.hiddenSports.contains($0) }
        .map { Option(key: $0, sport: $0) }

    /// Every selectable key, recovery group first, then the catalogue in its own order.
    static let options: [Option] = recoveryOptions + sportOptions

    static func option(forKey key: String) -> Option? {
        let q = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return options.first { $0.key.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// The activity a key is recorded as.
    static func sport(forKey key: String) -> String { option(forKey: key)?.sport ?? key }

    /// The variant a free-text label names ("yoga nidra" → NSDR), or nil for anything else.
    static func variant(matching raw: String) -> Option? {
        let s = raw.lowercased()
        if s.contains("nsdr") || s.contains("nidra") || s.contains("non-sleep deep rest")
            || s.contains("non sleep deep rest") {
            return variants.first { $0.key == nsdrKey }
        }
        if s.contains("restorative") || s.contains("yin yoga") {
            return variants.first { $0.key == restorativeYogaKey }
        }
        if s.contains("breath") && !s.contains("meditat") {
            return variants.first { $0.key == breathworkKey }
        }
        return nil
    }

    /// The selection key of a suggestion: its variant when it has one, else the catalogue spelling of its
    /// sport, else the sport as given.
    static func key(for s: WorkoutSuggestion) -> String {
        if let l = s.label, let o = option(forKey: l) { return o.key }
        return WorkoutCatalog.sport(named: s.sport)?.name ?? s.sport
    }

    /// True when nothing is unticked.
    var isUnrestricted: Bool { !Self.options.contains { excluded.contains($0.key) } }

    /// Whether `key` may be suggested. A label outside the list (free text from the model, "Other") can
    /// not be ticked, so it passes only while nothing at all is restricted.
    func allows(key: String) -> Bool {
        guard let o = Self.option(forKey: key) else { return isUnrestricted }
        return !excluded.contains(o.key)
    }

    func allows(_ s: WorkoutSuggestion) -> Bool { allows(key: Self.key(for: s)) }

    func filter(_ items: [WorkoutSuggestion]) -> [WorkoutSuggestion] { items.filter { allows($0) } }

    /// The first allowed key of `candidates`, in order.
    func first(of candidates: [String]) -> String? {
        candidates.first { Self.option(forKey: $0) != nil && allows(key: $0) }
    }

    /// The allowed keys, in list order.
    var allowedKeys: [String] { Self.options.map(\.key).filter { !excluded.contains($0) } }

    /// A stable short tag of the selection, for cache keys ("all" when unrestricted). FNV-1a rather than
    /// `hashValue`, which is seeded per launch and would miss the cache on every start.
    var signature: String {
        let keys = excluded.filter { Self.option(forKey: $0) != nil }.sorted()
        guard !keys.isEmpty else { return "all" }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in keys.joined(separator: "\n").utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }
}

enum StateWorkoutChoicesStore {
    static let key = "state.workoutChoices.excluded"

    static func read(_ d: UserDefaults = .standard) -> StateWorkoutChoices {
        StateWorkoutChoices(excluded: Set(d.stringArray(forKey: key) ?? []))
    }

    static func write(_ c: StateWorkoutChoices, _ d: UserDefaults = .standard) {
        d.set(c.excluded.sorted(), forKey: key)
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
            // The same sport at the same zone twice is one suggestion, not two. Compared by selection key,
            // so NSDR and a plain meditation (both recorded as Meditation) stay two.
            if out.contains(where: { $0.choiceKey.caseInsensitiveCompare(s.choiceKey) == .orderedSame && $0.zone == s.zone }) {
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
        // A recovery variant (NSDR, restorative yoga, breathwork) is recorded as its activity and keeps
        // its own name as the label.
        let variant = StateWorkoutChoices.variant(matching: rawSport)
        let sport = variant?.sport ?? canonicalSport(rawSport)
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
            why: String(why.prefix(220)),
            label: variant?.key)
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
///
/// STRESS IS THE SECOND OBJECTIVE, as in the coach's prompt: before 11:00 a short meditation comes first;
/// a hard session (done today, or the intervals suggested here) earns a down-regulation block after it
/// (NSDR, restorative yoga, meditation — whichever is allowed); high stress without either gets a quick
/// breathing / meditation block. Every pick goes through the wearer's selection (`StateWorkoutChoices`)
/// with substitutes in order; when nothing allowed fits, the list is empty and the tile says so.
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
        enduranceSport(recent: recent, choices: .all) ?? "Running"
    }

    /// Endurance sports to fall back on, in order, when the wearer's own is not allowed (or they have none).
    static let enduranceDefaults = [
        "Running", "Cycling", "Indoor cycle", "Rowing", "Row machine", "Elliptical", "Treadmill run",
        "Pool swim", "Open-water swim", "Hiking", "Spinning", "Stair climber", "Mountain biking",
        "Inline skating", "Jump rope", "Rucking",
    ]
    static let walkKeys = ["Walking", "Treadmill walk", "Hiking"]
    static let mobilityKeys = ["Stretching", "Yoga", StateWorkoutChoices.restorativeYogaKey, "Pilates"]
    static let calmMovementKeys = [StateWorkoutChoices.restorativeYogaKey, "Yoga", "Stretching"]
    static let strengthKeys = ["Strength", "Weightlifting", "Bodybuilding", "Calisthenics", "Powerlifting",
                               "CrossFit", "Boot camp", "Pilates"]
    /// After a hard session: the deepest down-regulation first.
    static let postHardKeys = [StateWorkoutChoices.nsdrKey, StateWorkoutChoices.restorativeYogaKey, "Meditation",
                               StateWorkoutChoices.breathworkKey, "Stretching"]
    /// The start of the day: a short sit.
    static let morningKeys = ["Meditation", StateWorkoutChoices.breathworkKey]
    /// High stress without hard training: the quickest downshift first.
    static let calmKeys = [StateWorkoutChoices.breathworkKey, "Meditation", StateWorkoutChoices.nsdrKey,
                           StateWorkoutChoices.restorativeYogaKey]
    /// Late evening: nothing that keeps you up.
    static let windDownKeys = ["Stretching", StateWorkoutChoices.restorativeYogaKey, StateWorkoutChoices.nsdrKey,
                               StateWorkoutChoices.breathworkKey, "Meditation", "Yoga"]

    /// The wearer's most frequent ALLOWED endurance sport over `recent`, else the first allowed default,
    /// else nil (nothing endurance-like is ticked).
    static func enduranceSport(recent: [StateWorkoutFact], choices: StateWorkoutChoices) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for w in recent {
            guard let hit = WorkoutCatalog.sport(named: w.sport),
                  !notEndurance.contains(hit.name.lowercased()),
                  !WorkoutCatalog.isRecovery(hit.name),
                  choices.allows(key: hit.name) else { continue }
            if counts[hit.name] == nil { order.append(hit.name) }
            counts[hit.name, default: 0] += 1
        }
        // Ties go to the most recent (recent is newest first, so `order` is too).
        if let best = counts.values.max(), let name = order.first(where: { counts[$0] == best }) { return name }
        return choices.first(of: enduranceDefaults)
    }

    /// A suggestion for a selection key: a variant is recorded as its activity and keeps its name as label.
    static func make(_ key: String, minutes: Int, zone: Int, effort: Double?, window: String?,
                     why: String) -> WorkoutSuggestion {
        let option = StateWorkoutChoices.option(forKey: key)
        let label: String? = (option?.isVariant ?? false) ? option?.key : nil
        return WorkoutSuggestion(sport: option?.sport ?? key, minutes: minutes, zone: zone, effort: effort,
                                 window: window, why: why, label: label)
    }

    /// Minutes for a recovery session of `key`.
    static func recoveryMinutes(_ key: String) -> Int {
        switch key {
        case StateWorkoutChoices.nsdrKey, StateWorkoutChoices.restorativeYogaKey, "Yoga": return 20
        case "Stretching": return 15
        default: return 10
        }
    }

    /// "HH:MM–HH:MM" from `startMinute` (rounded UP to 5), `length` minutes long. nil when it would start
    /// after 21:30 — too close to the night to be worth a line.
    static func clockWindow(startMinute: Int, length: Int) -> String? {
        let start = ((startMinute + 4) / 5) * 5
        guard start <= 21 * 60 + 30 else { return nil }
        let end = Swift.min(start + length, 22 * 60)
        return String(format: "%02d:%02d–%02d:%02d", start / 60, start % 60, end / 60, end % 60)
    }

    /// The start of a window string as minutes past midnight ("17:10–17:40" → 1030, "18:00" → 1080,
    /// "18–19" → 1080). nil when it does not start with a clock time.
    static func startMinute(of window: String?) -> Int? {
        guard let w = window else { return nil }
        let chars = Array(w)
        var i = 0
        while i < chars.count, !(chars[i].isASCII && chars[i].isNumber) { i += 1 }
        var h = ""
        while i < chars.count, h.count < 2, chars[i].isASCII, chars[i].isNumber {
            h.append(chars[i])
            i += 1
        }
        guard let hour = Int(h), (0...23).contains(hour) else { return nil }
        var minute = 0
        if i + 2 < chars.count, chars[i] == ":" || chars[i] == "." {
            if let v = Int(String(chars[(i + 1)...(i + 2)])), (0...59).contains(v) { minute = v }
        }
        return hour * 60 + minute
    }

    static func suggest(figures: StateTrainingFigures,
                        hour: Int,
                        today: [StateWorkoutFact],
                        recent: [StateWorkoutFact],
                        now: Date = Date(),
                        choices: StateWorkoutChoices = .all) -> [WorkoutSuggestion] {
        // LATE: only something that does not keep you up.
        if hour >= 21 {
            guard let key = choices.first(of: windDownKeys) else { return [] }
            return [make(key, minutes: key == "Stretching" ? 10 : recoveryMinutes(key), zone: 1, effort: 1,
                         window: nil,
                         why: String(localized: "It's late: a calm wind-down lowers stress before sleep without adding load."))]
        }

        let remaining = figures.remainingEffort
        let charge = figures.charge
        let walkWindow = window(hour: hour, preferredStart: hour + 1)
        let walkKey = choices.first(of: walkKeys)

        // Today's hard work, and whether a recovery session already followed it.
        let lastHard = today.filter { $0.isHard }.max { $0.end < $1.end }
        var recoveredSince = false
        if let h = lastHard {
            recoveredSince = today.contains { WorkoutCatalog.isRecovery($0.sport) && $0.start >= h.end }
        }
        let meditatedToday = today.contains { w in
            let name = w.sport.lowercased()
            return ["meditat", "mindful", "breath", "nidra", "nsdr"].contains { name.contains($0) }
        }
        let highStress = (figures.stress ?? 0) >= 2 || (figures.hrvDeltaPct ?? 0) <= -10

        // THE BRANCH'S OWN SESSIONS, most important first.
        var core: [WorkoutSuggestion] = []
        // A hard session this branch suggests (start minute, length), which earns a recovery block after it.
        var suggestedHardStart: Int?
        var suggestedHardMinutes = 0

        let lowCharge = (charge ?? 50) < 34
        let strained = (figures.sleepDebtMin ?? 0) >= 120
            || (figures.hrvDeltaPct ?? 0) <= -15
            || (figures.rhrDeltaBpm ?? 0) >= 5
            || (figures.stress ?? 0) >= 2.5

        if let remaining, remaining <= 3 {
            // TARGET REACHED: nothing that adds meaningful load.
            if let walkKey {
                core.append(make(walkKey, minutes: 20, zone: 1, effort: 3, window: walkWindow,
                                 why: String(localized: "Today's Effort target is reached. An easy walk aids recovery without adding real load.")))
            }
            if let mob = choices.first(of: mobilityKeys) {
                core.append(make(mob, minutes: 15, zone: 1, effort: 2, window: window(hour: hour, preferredStart: 19),
                                 why: String(localized: "Mobility work loosens you up after today's load.")))
            }
        } else if lowCharge || strained {
            // LOW CHARGE OR A STRAINED BODY: recovery only.
            let why = lowCharge
                ? String(localized: "Charge is low today: keep it in Zone 1 so recovery keeps going.")
                : String(localized: "Your body shows strain (sleep debt, HRV, resting HR or stress): easy movement only.")
            if let walkKey {
                core.append(make(walkKey, minutes: 30, zone: 1, effort: 5, window: walkWindow, why: why))
            }
            if let calmMove = choices.first(of: calmMovementKeys) {
                core.append(make(calmMove, minutes: 20, zone: 1, effort: 3,
                                 window: window(hour: hour, preferredStart: 18),
                                 why: String(localized: "Calm mobility supports recovery and lowers stress.")))
            }
        } else {
            let rem = remaining ?? 25
            let hardToday = lastHard != nil
            // Yesterday's (or earlier today's) intensity counts: two interval days in a row is the classic mistake.
            let hardRecently = hardToday || recent.prefix(3).contains { w in
                w.isHard && now.timeIntervalSince(w.start) < 36 * 3600
            }
            // After a hard session today, the next load waits until the recovery block has had its turn.
            let z2Start = hardToday ? hour + 3 : 11
            if let endurance = enduranceSport(recent: recent, choices: choices) {
                if (charge ?? 0) >= 67 && !hardRecently && rem >= 20 {
                    let intervalMin = minutes(for: rem * 0.6, zone: 4, range: 20...45)
                    let intervalWindow = window(hour: hour, preferredStart: 16)
                    core.append(WorkoutSuggestion(
                        sport: endurance, minutes: intervalMin, zone: 4,
                        effort: Swift.min(rem, Double(intervalMin) * effortPerMinute(zone: 4)).rounded(),
                        window: intervalWindow,
                        why: String(localized: "High charge and plenty of target left: intervals, e.g. 5 × 3 min in Zone 4 with easy recoveries.")))
                    suggestedHardStart = startMinute(of: intervalWindow)
                    suggestedHardMinutes = intervalMin
                    let z2 = minutes(for: rem, zone: 2, range: 30...75)
                    core.append(WorkoutSuggestion(
                        sport: endurance, minutes: z2, zone: 2,
                        effort: Swift.min(rem, Double(z2) * effortPerMinute(zone: 2)).rounded(),
                        window: window(hour: hour, preferredStart: 11),
                        why: String(localized: "Or steady Zone 2 endurance: builds base with little recovery cost.")))
                } else {
                    let z2 = minutes(for: rem, zone: 2, range: 20...60)
                    core.append(WorkoutSuggestion(
                        sport: endurance, minutes: z2, zone: 2,
                        effort: Swift.min(rem, Double(z2) * effortPerMinute(zone: 2)).rounded(),
                        window: window(hour: hour, preferredStart: z2Start),
                        why: hardRecently
                            ? String(localized: "You already went hard recently: keep today aerobic in Zone 2.")
                            : String(localized: "Zone 2 endurance closes the gap to today's target at a sustainable cost.")))
                }
            } else if let strength = choices.first(of: strengthKeys) {
                // No endurance sport ticked: the wearer's gym work, kept moderate.
                core.append(make(strength, minutes: 45, zone: 2,
                                 effort: Swift.min(rem, 45 * effortPerMinute(zone: 2)).rounded(),
                                 window: window(hour: hour, preferredStart: z2Start),
                                 why: String(localized: "A controlled strength session moves you toward today's target without a hard cardio hit.")))
            } else if let other = choices.allowedKeys.first(where: { key in
                !StateWorkoutChoices.recoveryKeys.contains(key) && !walkKeys.contains(key)
            }) {
                // Only other sports ticked: one of them, at a moderate intensity.
                core.append(make(other, minutes: 45, zone: 2,
                                 effort: Swift.min(rem, 45 * effortPerMinute(zone: 2)).rounded(),
                                 window: window(hour: hour, preferredStart: z2Start),
                                 why: String(localized: "One of your selected sports, kept at a moderate intensity.")))
            }
            if let walkKey {
                core.append(make(walkKey, minutes: 25, zone: 1, effort: 4, window: walkWindow,
                                 why: String(localized: "An easy walk adds steps and aids recovery between sessions.")))
            }
        }

        // DOWN-REGULATION, the stress half of the plan.
        // 1. The start of the day: a short sit before anything else, unless one is already logged.
        var morning: WorkoutSuggestion?
        if hour < 11, !meditatedToday, let key = choices.first(of: morningKeys) {
            morning = make(key, minutes: 10, zone: 1, effort: 1,
                           window: window(hour: hour, preferredStart: hour + 1, length: 1),
                           why: String(localized: "Start the day calm: a short sit early on lowers the stress baseline for everything after it."))
        }
        // 2. After hard work, done today or suggested above: a recovery block 30–90 minutes after it.
        var recovery: WorkoutSuggestion?
        if let key = choices.first(of: postHardKeys) {
            if let h = lastHard, !recoveredSince {
                let minutesSince = now.timeIntervalSince(h.end) / 60
                let win = minutesSince <= 240
                    ? window(hour: hour, preferredStart: hour + 1, length: 1)
                    : window(hour: hour, preferredStart: Swift.max(hour + 1, 19), length: 1)
                recovery = make(key, minutes: recoveryMinutes(key), zone: 1, effort: 1, window: win,
                                why: String(localized: "After today's hard session: a down-regulation block brings heart rate and stress back down and speeds recovery."))
            } else if let start = suggestedHardStart,
                      let win = clockWindow(startMinute: start + suggestedHardMinutes + 30, length: 30) {
                recovery = make(key, minutes: recoveryMinutes(key), zone: 1, effort: 1, window: win,
                                why: String(localized: "About 30 minutes after the intervals: a down-regulation block to bring stress back down."))
            }
        }
        // 3. High stress without either of the above: a quick downshift.
        var calm: WorkoutSuggestion?
        if highStress, morning == nil, recovery == nil, let key = choices.first(of: calmKeys) {
            calm = make(key, minutes: recoveryMinutes(key), zone: 1, effort: 1,
                        window: window(hour: hour, preferredStart: hour + 1, length: 1),
                        why: String(localized: "Stress is high today: a few minutes of slow breathing or a guided rest lowers it before anything else."))
        }

        // PRIORITY for the three places: the morning sit, the stress downshift (high stress puts
        // down-regulation ahead of any training), the main session, its recovery, then the alternatives.
        // Shown in clock order.
        var ranked: [WorkoutSuggestion] = []
        if let morning { ranked.append(morning) }
        if let calm { ranked.append(calm) }
        if let first = core.first { ranked.append(first) }
        if let recovery { ranked.append(recovery) }
        ranked.append(contentsOf: core.dropFirst())
        var picked: [WorkoutSuggestion] = []
        for s in ranked where !picked.contains(where: { $0.id == s.id }) {
            picked.append(s)
            if picked.count == WorkoutSuggestionParser.maxCount { break }
        }
        return inClockOrder(picked)
    }

    /// Sorted by window start; items without a readable window keep their order at the end.
    static func inClockOrder(_ items: [WorkoutSuggestion]) -> [WorkoutSuggestion] {
        items.enumerated()
            .sorted { a, b in
                let sa = startMinute(of: a.element.window) ?? Int.max
                let sb = startMinute(of: b.element.window) ?? Int.max
                return sa != sb ? sa < sb : a.offset < b.offset
            }
            .map { $0.element }
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

    static func systemPrompt(grounding: String, choices: StateWorkoutChoices = .all) -> String {
        var s = "You are the user's training coach. Suggest 1 to 3 FURTHER sessions for the REST OF TODAY, "
        s += "chosen from their data: what they already did today, the last two weeks of training and its "
        s += "effort, today's Effort against the recommended target, charge, sleep debt, HRV and resting HR "
        s += "against baseline, stress, the time of day and the weather. Rules: never prescribe hard work on "
        s += "low charge or a strained body; if the target is already reached suggest only easy Zone 1 "
        s += "movement, mobility or recovery; do not repeat a hard session the day after one. Prefer sports "
        s += "the user actually does.\n\n"
        s += StateDayPlanContext.stressObjective + "\n\n"
        s += allowedSection(choices) + "\n\n"
        s += "Answer with JSON ONLY, no prose and no code fence, exactly in this shape:\n"
        s += #"{"workouts":[{"sport":"Running","minutes":40,"zone":2,"effort":12,"window":"17:00-18:00","why":"one short sentence"},{"sport":"NSDR","minutes":20,"zone":1,"effort":1,"window":"18:30-19:00","why":"one short sentence"}]}"#
        s += "\n"
        s += "sport: exactly one name from the allowed list above. "
        s += "zone: the target heart-rate zone 1-5 on the user's zones listed below (recovery sessions: 1). "
        s += "effort: estimated Effort points (0-100 scale) the session adds today. "
        s += "window: a clock-time window HH:MM-HH:MM that starts LATER than the time now (never in the past) "
        s += "and fits the day's schedule below. "
        s += "why: one short sentence in the user's language.\n\n"
        s += grounding
        return s
    }

    /// The names the model may use. Always the full list, so "only from these" is a closed set the parser
    /// can hold the answer to.
    static func allowedSection(_ choices: StateWorkoutChoices) -> String {
        let keys = choices.allowedKeys
        guard !keys.isEmpty else {
            return "ALLOWED SESSIONS: the user has deselected every workout. Answer {\"workouts\":[]}."
        }
        var s = "ALLOWED SESSIONS — the user chose which workouts may be suggested. Only suggest from this "
        s += "list and use the names exactly as written; never suggest anything else: "
        s += keys.joined(separator: ", ") + "."
        let variants = StateWorkoutChoices.variants.filter { keys.contains($0.key) }
        if !variants.isEmpty {
            s += " (" + variants.map { v -> String in
                switch v.key {
                case StateWorkoutChoices.nsdrKey: return "NSDR = non-sleep deep rest / yoga nidra, a guided lying-down relaxation"
                case StateWorkoutChoices.restorativeYogaKey: return "Restorative yoga = slow, supported, floor-based yoga"
                default: return "Breathwork = slow-breathing practice, e.g. extended exhale or box breathing"
                }
            }.joined(separator: "; ") + ".)"
        }
        return s
    }

    static let question = "Suggest today's further workouts as JSON."
}

// MARK: - Stress objective and the day's schedule

/// The STATE tile's second objective beside training — keep stress low — and the day's clock the coach
/// plans it on: wake, focus window, wind-down, bedtime. Shared by the workout suggestions and the mission
/// the State refresh writes.
enum StateDayPlanContext {

    /// The rules the coach is asked to plan stress by. Stated once here so both prompts say the same thing.
    static let stressObjective: String = {
        var s = "SECOND OBJECTIVE — KEEP THE USER'S STRESS LOW. Read stress now, the stress-by-hour curve "
        s += "today, the stress score and HRV against baseline, and plan the day to bring stress down:\n"
        s += "- After any hard session (one done today, or one you suggest), schedule a down-regulation block "
        s += "— NSDR / yoga nidra, restorative yoga, meditation or breathwork, 10-20 min, Zone 1 — starting "
        s += "30-90 minutes after that session ends.\n"
        s += "- When stress is elevated (stress score 2 or more of 3, a rising curve, or HRV 10% or more below "
        s += "baseline), include a down-regulation block even without hard training and keep any training easy.\n"
        s += "- Follow the day's structure: a short meditation or breathwork early in the day, soon after "
        s += "waking, while it is still morning; training and movement breaks inside the focus window; only "
        s += "calm, low-arousal sessions in the wind-down before bedtime, never training.\n"
        s += "- Respect the user's routines (work hours, fixed appointments) when they are given.\n"
        s += "- Every time you give is a clock time later than the time now, never in the past."
        return s
    }()

    /// The mission's version: the same objective, pointed at ONE thing to do today.
    static func missionObjective(choices: StateWorkoutChoices) -> String {
        var s = stressObjective + "\n"
        s += "For TODAY'S MISSION this means: when stress is elevated, HRV is below baseline or a hard session "
        s += "is done or planned today, a down-regulation mission (meditation, breathwork, NSDR / yoga nidra "
        s += "or restorative yoga — GOAL: MEDITATION_MIN) or an earlier bedtime is often the right one thing. "
        s += "Name a clock time for it that fits the schedule below."
        if !choices.isUnrestricted {
            let keys = choices.allowedKeys
            s += keys.isEmpty
                ? " The user has deselected every workout: do not make the mission a workout."
                : " If the mission is a workout, pick it only from: " + keys.joined(separator: ", ") + "."
        }
        return s
    }

    private static func clock(_ minute: Int) -> String {
        let m = RoomClimateSchedule.wrap(minute)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// The day's clock for the coach: now, wake, the morning start-up, the focus window, the wind-down and
    /// bedtime, from the same schedule the bedroom-climate tile uses (the wearer's plan, else their
    /// typical nights, else 22:30–07:00).
    static func block(now: Date, schedule: RoomClimateSchedule, calendar: Calendar = .current) -> String {
        let source: String
        switch schedule.source {
        case .plan: source = "from the user's sleep plan"
        case .history: source = "typical of the last two weeks"
        case .fallback: source = "default estimate, no plan or sleep history"
        }
        let nowMinute = RoomClimateSchedule.minuteOfDay(now, calendar)
        let phase: String
        switch schedule.mode(atMinute: nowMinute) {
        case .morning: phase = "morning start-up"
        case .focus: phase = "focus / active day"
        case .sleep:
            phase = RoomClimateSchedule.within(nowMinute, from: schedule.sleepStartMinute, to: schedule.bedtimeMinute)
                ? "wind-down" : "night"
        }
        var s: [String] = ["TODAY'S SCHEDULE (local clock; place every session inside it and later than now):"]
        s.append("Time now: \(clock(nowMinute)) (\(phase)).")
        s.append("Wake: \(clock(schedule.wakeMinute)). Bedtime: \(clock(schedule.bedtimeMinute)) (\(source)).")
        s.append("Morning start-up (best for a short meditation or breathwork): "
                 + "\(clock(schedule.wakeMinute))–\(clock(schedule.focusStartMinute)).")
        s.append("Focus / active window (training, focus blocks, movement breaks): "
                 + "\(clock(schedule.focusStartMinute))–\(clock(schedule.sleepStartMinute)).")
        s.append("Wind-down (calm only — breathwork, NSDR, restorative yoga, stretching; no training): "
                 + "\(clock(schedule.sleepStartMinute))–\(clock(schedule.bedtimeMinute)).")
        return s.joined(separator: "\n")
    }
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

    /// The fingerprint of today's workouts (how many, and when the latest started) and of the wearer's
    /// workout selection, so changing the selection asks for fresh suggestions once.
    static func fingerprint(today: [StateWorkoutFact], choices: StateWorkoutChoices = .all) -> String {
        let latest = today.map { Int($0.start.timeIntervalSince1970) }.max() ?? 0
        return "\(today.count)|\(latest)|\(choices.signature)"
    }
}

// MARK: - The wearer's own hand on the list

/// What the wearer did to today's WORKOUTS TODAY list themselves: the workouts they asked for (pinned —
/// they survive every regeneration) and the ones they removed (gone for the rest of the day).
///
/// PER DAY, AND THE DAY ROLLS OVER BY ITSELF. A stored set from another day is never returned
/// (`StateWorkoutEditsStore.read`): a removal is "not today", not "never again", and a workout the wearer
/// asked for yesterday has no business on this morning's list.
struct StateWorkoutEdits: Codable, Equatable {

    let dayKey: String
    /// The workouts the wearer asked for, oldest request first.
    var pinned: [WorkoutSuggestion]
    /// `dismissKey` of every suggestion they removed.
    var dismissed: Set<String>

    init(dayKey: String, pinned: [WorkoutSuggestion] = [], dismissed: Set<String> = []) {
        self.dayKey = dayKey
        self.pinned = pinned
        self.dismissed = dismissed
    }

    var isEmpty: Bool { pinned.isEmpty && dismissed.isEmpty }

    /// The key a removal suppresses. NOT the id: the coach re-words and re-times its list on every
    /// regeneration, and "Running at 17:00" coming back as "Running at 17:05" is the same suggestion to
    /// the wearer — dismissing by id would let it walk straight back in. Selection key (the sport, or the
    /// recovery variant) plus the start of its window rounded to the nearest half hour.
    static func dismissKey(_ s: WorkoutSuggestion) -> String {
        // Written out rather than chained: the one-line `.map { ... } ?? "-"` version of this rounding
        // blew the type-checker's budget on CI.
        var slot = "-"
        if let start: Int = WorkoutSuggestionFallback.startMinute(of: s.window) {
            let rounded: Int = ((start + 15) / 30) * 30
            let wrapped: Int = rounded % (24 * 60)
            slot = String(wrapped)
        }
        return s.choiceKey.lowercased() + "@" + slot
    }

    func isDismissed(_ s: WorkoutSuggestion) -> Bool { dismissed.contains(Self.dismissKey(s)) }

    /// Remove `s` for the rest of today. A workout the wearer added themselves is DELETED — it was theirs,
    /// nothing regenerates it, and suppressing its key would also block asking for it again in an hour.
    /// Anything else is suppressed by key, so the next regeneration does not bring it back.
    mutating func dismiss(_ s: WorkoutSuggestion) {
        if s.byUser || pinned.contains(where: { $0.id == s.id }) {
            pinned.removeAll { $0.id == s.id }
            return
        }
        dismissed.insert(Self.dismissKey(s))
    }

    /// Pin a workout the wearer asked for. Asking twice for the same session at the same time replaces the
    /// first rather than listing it twice, and it is no longer dismissed — they just asked for it.
    mutating func pin(_ s: WorkoutSuggestion) {
        var item = s
        item.byUser = true
        let key = Self.dismissKey(item)
        pinned.removeAll { Self.dismissKey($0) == key }
        dismissed.remove(key)
        pinned.append(item)
    }

    /// Today's list as the tile shows it: `generated` with the removed ones dropped and the wearer's own
    /// pinned in, in clock order.
    ///
    /// `limit` caps the GENERATED half only. A workout the wearer asked for is theirs and is never squeezed
    /// out by the coach's three; and because the cap is applied AFTER the removals, taking one row away
    /// lets the next generated one through when more than `limit` were produced.
    func applied(to generated: [WorkoutSuggestion],
                 limit: Int = WorkoutSuggestionParser.maxCount) -> [WorkoutSuggestion] {
        var kept: [WorkoutSuggestion] = []
        for s in generated {
            guard !isDismissed(s),
                  // The wearer's own copy of the same session wins: it is not shown twice.
                  !pinned.contains(where: { Self.dismissKey($0) == Self.dismissKey(s) }),
                  !kept.contains(where: { $0.id == s.id })
            else { continue }
            kept.append(s)
            if kept.count == limit { break }
        }
        return WorkoutSuggestionFallback.inClockOrder(pinned + kept)
    }
}

enum StateWorkoutEditsStore {
    static let key = "state.workoutEdits"

    /// The edits for `dayKey`, or an empty set — including when what is stored belongs to another day.
    static func read(dayKey: String, _ d: UserDefaults = .standard) -> StateWorkoutEdits {
        guard let data = d.data(forKey: key),
              let v = try? JSONDecoder().decode(StateWorkoutEdits.self, from: data),
              v.dayKey == dayKey
        else { return StateWorkoutEdits(dayKey: dayKey) }
        return v
    }

    static func write(_ v: StateWorkoutEdits, _ d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        d.set(data, forKey: key)
    }
}

// MARK: - A workout the wearer asks for

/// When the wearer wants their own workout to start.
enum CustomWorkoutTime: Equatable {
    /// As soon as possible: the next five-minute mark.
    case asap
    /// A clock time, in minutes past local midnight.
    case clock(Int)

    /// The start, in minutes past local midnight. Kept inside the day; never moved into tomorrow, because
    /// the whole list is today's.
    func startMinute(now: Date, calendar: Calendar = .current) -> Int {
        switch self {
        case .asap:
            let c = calendar.dateComponents([.hour, .minute], from: now)
            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            return Swift.min(((m + 4) / 5) * 5, 23 * 60 + 55)
        case .clock(let m):
            return Swift.min(Swift.max(m, 0), 23 * 60 + 55)
        }
    }
}

/// The coach turning "30 min easy run, 18:00" into one suggestion in exactly the shape the other ones have.
///
/// Same request path as every other headless generation, same tolerant JSON read
/// (`WorkoutSuggestionParser`), and a deterministic fallback so tapping Add always produces a workout:
/// no provider, no consent or an unreadable answer maps the wearer's words to the closest sport (or
/// "Other") at the time they picked.
///
/// THE SELECTION DOES NOT APPLY HERE. `StateWorkoutChoices` governs what the coach may *suggest*; this is
/// the wearer naming a session themselves, and the whole catalogue is on the table.
///
/// THE START TIME IS OURS, NOT THE MODEL'S. The window is built here from the time the wearer picked and
/// the length that comes back, so the row can never sit at an hour they did not choose.
enum CustomWorkoutWriter {

    static let question = "Write the requested workout as JSON."

    /// A request longer than this is not a workout description any more; the tail is dropped rather than
    /// carried into the prompt.
    static let maxRequestChars = 300

    static func clock(_ minute: Int) -> String {
        let m = Swift.min(Swift.max(minute, 0), 24 * 60 - 1)
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// "HH:MM–HH:MM" for a session of `minutes` starting at `startMinute`. Unlike the suggestion rules'
    /// own window this is never refused for being late: the wearer asked for this time.
    static func window(startMinute: Int, minutes: Int) -> String {
        let start = Swift.min(Swift.max(startMinute, 0), 24 * 60 - 1)
        let end = Swift.min(start + Swift.max(minutes, 0), 24 * 60 - 1)
        return clock(start) + "–" + clock(end)
    }

    static func systemPrompt(grounding: String, request: String, startMinute: Int) -> String {
        var s = "You are the user's training coach. The user has ASKED FOR ONE SPECIFIC WORKOUT and chosen "
        s += "when it starts. Your job is not to talk them out of it: write it up as one proper session, "
        s += "sized and paced for the state their data is in.\n\n"
        s += "THE REQUEST: \"" + String(request.prefix(maxRequestChars)) + "\"\n"
        s += "START TIME: " + clock(startMinute) + " local, today. Do not change it.\n\n"
        s += "Answer with JSON ONLY, no prose and no code fence, exactly in this shape:\n"
        s += #"{"sport":"Running","minutes":30,"zone":2,"effort":11,"why":"one short sentence"}"#
        s += "\n"
        s += "sport: the closest name from this list, or \"Other\" when nothing fits: "
        s += StateWorkoutChoices.options.map(\.key).joined(separator: ", ") + ".\n"
        s += "minutes: the length they asked for; when they named none, a sensible one for that session.\n"
        s += "zone: the target heart-rate zone 1-5 on the user's own zones in the data below "
        s += "(a recovery or mobility session: 1).\n"
        s += "effort: the estimated Effort points (0-100 scale) the session adds to today.\n"
        s += "why: ONE short sentence in the user's language. If their charge, the effort they have already "
        s += "done against today's target, their stress or their sleep make this a bad idea, say so plainly "
        s += "in that same sentence — and still give them the session they asked for.\n"
        s += "One workout only. No second suggestion, no list.\n\n"
        s += grounding
        return s
    }

    /// The coach's answer if it is usable, otherwise the fallback. Never nil, and always at the wearer's
    /// own start time.
    static func resolve(answer: String?, request: String, startMinute: Int) -> WorkoutSuggestion {
        guard let answer, let first = WorkoutSuggestionParser.parse(answer)?.first else {
            return fallback(request: request, startMinute: startMinute)
        }
        var s = first
        s.window = window(startMinute: startMinute, minutes: s.minutes)
        s.byUser = true
        if s.why.isEmpty { s.why = String(localized: "You asked for this one.") }
        return s
    }

    /// The wearer's words as a workout, for when the coach cannot be reached. The reason says exactly that:
    /// nothing here has been weighed against today's state, and it must not pretend otherwise.
    static func fallback(request: String, startMinute: Int) -> WorkoutSuggestion {
        let option = sport(matching: request)
        let sportName = option?.sport ?? WorkoutCatalog.defaultSportName
        let label = (option?.isVariant ?? false) ? option?.key : nil
        let recovery = label != nil || WorkoutCatalog.isRecovery(sportName)
        let mins = minutes(in: request) ?? (recovery ? 15 : 40)
        let zone = requestedZone(request) ?? ((recovery || sportName == StateActionMapper.walkSport) ? 1 : 2)
        return WorkoutSuggestion(
            sport: sportName,
            minutes: mins,
            zone: zone,
            effort: (Double(mins) * WorkoutSuggestionFallback.effortPerMinute(zone: zone)).rounded(),
            window: window(startMinute: startMinute, minutes: mins),
            why: String(localized: "You asked for this one. The coach wasn't reachable, so it has not been weighed against today's state."),
            label: label,
            byUser: true)
    }

    /// The catalogue sport (or recovery variant) a free-text request names, else nil.
    ///
    /// Longest name first, so "Treadmill run" wins over "Running" and "Restorative yoga" never lands on
    /// plain Yoga. The alias table is the words people actually type instead of a catalogue name — in
    /// English and in German, because the request is written in the wearer's own language.
    static func sport(matching text: String) -> StateWorkoutChoices.Option? {
        if let v = StateWorkoutChoices.variant(matching: text) { return v }
        let haystack = text.lowercased()
        let names = WorkoutCatalog.all.map(\.name)
            .filter { $0 != WorkoutCatalog.defaultSportName }
            .sorted { $0.count > $1.count }
        if let hit = names.first(where: { haystack.contains($0.lowercased()) }) {
            return StateWorkoutChoices.Option(key: hit, sport: hit)
        }
        if let hit = requestAliases.sorted(by: { $0.key.count > $1.key.count })
            .first(where: { haystack.contains($0.key) }) {
            return StateWorkoutChoices.Option(key: hit.value, sport: hit.value)
        }
        return nil
    }

    /// Word stems → catalogue sport. Stems, not whole words, so "laufen", "Radfahren" and "stretching"
    /// all land. Deliberately not exhaustive: this is the offline safety net, the coach does the real
    /// reading.
    static let requestAliases: [String: String] = [
        "run": "Running", "jog": "Running", "lauf": "Running", "joggen": "Running",
        "walk": "Walking", "spazier": "Walking",
        "bike": "Cycling", "cycle": "Cycling", "radfahr": "Cycling", "fahrrad": "Cycling",
        "swim": "Pool swim", "schwimm": "Pool swim",
        "row": "Rowing", "ruder": "Rowing",
        "hike": "Hiking", "wander": "Hiking",
        "weights": "Weightlifting", "gewichte": "Weightlifting", "deadlift": "Weightlifting",
        "gym": "Strength", "kraft": "Strength", "upper body": "Strength", "lower body": "Strength",
        "oberkörper": "Strength", "unterkörper": "Strength", "leg day": "Strength", "beintag": "Strength",
        "interval": "HIIT", "sprint": "HIIT",
        "stretch": "Stretching", "dehn": "Stretching", "mobility": "Stretching", "mobilit": "Stretching",
        "meditat": "Meditation", "achtsam": "Meditation",
        "treadmill": "Treadmill run", "laufband": "Treadmill run",
        "climb": "Climbing", "kletter": "Climbing", "boulder": "Climbing",
        "fußball": "Soccer", "fussball": "Soccer",
    ]

    /// The length the request names ("30 min", "45 Minuten", "1.5 h"), clamped to the range a suggestion
    /// may carry, else nil. A bare number is NOT a length: "5k easy" is not a five-minute run.
    static func minutes(in text: String) -> Int? {
        let chars = Array(text.lowercased())
        var i = 0
        while i < chars.count {
            guard chars[i].isASCII, chars[i].isNumber else { i += 1; continue }
            var num = ""
            while i < chars.count, chars[i].isASCII,
                  chars[i].isNumber || ((chars[i] == "." || chars[i] == ",") && !num.contains(".")) {
                num.append(chars[i] == "," ? "." : chars[i])
                i += 1
            }
            if num.hasSuffix(".") { num.removeLast() }
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            var word = ""
            while j < chars.count, chars[j].isLetter, word.count < 8 {
                word.append(chars[j])
                j += 1
            }
            guard let v = Double(num), v > 0 else { continue }
            let hours = word == "h" || word == "hr" || word == "hrs" || word.hasPrefix("hour")
                || word == "std" || word.hasPrefix("stunde")
            let mins = word == "m" || word.hasPrefix("min")
            guard hours || mins else { continue }
            let total = hours ? v * 60 : v
            return Swift.min(Swift.max(Int(total.rounded()), WorkoutSuggestionParser.minutesRange.lowerBound),
                             WorkoutSuggestionParser.minutesRange.upperBound)
        }
        return nil
    }

    /// A zone the request names EXPLICITLY ("zone 2", "Z4"), else nil. A bare digit is not a zone:
    /// `WorkoutSuggestionParser.zoneNumber` would read "30 min" as Zone 3.
    static func requestedZone(_ text: String) -> Int? {
        let chars = Array(text.lowercased())
        var i = 0
        while i < chars.count {
            defer { i += 1 }
            guard chars[i] == "z" else { continue }
            let atWordStart = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber)
            guard atWordStart else { continue }
            var j = i + 1
            if j + 2 < chars.count, chars[j] == "o", chars[j + 1] == "n", chars[j + 2] == "e" { j += 3 }
            while j < chars.count, chars[j] == " " || chars[j] == ":" || chars[j] == "-" { j += 1 }
            if j < chars.count, let d = chars[j].wholeNumberValue, (1...5).contains(d) { return d }
        }
        return nil
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
