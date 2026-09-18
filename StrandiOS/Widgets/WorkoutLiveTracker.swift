#if os(iOS)
import Foundation
import StrandAnalytics

/// What the Live Activity shows about the session in progress, kept current while it runs.
///
/// EFFORT for a load session comes straight off the running workout. STRESS for a recovery session is
/// read here: the first five minutes once they have passed, then the latest five once the session is ten
/// minutes old, so the two windows never overlap. Read at most once a minute and off the main actor —
/// the heart-rate tick that calls this arrives every second.
@MainActor
final class WorkoutLiveTracker {
    private var sessionStart: Date?
    private var dayHours: [DaytimeStress.HourPoint] = []
    private var stressStart: Double?
    private var stressNow: Double?
    private var lastRead: Date = .distantPast
    private var reading = false

    private static let readEvery: TimeInterval = 60

    /// The banner's view of `model`'s session, or nil when none is running.
    func workout(for model: AppModel) -> LiveActivityController.Workout? {
        guard let w = model.activeWorkout else {
            reset()
            return nil
        }
        if sessionStart != w.start {
            reset()
            sessionStart = w.start
        }
        let recovery = WorkoutCatalog.isRecovery(w.sport)
        if recovery { readStressIfDue(start: w.start, repo: model.repo) }

        let scale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? "")
        let now = Date()
        return LiveActivityController.Workout(
            name: WorkoutSource.displaySport(w.sport),
            clockStart: w.start.addingTimeInterval(w.pausedDuration),
            pausedSeconds: w.isPaused ? Int(w.elapsed(at: now)) : nil,
            effort: UnitFormatter.effortDisplay(w.liveStrain, scale: scale),
            effortFraction: min(1, max(0, w.liveStrain / 100)),
            recovery: recovery,
            stressStart: stressStart,
            stressNow: stressNow)
    }

    private func reset() {
        sessionStart = nil
        dayHours = []
        stressStart = nil
        stressNow = nil
        lastRead = .distantPast
    }

    private func readStressIfDue(start: Date, repo: Repository) {
        let now = Date()
        guard !reading, now.timeIntervalSince(lastRead) >= Self.readEvery else { return }
        let window = WorkoutStressDelta.windowSeconds
        let startTs = Int(start.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)
        guard nowTs - startTs >= window else { return }
        reading = true
        lastRead = now
        Task { [weak self] in
            guard let self else { return }
            defer { self.reading = false }
            // Today's reference hours, once per session: the calm a window is measured against does not
            // move meaningfully within one meditation, and re-scoring the day every minute would.
            if self.dayHours.isEmpty {
                self.dayHours = await StressDayCurve.today(repo: repo)?.result.hours ?? []
            }
            let hours = self.dayHours
            if self.stressStart == nil {
                self.stressStart = await WindowStress.level(repo: repo, from: startTs, to: startTs + window,
                                                            dayHours: hours)
            }
            if nowTs - startTs >= 2 * window,
               let latest = await WindowStress.level(repo: repo, from: nowTs - window, to: nowTs,
                                                     dayHours: hours) {
                self.stressNow = latest
            }
            // A session that ended while this was reading must not have its figures carried forward.
            if self.sessionStart != start { self.stressStart = nil; self.stressNow = nil }
        }
    }
}
#endif
