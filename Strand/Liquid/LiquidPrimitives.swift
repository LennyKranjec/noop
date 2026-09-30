//  LiquidPrimitives.swift
//  NOOP · Liquid design language → Telos 2.0 instruments (INS)
//
//  The renderers + SwiftUI views for the signature elements: the circular vessel gauge, the horizontal
//  tube, and the live heart-rate thread. Colours come from StrandDesign tokens at the call site.
//
//  TELOS 2.0 (INS) — same initialisers, new look and a new motion contract:
//  • LiquidVessel is the thin LUMINOUS RING of the reference (it renders `TelosRing`): track in the
//    metric hue, halo + core arc, luminous tip. It no longer runs a frame loop at all — the old vessel
//    drove a 60 fps TimelineView while its renderer ignored the simulation (only `level` was read), which
//    is the spec finding this fixes. The arc now animates only when the value CHANGES (`TelosMotion`),
//    posed under Reduce Motion / Low Power; a tap gives the haptic plus a one-shot glow (≤ 0.6 s).
//  • LiquidTube keeps its liquid physics but only inside a SETTLE WINDOW: after a value change it
//    sloshes into the new level for ≤ 1.2 s (`telosSettleWindow`) at ≤ 30 fps, then rests on a still
//    frame. CoreMotion tilt is acquired only while it settles. Idle cost: zero.
//  • LiquidThread is redrawn per sample (when `bpm` changes) — no clock, no travelling glint, no
//    endpoint loop. A luminous line (halo + core) with a glowing end dot.

import SwiftUI
import StrandDesign   // NoopMotionState, TelosRing, TelosFrameGate, telosSettleWindow, telosOffscreen

// MARK: - Renderers (pure GraphicsContext drawing)

enum LiquidRender {

    /// A horizontal luminous capsule filled to `frac` (0…1). `slosh` shifts the liquid edge with the
    /// tilt, `phase` / `energy` bulge its front while settling; all three are 0 for the still frame.
    /// `frac == 0` draws the bare track (a zero reading is not a sliver of fill).
    static func tube(_ base: GraphicsContext, _ size: CGSize, frac: Double, tint: Color,
                     slosh: Double = 0, phase: Double = 0, energy: Double = 0,
                     showsHighlight: Bool = true, usesCleanFill: Bool = false) {
        let w = size.width, h = size.height, r = h / 2
        guard w > 1, h > 1 else { return }
        let outline = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerRadius: r)
        var ctx = base
        ctx.fill(outline, with: .color(tint.opacity(TelosOpacity.fill)))
        ctx.stroke(outline, with: .color(tint.opacity(0.26)), lineWidth: NoopMetrics.hairlineWidth)

        let f = max(0, min(1, frac))
        guard f > 0.001 else { return }
        var clip = ctx
        clip.clip(to: outline)
        let shift = -slosh * h * 1.3
        let edge = max(min(h, w), min(w, f * w + shift))
        let bulge = r * 0.6 + sin(phase * 2) * energy * h * 0.3 - 0.06 * h
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: edge - r * 0.3, y: 0))
        p.addQuadCurve(to: CGPoint(x: edge - r * 0.3, y: h), control: CGPoint(x: edge + bulge, y: h / 2))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.closeSubpath()
        // Luminous fill: the hue deepening toward the edge the value has reached.
        clip.fill(p, with: .linearGradient(
            Gradient(colors: [tint.opacity(usesCleanFill ? 0.65 : 0.5), tint]),
            startPoint: CGPoint(x: 0, y: h / 2),
            endPoint: CGPoint(x: max(edge, 1), y: h / 2)
        ))
        if showsHighlight && !usesCleanFill {
            clip.fill(Path(CGRect(x: 2, y: 1.2, width: max(0, edge - r * 0.6), height: 1)),
                      with: .color(.white.opacity(0.16)))
        }
        // The luminous head at the value (a faint wide dot + a bright core; no blur).
        if h >= 6 {
            let hx = edge - r * 0.3
            clip.fill(Path(ellipseIn: CGRect(x: hx - h * 0.8, y: h / 2 - h * 0.8, width: h * 1.6, height: h * 1.6)),
                      with: .color(tint.opacity(0.35)))
            clip.fill(Path(ellipseIn: CGRect(x: hx - h * 0.18, y: h / 2 - h * 0.18, width: h * 0.36, height: h * 0.36)),
                      with: .color(.white.opacity(0.85)))
        }
    }

    /// The heart-rate curve as a luminous line: one wide faint halo stroke under the crisp core, and a
    /// glowing dot on the latest sample. Smoothing uses midpoint quadratics, which stay inside each
    /// sample's neighbours — the line never passes beyond the real readings.
    /// - Parameter segments: per-value line identity from `hrGapSegments`, or nil for a series known to be
    ///   contiguous. Values whose ids differ are stroked as SEPARATE subpaths, so a stretch the strap never
    ///   recorded reads as a break instead of a straight climb across it (#2082).
    static func thread(_ base: GraphicsContext, _ size: CGSize, values: [Double], tint: Color,
                       segments: [String]? = nil) {
        guard values.count >= 2 else { return }
        let w = size.width, h = size.height, pad: Double = 10
        var mn = Double.greatestFiniteMagnitude, mx = -Double.greatestFiniteMagnitude
        for v in values { mn = min(mn, v); mx = max(mx, v) }
        let span = max(10, mx - mn)
        let n = values.count
        func px(_ i: Int) -> Double { pad + Double(i) * (w - 2 * pad) / Double(n - 1) }
        func py(_ v: Double) -> Double { h - pad - (v - mn) / span * (h - 2 * pad) }
        func appendRun(_ p: inout Path, _ lo: Int, _ hi: Int) {
            // A lone bucket between two gaps is real data, and it has to draw as something: give it a hair
            // of width so the round cap draws a dot (a bare `move` strokes nothing).
            guard hi > lo else {
                let x = px(lo), y = py(values[lo])
                p.move(to: CGPoint(x: x - 0.6, y: y))
                p.addLine(to: CGPoint(x: x + 0.6, y: y))
                return
            }
            p.move(to: CGPoint(x: px(lo), y: py(values[lo])))
            for i in (lo + 1)..<hi {
                let xc = (px(i) + px(i + 1)) / 2, yc = (py(values[i]) + py(values[i + 1])) / 2
                p.addQuadCurve(to: CGPoint(x: xc, y: yc), control: CGPoint(x: px(i), y: py(values[i])))
            }
            p.addLine(to: CGPoint(x: px(hi), y: py(values[hi])))
        }
        var runs: [ClosedRange<Int>] = [0...(n - 1)]
        if let segs = segments, segs.count == n { runs = hrGapRuns(segments: segs) }
        var line = Path()
        for r in runs { appendRun(&line, r.lowerBound, r.upperBound) }

        var ctx = base
        // One crisp line, no halo (decision 19: professional, no glow).
        ctx.stroke(line, with: .color(tint.opacity(0.95)),
                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        // The latest sample: a flat dot (static — it moves because the data moved).
        let ex = px(n - 1), ey = py(values[n - 1])
        ctx.fill(Path(ellipseIn: CGRect(x: ex - 3, y: ey - 3, width: 6, height: 6)), with: .color(tint))
    }
}

// MARK: - Views

/// Applies the splash tap either as a normal tap (consuming it) or as a simultaneous gesture (sharing
/// it with whatever wraps the view).
///
/// A plain `onTapGesture` inside a `NavigationLink` swallows the tap, so the link never pushes. That is
/// why the hero rings could splash but not navigate. `simultaneousGesture` lets both run, which is the
/// behaviour a tappable gauge wants; standalone vessels keep the consuming tap so nothing else changes.
private struct LiquidSplashTap: ViewModifier {
    let passesThrough: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if passesThrough {
            content.simultaneousGesture(TapGesture().onEnded { action() })
        } else {
            content.onTapGesture { action() }
        }
    }
}

/// A circular score gauge — the Telos luminous ring. `value` is 0...1 (nil = no data: a dashed bare
/// track, never a zero arc). Tap → haptic + a one-shot glow.
///
/// `animated: false` makes a value change jump instead of settling (the small gauges in rows). No
/// variant runs a frame clock: the arc is a shape that animates only while a value change settles.
struct LiquidVessel: View {
    let value: Double?
    let tint: Color
    var animated: Bool = true
    /// When the vessel sits inside a NavigationLink or Button, the tap must not CONSUME the tap or the
    /// wrapping control never fires. Opt in and the tap runs as a simultaneous gesture instead (#1995).
    var tapPassesThrough: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var taps = 0
    @State private var flash = false

    init(value: Double?, tint: Color, animated: Bool = true, tapPassesThrough: Bool = false) {
        self.value = value
        self.tint = tint
        self.animated = animated
        self.tapPassesThrough = tapPassesThrough
    }

    /// The drawn fraction: the vessel's contract is 0…1 (callers divide by their scale). Unbounded
    /// values (the Level) must use `TelosRing` directly, which draws overflow laps.
    private var fraction: Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, min(1, value))
    }

    var body: some View {
        GeometryReader { geo in
            let d = max(1, min(geo.size.width, geo.size.height))
            ZStack {
                TelosRing(value: fraction, scale: 1, color: tint, diameter: d,
                          showsValue: false, animatesChanges: animated)
                // Tap response: a brief, faint hairline acknowledgement — no glow (decision 19).
                Circle()
                    .stroke(TelosColor.textTertiary.opacity(flash ? 0.35 : 0), lineWidth: 1)
                    .padding(d * 0.02)
                    .allowsHitTesting(false)
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .contentShape(Circle())
        .modifier(LiquidSplashTap(passesThrough: tapPassesThrough) { tapped() })
        .liquidTapHaptic(trigger: taps)   // light tap feedback (guarded so the primitives compile on macOS 13)
    }

    private func tapped() {
        taps &+= 1
        guard !motion.poseStill(reduceMotion) else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { flash = true }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.6)) { flash = false }
        }
    }
}

/// A horizontal luminous tube filled to `frac` (0...1).
///
/// Still by default: it draws ONE posed frame (Core Animation caches it). When `frac` changes and the
/// tube is `animated`, on screen, not covered and not posed still, the liquid sloshes into its new level
/// for ≤ 1.2 s at ≤ 30 fps (tilt acquired only then) and rests again.
struct LiquidTube: View {
    let frac: Double
    let tint: Color
    var height: CGFloat = 14
    var animated: Bool = true
    var showsHighlight: Bool = true
    var usesCleanFill: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBackgroundCovered) private var covered
    @ObservedObject private var motion = NoopMotionState.shared
    /// Scrolled fully out of view (iOS 18 / macOS 15+; always false before).
    @State private var offscreen = false
    /// True for ≤ 1.2 s after `frac` changes (`telosSettleWindow`).
    @State private var settling = false
    /// The level last drawn, so a settle starts from where the liquid visibly was.
    @State private var posedFrac: Double? = nil
    @State private var sim = LiquidSim(target: 0)

    private var clamped: Double { frac.isFinite ? max(0, min(1, frac)) : 0 }

    private var isLive: Bool {
        TelosFrameGate.mode(requested: animated, visible: true, offscreen: offscreen, covered: covered,
                            poseStill: motion.poseStill(reduceMotion), withinActiveWindow: settling) == .live
    }

    var body: some View {
        Group {
            if isLive { liveTube } else { staticTube }
        }
        .frame(height: height)
        // Only a tube that can MOVE needs to know it scrolled away. A still tube (`animated: false` — every
        // Key-Metrics tile and vitals row on Today) paid for a scroll-visibility observer anyway, and each
        // edge crossing wrote `offscreen` and redrew its Canvas mid-scroll for nothing.
        .liquidOffscreen(enabled: animated) { offscreen = $0 }
        .onAppear {
            posedFrac = clamped
            sim.level = clamped      // a first change settles from the drawn level, never from empty
            sim.target = clamped
        }
        .onChangeCompat(of: clamped) { next in
            // Start the settle from the level on screen (mid-settle, the sim's own level already is),
            // then chase the new one.
            if !settling { sim.level = posedFrac ?? next }
            sim.target = next
            posedFrac = next
        }
        .telosSettleWindow(on: clamped, active: $settling)
    }

    /// Cost: one Canvas + one LiquidSim step per frame at ≤ 30 fps, ONLY during the ≤ 1.2 s settle window.
    private var liveTube: some View {
        TimelineView(.animation(minimumInterval: TelosFrameGate.minimumInterval, paused: !isLive)) { tl in
            let now = liquidSeconds(tl.date)
            Canvas { context, size in
                sim.step(now: now, tilt: LiquidMotion.shared.tilt, target: clamped)
                LiquidRender.tube(context, size, frac: sim.level, tint: tint, slosh: sim.a,
                                  phase: sim.p1, energy: sim.energy,
                                  showsHighlight: showsHighlight, usesCleanFill: usesCleanFill)
            }
        }
        .onAppear { LiquidMotion.shared.acquire() }
        .onDisappear { LiquidMotion.shared.release() }
    }

    /// The posed still frame at the value — no clock, no sim, no motion sensor.
    private var staticTube: some View {
        let f = clamped
        return Canvas { context, size in
            LiquidRender.tube(context, size, frac: f, tint: tint,
                              showsHighlight: showsHighlight, usesCleanFill: usesCleanFill)
        }
    }
}

/// The live heart-rate thread. `bpm` is the recent series (any length ≥ 2).
///
/// Redrawn per sample: the view re-renders when `bpm` changes (≈ 1 Hz while streaming) and otherwise
/// shows a still Canvas. No clock, no glint, no endpoint loop. `animated` is kept for source
/// compatibility and no longer changes anything.
struct LiquidThread: View {
    let bpm: [Double]
    /// Per-value line identity from `hrGapSegments`, or nil for a series known to be contiguous (#2082).
    var segments: [String]? = nil
    var tint: Color = Color(.sRGB, red: 1, green: 107/255, blue: 129/255, opacity: 1)
    var height: CGFloat = 96
    var animated: Bool = true

    var body: some View {
        Canvas { context, size in
            LiquidRender.thread(context, size, values: bpm, tint: tint, segments: segments)
        }
        .frame(height: height)
    }
}

// MARK: - Shared liquid components (cross-platform: used by Today AND the other liquid screens on iOS + mac)

extension View {
    /// Reports `true` when this view has scrolled fully out of its enclosing scroll view and `false` when
    /// any of it is back, so a frame loop can pause while nobody can see it. Forwards to the package's
    /// `telosOffscreen` so the liquid layer and the Telos instruments read ONE signal (iOS 18 / macOS 15+;
    /// a no-op before that and outside a scroll view).
    func liquidOffscreen(_ action: @escaping (Bool) -> Void) -> some View {
        telosOffscreen(action)
    }

    /// `liquidOffscreen` only where `enabled` — pass a value that is FIXED for the view's life (a `let`
    /// input), since it selects between two branches.
    @ViewBuilder
    func liquidOffscreen(enabled: Bool, _ action: @escaping (Bool) -> Void) -> some View {
        if enabled {
            telosOffscreen(action)
        } else {
            self
        }
    }

    /// A light selection/impact haptic, available only where `sensoryFeedback` is (iOS 17 / macOS 14);
    /// a no-op below that so the liquid primitives still compile on the macOS 13 deployment target.
    @ViewBuilder func liquidTapHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .light), trigger: trigger)
        } else {
            self
        }
    }

    /// A selection tick (e.g. the WHOOP-style day change), guarded so it compiles on macOS 13.
    @ViewBuilder func liquidSelectionHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.selection, trigger: trigger)
        } else {
            self
        }
    }

    /// A firmer medium impact (e.g. the pull-to-refresh release), guarded for the macOS 13 target.
    @ViewBuilder func liquidMediumHaptic(trigger: some Equatable) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.sensoryFeedback(.impact(weight: .medium), trigger: trigger)
        } else {
            self
        }
    }
}

/// The "this card was pressed" response for any tappable liquid card — the Telos `press` token:
/// scale 0.97 + opacity 0.88 over 0.12 s; under Reduce Motion the opacity alone. Cheap (a transform).
struct LiquidPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LiquidPressBody(configuration: configuration)
    }
}

private struct LiquidPressBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? TelosMotion.pressScale : 1)
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .animation(TelosMotion.press, value: pressed)
    }
}

/// A number that animates to its value: SwiftUI interpolates `animatableData`, so the shown integer rolls
/// smoothly frame-by-frame whenever `value` changes inside a `withAnimation` block.
struct CountUpNumber: View, Animatable {
    var value: Double
    var font: Font
    /// Decimal places to render. 0 (default) keeps the whole-number scores (Charge/Rest/100-scale Effort)
    /// byte-identical; the WHOOP 0–21 Effort scale passes 1 so the hero matches the app-wide one-decimal
    /// `effortDisplay` convention instead of rounding 12.6 → "13" (#45).
    var decimals: Int = 0
    /// Rendered ahead of the number and never animated, for a value that is bounded rather than
    /// measured: Fitness Age arrives clamped, so a reading at the edge of the scale shows "≤20" while
    /// the count-up still runs (#2173). Empty by default, which leaves every existing caller identical.
    var prefix: String = ""
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(prefix + (decimals > 0 ? String(format: "%.\(decimals)f", value) : "\(Int(value.rounded()))"))
            .font(font).monospacedDigit()
    }
}

// MARK: - LiquidScoreGauge — Home hero score instrument (shared)

/// The score gauge used on Today (`HeroScoreCell`): the luminous ring (`LiquidVessel`) with a light
/// centre numeral that counts to a NEW value (never on appear; instant under Reduce Motion / Low Power).
struct LiquidScoreGauge: View {
    /// Matches `HeroScoreCell.vesselDiameter` — the Home hero trio size.
    private static let homeHeroDiameter: CGFloat = 96

    let score: Double?
    let tint: Color
    let diameter: CGFloat
    let animated: Bool
    /// The scale `score` is expressed on (100 for Charge/Rest, 21 for WHOOP Effort, etc.).
    var maxValue: Double = 100
    var decimals: Int = 0
    /// Optional caption under the number (nil = Home hero: number only).
    var captionText: String? = nil
    var numberColor: Color = StrandPalette.textPrimary
    var captionColor: Color = StrandPalette.textTertiary
    /// Forwarded to `LiquidVessel` so a gauge inside a link still reacts AND still navigates (#1995).
    var tapPassesThrough: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var shown: Double = 0

    private var frac: Double? { score.map { max(0, min(1, $0 / maxValue)) } }
    private var centerFont: Font { TelosType.numeralFont(size: diameter * 26 / Self.homeHeroDiameter, weight: .light) }
    private var captionFont: Font { TelosType.numeralFont(size: diameter * 0.085, weight: .medium) }

    var body: some View {
        ZStack {
            LiquidVessel(value: frac, tint: tint, animated: animated,
                         tapPassesThrough: tapPassesThrough)
                .frame(width: diameter, height: diameter)
            VStack(spacing: captionText == nil ? 0 : 1) {
                Group {
                    if score != nil {
                        CountUpNumber(value: shown, font: centerFont, decimals: decimals)
                    } else {
                        Text(verbatim: TelosType.absent).font(centerFont)
                    }
                }
                if let captionText {
                    Text(captionText)
                        .font(captionFont)
                        .foregroundStyle(captionColor)
                }
            }
            .foregroundStyle(score == nil ? TelosColor.textTertiary : numberColor)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .onAppear { shown = score ?? 0 }
        .onChangeCompat(of: score) { rollTo($0) }
    }

    private func rollTo(_ v: Double?) {
        guard let v else { shown = 0; return }
        if !animated || motion.poseStill(reduceMotion) {
            shown = v
        } else {
            withAnimation(TelosMotion.countUp) { shown = v }
        }
    }
}
