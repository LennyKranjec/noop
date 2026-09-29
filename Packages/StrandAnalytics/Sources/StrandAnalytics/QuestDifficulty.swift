import Foundation

// QuestDifficulty.swift — the day's chosen gear, and the targets that follow from it.
//
// The morning flow ends with a choice: how hard today is supposed to be. The choice is the ONLY thing
// the wearer sets; every number that follows from it is scaled off their OWN measured history, here, in
// one place.
//
// WHY THE CHOICE CANNOT SET THE NUMBERS. "Hard mode = 15,000 steps" is a made-up number wearing a
// difficulty label: for one wearer it is a walk to the shop and for another it is unreachable, and
// neither of them learns anything from meeting or missing it. So a difficulty is a MULTIPLIER on what
// this wearer actually does — their own recent median steps, their own hydration goal, their own sleep
// need, the day's own recommended effort band — and the whole table of multipliers is `Scale` below.
//
// NOTHING IS INVENTED AND NOTHING IS GUESSED. A baseline field this wearer has no data for is nil, and
// a nil baseline produces NO target for that metric rather than a target off a substituted default:
// `QuestBaseline` is all-optional on purpose, and `targets(...)` skips what it cannot scale. A wearer
// with five days of step counts and nothing else gets one step quest and no others, which is the
// honest answer.
//
// THIN DATA IS NO DATA. `minBaselineDays` samples are needed before a median counts as a baseline —
// the same bar `QuestTriggers`' HRV trigger sets for its own baseline. A target scaled off two days is
// a target scaled off noise.
//
// EVERY TARGET IS CHECKABLE. Each one carries a `QuestGoal`, so the quest it becomes closes itself on
// the wearer's data (`QuestAutoComplete`) rather than on their word. A metric the app cannot read for
// this wearer never reaches a baseline field at all — see the note on `effortBand21`, which is only
// ever set when the day's strain is actually being measured.
//
// THE GEAR RESPECTS THE DAY (HEALTH_V2 H9). The ambition stays on behaviour that is safe to push — steps,
// water, meditation, the journal — and training and effort are bounded by the day's state
// (`QuestDayState`): on an `easy` or `rest` day (low Charge, illness heads-up) training and strain drop
// to Steady's factors and the training directive becomes easy movement of at most 30 minutes; on a
// `moveHard` day no training factor exceeds 1.0 and the strain point stops at the band's middle. Steps
// are never reduced: walking is compatible with recovery.
//
// ONE BEDTIME FOR EVERY GEAR (HEALTH_V2 H9b / S2). The bedtime threshold is the sleep anchor's
// (`QuestBaseline.bedtimeTargetMin`, from `SleepAnchor`), the same whichever gear was picked — the gear
// used to pull bedtime 20–40 minutes earlier by the morning's choice, which made bedtimes LESS regular.
// The gear only decides WHETHER a bedtime directive is issued (Steady no, Push yes, Relentless yes plus a
// wind-down directive). Swift-only change; the Android twin is not updated in 2.0.
//
// Pure + deterministic, so the whole table is unit-tested without a strap, an app target or a model —
// and so an Android twin, when it is written, can assert the same numbers off the same constants.

/// How hard today is meant to be. Three gears, chosen in the morning flow and held for the day.
///
/// The raw values are the stored form (`QuestModeStore`): stable strings rather than ordinals, so a
/// stored choice survives a reordering of the cases and reads the same on any platform that adopts it.
public enum QuestDifficulty: String, Equatable, Codable, CaseIterable, Sendable {
    /// Hold the line: roughly what this wearer already does, and a full night.
    case steady = "STEADY"
    /// A real step up on their own normal.
    case push = "PUSH"
    /// The top of what the day's own data says is sensible — never past it.
    case relentless = "RELENTLESS"

    /// The name on the card.
    public var title: String {
        switch self {
        case .steady: return "Steady"
        case .push: return "Push"
        case .relentless: return "Relentless"
        }
    }

    /// One line of what it actually costs. Honest about effort, and never a promise about a result.
    public var blurb: String {
        switch self {
        case .steady: return "Hold your own normal. Two directives, scaled to what you already do."
        case .push: return "A real step up on your own numbers. Three directives, and your anchored bedtime."
        case .relentless:
            return "The top of what today's data says is sensible. Four directives, and a wind-down."
        }
    }

    /// How many directives the day gets. More gears, more to carry.
    public var questCount: Int {
        switch self {
        case .steady: return 2
        case .push: return 3
        case .relentless: return 4
        }
    }

    /// What one of this mode's quests is worth. Clamped by `QuestCodec` either way.
    public var xp: Int {
        switch self {
        case .steady: return 35
        case .push: return 50
        case .relentless: return 70
        }
    }

    /// THE WHOLE MULTIPLIER TABLE, in one place. Every number a difficulty changes is here and nowhere
    /// else, so "what does Relentless actually ask for" has one answer that can be read off a screen.
    ///
    /// Each factor multiplies a figure measured on this wearer:
    ///   - `steps` × their recent median daily steps
    ///   - `water` × the day's own hydration goal (`HydrationGoal.dailyGoalML`)
    ///   - `training` × the median length of their training days
    ///   - `meditation` × the median length of their meditation sessions
    ///   - `sleep` × their personal sleep need (`AnalyticsEngine.Rest.engineNeedHours`)
    ///   - `bandPosition` picks a point in the day's recommended effort band (0 = its floor, 1 = its top)
    ///   - `issuesBedtime` / `issuesWindDown` decide WHETHER a bedtime / wind-down directive is issued.
    ///     The bedtime itself is the sleep anchor's, identical for every gear (H9b) — no gear moves it.
    ///
    /// Two deliberate asymmetries. `sleep` barely moves (0.95 → 1.05): sleeping far past your need is
    /// not a harder day, it is a different one, and the ambition in a sleep directive is hitting the
    /// need at all. And `bandPosition` never exceeds 1: the band's top is what the day's own charge says
    /// is sensible, so Relentless asks for the top of it and never for a point past it — a difficulty
    /// setting must not be able to talk the wearer into overreaching.
    public struct Scale: Equatable, Sendable {
        public let steps: Double
        public let water: Double
        public let training: Double
        public let meditation: Double
        public let sleep: Double
        public let bandPosition: Double
        /// Whether the gear issues a bedtime directive (at the anchor, never shifted).
        public let issuesBedtime: Bool
        /// Whether the gear also issues a wind-down directive (a journal entry as the evening winds down).
        public let issuesWindDown: Bool
    }

    public var scale: Scale {
        switch self {
        case .steady:
            return Scale(steps: 1.00, water: 0.85, training: 0.75, meditation: 1.00,
                         sleep: 0.95, bandPosition: 0.0, issuesBedtime: false, issuesWindDown: false)
        case .push:
            return Scale(steps: 1.15, water: 1.00, training: 1.00, meditation: 1.50,
                         sleep: 1.00, bandPosition: 0.5, issuesBedtime: true, issuesWindDown: false)
        case .relentless:
            return Scale(steps: 1.35, water: 1.10, training: 1.30, meditation: 2.00,
                         sleep: 1.05, bandPosition: 1.0, issuesBedtime: true, issuesWindDown: true)
        }
    }
}

/// What the day's body allows, for the gear's training and effort directives (HEALTH_V2 H9a).
///
/// The cases mirror S3's `DayGuidance` (`asPlanned`, `moveHard`, `easy`, `rest`) so the week plan can map
/// onto it one to one when it lands; until then `standIn(charge:illnessRaised:)` derives it from the two
/// figures the app already has, the same stand-in the penalty rules use (`charge < QuestTriggers.chargeLow`).
public enum QuestDayState: String, Equatable, Codable, CaseIterable, Sendable {
    /// Nothing holds the day back — or nothing was measured this morning (never invented as low).
    case asPlanned
    /// Hard sessions are not advised: no training factor above 1.0, effort no higher than mid-band.
    case moveHard
    /// A recovery day: training and effort at Steady's factors; training is easy movement ≤ 30 min.
    case easy
    /// An illness heads-up is up: as `easy`.
    case rest

    /// Whether the day is suppressed for training (easy or rest).
    public var isRecoveryDay: Bool { self == .easy || self == .rest }

    /// Until S3's week plan exists: illness heads-up ⇒ rest; Charge under `QuestTriggers.chargeLow` ⇒
    /// easy; anything else, including an unknown Charge, ⇒ as planned.
    public static func standIn(charge: Double?, illnessRaised: Bool) -> QuestDayState {
        if illnessRaised { return .rest }
        guard let charge, charge.isFinite else { return .asPlanned }
        return charge < QuestTriggers.chargeLow ? .easy : .asPlanned
    }

    /// On a recovery day the training directive asks for at most this much easy movement.
    public static let easyMovementMaxMinutes: Double = 30
}

/// What this wearer actually does — the figures every target is scaled from.
///
/// ALL OPTIONAL, AND NIL MEANS NIL. A field is set only when the reader found enough of this wearer's
/// own data to call it a baseline (`QuestDayPlan.minBaselineDays`); a field it could not fill stays nil
/// and produces no target. Nothing here has a default, because a default is a fabricated baseline.
public struct QuestBaseline: Equatable, Sendable {
    /// Median daily step count over the recent window.
    public var medianSteps: Double?
    /// The day's own hydration goal in ml — nil when the wearer does not track water, because a water
    /// quest would then be unverifiable.
    public var hydrationGoalMl: Double?
    /// Median length in minutes of the days this wearer trains on (days with no session excluded).
    public var medianTrainingMinutes: Double?
    /// Median length in minutes of their meditation sessions.
    public var medianMeditationMinutes: Double?
    /// Their personal sleep need in hours, as the last analysis pass scored Rest with.
    public var sleepNeedHours: Double?
    /// Median sleep onset, in minutes past midnight on the evening clock. Used for a bedtime directive's
    /// threshold only while there is no sleep anchor (`bedtimeTargetMin`) — the wearer's own usual, never
    /// shifted by the gear.
    public var medianSleepOnsetMinute: Int?
    /// The sleep anchor's asleep-by minute for tonight (`SleepSchedulePlan.asleepByMin`): the ONE bedtime
    /// threshold, the same for every gear (HEALTH_V2 H9b). Nil while the anchor abstains.
    public var bedtimeTargetMin: Int?
    /// What the day's body allows (H9a). Nil is `asPlanned`: an unmeasured morning is not a low one.
    public var dayState: QuestDayState?
    /// The day's recommended day-strain band on WHOOP's 0–21 axis.
    ///
    /// SET ONLY WHEN THE DAY'S STRAIN IS ACTUALLY MEASURED for this wearer. `QuestMetric.strain` is
    /// checked against WHOOP's own cloud strain and nothing stands in for it, so a band without a
    /// strain to check it against would be a quest that can never close. The reader carries the band
    /// and the evidence together for exactly that reason.
    public var effortBand21: ClosedRange<Int>?

    public init(medianSteps: Double? = nil, hydrationGoalMl: Double? = nil,
                medianTrainingMinutes: Double? = nil, medianMeditationMinutes: Double? = nil,
                sleepNeedHours: Double? = nil, medianSleepOnsetMinute: Int? = nil,
                effortBand21: ClosedRange<Int>? = nil, bedtimeTargetMin: Int? = nil,
                dayState: QuestDayState? = nil) {
        self.medianSteps = medianSteps
        self.hydrationGoalMl = hydrationGoalMl
        self.medianTrainingMinutes = medianTrainingMinutes
        self.medianMeditationMinutes = medianMeditationMinutes
        self.sleepNeedHours = sleepNeedHours
        self.medianSleepOnsetMinute = medianSleepOnsetMinute
        self.effortBand21 = effortBand21
        self.bedtimeTargetMin = bedtimeTargetMin
        self.dayState = dayState
    }
}

/// One scaled directive, ready to become a quest.
///
/// The same shape `QuestTrigger` has, for the same reason: the directive and its number are decided
/// here, and a model only ever gets to name the thing (`QuestGenerator`).
public struct QuestPlanTarget: Equatable, Sendable {
    /// Stable within a day, so re-picking a difficulty replaces rather than duplicates.
    public let id: String
    /// What the system saw, handed to the model as the reason.
    public let observation: String
    /// The directive, with its number already in it.
    public let target: String
    public let rewards: [QuestReward]
    public let xp: Int
    /// What closes it.
    public let goal: QuestGoal
    /// Which parts of the level this directive plausibly moves — used to put the level's weakest
    /// MEASURED part first. Empty for a directive the level does not read at all (water).
    public let parts: Set<LevelPart>

    public init(id: String, observation: String, target: String, rewards: [QuestReward], xp: Int,
                goal: QuestGoal, parts: Set<LevelPart>) {
        self.id = id
        self.observation = observation
        self.target = target
        self.rewards = rewards
        self.xp = xp
        self.goal = goal
        self.parts = parts
    }
}

extension QuestPlanTarget {

    /// The name used when the model could not be reached at all — same contract as
    /// `QuestNaming.fallbackTitle`: the quest still goes out, under a written name.
    public var fallbackTitle: String {
        switch goal.metric {
        case .steps: return "Ground Covered"
        case .sleepHours: return "Hours Owed"
        case .bedtimeBy, .bedtimeEarlier: return "Lights Out"
        case .workoutMinutes: return "Time Under Load"
        case .strain: return "Matched Effort"
        case .meditationMinutes: return "Nervous System Maintenance"
        case .waterMl: return "Fluid Dynamics"
        case .journal: return "Written Record"
        }
    }

    public var fallbackTaunt: String {
        switch goal.metric {
        case .steps: return "You set the gear. The step counter is holding you to it."
        case .sleepHours: return "You chose the number. Now go and be unconscious for it."
        case .bedtimeBy, .bedtimeEarlier:
            return "A deadline you set yourself. Those are the ones people miss."
        case .workoutMinutes: return "Minutes, logged. Intentions do not appear in the data."
        case .strain: return "Today's own band, nothing past it. Ambition within reason."
        case .meditationMinutes: return "Sitting still is the hardest thing you will do today."
        case .waterMl: return "Water. The intervention with the strongest evidence and the worst compliance."
        case .journal: return "Write it down. Memory is not a data source."
        }
    }
}

/// The day's plan: which directives the chosen difficulty produces, in which order.
public enum QuestDayPlan {

    /// How many of this wearer's own days a median needs before it counts as a baseline. The same bar
    /// `QuestTriggers`' HRV trigger sets for its own baseline — five days of a figure, or no figure.
    public static let minBaselineDays = 5

    /// The window a median is taken over.
    public static let baselineWindowDays = 28

    /// Ids of this mode's quests start with this, so they can be found, replaced and kept out of the
    /// side-quest budget without a new field in the stored record (`QuestCodec`'s wire shape is a
    /// parity contract).
    public static let idPrefix = "plan-"

    /// The id one of the day's mode quests gets. Stable per day and metric: re-picking a difficulty
    /// writes over the same rows rather than stacking a second set.
    public static func questId(day: String, metric: QuestMetric) -> String {
        "\(idPrefix)\(day)-\(metric.rawValue)"
    }

    /// Whether `quest` was issued by a difficulty choice.
    public static func isPlanQuest(_ quest: Quest) -> Bool { quest.id.hasPrefix(idPrefix) }

    /// THE LEVEL'S WEAKEST MEASURED PART, or nil.
    ///
    /// AN ABSTAINING PART IS NOT A WEAK PART. A part the level had no data for scores nil, and nil is
    /// not zero: calling it the day's weakest would aim the whole day at whichever measurement is
    /// simply missing. `LevelBreakdown.levers()` already drops every part with no score and ranks the
    /// rest by headroom, so this is that ranking's head and nothing else — the same rule the coach's
    /// tile uses, read through the same function so the two cannot drift apart.
    public static func focus(_ breakdown: LevelBreakdown?) -> LevelPart? {
        breakdown?.levers().first?.part
    }

    /// Every directive `difficulty` can scale from `baseline`, in issue order.
    ///
    /// The order is fixed except for `focus`: a directive that moves the level's weakest MEASURED part
    /// comes first, and the rest keep their base order behind it (stable, so the same inputs always
    /// produce the same day). Take `difficulty.questCount` of these to get the day's quests — `plan` does,
    /// and adds Relentless's wind-down on top.
    ///
    /// `dayState` overrides `baseline.dayState`; with neither, the day is `asPlanned`.
    public static func targets(baseline: QuestBaseline, difficulty: QuestDifficulty,
                               focus: LevelPart? = nil, day: String,
                               dayState: QuestDayState? = nil) -> [QuestPlanTarget] {
        let s = difficulty.scale
        let steady = QuestDifficulty.steady.scale
        let state = dayState ?? baseline.dayState ?? .asPlanned
        let xp = difficulty.xp
        var out: [QuestPlanTarget] = []
        var windDown: QuestPlanTarget?

        func add(_ metric: QuestMetric, threshold: Double, observation: String, target: String,
                 rewards: [QuestReward], parts: Set<LevelPart>) {
            out.append(QuestPlanTarget(id: questId(day: day, metric: metric),
                                       observation: observation, target: target, rewards: rewards,
                                       xp: xp, goal: QuestGoal(metric: metric, threshold: threshold),
                                       parts: parts))
        }

        // STEPS — off their own median, never below the floor at which a day counts as having happened.
        if let median = baseline.medianSteps, median > 0 {
            let scaled = Swift.max(Double(QuestTriggers.stepsFloor), median * s.steps)
            let steps = Double(round(scaled, to: 250))
            add(.steps, threshold: steps,
                observation: "Their own median is \(whole(median)) steps a day, and they picked "
                    + "\(difficulty.title) for today.",
                target: "\(whole(steps)) steps before the day is out",
                rewards: [.heart, .lungs], parts: [.heart, .lungs])
        }

        // SLEEP — against their own need, which is the only honest anchor for "enough".
        if let need = baseline.sleepNeedHours, need > 0 {
            let hours = (need * s.sleep * 4).rounded() / 4
            add(.sleepHours, threshold: hours,
                observation: "Their own sleep need is \(oneDp(need)) hours and they picked "
                    + "\(difficulty.title) for today.",
                target: "\(oneDp(hours)) hours of sleep tonight",
                rewards: [.sleep, .brain], parts: [.sleep])
        }

        // BEDTIME — ONE threshold for every gear: the sleep anchor's asleep-by, or, while the anchor
        // abstains, the wearer's own median onset unshifted. The gear only decides whether it is issued.
        // ONE EXPRESSION FOR THE NUMBER, read by both the goal and the sentence.
        // The anchor's figure is used EXACTLY as the plan states it; only the median fallback is rounded.
        let anchored = baseline.bedtimeTargetMin.map { wrapMinute($0) }
        let usualOnset = baseline.medianSleepOnsetMinute.map { round(wrapMinute($0), to: 5) }
        if s.issuesBedtime, let deadline = anchored ?? usualOnset {
            let observation = baseline.bedtimeTargetMin != nil
                ? "Their sleep anchor puts asleep-by at \(clock(deadline)) whichever gear they pick, and "
                    + "they picked \(difficulty.title) for today."
                : "They usually fall asleep around \(clock(deadline)) (no sleep anchor yet), and they "
                    + "picked \(difficulty.title) for today."
            add(.bedtimeBy, threshold: Double(deadline), observation: observation,
                target: "Asleep by \(clock(deadline))",
                rewards: [.sleep], parts: [.sleep])
            // WIND-DOWN (Relentless) — a journal entry as the evening winds down, an hour before lights
            // out. The journal is what is checked; the time is the plan's guidance.
            if s.issuesWindDown {
                let start = wrapMinute(deadline - SleepAnchor.onsetBufferMin - SleepAnchor.windDownLeadMin)
                windDown = QuestPlanTarget(
                    id: questId(day: day, metric: .journal),
                    observation: "Their wind-down starts around \(clock(start)), and they picked "
                        + "\(difficulty.title) for today.",
                    target: "A journal entry tonight as you wind down (from \(clock(start)))",
                    rewards: [.brain, .sleep], xp: xp,
                    goal: QuestGoal(metric: .journal, threshold: 1), parts: [])
            }
        }

        // TRAINING — off the length of the days they actually train on, bounded by the day's state.
        if let usual = baseline.medianTrainingMinutes, usual > 0 {
            if state.isRecoveryDay {
                // A recovery day: Steady's factor, and never more than 30 minutes of easy movement.
                let minutes = Swift.min(QuestDayState.easyMovementMaxMinutes,
                                        Double(round(Int((usual * steady.training).rounded()), to: 5)))
                if minutes > 0 {
                    add(.workoutMinutes, threshold: minutes,
                        observation: "Today is a recovery day for their body, so they get easy movement "
                            + "whatever gear they picked (\(difficulty.title)).",
                        target: "\(whole(minutes)) minutes of easy movement — no more than "
                            + "\(whole(QuestDayState.easyMovementMaxMinutes)) today",
                        rewards: [.muscle, .heart], parts: [.muscle, .lungs])
                }
            } else {
                let factor = state == .moveHard ? Swift.min(s.training, 1.0) : s.training
                let minutes = Double(round(Int((usual * factor).rounded()), to: 5))
                if minutes > 0 {
                    add(.workoutMinutes, threshold: minutes,
                        observation: "Their training days run about \(whole(usual)) minutes, and they "
                            + "picked \(difficulty.title) for today"
                            + (state == .moveHard ? ", on a day not suited to hard sessions." : "."),
                        target: state == .moveHard
                            ? "\(whole(minutes)) minutes of easy aerobic or strength at held loads today"
                            : "\(whole(minutes)) minutes of training logged today",
                        rewards: [.muscle, .heart], parts: [.muscle, .lungs])
                }
            }
        }

        // EFFORT — a point in the day's OWN recommended band. Never past its top; see `Scale`. On a
        // recovery day the band's floor (Steady), on a moveHard day no higher than its middle.
        if let band = baseline.effortBand21 {
            let position: Double
            switch state {
            case .easy, .rest: position = steady.bandPosition
            case .moveHard: position = Swift.min(s.bandPosition, 0.5)
            case .asPlanned: position = s.bandPosition
            }
            let span = Double(band.upperBound - band.lowerBound)
            let strain = (Double(band.lowerBound) + span * Swift.min(Swift.max(position, 0), 1))
            let rounded = (strain * 2).rounded() / 2
            add(.strain, threshold: rounded,
                observation: "Today's charge puts their recommended day strain at "
                    + "\(band.lowerBound)–\(band.upperBound) of 21, and they picked "
                    + "\(difficulty.title) for today.",
                target: "A day strain of \(oneDp(rounded)) on WHOOP's scale",
                rewards: [.muscle, .heart], parts: [.muscle, .lungs])
        }

        // MEDITATION — off the length of their own sessions, floored at what counts as one at all ON THIS
        // DAY (`LevelEngine.meditationMinMinutes(on:)`, the one date-effective rule).
        if let usual = baseline.medianMeditationMinutes, usual > 0 {
            let floor = LevelEngine.meditationMinMinutes(on: day)
            let scaled = Swift.max(floor, usual * s.meditation)
            // Rounded to five, then floored again: rounding DOWN to zero or to under what counts as a
            // session at all would be a target met by not sitting down.
            let minutes = Swift.max(floor, Double(round(Int(scaled.rounded()), to: 5)))
            add(.meditationMinutes, threshold: minutes,
                observation: "Their own sessions run about \(whole(usual)) minutes, and they picked "
                    + "\(difficulty.title) for today.",
                target: "\(whole(minutes)) minutes of meditation or slow breathing",
                rewards: [.brain, .stress], parts: [.focus, .heart])
        }

        // WATER — off the day's own goal. Last, and part of no level: the level does not read water, so
        // this can never be the focus, only a filler.
        if let goal = baseline.hydrationGoalMl, goal > 0 {
            let ml = Double(HydrationGoal.roundToNearest(Int((goal * s.water).rounded()),
                                                         step: HydrationGoal.roundToML))
            add(.waterMl, threshold: ml,
                observation: "Their goal for today is \(oneDp(goal / 1000)) L of water, and they "
                    + "picked \(difficulty.title) for today.",
                target: "\(oneDp(ml / 1000)) L of water today",
                rewards: [.heart], parts: [])
        }

        // The wind-down goes LAST: it is issued on top of the gear's count (see `plan`), never in place of
        // one of its measured directives.
        guard let focus else { return out + (windDown.map { [$0] } ?? []) }
        // Stable partition: the focus part's directives first, everything else in its base order.
        let leading = out.filter { $0.parts.contains(focus) }
        return leading + out.filter { !$0.parts.contains(focus) } + (windDown.map { [$0] } ?? [])
    }

    /// The day's quests: `targets(...)` cut to the chosen mode's count, plus Relentless's wind-down
    /// directive on top when the day has a bedtime.
    public static func plan(baseline: QuestBaseline, difficulty: QuestDifficulty,
                            focus: LevelPart? = nil, day: String,
                            dayState: QuestDayState? = nil) -> [QuestPlanTarget] {
        let all = targets(baseline: baseline, difficulty: difficulty, focus: focus, day: day,
                          dayState: dayState)
        let measured = all.filter { $0.goal.metric != .journal }
        var cut = Array(measured.prefix(difficulty.questCount))
        if let windDown = all.first(where: { $0.goal.metric == .journal }) { cut.append(windDown) }
        return cut
    }

    // MARK: - Arithmetic and formatting
    //
    // Locale-fixed, like `QuestTriggers.fmt`: the sentence handed to the model and the directive stored
    // on the quest have to read the same on a German phone as on an American one, and match the twin.

    static func round(_ value: Int, to step: Int) -> Int {
        guard step > 0 else { return value }
        return Int((Double(value) / Double(step)).rounded()) * step
    }

    static func round(_ value: Double, to step: Int) -> Int { round(Int(value.rounded()), to: step) }

    /// Minutes past midnight, wrapped into a day — an onset pulled back past midnight is late evening.
    static func wrapMinute(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }

    static func whole(_ v: Double) -> String { String(Int(v.rounded())) }

    static func oneDp(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v))
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    static func clock(_ minute: Int) -> String {
        let w = wrapMinute(minute)
        return String(format: "%02d:%02d", w / 60, w % 60)
    }

    /// The median of `xs`, or nil when there are fewer than `minBaselineDays` of them.
    ///
    /// A MEDIAN, NOT A MEAN: one 30,000-step hike or one night of four hours must not move what the
    /// wearer is asked for tomorrow.
    public static func median(_ xs: [Double], minSamples: Int = QuestDayPlan.minBaselineDays) -> Double? {
        let sorted = xs.filter { $0.isFinite }.sorted()
        guard sorted.count >= minSamples, !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The median of a set of clock minutes on the EVENING clock, so onsets either side of midnight
    /// average to an evening time rather than to the middle of the afternoon.
    public static func medianOnsetMinute(_ minutes: [Int],
                                        minSamples: Int = QuestDayPlan.minBaselineDays) -> Int? {
        let evening = minutes.map { m -> Double in
            let w = Double(wrapMinute(m))
            return w < 12 * 60 ? w + 1440 : w
        }
        guard let m = median(evening, minSamples: minSamples) else { return nil }
        return wrapMinute(Int(m.rounded()))
    }
}

// MARK: - How the day's plan ended
//
// ONE OUTCOME FOR THE DAY, NOT N FAILURES. A directive that runs out unmet normally gets its own red
// card, because a commitment that quietly vanished would be the system pretending it never asked. That
// is right for a quest the DATA raised; it is wrong for the day's plan. A wearer who picked Relentless
// and took two of its four directives would be handed four red cards the next morning, one at a time —
// four punishments for aiming high, which is the opposite of what the choice is for. So the plan's
// directives are summarised together, once, as an outcome.
//
// AND IT IS EXACT. Three categories, never two:
//
//   * MET — the data closed it (or closed it later than the check that mattered; a completion is never
//     re-litigated here).
//   * SHORT — measured, and under the target. It carries the reading, so "8,400 of the 12,250 asked
//     for" is what the wearer sees rather than a verdict.
//   * NOT MEASURED — there was nothing to check it against. No step count recorded is not zero steps,
//     and a directive whose metric was never read must NOT be reported as a miss. This is the honesty
//     rule the rest of the app is built on, and a summary is exactly where it would be easiest to break.
//
// Partial is partial. Nothing here rounds an unfinished day down to a failure.

extension QuestGoal {

    /// Whether the day's data carries the figure this goal is checked against AT ALL.
    ///
    /// The difference between "not done" and "not known". Written field by field against the same
    /// evidence `isMet` reads, so the two can never disagree about which figure a metric is checked
    /// against — the way they would if this guessed from the metric name.
    public func isMeasured(by e: QuestEvidence) -> Bool {
        switch metric {
        case .steps: return e.steps != nil
        case .workoutMinutes: return e.workoutMinutes != nil
        case .meditationMinutes: return e.meditationMinutes != nil
        case .waterMl: return e.waterMl != nil
        case .strain: return e.strain != nil
        case .sleepHours: return e.nextSleepHours != nil
        case .bedtimeBy: return e.nextSleepOnsetMinute != nil
        case .bedtimeEarlier:
            return e.nextSleepOnsetMinute != nil && e.previousSleepOnsetMinute != nil
        case .journal: return e.journaled != nil
        }
    }
}

/// How one of the day's plan directives ended.
public enum QuestPlanOutcome: String, Equatable, Sendable {
    case met
    /// Measured, and under the target.
    case short
    /// Nothing to check it against. NOT a miss.
    case notMeasured
}

/// One line of the day's outcome.
public struct QuestPlanLine: Equatable, Sendable {
    /// The directive as it was issued.
    public let target: String
    public let outcome: QuestPlanOutcome
    /// What was measured against what was asked, from the SAME evidence the check used — so nothing here
    /// can quote a different number from the one that decided the outcome. Empty when nothing was
    /// measured. Kept on every line, including a met one, as the record of what closed it.
    public let reading: String

    public init(target: String, outcome: QuestPlanOutcome, reading: String = "") {
        self.target = target
        self.outcome = outcome
        self.reading = reading
    }

    /// The line as it is shown: the category, then whichever of the two says more.
    ///
    /// A SHORT LINE CARRIES ITS READING, because "how close" is the whole difference between an outcome
    /// and a verdict. A met one carries the DIRECTIVE instead: it is done, the number is no longer the
    /// point, and the card it is printed on has a phone's width to fit four of these into.
    public var text: String {
        switch outcome {
        case .met: return "Met · " + target
        case .short: return "Short · " + (reading.isEmpty ? target : reading)
        case .notMeasured: return "Not measured · " + target
        }
    }
}

/// The whole day's plan, as it ended.
public struct QuestPlanDayReport: Equatable, Sendable {
    public let day: String
    public let difficulty: QuestDifficulty
    /// One line per directive the day issued, in issue order.
    public let lines: [QuestPlanLine]

    public init(day: String, difficulty: QuestDifficulty, lines: [QuestPlanLine]) {
        self.day = day
        self.difficulty = difficulty
        self.lines = lines
    }

    public var met: [QuestPlanLine] { lines.filter { $0.outcome == .met } }
    public var short: [QuestPlanLine] { lines.filter { $0.outcome == .short } }
    public var notMeasured: [QuestPlanLine] { lines.filter { $0.outcome == .notMeasured } }

    /// Whether there is anything to say.
    ///
    /// A DAY THAT WENT ENTIRELY RIGHT SAYS NOTHING HERE. Every met directive already had its own
    /// completion card with its XP on it, so a summary that only repeated them would be a second
    /// notification about the same good news. The summary exists for the part that did not close.
    public var isWorthShowing: Bool {
        !lines.isEmpty && !(short.isEmpty && notMeasured.isEmpty)
    }

    /// The headline: what was met out of what was asked. The denominator is what the day ISSUED, which
    /// is the only number that is not an interpretation.
    public var headline: String { "\(met.count) of \(lines.count) met" }

    /// The line under it: the gear, how much it asked for, and how much of it the data could not see.
    public var subtitle: String {
        var parts = [difficulty.title.uppercased(),
                     "\(lines.count) DIRECTIVE" + (lines.count == 1 ? "" : "S")]
        if !notMeasured.isEmpty { parts.append("\(notMeasured.count) NOT MEASURED") }
        return parts.joined(separator: " · ")
    }

    /// AN OUTCOME, NOT A SCOLDING. It says where the day landed and then gets out of the way; the only
    /// judgement in it is arithmetic.
    public var lead: String {
        if !met.isEmpty { return "You aimed high and took part of it. Where the day landed:" }
        if short.isEmpty {
            return "None of this could be checked, so none of it is being called a miss:"
        }
        return "This one did not land. Where the day got to:"
    }

    public var body: String {
        ([lead, ""] + lines.map(\.text)).joined(separator: "\n")
    }

    /// Classify one issued directive against the day's own evidence.
    ///
    /// `completed` wins over everything: a quest the data already closed is met, and a later read of the
    /// evidence does not get to take that back — the XP is paid and the completion card has been shown.
    public static func line(target: String, goal: QuestGoal?, completed: Bool,
                            evidence: QuestEvidence) -> QuestPlanLine {
        if completed {
            let reading = goal.flatMap { $0.isMeasured(by: evidence) ? $0.summary(evidence) : nil }
            return QuestPlanLine(target: target, outcome: .met, reading: reading ?? "")
        }
        // NO GOAL, OR NOTHING READ: not measured. Never a miss.
        guard let goal, goal.isMeasured(by: evidence) else {
            return QuestPlanLine(target: target, outcome: .notMeasured)
        }
        return QuestPlanLine(target: target,
                             outcome: goal.isMet(by: evidence) ? .met : .short,
                             reading: goal.summary(evidence))
    }
}
