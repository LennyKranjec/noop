import SwiftUI

// MARK: - TelosGlow — the retired glow primitives, now clinical and flat (docs/DESIGN_V2.md decision 19)
//
// Decision 19 (owner, 2026-09-30): "Remove the greenish or yellowish glimmer … professional, like a
// biological optimization system … not some childish gameplay." No glimmer, shimmer, sparkle, halo or
// neon anywhere; colour is for data. The type and modifier NAMES below are kept only so the many call
// sites stay source-compatible — what they draw is now restrained:
//
//   • `TelosRadialGlow`        — a NO-OP (a clear, layout-neutral fill). No colour cast of any kind.
//   • `.telosLuminousStroke`   — ONE crisp stroke. The wider halo stroke is gone.
//   • `.telosGlowingPill`      — a FLAT selected pill: a subtle neutral fill + a 1 pt hairline in the
//                                caller's colour. No gradient edge, no shadow.
//   • `TelosParticleField`     — a STATIC, very faint neutral grey-teal dot texture (≤ 4 % opacity) for
//                                background depth only. No drift, no twinkle, no clock; the caller's
//                                colour is ignored so no hue ever glimmers.
//   • `TelosWordmark`          — "T E L O S" + "BIOLOGICAL OPTIMIZATION ENGINE".
//
// Cost (§2.1 rule 8): shapes and one static Canvas only — nothing here animates.

// MARK: - Radial glow

/// RETIRED (decision 19): formerly a coloured radial glow behind a luminous element. It now draws
/// nothing — a clear, hit-test-transparent fill that takes the same (greedy) space the gradient did, so
/// every existing `.background(TelosRadialGlow(...))` / `ZStack` call site keeps its layout. The
/// parameters are accepted and ignored.
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
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Luminous stroke

public extension Shape {
    /// A crisp thin line in `color` (decision 19: the former wider halo stroke is removed). The name
    /// and the `haloOpacity` parameter are kept for source compatibility; `haloOpacity` is ignored.
    func telosLuminousStroke(_ color: Color,
                             lineWidth: CGFloat = TelosStroke.data,
                             haloOpacity: Double = 0.22) -> some View {
        self.stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Glowing pill

private struct TelosGlowingPill: ViewModifier {
    let color: Color
    let isActive: Bool
    let padded: Bool

    func body(content: Content) -> some View {
        let shape = Capsule(style: .continuous)
        // Flat (decision 19): a subtle NEUTRAL fill; the caller's colour appears only as the 1 pt
        // hairline of the selected state. No gradient edge, no shadow, no tinted wash.
        return content
            .padding(.horizontal, padded ? TelosSpace.l : 0)
            .padding(.vertical, padded ? TelosSpace.s : 0)
            .frame(minHeight: TelosSpace.hitTarget)
            .background(shape.fill(isActive ? TelosColor.glassRaised : TelosColor.glassFill))
            .overlay(shape.strokeBorder(isActive ? color.opacity(TelosOpacity.border) : TelosColor.line,
                                        lineWidth: TelosStroke.line))
    }
}

public extension View {
    /// The selected pill (the window-advice pill, the selected tab) — FLAT since decision 19: a subtle
    /// neutral fill and a 1 pt hairline (in `color` when `isActive`, the neutral line otherwise). No glow,
    /// no shadow. 44 pt minimum height. `padded: false` when the caller already sizes the content. The
    /// legacy name is kept for source compatibility.
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

/// A STATIC, very faint dot texture drawn into ONE `Canvas` — background depth only (decision 19).
/// Deterministic positions, no drift, no twinkle, no clock. Every dot is the neutral grey-teal
/// `dotColor` at ≤ `maxDotOpacity` (4 %); the caller's `color` is ignored so no hue ever glimmers.
///
/// Cost (§2.1 rule 8): one Canvas layer, `count` (≤ 400) tiny ellipses, drawn once per layout.
public struct TelosParticleField: View {
    /// The one dot colour: a neutral grey-teal (the tertiary ink), never an accent or a glow.
    public static let dotColor = TelosColor.textTertiary
    /// The brightest any dot may be drawn (seeded alphas are scaled into 0…this).
    public static let maxDotOpacity: Double = 0.04

    private let particles: [TelosParticle]

    /// - Parameters:
    ///   - color: IGNORED since decision 19 (kept for source compatibility).
    ///   - count: number of dots (clamped to 0…400).
    ///   - seed: positions are a pure function of this.
    ///   - sizes: dot diameter range in points.
    ///   - drift: IGNORED (the texture is static).
    ///   - animated: IGNORED (the texture is static).
    public init(color: Color = TelosColor.mint,
                count: Int = 140,
                seed: UInt64 = 0x7E105,
                sizes: ClosedRange<Double> = 0.8...2.2,
                drift: CGFloat = 3,
                animated: Bool = true) {
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

    public var body: some View {
        let dots = particles
        return Canvas(rendersAsynchronously: true) { context, size in
            TelosParticleField.draw(dots, context: context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The opacity a dot with seeded `alpha` (0.18…0.80) is drawn at: scaled into 0…`maxDotOpacity`.
    static func dotOpacity(_ alpha: Double) -> Double {
        guard alpha.isFinite else { return 0 }
        return min(max(alpha / 0.8, 0), 1) * maxDotOpacity
    }

    static func draw(_ particles: [TelosParticle], context: GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        for p in particles {
            let d = CGFloat(p.size)
            let rect = CGRect(x: CGFloat(p.x) * size.width - d / 2,
                              y: CGFloat(p.y) * size.height - d / 2,
                              width: d, height: d)
            context.fill(Path(ellipseIn: rect), with: .color(dotColor.opacity(dotOpacity(p.alpha))))
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
