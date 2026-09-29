import Foundation

// HabitModel.swift — one model of every behaviour the app records, keyed to the night it precedes.
//
// HEALTH_V2 §S1-A.2. Before this file, behaviour lived in a dozen stores with a dozen conventions: a
// journal "no" was a row, a numeric journal 0 was a "yes", a dream answer was a number nobody read, a
// caffeine intake vanished after 48 hours, and "no row" was silently read as "no" by several statistics.
// Here every behaviour is normalised to ONE shape (`HabitObservation`), keyed by ONE rule (the wake-day
// key of the night the behaviour precedes), with ONE rule for absence: a night the app cannot see is not
// a "no", it is not an observation at all.
//
// Pure + deterministic: `yyyy-MM-dd` strings, integer calendar math (never `Calendar`, so a DST change is
// a date and never a 23- or 25-hour day), no store. Swift-only in 2.0; every primitive is chosen so a
// Kotlin twin can reproduce it (see HEALTH_V2 "Platform note").

// MARK: - Day keys

/// Integer civil-calendar math on `yyyy-MM-dd` keys (Howard Hinnant's days_from_civil / civil_from_days).
public enum HabitDay {

    /// Days since 1970-01-01, or nil for a key that is not a valid date.
    public static func epochDay(_ key: String) -> Int? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= daysInMonth(year: y, month: m) else { return nil }
        let yy = m <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The key for a day number (inverse of `epochDay`).
    public static func key(_ epochDay: Int) -> String {
        let z = epochDay + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
    }

    /// `key` shifted by `days` (may be negative). Nil when `key` is not a date.
    public static func adding(_ days: Int, to key: String) -> String? {
        guard let e = epochDay(key) else { return nil }
        return HabitDay.key(e + days)
    }

    /// `to − from` in whole days. Nil when either key is not a date.
    public static func days(from: String, to: String) -> Int? {
        guard let a = epochDay(from), let b = epochDay(to) else { return nil }
        return b - a
    }

    /// ISO weekday, 1 = Monday … 7 = Sunday.
    public static func isoWeekday(_ key: String) -> Int? {
        guard let e = epochDay(key) else { return nil }
        // 1970-01-01 was a Thursday (ISO 4).
        return ((e + 3) % 7 + 7) % 7 + 1
    }

    /// Whether the EVENING of `key` is a weekend evening: Friday or Saturday — the evenings that lead into
    /// a day off, which is where later nights, alcohol and social meals cluster. One definition, used by the
    /// habit associations and by the blocked trial design alike.
    public static func isWeekendEvening(_ key: String) -> Bool {
        guard let wd = isoWeekday(key) else { return false }
        return wd == 5 || wd == 6
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        }
    }

    private static func pad(_ v: Int, _ width: Int) -> String {
        let s = String(v)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }
}

// MARK: - Identity and kinds

/// A habit's identity: `"journal:<canonical>"`, `"dream:screen"`, `"auto:lateCaffeine"`, …
public struct HabitId: Hashable, Codable, Comparable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public static func < (lhs: HabitId, rhs: HabitId) -> Bool { lhs.raw < rhs.raw }
}

/// What kind of thing a habit is — which decides whether it may ever be tested or trialled.
public enum HabitKind: String, Codable, Sendable {
    /// A choice the wearer makes. Tested (associations) and, when catalogued, trialled.
    case behaviour
    /// A state, not a choice (stressed, sick, shared bed): reported with counts, never tested, never trialled.
    case context
    /// Recorded (magnesium) and shown descriptively, never tested, never proposed as a trial.
    case supplement
}

/// A direction of change.
public enum EffectDirection: String, Codable, Sendable {
    case increase
    case decrease

    /// +1 for `.increase`, −1 for `.decrease`.
    public var sign: Double { self == .increase ? 1 : -1 }
}

/// Where an observation came from.
public enum HabitSource: String, Codable, Sendable {
    case journal, dream, caffeineLog, workouts, climate, breathLog, wiz, sleepTiming
}

/// An observed state. There is deliberately no `absent` case: a night without an observation has NO
/// `HabitObservation` at all, so "not logged" can never be mistaken for "no".
public enum ObservationState: String, Codable, Sendable { case yes, no }

/// One observed night of one habit.
public struct HabitObservation: Equatable, Codable, Sendable {
    /// Wake-day key of the night this behaviour precedes.
    public let nightKey: String
    public let habit: HabitId
    public let state: ObservationState
    public let source: HabitSource
    /// True when reported the next morning (dream answers).
    public let recalled: Bool

    public init(nightKey: String, habit: HabitId, state: ObservationState, source: HabitSource,
                recalled: Bool = false) {
        self.nightKey = nightKey
        self.habit = habit
        self.state = state
        self.source = source
        self.recalled = recalled
    }
}

// MARK: - Outcomes

/// What a habit is related to. All keyed to the night (see `HabitNightKey`).
public enum HabitOutcome: String, Codable, CaseIterable, Sendable {
    // May be primary.
    case nightHrvLn, nightRhr, totalSleepMin, onsetClockMin, sleepEfficiency
    // Secondary / exploratory only.
    case nextMorningCharge, dayStressMean, feltRested

    /// Whether this outcome may ever be a habit's or a trial's primary outcome.
    public var canBePrimary: Bool {
        switch self {
        case .nightHrvLn, .nightRhr, .totalSleepMin, .onsetClockMin, .sleepEfficiency: return true
        case .nextMorningCharge, .dayStressMean, .feltRested: return false
        }
    }

    /// Which way is better.
    public var betterDirection: EffectDirection {
        switch self {
        case .nightHrvLn, .totalSleepMin, .sleepEfficiency, .nextMorningCharge, .feltRested: return .increase
        case .nightRhr, .onsetClockMin, .dayStressMean: return .decrease
        }
    }

    /// Analysed on the natural-log scale (reported back as a percentage).
    public var isLogScale: Bool { self == .nightHrvLn }

    /// Plain-words name.
    public var label: String {
        switch self {
        case .nightHrvLn: return "night HRV"
        case .nightRhr: return "night resting HR"
        case .totalSleepMin: return "total sleep"
        case .onsetClockMin: return "sleep onset time"
        case .sleepEfficiency: return "sleep efficiency"
        case .nextMorningCharge: return "next-morning Charge"
        case .dayStressMean: return "daytime stress"
        case .feltRested: return "felt rested"
        }
    }

    /// The unit of an ESTIMATE in display terms.
    public var displayUnit: String {
        switch self {
        case .nightHrvLn: return "%"
        case .nightRhr: return "bpm"
        case .totalSleepMin, .onsetClockMin: return "min"
        case .sleepEfficiency: return "pts"
        case .nextMorningCharge: return "pts"
        case .dayStressMean, .feltRested: return ""
        }
    }

    /// The minimal meaningful effect (HEALTH_V2 §B.2 table), in analysis units. `baselineSD` is the SD of
    /// the outcome over the reference nights. Nil where the outcome is exploratory-only, or where the
    /// threshold depends on a baseline that is not there.
    public func mcid(baselineSD: Double?) -> Double? {
        switch self {
        case .nightHrvLn:
            guard let sd = baselineSD, sd.isFinite, sd >= 0 else { return nil }
            return Swift.max(0.5 * sd, 0.04)
        case .nightRhr:
            guard let sd = baselineSD, sd.isFinite, sd >= 0 else { return nil }
            return Swift.max(0.5 * sd, 1.0)
        case .totalSleepMin: return 15
        case .onsetClockMin: return 15
        case .sleepEfficiency: return 2
        case .nextMorningCharge: return 5
        case .dayStressMean, .feltRested: return nil
        }
    }

    /// An estimate in analysis units → display units (ln → percent; everything else unchanged).
    public func display(_ estimate: Double) -> Double {
        isLogScale ? (exp(estimate) - 1) * 100 : estimate
    }

    /// Sleep onset as a continuous clock value: minutes after local midnight, with onsets before noon
    /// counted as the previous evening's continuation (00:30 → 1470), so 23:50 and 00:10 are 20 min apart
    /// and not 1420.
    public static func onsetClockValue(onsetMinute: Int) -> Double {
        let m = ((onsetMinute % 1440) + 1440) % 1440
        return Double(m < 720 ? m + 1440 : m)
    }
}

// MARK: - Definitions

/// One habit the model knows.
public struct HabitDefinition: Equatable, Sendable {
    public let id: HabitId
    public let label: String
    public let kind: HabitKind
    /// Fixed per habit, never searched.
    public let primaryOutcome: HabitOutcome
    /// At most two; always exploratory.
    public let secondaryOutcomes: [HabitOutcome]
    /// Which way "better" is for the primary outcome.
    public let direction: EffectDirection
    /// The `HabitTrialCatalog` entry that tests this habit, if any.
    public let trialId: String?

    public init(id: HabitId, label: String, kind: HabitKind, primaryOutcome: HabitOutcome,
                secondaryOutcomes: [HabitOutcome] = [], trialId: String? = nil) {
        // A primary outcome that may not be primary is a programming error; fall back to HRV rather
        // than let an exploratory outcome acquire a label.
        let primary: HabitOutcome = primaryOutcome.canBePrimary ? primaryOutcome : .nightHrvLn
        self.id = id
        self.label = label
        self.kind = kind
        self.primaryOutcome = primary
        self.secondaryOutcomes = Array(secondaryOutcomes.filter { $0 != primary }.prefix(2))
        self.direction = primary.betterDirection
        self.trialId = trialId
    }
}

/// The fixed habit table (HEALTH_V2 §S1-A.2, "Primary outcome per habit").
public enum HabitCatalog {

    // Journal starters, by their canonical (stored, never localised) question text.
    public static let alcohol = HabitId("journal:alcohol")
    public static let lateCaffeineJournal = HabitId("journal:lateCaffeine")
    public static let screenInBed = HabitId("journal:screenInBed")
    public static let lateMeal = HabitId("journal:lateMeal")
    public static let stressed = HabitId("journal:stressed")
    public static let sauna = HabitId("journal:sauna")
    public static let sharedBed = HabitId("journal:sharedBed")
    public static let sick = HabitId("journal:sick")
    public static let magnesium = HabitId("journal:magnesium")
    public static let reading = HabitId("journal:reading")
    // Dream answers.
    public static let dreamScreen = HabitId("dream:screen")
    public static let dreamMeal = HabitId("dream:meal")
    // Derived.
    public static let lateWorkout = HabitId("auto:lateWorkout")
    public static let lateCaffeineAuto = HabitId("auto:lateCaffeine")
    public static let warmBedroom = HabitId("auto:warmBedroom")
    public static let breathingSession = HabitId("auto:breathingSession")
    public static let lightsDimmed = HabitId("auto:lightsDimmed")
    public static let bedtimeOnTarget = HabitId("auto:bedtimeOnTarget")

    /// The ten starter questions (`JournalCatalogStore.starterQuestions`), canonical text → habit id.
    public static let journalStarters: [String: HabitId] = [
        "Did you drink any alcohol?": alcohol,
        "Did you have caffeine late in the day?": lateCaffeineJournal,
        "Did you view a screen in bed?": screenInBed,
        "Did you eat close to bedtime?": lateMeal,
        "Did you feel stressed?": stressed,
        "Did you use a sauna?": sauna,
        "Did you share your bed?": sharedBed,
        "Did you feel sick or ill?": sick,
        "Did you take magnesium?": magnesium,
        "Did you read before bed?": reading,
    ]

    /// Journal questions that are OUTCOME-like self-reports (the dream journal's mirrored rows). They are
    /// never habits. `Screen before bed` / `Last meal before bed` are habits, but they enter through the
    /// dream store (`dream:screen` / `dream:meal`), so their mirrored journal rows are skipped too — one
    /// source per concern.
    public static let nonHabitJournalQuestions: Set<String> = [
        "Felt rested", "Night wakings (felt)", "Dream tone", "Dream recall", "Wake-up", "Dream",
        "Screen before bed", "Last meal before bed",
    ]

    /// Every fixed definition.
    public static let definitions: [HabitDefinition] = [
        HabitDefinition(id: alcohol, label: "Alcohol in the evening", kind: .behaviour,
                        primaryOutcome: .nightHrvLn, secondaryOutcomes: [.nightRhr, .totalSleepMin],
                        trialId: "alcoholFree"),
        HabitDefinition(id: lateCaffeineJournal, label: "Late caffeine (journal)", kind: .behaviour,
                        primaryOutcome: .totalSleepMin, secondaryOutcomes: [.onsetClockMin, .nightHrvLn],
                        trialId: "caffeineCutoff14"),
        HabitDefinition(id: lateCaffeineAuto, label: "Caffeine after 14:00 (caffeine log)", kind: .behaviour,
                        primaryOutcome: .totalSleepMin, secondaryOutcomes: [.onsetClockMin, .nightHrvLn],
                        trialId: "caffeineCutoff14"),
        HabitDefinition(id: screenInBed, label: "Screen in bed", kind: .behaviour,
                        primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin],
                        trialId: "screensOff60"),
        HabitDefinition(id: dreamScreen, label: "Screen < 30 min before sleep", kind: .behaviour,
                        primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin],
                        trialId: "screensOff60"),
        HabitDefinition(id: lateMeal, label: "Eating close to bedtime", kind: .behaviour,
                        primaryOutcome: .nightRhr, secondaryOutcomes: [.nightHrvLn],
                        trialId: "dinner3h"),
        HabitDefinition(id: dreamMeal, label: "Meal < 2 h before sleep", kind: .behaviour,
                        primaryOutcome: .nightRhr, secondaryOutcomes: [.nightHrvLn],
                        trialId: "dinner3h"),
        HabitDefinition(id: reading, label: "Reading before bed", kind: .behaviour,
                        primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin]),
        HabitDefinition(id: sauna, label: "Sauna", kind: .behaviour,
                        primaryOutcome: .nightRhr, secondaryOutcomes: [.nightHrvLn]),
        HabitDefinition(id: lateWorkout, label: "Workout ending < 3 h before sleep", kind: .behaviour,
                        primaryOutcome: .nightHrvLn, secondaryOutcomes: [.onsetClockMin]),
        HabitDefinition(id: warmBedroom, label: "Bedroom above 19.5 °C", kind: .behaviour,
                        primaryOutcome: .nightHrvLn, secondaryOutcomes: [.sleepEfficiency],
                        trialId: "bedroom18"),
        HabitDefinition(id: breathingSession, label: "Evening breathing session", kind: .behaviour,
                        primaryOutcome: .nightHrvLn, secondaryOutcomes: [.nightRhr],
                        trialId: "breathing10"),
        HabitDefinition(id: lightsDimmed, label: "Lights dimmed (wind-down)", kind: .behaviour,
                        primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin]),
        HabitDefinition(id: bedtimeOnTarget, label: "Asleep within 30 min of target", kind: .behaviour,
                        primaryOutcome: .totalSleepMin, secondaryOutcomes: [.nightHrvLn]),
        HabitDefinition(id: stressed, label: "Felt stressed", kind: .context, primaryOutcome: .nightHrvLn),
        HabitDefinition(id: sharedBed, label: "Shared bed", kind: .context, primaryOutcome: .nightHrvLn),
        HabitDefinition(id: sick, label: "Felt sick or ill", kind: .context, primaryOutcome: .nightHrvLn),
        HabitDefinition(id: magnesium, label: "Magnesium", kind: .supplement, primaryOutcome: .nightHrvLn),
    ]

    /// The definition for `id` among the fixed ones.
    public static func definition(_ id: HabitId) -> HabitDefinition? {
        definitions.first { $0.id == id }
    }

    /// The habit id a journal question maps to, or nil when the question is not a habit.
    public static func journalHabitId(question: String) -> HabitId? {
        if nonHabitJournalQuestions.contains(question) { return nil }
        if let starter = journalStarters[question] { return starter }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return HabitId("journal:" + trimmed)
    }

    /// A custom journal item: a behaviour whose primary outcome the wearer picked (default night HRV),
    /// with no secondaries and no trial.
    public static func custom(question: String, primary: HabitOutcome? = nil) -> HabitDefinition {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return HabitDefinition(id: HabitId("journal:" + text), label: text, kind: .behaviour,
                               primaryOutcome: primary ?? .nightHrvLn)
    }
}

// MARK: - Dichotomisation (absence is never "no")

/// Every source's rule for turning a record into yes / no / nothing. Nil means NO observation.
/// Cut points are fixed here and never chosen from data.
public enum HabitRules {

    /// A journal yes/no row. No row → nil.
    public static func journalBool(answeredYes: Bool?) -> ObservationState? {
        guard let answeredYes else { return nil }
        return answeredYes ? .yes : .no
    }

    /// A numeric journal item: > 0 → yes; exactly 0 AND entered (a row exists) → no; no row → nil.
    public static func journalNumeric(value: Double?) -> ObservationState? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value > 0 ? .yes : .no
    }

    /// Dream "Screen before bed", 1-based option as stored in the journal (1 "right up to sleep",
    /// 2 "under 30 minutes", 3 "30 to 60 minutes", 4 "over an hour"): 1–2 → yes, 3–4 → no.
    public static func dreamScreen(option: Int?) -> ObservationState? {
        guard let option else { return nil }
        switch option {
        case 1, 2: return .yes
        case 3, 4: return .no
        default: return nil
        }
    }

    /// Dream "Last meal before bed", 1-based (1 "within an hour", 2 "one to two hours", 3 "two to three
    /// hours", 4 "more than three"): 1–2 (within 2 h) → yes, 3–4 → no.
    public static func dreamMeal(option: Int?) -> ObservationState? {
        guard let option else { return nil }
        switch option {
        case 1, 2: return .yes
        case 3, 4: return .no
        default: return nil
        }
    }

    /// The late-caffeine cut: an intake after 14:00.
    public static let lateCaffeineMinute = 14 * 60

    /// `auto:lateCaffeine` from the day's last intake (minutes after that day's local midnight, may exceed
    /// 1440 for an after-midnight intake attributed to the evening — see `HabitNightKey.caffeineDay`).
    /// A day with no intake logged is nil: "no coffee" and "didn't log" look the same.
    public static func lateCaffeine(lastIntakeMinute: Int?) -> ObservationState? {
        guard let m = lastIntakeMinute else { return nil }
        return m > lateCaffeineMinute ? .yes : .no
    }

    /// `auto:lateWorkout`: yes if any session ENDS in the 3 hours before onset. Observed only on a night
    /// with an onset and with workout-table coverage for that day.
    public static func lateWorkout(workoutEndsEpochSec: [Int64], onsetEpochSec: Int64?,
                                   hasWorkoutCoverage: Bool) -> ObservationState? {
        guard let onset = onsetEpochSec, hasWorkoutCoverage else { return nil }
        let window = onset - 3 * 3600
        return workoutEndsEpochSec.contains { $0 > window && $0 <= onset } ? .yes : .no
    }

    /// The warm-bedroom cut (top of `ClimateAdvice`'s sleep band).
    public static let warmBedroomC = 19.5
    /// Minimum share of the 5-minute slots in the first 90 min after onset a sensor must cover.
    public static let climateMinCoverage = 0.6

    /// `auto:warmBedroom` from the mean temperature over the first 90 min after onset.
    public static func warmBedroom(meanC: Double?, slotCoverage: Double) -> ObservationState? {
        guard let meanC, meanC.isFinite, slotCoverage >= climateMinCoverage else { return nil }
        return meanC > warmBedroomC ? .yes : .no
    }

    /// `auto:breathingSession`: observed only while the wearer is "active" (≥ 1 session in the previous
    /// 14 days). Yes if a ≥ 5-min session ended between 17:00 and onset.
    public static func breathingSession(activeInLast14Days: Bool,
                                        sessions: [(endEpochSec: Int64, minutes: Double)],
                                        eveningStartEpochSec: Int64, onsetEpochSec: Int64?) -> ObservationState? {
        guard activeInLast14Days, let onset = onsetEpochSec else { return nil }
        let hit = sessions.contains { $0.minutes >= 5 && $0.endEpochSec >= eveningStartEpochSec && $0.endEpochSec <= onset }
        return hit ? .yes : .no
    }

    /// `auto:lightsDimmed` from the `wiz_winddown_ran` series: 1 → yes, 0 → no, no row → nil.
    public static func lightsDimmed(winddownRan: Double?) -> ObservationState? {
        guard let v = winddownRan else { return nil }
        if v == 1 { return .yes }
        if v == 0 { return .no }
        return nil
    }

    /// `auto:bedtimeOnTarget`: onset within ±30 min of the target (clock minutes, wrapping midnight).
    public static func bedtimeOnTarget(onsetMinute: Int?, targetMinute: Int?) -> ObservationState? {
        guard let onset = onsetMinute, let target = targetMinute else { return nil }
        let raw = abs(((onset - target) % 1440 + 1440) % 1440)
        let diff = Swift.min(raw, 1440 - raw)
        return diff <= 30 ? .yes : .no
    }
}

// MARK: - The keying rule

/// Everything is keyed to the night: the wake-day key of the night a behaviour precedes.
public enum HabitNightKey {

    /// Before this local minute, an event belongs to the PREVIOUS evening (still up after midnight).
    public static let eveningRolloverMinute = 4 * 60

    /// The night key for an event with an absolute time.
    ///
    /// - `localDay` / `localMinute`: the event's local calendar day and minute after local midnight.
    /// - `nightOnsets`: known nights as (night key, onset epoch seconds).
    ///
    /// Rule: the night whose onset is the first one at or after the event (within 20 h) — so an intake at
    /// 00:30 before a 01:15 onset belongs to that night. With no such session: an event before 04:00 is
    /// the previous evening's (night keyed `localDay`), anything later is the coming night (`localDay + 1`).
    public static func forEvent(epochSec: Int64, localDay: String, localMinute: Int,
                                nightOnsets: [(nightKey: String, onsetEpochSec: Int64)]) -> String? {
        let horizon = epochSec + 20 * 3600
        let next = nightOnsets
            .filter { $0.onsetEpochSec >= epochSec && $0.onsetEpochSec <= horizon }
            .min { $0.onsetEpochSec < $1.onsetEpochSec }
        if let next { return next.nightKey }
        return fallback(localDay: localDay, localMinute: localMinute)
    }

    /// The session-free rule on its own.
    public static func fallback(localDay: String, localMinute: Int) -> String? {
        localMinute < eveningRolloverMinute ? (HabitDay.epochDay(localDay) != nil ? localDay : nil)
                                            : HabitDay.adding(1, to: localDay)
    }

    /// The calendar day and minute a caffeine intake is SUMMARISED under: an intake before 04:00 is the
    /// previous day's evening, with its minute extended past 1440 (00:30 → 1470), so "the last intake of
    /// day D" means the last one before that night's sleep.
    public static func caffeineDay(localDay: String, localMinute: Int) -> (day: String, minute: Int)? {
        if localMinute < eveningRolloverMinute {
            guard let prev = HabitDay.adding(-1, to: localDay) else { return nil }
            return (prev, localMinute + 1440)
        }
        guard HabitDay.epochDay(localDay) != nil else { return nil }
        return (localDay, localMinute)
    }

    /// The night key a behaviour on evening `day` precedes: `day + 1`.
    public static func nightAfter(_ day: String) -> String? { HabitDay.adding(1, to: day) }
}

// MARK: - Ledger inputs

/// Everything the association analysis reads, already normalised. Built app-side by `HabitLedgerSource`.
public struct HabitLedgerInputs: Equatable, Sendable {
    public var observations: [HabitObservation]
    /// Outcome values in ANALYSIS units (HRV as ln RMSSD), keyed by night key.
    public var outcomes: [HabitOutcome: [String: Double]]
    /// Day Effort keyed by calendar day (any fixed linear scale; the fit is invariant to it).
    public var effortByDay: [String: Double]
    /// Custom definitions (wearer-created journal items) in addition to `HabitCatalog.definitions`.
    public var customDefinitions: [HabitDefinition]

    public init(observations: [HabitObservation], outcomes: [HabitOutcome: [String: Double]],
                effortByDay: [String: Double], customDefinitions: [HabitDefinition] = []) {
        self.observations = observations
        self.outcomes = outcomes
        self.effortByDay = effortByDay
        self.customDefinitions = customDefinitions
    }

    /// The fixed definitions plus any custom ones not already fixed.
    public var allDefinitions: [HabitDefinition] {
        var seen = Set(HabitCatalog.definitions.map { $0.id })
        var out = HabitCatalog.definitions
        for d in customDefinitions where !seen.contains(d.id) {
            out.append(d)
            seen.insert(d.id)
        }
        return out
    }

    /// Per habit, per night: the state. When two sources disagree on the same night (a journal "no" and
    /// a dream "yes" never share an id, but a duplicated journal row could), "yes" wins — the wearer
    /// reported the behaviour at least once.
    public func statesByHabit() -> [HabitId: [String: ObservationState]] {
        var out: [HabitId: [String: ObservationState]] = [:]
        for o in observations {
            var m = out[o.habit] ?? [:]
            if m[o.nightKey] != .yes { m[o.nightKey] = o.state }
            out[o.habit] = m
        }
        return out
    }
}
