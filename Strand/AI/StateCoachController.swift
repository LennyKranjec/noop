import Foundation
import StrandAnalytics
import WhoopStore

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

        var id: String {
            switch self {
            case .detail(let r): return "detail-" + r.id
            case .workoutDetail(let w): return "workout-" + w.id
            case .breathe: return "breathe"
            }
        }
    }

    @Published private(set) var suggestions: [WorkoutSuggestion] = []
    @Published private(set) var source: Source = .none
    /// A manual refresh is running (the button spins and is disabled).
    @Published private(set) var isRefreshing = false
    /// An automatic coach generation is running.
    @Published private(set) var isGenerating = false
    /// One line under the section when a refresh did not land (or was throttled). nil when all is well.
    @Published private(set) var notice: String?
    @Published var presented: Presentation?
    /// The start-workout picker (a separate cover, it is its own full-screen browser on iPhone).
    @Published var pickingWorkout = false

    private var throttle = RefreshThrottle(minInterval: StateCoachController.minRefreshInterval)
    /// The automatic generation, held here rather than in the view's task so a re-render that restarts
    /// the task does not cancel a request half-way and throw its answer away.
    private var generation: Task<Void, Never>?

    private init() {}

    // MARK: Snapshot

    struct TrainingSnapshot {
        let today: [StateWorkoutFact]
        let recent: [StateWorkoutFact]
        let zones: [HRZoneBPMRange]
        let hrvDeltaPct: Double?
        let rhrDeltaBpm: Double?
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
        return TrainingSnapshot(
            today: today, recent: Array(recent), zones: zoneSet.bpmRanges,
            hrvDeltaPct: hrv.flatMap { $0.baseline > 0 ? ($0.latest / $0.baseline - 1) * 100 : nil },
            rhrDeltaBpm: rhr.map { $0.latest - $0.baseline })
    }

    private func completed(_ f: StateTrainingFigures, _ snap: TrainingSnapshot) -> StateTrainingFigures {
        var out = f
        if out.hrvDeltaPct == nil { out.hrvDeltaPct = snap.hrvDeltaPct }
        if out.rhrDeltaBpm == nil { out.rhrDeltaBpm = snap.rhrDeltaBpm }
        return out
    }

    private func fallback(_ f: StateTrainingFigures, _ snap: TrainingSnapshot, now: Date = Date()) -> [WorkoutSuggestion] {
        WorkoutSuggestionFallback.suggest(figures: f, hour: Calendar.current.component(.hour, from: now),
                                          today: snap.today, recent: snap.recent, now: now)
    }

    // MARK: Automatic

    /// The screen's read: the cached coach suggestions when they are current, else the fallback now and
    /// (coach permitting) a generation in the background.
    func load(figures: StateTrainingFigures, repo: Repository, profile: ProfileStore, coach: AICoachEngine) async {
        let day = DailyMissionStore.dayKey()
        // The cache check first, from the (memoised) workout list alone: a current coach answer needs none
        // of the per-workout heart-rate reads the snapshot makes.
        let dayStart = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let todayRows = await repo.workoutRows(days: 15).filter { $0.startTs >= dayStart }.prefix(6)
        let fp = WorkoutSuggestionStore.fingerprint(today: todayRows.map { fact($0, zoneMinutes: nil) })
        if let cached = WorkoutSuggestionStore.current(dayKey: day, fingerprint: fp) {
            suggestions = cached.items
            source = .coach
            return
        }
        let snap = await snapshot(repo: repo, profile: profile)
        let f = completed(figures, snap)
        // While a generation is out, keep whatever is on screen; its answer lands shortly.
        guard generation == nil, !isRefreshing else { return }
        suggestions = fallback(f, snap)
        source = .fallback
        // Only ask the coach once the day's figures are in: a generation from a half-loaded screen would
        // be cached for the whole day.
        guard coach.isConfigured, coach.dataConsent, f.charge != nil || f.effortNow != nil else { return }
        isGenerating = true
        generation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isGenerating = false; self.generation = nil }
            let grounding = await coach.buildFullContext() + "\n\n"
                + StateTrainingContext.block(figures: f, zones: snap.zones, today: snap.today, recent: snap.recent)
            guard let answer = await coach.generateOneShot(
                    systemPrompt: WorkoutSuggestionWriter.systemPrompt(grounding: grounding),
                    question: WorkoutSuggestionWriter.question),
                  let items = WorkoutSuggestionParser.parse(answer) else { return }
            WorkoutSuggestionStore.write(StoredWorkoutSuggestions(dayKey: day, fingerprint: fp,
                                                                  createdAt: Date(), items: items))
            // Only if nothing newer (a manual refresh) replaced the list meanwhile.
            if !self.isRefreshing {
                self.suggestions = items
                self.source = .coach
            }
        }
    }

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
            return false
        }
        isRefreshing = true
        notice = nil
        defer { isRefreshing = false }

        let figures = await prepare()
        let snap = await snapshot(repo: repo, profile: profile)
        let f = completed(figures, snap)
        let day = DailyMissionStore.dayKey()
        let fp = WorkoutSuggestionStore.fingerprint(today: snap.today)

        guard coach.isConfigured, coach.dataConsent else {
            suggestions = fallback(f, snap)
            source = .fallback
            notice = coach.isConfigured
                ? String(localized: "Coach data access is off. Showing the built-in suggestions.")
                : String(localized: "Coach is not set up. Showing the built-in suggestions.")
            return false
        }

        let grounding = await coach.buildFullContext() + "\n\n"
            + StateTrainingContext.block(figures: f, zones: snap.zones, today: snap.today, recent: snap.recent)
        // Both in parallel: they share the grounding and neither depends on the other.
        async let missionAnswer = coach.generateOneShot(
            systemPrompt: DailyMissionWriter.systemPrompt(grounding: grounding),
            question: DailyMissionWriter.question)
        async let workoutAnswer = coach.generateOneShot(
            systemPrompt: WorkoutSuggestionWriter.systemPrompt(grounding: grounding),
            question: WorkoutSuggestionWriter.question)
        let mAnswer = await missionAnswer
        let wAnswer = await workoutAnswer

        var missionUpdated = false
        if let mAnswer, let mission = DailyMissionWriter.parse(mAnswer, dayKey: day) {
            DailyMissionStore.write(mission)
            missionUpdated = true
        }
        var workoutsUpdated = false
        if let wAnswer, let items = WorkoutSuggestionParser.parse(wAnswer) {
            WorkoutSuggestionStore.write(StoredWorkoutSuggestions(dayKey: day, fingerprint: fp,
                                                                  createdAt: Date(), items: items))
            suggestions = items
            source = .coach
            workoutsUpdated = true
        } else if source != .coach || suggestions.isEmpty {
            // Nothing from the coach to keep: the rules, on the fresh figures.
            suggestions = fallback(f, snap)
            source = .fallback
        }

        if mAnswer == nil && wAnswer == nil {
            notice = String(localized: "Couldn't reach the coach. Kept the previous state.")
        } else if !workoutsUpdated {
            notice = String(localized: "The coach's workout suggestions didn't come through. Showing the last good ones.")
        } else if !missionUpdated {
            notice = String(localized: "The mission couldn't be rewritten. Kept the previous one.")
        }
        return missionUpdated
    }
}
