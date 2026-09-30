import SwiftUI

// MARK: - TelosGlow — the cheap bioluminescence primitives (docs/DESIGN_V2.md "VISUAL DIRECTION")
//
// The look is shining light on a near-black ground — but the owner reports lag, so every primitive
// here is the CHEAP way to that look (binding performance rules):
//
//   • `TelosRadialGlow`        — a pre-composited radial gradient. No blur, no shadow.
//   • `.telosLuminousStroke`   — a crisp core stroke over ONE wider faint halo stroke. No blur.
//   • `.telosGlowingPill`      — the glowing capsule (window-advice pill, selected tab): tinted fill,
//                                gradient hairline and ONE small shadow on a small static element.
//   • `TelosParticleField`     — the dotted particle field, drawn in a single `Canvas` (one layer,
//                                rendered asynchronously), ≤ 30 fps ONLY while visible, and a still
//                                frame when paused: offscreen, behind a sheet (`noopBackgroundCovered`),
//                                under Reduce Motion / Low Power / "Reduce motion in NOOP"
//                                (`NoopMotionState.poseStill`), or when the caller passes
//                                `animated: false`. Positions are seeded (deterministic), so a still
//                                frame is the same frame every time.
//   • `TelosWordmark`          — "T E L O S" + "BIOLOGICAL OPTIMIZATION ENGINE".
//
// The INS package builds the organic blob and the thin luminous rings on top of these. Every flourish
// call site still names its cost (§2.1 rule 8).

// MARK: - Radial glow

/// A soft radial glow: `color` at `intensity` in the centre, fading to clear at `radius`. Place it
/// behind a luminous element (`.background(TelosRadialGlow(...))`). Static, one gradient fill.
public struct TelosRadialGlow: View {
    private let color: Color
    private let intensity: Double
    private let radius: CGFloat

    public init(color: Color = TelosColor.glow, intensity: Double = 0.35, radius: CGFloat = 120) {
        self.color = color
        self.intensity = min(max(intensity, 0), 1)
        self.radius = max(radius, 1)
    }

    public var body: some View {
        RadialGradient(
            colors: [color.opacity(intensity), color.opacity(intensity * 0.35), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: radius
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Luminous stroke

public extension Shape {
    /// A luminous line: the crisp core stroke drawn over ONE wider, faint halo stroke of the same colour
    /// (no blur, no shadow) — the thin glowing rings and orbit lines of the reference.
    func telosLuminousStroke(_ color: Color,
                             lineWidth: CGFloat = TelosStroke.data,
                             haloOpacity: Double = 0.22) -> some View {
        ZStack {
            self.stroke(color.opacity(haloOpacity),
                        style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round, lineJoin: .round))
            self.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Glowing pill

private struct TelosGlowingPill: ViewModifier {
    let color: Color
    let isActive: Bool
    let padded: Bool

    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        let edge = LinearGradient(
            colors: [color.opacity(isActive ? 0.9 : 0.35), color.opacity(isActive ? 0.25 : 0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        let pill = content
            .padding(.horizontal, padded ? TelosSpace.l : 0)
            .padding(.vertical, padded ? TelosSpace.s : 0)
            .frame(minHeight: TelosSpace.hitTarget)
            .background(shape.fill(color.opacity(isActive ? TelosOpacity.fill : TelosOpacity.whisper)))
            .overlay(shape.strokeBorder(edge, lineWidth: TelosStroke.line))
        return Group {
            if isActive {
                // Cost: ONE shadow on one small static capsule; never on a card, never in a list.
                pill.shadow(color: color.opacity(0.35), radius: 8, x: 0, y: 0)
            } else {
                pill
            }
        }
    }
}

public extension View {
    /// The glowing pill (the window-advice pill, the selected tab): a capsule tinted with `color`, a
    /// gradient hairline bright at the top-leading edge and — when `isActive` — one soft glow. 44 pt
    /// minimum height. `padded: false` when the caller already sizes the content.
    func telosGlowingPill(_ color: Color = TelosColor.mint, isActive: Bool = true, padded: Bool = true) -> some View {
        modifier(TelosGlowingPill(color: color, isActive: isActive, padded: padded))
    }
}

// MARK: - Particle field

/// One seeded particle (unit coordinates).
struct TelosParticle {
    let x: Double
    let y: Double
    let size: Double
    let alpha: Double
    let phase: Double
    let speed: Double
}

/// A tiny deterministic generator (SplitMix64), so particle positions are the same on every launch.
struct TelosSeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// A uniform double in 0..<1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}

/// A dotted particle field drawn into ONE `Canvas`. Deterministic positions; a slow drift of a few
/// points while visible and animated, at ≤ 30 fps; otherwise a still frame.
///
/// Cost (§2.1 rule 8): one Canvas layer, `count` (≤ 400) tiny ellipses per frame; the clock runs ONLY
/// while the view is on screen, not covered by a sheet, `animated` is true and
/// `NoopMotionState.poseStill` is false. Everything else shows the same still frame.
public struct TelosParticleField: View {
    private let color: Color
    private let particles: [TelosParticle]
    private let animated: Bool
    private let drift: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBackgroundCovered) private var covered
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var visible = false

    /// - Parameters:
    ///   - color: the dot colour (defaults to the bioluminescent green).
    ///   - count: number of dots (clamped to 0…400).
    ///   - seed: positions are a pure function of this.
    ///   - sizes: dot diameter range in points.
    ///   - drift: how far (pt) a dot wanders while animating.
    ///   - animated: false = always the still frame.
    public init(color: Color = TelosColor.mint,
                count: Int = 140,
                seed: UInt64 = 0x7E105,
                sizes: ClosedRange<Double> = 0.8...2.2,
                drift: CGFloat = 3,
                animated: Bool = true) {
        self.color = color
        self.animated = animated
        self.drift = drift
        self.particles = TelosParticleField.makeParticles(count: count, seed: seed, sizes: sizes)
    }

    static func makeParticles(count: Int, seed: UInt64, sizes: ClosedRange<Double>) -> [TelosParticle] {
        var rng = TelosSeededRandom(seed: seed)
        let n = min(max(count, 0), 400)
        var out: [TelosParticle] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let x = rng.unit()
            let y = rng.unit()
            let size = sizes.lowerBound + rng.unit() * (sizes.upperBound - sizes.lowerBound)
            let alpha = 0.18 + rng.unit() * 0.62
            let phase = rng.unit() * 2 * Double.pi
            let speed = 0.15 + rng.unit() * 0.35
            out.append(TelosParticle(x: x, y: y, size: size, alpha: alpha, phase: phase, speed: speed))
        }
        return out
    }

    private var paused: Bool {
        !animated || !visible || covered || motion.poseStill(reduceMotion)
    }

    public var body: some View {
        let isPaused = paused
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
            let t: Double = isPaused ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas(rendersAsynchronously: true) { context, size in
                TelosParticleField.draw(particles, context: context, size: size, time: t,
                                        color: color, drift: drift)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func draw(_ particles: [TelosParticle], context: GraphicsContext, size: CGSize,
                     time: Double, color: Color, drift: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        for p in particles {
            let angle = p.phase + time * p.speed
            let dx = CGFloat(cos(angle)) * drift
            let dy = CGFloat(sin(angle * 0.7)) * drift
            let d = CGFloat(p.size)
            let rect = CGRect(x: CGFloat(p.x) * size.width + dx - d / 2,
                              y: CGFloat(p.y) * size.height + dy - d / 2,
                              width: d, height: d)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(p.alpha)))
        }
    }
}

// MARK: - Wordmark

/// "T E L O S" with the "BIOLOGICAL OPTIMIZATION ENGINE" subline — the header of Today and the brand
/// mark elsewhere. The brand text is not translated (it is a logo); VoiceOver reads "Telos".
public struct TelosWordmark: View {
    private let showsSubline: Bool
    private let color: Color

    public init(showsSubline: Bool = true, color: Color = TelosColor.textPrimary) {
        self.showsSubline = showsSubline
        self.color = color
    }

    public var body: some View {
        VStack(spacing: TelosSpace.xs) {
            Text(verbatim: "TELOS")
                .font(TelosType.wordmark)
                .tracking(TelosType.Tracking.wordmark)
                .foregroundStyle(color)
            if showsSubline {
                Text(verbatim: "BIOLOGICAL OPTIMIZATION ENGINE")
                    .font(TelosType.wordmarkSubline)
                    .tracking(TelosType.Tracking.wordmarkSubline)
                    .foregroundStyle(TelosColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Telos"))
        .accessibilityAddTraits(.isHeader)
    }
}
