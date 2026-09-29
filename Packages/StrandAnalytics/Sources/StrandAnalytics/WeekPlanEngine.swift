import Foundation

// WeekPlanEngine.swift — the weekly movement plan (HEALTH_V2 S3 §3.3–3.5).
//
// WHAT IT REPLACES. The day-by-day prescription (a population strain band plus gears scaled on medians)
// with a week-level plan that moves the wearer toward the ranges with the strongest health evidence:
//   * aerobic minutes toward the WHO 150–300 min/week range (Bull 2020), counted as `mvpaEq`
//     (moderate + 2 × vigorous, `SessionIntensity`), ramped from the wearer's OWN baseline;
//   * 2 strength sessions a week (WHO; Momma 2022), tied to `StrengthProgression` in the app;
//   * a step target from the wearer's own median toward the plateau of the dose-response (Paluch 2022),
//     ONLY when steps are reliable (the step gate);
//   * easy / hold weeks TRIGGERED BY DATA (the 7-day HRV tier, illness, sleep debt, load spikes,
//     monotony), never by a calendar (Coleman 2024 found no benefit of a fixed deload week);
//   * day guidance where the 7-day HRV trend and this morning's Charge MOVE a hard session and never
//     cancel a week (Plews 2013; Kiviniemi 2007; Vesterinen 2016; Javaloyes 2019).
//
// WHAT IT NEVER DOES:
//   * set a VO₂max, Fitness Age, strain or calorie target;
//   * show an ACWR "sweet spot" or an injury-risk figure (Impellizzeri 2020; Lolli 2019) — a big
//     week-to-week jump is stated plainly as a ramp note (Nielsen 2014), nothing more;
//   * invent state: a missing input abstains with a typed reason.
//
// FROZEN WEEKS. The plan is decided at the first open on or after Monday 04:00 local (the app computes
// the logical day) and then frozen: `plan(_:frozen:)` returns the stored plan for the week unchanged,
// so re-running mid-week can never move a target (tested).
//
// Pure, deterministic, DB-free, `yyyy-MM-dd` strings and plain numbers only. Swift-only engine; a Kotlin
// twin can be added later without changing results.

// MARK: - Inputs

/// One local day of activity as the plan reads it. Every field is optional where the data can be absent;
/// nil is "unknown", never zero.
public struct DayActivity: Codable, Equatable, Sendable {
    public let day: String
    /// WHO-equivalent aerobic minutes inside recorded sessions (moderate + 2 × vigorous). nil = unknown
    /// (the day's intensity abstained). A worn day with no session is 0.
    public let mvpaEq: Double?
    public let moderateMin: Double?
    public let vigorousMin: Double?
    public let hardSession: Bool?
    public let strengthSession: Bool?
    /// The day's step total, whatever its provenance.
    public let steps: Double?
    /// Whether `steps` is a measurement (calibrated counter, phone, or a fitted 4.0 estimate ≥ building).
    public let stepsReliable: Bool
    /// Linear TRIMP for the day (Effort taken back through `StrainScorer.strainToTRIMP`).
    public let trimp: Double?
    /// Fraction of the day the strap was worn (0–1).
    public let wearCoverage: Double?
    /// Sessions that had no heart rate (counted, no minutes).
    public let unmeasuredSessions: Int
    /// Minutes partly from imported zones ("≈").
    public let approximate: Bool

    public init(day: String, mvpaEq: Double? = nil, moderateMin: Double? = nil, vigorousMin: Double? = nil,
                hardSession: Bool? = nil, strengthSession: Bool? = nil, steps: Double? = nil,
                stepsReliable: Bool = false, trimp: Double? = nil, wearCoverage: Double? = nil,
                unmeasuredSessions: Int = 0, approximate: Bool = false) {
        self.day = day
        self.mvpaEq = mvpaEq
        self.moderateMin = moderateMin
        self.vigorousMin = vigorousMin
        self.hardSession = hardSession
        self.strengthSession = strengthSession
        self.steps = steps
        self.stepsReliable = stepsReliable
        self.trimp = trimp
        self.wearCoverage = wearCoverage
        self.unmeasuredSessions = unmeasuredSessions
        self.approximate = approximate
    }
}

/// Everything the week decision reads. Assembled by `WeekPlanSource` in the app.
public struct WeekPlanInputs: Equatable, Sendable {
    /// The LOGICAL local day the decision is made on (the day rolls at 04:00, not midnight).
    public let today: String
    /// The last ≥ 42 days of activity (any order; duplicates: the last one wins).
    public let days: [DayActivity]
    /// This morning's 7-day HRV tier (`HRVReadiness.evaluate`), nil below 14 valid nights.
    public let hrvTier: ReadinessTier?
    /// The tier on each of the last 7 days, oldest → newest (nil = no reading that day).
    public let hrvTierLast7: [ReadinessTier?]
    /// Valid HRV nights banked so far (for the "calibrating (n of 14 nights)" line).
    public let hrvValidNights: Int
    /// This morning's Charge (0–100), nil when no reading.
    public let charge: Double?
    /// Local days on which the illness heads-up was raised (the app keeps this history).
    public let illnessRaisedDays: [String]
    /// The heads-up is up right now.
    public let illnessRaisedNow: Bool
    /// Current sleep-debt balance in minutes (≥ 0), nil when not computable.
    public let sleepDebtMin: Double?
    /// Age in years, nil when unknown.
    public let age: Int?

    public init(today: String, days: [DayActivity], hrvTier: ReadinessTier?, hrvTierLast7: [ReadinessTier?],
                hrvValidNights: Int, charge: Double?, illnessRaisedDays: [String], illnessRaisedNow: Bool,
                sleepDebtMin: Double?, age: Int?) {
        self.today = today
        self.days = days
        self.hrvTier = hrvTier
        self.hrvTierLast7 = hrvTierLast7
        self.hrvValidNights = hrvValidNights
        self.charge = charge
        self.illnessRaisedDays = illnessRaisedDays
        self.illnessRaisedNow = illnessRaisedNow
        self.sleepDebtMin = sleepDebtMin
        self.age = age
    }
}

// MARK: - Outputs

public enum WeekType: String, Codable, Equatable, Sendable {
    case build, hold, easy
}

/// Why the week got its type. A code plus the number behind it, so the card can say exactly what fired.
public struct WeekTypeReason: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        /// (a) the 7-day HRV tier was suppressed on ≥ 5 of the last 7 days. value = days.
        case hrvSuppressed
        /// (b) the illness heads-up was raised in the last 3 days.
        case illnessRecent
        /// (c) sleep debt ≥ 180 min at week start. value = minutes.
        case sleepDebt
        /// (d) three build weeks in a row, all met — an easy week OFFERED (accepted when the plan is easy).
        case buildStreak
        /// hold: baseline at the top of the WHO range. value = baseline minutes.
        case topOfRange
        /// hold: last week's load > 1.3 × the 4-week mean. value = ratio.
        case loadSpike
        /// hold: Foster monotony ≥ 2.0 last week. value = monotony.
        case monotony
    }
    public let code: Code
    public let value: Double?

    public init(_ code: Code, _ value: Double? = nil) {
        self.code = code
        self.value = value
    }

    /// The line the card and the detail view show (English; the app localises in its integration pass).
    public var text: String {
        switch code {
        case .hrvSuppressed:
            return "your 7-day HRV has been below your normal range for \(Int(value ?? 0)) days"
        case .illnessRecent:
            return "the illness heads-up was raised in the last 3 days"
        case .sleepDebt:
            return "you are carrying about \(Int(((value ?? 0) / 60).rounded())) h of sleep debt"
        case .buildStreak:
            return "three build weeks met in a row — a lighter week is common coaching practice; direct "
                + "evidence that it improves results is limited"
        case .topOfRange:
            return "you are already at the top of the WHO range — more is fine but not needed for health"
        case .loadSpike:
            return "last week was well above your usual load"
        case .monotony:
            return "last week's load was very similar every day"
        }
    }

    /// The evidence note shown in the detail view (HEALTH_V2 §3.3 table).
    public var evidenceNote: String? {
        switch code {
        case .hrvSuppressed, .illnessRecent, .sleepDebt:
            return "This comes from your body's own signals."
        case .buildStreak:
            return "A lighter week is common coaching practice; direct evidence that it improves results is limited."
        case .loadSpike, .monotony:
            return "Big week-to-week jumps have been linked to more injuries in new runners."
        case .topOfRange:
            return nil
        }
    }
}

/// Strength sessions for the week, tied to `StrengthProgression` in the app.
public struct StrengthTarget: Codable, Equatable, Sendable {
    public let minSessions: Int
    public let maxSessions: Int
    /// Easy week: keep loads where they are (the card shows "hold loads" on the progression).
    public let holdLoads: Bool
    /// Share of the usual sets (easy week ≈ two-thirds).
    public let setsFactor: Double

    public init(minSessions: Int, maxSessions: Int, holdLoads: Bool, setsFactor: Double) {
        self.minSessions = minSessions
        self.maxSessions = maxSessions
        self.holdLoads = holdLoads
        self.setsFactor = setsFactor
    }
}

/// The step reliability gate (§3.4).
public struct StepGate: Codable, Equatable, Sendable {
    public let passed: Bool
    public let reliableDays: Int
    public let windowDays: Int
}

/// An easy week offered after a build streak (reason (d)). Declining is never penalised.
public enum EasyOfferState: String, Codable, Equatable, Sendable {
    case offered, accepted, declined
}

/// The frozen plan for one Monday–Sunday week.
public struct WeekPlan: Codable, Equatable, Sendable {
    /// Bumped when the decision rules change; a plan from an older version is still shown as frozen.
    public static let currentVersion = 1

    public let version: Int
    /// Monday, `yyyy-MM-dd`.
    public let weekStart: String
    /// The logical day it was decided on.
    public let decidedOn: String
    public var type: WeekType
    public var reasons: [WeekTypeReason]
    /// b: mean weekly `mvpaEq` over the valid baseline weeks; nil while calibrating.
    public let baselineMvpa: Double?
    /// How many of the last 4 complete weeks were valid (≥ 5 days with wear ≥ 0.7). Needs 3.
    public let validBaselineWeeks: Int
    public let chronicLoad: Double?
    public let lastWeekLoad: Double?
    public let monotony: Double?
    /// Weekly aerobic target in `mvpaEq` minutes; nil while calibrating (the card shows the WHO range).
    public var aerobicTarget: Double?
    public var hardSessionTarget: Int
    /// The one hard session is offered as optional (first time the base allows one).
    public var hardSessionOptional: Bool
    public var strength: StrengthTarget
    /// Steps/day target; nil when the step gate is not met.
    public var stepsTarget: Double?
    public let stepsMedian: Double?
    public let stepsPlateau: Double
    public let ageKnown: Bool
    public let stepGate: StepGate
    public var easyOffer: EasyOfferState?

    /// Sunday of the week.
    public var weekEnd: String { WeeklyDigestEngine.addDays(weekStart, 6) }
    /// Personal target exists (the baseline is established).
    public var isCalibrating: Bool { baselineMvpa == nil }
}

/// The day's guidance (§3.5). Consumed by the week card's day line, the quest layer
/// (`WeekPlanQuestBridge`) and the coach's week line.
public struct DayGuidance: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case rest, easy, moveHard, asPlanned
    }
    public enum Note: String, Codable, Equatable, Sendable {
        case illness, easyWeek, hrvSuppressed, chargeLow, sleepDebt, hrvCalibrating, noReading
    }
    public let day: String
    public let kind: Kind
    public let notes: [Note]
    /// Valid HRV nights so far (for the calibrating line).
    public let hrvNights: Int
    public let charge: Double?

    public init(day: String, kind: Kind, notes: [Note], hrvNights: Int, charge: Double?) {
        self.day = day
        self.kind = kind
        self.notes = notes
        self.hrvNights = hrvNights
        self.charge = charge
    }

    /// Hard sessions are not advised today.
    public var hardSessionAdvised: Bool { kind == .asPlanned }
    /// A gear factor above 1.0 on training is allowed today (acceptance 4: never on easy/rest/moveHard).
    public var allowsTrainingFactorAboveOne: Bool { kind == .asPlanned }

    /// The day line on the week card.
    public var line: String {
        switch kind {
        case .rest:
            return "Rest — body off baseline."
        case .easy:
            return "Easy movement only today."
        case .moveHard:
            if notes.contains(.hrvSuppressed) { return "Move today's hard session — HRV below your range." }
            return "Move today's hard session — Charge is low this morning."
        case .asPlanned:
            if notes.contains(.noReading) { return "As planned." }
            return "As planned. A harder session fits today."
        }
    }

    /// The qualifier lines (calibrating HRV, no reading).
    public var qualifiers: [String] {
        var out: [String] = []
        if notes.contains(.hrvCalibrating) {
            out.append("HRV trend still calibrating (\(min(hrvNights, HRVReadiness.minNights)) of "
                + "\(HRVReadiness.minNights) nights)")
        }
        if notes.contains(.noReading) { out.append("No reading this morning") }
        return out
    }
}

/// The live state of the current week (recomputed on every refresh; never frozen).
public struct WeekProgress: Equatable, Sendable {
    public let weekStart: String
    public let today: String
    public let aerobicDone: Double
    public let moderateMin: Double
    public let vigorousMin: Double
    public let hardSessionsDone: Int
    public let strengthDone: Int
    public let unmeasuredSessions: Int
    public let approximate: Bool
    /// Mean of this week's reliable daily step totals so far, nil when none.
    public let stepsMeanReliable: Double?
    public let loadSoFar: Double?
    /// "This week is already well above your usual load — keep the rest easy." No push, ever.
    public let midWeekLoadNote: Bool
}

// MARK: - Engine

public enum WeekPlanEngine {

    // MARK: Constants (each with its reason)

    /// WHO lower edge of the aerobic range (min/week, moderate-equivalent).
    public static let whoLow: Double = 150
    /// WHO upper edge. Mortality benefit keeps rising past it but plateaus around 3–5× the minimum (Arem
    /// 2015), so the plan never pushes past 300 — more is the wearer's choice, not a prescription.
    public static let whoHigh: Double = 300
    /// Build ramp under the WHO minimum: +10 % of baseline, but at least +20 min so a beginner at 0 gets
    /// a real first step (two 10-min walks at moderate pace).
    public static let rampFraction: Double = 0.10
    public static let rampFloorMin: Double = 20
    /// Ramp guard: a build target never exceeds max(1.3 b, b + 20). 1.3 is the ~30 % week-over-week
    /// increase above which novice runners had more injuries (Nielsen 2014); +20 lets a beginner start.
    public static let rampCapFactor: Double = 1.3
    /// Easy-week aerobic target: 60 % of baseline — enough to keep the habit, clearly lighter.
    public static let easyAerobicFactor: Double = 0.6
    /// Easy-week strength: about two-thirds of the usual sets, loads held.
    public static let easySetsFactor: Double = 2.0 / 3.0

    /// Baseline weeks looked back over, and how many must be valid.
    public static let baselineWeeks: Int = 4
    public static let minValidWeeks: Int = 3
    /// A week is valid with ≥ 5 days of ≥ 70 % wear: otherwise "no sessions" cannot be told from "not worn".
    public static let minWornDaysPerWeek: Int = 5
    public static let minWearCoverage: Double = 0.7

    /// Load spike: last week's load above 1.3 × the 4-week mean (same 30 % line as the ramp guard).
    public static let loadSpikeRatio: Double = 1.3
    /// Foster monotony (mean / SD of daily load over a week) at/above 2.0 — the same line `ReadinessEngine`
    /// uses, here computed on LINEAR load, needing ≥ 4 days.
    public static let monotonyHold: Double = 2.0
    public static let monotonyMinDays: Int = 4

    /// Easy trigger (a): suppressed on ≥ 5 of the last 7 days — a sustained trend, not one bad night.
    public static let suppressedDaysForEasy: Int = 5
    /// Easy trigger (b): the illness heads-up within the last 3 days.
    public static let illnessLookbackDays: Int = 3
    /// Easy trigger (c): ≥ 3 h of sleep debt at week start — the level at which adding load competes
    /// with recovery the wearer already owes.
    public static let sleepDebtEasyMin: Double = 180
    /// Easy trigger (d): this many consecutive build weeks, each met at ≥ 90 %.
    public static let buildStreakWeeks: Int = 3

    /// Day guidance: Charge below this is a low morning. `QuestTriggers.chargeLow` (34) — the app's one
    /// low-charge line, so the plan, the quests and the coach agree.
    public static var chargeLow: Double { QuestTriggers.chargeLow }
    /// Day guidance: ≥ 2 h of debt together with a suppressed tier turns the day easy.
    public static let sleepDebtEasyDayMin: Double = 120

    /// Steps: +1000/day per week toward the plateau (Paluch 2022: the largest gains are at the low end).
    public static let stepIncrement: Double = 1000
    /// Plateau lower edges (Paluch 2022): 8,000 under 60, 7,000 at 60+ or when age is unknown.
    public static let plateauUnder60: Double = 8000
    public static let plateau60Plus: Double = 7000
    /// Step gate: ≥ 70 % of the last 28 days reliable, and ≥ 14 reliable days.
    public static let stepWindowDays: Int = 28
    public static let stepMinReliableFraction: Double = 0.7
    public static let stepMinReliableDays: Int = 14

    /// Hard sessions: none while b < 150 (build the base first; vigorous minutes still count), at most 2.
    public static let maxHardSessions: Int = 2

    // MARK: Rounding

    static func round5(_ x: Double) -> Double { (x / 5).rounded() * 5 }
    static func floor5(_ x: Double) -> Double { (x / 5).rounded(.down) * 5 }
    static func round250(_ x: Double) -> Double { (x / 250).rounded() * 250 }

    // MARK: Day helpers

    /// Monday of the week containing `day`.
    public static func weekStart(of day: String) -> String? { WeeklyDigestEngine.mondayOfWeek(containing: day) }

    static func index(_ days: [DayActivity]) -> [String: DayActivity] {
        var out: [String: DayActivity] = [:]
        for d in days { out[d.day] = d }
        return out
    }

    static func weekDays(_ start: String) -> [String] { (0..<7).map { WeeklyDigestEngine.addDays(start, $0) } }

    /// Monday of each of the `n` complete weeks before `weekStart`, newest first.
    static func previousWeekStarts(_ weekStart: String, _ n: Int) -> [String] {
        (1...max(1, n)).map { WeeklyDigestEngine.addDays(weekStart, -7 * $0) }
    }

    // MARK: Baseline

    /// Whether a week has enough wear to count as a baseline week.
    static func isValidWeek(_ start: String, _ byDay: [String: DayActivity]) -> Bool {
        let worn = weekDays(start).filter { (byDay[$0]?.wearCoverage ?? 0) >= minWearCoverage }.count
        return worn >= minWornDaysPerWeek
    }

    /// Σ mvpaEq over a week (unknown days add nothing).
    static func weekMvpa(_ start: String, _ byDay: [String: DayActivity]) -> Double {
        weekDays(start).reduce(0) { $0 + (byDay[$1]?.mvpaEq ?? 0) }
    }

    /// b and how many valid weeks backed it. b is nil below `minValidWeeks` (calibrating).
    public static func baseline(days: [DayActivity], weekStart: String) -> (b: Double?, validWeeks: Int) {
        let byDay = index(days)
        let valid = previousWeekStarts(weekStart, baselineWeeks).filter { isValidWeek($0, byDay) }
        guard valid.count >= minValidWeeks else { return (nil, valid.count) }
        let b = valid.map { weekMvpa($0, byDay) }.reduce(0, +) / Double(valid.count)
        return (b, valid.count)
    }

    // MARK: Load

    /// Σ linear TRIMP over a week, nil with fewer than 5 days of load.
    static func weekLoad(_ start: String, _ byDay: [String: DayActivity]) -> Double? {
        let loads = weekDays(start).compactMap { byDay[$0]?.trimp }
        guard loads.count >= minWornDaysPerWeek else { return nil }
        return loads.reduce(0, +)
    }

    /// Chronic = mean weekly load over the last 4 complete weeks (≥ 3 with enough load), and last week's.
    public static func load(days: [DayActivity], weekStart: String) -> (chronic: Double?, lastWeek: Double?) {
        let byDay = index(days)
        let starts = previousWeekStarts(weekStart, baselineWeeks)
        let loads = starts.compactMap { weekLoad($0, byDay) }
        let chronic: Double? = loads.count >= minValidWeeks ? loads.reduce(0, +) / Double(loads.count) : nil
        return (chronic, weekLoad(starts[0], byDay))
    }

    /// Foster monotony over one week of daily linear load: mean / SD, nil below 4 days or with SD 0.
    public static func monotony(dailyLoads: [Double]) -> Double? {
        guard dailyLoads.count >= monotonyMinDays else { return nil }
        let n = Double(dailyLoads.count)
        let mean = dailyLoads.reduce(0, +) / n
        let ss = dailyLoads.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let sd = (ss / (n - 1)).squareRoot()
        guard sd > 0 else { return nil }
        return mean / sd
    }

    // MARK: Aerobic target

    /// The build-week target for baseline b (§3.3 table), with the ramp guard enforced after rounding.
    public static func buildAerobicTarget(b: Double) -> Double {
        let base = max(0, b)
        let raw: Double
        if base < whoLow {
            raw = min(whoLow, base + max(rampFloorMin, rampFraction * base))
        } else {
            raw = min(whoHigh, (1 + rampFraction) * base)
        }
        let cap = min(whoHigh, max(rampCapFactor * base, base + rampFloorMin))
        var t = round5(raw)
        if t > cap { t = floor5(cap) }
        return t
    }

    public static func aerobicTarget(type: WeekType, b: Double?) -> Double? {
        guard let b else { return nil }
        switch type {
        case .build: return buildAerobicTarget(b: b)
        case .hold: return round5(max(0, b))
        case .easy: return round5(easyAerobicFactor * max(0, b))
        }
    }

    // MARK: Steps

    public static func plateau(age: Int?) -> Double {
        guard let age, age > 0 else { return plateau60Plus }
        return age < 60 ? plateauUnder60 : plateau60Plus
    }

    /// The step gate over the `stepWindowDays` days before `today`.
    public static func stepGate(days: [DayActivity], today: String) -> StepGate {
        let byDay = index(days)
        let window = (1...stepWindowDays).map { WeeklyDigestEngine.addDays(today, -$0) }
        let reliable = window.filter { d in
            guard let a = byDay[d], a.stepsReliable, a.steps != nil else { return false }
            return true
        }.count
        let passed = Double(reliable) >= stepMinReliableFraction * Double(stepWindowDays)
            && reliable >= stepMinReliableDays
        return StepGate(passed: passed, reliableDays: reliable, windowDays: stepWindowDays)
    }

    /// Median of the reliable step days in the gate window.
    public static func stepsMedian(days: [DayActivity], today: String) -> Double? {
        let byDay = index(days)
        let window = (1...stepWindowDays).map { WeeklyDigestEngine.addDays(today, -$0) }
        let xs = window.compactMap { d -> Double? in
            guard let a = byDay[d], a.stepsReliable else { return nil }
            return a.steps
        }.sorted()
        guard !xs.isEmpty else { return nil }
        let mid = xs.count / 2
        return xs.count % 2 == 1 ? xs[mid] : (xs[mid - 1] + xs[mid]) / 2
    }

    /// Steps/day target from the reliable median m (same in build, hold and easy: walking is compatible
    /// with recovery). Below the plateau: +1000 toward it, never more than +1000 above last week's target.
    /// At/above it: hold at m — no step-up past the plateau.
    public static func stepsTarget(median m: Double, plateau p: Double, lastWeekTarget: Double?) -> Double {
        guard m < p else { return round250(m) }
        var t = min(p, round250(m + stepIncrement))
        if let last = lastWeekTarget { t = min(t, last + stepIncrement) }
        return t
    }

    // MARK: Week type

    /// Days (in the illness lookback) with the heads-up raised, inclusive of `today`.
    static func illnessRecent(_ inputs: WeekPlanInputs) -> Bool {
        if inputs.illnessRaisedNow { return true }
        let window = Set((0..<illnessLookbackDays).map { WeeklyDigestEngine.addDays(inputs.today, -$0) })
        return inputs.illnessRaisedDays.contains { window.contains($0) }
    }

    static func illnessInLast7(_ inputs: WeekPlanInputs) -> Bool {
        if inputs.illnessRaisedNow { return true }
        let window = Set((0..<7).map { WeeklyDigestEngine.addDays(inputs.today, -$0) })
        return inputs.illnessRaisedDays.contains { window.contains($0) }
    }

    /// Whether the last `buildStreakWeeks` frozen plans were all `build` and each met every target at
    /// ≥ 90 % (reason (d)).
    static func buildStreakMet(weekStart: String, frozen: [WeekPlan], days: [DayActivity],
                               guidance: [String: DayGuidance.Kind]) -> Bool {
        let starts = previousWeekStarts(weekStart, buildStreakWeeks)
        for s in starts {
            guard let p = frozen.first(where: { $0.weekStart == s }), p.type == .build else { return false }
            let parts = WeekReview.planVsDone(plan: p, days: days, guidanceByDay: guidance, liftDataFresh: true)
            let asked = parts.filter { $0.status != .notAsked }
            guard !asked.isEmpty, asked.allSatisfy({ $0.status == .met }) else { return false }
        }
        return true
    }

    /// Decide a fresh plan for the week containing `inputs.today` (no freezing — see `plan(_:frozen:)`).
    public static func decide(_ inputs: WeekPlanInputs, frozen: [WeekPlan] = [],
                              guidanceHistory: [String: DayGuidance.Kind] = [:]) -> WeekPlan {
        let start = weekStart(of: inputs.today) ?? inputs.today
        let (b, validWeeks) = baseline(days: inputs.days, weekStart: start)
        let (chronic, lastLoad) = load(days: inputs.days, weekStart: start)
        let byDay = index(inputs.days)
        let lastWeekLoads = weekDays(WeeklyDigestEngine.addDays(start, -7)).compactMap { byDay[$0]?.trimp }
        let mono = monotony(dailyLoads: lastWeekLoads)

        // Easy triggers (a)–(c): the body's own signals.
        var easyReasons: [WeekTypeReason] = []
        let suppressed = inputs.hrvTierLast7.suffix(7).filter { $0 == .suppressed }.count
        if suppressed >= suppressedDaysForEasy && !illnessInLast7(inputs) {
            easyReasons.append(WeekTypeReason(.hrvSuppressed, Double(suppressed)))
        }
        if illnessRecent(inputs) { easyReasons.append(WeekTypeReason(.illnessRecent)) }
        if let debt = inputs.sleepDebtMin, debt >= sleepDebtEasyMin {
            easyReasons.append(WeekTypeReason(.sleepDebt, debt))
        }

        let type: WeekType
        var reasons: [WeekTypeReason]
        var offer: EasyOfferState? = nil
        if !easyReasons.isEmpty {
            type = .easy
            reasons = easyReasons
        } else {
            var holdReasons: [WeekTypeReason] = []
            if let b, b >= whoHigh { holdReasons.append(WeekTypeReason(.topOfRange, b)) }
            if let chronic, chronic > 0, let lastLoad, lastLoad > loadSpikeRatio * chronic {
                holdReasons.append(WeekTypeReason(.loadSpike, lastLoad / chronic))
            }
            if let mono, mono >= monotonyHold { holdReasons.append(WeekTypeReason(.monotony, mono)) }
            if !holdReasons.isEmpty {
                type = .hold
                reasons = holdReasons
            } else {
                type = .build
                reasons = []
                // (d): OFFERED, never imposed. The plan stays a build week until the wearer accepts.
                if buildStreakMet(weekStart: start, frozen: frozen, days: inputs.days, guidance: guidanceHistory) {
                    offer = .offered
                    reasons = [WeekTypeReason(.buildStreak)]
                }
            }
        }

        // Steps.
        let gate = stepGate(days: inputs.days, today: inputs.today)
        let median = gate.passed ? stepsMedian(days: inputs.days, today: inputs.today) : nil
        let p = plateau(age: inputs.age)
        let lastTarget = frozen.first(where: { $0.weekStart == WeeklyDigestEngine.addDays(start, -7) })?.stepsTarget
        let steps = median.map { stepsTarget(median: $0, plateau: p, lastWeekTarget: lastTarget) }

        var plan = WeekPlan(
            version: WeekPlan.currentVersion, weekStart: start, decidedOn: inputs.today, type: type,
            reasons: reasons, baselineMvpa: b, validBaselineWeeks: validWeeks, chronicLoad: chronic,
            lastWeekLoad: lastLoad, monotony: mono, aerobicTarget: nil, hardSessionTarget: 0,
            hardSessionOptional: false,
            strength: StrengthTarget(minSessions: 2, maxSessions: 2, holdLoads: false, setsFactor: 1),
            stepsTarget: steps, stepsMedian: median, stepsPlateau: p, ageKnown: (inputs.age ?? 0) > 0,
            stepGate: gate, easyOffer: offer)
        applyTargets(&plan, days: inputs.days)
        return plan
    }

    /// Fill the aerobic, hard-session and strength targets for the plan's current type.
    static func applyTargets(_ plan: inout WeekPlan, days: [DayActivity]) {
        let byDay = index(days)
        let prev = previousWeekStarts(plan.weekStart, baselineWeeks)
        let b = plan.baselineMvpa
        plan.aerobicTarget = aerobicTarget(type: plan.type, b: b)

        // Hard sessions: mean hard days per week over the last 4 weeks.
        let hardDays = prev.flatMap { weekDays($0) }.filter { byDay[$0]?.hardSession == true }.count
        let meanHard = Double(hardDays) / Double(baselineWeeks)
        var hard = 0
        var optional = false
        if plan.type != .easy, let b, b >= whoLow {
            hard = min(maxHardSessions, Int(meanHard.rounded()))
            if hard == 0 && plan.type == .build {
                // Base established for 3 weeks running and never a hard session: offer one, optional.
                let lastThree = previousWeekStarts(plan.weekStart, 3)
                if lastThree.allSatisfy({ isValidWeek($0, byDay) && weekMvpa($0, byDay) >= whoLow }) {
                    hard = 1
                    optional = true
                }
            }
        }
        plan.hardSessionTarget = hard
        plan.hardSessionOptional = optional

        // Strength: 2 (WHO), stepping in at 1 while the wearer averages < 1 a week.
        let strengthDays = prev.flatMap { weekDays($0) }.filter { byDay[$0]?.strengthSession == true }.count
        let meanStrength = Double(strengthDays) / Double(baselineWeeks)
        switch plan.type {
        case .build, .hold:
            // Hold uses the same ramp as build: a hold week is about aerobic load, and asking a wearer who
            // does not lift for two sessions at once would be the spike the plan exists to avoid.
            let n = meanStrength < 1 ? 1 : 2
            plan.strength = StrengthTarget(minSessions: n, maxSessions: n, holdLoads: false, setsFactor: 1)
        case .easy:
            plan.strength = StrengthTarget(minSessions: 1, maxSessions: 2, holdLoads: true,
                                           setsFactor: easySetsFactor)
        }
    }

    /// The week's plan: the frozen one when it exists, else a fresh decision. Re-running mid-week never
    /// changes a frozen plan.
    public static func plan(_ inputs: WeekPlanInputs, frozen: [WeekPlan],
                            guidanceHistory: [String: DayGuidance.Kind] = [:]) -> WeekPlan {
        let start = weekStart(of: inputs.today) ?? inputs.today
        if let existing = frozen.first(where: { $0.weekStart == start }) { return existing }
        return decide(inputs, frozen: frozen, guidanceHistory: guidanceHistory)
    }

    /// The wearer's answer to an offered easy week. Accept → easy targets (aerobic 0.6 b, strength held);
    /// decline → the build plan unchanged. Neither records anything the penalty layer reads.
    public static func respond(to plan: WeekPlan, accept: Bool, days: [DayActivity]) -> WeekPlan {
        guard plan.easyOffer == .offered else { return plan }
        var p = plan
        if accept {
            p.easyOffer = .accepted
            p.type = .easy
            applyTargets(&p, days: days)
        } else {
            p.easyOffer = .declined
        }
        return p
    }

    // MARK: Day guidance

    /// This morning's guidance (§3.5). First matching rule wins:
    ///   rest     — illness heads-up raised;
    ///   easy     — easy week, or (tier suppressed and (Charge low or debt ≥ 120 min));
    ///   moveHard — tier suppressed, or Charge low;
    ///   asPlanned — otherwise.
    /// Missing inputs never invent state: no tier ⇒ Charge only (+ "calibrating n of 14"); no tier and no
    /// Charge ⇒ asPlanned + "No reading this morning".
    public static func guidance(day: String, weekType: WeekType?, hrvTier: ReadinessTier?, hrvValidNights: Int,
                                charge: Double?, illnessRaised: Bool, sleepDebtMin: Double?) -> DayGuidance {
        var notes: [DayGuidance.Note] = []
        if hrvTier == nil { notes.append(.hrvCalibrating) }
        if hrvTier == nil && charge == nil { notes.append(.noReading) }

        let suppressed = hrvTier == .suppressed
        let low = charge.map { $0 < chargeLow } ?? false
        let debt = (sleepDebtMin ?? 0) >= sleepDebtEasyDayMin

        let kind: DayGuidance.Kind
        if illnessRaised {
            kind = .rest
            notes.append(.illness)
        } else if weekType == .easy || (suppressed && (low || debt)) {
            kind = .easy
            if weekType == .easy { notes.append(.easyWeek) }
            if suppressed { notes.append(.hrvSuppressed) }
            if low { notes.append(.chargeLow) }
            if suppressed && debt { notes.append(.sleepDebt) }
        } else if suppressed || low {
            kind = .moveHard
            if suppressed { notes.append(.hrvSuppressed) }
            if low { notes.append(.chargeLow) }
        } else {
            kind = .asPlanned
        }
        return DayGuidance(day: day, kind: kind, notes: notes, hrvNights: hrvValidNights, charge: charge)
    }

    // MARK: Progress

    public static func progress(plan: WeekPlan, days: [DayActivity], today: String) -> WeekProgress {
        let byDay = index(days)
        let elapsed = weekDays(plan.weekStart).filter { $0 <= today }
        let acts = elapsed.compactMap { byDay[$0] }
        let aerobic = acts.reduce(0) { $0 + ($1.mvpaEq ?? 0) }
        let moderate = acts.reduce(0) { $0 + ($1.moderateMin ?? 0) }
        let vigorous = acts.reduce(0) { $0 + ($1.vigorousMin ?? 0) }
        let hard = acts.filter { $0.hardSession == true }.count
        let strength = acts.filter { $0.strengthSession == true }.count
        let unmeasured = acts.reduce(0) { $0 + $1.unmeasuredSessions }
        let approx = acts.contains { $0.approximate }
        let steps = acts.compactMap { a -> Double? in a.stepsReliable ? a.steps : nil }
        let stepsMean = steps.isEmpty ? nil : steps.reduce(0, +) / Double(steps.count)
        let loads = acts.compactMap { $0.trimp }
        let loadSoFar = loads.isEmpty ? nil : loads.reduce(0, +)
        let isSunday = today == plan.weekEnd
        var note = false
        if !isSunday, let chronic = plan.chronicLoad, chronic > 0, let l = loadSoFar, l > loadSpikeRatio * chronic {
            note = true
        }
        return WeekProgress(weekStart: plan.weekStart, today: today, aerobicDone: aerobic, moderateMin: moderate,
                            vigorousMin: vigorous, hardSessionsDone: hard, strengthDone: strength,
                            unmeasuredSessions: unmeasured, approximate: approx, stepsMeanReliable: stepsMean,
                            loadSoFar: loadSoFar, midWeekLoadNote: note)
    }

    /// The "Optimum reached" trigger from the week plan (HEALTH_V2 S0 H2(b)/(c)), replacing the population
    /// strain band: due only on an `easy` or `moveHard` day, once today's linear load exceeds an easy day's
    /// share of the wearer's own usual week — `chronic / 7 × easyAerobicFactor`. Never on a `rest` day (the
    /// illness banner carries that day) and never without a chronic load to compare against.
    public static func optimumNoticeDue(plan: WeekPlan?, guidance: DayGuidance?, todayLoad: Double?) -> Bool {
        guard let g = guidance, g.kind == .easy || g.kind == .moveHard,
              let chronic = plan?.chronicLoad, chronic > 0, let load = todayLoad else { return false }
        return load > chronic / 7 * easyAerobicFactor
    }

    /// The mid-week load line (§3.3). No push notification.
    public static let midWeekLoadLine = "This week is already well above your usual load — keep the rest easy."

    /// Header line of the card, e.g. "BUILD WEEK" / "EASY WEEK — <reason>".
    public static func header(_ plan: WeekPlan) -> String {
        let name: String
        switch plan.type {
        case .build: name = "BUILD WEEK"
        case .hold: name = "HOLD WEEK"
        case .easy: name = "EASY WEEK"
        }
        guard plan.type != .build, let first = plan.reasons.first else { return name }
        return name + " — " + first.text
    }
}

// MARK: - Quest bridge

/// How the week plan constrains the quest layer. The rules the coordinator made binding:
///   * PENALISE BEHAVIOUR, NEVER PHYSIOLOGY. A plan target that becomes a quest is stated in LOGGED
///     MINUTES (behaviour), never in %HRR minutes — whether a minute reaches the moderate line depends on
///     the body's heart-rate response, and a fit wearer walking below it must not be charged for that.
///   * NEVER PUSH LOAD ON A LOW-CHARGE DAY. On rest/easy days, on moveHard days, and whenever Charge is
///     low or unknown, no training or strain directive above Steady is issued, strain is dropped, and a
///     training shortfall is reported, not charged (HEALTH_V2 S0 penalty rule 2).
public enum WeekPlanQuestBridge {

    /// "Easy movement ≤ 30 min" on easy/moveHard days (HEALTH_V2 S0 H9).
    public static let easyMovementCapMin: Double = 30
    /// A week-plan aerobic quest asks for between 10 and 45 logged minutes: under 10 is not a session,
    /// over 45 would turn a weekly total into a single-day spike.
    public static let aerobicQuestRange: ClosedRange<Double> = 10...45

    /// Whether today's Charge allows added training load: known AND above the low line. The same test as
    /// `QuestDebtContext.trainingAllowed` (unknown counts as low).
    public static func loadAllowed(charge: Double?) -> Bool {
        guard let charge else { return false }
        return charge > QuestTriggers.chargeLow
    }

    /// Whether a missed quest on `metric` may be CHARGED today. Training (`workoutMinutes`, `strain`) is
    /// chargeable only on an `asPlanned` day with Charge known and not low; everything else about the
    /// metric is left to `QuestMetric.penaltyClass`.
    public static func isChargeable(metric: QuestMetric, guidance: DayGuidance?, charge: Double?) -> Bool {
        switch metric {
        case .workoutMinutes, .strain:
            guard let g = guidance else { return loadAllowed(charge: charge) }
            return g.kind == .asPlanned && loadAllowed(charge: charge)
        case .steps, .waterMl, .meditationMinutes, .journal, .bedtimeBy, .bedtimeEarlier, .sleepHours:
            return metric.isBehaviour
        }
    }

    /// Constrain the gear's day plan with today's guidance. Ids are preserved so the quest store replaces
    /// rather than duplicates.
    ///   rest               → training and strain directives dropped.
    ///   easy / moveHard with low or unknown Charge
    ///                      → training becomes "easy movement ≤ 30 min" at Steady's factor; strain dropped.
    ///   moveHard, Charge ok → training at Steady's factor (no factor above 1.0); strain dropped.
    ///   asPlanned          → unchanged.
    /// Steps are never touched: walking is compatible with recovery.
    ///
    /// No guidance at all (the plan has not run for this day): a KNOWN low Charge is still treated as a
    /// moveHard day, so a missing plan can never let a gear push load on a low-Charge morning.
    public static func apply(_ targets: [QuestPlanTarget], guidance: DayGuidance?, difficulty: QuestDifficulty,
                             charge: Double?) -> [QuestPlanTarget] {
        let kind: DayGuidance.Kind
        let line: String
        if let guidance {
            kind = guidance.kind
            line = guidance.line
        } else if let c = charge, c <= QuestTriggers.chargeLow {
            kind = .moveHard
            line = "Move today's hard session — Charge is low this morning."
        } else {
            return targets
        }
        guard kind != .asPlanned else { return targets }
        let gearTraining = difficulty.scale.training
        let steadyTraining = QuestDifficulty.steady.scale.training
        let lowOrUnknown = !loadAllowed(charge: charge)
        var out: [QuestPlanTarget] = []
        for t in targets {
            switch t.goal.metric {
            case .workoutMinutes:
                if kind == .rest { continue }
                // Undo the gear, apply Steady's factor, never above 1.0 of the usual.
                let usual = gearTraining > 0 ? t.goal.threshold / gearTraining : t.goal.threshold
                var minutes = usual * min(steadyTraining, 1.0)
                let easy = kind == .easy || lowOrUnknown
                if easy { minutes = min(minutes, easyMovementCapMin) }
                let rounded = max(5, (minutes / 5).rounded() * 5)
                let text = easy ? "Easy movement, \(Int(rounded)) minutes at most — nothing hard today"
                                : "\(Int(rounded)) minutes of easy-to-moderate training — hard sessions move to another day"
                out.append(QuestPlanTarget(id: t.id, observation: t.observation + " Today's plan: "
                                               + line, target: text, rewards: t.rewards, xp: t.xp,
                                           goal: QuestGoal(metric: .workoutMinutes, threshold: rounded),
                                           parts: t.parts))
            case .strain:
                // A strain directive is a point in the day's band — at Push/Relentless its upper half, i.e. a
                // hard day. Not advised on any non-asPlanned day (acceptance 3), so it is dropped.
                continue
            case .steps, .waterMl, .meditationMinutes, .journal, .bedtimeBy, .bedtimeEarlier, .sleepHours:
                out.append(t)
            }
        }
        return out
    }

    /// A week-plan aerobic quest for today: the remaining weekly aerobic deficit spread over the days
    /// left, in LOGGED MINUTES. Issued only on an `asPlanned` day with Charge known and not low, only when
    /// there is a personal target (not while calibrating), and never once the week is met — the plan does
    /// not ask for more than its own target.
    public static func aerobicQuest(plan: WeekPlan, progress: WeekProgress, guidance: DayGuidance?,
                                    charge: Double?, day: String, xp: Int) -> QuestPlanTarget? {
        guard let g = guidance, g.kind == .asPlanned, loadAllowed(charge: charge),
              let target = plan.aerobicTarget else { return nil }
        let remaining = target - progress.aerobicDone
        guard remaining > 0 else { return nil }
        let daysLeft = max(1, WeekPlanEngine.weekDays(plan.weekStart).filter { $0 >= day }.count)
        let share = remaining / Double(daysLeft)
        let minutes = min(aerobicQuestRange.upperBound, max(aerobicQuestRange.lowerBound, (share / 5).rounded() * 5))
        return QuestPlanTarget(
            id: QuestDayPlan.questId(day: day, metric: .workoutMinutes),
            observation: "The week plan has \(Int(remaining.rounded())) aerobic minutes left over "
                + "\(daysLeft) day\(daysLeft == 1 ? "" : "s").",
            target: "\(Int(minutes)) minutes of training logged today",
            rewards: [.muscle, .heart], xp: xp,
            goal: QuestGoal(metric: .workoutMinutes, threshold: minutes),
            parts: [.muscle, .lungs])
    }
}
