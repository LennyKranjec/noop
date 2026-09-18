#if os(iOS)
import Foundation
import ActivityKit

/// Live Activity attributes for an active live-HR / workout session. Shared between the app (which
/// starts/updates the activity) and the widget extension (which renders it on the Lock Screen and in
/// the Dynamic Island).
public struct NOOPActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var bpm: Int?
        public var recovery: Int?
        public var bonded: Bool
        // Effort / strain on NOOP's 0–100 axis (#446) — one more stat in the Dynamic Island expanded
        // region. OPTIONAL with a nil default so an activity started by an older build still decodes.
        public var effort: Int?

        // THE WORKOUT, while one is running. All optional and nil outside a session, so the same
        // activity is the live-HR banner between sessions and the session banner during one — and an
        // activity started by an older build still decodes.
        /// The session's name as shown ("Meditation", "Running").
        public var workoutName: String?
        /// The start with every pause removed, so `Text(timerInterval:)` on the lock screen counts the
        /// ACTIVE time by itself, second by second, with no update needed.
        public var workoutClockStart: Date?
        /// While paused: the frozen active time in seconds. Nil while running.
        public var workoutPausedSeconds: Int?
        /// Effort so far, on the wearer's own scale, and as a 0–1 fill.
        public var workoutEffort: String?
        public var workoutEffortFraction: Double?
        /// True for a recovery session, which is shown by what it did to stress rather than by effort.
        public var workoutRecovery: Bool?
        /// Stress (0–3) over the session's first five minutes, and over the last five.
        public var stressStart: Double?
        public var stressNow: Double?

        public init(bpm: Int?, recovery: Int?, bonded: Bool, effort: Int? = nil) {
            self.bpm = bpm
            self.recovery = recovery
            self.bonded = bonded
            self.effort = effort
        }

        /// Whether this state describes a session in progress.
        public var inWorkout: Bool { workoutName != nil }
    }

    /// Static title shown for the session.
    public var title: String

    public init(title: String = "Live HR") {
        self.title = title
    }
}
#endif
