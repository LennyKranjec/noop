import Foundation

// QuestPenalty.swift — what an unmet quest costs, in one place.
//
// A quest that runs out unmet used to cost nothing: a red card, "+0 XP", and the day moved on. That made
// the gear choice in the morning free — Relentless paid more when it landed and cost nothing when it did
// not, so there was never a reason to pick anything else. Now an unmet quest has a price, and the price
// is set here and nowhere else.
//
// PENALTIES ARE A GAME-LAYER THING, AND ONLY A GAME-LAYER THING. What a miss can move is the XP balance,
// the daily-quest streak and tomorrow's make-up obligations — the parts of the app that exist to be a
// game. It NEVER touches the measured health Level (`LevelEngine` / `LevelLedger`): that is a frozen
// description of the body against a fixed scale, and a missed quest does not change a single heartbeat.
// Nothing in this file imports, reads or writes anything the Level reads, and nothing may start to.
//
// HONEST INSIDE THE PUNISHMENT. The rules the rest of the app is built on hold here too:
//
//   * NOT MEASURED IS NOT FAILED. A metric the data never carried — no strap data, no step count, a
//     HealthKit read that came back empty — costs nothing, and says so: "not measured, no penalty".
//   * THE DATA DECIDES, NOT THE CLOCK. A quest whose data lands late is judged on that data when it lands
//     (`QuestLedger.judge` waits `lateDataGraceMs` for it), and a penalty the later data contradicts is
//     refunded in full (`QuestLedger.void`).
//   * A COMPLETED QUEST KEEPS ITS REWARD. Nothing here claws back a payout.
//   * ONE MISS, ONE PENALTY. Every judgement is keyed by the quest's id, and two quests on the same day
//     that ask for the same metric are charged as one miss — the larger of the two — not twice.
//
// Pure + deterministic, database-free, so every number is pinned by `swift test` with no app, no strap
// and no model. The ledger's stored shape is `Codable` JSON local to this device; there is no Android
// twin of the penalty system yet, so nothing here crosses the `.noopbak` boundary.

// MARK: - The constants

/// Every number the penalty system uses. One table, so "what does a Relentless miss cost" has one answer.
public enum QuestPenaltyRules {

    /// How much of a quest's XP a TOTAL miss costs, by the gear the day was running in.
    ///
    /// THE GEAR WAS THE WEARER'S OWN BET. Relentless pays 70 XP a directive against Steady's 35
    /// (`QuestDifficulty.xp`), and it risks proportionally more: a full Relentless miss costs the whole
    /// 70, a full Steady miss half of its 35. So the gap between the gears is 4× on the downside and 2× on
    /// the upside — picking the hard gear is a real wager, and picking the easy one is the safe play it
    /// looks like.
    public static func gearFactor(_ gear: QuestDifficulty?) -> Double {
        switch gear {
        case .some(.steady): return 0.50
        case .some(.push): return 0.75
        case .some(.relentless): return 1.00
        case .none: return ungearedFactor
        }
    }

    /// The factor for a quest no gear scaled — the daily quest, a triggered side quest, the wearer's own
    /// task with a goal. The middle of the gear table: those were not a bet, so they are neither the
    /// safe play nor the wager.
    public static let ungearedFactor = 0.75

    /// Each earlier miss of the SAME metric inside the window adds this much to the multiplier: a second
    /// miss costs ×1.5, a third ×2.0.
    public static let escalationStep = 0.5

    /// Where escalation stops. A metric missed every day for a week costs twice its first miss and no
    /// more — enough to hurt, not a spiral that empties the balance over one bad week.
    public static let escalationCap = 2.0

    /// How far back an earlier miss still counts toward escalation, in days.
    public static let escalationWindowDays = 7

    /// A miss is never free. 90 % of the steps costs a sliver — never zero, or the last 10 % would be
    /// optional.
    public static let minimumCost = 1

    /// Minutes past a bedtime deadline that count as a total miss. Asleep 30 minutes late is a quarter
    /// of the penalty; two hours late is all of it.
    public static let bedtimeFullMissMinutes = 120.0

    /// How far the XP balance can fall. THE BALANCE CAN GO NEGATIVE — "in the red" — because a penalty
    /// that stops at zero is no penalty at all for a wearer who has not earned anything yet. It stops
    /// here, roughly four fully missed Relentless days, so digging out stays possible.
    public static let balanceFloor = -300

    /// What clearing a make-up quest gives back, as a share of what the miss actually cost.
    ///
    /// Half, not all: making it up is worth doing, but the miss still happened. A penalty that a make-up
    /// erased completely would turn every miss into a free day off with homework.
    public static let restoreFraction = 0.5

    /// How long a judgement stays pinned above the quests, in days after the quest's own day — unless
    /// its make-up is still open, which keeps it there until it is cleared or lapses.
    public static let pinnedDays = 3

    /// How much history is kept.
    public static let historyDays = 30

    /// How long an unmeasured quest waits for its data before it is closed as "not measured".
    ///
    /// A strap that syncs the next morning is the normal case, not an edge case: judging at the moment
    /// the window shut would penalise the sync schedule, not the wearer.
    public static let lateDataGraceMs: Int64 = 24 * 3_600_000

    /// The oldest quest day that is still judged on its data, in days before today.
    ///
    /// The evidence reader looks back only a few days (`QuestAutoComplete.gather` reads a 4–5 day window),
    /// so a day older than this cannot be read reliably — and an unreliable read must not become a
    /// penalty. Older than this is "not measured", and costs nothing.
    public static let judgeableMaxAgeDays = 2

    /// A make-up adds at most this share of the missed target on top of it.
    ///
    /// 12,000 steps missed by 7,000 does not become 19,000 tomorrow; it becomes 15,000.
    public static let debtAddOnCap = 0.25

    /// Absolute ceilings a make-up can never pass, whatever the arithmetic says.
    public static let debtStepsCeiling = 25_000.0
    public static let debtMeditationCeilingMinutes = 45.0

    /// A miss older than this, in days, gets no make-up — tomorrow is not the day to pay off last week.
    public static let debtMaxAgeDays = 2

    /// How many idempotence keys are remembered. Far more than the quest list ever holds (`maxKept`).
    public static let settledKept = 1_000
}

// MARK: - What may be penalised at all
//
// PENALISE BEHAVIOUR, NEVER PHYSIOLOGY. A penalty is only fair for something the wearer DOES: walking,
// drinking, training, sitting down to breathe, writing, getting into bed. It is never fair for something
// the body does — HRV, resting heart rate, Charge, stress, how long sleep actually lasted — because
// nobody can will those, and a penalty for them teaches nothing and can feed the very anxiety that moves
// them the wrong way. A quest on a physiological figure that is missed is REPORTED, plainly, with its
// reading, and costs nothing: no XP, no streak, no make-up.
//
// Effort is the borderline case. Training is behaviour; the strain it produces depends on the body and
// the band depends on Charge. So a strain quest is charged only for "did not train at all when the day's
// band asked for it" — never for falling short of a number the body set.

/// How a metric is treated when its quest is missed.
public enum QuestPenaltyClass: String, Equatable, Sendable {
    /// Something the wearer does. Missed → charged, in proportion to the shortfall.
    case behaviour
    /// Something the body does. Missed → reported, never charged.
    case physiology
    /// Strain: charged only when there was no training at all; otherwise reported.
    case effort
}

extension QuestMetric {

    /// The one place a metric is classified. Exhaustive with NO default, so a metric added later cannot
    /// become penalisable by accident: it fails to compile here until someone decides which it is.
    public var penaltyClass: QuestPenaltyClass {
        switch self {
        case .steps: return .behaviour
        case .waterMl: return .behaviour
        case .workoutMinutes: return .behaviour
        case .meditationMinutes: return .behaviour
        case .journal: return .behaviour
        // Going to bed is a behaviour; how long sleep then lasts is not.
        case .bedtimeBy: return .behaviour
        case .bedtimeEarlier: return .behaviour
        case .sleepHours: return .physiology
        case .strain: return .effort
        }
    }

    /// Whether a miss on this metric is charged in proportion to its shortfall.
    public var isBehaviour: Bool { penaltyClass == .behaviour }
}

extension QuestPenaltyRules {

    /// Ids of n-of-1 trial quests start with this. A trial is an experiment, and an experiment whose
    /// arms carry a price is no longer measuring what it says: neither arm is ever judged, charged or
    /// given a make-up.
    public static let trialIdPrefix = "trial-"

    /// Whether a quest of this kind and id can be judged for a penalty at all.
    ///
    /// EXEMPT BY CONSTRUCTION. The switch has no default: when a trial kind is added to `QuestKind`, this
    /// stops compiling until it is listed — and it must be listed as `false`. Until then, the id prefix
    /// exempts trial quests stored under an existing kind.
    public static func isPenalisable(kind: QuestKind, questId: String) -> Bool {
        if questId.hasPrefix(trialIdPrefix) { return false }
        switch kind {
        case .daily: return true
        case .side: return true
        case .custom: return true
        }
    }
}

// MARK: - How far short

extension QuestGoal {

    /// How far short of the goal the evidence fell, as a share of the goal: 0 when met, up to 1 for a
    /// total miss — and NIL WHEN THE DATA DOES NOT CARRY THE FIGURE AT ALL.
    ///
    /// Written against `isMeasured` and `isMet`, so the three can never disagree: nil exactly when not
    /// measured, 0 exactly when met, and strictly positive for every measured miss.
    public func shortfall(_ e: QuestEvidence) -> Double? {
        guard isMeasured(by: e) else { return nil }
        if isMet(by: e) { return 0 }
        func share(_ value: Double?) -> Double {
            guard threshold > 0, let value else { return 1 }
            return Swift.min(1, Swift.max(0, (threshold - value) / threshold))
        }
        switch metric {
        case .steps: return share(e.steps)
        case .workoutMinutes: return share(e.workoutMinutes)
        case .meditationMinutes: return share(e.meditationMinutes)
        case .waterMl: return share(e.waterMl)
        case .strain: return share(e.strain)
        case .sleepHours: return share(e.nextSleepHours)
        case .journal: return 1
        case .bedtimeBy:
            guard let onset = e.nextSleepOnsetMinute else { return nil }
            let late = Double(Self.minutesPast(onset, deadline: Int(threshold)))
            return Swift.min(1, Swift.max(0, late / QuestPenaltyRules.bedtimeFullMissMinutes))
        case .bedtimeEarlier:
            guard let tonight = e.nextSleepOnsetMinute, let before = e.previousSleepOnsetMinute else {
                return nil
            }
            let earlier = Double(-Self.minutesPast(tonight, deadline: before))
            return share(earlier)
        }
    }
}

// MARK: - What it costs

/// The price of one unmet quest.
public enum QuestPenalty {

    /// The escalation multiplier for a metric already missed `priorMisses` times inside the window.
    public static func escalation(priorMisses: Int) -> Double {
        Swift.min(QuestPenaltyRules.escalationCap,
                  1 + QuestPenaltyRules.escalationStep * Double(Swift.max(0, priorMisses)))
    }

    /// XP lost for missing a quest worth `xp`, `shortfall` of the way, in `gear`, after `priorMisses`.
    ///
    ///     cost = xp × gearFactor × shortfall × escalation   (rounded, at least `minimumCost`)
    ///
    /// Zero only when nothing was missed.
    public static func cost(xp: Int, gear: QuestDifficulty?, shortfall: Double, priorMisses: Int) -> Int {
        guard shortfall > 0, xp > 0 else { return 0 }
        let raw = Double(xp) * QuestPenaltyRules.gearFactor(gear) * Swift.min(1, shortfall)
            * escalation(priorMisses: priorMisses)
        return Swift.max(QuestPenaltyRules.minimumCost, Int(raw.rounded()))
    }
}

// MARK: - Day arithmetic

/// Whole days between `yyyy-MM-dd` keys, on a fixed UTC Gregorian calendar — so a DST change is a date
/// and never a 23- or 25-hour day.
public enum QuestDayMath {

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return c
    }()

    /// Days since 1970-01-01 for a day key, or nil for a key that is not a date.
    public static func ordinal(_ key: String) -> Int? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3,
              let date = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// `to` minus `from`, in days. Nil when either is not a date.
    public static func days(from: String, to: String) -> Int? {
        guard let a = ordinal(from), let b = ordinal(to) else { return nil }
        return b - a
    }
}

// MARK: - Make-up obligations

/// What the day a make-up would land on looks like — the part of it the make-up has to respect.
public struct QuestDebtContext: Equatable, Sendable {
    /// The day the make-up would be issued for.
    public let today: String
    /// Today's Charge (0–100), nil when it is not known.
    public let charge: Double?
    /// Today's recommended day-strain band on WHOOP's 0–21 axis, nil when there is none.
    public let effortBand21: ClosedRange<Int>?

    public init(today: String, charge: Double? = nil, effortBand21: ClosedRange<Int>? = nil) {
        self.today = today
        self.charge = charge
        self.effortBand21 = effortBand21
    }

    /// Whether today's Charge allows ANY added training load. Unknown is treated as low: a make-up that
    /// adds load on a day whose recovery nobody measured is exactly the overreach this rule exists for.
    public var trainingAllowed: Bool {
        guard let charge else { return false }
        return charge > QuestTriggers.chargeLow
    }
}

/// Whether a miss rolls into a make-up, and what the make-up asks for.
public enum QuestDebtDecision: Equatable, Sendable {
    case issue(goal: QuestGoal, target: String)
    case none(reason: String)
}

/// The make-up rules.
///
/// THREE KINDS OF METRIC, THREE RULES:
///   * VOLUME (steps, meditation): the shortfall is added on top of the missed target, capped at
///     `debtAddOnCap` of it and under an absolute ceiling — a bad day cannot snowball.
///   * RECOVERY (sleep, bedtime, water, journal): the SAME target again, never raised. Owing sleep is not
///     paid by being told to sleep longer than your need, and owing water is not paid by drinking double.
///   * LOAD (training minutes, strain): the same target at most, never raised, and NOTHING AT ALL on a
///     day whose Charge is low or unknown. Strain is also held inside today's own recommended band.
public enum QuestDebtPolicy {

    public static func decide(goal: QuestGoal, shortfall: Double, kind: QuestKind, questId: String,
                              missedDay: String, context: QuestDebtContext) -> QuestDebtDecision {
        if QuestDebt.isDebtQuest(questId) {
            return .none(reason: "A missed make-up does not roll over again.")
        }
        if kind == .custom {
            return .none(reason: "Your own tasks do not roll over.")
        }
        guard let age = QuestDayMath.days(from: missedDay, to: context.today),
              age >= 0, age <= QuestPenaltyRules.debtMaxAgeDays else {
            return .none(reason: "Too old to make up.")
        }
        let t = goal.threshold
        switch goal.metric {
        case .steps:
            let add = Swift.min(t * shortfall, t * QuestPenaltyRules.debtAddOnCap)
            let steps = Double(QuestDayPlan.round(
                Swift.min(QuestPenaltyRules.debtStepsCeiling, t + add), to: 250))
            return .issue(goal: QuestGoal(metric: .steps, threshold: steps),
                          target: "\(QuestDayPlan.whole(steps)) steps today — the missed "
                              + "\(QuestDayPlan.whole(t)) plus what is owed")
        case .meditationMinutes:
            let add = Swift.min(t * shortfall, t * QuestPenaltyRules.debtAddOnCap)
            let minutes = Swift.max(t, Double(QuestDayPlan.round(
                Swift.min(QuestPenaltyRules.debtMeditationCeilingMinutes, t + add), to: 5)))
            return .issue(goal: QuestGoal(metric: .meditationMinutes, threshold: minutes),
                          target: "\(QuestDayPlan.whole(minutes)) minutes of meditation or slow breathing today")
        case .waterMl:
            return .issue(goal: goal, target: "\(QuestDayPlan.oneDp(t / 1000)) L of water today — the same target, not more")
        case .sleepHours:
            return .issue(goal: goal, target: "\(QuestDayPlan.oneDp(t)) hours of sleep tonight — the same target, not more")
        case .bedtimeBy:
            return .issue(goal: goal, target: "Asleep by \(QuestDayPlan.clock(Int(t))) tonight — the same deadline")
        case .bedtimeEarlier:
            return .issue(goal: goal, target: "Asleep \(QuestDayPlan.whole(t)) minutes earlier than last night")
        case .journal:
            return .issue(goal: goal, target: "An entry in the journal today")
        case .workoutMinutes:
            guard context.trainingAllowed else {
                return .none(reason: "No make-up: today's Charge is low or unknown, so no training load is added.")
            }
            return .issue(goal: goal, target: "\(QuestDayPlan.whole(t)) minutes of training logged today — the same target, not more")
        case .strain:
            guard context.trainingAllowed else {
                return .none(reason: "No make-up: today's Charge is low or unknown, so no training load is added.")
            }
            guard let band = context.effortBand21 else {
                return .none(reason: "No make-up: today has no recommended effort band to stay inside.")
            }
            let capped = Swift.min(t, Double(band.upperBound))
            return .issue(goal: QuestGoal(metric: .strain, threshold: capped),
                          target: "A day strain of \(QuestDayPlan.oneDp(capped)) — inside today's "
                              + "\(band.lowerBound)–\(band.upperBound) band")
        }
    }
}

/// Where a make-up stands.
public enum QuestDebtState: String, Codable, Equatable, Sendable {
    case open = "OPEN"
    /// Met: part of the lost XP came back.
    case cleared = "CLEARED"
    /// Its day ran out unmet. The original penalty stands; nothing further is charged.
    case lapsed = "LAPSED"
    /// The miss it was owed for turned out not to be one (later data met the quest).
    case withdrawn = "WITHDRAWN"
}

/// One make-up obligation.
public struct QuestDebt: Codable, Equatable, Sendable {

    /// Ids of make-up quests start with this, so the quest list can tell one apart without a new field.
    public static let idPrefix = "debt-"

    public static func questId(day: String, metric: QuestMetric) -> String {
        "\(idPrefix)\(day)-\(metric.rawValue)"
    }

    public static func isDebtQuest(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// The make-up quest's id.
    public let questId: String
    /// The day the make-up is for.
    public let dayKey: String
    public let metric: QuestMetric
    public let threshold: Double
    public let target: String
    /// What clearing it gives back.
    public let restoreXp: Int
    public var state: QuestDebtState

    public init(questId: String, dayKey: String, metric: QuestMetric, threshold: Double, target: String,
                restoreXp: Int, state: QuestDebtState = .open) {
        self.questId = questId
        self.dayKey = dayKey
        self.metric = metric
        self.threshold = threshold
        self.target = target
        self.restoreXp = restoreXp
        self.state = state
    }

    public var goal: QuestGoal { QuestGoal(metric: metric, threshold: threshold) }

    /// The systems the make-up touches — the same icons the missed directive carried for that metric.
    public var rewards: [QuestReward] {
        switch metric {
        case .steps: return [.heart, .lungs]
        case .sleepHours, .bedtimeBy, .bedtimeEarlier: return [.sleep]
        case .workoutMinutes, .strain: return [.muscle, .heart]
        case .meditationMinutes: return [.brain, .stress]
        case .waterMl: return [.heart]
        case .journal: return [.brain]
        }
    }
}

// MARK: - Judgements

/// What a closed quest was judged as.
public enum QuestJudgementOutcome: String, Codable, Equatable, Sendable {
    /// Measured, and short. XP was taken.
    case penalised = "PENALISED"
    /// Nothing to check it against. No penalty — ever.
    case notMeasured = "NOT_MEASURED"
    /// Judged short, then later data showed it met. Refunded in full.
    case metLate = "MET_LATE"
    /// Missed, on a figure the body sets (or strain after real training). Reported, never charged.
    case reported = "REPORTED"
}

/// A quest waiting to be judged: its window has closed (or it was abandoned), and the data decides.
public struct QuestJudgementSubject: Codable, Equatable, Sendable {
    public let questId: String
    public let kind: QuestKind
    public let dayKey: String
    public let title: String
    public let target: String
    public let metric: QuestMetric?
    public let threshold: Double?
    public let xp: Int
    /// The gear the day ran in, for a quest that gear scaled. Nil otherwise.
    public let gear: QuestDifficulty?
    /// Not judged before this. A quest's own "checkable until" — an abandoned quest is judged at the
    /// deadline it would have had, on the data, like any other.
    public let judgeAfterMs: Int64

    public init(questId: String, kind: QuestKind, dayKey: String, title: String, target: String,
                goal: QuestGoal?, xp: Int, gear: QuestDifficulty?, judgeAfterMs: Int64) {
        self.questId = questId
        self.kind = kind
        self.dayKey = dayKey
        self.title = title
        self.target = target
        self.metric = goal?.metric
        self.threshold = goal?.threshold
        self.xp = xp
        self.gear = gear
        self.judgeAfterMs = judgeAfterMs
    }

    /// The subject for `quest`. The gear only counts for a quest the gear actually scaled.
    public init(quest: Quest, gear: QuestDifficulty?, judgeAfterMs: Int64? = nil) {
        self.init(questId: quest.id, kind: quest.kind, dayKey: quest.dayKey, title: quest.title,
                  target: quest.target, goal: quest.effectiveGoal, xp: quest.xp,
                  gear: QuestDayPlan.isPlanQuest(quest) ? gear : nil,
                  judgeAfterMs: judgeAfterMs ?? quest.checkableUntilMs())
    }

    public var goal: QuestGoal? {
        guard let metric, let threshold else { return nil }
        return QuestGoal(metric: metric, threshold: threshold)
    }
}

/// One closed quest, judged.
public struct QuestJudgement: Codable, Equatable, Sendable, Identifiable {
    public var id: String { questId }

    public let questId: String
    public let kind: QuestKind
    public let dayKey: String
    public let title: String
    public let target: String
    public let metric: QuestMetric?
    public let threshold: Double?
    public let gear: QuestDifficulty?
    public let judgedAtMs: Int64
    public var outcome: QuestJudgementOutcome
    /// What was measured against what was asked, from the same evidence the judgement used.
    public var reading: String
    /// 0...1 — see `QuestGoal.shortfall`.
    public var shortfall: Double
    /// Earlier misses of the same metric inside the escalation window.
    public var priorMisses: Int
    /// What the rules priced the miss at, before overlap and the balance floor.
    public var nominalCost: Int
    /// What actually left the balance. Zero or negative.
    public var applied: Int
    /// XP given back when later data showed the quest met.
    public var refunded: Int
    /// Another judgement for the same metric on the same day that already carries this miss.
    public var overlapOf: String?
    /// The daily streak this miss ended, when it was the daily quest and a streak was running.
    public var streakBroken: Int?
    public var debt: QuestDebt?
    /// Why no make-up was issued, when none was.
    public var noDebtReason: String?
    /// Why a miss was reported rather than charged, or what made an effort miss chargeable.
    public var note: String?

    public init(questId: String, kind: QuestKind, dayKey: String, title: String, target: String,
                metric: QuestMetric?, threshold: Double?, gear: QuestDifficulty?, judgedAtMs: Int64,
                outcome: QuestJudgementOutcome, reading: String, shortfall: Double = 0,
                priorMisses: Int = 0, nominalCost: Int = 0, applied: Int = 0, refunded: Int = 0,
                overlapOf: String? = nil, streakBroken: Int? = nil, debt: QuestDebt? = nil,
                noDebtReason: String? = nil, note: String? = nil) {
        self.questId = questId
        self.kind = kind
        self.dayKey = dayKey
        self.title = title
        self.target = target
        self.metric = metric
        self.threshold = threshold
        self.gear = gear
        self.judgedAtMs = judgedAtMs
        self.outcome = outcome
        self.reading = reading
        self.shortfall = shortfall
        self.priorMisses = priorMisses
        self.nominalCost = nominalCost
        self.applied = applied
        self.refunded = refunded
        self.overlapOf = overlapOf
        self.streakBroken = streakBroken
        self.debt = debt
        self.noDebtReason = noDebtReason
        self.note = note
    }

    public var goal: QuestGoal? {
        guard let metric, let threshold else { return nil }
        return QuestGoal(metric: metric, threshold: threshold)
    }

    /// What this miss has cost so far, net of anything given back. Never negative.
    public var netCost: Int {
        let restored = debt?.state == .cleared ? (debt?.restoreXp ?? 0) : 0
        return Swift.max(0, -applied - restored - refunded)
    }
}

/// How often one metric was missed.
public struct QuestMissCount: Equatable, Sendable {
    public let metric: QuestMetric
    public let count: Int

    public init(metric: QuestMetric, count: Int) {
        self.metric = metric
        self.count = count
    }
}

// MARK: - The ledger

/// The game layer's books: the XP balance, the daily streak, every judgement of the last month, the
/// quests waiting to be judged, and the keys that make every operation happen exactly once.
public struct QuestLedger: Codable, Equatable, Sendable {

    public private(set) var balance: Int = 0
    /// Daily quests completed in a row, with no measured miss of the daily in between.
    public private(set) var streak: Int = 0
    public private(set) var bestStreak: Int = 0
    public private(set) var judgements: [QuestJudgement] = []
    public private(set) var pending: [QuestJudgementSubject] = []
    /// Idempotence keys: a quest is paid once, however many times it is reported complete.
    public private(set) var settled: [String] = []
    /// Whether the completions that pre-date the ledger have been paid in.
    public var seeded: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case balance, streak, bestStreak, judgements, pending, settled, seeded
    }

    // Tolerant: a field a future build adds, or one an older build never wrote, degrades to its default
    // rather than failing the whole read and silently resetting the books.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = try c.decodeIfPresent(Int.self, forKey: .balance) ?? 0
        streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
        bestStreak = try c.decodeIfPresent(Int.self, forKey: .bestStreak) ?? 0
        judgements = (try? c.decodeIfPresent([QuestJudgement].self, forKey: .judgements)) ?? []
        pending = (try? c.decodeIfPresent([QuestJudgementSubject].self, forKey: .pending)) ?? []
        settled = try c.decodeIfPresent([String].self, forKey: .settled) ?? []
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
    }

    // MARK: Paying out

    /// Pay a completed quest. Idempotent. Returns the XP added.
    ///
    /// A MAKE-UP QUEST DOES NOT PAY ITS OWN XP: completing one clears its debt, which gives back its
    /// share of the lost XP (`clearDebt`) — and nothing else.
    @discardableResult
    public mutating func credit(questId: String, kind: QuestKind, xp: Int) -> Int {
        let key = "credit-\(questId)"
        guard !settled.contains(key) else { return 0 }
        settle(key)
        // A quest completed while it was waiting to be judged is no longer anything to judge.
        pending.removeAll { $0.questId == questId }
        if QuestDebt.isDebtQuest(questId) { return clearDebt(debtQuestId: questId) }
        let paid = Swift.max(0, xp)
        balance += paid
        if kind == .daily {
            streak += 1
            bestStreak = Swift.max(bestStreak, streak)
        }
        return paid
    }

    /// Whether `questId` has been paid.
    public func isCredited(_ questId: String) -> Bool { settled.contains("credit-\(questId)") }

    // MARK: Judging

    /// Queue a closed quest for judgement. Idempotent; refuses one already paid or judged.
    @discardableResult
    public mutating func enqueue(_ subject: QuestJudgementSubject) -> Bool {
        guard QuestPenaltyRules.isPenalisable(kind: subject.kind, questId: subject.questId),
              !pending.contains(where: { $0.questId == subject.questId }),
              !judgements.contains(where: { $0.questId == subject.questId }),
              !isCredited(subject.questId) else { return false }
        pending.append(subject)
        return true
    }

    public enum JudgeResult: Equatable, Sendable {
        /// Not pending, or its time has not come.
        case notDue
        /// Nothing measured yet, and the grace for late data is still running.
        case awaitingData
        /// The data meets it. The caller completes the quest — and the completion pays it.
        case met
        case judged(QuestJudgement)
    }

    /// Judge one pending quest against `evidence` (nil = nothing could be read at all).
    public mutating func judge(questId: String, evidence: QuestEvidence?, nowMs: Int64,
                               context: QuestDebtContext) -> JudgeResult {
        guard let index = pending.firstIndex(where: { $0.questId == questId }) else { return .notDue }
        let s = pending[index]
        guard nowMs >= s.judgeAfterMs else { return .notDue }

        // Too old to read reliably is the same as not read at all.
        let age = QuestDayMath.days(from: s.dayKey, to: context.today) ?? Int.max
        let readable = age <= QuestPenaltyRules.judgeableMaxAgeDays ? evidence : nil
        let short = s.goal.flatMap { goal in readable.flatMap { goal.shortfall($0) } }

        if short == 0 {
            pending.remove(at: index)
            return .met
        }
        guard let short, let goal = s.goal, let readable else {
            // NOT MEASURED. Wait for late data while the grace runs and the day is still readable; after
            // that it closes as exactly what it is — not measured, no penalty.
            if s.goal != nil, age <= QuestPenaltyRules.judgeableMaxAgeDays,
               nowMs < s.judgeAfterMs + QuestPenaltyRules.lateDataGraceMs {
                return .awaitingData
            }
            pending.remove(at: index)
            let j = QuestJudgement(
                questId: s.questId, kind: s.kind, dayKey: s.dayKey, title: s.title, target: s.target,
                metric: s.metric, threshold: s.threshold, gear: s.gear, judgedAtMs: nowMs,
                outcome: .notMeasured,
                reading: s.goal == nil ? "Nothing the app can measure." : "No data for this metric.")
            judgements.append(j)
            return .judged(j)
        }

        pending.remove(at: index)

        // BEHAVIOUR, NEVER PHYSIOLOGY. A miss the body decided is reported with its reading and costs
        // nothing — no XP, no streak, no make-up. Strain is charged only as "did not train at all".
        var chargeable = short
        var chargedNote: String?
        var reportNote: String?
        switch goal.metric.penaltyClass {
        case .behaviour:
            break
        case .physiology:
            reportNote = "The body sets this one: reported, never penalised."
        case .effort:
            switch readable.workoutMinutes {
            case .some(let minutes) where minutes <= 0:
                chargeable = 1
                chargedNote = "No training at all, on a day whose band asked for it."
            case .some:
                reportNote = "You trained. The strain it produced is the body's number, not a miss."
            case .none:
                reportNote = "Whether you trained could not be read, so there is no penalty."
            }
        }
        if let reportNote {
            let j = QuestJudgement(
                questId: s.questId, kind: s.kind, dayKey: s.dayKey, title: s.title, target: s.target,
                metric: s.metric, threshold: s.threshold, gear: s.gear, judgedAtMs: nowMs,
                outcome: .reported, reading: goal.summary(readable), shortfall: short, note: reportNote)
            judgements.append(j)
            return .judged(j)
        }

        let prior = priorMisses(metric: goal.metric, day: s.dayKey, excluding: s.questId)
        let nominal = QuestPenalty.cost(xp: s.xp, gear: s.gear, shortfall: chargeable, priorMisses: prior)

        // ONE MISS, ONE PENALTY: a second quest on the same day asking for the same metric is the same
        // miss. Only what it costs ABOVE the one already charged is charged.
        let overlap = judgements
            .filter { $0.outcome == .penalised && $0.dayKey == s.dayKey && $0.metric == goal.metric }
            .max { $0.nominalCost < $1.nominalCost }
        let charge = overlap.map { Swift.max(0, nominal - $0.nominalCost) } ?? nominal

        let after = Swift.max(QuestPenaltyRules.balanceFloor, balance - charge)
        let applied = Swift.min(0, after - balance)
        balance += applied

        var j = QuestJudgement(
            questId: s.questId, kind: s.kind, dayKey: s.dayKey, title: s.title, target: s.target,
            metric: s.metric, threshold: s.threshold, gear: s.gear, judgedAtMs: nowMs,
            outcome: .penalised, reading: goal.summary(readable), shortfall: chargeable,
            priorMisses: prior, nominalCost: nominal, applied: applied, overlapOf: overlap?.questId,
            note: chargedNote)

        // MISSING THE DAILY BREAKS THE STREAK.
        if s.kind == .daily {
            if streak > 0 { j.streakBroken = streak }
            streak = 0
        }

        if overlap != nil {
            j.noDebtReason = "Covered by the make-up for the same metric that day."
        } else if applied == 0 {
            j.noDebtReason = "Nothing was taken, so there is nothing to win back."
        } else {
            switch QuestDebtPolicy.decide(goal: goal, shortfall: chargeable, kind: s.kind, questId: s.questId,
                                          missedDay: s.dayKey, context: context) {
            case .none(let reason):
                j.noDebtReason = reason
            case .issue(let debtGoal, let target):
                let id = QuestDebt.questId(day: context.today, metric: debtGoal.metric)
                if judgements.contains(where: { $0.debt?.questId == id }) {
                    j.noDebtReason = "A make-up for this metric is already set for today."
                } else {
                    let restore = Swift.max(1, Int((Double(-applied) * QuestPenaltyRules.restoreFraction).rounded()))
                    j.debt = QuestDebt(questId: id, dayKey: context.today, metric: debtGoal.metric,
                                       threshold: debtGoal.threshold, target: target, restoreXp: restore)
                }
            }
        }
        judgements.append(j)
        return .judged(j)
    }

    /// Distinct earlier DAYS inside the window on which `metric` was missed and charged.
    public func priorMisses(metric: QuestMetric, day: String, excluding questId: String) -> Int {
        let days = judgements.filter {
            guard $0.outcome == .penalised, $0.metric == metric, $0.questId != questId,
                  let d = QuestDayMath.days(from: $0.dayKey, to: day) else { return false }
            return d >= 1 && d <= QuestPenaltyRules.escalationWindowDays
        }.map(\.dayKey)
        return Set(days).count
    }

    // MARK: Correcting

    /// Later data met a quest that was judged short: refund everything it still cost, withdraw its
    /// make-up, and give back the streak it broke. Returns the refund and the withdrawn make-up's id.
    @discardableResult
    public mutating func void(questId: String) -> (refund: Int, withdrawnDebt: String?) {
        guard let i = judgements.firstIndex(where: { $0.questId == questId && $0.outcome == .penalised })
        else { return (0, nil) }
        var j = judgements[i]
        let refund = j.netCost
        balance += refund
        j.refunded = refund
        j.outcome = .metLate
        var withdrawn: String?
        if var debt = j.debt, debt.state == .open {
            debt.state = .withdrawn
            j.debt = debt
            withdrawn = debt.questId
        }
        if let broken = j.streakBroken {
            streak += broken
            bestStreak = Swift.max(bestStreak, streak)
        }
        judgements[i] = j
        return (refund, withdrawn)
    }

    /// The make-up quest was met: give back its share. Idempotent. Returns the XP restored.
    @discardableResult
    public mutating func clearDebt(debtQuestId: String) -> Int {
        guard let i = judgements.firstIndex(where: { $0.debt?.questId == debtQuestId && $0.debt?.state == .open }),
              var debt = judgements[i].debt else { return 0 }
        debt.state = .cleared
        judgements[i].debt = debt
        balance += debt.restoreXp
        return debt.restoreXp
    }

    /// The make-up quest ran out unmet. The original penalty stands; nothing more is charged.
    public mutating func lapseDebt(debtQuestId: String) {
        guard let i = judgements.firstIndex(where: { $0.debt?.questId == debtQuestId && $0.debt?.state == .open }),
              var debt = judgements[i].debt else { return }
        debt.state = .lapsed
        judgements[i].debt = debt
    }

    /// Every make-up still open.
    public var openDebts: [QuestDebt] {
        judgements.compactMap { $0.debt }.filter { $0.state == .open }
    }

    /// Drop history past `historyDays`, and bound the idempotence keys.
    public mutating func prune(today: String) {
        judgements.removeAll {
            guard let age = QuestDayMath.days(from: $0.dayKey, to: today) else { return true }
            return age > QuestPenaltyRules.historyDays && $0.debt?.state != .open
        }
        if settled.count > QuestPenaltyRules.settledKept {
            settled = Array(settled.suffix(QuestPenaltyRules.settledKept))
        }
    }

    private mutating func settle(_ key: String) {
        settled.append(key)
        if settled.count > QuestPenaltyRules.settledKept {
            settled.removeFirst(settled.count - QuestPenaltyRules.settledKept)
        }
    }

    // MARK: Reading

    /// What sits pinned above the quests: every judgement from the last `pinnedDays`, plus any whose
    /// make-up is still open — newest first. A cleared make-up takes its miss off the board (it lives on
    /// in the history), and a quest later met is nothing to show.
    public func pinned(today: String) -> [QuestJudgement] {
        judgements.filter { j in
            if j.outcome == .metLate { return false }
            if j.debt?.state == .open { return true }
            if j.debt?.state == .cleared { return false }
            guard let age = QuestDayMath.days(from: j.dayKey, to: today) else { return false }
            return age >= 0 && age <= QuestPenaltyRules.pinnedDays
        }
        .sorted { ($0.dayKey, $0.judgedAtMs) > ($1.dayKey, $1.judgedAtMs) }
    }

    /// The last `historyDays` of judgements, newest first.
    public func history(today: String) -> [QuestJudgement] {
        judgements.filter { j in
            guard let age = QuestDayMath.days(from: j.dayKey, to: today) else { return false }
            return age >= 0 && age <= QuestPenaltyRules.historyDays
        }
        .sorted { ($0.dayKey, $0.judgedAtMs) > ($1.dayKey, $1.judgedAtMs) }
    }

    /// Which metrics were missed (and charged) most in the history window — the pattern the owner looks
    /// for. Most-missed first; ties in a fixed order so the list does not shuffle between renders.
    public func missCounts(today: String) -> [QuestMissCount] {
        var counts: [QuestMetric: Int] = [:]
        for j in history(today: today) where j.outcome == .penalised {
            if let m = j.metric { counts[m, default: 0] += 1 }
        }
        return counts.map { QuestMissCount(metric: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.metric.rawValue < $1.metric.rawValue }
    }

    /// XP lost to penalties in the history window, net of refunds and restorations.
    public func netLost(today: String) -> Int { history(today: today).reduce(0) { $0 + $1.netCost } }

    /// XP won back by cleared make-ups in the history window.
    public func restored(today: String) -> Int {
        history(today: today).reduce(0) { $0 + ($1.debt?.state == .cleared ? ($1.debt?.restoreXp ?? 0) : 0) }
    }

    /// The balance as the board prints it. Negative is said in words, not just with a sign.
    public var balanceText: String {
        balance < 0 ? "IN THE RED · \(QuestPenaltyText.signed(balance)) XP" : "\(balance) XP"
    }
}

// MARK: - Words

/// The penalty system's sentences, locale-fixed like `QuestDayPlan`'s — pinned by tests.
public enum QuestPenaltyText {

    /// "−24" with a real minus sign; "+12"; "0".
    public static func signed(_ v: Int) -> String {
        v < 0 ? "\u{2212}\(-v)" : (v > 0 ? "+\(v)" : "0")
    }

    /// "Today", "Yesterday", "3 days ago".
    public static func when(_ dayKey: String, today: String) -> String {
        switch QuestDayMath.days(from: dayKey, to: today) {
        case .some(0): return "Today"
        case .some(1): return "Yesterday"
        case .some(let n) where n > 1: return "\(n) days ago"
        default: return dayKey
        }
    }

    /// "2nd", "3rd", "4th".
    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch n % 100 {
        case 11, 12, 13: suffix = "th"
        default:
            switch n % 10 {
            case 1: suffix = "st"
            case 2: suffix = "nd"
            case 3: suffix = "rd"
            default: suffix = "th"
            }
        }
        return "\(n)\(suffix)"
    }

    /// "×1.0", "×1.5", "×0.75" — two decimals only where the second one says something.
    static func factor(_ v: Double) -> String {
        var s = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
        if s.hasSuffix("0") { s.removeLast() }
        return "×" + s
    }
}

extension QuestMetric {

    /// The metric's name in the penalty record's "missed most" list.
    public var penaltyLabel: String {
        switch self {
        case .steps: return "Steps"
        case .workoutMinutes: return "Training"
        case .meditationMinutes: return "Meditation"
        case .waterMl: return "Water"
        case .strain: return "Strain"
        case .sleepHours: return "Sleep"
        case .bedtimeBy: return "Bedtime"
        case .bedtimeEarlier: return "Earlier bedtime"
        case .journal: return "Journal"
        }
    }
}

extension QuestJudgement {

    /// "−24 XP", "No penalty", "Refunded".
    public var costText: String {
        switch outcome {
        case .notMeasured, .reported: return "No penalty"
        case .metLate: return "Refunded"
        case .penalised: return applied < 0 ? "\(QuestPenaltyText.signed(applied)) XP" : "0 XP"
        }
    }

    /// Why it cost what it cost: "31 % short · Relentless ×1.0 · 2nd miss ×1.5". Empty unless penalised.
    public var reasonText: String {
        guard outcome == .penalised else { return "" }
        var parts = ["\(Int((shortfall * 100).rounded())) % short"]
        let gearName = gear?.title ?? "No gear"
        parts.append("\(gearName) \(QuestPenaltyText.factor(QuestPenaltyRules.gearFactor(gear)))")
        if priorMisses > 0 {
            parts.append("\(QuestPenaltyText.ordinal(priorMisses + 1)) miss "
                + QuestPenaltyText.factor(QuestPenalty.escalation(priorMisses: priorMisses)))
        }
        if overlapOf != nil { parts.append("same miss as another quest, charged once") }
        if applied > -nominalCost, overlapOf == nil {
            parts.append("balance floor reached")
        }
        return parts.joined(separator: " · ")
    }

    /// The make-up line, if there is one to say.
    public var debtText: String? {
        if let debt {
            switch debt.state {
            case .open: return "Make-up open: \(debt.target) · clears \(QuestPenaltyText.signed(debt.restoreXp)) XP back"
            case .cleared: return "Make-up cleared · \(QuestPenaltyText.signed(debt.restoreXp)) XP back"
            case .lapsed: return "Make-up lapsed · the penalty stands"
            case .withdrawn: return "Make-up withdrawn · the data met the quest after all"
            }
        }
        guard outcome == .penalised else { return nil }
        return noDebtReason
    }

    /// The streak line, when this miss ended one.
    public var streakText: String? {
        guard outcome == .penalised, kind == .daily else { return nil }
        if let streakBroken { return "Daily streak broken · was \(streakBroken)" }
        return "Daily streak reset"
    }

    /// The line under the title: what was measured, or why nothing was charged.
    public var detailText: String {
        switch outcome {
        case .penalised: return note.map { "\($0) \(reading)" } ?? reading
        case .notMeasured: return "Not measured, no penalty. \(reading)"
        case .metLate: return "The data met it after all. \(QuestPenaltyText.signed(refunded)) XP refunded."
        case .reported: return "Missed, no penalty. \(note ?? "")" + (reading.isEmpty ? "" : " \(reading)")
        }
    }
}

// MARK: - The day card

/// The one card that closes a chosen-gear day — the plan summary, with the numbers and the penalty on
/// every line that fell short.
public struct QuestPenaltyDayCard: Equatable, Sendable {
    public let overline: String
    public let title: String
    public let subtitle: String
    public let message: String
    /// XP the day's plan misses took.
    public let totalCost: Int

    /// Build the card from the day's plan report and the judgements of that day's plan quests.
    ///
    /// Lines are matched by the directive text, which is stable per day and metric (`QuestDayPlan`).
    public static func make(report: QuestPlanDayReport, judgements: [QuestJudgement]) -> QuestPenaltyDayCard {
        let byTarget = Dictionary(judgements.map { ($0.target, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [String] = []
        var total = 0
        for line in report.lines {
            guard let j = byTarget[line.target] else {
                lines.append(line.text)
                continue
            }
            switch j.outcome {
            case .penalised:
                total += -j.applied
                lines.append("Short · \(j.reading.isEmpty ? j.target : j.reading) — \(j.costText) "
                    + "(\(j.reasonText))")
                if let debt = j.debtText { lines.append("   \(debt)") }
            case .notMeasured:
                lines.append("Not measured · \(j.target) — no penalty")
            case .reported:
                lines.append("Short · \(j.reading.isEmpty ? j.target : j.reading) — no penalty "
                    + "(\(j.note ?? "reported"))")
            case .metLate:
                lines.append("Met · \(j.target)")
            }
        }
        let gear = report.difficulty.title
        let lead = total > 0
            ? "You picked \(gear). The day did not hold it, and it cost you:"
            : report.lead
        let footer = "Penalties move XP, streaks and make-ups only. Your Level is measured from your "
            + "body, and a missed quest never changes it."
        return QuestPenaltyDayCard(
            overline: total > 0 ? "DIRECTIVES FAILED" : "DAY CLOSED",
            title: total > 0 ? "\(QuestPenaltyText.signed(-total)) XP" : report.headline,
            subtitle: total > 0 ? "\(report.headline.uppercased()) · \(report.subtitle)" : report.subtitle,
            message: ([lead, ""] + lines + ["", footer]).joined(separator: "\n"),
            totalCost: total)
    }
}
