import SwiftUI

// MARK: - TelosFrameGate — when an instrument may run a frame clock (docs/DESIGN_V2.md §2.1 rule 1, §7)
//
// The ONE decision every INS frame loop makes (the life orb, the settling liquid tube, the particle
// field's callers): a per-frame clock runs only when ALL of these hold —
//
//   • the caller asked for motion at all (`requested`),
//   • the view is on screen (`visible` from onAppear / onDisappear — tab switches, pops),
//   • it has not scrolled fully out of its scroll view (`offscreen`, iOS 18 / macOS 15 / watchOS 11
//     through `telosOffscreen`; always false before, so older OSes fall back to the other gates),
//   • nothing covers it (`\.noopBackgroundCovered` — a sheet over the tab),
//   • the wearer has not asked for stillness (`NoopMotionState.poseStill(reduceMotion)` = Reduce
//     Motion ‖ Low Power ‖ "Reduce motion in NOOP"),
//   • and, for settle-then-rest clocks, the value is still settling (`withinActiveWindow`).
//
// Anything else is a STILL frame: the same deterministic picture, no clock, zero per-frame cost —
// Core Animation keeps the last rasterised layer. The decision is pure so the tests pin it.
//
// Rate: ≤ 30 fps (`minimumInterval`). The orb's breathing and rotation are slow (periods of seconds),
// so 30 fps is visually identical to 60 and halves the cost on the 60 Hz reference phone.

public enum TelosFrameGate {

    /// The cap for every decorative INS clock.
    public static let maxFramesPerSecond: Double = 30
    /// `TimelineView(.animation(minimumInterval:))` for that cap.
    public static let minimumInterval: Double = 1.0 / maxFramesPerSecond

    public enum Mode: Equatable, Sendable {
        /// Run the clock at ≤ 30 fps.
        case live
        /// Draw one still frame; no clock.
        case still
    }

    /// The gate. Pure.
    public static func mode(requested: Bool,
                            visible: Bool,
                            offscreen: Bool,
                            covered: Bool,
                            poseStill: Bool,
                            withinActiveWindow: Bool = true) -> Mode {
        guard requested, visible, !offscreen, !covered, !poseStill, withinActiveWindow else { return .still }
        return .live
    }

    /// A requested frame interval clamped to the cap (asking for more than 30 fps buys nothing here).
    /// Non-finite / non-positive requests fall back to the cap.
    public static func clampedInterval(_ requested: Double) -> Double {
        guard requested.isFinite, requested > 0 else { return minimumInterval }
        return max(requested, minimumInterval)
    }
}

// MARK: - Offscreen gate

public extension View {
    /// Reports `true` when this view has scrolled fully out of its enclosing scroll view and `false`
    /// when any of it is back, so a frame loop can pause while nobody can see it. iOS 18 / macOS 15 /
    /// watchOS 11+; a no-op before that and outside a scroll view (the callback never fires, so the
    /// caller's flag stays false and the other gates — appear, covered, poseStill — still apply).
    ///
    /// The package twin of the app's `liquidOffscreen` (which now forwards here), so the orb and the
    /// liquid primitives read the SAME signal.
    @ViewBuilder
    func telosOffscreen(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            self.onScrollVisibilityChange(threshold: 0.01) { visible in action(!visible) }
        } else {
            self
        }
    }

    /// Opens a settle window each time `value` changes: `active` turns true at once and false again
    /// `duration` seconds after the LAST change (a newer change extends the window; a stale timer never
    /// closes a newer window). Settle-then-rest clocks gate on it so a value change draws for ≤ 1.2 s
    /// (`TelosMotion.settleBudget`) and then the view rests with no clock.
    func telosSettleWindow<V: Equatable>(on value: V,
                                         duration: Double = TelosMotion.settleBudget,
                                         active: Binding<Bool>) -> some View {
        modifier(TelosSettleWindowModifier(value: value, duration: duration, active: active))
    }
}

private struct TelosSettleWindowModifier<V: Equatable>: ViewModifier {
    let value: V
    let duration: Double
    @Binding var active: Bool
    /// Bumped on every change; a timer only closes the window it opened.
    @State private var generation = 0

    func body(content: Content) -> some View {
        content.onChangeCompat(of: value) { _ in
            generation &+= 1
            let token = generation
            active = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration)) {
                if generation == token { active = false }
            }
        }
    }
}
