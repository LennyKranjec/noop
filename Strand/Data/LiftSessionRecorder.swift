import Foundation
import Combine
import StrandAnalytics
import StrandDesign
import StrandImport
import WhoopStore
#if canImport(UserNotifications)
import UserNotifications
#endif
#if os(iOS)
import UIKit
#endif

// LiftSessionRecorder.swift — the running Telos Lift session (DESIGN_V2 decision 16).
//
// OWNS: the logged session value (`LiftLoggedSession`, pure, in StrandAnalytics/Lift), the rest timer, the
// per-exercise context the logger shows (prefill source, "last time", the progression proposal), and the two
// kinds of persistence:
//
//   1. THE JOURNAL — `lift-active.json` in the store directory, rewritten synchronously on EVERY change. A crash
//      or an OS kill loses nothing that was on screen; a relaunch with the same workout re-attaches to it (the
//      session id is derived from the workout start), and a journal whose workout is gone is finalised as an
//      early finish rather than thrown away.
//   2. THE STORE — every checked set is upserted into `liftSession` / `liftSet` (deviceId "lifting", sport
//      "Strength Training") as it is checked, through ONE serial write chain so an un-check can never be
//      overtaken by an older upsert. So even without the journal a crash loses at most the set being written.
//
// ONE SOURCE (decision 16): the rows land exactly where the Alphaprog / Hevy imports put theirs, so
// `StrengthProgressionSource`, the muscle model, the Level's strength term and the coach read logged sessions
// without a second code path. After a finish the per-day series those readers use (`strength_index`,
// `muscle_volume_*`) are rebuilt from the stored sets (`LiftDerivedSeries`), and a later Alphaprog import skips
// the sessions logged here (`LiftImportDedupe`).
//
// FLAGS ARE CLEARED ON EVERY EXIT. `loading` is reset by `defer`; the rest task is cancelled on stop, finish,
// discard and switch; the write chain never holds a flag.

// MARK: - Strap cue seam

/// The two strap cues the logger asks for. `StrapCueEngine` already implements both (`fire(.restOver)`,
/// `fire(.reward, eventId:)`); this seam exists so the recorder can be driven in a test without a strap.
/// Where a rest-over cue ended up, as the strap-cue engine reported it (never what was hoped).
enum LiftCueDelivery: Equatable {
    /// Written to the strap.
    case strap
    /// The engine's own phone fallback buzzed (strap unreachable, app in front).
    case phone
    /// Nobody felt it (strap unreachable and the app not in front, cues off, held by a rule).
    case notDelivered
    /// The motor was busy: the engine re-fires within about a minute and logs the outcome then.
    case deferred
}

@MainActor
protocol LiftCueing {
    /// Buzz the strap for the end of a rest.
    func restOver() -> LiftCueDelivery
    /// The PR reward buzz, once per event id (the engine holds a repeat as `.duplicate`).
    func reward(eventId: String)
}

@MainActor
struct StrapCueLiftCueing: LiftCueing {
    func restOver() -> LiftCueDelivery {
        switch StrapCueEngine.shared.fire(.restOver) {
        case .attempted(.strap): return .strap
        case .attempted(.phone): return .phone
        case .attempted(.notDelivered): return .notDelivered
        case .scheduled: return .deferred
        case .held: return .notDelivered
        }
    }

    func reward(eventId: String) {
        _ = StrapCueEngine.shared.fire(.reward, eventId: eventId)
    }
}

// MARK: - Recorder

@MainActor
final class LiftSessionRecorder: ObservableObject {

    static let shared = LiftSessionRecorder()

    enum Phase: Equatable {
        /// No strength workout attached.
        case idle
        /// Attached, but there is no plan to start from (the empty state: import or log freehand).
        case choosing
        case logging
        /// Finished: `summary` is set and the finish screen shows.
        case finished
    }

    /// What the logger shows beside an exercise, computed once when the session starts.
    struct ExerciseContext: Equatable {
        var prefillSource: LiftPrefill.Source
        var lastTime: [LiftHistorySet]
        var lastTimeTitle: String?
        var proposal: LiftProposal.Result
        /// The best this exercise had reached BEFORE this session (e1RM, heaviest load, and the set behind the
        /// best e1RM). Empty for a first-ever session: then nothing today can be a PR.
        var priorBest: LiftPriorBest
    }

    /// A set that just became a personal record — drives the row's short gold flash in the logger.
    struct PRFlash: Equatable {
        let exerciseId: String
        let setId: String
        let records: [LiftSessionSummary.Record]
        let at: Date
    }

    /// How long the row's PR flash stays up (decision 17: ≤ 1.5 s, then rest).
    nonisolated static let prFlashSeconds: Double = 1.4

    nonisolated static let deviceId = LiftingImporter.sourceId
    nonisolated static let sport = LiftingImporter.sport
    nonisolated static let journalFileName = "lift-active.json"
    nonisolated static let restNotificationId = "telos.lift.restOver"
    nonisolated static let notificationAskedKey = "lift.restNotificationAsked"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var session: LiftLoggedSession?
    @Published private(set) var rest = LiftRestTimer()
    @Published private(set) var restExerciseName: String?
    @Published private(set) var context: [String: ExerciseContext] = [:]
    @Published private(set) var pickReason: LiftTemplatePicker.Reason?
    @Published private(set) var summary: LiftSessionSummary?
    @Published private(set) var loading = false
    /// The last stored-write failure, said on screen rather than swallowed (the journal still has the data).
    @Published private(set) var writeProblem: String?
    /// The PR flash on screen right now, nil otherwise.
    @Published private(set) var prFlash: PRFlash?

    let programs: LiftProgramStore
    var cues: LiftCueing

    private var history: [LiftHistorySession] = []
    /// Exercises whose PR already buzzed the strap this session (once per exercise per session). The strap-cue
    /// engine ALSO dedupes on the event id `pr:<session>:<exercise>`, so a relaunch that forgets this set cannot
    /// double-buzz either; this set only keeps the finish path from asking at all.
    private var rewardedExercises: Set<String> = []
    private var prFlashTask: Task<Void, Never>?
    private var progression: [String: StrengthProgression.Exercise] = [:]
    private var workoutStart: Date?
    private var storeProvider: (() async -> WhoopStore?)?
    private var charge: Double?
    private var holdLoads = false
    private var restTask: Task<Void, Never>?
    private var writeChain: Task<Void, Never>?
    private var inBackground = false
    private let journalURL: URL?
    private let defaults: UserDefaults

    init(programs: LiftProgramStore? = nil,
         cues: LiftCueing? = nil,
         journalURL: URL? = LiftSessionRecorder.defaultJournalURL(),
         defaults: UserDefaults = .standard) {
        self.programs = programs ?? LiftProgramStore.shared
        self.cues = cues ?? StrapCueLiftCueing()
        self.journalURL = journalURL
        self.defaults = defaults
    }

    nonisolated static func defaultJournalURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(journalFileName)
    }

    /// The strength sports that open the logger (the catalogue names are stored data, never localised).
    nonisolated static let strengthSports: Set<String> = ["Strength", "Bodybuilding", "Weightlifting", "Powerlifting",
                                              LiftingImporter.sport]

    nonisolated static func isStrengthSport(_ sport: String?) -> Bool {
        guard let sport else { return false }
        return strengthSports.contains(sport.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Attach / start

    /// Attach to the running strength workout. Idempotent: a second call for the same workout does nothing.
    ///
    /// - charge: today's Charge (nil when not scored — the proposal then simply does not hold for it).
    /// - holdLoads: the week plan's easy-week flag (`WeekPlanSource.currentPlan?.strength.holdLoads`).
    func attach(workoutStart: Date,
                storeProvider: @escaping () async -> WhoopStore?,
                charge: Double?,
                holdLoads: Bool) async {
        self.storeProvider = storeProvider
        self.charge = charge
        self.holdLoads = holdLoads
        if self.workoutStart == workoutStart, phase != .idle { return }
        self.workoutStart = workoutStart
        // A different workout: nothing of the previous one may leak in (its rows are already stored).
        stopRest()
        session = nil
        context = [:]
        summary = nil
        rewardedExercises = []
        prFlash = nil
        phase = .idle
        loading = true
        defer { loading = false }

        let sessionId = LiftLoggedSession.sessionId(workoutStart: workoutStart)
        await loadHistory(excluding: sessionId)

        if let journal = readJournal() {
            if journal.session.start == workoutStart {
                restore(journal)
                return
            }
            await finalizeOrphan(journal)
            await loadHistory(excluding: sessionId)
        }

        let templates = programs.library.allTemplates
        let weekday = Calendar.current.component(.weekday, from: workoutStart)
        if let pick = LiftTemplatePicker.pick(templates: templates, weekday: weekday,
                                              lastCompletedTemplateId: lastCompletedTemplateId(templates)) {
            pickReason = pick.reason
            start(templateId: pick.template.id)
        } else {
            pickReason = nil
            session = nil
            phase = .choosing
        }
    }

    /// Start (or restart, before the first checked set) from a day template; nil = freehand.
    func start(templateId: String?) {
        guard let workoutStart else { return }
        // Never throw away logged work by switching templates mid-session.
        if let s = session, s.start == workoutStart, s.doneCount > 0 { return }
        let template = templateId.flatMap { programs.library.template(id: $0) }
        var exercises: [LiftLoggedExercise] = []
        var ctx: [String: ExerciseContext] = [:]
        for plan in template?.exercises ?? [] {
            let made = makeExercise(plan: plan, templateId: template?.id, templateName: template?.name)
            exercises.append(made.exercise)
            ctx[made.exercise.id] = made.context
        }
        session = LiftLoggedSession(
            id: LiftLoggedSession.sessionId(workoutStart: workoutStart),
            templateId: template?.id,
            templateName: template?.name,
            programName: template.flatMap { programs.library.programName(forTemplate: $0.id) },
            start: workoutStart,
            exercises: exercises)
        context = ctx
        stopRest()
        phase = .logging
        writeJournal()
    }

    /// A plan was just imported from the empty state: pick today's template from it and start.
    func restartAfterPlanImport() {
        guard let workoutStart, (session?.doneCount ?? 0) == 0 else { return }
        let templates = programs.library.allTemplates
        let weekday = Calendar.current.component(.weekday, from: workoutStart)
        guard let pick = LiftTemplatePicker.pick(templates: templates, weekday: weekday,
                                                 lastCompletedTemplateId: lastCompletedTemplateId(templates))
        else { return }
        pickReason = pick.reason
        start(templateId: pick.template.id)
    }

    /// The templates the header can switch to.
    var templates: [LiftDayTemplate] { LiftTemplatePicker.rotation(programs.library.allTemplates) }

    var canSwitchTemplate: Bool { (session?.doneCount ?? 0) == 0 }

    // MARK: - Set edits

    func setWeight(exerciseId: String, setId: String, to kg: Double?) {
        mutateSession { s in s.updateSet(exerciseId: exerciseId, setId: setId) { set in set.weightKg = kg; set.prefilled = false } }
        resaveIfDone(exerciseId: exerciseId, setId: setId)
    }

    func setReps(exerciseId: String, setId: String, to reps: Int?) {
        let clean = reps.map { max(0, min(999, $0)) }
        mutateSession { s in s.updateSet(exerciseId: exerciseId, setId: setId) { set in set.reps = clean; set.prefilled = false } }
        resaveIfDone(exerciseId: exerciseId, setId: setId)
    }

    func stepWeight(exerciseId: String, setId: String, by steps: Int) {
        guard let ex = session?.exercises.first(where: { $0.id == exerciseId }),
              let set = ex.sets.first(where: { $0.id == setId }) else { return }
        setWeight(exerciseId: exerciseId, setId: setId,
                  to: LiftIncrement.step(set.weightKg, by: steps, incrementKg: ex.increment.kg))
        TelosHaptics.play(.select)
    }

    func stepReps(exerciseId: String, setId: String, by delta: Int) {
        guard let set = session?.exercises.first(where: { $0.id == exerciseId })?.sets.first(where: { $0.id == setId })
        else { return }
        let next = (set.reps ?? 0) + delta
        setReps(exerciseId: exerciseId, setId: setId, to: next > 0 ? next : nil)
        TelosHaptics.play(.select)
    }

    func setKind(exerciseId: String, setId: String, to kind: LiftSetKind) {
        mutateSession { s in s.updateSet(exerciseId: exerciseId, setId: setId) { set in set.kind = kind } }
        resaveIfDone(exerciseId: exerciseId, setId: setId)
    }

    /// Check a set: done now, the rest timer starts (unless that was the last planned set), the row is stored.
    func check(exerciseId: String, setId: String) {
        guard var s = session else { return }
        let now = Date()
        guard let seconds = s.check(exerciseId: exerciseId, setId: setId, at: now,
                                    defaultRestSeconds: programs.library.defaultRestSeconds) else { return }
        session = s
        rewardIfRecord(exerciseId: exerciseId, setId: setId, session: s)
        if !s.allPlannedDone, seconds > 0 {
            startRest(seconds: seconds, exerciseName: s.exercises.first { $0.id == exerciseId }?.name, now: now)
        } else {
            stopRest()
        }
        writeJournal()
        enqueueStoreWrite(replacing: false)
        askForNotificationsOnce()
    }

    /// The in-the-moment reward (decisions 16–17). A checked set that beats the exercise's pre-session best
    /// (raised by this session's other done sets) flashes its row gold and plays the reward haptic; the FIRST
    /// such set per exercise also buzzes the strap. Any other check plays `success`. One action, one pattern.
    private func rewardIfRecord(exerciseId: String, setId: String, session s: LiftLoggedSession) {
        guard let ex = s.exercises.first(where: { $0.id == exerciseId }) else { return }
        let records = LiftRecordCheck.liveRecords(setId: setId, in: ex,
                                                  prior: context[exerciseId]?.priorBest ?? LiftPriorBest())
        guard !records.isEmpty else {
            TelosHaptics.play(.success)
            return
        }
        TelosHaptics.play(.reward, action: "lift.pr.\(s.id).\(setId)")
        if !rewardedExercises.contains(exerciseId) {
            rewardedExercises.insert(exerciseId)
            cues.reward(eventId: Self.prEventId(sessionId: s.id, exerciseId: exerciseId))
        }
        let flash = PRFlash(exerciseId: exerciseId, setId: setId, records: records, at: Date())
        prFlash = flash
        prFlashTask?.cancel()
        prFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.prFlashSeconds * 1_000_000_000))
            guard !Task.isCancelled, self?.prFlash == flash else { return }
            self?.prFlash = nil
        }
    }

    /// The strap-cue event id for one exercise's PR in one session — shared by the live check and the finish
    /// screen, so the engine's per-event dedupe (`StrapCueGate.eventKey` + `markFired`) holds the second call.
    nonisolated static func prEventId(sessionId: String, exerciseId: String) -> String {
        "pr:\(sessionId):\(exerciseId)"
    }

    func uncheck(exerciseId: String, setId: String) {
        mutateSession { $0.uncheck(exerciseId: exerciseId, setId: setId) }
        enqueueStoreWrite(replacing: true)
    }

    func addSet(exerciseId: String, kind: LiftSetKind = .working) {
        mutateSession { $0.addSet(exerciseId: exerciseId, kind: kind) }
    }

    func removePendingSet(exerciseId: String, setId: String) {
        mutateSession { $0.removePendingSet(exerciseId: exerciseId, setId: setId) }
    }

    /// Copy the proposal's weight/reps into this exercise's pending WORK sets — only on the wearer's tap.
    func applyProposal(exerciseId: String) {
        guard let p = context[exerciseId]?.proposal, p.kind != .none else { return }
        mutateSession { s in
            guard let e = s.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
            for i in s.exercises[e].sets.indices {
                guard s.exercises[e].sets[i].status == .pending, !s.exercises[e].sets[i].kind.isWarmup else { continue }
                if let w = p.weightKg { s.exercises[e].sets[i].weightKg = w }
                if let r = p.reps { s.exercises[e].sets[i].reps = r }
                s.exercises[e].sets[i].prefilled = false
            }
        }
        TelosHaptics.play(.commit)
    }

    // MARK: - Exercise edits (session, optionally written back to the plan)

    func updateExercise(exerciseId: String, equipment: String?, targetReps: Int?, restSeconds: Int?,
                        saveToPlan: Bool) {
        mutateSession { s in
            guard let e = s.exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
            s.exercises[e].equipment = equipment
            s.exercises[e].targetReps = targetReps
            s.exercises[e].restSeconds = restSeconds
            let plan = LiftExercisePlan(name: s.exercises[e].name, equipment: equipment, sets: [])
            s.exercises[e].isBodyweight = plan.isBodyweight
        }
        guard saveToPlan, let templateId = session?.templateId else { return }
        programs.mutate { lib in
            lib.updateTemplate(id: templateId) { day in
                day.updateExercise(id: exerciseId) { ex in
                    ex.equipment = equipment
                    ex.targetReps = targetReps
                    ex.restSeconds = restSeconds
                }
            }
        }
    }

    /// Add an exercise to today's session (and to the plan when asked). Three working sets at the given target.
    func addExercise(name: String, equipment: String?, targetReps: Int?, saveToPlan: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, session != nil else { return }
        var plan = LiftExercisePlan(name: trimmed, equipment: equipment, sets: [], targetReps: targetReps)
        plan.setWorkingSetCount(3)
        let made = makeExercise(plan: plan, templateId: session?.templateId, templateName: session?.templateName)
        mutateSession { $0.exercises.append(made.exercise) }
        context[made.exercise.id] = made.context
        if saveToPlan, let templateId = session?.templateId {
            programs.mutate { lib in lib.updateTemplate(id: templateId) { $0.addExercise(plan) } }
        }
    }

    // MARK: - Rest timer

    func adjustRest(bySeconds delta: Int) {
        let now = Date()
        rest.adjust(bySeconds: delta, now: now)
        TelosHaptics.play(.select)
        if rest.isRunning(at: now) { scheduleRestCue() } else { stopRest() }
        writeJournal()
    }

    func skipRest() {
        stopRest()
        writeJournal()
    }

    /// The app moved to / from the background (the view forwards `scenePhase`).
    ///
    /// The local notification is the BACKUP for a suspended app, so it is scheduled only on the way into the
    /// background and removed on the way back: in the foreground the strap cue and the phone haptic are the
    /// cue, and a banner on top of them would be the same event twice.
    func sceneDidChange(background: Bool) {
        inBackground = background
        if background {
            scheduleRestNotification()
        } else {
            cancelRestNotification()
            if case .late = rest.expiry(at: Date()) { stopRest() } else if rest.endsAt != nil { scheduleRestCue() }
        }
    }

    private func startRest(seconds: Int, exerciseName: String?, now: Date) {
        rest.start(now: now, seconds: seconds)
        restExerciseName = exerciseName
        scheduleRestCue()
        if inBackground { scheduleRestNotification() }
    }

    private func stopRest() {
        restTask?.cancel()
        restTask = nil
        rest.stop()
        restExerciseName = nil
        cancelRestNotification()
    }

    /// Wake at the target date. A task sleeping through a suspension wakes LATE, and `expiry` then says so:
    /// a late zero is not cued on the strap (the notification already was the cue).
    private func scheduleRestCue() {
        restTask?.cancel()
        guard let end = rest.endsAt else { return }
        let delay = max(0, end.timeIntervalSinceNow)
        restTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.restDue()
        }
    }

    private func restDue() {
        switch rest.expiry(at: Date()) {
        case .idle:
            return
        case .running:
            scheduleRestCue()
            return
        case .dueNow:
            let delivery = cues.restOver()
            // A phone haptic when in front — unless the engine's fallback already buzzed the phone (one action,
            // one pattern).
            if delivery != .phone, isForeground { TelosHaptics.play(.warning) }
            // Suspended-but-alive with an unreachable strap: the local notification is the only cue left, so
            // it is NOT removed here.
            if delivery == .notDelivered, !isForeground {
                restTask = nil
                rest.stop()
                restExerciseName = nil
                writeJournal()
                return
            }
        case .late:
            break
        }
        restTask = nil
        rest.stop()
        restExerciseName = nil
        cancelRestNotification()
        writeJournal()
    }

    private var isForeground: Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return !inBackground
        #endif
    }

    private func askForNotificationsOnce() {
        guard !defaults.bool(forKey: Self.notificationAskedKey) else { return }
        defaults.set(true, forKey: Self.notificationAskedKey)
        // From a user action (the first checked set), never from a launch path — see NotificationPermission.
        Task { _ = await NotificationPermission.requestFromUserAction() }
    }

    private func scheduleRestNotification() {
        #if canImport(UserNotifications)
        cancelRestNotification()
        let remaining = rest.remaining(at: Date())
        guard remaining >= 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Rest over")
        if let name = restExerciseName {
            content.body = String(localized: "Next set: \(name)")
        }
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)
        let request = UNNotificationRequest(identifier: Self.restNotificationId, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { _ in }
        #endif
    }

    private func cancelRestNotification() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.restNotificationId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.restNotificationId])
        #endif
    }

    // MARK: - Finish / discard

    /// Finish. Pending sets become NOT DONE (never zero); the final rows are written; the per-day series are
    /// rebuilt; the summary is built; a PR fires the strap reward once for this session.
    @discardableResult
    func finish() async -> LiftSessionSummary? {
        guard var s = session else { return nil }
        s.finish(at: Date())
        session = s
        stopRest()
        writeJournal()

        let finished = s
        enqueueStoreWrite(replacing: true, finalDelete: finished.doneCount == 0)
        await writeChain?.value
        if let store = await storeProvider?() {
            await LiftDerivedSeries.rebuild(store: store)
        }

        let built = LiftSummaryBuilder.build(
            session: finished,
            history: history,
            musclesFor: { MuscleAttribution.muscles(for: $0).map(\.rawValue) },
            calendar: .current)
        summary = built
        // Records that did not already buzz at check time (e.g. a value edited after checking): one buzz each,
        // under the SAME event id the live path uses, so nothing is rewarded twice.
        var unrewarded = false
        for (ex, line) in zip(finished.exercises, built.exercises) {
            guard !line.records.isEmpty, !rewardedExercises.contains(ex.id) else { continue }
            rewardedExercises.insert(ex.id)
            cues.reward(eventId: Self.prEventId(sessionId: finished.id, exerciseId: ex.id))
            unrewarded = true
        }
        if unrewarded { TelosHaptics.play(.reward, action: "lift.pr.\(finished.id)") }
        clearJournal()
        phase = .finished
        return built
    }

    /// The finished session's one-line note for its workout row — the same wording an imported session carries
    /// ("Lower A (Di): Strength · volume load 12,400 kg · 18 sets · 5 exercises"). Hand-off: `AppModel.endWorkout`.
    var finishedWorkoutNote: String? {
        guard phase == .finished, let s = session, let summary, summary.setsDone > 0 else { return nil }
        let lifting = LiftingSession(
            start: s.start, end: s.end ?? s.start,
            volumeLoadKg: summary.volumeKg,
            setCount: summary.workingSetsDone,
            exerciseCount: summary.exercises.filter { $0.setsDone > 0 }.count,
            totalReps: 0,
            topSetKg: nil,
            title: s.templateName)
        return lifting.volumeLoadNote()
    }

    /// The workout was deleted: drop the session everywhere.
    func discard() {
        stopRest()
        rewardedExercises = []
        prFlash = nil
        let id = session?.id
        session = nil
        context = [:]
        summary = nil
        phase = .idle
        workoutStart = nil
        clearJournal()
        guard let id else { return }
        let provider = storeProvider
        let previous = writeChain
        writeChain = Task {
            await previous?.value
            guard let store = await provider?() else { return }
            _ = try? await store.deleteLiftSession(id: id)
        }
    }

    /// After the finish screen is dismissed.
    func reset() {
        stopRest()
        rewardedExercises = []
        prFlash = nil
        session = nil
        context = [:]
        summary = nil
        phase = .idle
        workoutStart = nil
    }

    // MARK: - Store writes (one serial chain)

    /// Write the current session. `replacing` rewrites the session's whole set list (un-check, finish);
    /// otherwise the done rows are upserted (the check path). `finalDelete` removes a finished session that
    /// has no done set at all — a session row with no sets would read as "a session with nothing in it".
    private func enqueueStoreWrite(replacing: Bool, finalDelete: Bool = false) {
        guard let snapshot = session else { return }
        let provider = storeProvider
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            guard let store = await provider?() else { return }
            do {
                if finalDelete {
                    _ = try await store.deleteLiftSession(id: snapshot.id)
                    return
                }
                let rows = LiftStoreBridge.setRows(snapshot, deviceId: Self.deviceId)
                guard !rows.isEmpty || replacing else { return }
                _ = try await store.upsertLiftSessions([LiftStoreBridge.sessionRow(snapshot, deviceId: Self.deviceId,
                                                                                   sport: Self.sport)])
                if replacing {
                    _ = try await store.replaceLiftSets(sessionId: snapshot.id, sets: rows)
                } else {
                    _ = try await store.upsertLiftSets(rows)
                }
                self?.writeProblem = nil
            } catch {
                self?.writeProblem = String(localized: "Couldn't save the last set to the log — it is kept on this phone and saved again on the next change.")
            }
        }
    }

    private func resaveIfDone(exerciseId: String, setId: String) {
        let done = session?.exercises.first { $0.id == exerciseId }?.sets.first { $0.id == setId }?.status == .done
        if done { enqueueStoreWrite(replacing: false) }
    }

    // MARK: - Journal

    private struct Journal: Codable {
        var session: LiftLoggedSession
        var rest: LiftRestTimer
        var restExerciseName: String?
    }

    private func mutateSession(_ change: (inout LiftLoggedSession) -> Void) {
        guard var s = session else { return }
        change(&s)
        guard s != session else { return }
        session = s
        writeJournal()
    }

    private func writeJournal() {
        guard let journalURL, let s = session, phase != .finished else { return }
        let journal = Journal(session: s, rest: rest, restExerciseName: restExerciseName)
        guard let data = try? JSONEncoder().encode(journal) else { return }
        try? data.write(to: journalURL, options: .atomic)
    }

    private func readJournal() -> Journal? {
        guard let journalURL, let data = try? Data(contentsOf: journalURL) else { return nil }
        return try? JSONDecoder().decode(Journal.self, from: data)
    }

    private func clearJournal() {
        guard let journalURL else { return }
        try? FileManager.default.removeItem(at: journalURL)
    }

    private func restore(_ journal: Journal) {
        session = journal.session
        rest = journal.rest
        restExerciseName = journal.restExerciseName
        var ctx: [String: ExerciseContext] = [:]
        for ex in journal.session.exercises {
            let plan = LiftExercisePlan(id: ex.id, name: ex.name, equipment: ex.equipment, sets: [],
                                        targetReps: ex.targetReps, restSeconds: ex.restSeconds)
            ctx[ex.id] = makeContext(plan: plan, increment: ex.increment,
                                     templateId: journal.session.templateId,
                                     templateName: journal.session.templateName).context
        }
        context = ctx
        phase = .logging
        switch rest.expiry(at: Date()) {
        case .running: scheduleRestCue()
        case .dueNow: restDue()
        case .late, .idle: stopRest()
        }
    }

    /// A journal whose workout is gone (killed, then ended or discarded elsewhere): keep what was done as an
    /// early finish at the last checked set, or drop it when nothing was done.
    private func finalizeOrphan(_ journal: Journal) async {
        var s = journal.session
        let last = s.doneSetsInOrder.last?.set.completedAt ?? s.start
        s.finish(at: last)
        if let store = await storeProvider?() {
            if s.doneCount == 0 {
                _ = try? await store.deleteLiftSession(id: s.id)
            } else {
                _ = try? await store.upsertLiftSessions([LiftStoreBridge.sessionRow(s, deviceId: Self.deviceId,
                                                                                    sport: Self.sport)])
                _ = try? await store.replaceLiftSets(sessionId: s.id,
                                                     sets: LiftStoreBridge.setRows(s, deviceId: Self.deviceId))
                await LiftDerivedSeries.rebuild(store: store)
            }
        }
        clearJournal()
    }

    /// Hand-off hook for app launch (see the report): finalise a journal left by a killed session whose
    /// workout no longer runs. Safe to call when there is none.
    func finalizeOrphanedJournal(activeWorkoutStart: Date?, storeProvider: @escaping () async -> WhoopStore?) async {
        guard phase == .idle, let journal = readJournal() else { return }
        if let activeWorkoutStart, journal.session.start == activeWorkoutStart { return }
        self.storeProvider = storeProvider
        await finalizeOrphan(journal)
    }

    // MARK: - History + context

    private func loadHistory(excluding sessionId: String) async {
        guard let store = await storeProvider?() else {
            history = []
            progression = [:]
            return
        }
        let nowTs = Int(Date().timeIntervalSince1970)
        let sessions = (try? await store.liftSessions(deviceId: Self.deviceId, fromTs: 0, toTs: nowTs)) ?? []
        let sets = (try? await store.liftSetsWithSessionStart(deviceId: Self.deviceId, fromTs: 0, toTs: nowTs)) ?? []
        history = LiftStoreBridge.history(sessions: sessions, sets: sets).filter { $0.id != sessionId }
        let exercises = await StrengthProgressionSource.load(store: store)
        var byKey: [String: StrengthProgression.Exercise] = [:]
        for ex in exercises where byKey[LiftDedupe.exerciseKey(ex.name)] == nil {
            byKey[LiftDedupe.exerciseKey(ex.name)] = ex
        }
        progression = byKey
    }

    /// The template of the most recent stored session that ran one of `templates` (a logged session by id, an
    /// imported one by its title's template segment) — the anchor for the rotation.
    private func lastCompletedTemplateId(_ templates: [LiftDayTemplate]) -> String? {
        for session in history.reversed() {
            if let t = templates.first(where: { session.ran(templateId: $0.id, templateName: $0.name) }) {
                return t.id
            }
        }
        return nil
    }

    private func makeExercise(plan: LiftExercisePlan, templateId: String?,
                              templateName: String?) -> (exercise: LiftLoggedExercise, context: ExerciseContext) {
        let increment = LiftIncrement.resolve(weightsKg: LiftPrefill.weightsUsed(exercise: plan.name, history: history))
        let made = makeContext(plan: plan, increment: increment, templateId: templateId, templateName: templateName)
        let exercise = LiftLoggedExercise(
            id: plan.id, name: plan.name, equipment: plan.equipment, targetReps: plan.targetReps,
            restSeconds: plan.restSeconds, isBodyweight: plan.isBodyweight,
            sets: made.prefill.sets, increment: increment)
        return (exercise: exercise, context: made.context)
    }

    private func makeContext(plan: LiftExercisePlan, increment: LiftIncrement.Resolved, templateId: String?,
                             templateName: String?) -> (prefill: LiftPrefill.Result, context: ExerciseContext) {
        let prefill = LiftPrefill.build(plan: plan, templateId: templateId, templateName: templateName, history: history)
        let proposal = LiftProposal.make(
            input: Self.proposalInput(progression[LiftDedupe.exerciseKey(plan.name)]),
            holdLoads: holdLoads,
            charge: charge,
            lowChargeThreshold: StrengthProgressionSource.lowChargeThreshold,
            stepKg: increment.observed ? increment.kg : nil)
        return (prefill: prefill,
                context: ExerciseContext(prefillSource: prefill.source, lastTime: prefill.lastTime,
                                         lastTimeTitle: prefill.lastTimeTitle, proposal: proposal,
                                         priorBest: LiftPriorBest(sets: history.flatMap { $0.sets(of: plan.name) })))
    }

    /// `StrengthProgression`'s reading of one exercise, in the proposal's input shape.
    nonisolated static func proposalInput(_ ex: StrengthProgression.Exercise?) -> LiftProposal.Input? {
        guard let ex else { return nil }
        if let abstained = ex.abstained {
            switch abstained {
            case .tooFewSessions(let have, let need):
                return LiftProposal.Input(step: nil, weightKg: nil, reps: nil, incrementKg: nil,
                                          fromWeightKg: nil, fromReps: nil, tooFewHave: have, tooFewNeed: need)
            case .noUsableSets:
                return nil
            }
        }
        let last = ex.sessions.last { $0.topSetKg != nil }
        var step: LiftProposal.Input.Step?
        if let s = ex.suggestion {
            switch s.step {
            case .addReps: step = .addReps
            case .addWeight: step = .addWeight
            }
        }
        return LiftProposal.Input(
            step: step,
            weightKg: ex.suggestion?.weightKg,
            reps: ex.suggestion?.reps,
            incrementKg: ex.suggestion?.incrementKg ?? ex.incrementKg,
            fromWeightKg: ex.suggestion?.fromWeightKg ?? last?.topSetKg,
            fromReps: ex.suggestion?.fromReps ?? last?.topSetReps,
            stalledSessions: ex.stall?.sessions,
            stalledDays: ex.stall?.days,
            stuckAtKg: ex.stall?.stuckAtKg)
    }
}

// MARK: - Derived per-day series (strength_index, muscle_volume_*)

/// Rebuilds the two per-day series the Level's strength term and the muscle model read, from the STORED sets —
/// imported and logged alike — so a session logged in Telos counts exactly like an imported one.
///
/// `strength_index` is recomputed over the whole stored history with `StrengthIndex.daily` (the same function
/// the Alphaprog import calls; warm-ups and bodyweight-added loads excluded the same way). The muscle volume
/// rows are rewritten only for the DAYS that hold a Telos-logged session, summing every stored session of that
/// day — the import already wrote the other days from the file, and rewriting them from stored sets would
/// drop the volume of an old import that carried no per-set detail.
enum LiftDerivedSeries {

    static func rebuild(store: WhoopStore, now: Date = Date(), calendar: Calendar = .current) async {
        let deviceId = LiftingImporter.sourceId
        let nowTs = Int(now.timeIntervalSince1970)
        guard let sessions = try? await store.liftSessions(deviceId: deviceId, fromTs: 0, toTs: nowTs),
              let sets = try? await store.liftSetsWithSessionStart(deviceId: deviceId, fromTs: 0, toTs: nowTs),
              !sets.isEmpty else { return }
        let history = LiftStoreBridge.history(sessions: sessions, sets: sets)
        guard history.contains(where: { LiftStoreBridge.isTelosSession(id: $0.id) }) else { return }

        // strength_index, whole history.
        let workouts = history.map { workout(from: $0) }
        let strength = StrengthIndex.daily(workouts, through: now, calendar: calendar)
        if !strength.isEmpty {
            _ = try? await store.upsertMetricSeries(
                strength.map { MetricPoint(day: $0.day, key: StrengthIndex.key, value: $0.value) },
                deviceId: deviceId)
        }

        // muscle_volume_*, for the days that hold a logged session.
        let telosDays = Set(history.filter { LiftStoreBridge.isTelosSession(id: $0.id) }
            .map { Repository.localDayKey($0.start) })
        let sameDays = history.filter { telosDays.contains(Repository.localDayKey($0.start)) }
        let liftingSessions = sameDays.map { h -> LiftingSession in
            var byExercise: [String: Double] = [:]
            for set in h.sets { byExercise[set.exercise, default: 0] += set.volumeKg }
            return LiftingSession(start: h.start, end: h.end ?? h.start,
                                  volumeLoadKg: h.sets.reduce(0) { $0 + $1.volumeKg },
                                  setCount: h.sets.filter { !$0.isWarmup }.count,
                                  exerciseCount: Set(h.sets.map { LiftDedupe.exerciseKey($0.exercise) }).count,
                                  totalReps: h.sets.filter { !$0.isWarmup }.compactMap(\.reps).reduce(0, +),
                                  topSetKg: h.sets.filter { !$0.isWarmup }.compactMap(\.weightKg).max(),
                                  title: h.title,
                                  muscleVolumeKg: LiftingImporter.muscleVolume(byExercise: byExercise))
        }
        let rows = LiftingImporter.muscleSeriesRows(liftingSessions, calendar: calendar)
        if !rows.isEmpty {
            _ = try? await store.upsertMetricSeries(rows.map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) },
                                                    deviceId: deviceId)
        }
    }

    /// A stored session in the shape `StrengthIndex.daily` reads. Warm-ups are left out (the Alphaprog set has no
    /// warm-up flag, and StrengthIndex excludes warm-ups anyway); a bodyweight-added load keeps its flag.
    static func workout(from h: LiftHistorySession) -> AlphaprogImporter.Workout {
        var order: [String] = []
        var byName: [String: [AlphaprogImporter.Set]] = [:]
        for set in h.sets where !set.isWarmup {
            if byName[set.exercise] == nil { order.append(set.exercise) }
            byName[set.exercise, default: []].append(AlphaprogImporter.Set(
                weightKg: set.weightKg ?? 0, reps: set.reps ?? 0, addedToBodyweight: set.addedToBodyweight))
        }
        return AlphaprogImporter.Workout(
            title: h.title ?? "", start: h.start, end: h.end ?? h.start,
            exercises: order.map { AlphaprogImporter.Exercise(name: $0, sets: byName[$0] ?? []) })
    }
}

// MARK: - Import dedupe

/// Keeps a later Alphaprog / lifting import from counting a session already logged in Telos (decision 16).
/// The rule is `LiftDedupe.isSameSession` (± 30 min and the same template or exercises); the LOGGED session
/// wins, and the duplicates are dropped from the import before its workout rows, sets and muscle rows are
/// written.
enum LiftImportDedupe {

    static func filter(_ sessions: [LiftingSession], store: WhoopStore) async -> (kept: [LiftingSession], skipped: Int) {
        guard let first = sessions.map(\.start).min(), let last = sessions.map(\.start).max() else {
            return (sessions, 0)
        }
        let pad = Int(LiftDedupe.tolerance)
        let fromTs = Int(first.timeIntervalSince1970) - pad
        let toTs = Int(last.timeIntervalSince1970) + pad
        let stored = ((try? await store.liftSessions(deviceId: LiftingImporter.sourceId, fromTs: fromTs, toTs: toTs)) ?? [])
            .filter { LiftStoreBridge.isTelosSession(id: $0.id) }
        guard !stored.isEmpty else { return (sessions, 0) }
        let sets = (try? await store.liftSetsWithSessionStart(deviceId: LiftingImporter.sourceId,
                                                             fromTs: fromTs, toTs: toTs)) ?? []
        let logged = LiftStoreBridge.history(sessions: stored, sets: sets).map {
            LiftDedupe.Candidate(start: $0.start, title: $0.title, exercises: $0.sets.map(\.exercise))
        }
        let imported = sessions.map {
            LiftDedupe.Candidate(start: $0.start, title: $0.title, exercises: $0.sets.map(\.exercise))
        }
        let dupes = LiftDedupe.duplicateIndices(imported: imported, logged: logged)
        guard !dupes.isEmpty else { return (sessions, 0) }
        let kept = sessions.enumerated().filter { !dupes.contains($0.offset) }.map(\.element)
        return (kept, dupes.count)
    }
}
