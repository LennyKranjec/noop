import Foundation

// HabitTrialCatalog.swift — the closed list of habits the app may randomise, and nothing else.
//
// HEALTH_V2 §S1-B.1. Only behaviours that are harmless, reversible within a day, and that a healthy adult
// already varies without supervision. A trial may only ever REMOVE a plausible disruptor or ADD a
// low-dose, everyday behaviour. The table is fixed Swift, not model output: the coach can PROPOSE an entry
// by its id, never invent one, and there is no free-text field anywhere in the trial path.
//
// Supplements, medication, caffeine increases, fasting / time-restricted eating, calorie restriction,
// sleep restriction, cold or heat exposure, breath-holds / hyperventilation and training-intensity
// increases are excluded BY RULE, with the reason listed in `exclusions` so the catalogue screen can say why.

/// How long an intervention's effect lingers — which decides the design.
public enum HabitTrialCarryOver: String, Codable, Sendable {
    /// Gone by the next night.
    case none
    /// May spill into one following night: analysed with a `prevAssignedOn` covariate.
    case short
    /// Builds and decays over days (circadian phase): 4-day blocks with a washout day.
    case phase

    public var design: HabitTrialDesign {
        switch self {
        case .none, .short: return .weekdayBalanced
        case .phase: return .phaseBlocks
        }
    }
}

/// Whether the ON instruction removes a disruptor or adds a behaviour — which decides what the contrast
/// question counts, and which way a linked association has to point to support a trial.
public enum HabitTrialPolarity: String, Codable, Sendable {
    /// ON removes something (late caffeine, screens, late dinner, alcohol).
    case removesDisruptor
    /// ON adds something (a walk, a breathing session, daylight, a cooler room).
    case addsBehaviour
}

/// One catalogue entry.
public struct HabitTrialEntry: Equatable, Sendable {
    public let id: String
    public let title: String
    public let onInstruction: String
    public let offInstruction: String
    public let carryOver: HabitTrialCarryOver
    public let polarity: HabitTrialPolarity
    public let primaryOutcome: HabitOutcome
    public let secondaryOutcomes: [HabitOutcome]
    /// A covariate the intervention itself moves: effort is then taken from the day BEFORE (a mediator
    /// adjusted away would subtract the effect).
    public let affectsEffort: Bool
    /// 1 = least effort … 3 = most.
    public let effortRank: Int
    /// Quest metrics that must not be directed while this trial runs (the behaviour itself, or the primary
    /// outcome's obvious lever) — a directive on them would differ between arms and bias the estimate.
    public let conflictingMetrics: Set<QuestMetric>
    /// Habits whose association supports proposing this trial.
    public let linkedHabits: [HabitId]
    /// How adherence is seen automatically, in plain words.
    public let autoAdherence: String
    /// The contrast question: "On how many evenings a week do you usually …?"
    public let contrastQuestion: String
    /// Minimum evenings a week that differ from the ON instruction for the trial to be offered.
    public let minContrastPerWeek: Int
    /// One honest evidence line.
    public let evidence: String
    /// Population evidence strong enough to propose it untested.
    public let strongPopulationEvidence: Bool
    /// Needs a paired Govee sensor and the wearer's confirmation that ~18 °C is reachable.
    public let needsClimateSensor: Bool

    public var design: HabitTrialDesign { carryOver.design }
    public var direction: EffectDirection { primaryOutcome.betterDirection }
    public var allowedLengths: [Int] { design.allowedLengths }
}

/// An excluded category and why.
public struct HabitTrialExclusion: Equatable, Sendable {
    public let category: String
    public let reason: String
}

/// Wearer context the catalogue needs to decide eligibility.
public struct HabitTrialEligibilityContext: Equatable, Sendable {
    /// A Govee (or other) climate sensor is paired.
    public var climateSensorPaired: Bool
    /// The wearer confirmed the room can reach about 18 °C.
    public var coolRoomConfirmed: Bool
    /// Evenings with a logged drink in the last 28 days (journal alcohol "yes"). Nil = unknown.
    public var drinkingEveningsLast28: Int?
    /// Last day each intervention was trialled (completed or stopped), by entry id.
    public var lastTrialledDay: [String: String]
    /// Today, `yyyy-MM-dd`.
    public var today: String

    public init(climateSensorPaired: Bool = false, coolRoomConfirmed: Bool = false,
                drinkingEveningsLast28: Int? = nil, lastTrialledDay: [String: String] = [:], today: String) {
        self.climateSensorPaired = climateSensorPaired
        self.coolRoomConfirmed = coolRoomConfirmed
        self.drinkingEveningsLast28 = drinkingEveningsLast28
        self.lastTrialledDay = lastTrialledDay
        self.today = today
    }
}

/// Why an entry is not offered.
public enum HabitTrialIneligibility: Equatable, Sendable {
    case needsClimateSensor
    case needsCoolRoomConfirmation
    case tooFewDrinkingEvenings(have: Int, need: Int)
    case drinkingUnknown
    case trialledRecently(lastDay: String)
    case noContrast
    case unknownEntry

    public var text: String {
        switch self {
        case .needsClimateSensor: return "Needs a paired room sensor to check the temperature."
        case .needsCoolRoomConfirmation: return "Only if your bedroom can reach about 18 °C."
        case .tooFewDrinkingEvenings(let have, let need):
            return "Not offered: \(have) drinking evenings in the last 4 weeks (needs \(need)). There is nothing to compare, and the app never suggests drinking to make a trial work."
        case .drinkingUnknown: return "Not offered until the journal shows how often you drink."
        case .trialledRecently(let day): return "Tested recently (\(day)). A repeat is a new trial after 90 days."
        case .noContrast: return "You already mostly do this — there is nothing to compare."
        case .unknownEntry: return "Not in the catalogue."
        }
    }
}

/// A proposed trial.
public struct TrialProposal: Equatable, Codable, Sendable {
    public let entryId: String
    /// "your data suggests …" or "commonly effective; untested for you".
    public let reason: String
    /// True when the wearer's own data (a possible link) motivated it.
    public let fromOwnData: Bool

    public init(entryId: String, reason: String, fromOwnData: Bool) {
        self.entryId = entryId
        self.reason = reason
        self.fromOwnData = fromOwnData
    }
}

public enum HabitTrialCatalog {

    /// Days before the same intervention may be proposed again.
    public static let repeatCooldownDays = 90
    /// Drinking evenings in the last 28 days needed before `alcoholFree` is offered (2 a week).
    public static let alcoholMinDrinkingEvenings = 8

    public static let entries: [HabitTrialEntry] = [
        HabitTrialEntry(
            id: "caffeineCutoff14", title: "No caffeine after 14:00",
            onInstruction: "No caffeine after 14:00 today", offInstruction: "Caffeine as usual",
            carryOver: .none, polarity: .removesDisruptor,
            primaryOutcome: .totalSleepMin, secondaryOutcomes: [.onsetClockMin, .nightHrvLn],
            affectsEffort: false, effortRank: 1,
            conflictingMetrics: [.sleepHours, .bedtimeBy, .bedtimeEarlier],
            linkedHabits: [HabitCatalog.lateCaffeineJournal, HabitCatalog.lateCaffeineAuto],
            autoAdherence: "Your caffeine log, on days you log an intake; otherwise your tap.",
            contrastQuestion: "On how many days a week do you usually have caffeine after 14:00?",
            minContrastPerWeek: 3,
            evidence: "Caffeine taken even 6 hours before bed measurably reduced sleep (Drake 2013).",
            strongPopulationEvidence: true, needsClimateSensor: false),
        HabitTrialEntry(
            id: "screensOff60", title: "Screens off an hour before bed",
            onInstruction: "Screens off 60 minutes before your planned bedtime", offInstruction: "Evening as usual",
            carryOver: .none, polarity: .removesDisruptor,
            primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin],
            affectsEffort: false, effortRank: 2,
            conflictingMetrics: [.bedtimeBy, .bedtimeEarlier],
            linkedHabits: [HabitCatalog.screenInBed, HabitCatalog.dreamScreen],
            autoAdherence: "Your tap (the dream journal's screen answer is a recall check only).",
            contrastQuestion: "On how many evenings a week do you usually use a screen in the last hour before bed?",
            minContrastPerWeek: 3,
            evidence: "Light-emitting screens before bed delayed circadian timing in a lab study (Chang 2015).",
            strongPopulationEvidence: true, needsClimateSensor: false),
        HabitTrialEntry(
            id: "bedroom18", title: "Bedroom at about 18 °C",
            onInstruction: "Bedroom at about 18 °C at lights-out", offInstruction: "Bedroom as usual",
            carryOver: .none, polarity: .addsBehaviour,
            primaryOutcome: .nightHrvLn, secondaryOutcomes: [.sleepEfficiency],
            affectsEffort: false, effortRank: 2,
            conflictingMetrics: [],
            linkedHabits: [HabitCatalog.warmBedroom],
            autoAdherence: "Your room sensor over the first 90 minutes of sleep; otherwise your tap.",
            contrastQuestion: "On how many nights a week is your bedroom already at about 18 °C?",
            minContrastPerWeek: 3,
            evidence: "Bedroom temperature affects sleep, and the best temperature differs between people.",
            strongPopulationEvidence: false, needsClimateSensor: true),
        HabitTrialEntry(
            id: "walkAfterDinner10", title: "10-minute walk after dinner",
            onInstruction: "A 10-minute walk within 60 minutes after dinner", offInstruction: "No planned walk",
            carryOver: .none, polarity: .addsBehaviour,
            primaryOutcome: .nightRhr, secondaryOutcomes: [.nightHrvLn],
            affectsEffort: true, effortRank: 2,
            conflictingMetrics: [.steps],
            linkedHabits: [],
            autoAdherence: "Evening steps when your step count is calibrated; otherwise your tap.",
            contrastQuestion: "On how many evenings a week do you usually walk after dinner?",
            minContrastPerWeek: 3,
            evidence: "A short walk after a meal is a common, low-risk habit; its effect on your night is untested.",
            strongPopulationEvidence: false, needsClimateSensor: false),
        HabitTrialEntry(
            id: "morningDaylight", title: "Morning daylight",
            onInstruction: "At least 10 minutes outdoors within 30 minutes of waking",
            offInstruction: "No deliberate outdoor time before 10:00",
            carryOver: .phase, polarity: .addsBehaviour,
            primaryOutcome: .onsetClockMin, secondaryOutcomes: [.totalSleepMin],
            affectsEffort: false, effortRank: 2,
            conflictingMetrics: [.bedtimeBy, .bedtimeEarlier],
            linkedHabits: [],
            autoAdherence: "Your tap.",
            contrastQuestion: "On how many mornings a week do you usually get outdoor light within 30 minutes of waking?",
            minContrastPerWeek: 3,
            evidence: "Morning daylight helps set the body clock earlier; its effect on your sleep timing is untested.",
            strongPopulationEvidence: false, needsClimateSensor: false),
        HabitTrialEntry(
            id: "dinner3h", title: "Dinner 3 hours before bed",
            onInstruction: "Last meal at least 3 hours before bed", offInstruction: "Dinner as usual",
            carryOver: .none, polarity: .removesDisruptor,
            primaryOutcome: .nightRhr, secondaryOutcomes: [.nightHrvLn],
            affectsEffort: false, effortRank: 3,
            conflictingMetrics: [],
            linkedHabits: [HabitCatalog.lateMeal, HabitCatalog.dreamMeal],
            autoAdherence: "Your tap (the dream journal's meal answer is a recall check only).",
            contrastQuestion: "On how many evenings a week do you usually eat within 3 hours of bed?",
            minContrastPerWeek: 3,
            evidence: "A late meal can raise night heart rate; how much for you is untested.",
            strongPopulationEvidence: false, needsClimateSensor: false),
        HabitTrialEntry(
            id: "breathing10", title: "10 minutes of evening breathing",
            onInstruction: "One 10-minute paced-breathing session this evening", offInstruction: "No breathing session",
            carryOver: .none, polarity: .addsBehaviour,
            primaryOutcome: .nightHrvLn, secondaryOutcomes: [.nightRhr],
            affectsEffort: false, effortRank: 2,
            conflictingMetrics: [.meditationMinutes],
            linkedHabits: [HabitCatalog.breathingSession],
            autoAdherence: "A logged meditation or breathing session in the evening.",
            contrastQuestion: "On how many evenings a week do you usually do a breathing session?",
            minContrastPerWeek: 3,
            evidence: "Slow breathing raises HRV during and shortly after a session (Laborde 2022).",
            strongPopulationEvidence: false, needsClimateSensor: false),
        HabitTrialEntry(
            id: "alcoholFree", title: "Alcohol-free evening",
            onInstruction: "No alcohol this evening", offInstruction: "Evening as usual (no instruction to drink)",
            carryOver: .short, polarity: .removesDisruptor,
            primaryOutcome: .nightHrvLn, secondaryOutcomes: [.nightRhr, .totalSleepMin],
            affectsEffort: false, effortRank: 1,
            conflictingMetrics: [],
            linkedHabits: [HabitCatalog.alcohol],
            autoAdherence: "Your tap.",
            contrastQuestion: "On how many evenings a week do you usually drink alcohol?",
            minContrastPerWeek: 2,
            evidence: "Alcohol lowers night HRV in a dose-dependent way (Pietilä 2018).",
            strongPopulationEvidence: true, needsClimateSensor: false),
    ]

    public static let exclusions: [HabitTrialExclusion] = [
        HabitTrialExclusion(category: "Supplements (melatonin, magnesium, creatine, …)",
                            reason: "Not an everyday behaviour to randomise; doses and interactions need a professional."),
        HabitTrialExclusion(category: "Any medication, or a change to one",
                            reason: "Medical decisions belong with a clinician."),
        HabitTrialExclusion(category: "More caffeine", reason: "A trial may only remove a disruptor, never add one."),
        HabitTrialExclusion(category: "Fasting, time-restricted eating or calorie restriction",
                            reason: "Medical risk for some people; outside what an app should randomise."),
        HabitTrialExclusion(category: "Sleep restriction or deliberately shortened nights",
                            reason: "Short sleep is itself a harm."),
        HabitTrialExclusion(category: "Cold or heat exposure (ice baths, sauna)",
                            reason: "Cardiovascular risk for some people."),
        HabitTrialExclusion(category: "Breath-holds or hyperventilation",
                            reason: "Can cause fainting."),
        HabitTrialExclusion(category: "Harder training", reason: "Load increases need a plan, not a coin flip."),
        HabitTrialExclusion(category: "Anything written as free text",
                            reason: "Only the fixed list can be pre-registered and checked for safety."),
    ]

    public static func entry(_ id: String) -> HabitTrialEntry? { entries.first { $0.id == id } }

    /// Whether the wearer's usual week leaves enough contrast. `usualPerWeek` answers the entry's
    /// `contrastQuestion` (0…7).
    public static func hasContrast(_ entry: HabitTrialEntry, usualPerWeek: Int) -> Bool {
        let usual = Swift.max(0, Swift.min(7, usualPerWeek))
        let differing: Int
        switch entry.polarity {
        case .removesDisruptor: differing = usual            // evenings WITH the disruptor
        case .addsBehaviour: differing = 7 - usual           // evenings WITHOUT the behaviour
        }
        return differing >= entry.minContrastPerWeek
    }

    /// Why `entry` is not offered, or nil when it is.
    public static func ineligibility(_ entry: HabitTrialEntry,
                                     context: HabitTrialEligibilityContext) -> HabitTrialIneligibility? {
        if entry.needsClimateSensor {
            if !context.climateSensorPaired { return .needsClimateSensor }
            if !context.coolRoomConfirmed { return .needsCoolRoomConfirmation }
        }
        if entry.id == "alcoholFree" {
            guard let n = context.drinkingEveningsLast28 else { return .drinkingUnknown }
            if n < alcoholMinDrinkingEvenings {
                return .tooFewDrinkingEvenings(have: n, need: alcoholMinDrinkingEvenings)
            }
        }
        if let last = context.lastTrialledDay[entry.id],
           let age = HabitDay.days(from: last, to: context.today), age < repeatCooldownDays {
            return .trialledRecently(lastDay: last)
        }
        return nil
    }

    /// Up to two proposals (HEALTH_V2 §S1-A.4), ranked: (1) the wearer's data shows a possible link — or
    /// an unclear estimate pointing the harmful way — on a linked habit; (2) lowest effort; (3) untested
    /// entries with strong population evidence. Ties break on the catalogue order, so the list is stable.
    public static func proposals(report: HabitAssociationReport?,
                                 context: HabitTrialEligibilityContext) -> [TrialProposal] {
        struct Candidate {
            let entry: HabitTrialEntry
            let order: Int
            let dataTier: Int      // 0 possible link, 1 unclear-harmful, 2 nothing from data
            let reason: String
        }
        var candidates: [Candidate] = []
        for (order, e) in entries.enumerated() where ineligibility(e, context: context) == nil {
            var tier = 2
            var reason = "Commonly effective; untested for you."
            for habit in e.linkedHabits {
                guard let row = report?.rows.first(where: { $0.habit == habit }),
                      row.outcome == e.primaryOutcome, let beta = row.estimate else { continue }
                let better = beta * row.outcome.betterDirection.sign     // > 0: presence is better
                let supports = e.polarity == .removesDisruptor ? better < 0 : better > 0
                guard supports else { continue }
                if row.label == .possibleLink, tier > 0 {
                    tier = 0
                    reason = "Your data suggests a link between \(row.habitLabel.lowercased()) and your "
                        + "\(row.outcome.label) — a trial can test it."
                } else if row.label == .unclear, tier > 1 {
                    tier = 1
                    reason = "Your data points this way but is unclear — a trial can settle it."
                }
            }
            if tier == 2 && !e.strongPopulationEvidence { continue }
            candidates.append(Candidate(entry: e, order: order, dataTier: tier, reason: reason))
        }
        candidates.sort { a, b in
            if a.dataTier != b.dataTier { return a.dataTier < b.dataTier }
            if a.entry.effortRank != b.entry.effortRank { return a.entry.effortRank < b.entry.effortRank }
            return a.order < b.order
        }
        return candidates.prefix(2).map {
            TrialProposal(entryId: $0.entry.id, reason: $0.reason, fromOwnData: $0.dataTier < 2)
        }
    }
}

// MARK: - Trial quests

/// Trial quest ids. The prefix is the penalty system's own exemption constant — one source, so a trial
/// quest can never become penalisable by a typo.
public enum HabitTrialQuestId {

    public static var prefix: String { QuestPenaltyRules.trialIdPrefix }

    /// `trial-<trialId>-<day>`.
    public static func make(trialId: String, day: String) -> String {
        "\(prefix)\(trialId)-\(day)"
    }

    public static func isTrialQuest(_ id: String) -> Bool { id.hasPrefix(prefix) }

    /// The day key at the end of a trial quest id, or nil.
    public static func day(of id: String) -> String? {
        guard isTrialQuest(id), id.count >= 10 else { return nil }
        let day = String(id.suffix(10))
        return HabitDay.epochDay(day) != nil ? day : nil
    }

    /// XP for LOGGING a trial day — identical for every answer in either arm, so XP can neither reward a
    /// false "did it" nor make ON days more attractive to report. Inside `QuestCodec`'s XP band.
    public static let loggingXp = 10
}
