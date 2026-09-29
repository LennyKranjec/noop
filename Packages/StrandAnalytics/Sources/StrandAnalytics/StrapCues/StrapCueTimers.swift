import Foundation

// StrapCueTimers.swift — the pure timing rules behind the Strap cues the wearer STARTS (focus block,
// silent meditation timer, breathing pacer) and the two evening cues (wind-down, screens off).
//
// iOS can suspend NOOP, and a run-loop timer armed for an absolute instant then fires late — when the app is
// next woken, which may be much later. So every timed cue goes through one due-check with a grace window
// (the same idea as `WakeBuzzAlarm.shouldRing`): late by less than the grace it still fires; later than that
// it is logged as missed instead of buzzing a wrist long after the moment has passed.
//
// The breathing pacer is built around HD's honest breathing outcome (`BreathSessionOutcome`): a 90 s QUIET
// reading before and after with NO cues (normal breathing), and the paced part between them. The phase
// boundaries are emitted so the session recorder can read exactly the windows it expects.
//
// Pure, no clocks. Swift-only in 2.0.

public enum StrapCueTimerState: Equatable, Sendable {
    /// Still running; this many seconds left.
    case running(remaining: Int)
    /// Due now (on time or within the grace window).
    case fire
    /// Passed while NOOP could not act, by more than the grace window.
    case missed(lateBy: Int)
}

/// One phase boundary of a breathing-pacer session, for the session recorder.
public enum StrapCueBreathPhase: String, Equatable, Sendable, Codable {
    /// The quiet "before" reading starts (no cues, normal breathing).
    case preQuietStart
    /// The paced part starts (first inhale cue).
    case pacedStart
    /// The paced part ends; the quiet "after" reading starts (no cues).
    case pacedEnd
    /// The quiet "after" reading ends; the session is complete (time's-up cue).
    case postQuietEnd
}

/// A planned pacer session: every cue and every phase boundary as millisecond offsets from the start.
public struct StrapCueBreathPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let offsetMs: Int
        /// The cue to play at this offset, if any.
        public let cue: StrapCueKind?
        /// The phase boundary at this offset, if any.
        public let phase: StrapCueBreathPhase?
    }
    public let steps: [Step]
    public let totalMs: Int
    public let paceBpm: Double
}

public enum StrapCueTimers {

    /// Late by up to this and a timed cue still fires.
    public static let graceSeconds = 15 * 60

    public static func state(endsAt: Int, nowSec: Int, graceSeconds: Int = graceSeconds) -> StrapCueTimerState {
        if nowSec < endsAt { return .running(remaining: endsAt - nowSec) }
        let late = nowSec - endsAt
        return late <= graceSeconds ? .fire : .missed(lateBy: late)
    }

    /// The whole pacer session: quiet "before" (`BreathSessionOutcome.quietSeconds`), `pacedMinutes` of
    /// inhale/exhale cues at `paceBpm` (the shipped 40:60 inhale:exhale split), quiet "after", then the
    /// time's-up cue. Uses `BreathPacer.schedule`, so the phase timing is the Breathe screen's own.
    public static func breathPlan(pacedMinutes: Int, paceBpm: Double) -> StrapCueBreathPlan {
        let quietMs = BreathSessionOutcome.quietSeconds * 1000
        let cycles = max(1, Int((Double(max(1, pacedMinutes)) * paceBpm).rounded()))
        let paced = BreathPacer.schedule(bpm: paceBpm, cycles: cycles)
        let pacedMs = BreathPacer.sessionDurationMs(bpm: paceBpm, cycles: cycles)
        var steps: [StrapCueBreathPlan.Step] = [.init(offsetMs: 0, cue: nil, phase: .preQuietStart)]
        for (i, c) in paced.enumerated() {
            let kind: StrapCueKind? = c.phase == .inhale ? .breathInhale : (c.phase == .exhale ? .breathExhale : nil)
            steps.append(.init(offsetMs: quietMs + c.offsetMs, cue: kind, phase: i == 0 ? .pacedStart : nil))
        }
        steps.append(.init(offsetMs: quietMs + pacedMs, cue: nil, phase: .pacedEnd))
        let total = quietMs + pacedMs + quietMs
        steps.append(.init(offsetMs: total, cue: .breathingDone, phase: .postQuietEnd))
        return StrapCueBreathPlan(steps: steps, totalMs: total, paceBpm: min(max(paceBpm, BreathPacer.minBpm), BreathPacer.maxBpm))
    }

    /// Fire-once key for an evening cue of the night that ends on `wakeDayKey`.
    public static func eveningKey(_ kind: StrapCueKind, wakeDayKey: String) -> String {
        "\(kind.rawValue):\(wakeDayKey)"
    }

    /// Minutes before lights-out the "screens off" cue sits. A CONVENTION (common sleep-hygiene advice puts
    /// screens away 30–60 min before bed), not a measured optimum — the evidence on evening screens is mixed,
    /// so the screen copy does not overclaim.
    public static let screensOffLeadMin = 30

    /// For an evening cue of `plan`: (minute-of-day, day shift relative to the WAKE day).
    public static func eveningSlot(_ kind: StrapCueKind, plan: SleepSchedulePlan) -> (minuteOfDay: Int, dayShift: Int)? {
        switch kind {
        case .windDown:
            return (plan.windDownStartMin, plan.windDownDayShift)
        case .screensOff:
            return (SleepClock.wrap(plan.bedtimeMin - screensOffLeadMin),
                    plan.dayShift(leadBeforeAnchorMin: plan.bedtimeLeadMin + screensOffLeadMin))
        default:
            return nil
        }
    }
}
