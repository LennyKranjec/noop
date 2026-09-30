import SwiftUI
import StrandAnalytics
import StrandDesign

// HydrationTileView.swift — the water tile, on Today.
//
// SwiftUI twin of the Android `HydrationTile`. A tile that FILLS: the day's water is the level of the
// liquid in it, the figure sits top right, and the two buttons add or take back a glass.
//
// THE TILE IS THE GAUGE. A ring or a bar would have said the same thing in less space, and said it in
// the language every other card on Today already speaks. A vessel that fills is the one instrument here
// that reads without being read — you see the level before you see the number.
//
// THE TAP MOVES THE WATER IMMEDIATELY. The store round trip takes a frame or two, and a tile that sat
// still until it returned read as a button that had not worked, so the shown figure is an optimistic
// overlay cleared whenever a fresh read lands.
//
// LOGGING A GLASS IS THE OPT-IN. Hydration tracking ships off; without turning it on here, the rest of
// the app (the Your-cards tile, the goal ring) would keep reading zero for water this tile had already
// banked. Only ever turned ON, and only by a tap.

/// How tall the vessel is. Enough for the fill to read as a level rather than a stripe.
private let waterTileHeight: CGFloat = 132

/// One glass. The same 250 ml the Android tile adds and removes.
private let glassML = 250

struct HydrationTileView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Bumped by the shell so the tile re-reads after something else changed the day.
    let refreshKey: Int
    let onOpen: () -> Void

    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false

    @State private var storedML: Double = 0
    /// The optimistic overlay — see the note at the top. Reset whenever a store read lands.
    @State private var shownML: Double = 0
    @State private var goalML: Int = 0

    private var fraction: Double {
        guard goalML > 0 else { return 0 }
        return min(max(shownML / Double(goalML), 0), 1)
    }

    var body: some View {
        // NOT A BUTTON WRAPPING THE WHOLE TILE. It was, and the two glass buttons sat inside that
        // button's LABEL — where iOS gives the taps to the outer button. Tapping + or − opened the
        // hydration screen instead of logging anything, which is also why there was no haptic: the
        // code that plays it never ran. The tile's own tap is a gesture on its own clear layer now,
        // and the two controls are real buttons above it.
        //
        // THE TAP LAYER IS ITS OWN VIEW rather than a gesture on the water, because `WaterFill` ends
        // in `.allowsHitTesting(false)` — it is a Canvas redrawn thirty times a second and must never
        // be in the hit-test path. A tap gesture attached to it was therefore never delivered, which
        // is why the tile opened nothing at all.
        //
        // NOTHING IN HERE STATES A WIDTH. A ZStack takes the size of its widest child, and a child
        // with an intrinsic width (the figures) against children that are flexible is exactly how a
        // tile ends up sized by its text and then offset inside the column it does not fill.
        ZStack {
            WaterFill(fraction: fraction)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onOpen() }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text("\(formatML(shownML)) / \(formatML(Double(goalML)))")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                // The buttons take the place the reference tile gives its caption.
                HStack(spacing: 12) {
                    WaterButton(icon: "minus", label: "Remove a glass") { change(-glassML) }
                    WaterButton(icon: "plus", label: "Add a glass") { change(glassML) }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: waterTileHeight)
        // V2 faux glass (fill + luminous hairline + top glow). No material, no shadow.
        .background(NoopPanelSurface(tint: StrandPalette.metricCyan, cornerRadius: NoopMetrics.cardRadius))
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .task(id: "\(repo.refreshSeq)-\(repo.hydrationSeq)-\(refreshKey)") { await load() }
    }

    private func load() async {
        goalML = repo.hydrationGoalML(profileSex: profile.sex)
        storedML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        shownML = storedML
    }

    private func change(_ deltaML: Int) {
        // THE TWO DIRECTIONS FEEL DIFFERENT. Adding a glass is a commitment the day keeps, so it lands
        // as a confirm; taking one back is an edit, so it is the lighter select. A single cue for both
        // would make the undo feel like a second drink.
        //
        // AND NOTHING AT THE FLOOR. Pressing − on an empty day changes no figure, and a haptic for a
        // tap that did nothing is the app claiming to have done something.
        let wouldChange = deltaML > 0 || shownML > 0
        if wouldChange { SystemHaptics.play(deltaML > 0 ? .confirm : .select) }
        guard wouldChange else { return }
        shownML = max(shownML + Double(deltaML), 0)
        Task {
            if deltaML > 0 {
                // Logging a glass IS the opt-in — see the note at the top.
                if !hydrationEnabled { hydrationEnabled = true }
                await repo.logHydration(amountMl: deltaML)
            } else {
                await repo.removeHydration(amountMl: -deltaML)
            }
            await load()
            // The glass that finishes a water quest should close it now, not on the next refresh.
            await QuestAutoComplete.run(repo: repo)
        }
    }

    /// ml as the tile shows it: litres past a litre, plain millilitres below.
    ///
    /// TWO decimals. A glass is 250 ml, so at one decimal every second glass moves the figure by 0.2 or
    /// by 0.3 and two different day totals print the same number — the tile looked stuck after a tap.
    private func formatML(_ ml: Double) -> String {
        ml >= 1000 ? String(format: "%.2f L", ml / 1000) : "\(Int(ml)) ml"
    }
}

private struct WaterButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceBase.opacity(0.55), in: Circle())
                // THE DISC STAYS 34pt; THE REACH IS 44. These are the two most-tapped controls on
                // Today and they sit 12pt apart over a tile that opens a screen when missed — so a
                // near-miss used to log nothing and navigate instead. The tile has the height to
                // spare, and the drawn circle is unchanged.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// The liquid.
///
/// CALM AND PHYSICAL (owner, 2.0: a professional look, nothing playful). The surface moves the way water
/// in a box does: its first two SLOSHING MODES — a standing wave that tilts the surface about the middle
/// (cos πx/L) and a smaller one with a node at each quarter (cos 2πx/L) — each ringing down under damping,
/// while the level itself springs to its new height with one soft overshoot. No glint, no travelling
/// sparkle, no idle loop. Layers are drawn back to front, each deeper, fainter and a beat behind the one in
/// front, which is what the eye reads as depth.
///
/// WHEN IT MOVES. For `motionDuration` after the tile appears (including coming back to Home, or back from a
/// pushed screen) and after the amount changes, at ≤ 30 fps; then it rests on a posed still frame that is
/// exactly where the motion ended — the rest surface is the same static ripple the motion decays onto, so
/// the hand-off has no snap. Nothing runs while the tile is scrolled away, covered, or the app is asked to
/// hold still (Reduce Motion, Low Power, quiet motion): a change then simply lands, on a flat waterline.
///
/// WHY IT DID NOT MOVE BEFORE. The clock ran only inside the shared 1.2 s settle window, which opens on a
/// value CHANGE and never on appear — so arriving on Home showed a still tile — and inside it the level
/// itself jumped while only a 4 pt wobble moved, which read as a flicker rather than water.
private struct WaterFill: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBackgroundCovered) private var covered
    @ObservedObject private var motion = NoopMotionState.shared

    /// Scrolled fully out of view (iOS 18 / macOS 15+; always false before) — the frame loop stands down.
    @State private var offscreen = false
    /// The motion in progress; nil = at rest (no clock).
    @State private var settle: WaterSettle?
    /// Bumped per settle, so only the newest settle's timer ends the motion.
    @State private var settleGeneration = 0
    /// The level the last settle was heading for — where the water visibly is when nothing is moving.
    @State private var restingLevel: Double?

    /// How long a settle draws. Both damped terms are under a tenth of a point by then.
    private static let motionDuration: Double = 2.6

    private var still: Bool { motion.poseStill(reduceMotion) }
    private var clamped: Double { fraction.isFinite ? min(max(fraction, 0), 1) : 0 }
    /// Cost: one Canvas, ≤ 30 fps, only while a settle runs; paused by poseStill / covered / offscreen.
    private var live: Bool { settle != nil && !still && !covered && !offscreen }

    /// The water's own blue. Deeper than the palette's cyan and with a lift at the surface, because a
    /// flat fill reads as a coloured rectangle — the gradient is what makes it read as a body of liquid
    /// with a top to it.
    private static let deep = Color(.sRGB, red: 0.06, green: 0.36, blue: 0.62, opacity: 1)
    private static let bright = Color(.sRGB, red: 0.30, green: 0.71, blue: 0.96, opacity: 1)

    var body: some View {
        let isLive = live
        let current = settle
        let level = clamped
        let ripple = !still
        TimelineView(.animation(minimumInterval: TelosFrameGate.minimumInterval, paused: !isLive)) { timeline in
            let elapsed: Double? = isLive ? current.map { timeline.date.timeIntervalSince($0.start) } : nil
            Canvas { context, size in
                WaterFill.draw(context, size, settle: isLive ? current : nil, elapsed: elapsed,
                               restLevel: level, ripple: ripple)
            }
        }
        .allowsHitTesting(false)
        .liquidOffscreen { offscreen = $0 }
        // Settles in on arrival: the tile is seen to hold water, not a painted level.
        .onAppear { begin(from: restingLevel ?? clamped, to: clamped, slosh: 0.035) }
        .onDisappear {
            settle = nil
            restingLevel = clamped
        }
        .onChangeCompat(of: clamped) { next in
            // From where the water visibly is — mid-settle, that is the settle's own level.
            let from = settle.map { $0.state(at: Date().timeIntervalSince($0.start)).level }
                ?? restingLevel ?? next
            begin(from: from, to: next, slosh: 0.03 + min(0.05, abs(next - from) * 0.3))
        }
        // Ends the motion. `.task(id:)` cancels the previous timer when a newer settle starts.
        .task(id: settleGeneration) {
            guard settle != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.motionDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            settle = nil
        }
    }

    private func begin(from: Double, to: Double, slosh: Double) {
        restingLevel = to
        guard !still else {
            settle = nil
            return
        }
        settle = WaterSettle(start: Date(), from: from, to: to, slosh: slosh)
        settleGeneration &+= 1
    }

    private static func draw(_ context: GraphicsContext, _ size: CGSize, settle: WaterSettle?, elapsed: Double?,
                             restLevel: Double, ripple: Bool) {
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }

        // THE MEASURE LINES, behind the water and across the whole tile. Dashed rather than solid: a solid
        // rule at a quarter of the tile reads as a target, and there is no hydration target drawn here —
        // these are a scale to judge the level against.
        for share in [0.25, 0.5, 0.75] {
            var rule = Path()
            let y = h * (1 - share)
            rule.move(to: CGPoint(x: 0, y: y))
            rule.addLine(to: CGPoint(x: w, y: y))
            context.stroke(rule, with: .color(StrandPalette.hairlineStrong),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }

        // The rest surface: a fixed, barely-there ripple so still water reads as water, not a ruler line.
        // Flat when the app is asked to hold still.
        let restAmp = ripple ? h * 0.007 : 0

        func sheet(depth: Double, lag: Double, gain: Double, opacity: Double) {
            let s: WaterSettle.Frame
            if let settle, let elapsed {
                s = settle.state(at: max(0, elapsed - lag))
            } else {
                s = WaterSettle.Frame(level: restLevel, mode1: 0, mode2: 0)
            }
            let level = min(max(s.level, 0), 1)
            // An empty tile stays empty: the slosh fades out as the water runs out.
            let fill = min(1, level * 6)
            let a1 = s.mode1 * gain * fill * h
            let a2 = s.mode2 * gain * fill * h
            let surfaceY = h * (1 - level) + depth
            var path = Path()
            path.move(to: CGPoint(x: 0, y: h))
            let steps = 40
            var crest = h
            for i in 0...steps {
                let u = Double(i) / Double(steps)
                let x = w * u
                let y = surfaceY
                    - a1 * cos(.pi * u)
                    - a2 * cos(2 * .pi * u)
                    + restAmp * (sin(2 * .pi * u + 0.9 + depth * 0.4) + 0.5 * sin(2 * .pi * u * 2.3 + 2.1))
                crest = Swift.min(crest, y)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.closeSubpath()
            // Lit at the surface, dark at the bottom — the gradient runs from the highest point this sheet
            // reaches to the floor of the tile, so the lighter band stays ON the water as the level rises.
            context.fill(path, with: .linearGradient(
                Gradient(colors: [bright.opacity(opacity * 1.15), deep.opacity(opacity)]),
                startPoint: CGPoint(x: 0, y: crest),
                endPoint: CGPoint(x: 0, y: h)))
        }

        // Back to front: deeper, fainter and a beat behind.
        sheet(depth: 6, lag: 0.12, gain: 0.6, opacity: 0.38)
        sheet(depth: 3, lag: 0.06, gain: 0.8, opacity: 0.52)
        sheet(depth: 0, lag: 0, gain: 1.0, opacity: 0.72)
    }
}

/// One settle of the water tile: a level spring plus the two sloshing modes, all damped. Pure, so the drawn
/// frame is a function of the elapsed time alone.
private struct WaterSettle {
    let start: Date
    let from: Double
    let to: Double
    /// The first mode's starting amplitude, as a share of the tile height.
    let slosh: Double

    struct Frame {
        let level: Double
        /// Mode amplitudes, as shares of the tile height (signed — they swing through zero).
        let mode1: Double
        let mode2: Double
    }

    func state(at e: Double) -> Frame {
        // The level: an underdamped spring — one soft overshoot (≈ 5 % of the step), gone within ~1.5 s.
        let level = to + (from - to) * exp(-2.8 * e) * cos(3.0 * e)
        // The fundamental slosh (period ≈ 1.1 s) and its first harmonic, the harmonic dying faster.
        let mode1 = slosh * exp(-1.6 * e) * cos(5.6 * e)
        let mode2 = slosh * 0.35 * exp(-2.4 * e) * cos(9.4 * e + 0.8)
        return Frame(level: level, mode1: mode1, mode2: mode2)
    }
}
