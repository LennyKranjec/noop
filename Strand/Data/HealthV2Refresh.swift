import Foundation
import StrandAnalytics
import WhoopStore

// HealthV2Refresh.swift — one coordinator for the 2.0 health refreshes that follow a days republish.
//
// HEALTH_V2 §S1-A.8. Called from `AppModel`'s `repo.$days` sink. Throttled (a days republish happens many
// times a day, the inputs are nights): bedroom and WiZ night records, the habit-trial tick (illness flag,
// automatic adherence, completion), today's trial quest, the once-a-day habit report, and the week plan.
// The sleep-anchor plan is refreshed by its own hook in the same sink (`SleepScheduleProvider.noteDaysChanged`)
// and is deliberately not called a second time here. The pass ends with Look ahead's projections and the
// goals' reached / date-passed bookkeeping (DESIGN_V2 decision 14), at most once per `projectionInterval`.

@MainActor
final class HealthV2Refresh {

    static let shared = HealthV2Refresh()
    static let interval: TimeInterval = 10 * 60

    /// Look ahead reads 26 weeks of workouts, lifts and session intensity: far more than this pass's other
    /// steps, so it re-runs at most hourly here (a new local day always re-runs it). Its screen still
    /// refreshes on open.
    static let projectionInterval: TimeInterval = 60 * 60

    private var lastRun: Date?
    private var lastProjectionRun: Date?
    private var running = false
    private var attached = false

    /// One-time wiring of the providers the week plan reads. Idempotent; runs before any refresh this type
    /// drives (both `daysChanged` and a direct `run`). The closures read the shared stores at call time.
    private func attachOnce(model: AppModel) {
        guard !attached else { return }
        attached = true
        CaffeineDailySummary.attach(model.repo)
        WeekPlanSource.shared.trialStatusProvider = { HealthV2Refresh.trialStatusLine() }
        WeekPlanSource.shared.sleepInputsProvider = { SleepScheduleProvider.shared.weekReviewSleepInputs }
    }

    /// Hook target. `days` is the republished list (unused beyond triggering; the stores read the repo).
    func daysChanged(_ days: [DailyMetric], model: AppModel, now: Date = Date()) {
        attachOnce(model: model)
        if let at = lastRun, now.timeIntervalSince(at) < Self.interval { return }
        lastRun = now
        Task { await self.run(model: model, now: now) }
    }

    /// The same pass, unthrottled (a pull-to-refresh on the Habits hub).
    func run(model: AppModel, now: Date = Date()) async {
        guard !running else { return }
        running = true
        defer { running = false }
        attachOnce(model: model)
        let repo = model.repo
        let timings = await repo.sleepTimingsByDay(days: 30)
        await BedroomNightSummary.writeIfDue(repo: repo, timings: timings, now: now)
        WizDailyRecord.noteEnabledState(now: now)
        await WizDailyRecord.finalise(repo: repo, timings: timings, now: now)
        let illness = (model.illnessSignal?.score ?? 0) >= IllnessSignalEngine.raiseThreshold
        await HabitTrialStore.shared.tick(now: now, repo: repo, illnessRaised: illness)
        HabitTrialQuestBridge.shared.sync(now: now)
        await HabitAnalysisStore.shared.refreshIfDue(repo: repo, now: now)
        await WeekPlanSource.shared.refresh(model: model, now: now)
        await refreshProjectionsAndGoals(model: model, now: now)
    }

    /// Look ahead + the goals' bookkeeping. Goal verdicts are only noted from projections computed for
    /// TODAY: when `ProjectionSource.refresh` returned early (a screen's refresh was already in flight) or
    /// has never run, stale or empty series could stamp a goal "date passed" with no data behind it.
    private func refreshProjectionsAndGoals(model: AppModel, now: Date) async {
        let goalDay = Repository.localDayKey(now)
        let projections = ProjectionSource.shared
        let due = projections.asOf != goalDay
            || lastProjectionRun.map { now.timeIntervalSince($0) >= Self.projectionInterval } ?? true
        if due {
            lastProjectionRun = now
            await projections.refresh(model: model, now: now)
        }
        guard projections.asOf == goalDay else { return }
        let goals = GoalStore.shared
        goals.noteAssessments(goals.activeGoals.map { projections.assess($0, today: goalDay) }, today: goalDay)
    }

    /// One line for the weekly review: counts and dates only while a trial runs.
    static func trialStatusLine(now: Date = Date()) -> String? {
        let store = HabitTrialStore.shared
        let today = Repository.localDayKey(now)
        if let p = store.runningProgress(today: today), let entry = HabitTrialCatalog.entry(p.interventionId) {
            return "Trial \(entry.title): day \(p.dayNumber) of \(p.lengthDays), results sealed until \(p.sealedUntil)."
        }
        if let last = store.finished.first, let v = last.result?.verdict, let entry = last.entry,
           let ended = last.endedOn, let age = HabitDay.days(from: ended, to: today), age <= 7 {
            return "Trial \(entry.title) finished: \(v.headline)."
        }
        return nil
    }
}
