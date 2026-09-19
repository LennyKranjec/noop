#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date = .distantPast
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while its content changes and at least every `refreshEvery` (60 s) while it
    /// does not, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120

    /// A session in progress, as the banner shows it.
    struct Workout: Equatable {
        var name: String
        /// The start with the pauses removed, for the lock screen's self-ticking clock.
        var clockStart: Date
        /// The frozen active seconds while paused; nil while running.
        var pausedSeconds: Int?
        var effort: String?
        var effortFraction: Double?
        var recovery: Bool
        var stressStart: Double?
        var stressNow: Double?
    }

    /// What the last push carried about the session, so a start, an end or a pause goes out AT ONCE
    /// instead of waiting out the two-second throttle.
    private var lastWorkoutShape: String = ""
    /// The content of the last push. An update whose content is identical is skipped — the Lock Screen
    /// already shows it — except that one still goes out every `refreshEvery` so the stale date keeps
    /// moving ahead of `staleAfter` while the stream is live.
    private var lastPushedState: NOOPActivityAttributes.ContentState?
    private static let refreshEvery: TimeInterval = 60

    /// Drive the activity from the latest live values. Lazily starts when the strap is CONNECTED (the
    /// live link, not the sticky "paired" flag) and a heart rate is present; ends the moment the link
    /// drops. Throttled to ~once every 2 s so we stay well under the Live Activity update budget.
    func update(bpm: Int?, recovery: Int?, connected: Bool, effort: Int? = nil, workout: Workout? = nil) {
        guard authInfo.areActivitiesEnabled else { return }

        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

        // User opt-out (#336): if the in-app toggle is off, never start — and end any activity that's
        // already showing (the user just turned it off; this fires on the next ~1 Hz HR tick).
        guard UnitPrefs.liveActivityEnabled() else {
            if activity != nil { Task { await end() } }
            return
        }

        // End the moment the live link drops — `bonded` stays true across every disconnect (it means
        // "this strap is paired"), so keying off it left a frozen, fabricated "live" HR on the Lock
        // Screen / Dynamic Island indefinitely after the strap went out of range.
        if !connected {
            Task { await end() }
            return
        }
        guard bpm != nil else { return }

        // The 2-second throttle goes FIRST, before any content is built: most ~1 Hz ticks stop here.
        let shape = workout.map { "\($0.name)|\($0.pausedSeconds != nil)" } ?? ""
        let shapeChanged = shape != lastWorkoutShape
        if activity != nil {
            guard shapeChanged || Date().timeIntervalSince(lastPush) > 2 else { return }
        }

        var state = NOOPActivityAttributes.ContentState(bpm: bpm, recovery: recovery, bonded: connected,
                                                        effort: effort)
        if let workout {
            state.workoutName = workout.name
            state.workoutClockStart = workout.clockStart
            state.workoutPausedSeconds = workout.pausedSeconds
            state.workoutEffort = workout.effort
            state.workoutEffortFraction = workout.effortFraction
            state.workoutRecovery = workout.recovery
            state.stressStart = workout.stressStart
            state.stressNow = workout.stressNow
        }
        let staleDate = Date().addingTimeInterval(Self.staleAfter)

        if let activity {
            // Same content as the last push: nothing on screen would change, so spend no update — unless
            // `refreshEvery` has passed, when it goes out anyway to carry the stale date forward.
            if state == lastPushedState, Date().timeIntervalSince(lastPush) < Self.refreshEvery { return }
            lastWorkoutShape = shape
            lastPush = Date()
            lastPushedState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. The 2-second throttle above only guards the update path.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                lastPush = Date()
                lastWorkoutShape = shape
                lastPushedState = state
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        self.lastPushedState = nil
    }
}
#endif
