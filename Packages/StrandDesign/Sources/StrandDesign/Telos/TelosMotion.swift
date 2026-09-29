import SwiftUI

// MARK: - TelosMotion — the Telos 2.0 motion tokens (docs/DESIGN_V2.md §4.8, §7)
//
// THE RULE: motion must encode data or state. Allowed triggers are a value changing, data arriving,
// the wearer touching something, a live stream running, a sync running, or a transition the wearer
// caused. When nothing is happening, nothing moves.
//
// Organic feel (coordinator decision 8): data moves on springs WITHOUT bounce (`settle`, `flow`);
// only the wearer's own direct manipulation (drag, press release) may overshoot, gently (`release`).
//
// Every token has a Reduce Motion alternative (`animation(_:reduced:)`, `gated(_:reduced:)`). Loops
// additionally pose still in Low Power Mode and under "Reduce motion in NOOP" — the three signals are
// OR-ed by `NoopMotionState.poseStill(_:)`, and the only loop token here (`liveLoop`) takes that
// composed flag (or the `NoopMotionState` itself) so a call site cannot gate on Reduce Motion alone.
//
// | token     | curve                              | reduce motion          |
// |-----------|------------------------------------|------------------------|
// | press     | easeOut 0.12; scale 0.97, op 0.88  | opacity 0.88 only      |
// | select    | spring(0.28, 0.86)                 | instant                |
// | settle    | spring(0.45, 0.90)                 | instant                |
// | flow      | spring(0.80, 0.92)                 | instant (posed)        |
// | screen    | spring(0.46, 0.88)                 | fade 0.20              |
// | fade      | easeInOut 0.20                     | same                   |
// | countUp   | settle, ≤ 0.6 s                    | instant                |
// | beat      | easeOut 0.30                       | static dot             |
// | live      | easeInOut 2.0 loop (LIVE dot only) | static dot             |
// | breath    | 5.5 s period (guided breathing)    | exercise's static mode |
// | stagger   | 0.035 s per item, first 4 items    | none                   |
// | release   | spring(0.35, 0.72) — drag release  | instant                |

public enum TelosMotion {

    // MARK: Tokens

    /// Press feedback curve.
    public static let press = Animation.easeOut(duration: 0.12)
    /// Pressed scale (dropped under Reduce Motion).
    public static let pressScale: CGFloat = 0.97
    /// Pressed opacity (kept under Reduce Motion — it is the whole press cue there).
    public static let pressOpacity: Double = 0.88

    /// Segment / chip / toggle selection.
    public static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)
    /// Numeral change, arc / caret move, delta chips.
    public static let settle = Animation.spring(response: 0.45, dampingFraction: 0.90)
    /// A liquid level change (vessel / tube).
    public static let flow = Animation.spring(response: 0.80, dampingFraction: 0.92)
    /// Expand / collapse, in-sheet page swap.
    public static let screen = Animation.spring(response: 0.46, dampingFraction: 0.88)
    /// Insert / remove, content swap. Fades are allowed under Reduce Motion.
    public static let fade = Animation.easeInOut(duration: fadeDuration)
    public static let fadeDuration: Double = 0.20
    /// Numeral count on a NEW value (never on re-appear; an absent value never counts).
    public static let countUp = settle
    /// The longest a count-up may visibly run.
    public static let countUpMaxDuration: Double = 0.6
    /// HR dot pulse per received sample.
    public static let beat = Animation.easeOut(duration: 0.30)
    /// One half-cycle of the LIVE dot's loop. Use `liveLoop(…)`, never `.repeatForever` at a call site.
    public static let live = Animation.easeInOut(duration: livePeriod)
    public static let livePeriod: Double = 2.0
    /// Guided breathing period (breathing content only).
    public static let breathPeriod: Double = 5.5
    /// First-arrival stagger per item, applied to the first `staggerMaxItems` items only.
    public static let stagger: Double = 0.035
    public static let staggerMaxItems: Int = 4
    /// The wearer's own direct manipulation letting go (drag release, swipe-to-dismiss snap-back): a
    /// gentle overshoot is allowed here and ONLY here.
    public static let release = Animation.spring(response: 0.35, dampingFraction: 0.72)
    /// The longest any value-change drawing may run before the view must rest (§2.1).
    public static let settleBudget: Double = 1.2

    // MARK: Reduce Motion

    /// The named tokens, for table-driven gating.
    public enum Token: CaseIterable, Sendable {
        case press, select, settle, flow, screen, fade, countUp, beat, live, stagger, release
    }

    /// The token's curve, or its Reduce Motion alternative when `reduced` (nil = instant).
    public static func animation(_ token: Token, reduced: Bool) -> Animation? {
        switch token {
        case .press:   return press                       // the caller drops the scale, keeps opacity
        case .select:  return reduced ? nil : select
        case .settle:  return reduced ? nil : settle
        case .flow:    return reduced ? nil : flow
        case .screen:  return reduced ? fade : screen
        case .fade:    return fade
        case .countUp: return reduced ? nil : countUp
        case .beat:    return reduced ? nil : beat
        case .live:    return reduced ? nil : live
        case .stagger: return reduced ? nil : settle
        case .release: return reduced ? nil : release
        }
    }

    /// `animation`, or nil (instant) under Reduce Motion — the `NoopMotion.gated` shape.
    public static func gated(_ animation: Animation, reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }

    /// The first-arrival stagger delay for item `index`: 0.035 s steps for the first four items, and
    /// items after the fourth arrive with the fourth (so a long list never trickles in).
    public static func staggerDelay(index: Int) -> Double {
        let clamped = min(max(index, 0), staggerMaxItems - 1)
        return Double(clamped) * stagger
    }

    // MARK: The one loop

    /// The LIVE dot's loop — the only never-settling animation in the token set, allowed ONLY while a
    /// stream is actually live. Returns nil (no loop, static dot) when `poseStill` is set, where
    /// `poseStill` MUST be `NoopMotionState.shared.poseStill(reduceMotion)` (Reduce Motion ‖ Low
    /// Power ‖ "Reduce motion in NOOP"), not Reduce Motion alone.
    public static func liveLoop(poseStill: Bool) -> Animation? {
        poseStill ? nil : live.repeatForever(autoreverses: true)
    }

    /// `liveLoop(poseStill:)` reading the composed gate straight from `NoopMotionState`.
    public static func liveLoop(_ motion: NoopMotionState, reduceMotion: Bool) -> Animation? {
        liveLoop(poseStill: motion.poseStill(reduceMotion))
    }
}
