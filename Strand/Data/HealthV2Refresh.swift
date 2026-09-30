import Foundation
import StrandAnalytics
import WhoopStore

// HealthV2Refresh.swift — one coordinator for the 2.0 health refreshes that follow a days republish.
//
// HEALTH_V2 §S1-A.8. Called from `AppModel`'s `repo.$days` sink. Throttled (a days republish happens many
// times a day, the inputs are nights): bedroom and WiZ night records, the habit-trial tick (illness flag,
// automatic adherence, completion), today's trial quest, the once-a-day habit report, and the week plan.
// The sleep-anchor plan is refreshed by its own hook in the same sink (`SleepScheduleProvider.noteDaysChanged`)
// and is deliberately not called a second time here.

@MainActor
final class HealthV2Refresh {

    static let shared = HealthV2Refresh()
    static let interval: TimeInterval = 10 * 60

    private var lastRun: Date?
    private var running = false
    private var attached = false

    /// Hook target. `days` is the republished list (unused beyond triggering; the stores read the repo).
    func daysChanged(_ days: [DailyMetric], model: AppModel, now: Date = Date()) {
        if !attached {
            attached = true
            CaffeineDailySummary.attach(model.repo)
            WeekPlanSource.shared.trialStatusProvider = { HealthV2Refresh.trialStatusLine() }
        }
        if let at = lastRun, now.timeIntervalSince(at) < Self.interval { return }
        lastRun = now
        Task { await self.run(model: model, now: now) }
    }

    /// The same pass, unthrottled (a pull-to-refresh on the Habits hub).
    func run(model: AppModel, now: Date = Date()) async {
        guard !running else { return }
        running = true
        defer { running = false }
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
