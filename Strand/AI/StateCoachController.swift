import Foundation
import StrandAnalytics
import WhoopStore
#if os(iOS)
import UIKit
#endif

// StateCoachController.swift — the STATE tile's generation: the "WORKOUTS TODAY" suggestions and the
// manual refresh that regenerates them together with today's mission.
//
// CADENCE. Automatic: once per day per set of today's workouts (a finished session gets fresh suggestions
// once), and only when the coach is configured with data consent — otherwise the deterministic fallback
// renders, which costs nothing and is recomputed on every read. Manual: the refresh button bypasses the
// cache for BOTH the suggestions and the mission, throttled by `RefreshThrottle`.
//
// A FAILED REFRESH KEEPS WHAT WAS THERE. The old mission and the old suggestions stay on screen and a
// one-line note says the refresh did not land; nothing is cleared before a replacement exists.

@MainActor
final class StateCoachController: ObservableObject {

    static let shared = StateCoachController()

    /// Minimum seconds between two manual refreshes.
    static let minRefreshInterval: TimeInterval = 20

    enum Source: Equatable { case none, coach, fallback }

    /// A sheet the tile raises. Presented by `StateTilePresentationHost`.
    enum Presentation: Identifiable, Equatable {
        case detail(StateRecommendation)
        case workoutDetail(WorkoutSuggestion)
        case breathe
        /// The "which workouts may be suggested" checklist.
        case workoutChoices

        var id: String {
            switch self {
            case .detail(let r): return "detail-" + r.id
            case .workoutDetail(let w): return "workout-" + w.id
            case .breathe: return "breathe"
            case .workoutChoices: return "workout-choices"
            }
        }
    }

    /// The list as the tile shows it: `generated` with the wearer's own edits applied.
    @Published private(set) var suggestions: [WorkoutSuggestion] = []
    @Published private(set) var source: Source = .none
    /// A manual refresh is running (the button spins and is disabled).
    @Published private(set) var isRefreshing = false
    /// An automatic coach generation is running.
    @Published private(set) var isGenerating = false
    /// The coach is writing a workout the wearer asked for through the "+".
    @Published private(set) var isAddingWorkout = false
    /// Today's pins and removals. Read back per day, so both reset by themselves at midnight.
    @Published private(set) var edits = StateWorkoutEditsStore.read(dayKey: DailyMissionStore.dayKey())

    /// What the coach (or the fallback) produced, BEFORE the wearer's edits. Kept apart from
    /// `suggestions` so removing a row does not have to be re-derived out of the list it left behind:
    /// every regeneration replaces this, and the edits are re-applied on top.
    private var generated: [WorkoutSuggestion] = []
    /// One line under the section when a refresh did not land (or was throttled). nil when all is well.
    @Published private(set) var notice: String?
    /// Whether `notice` describes something worth simply trying again (a rate limit, a timeout, a network
    /// blip) as opposed to something the wearer has to go and change (no key, a rejected key, a key stored
    /// for another provider). Drives the retry affordance so the note is not a dead end.
    @Published private(set) var noticeRetryable = false
    /// The coach's own answer to "what is still due today" — or the deterministic one. Shown above the rows,
    /// because "nothing, you are done" is an answer no list of rows can give.
    @Published private(set) var leftToday: String?
    /// When today's mission was last rewritten. The tile watches it, so an automatically regenerated mission
    /// appears without the wearer tapping anything — previously only the refresh button's return value told
    /// the screen to re-read, which is why an automatic rewrite could not exist.
    @Published private(set) var missionRewrittenAt: Date?
    @Published var presented: Presentation?
    /// The start-workout picker (a separate cover, it is its own full-screen browser on iPhone).
    @Published var pickingWorkout = false
    /// Which workouts may be suggested (persisted; default everything).
    @Published private(set) var choices: StateWorkoutChoices = StateWorkoutChoicesStore.read()

    private var throttle = RefreshThrottle(minInterval: StateCoachController.minRefreshInterval)
    /// The automatic generation, held here rather than in the view's task so a re-render that restarts
    /// the task does not cancel a request half-way and throw its answer away.
    private var generation: Task<Void, Never>?
    /// Bumped whenever an in-flight generation is superseded (the selection changed, a manual refresh
    /// started), so its late answer is dropped instead of overwriting the newer list.
    private var generationToken = 0
    /// When the last AUTOMATIC generation was started. Separate from `throttle`, which guards the button:
    /// a tap must never be refused because a sync fired a moment ago, and a sync must never be allowed to
    /// spend a request every time a published tick lands.
    private var lastAutoAttempt: Date?
    /// The one scheduled re-evaluation that coalesces a burst of signals into a single regeneration.
    private var coalesceTask: Task<Void, Never>?

    private init() {}

    /// Whether a request may be spent right now. `!= .background`, not `== .active`: a pulled-down Control
    /// Centre is `.inactive` and the wearer is still looking at the tile.
    private var isForeground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState != .background
        #else
        return true
        #endif
    }

    // MARK: The wearer's edits

    /// A fresh generated list, with today's pins and removals applied over it.
    private func setGenerated(_ items: [WorkoutSuggestion]) {
        generated = items
        suggestions = edits.applied(to: items)
    }

    /// Record which of the list's rows today's sessions have already closed, and re-apply so they show as
    /// done rather than vanishing. Called after every snapshot, so a session finished twenty minutes ago
    /// ticks its row off on the very next read — no regeneration needed.
    private func markCompleted(from today: [StateWorkoutFact]) {
        let keys = StateSuggestionCompletion.completedKeys(in: generated + edits.pinned, today: today)
        guard keys != edits.completed else {
            suggestions = edits.applied(to: generated)
            return
        }
        var e = edits
        e.completed = keys
        commit(e)
    }

    /// The sentence above the rows: the coach's own when it wrote one, else the deterministic answer.
    private func setLeftToday(_ coachLine: String?, figures: StateTrainingFigures, now: Date = Date()) {
        let trimmed = coachLine?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            leftToday = trimmed
            return
        }
        leftToday = StateDueToday.sentence(figures: figures, stillDue: suggestions,
                                           hour: Calendar.current.component(.hour, from: now))
    }

    /// Re-read the edits when the day has rolled over under a long-running app: the singleton outlives
    /// midnight, and yesterday's removals must not silently keep filtering this morning's list.
    private func syncEditsDay(_ day: String = DailyMissionStore.dayKey()) {
        guard edits.dayKey != day else { return }
        edits = StateWorkoutEditsStore.read(dayKey: day)
        suggestions = edits.applied(to: generated)
    }

    private func commit(_ new: StateWorkoutEdits) {
        edits = new
        StateWorkoutEditsStore.write(new)
        suggestions = new.applied(to: generated)
    }

    /// Remove a suggestion for the rest of today: the wearer's own workout is deleted, a generated one is
    /// suppressed by key so the next regeneration does not hand it back.
    func remove(_ s: WorkoutSuggestion) {
        syncEditsDay()
        var e = edits
        e.dismiss(s)
        commit(e)
    }

    /// Pin a workout the wearer asked for. It rides every regeneration for the rest of the day.
    func pin(_ s: WorkoutSuggestion) {
        syncEditsDay()
        var e = edits
        e.pin(s)
        commit(e)
    }

    /// The "+" sheet: the coach writes `request` up as a suggestion at the time the wearer picked, and it
    /// is pinned. Never fails to add — an unreachable coach falls back to the wearer's own words
    /// (`CustomWorkoutWriter.fallback`), which is also why the allowed-workouts selection is not consulted:
    /// they named this session themselves.
    @discardableResult
    func addCustomWorkout(request: String, at time: CustomWorkoutTime, figures: StateTrainingFigures,
                          repo: Repository, profile: ProfileStore, coach: AICoachEngine,
                          now: Date = Date()) async -> WorkoutSuggestion? {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAddingWorkout else { return nil }
        let startMinute = time.startMinute(now: now)
        isAddingWorkout = true
        // Cleared on EVERY path out — the give-up branch and a cancellation included.
        defer { isAddingWorkout = false }

        var answer: String?
        var failure: AICoachError?
        if coach.isConfigured, coach.dataConsent {
            let snap = await snapshot(repo: repo, profile: profile, now: now)
            let f = completed(figures, snap)
            let framing = CustomWorkoutWriter.systemPrompt(grounding: "", request: text,
                                                          startMinute: startMinute)
            switch await coach.generateOneShotResult(budget: .customWorkout, build: { budget in
                (systemPrompt: CustomWorkoutWriter.systemPrompt(
                    grounding: await self.stateGrounding(coach: coach, repo: repo, figures: f,
                                                         snap: snap, budget: budget,
                                                         framing: framing,
                                                         question: CustomWorkoutWriter.question,
                                                         now: now),
                    request: text, startMinute: startMinute),
                 question: CustomWorkoutWriter.question)
            }) {
            case .success(let text): answer = text
            case .failure(let e): failure = e
            }
        }
        let made = CustomWorkoutWriter.resolve(answer: answer, request: text, startMinute: startMinute)
        pin(made)
        // The workout was added either way — what the note says is WHY the coach did not write it up, which
        // used to be "couldn't reach the coach" for a rejected key and a rate limit alike.
        if let failure {
            report(failure)
            if !(notice ?? "").isEmpty {
                notice = (notice ?? "") + " "
                    + String(localized: "Added your workout from your own words.")
            }
        } else {
            notice = nil
            noticeRetryable = false
        }
        return made
    }

    // MARK: Snapshot

    struct TrainingSnapshot {
        let today: [StateWorkoutFact]
        let recent: [StateWorkoutFact]
        let zones: [HRZoneBPMRange]
        let hrvDeltaPct: Double?
        let rhrDeltaBpm: Double?
        /// Minutes of meditation / breathwork / NSDR logged today. Read from the meditation series rather
        /// than counted out of the workout list: a session started from the meditation card is not
        /// necessarily a workout row, and the level counts the series.
        var mindfulMinutesToday: Double?
        /// The level's own gaps, worst first, and the parts it had no data for.
        var levelGaps: [StateLevelGap] = []
        var levelPartsWithoutData: [String] = []
        var levelDayKey: String?
        var levelStepPenalty: Double?
    }

    /// The level's parts as the tile's grounding needs them: the measured gaps worst-first, and the
    /// abstentions named separately so nothing can call an unmeasured part weak.
    ///
    /// READ FROM THE SAME LEDGER THE STRIP AND THE COACH'S FULL CONTEXT READ (`LevelDayFreeze.standIn`),
    /// never recomputed: a tile quoting a different level from the bar above it is two answers to one
    /// question, which is the duplicated-value bug this repo keeps shipping.
    private func levelState() -> (gaps: [StateLevelGap], missing: [String], day: String?, stepPenalty: Double?) {
        let calendar = Calendar.current
        let now = Date()
        let dayKey = LevelWiring.key(from: LevelDayFreeze.levelDay(now: now, calendar: calendar),
                                     calendar: calendar)
        let ledger = LevelLedger.shared
        guard let frozen = ledger.entry(dayKey) ?? LevelDayFreeze.standIn(levelDay: dayKey, ledger: ledger) else {
            return ([], LevelBarModel.lastMissing.map(\.label), nil, nil)
        }
        let b = frozen.breakdown
        // `levers()` already drops every part with no score, so an abstention can never arrive as a gap.
        let gaps = b.levers().map {
            StateLevelGap(part: $0.part.rawValue, headroom: $0.headroom * b.stepPenalty, score: $0.score ?? 0)
        }
        let missing = b.components.filter { $0.score == nil }.map { $0.part.rawValue }
        return (gaps, missing, frozen.day, b.stepPenalty)
    }

    private func fact(_ w: WorkoutRow, zoneMinutes: [Double]?) -> StateWorkoutFact {
        StateWorkoutFact(sport: w.sport,
                         start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                         end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                         durationMin: w.durationS.map { $0 / 60 } ?? Double(max(0, w.endTs - w.startTs)) / 60,
                         avgHr: w.avgHr, maxHr: w.maxHr, effort: w.strain, zoneMinutes: zoneMinutes)
    }

    func snapshot(repo: Repository, profile: ProfileStore, now: Date = Date()) async -> TrainingSnapshot {
        let rows = await repo.workoutRows(days: 15)   // newest first
        let dayStart = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let zoneSet = profile.hrZoneSet
        var today: [StateWorkoutFact] = []
        // Time in zones for today's sessions only (a narrow HR read each); capped so a day of many
        // short detected bouts does not turn one refresh into a dozen reads.
        for w in rows.filter({ $0.startTs >= dayStart }).prefix(6) {
            let z = await repo.workoutZoneMinutes(from: w.startTs, to: w.endTs, zoneSet: zoneSet, source: w.source)
            today.append(fact(w, zoneMinutes: z))
        }
        let cutoff = dayStart - 14 * 86_400
        let recent = rows.filter { $0.startTs < dayStart && $0.startTs >= cutoff }.prefix(20)
            .map { fact($0, zoneMinutes: nil) }

        let days = repo.days
        let hrv = StateTrainingContext.latestVsBaseline(days.compactMap { $0.avgHrv })
        let rhr = StateTrainingContext.latestVsBaseline(days.compactMap { $0.restingHr.map(Double.init) })
        let mindful = await repo.meditationMinutesByDay(days: 2)[Repository.localDayKey(now)]
        let level = levelState()
        return TrainingSnapshot(
            today: today, recent: Array(recent), zones: zoneSet.bpmRanges,
            hrvDeltaPct: hrv.flatMap { $0.baseline > 0 ? ($0.latest / $0.baseline - 1) * 100 : nil },
            rhrDeltaBpm: rhr.map { $0.latest - $0.baseline },
            mindfulMinutesToday: mindful,
            levelGaps: level.gaps, levelPartsWithoutData: level.missing,
            levelDayKey: level.day, levelStepPenalty: level.stepPenalty)
    }

    private func completed(_ f: StateTrainingFigures, _ snap: TrainingSnapshot) -> StateTrainingFigures {
        var out = f
        if out.hrvDeltaPct == nil { out.hrvDeltaPct = snap.hrvDeltaPct }
        if out.rhrDeltaBpm == nil { out.rhrDeltaBpm = snap.rhrDeltaBpm }
        if out.mindfulMinutesToday == nil { out.mindfulMinutesToday = snap.mindfulMinutesToday }
        out.levelGaps = snap.levelGaps
        out.levelPartsWithoutData = snap.levelPartsWithoutData
        out.levelDayKey = snap.levelDayKey
        out.levelStepPenalty = snap.levelStepPenalty
        return out
    }

    private func fallback(_ f: StateTrainingFigures, _ snap: TrainingSnapshot, now: Date = Date()) -> [WorkoutSuggestion] {
        WorkoutSuggestionFallback.suggest(figures: f, hour: Calendar.current.component(.hour, from: now),
                                          today: snap.today, recent: snap.recent, now: now, choices: choices)
    }

    /// How many of the previous fortnight's sessions the tile lists. SIX, not twenty: the tile's prompt asks
    /// whether a hard session is recent and what the last two weeks looked like in outline, and the block
    /// states the most recent hard session separately whatever it lists.
    private static let recentWorkoutsListed = 6

    /// The State tile's OWN grounding, assembled to a token budget.
    ///
    /// IT NO LONGER REUSES THE CHAT'S. `buildFullContext()` measured about 5,200 estimated tokens — the
    /// level formula, fourteen days of every metric, the dream journal, the quest history, the strength
    /// progression, the bedroom — and the tile then sent it TWICE in parallel against an 8,000-tokens-per-
    /// MINUTE allowance. One of the two was refused with a 413 stating "Limit 8000, Requested 8646".
    ///
    /// WHAT THE TILE ACTUALLY NEEDS is what its prompt names: today's training state, the day's schedule,
    /// which day each figure belongs to, a short history, stress today, and the routines the times have to
    /// fit inside. That is what this builds — about 1,600 estimated tokens — and the budget then decides
    /// whether even that fits, shortening or dropping cheapest-value-first and saying so.
    ///
    /// `framing` and `question` are the request's own ASKING — its system prompt with no grounding in it, and
    /// the question. They are reserved out of the budget before the grounding is assembled, because none of
    /// that can be trimmed and the provider meters the whole request. Each caller passes ITS OWN: the merged
    /// plan writer's instruction is a different size from the custom-workout writer's, and reserving one for
    /// the other is the same class of mistake as budgeting the grounding alone.
    private func stateGrounding(coach: AICoachEngine, repo: Repository,
                                figures f: StateTrainingFigures,
                                snap: TrainingSnapshot, budget: Int,
                                framing: String, question: String,
                                now: Date = Date()) async -> String {
        let schedule = RoomClimatePlan.schedule(now: now)
        let day = DailyMissionStore.dayKey(now)
        func training(_ limit: Int) -> String {
            StateTrainingContext.block(figures: f, zones: snap.zones, today: snap.today,
                                       recent: snap.recent, now: now,
                                       bedtimeMinute: schedule.bedtimeMinute, recentLimit: limit)
        }
        let curve = await StressDayCurve.today(repo: repo, now: now)
        let hourly = (curve?.result.hours ?? []).compactMap { h -> (hour: Int, level: Double)? in
            h.level.map { (hour: h.hour, level: $0) }
        }
        let blocks = StateGrounding.blocks(
            dayFrame: CoachDayFrame.compactBlock(now: now),
            training: training(Self.recentWorkoutsListed),
            trainingShort: training(0),
            schedule: StateDayPlanContext.block(now: now, schedule: schedule),
            history: coach.shortHistoryBlock(),
            stress: StateGrounding.stressBlock(day: day,
                                               now: LiveStressMonitor.shared.current,
                                               hourly: hourly,
                                               stressIndex: await coach.stressIndexToday(now: now)),
            routines: CoachRoutines.promptSection(),
            memory: CoachMemory.shared.promptSection(),
            closing: CoachDayFrame.closingRule)
        // Measured rather than guessed: a budget that under-reserves the asking overruns by exactly its own
        // error, which is how a request sized for 8,000 came to ask for 8,646.
        let reserved = coach.reservedTokens(framing: framing, question: question, now: now)
        let fit = CoachContextBudget.fit(blocks, budget: budget, reserved: reserved)
        if !fit.isComplete {
            CoachLog.ai("state grounding trimmed to \(budget): shortened \(fit.shortened.count), "
                        + "dropped \(fit.dropped.count)")
        }
        return fit.text
    }

    /// The coach's list held to the selection: disallowed sessions dropped, nil when nothing is left.
    private func allowed(_ items: [WorkoutSuggestion]?) -> [WorkoutSuggestion]? {
        guard let items else { return nil }
        let kept = choices.filter(items)
        return kept.isEmpty ? nil : kept
    }

    // MARK: Selection

    /// Save a new selection. What is on screen is held to it at once (disallowed rows vanish) and a coach
    /// generation still out for the OLD selection is superseded. The fresh list comes from the next
    /// `load`: the selection is part of the cache fingerprint and of the section's load key, so a change
    /// misses the cache and generates once — outside the manual refresh's 20 s throttle, which guards the
    /// refresh button, not this. The sheet commits once, on close, so ticking boxes costs nothing.
    func updateChoices(_ new: StateWorkoutChoices) {
        guard new != choices else { return }
        StateWorkoutChoicesStore.write(new)
        choices = new
        generationToken += 1
        generation?.cancel()
        generation = nil
        isGenerating = false
        notice = nil
        noticeRetryable = false
        // Only the GENERATED half is held to the selection: a workout the wearer asked for themselves is
        // always allowed, whatever is ticked.
        setGenerated(new.filter(generated))
    }


    // MARK: Automatic

    /// The screen's read, and the tile's own decision about whether the text on it is still true.
    ///
    /// THREE THINGS HAPPEN HERE, in this order, and the order is the point:
    /// 1. Whatever is current is put on screen — the cached coach answer if its fingerprint still matches,
    ///    else the deterministic rules — so the tile is never blank and never waits on a network.
    /// 2. Today's finished sessions tick off the rows they closed, so a workout logged twenty minutes ago is
    ///    acknowledged on the very next read whether or not anything is regenerated.
    /// 3. `StateRegenerationPolicy` decides whether the day has moved on enough to be worth asking again,
    ///    and BOTH the mission and the suggestions are rewritten when it has. Before this the mission was
    ///    written once per day and the suggestions once per set of workouts, so an instruction written at
    ///    07:00 was still standing at 19:00 after a hard session had made it wrong — and the refresh button
    ///    was the only way out, which is the wearer doing the app's job.
    func load(figures: StateTrainingFigures, repo: Repository, profile: ProfileStore, coach: AICoachEngine) async {
        let day = DailyMissionStore.dayKey()
        syncEditsDay(day)
        // The cache check first, from the (memoised) workout list alone: a current coach answer needs none
        // of the per-workout heart-rate reads the snapshot makes.
        let dayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let todayRows = await repo.workoutRows(days: 15).filter { $0.startTs >= dayStart }.prefix(6)
        let todayFacts = todayRows.map { fact($0, zoneMinutes: nil) }
        let fp = WorkoutSuggestionStore.fingerprint(today: todayFacts, choices: choices)
        let cached = WorkoutSuggestionStore.current(dayKey: day, fingerprint: fp)

        var shown = figures
        shown.mindfulMinutesToday = figures.mindfulMinutesToday ?? lastMindfulMinutes(day: day)
        let current = StateRegenerationInputs(dayKey: day, workoutsSeq: repo.workoutsSeq,
                                              refreshSeq: repo.refreshSeq, choices: choices,
                                              figures: shown)

        var snap: TrainingSnapshot?
        if let cached, let items = allowed(cached.items) {
            setGenerated(items)
            source = .coach
            markCompleted(from: todayFacts)
            setLeftToday(cached.leftToday, figures: withLevel(shown))
        } else {
            let s = await snapshot(repo: repo, profile: profile)
            // While a generation is out, keep whatever is on screen; its answer lands shortly.
            guard generation == nil, !isRefreshing else { return }
            snap = s
            let f = completed(shown, s)
            setGenerated(fallback(f, s))
            source = .fallback
            markCompleted(from: s.today)
            setLeftToday(nil, figures: f)
        }

        // Only ask the coach once the day's figures are in: a generation from a half-loaded screen would
        // be cached for the whole day.
        guard coach.isConfigured, coach.dataConsent,
              shown.charge != nil || shown.effortNow != nil,
              !choices.allowedKeys.isEmpty else { return }
        guard generation == nil, !isRefreshing else { return }

        let forced = forceRegenerate
        forceRegenerate = false
        // Paused by a failure a retry cannot fix, and still the same day: ask nothing. The wearer clears it
        // by tapping refresh or "Try again", both of which force a generation.
        guard forced || autoPausedOn != day else { return }
        let decision = StateRegenerationPolicy.decide(
            previous: forced ? nil : cached?.inputs,
            generatedAt: forced ? nil : cached?.createdAt, current: current,
            lastAutoAttempt: forced ? nil : lastAutoAttempt, foreground: isForeground)
        switch decision {
        case .skip:
            coalesceTask?.cancel()
            coalesceTask = nil
        case .wait(let seconds):
            // ONE scheduled re-evaluation, replacing any earlier one: that is what turns a burst of signals
            // (a sync bumps refreshSeq, workoutsSeq and the day's figures inside the same second) into a
            // single request instead of three.
            scheduleReevaluation(after: seconds, figures: figures, repo: repo, profile: profile, coach: coach)
        case .regenerate(let cause):
            coalesceTask?.cancel()
            coalesceTask = nil
            let s: TrainingSnapshot
            if let snap {
                s = snap
            } else {
                s = await snapshot(repo: repo, profile: profile)
            }
            let f = completed(shown, s)
            lastAutoAttempt = Date()
            CoachLog.ai("state tile regenerating: \(cause.rawValue)")
            // The MISSION is rewritten together with the suggestions: it is the same day and the same
            // grounding, and a mission from this morning standing over freshly-regenerated suggestions is
            // the stale text the wearer complained about. ONE request now carries both.
            await generate(day: day, fingerprint: fp, figures: f, snap: s, inputs: current,
                           repo: repo, coach: coach)
        }
    }

    /// The mindful minutes the last snapshot read, when it was for the same day. Lets the cheap path — the
    /// one that hits the suggestion cache and makes no store read — still notice a meditation logged since,
    /// instead of comparing nil against nil forever.
    private var lastMindful: (day: String, minutes: Double)?

    private func lastMindfulMinutes(day: String) -> Double? {
        guard let lastMindful, lastMindful.day == day else { return nil }
        return lastMindful.minutes
    }

    /// `figures` with the level state filled in, for the deterministic sentence on the cached path (which
    /// takes no snapshot). The level comes from the ledger, not from a store read, so this is cheap.
    private func withLevel(_ f: StateTrainingFigures) -> StateTrainingFigures {
        var out = f
        let level = levelState()
        out.levelGaps = level.gaps
        out.levelPartsWithoutData = level.missing
        out.levelDayKey = level.day
        out.levelStepPenalty = level.stepPenalty
        return out
    }

    /// Re-run `load` once, after `seconds`. Replaces any earlier scheduled run, so several signals landing
    /// together end in ONE re-evaluation.
    private func scheduleReevaluation(after seconds: TimeInterval, figures: StateTrainingFigures,
                                      repo: Repository, profile: ProfileStore, coach: AICoachEngine) {
        coalesceTask?.cancel()
        coalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Swift.max(0.5, seconds) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.coalesceTask = nil
            await self.load(figures: figures, repo: repo, profile: profile, coach: coach)
        }
    }

    /// Ask the coach for the plan AND for today's mission, and apply whatever comes back. A superseded
    /// generation drops its answer instead of overwriting a newer list.
    ///
    /// ONE REQUEST, NOT TWO. This used to fire the workout suggestions and the mission in parallel over the
    /// same grounding word for word — paying for it twice, and colliding with itself against a per-MINUTE
    /// token limit even when each half fitted. `StatePlanWriter` asks for both in one JSON object; the two
    /// halves are still parsed and still fail independently, so a reply that gets the list right and forgets
    /// the mission is used for the list exactly as before.
    private func generate(day: String, fingerprint fp: String, figures f: StateTrainingFigures,
                          snap: TrainingSnapshot, inputs: StateRegenerationInputs,
                          repo: Repository, coach: AICoachEngine) async {
        isGenerating = true
        generationToken += 1
        let token = generationToken
        let choicesNow = choices
        if let m = snap.mindfulMinutesToday { lastMindful = (day, m) }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // Only the generation still current clears the flags; a superseded one leaves them to
                // whatever replaced it.
                if self.generationToken == token {
                    self.isGenerating = false
                    self.generation = nil
                }
            }
            let result = await coach.generateOneShotResult(budget: .stateTile) { budget in
                (systemPrompt: StatePlanWriter.systemPrompt(
                    grounding: await self.stateGrounding(
                        coach: coach, repo: repo, figures: f, snap: snap, budget: budget,
                        framing: StatePlanWriter.systemPrompt(grounding: "", choices: choicesNow),
                        question: StatePlanWriter.question),
                    choices: choicesNow),
                 question: StatePlanWriter.question)
            }
            guard self.generationToken == token, !self.isRefreshing else { return }

            let merged = result.map(StatePlanWriter.parse)
            if case .success(let answer) = merged, let text = answer.missionText,
               let written = DailyMissionWriter.parse(text, dayKey: day) {
                DailyMissionStore.write(written)
                self.missionRewrittenAt = Date()
            }
            switch merged {
            case .success(let answer):
                guard let parsed = answer.plan else {
                    self.report(.decode)
                    return
                }
                // An EMPTY list is a legitimate answer ("you are done"); a list whose every row the wearer
                // has unticked is not, and must not wipe the good one on screen.
                let items = self.choices.filter(parsed.workouts)
                guard parsed.workouts.isEmpty || !items.isEmpty else {
                    self.notice = String(localized: "The coach only suggested workouts you have unticked. Kept the previous ones.")
                    self.noticeRetryable = true
                    return
                }
                WorkoutSuggestionStore.write(StoredWorkoutSuggestions(
                    dayKey: day, fingerprint: fp, createdAt: Date(), items: items,
                    leftToday: parsed.leftToday, inputs: inputs))
                self.setGenerated(items)
                // An empty list WITH the coach's sentence is the coach answering "you are done", not the
                // built-in rules standing in — the header must not say "Built-in" for it.
                self.source = (items.isEmpty && parsed.leftToday == nil) ? .fallback : .coach
                self.markCompleted(from: snap.today)
                self.setLeftToday(parsed.leftToday, figures: f)
                self.notice = nil
                self.noticeRetryable = false
            case .failure(let error):
                self.report(error)
            }
        }
        generation = task
        await task.value
    }

    /// The "Try again" the failure note offers.
    ///
    /// NOT the refresh button: this exists so a transient failure does not LATCH. It clears the note, drops
    /// the automatic-run spacing (the failed attempt bought nothing, so it must not hold the next one off)
    /// and re-evaluates. The manual button's 20 s throttle is untouched — a tap and a retry are different
    /// affordances and neither may block the other.
    func retry(figures: StateTrainingFigures, repo: Repository, profile: ProfileStore,
               coach: AICoachEngine) async {
        guard !isRefreshing, !isGenerating else { return }
        notice = nil
        noticeRetryable = false
        lastAutoAttempt = nil
        forceRegenerate = true
        autoPausedOn = nil
        coalesceTask?.cancel()
        coalesceTask = nil
        await load(figures: figures, repo: repo, profile: profile, coach: coach)
    }

    /// Set by `retry`: the next `load` asks again even though nothing in the day has moved. Cleared as soon
    /// as it is read, so a retry is one attempt, not a mode.
    private var forceRegenerate = false

    /// Put a failure on screen as the reason it actually was.
    ///
    /// A cancellation is NOT reported: it means something newer replaced this request, which is not a
    /// failure and never was — reporting it is how "the coach is not reachable" appeared after a perfectly
    /// healthy refresh.
    private func report(_ error: AICoachError) {
        CoachLog.ai("state tile: \(error.logReason)")
        if case .cancelled = error { return }
        notice = StateCoachFailure.notice(error)
        noticeRetryable = StateCoachFailure.canRetry(error)
        // AND IT MUST NOT HAMMER. A failed generation wrote no cache record, so the day still looks changed
        // and the policy would say "regenerate" again on the very next signal.
        if error.isTransient {
            // Push the automatic clock forward, so the retry is minutes away rather than ninety seconds.
            lastAutoAttempt = Date().addingTimeInterval(
                StateRegenerationPolicy.failureBackoff - StateRegenerationPolicy.minAutoInterval)
        } else {
            // Nothing a retry can fix (no key, a rejected key, a key saved for another provider, a bad
            // server URL). Stop asking until the wearer changes something: the refresh button and the note's
            // "Try again" both clear this, and so does the day rolling over.
            autoPausedOn = DailyMissionStore.dayKey()
        }
    }

    /// The day on which automatic regeneration was paused by a failure a retry cannot fix. See `report`.
    private var autoPausedOn: String?

    // MARK: Manual refresh

    /// Seconds until the refresh button may run again.
    var refreshCooldown: TimeInterval { throttle.remaining(at: Date()) }

    /// Regenerate the mission and the suggestions, bypassing both caches.
    ///
    /// `prepare` runs first, inside the spinner: the tile's own recomputation (deficits, energy) that
    /// returns the figures as they are NOW, so the coach is not grounded on the numbers from before the
    /// tap. Returns true when the mission was rewritten (the caller re-reads it).
    @discardableResult
    func refresh(repo: Repository, profile: ProfileStore, coach: AICoachEngine,
                 prepare: () async -> StateTrainingFigures) async -> Bool {
        guard !isRefreshing else { return false }
        let now = Date()
        guard throttle.tryStart(at: now) else {
            let secs = Int(throttle.remaining(at: now).rounded(.up))
            notice = String(localized: "Updated moments ago. Try again in \(secs) s.")
            noticeRetryable = true
            return false
        }
        isRefreshing = true
        notice = nil
        noticeRetryable = false
        // A tap is the wearer saying "try it now": whatever paused the automatic side is cleared, so a fixed
        // key or a corrected server URL takes effect at once rather than at midnight.
        autoPausedOn = nil
        defer { isRefreshing = false }

        let figures = await prepare()
        let snap = await snapshot(repo: repo, profile: profile)
        let f = completed(figures, snap)
        let day = DailyMissionStore.dayKey()
        syncEditsDay(day)
        let fp = WorkoutSuggestionStore.fingerprint(today: snap.today, choices: choices)
        let choicesNow = choices
        let inputs = StateRegenerationInputs(dayKey: day, workoutsSeq: repo.workoutsSeq,
                                             refreshSeq: repo.refreshSeq, choices: choices, figures: f)
        if let m = snap.mindfulMinutesToday { lastMindful = (day, m) }

        // WHY THE TWO PRECONDITIONS ARE CHECKED SEPARATELY. "No provider" and "data access off" are two
        // different things to go and do, and reporting either as "couldn't reach the coach" sent the wearer
        // looking for a network problem they did not have.
        if !coach.isConfigured || !coach.dataConsent {
            setGenerated(fallback(f, snap))
            source = .fallback
            markCompleted(from: snap.today)
            setLeftToday(nil, figures: f)
            notice = coach.isConfigured
                ? String(localized: "Coach data access is off. Showing the built-in suggestions.")
                : String(localized: "Coach is not set up. Showing the built-in suggestions.")
            noticeRetryable = false
            return false
        }

        // A manual refresh supersedes an automatic generation still out.
        generationToken += 1
        generation?.cancel()
        generation = nil
        isGenerating = false
        coalesceTask?.cancel()
        coalesceTask = nil
        lastAutoAttempt = Date()
        // ONE REQUEST for both, budgeted, with one automatic retry at half the budget on a 413 or a 429.
        // This was two requests in parallel over one grounding sent twice — see `generate`.
        let result = await coach.generateOneShotResult(budget: .stateTile) { budget in
            (systemPrompt: StatePlanWriter.systemPrompt(
                grounding: await self.stateGrounding(
                    coach: coach, repo: repo, figures: f, snap: snap, budget: budget,
                    framing: StatePlanWriter.systemPrompt(grounding: "", choices: choicesNow),
                    question: StatePlanWriter.question),
                choices: choicesNow),
             question: StatePlanWriter.question)
        }
        let merged = result.map(StatePlanWriter.parse)

        var missionUpdated = false
        if case .success(let answer) = merged, let text = answer.missionText,
           let mission = DailyMissionWriter.parse(text, dayKey: day) {
            DailyMissionStore.write(mission)
            missionRewrittenAt = Date()
            missionUpdated = true
        }
        var workoutsUpdated = false
        var plan: WorkoutPlan?
        if choicesNow.allowedKeys.isEmpty {
            // Nothing may be suggested: an empty generated list (the wearer's own pins still show).
            setGenerated([])
            source = .fallback
            workoutsUpdated = true
        } else if case .success(let answer) = merged, let parsed = answer.plan,
                  parsed.workouts.isEmpty || !choices.filter(parsed.workouts).isEmpty {
            plan = parsed
            let items = choices.filter(parsed.workouts)
            WorkoutSuggestionStore.write(StoredWorkoutSuggestions(
                dayKey: day, fingerprint: fp, createdAt: Date(), items: items,
                leftToday: parsed.leftToday, inputs: inputs))
            setGenerated(items)
            source = (items.isEmpty && parsed.leftToday == nil) ? .fallback : .coach
            workoutsUpdated = true
        } else if source != .coach || generated.isEmpty {
            // Nothing from the coach to keep: the rules, on the fresh figures.
            setGenerated(fallback(f, snap))
            source = .fallback
        }
        markCompleted(from: snap.today)
        setLeftToday(plan?.leftToday, figures: f)

        // THE REASON, NOT "COULDN'T REACH THE COACH". The wearer is told what actually happened: the key was
        // rejected, the provider rate-limited or refused the request for its size (with the numbers), the
        // reply was unreadable, the local server URL is wrong, the key belongs to another provider. A
        // cancellation says nothing. One request now, so one result to read.
        if let failure = StateCoachFailure.firstReportable([result]) {
            report(failure)
        } else if !workoutsUpdated {
            notice = String(localized: "The coach's workout suggestions didn't come through. Showing the last good ones.")
            noticeRetryable = true
        } else if !missionUpdated {
            notice = String(localized: "The mission couldn't be rewritten. Kept the previous one.")
            noticeRetryable = true
        }
        return missionUpdated
    }
}
