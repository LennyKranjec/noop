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
        case .push: return "A real step up on your own numbers. Three directives."
        case .relentless: return "The top of what today's data says is sensible. Four directives."
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
    ///   - `bedtimeEarlierMin` is SUBTRACTED from their own median sleep onset
    ///   - `bandPosition` picks a point in the day's recommended effort band (0 = its floor, 1 = its top)
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
        public let bedtimeEarlierMin: Int
        public let bandPosition: Double
    }

    public var scale: Scale {
        switch self {
        case .steady:
            return Scale(steps: 1.00, water: 0.85, training: 0.75, meditation: 1.00,
                         sleep: 0.95, bedtimeEarlierMin: 0, bandPosition: 0.0)
        case .push:
            return Scale(steps: 1.15, water: 1.00, training: 1.00, meditation: 1.50,
                         sleep: 1.00, bedtimeEarlierMin: 20, bandPosition: 0.5)
        case .relentless:
            return Scale(steps: 1.35, water: 1.10, training: 1.30, meditation: 2.00,
                         sleep: 1.05, bedtimeEarlierMin: 40, bandPosition: 1.0)
        }
    }
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
    /// Median sleep onset, in minutes past midnight on the evening clock.
    public var medianSleepOnsetMinute: Int?
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
                effortBand21: ClosedRange<Int>? = nil) {
        self.medianSteps = medianSteps
        self.hydrationGoalMl = hydrationGoalMl
        self.medianTrainingMinutes = medianTrainingMinutes
        self.medianMeditationMinutes = medianMeditationMinutes
        self.sleepNeedHours = sleepNeedHours
        self.medianSleepOnsetMinute = medianSleepOnsetMinute
        self.effortBand21 = effortBand21
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
        case .bedtimeBy: return "Lights Out"
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
        case .bedtimeBy: return "A deadline you set yourself. Those are the ones people miss."
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
    /// produce the same day). Take `difficulty.questCount` of these to get the day's quests.
    public static func targets(baseline: QuestBaseline, difficulty: QuestDifficulty,
                               focus: LevelPart? = nil, day: String) -> [QuestPlanTarget] {
        let s = difficulty.scale
        let xp = difficulty.xp
        var out: [QuestPlanTarget] = []

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

        // BEDTIME — measured off their own median onset, so "earlier" means earlier than THEY are.
        if let onset = baseline.medianSleepOnsetMinute {
            // ONE EXPRESSION FOR THE NUMBER, read by both the goal and the sentence — a card that said
            // 22:40 while the goal checked 22:37 would be two answers to one question.
            let deadline = round(wrapMinute(onset - s.bedtimeEarlierMin), to: 5)
            add(.bedtimeBy, threshold: Double(deadline),
                observation: "They usually fall asleep around \(clock(onset)), and they picked "
                    + "\(difficulty.title) for today.",
                target: "Asleep by \(clock(deadline))",
                rewards: [.sleep], parts: [.sleep])
        }

        // TRAINING — off the length of the days they actually train on.
        if let usual = baseline.medianTrainingMinutes, usual > 0 {
            let minutes = Double(round(Int((usual * s.training).rounded()), to: 5))
            if minutes > 0 {
                add(.workoutMinutes, threshold: minutes,
                    observation: "Their training days run about \(whole(usual)) minutes, and they "
                        + "picked \(difficulty.title) for today.",
                    target: "\(whole(minutes)) minutes of training logged today",
                    rewards: [.muscle, .heart], parts: [.muscle, .lungs])
            }
        }

        // EFFORT — a point in the day's OWN recommended band. Never past its top; see `Scale`.
        if let band = baseline.effortBand21 {
            let span = Double(band.upperBound - band.lowerBound)
            let strain = (Double(band.lowerBound) + span * Swift.min(Swift.max(s.bandPosition, 0), 1))
            let rounded = (strain * 2).rounded() / 2
            add(.strain, threshold: rounded,
                observation: "Today's charge puts their recommended day strain at "
                    + "\(band.lowerBound)–\(band.upperBound) of 21, and they picked "
                    + "\(difficulty.title) for today.",
                target: "A day strain of \(oneDp(rounded)) on WHOOP's scale",
                rewards: [.muscle, .heart], parts: [.muscle, .lungs])
        }

        // MEDITATION — off the length of their own sessions, floored at what counts as one at all.
        if let usual = baseline.medianMeditationMinutes, usual > 0 {
            let scaled = Swift.max(LevelEngine.meditationMinMinutes, usual * s.meditation)
            // Rounded to five, then floored again: rounding DOWN to zero or to under what counts as a
            // session at all would be a target met by not sitting down.
            let minutes = Swift.max(LevelEngine.meditationMinMinutes,
                                    Double(round(Int(scaled.rounded()), to: 5)))
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

        guard let focus else { return out }
        // Stable partition: the focus part's directives first, everything else in its base order.
        let leading = out.filter { $0.parts.contains(focus) }
        return leading + out.filter { !$0.parts.contains(focus) }
    }

    /// The day's quests: `targets(...)` cut to the chosen mode's count.
    public static func plan(baseline: QuestBaseline, difficulty: QuestDifficulty,
                            focus: LevelPart? = nil, day: String) -> [QuestPlanTarget] {
        Array(targets(baseline: baseline, difficulty: difficulty, focus: focus, day: day)
            .prefix(difficulty.questCount))
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
