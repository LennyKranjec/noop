import SwiftUI

// MARK: - TelosOrb — the organic "life orb" (docs/DESIGN_V2.md VISUAL DIRECTION: Today / Home centrepiece)
//
// A glowing, slowly breathing 3-D-looking blob of dotted particles with thin orbit ellipses and small
// glowing dots travelling along them. It is an INSTRUMENT, not decoration — its form encodes the day:
//
// THE DATA MAPPING (`TelosOrbMapping.state(for:)`, pure and tested)
//
//   channel      input (scale)                         → drawn as
//   ───────────  ────────────────────────────────────  ───────────────────────────────────────────────
//   Level        today's Level vs the wearer's OWN      SIZE. delta = level / baseline − 1; ±25 % of the
//                typical Level (e.g. trailing median)   baseline spans size 0.88…1.12. A faint dashed
//                — both unbounded                       contour marks the baseline size, so "bigger or
//                                                       smaller than my usual" reads directly. Past
//                                                       +25 % the orb does NOT clip: each further 25 %
//                                                       adds a bright outer orbit (overflow, decision 9).
//   Charge       Charge / recovery, 0–100               BRIGHTNESS of the dots and the glow, 0.40…1.0.
//   Stress       daily stress, the shared 0–3 scale     TURBULENCE (lobe depth + surface ripple,
//                                                       0.12…1.0) and BREATH RATE (8 s calm → 4.5 s).
//
//   A missing input never invents a value: that channel rests at its CALM NEUTRAL (size 1, no
//   baseline contour; brightness 0.62; turbulence 0.12, 8 s breath). With ALL three missing the orb is
//   also DESATURATED (neutral grey-green instead of the tint), so "no data" never looks like a good day.
//   The orb is a qualitative read; the exact numbers (the unbounded Level, Charge, stress) are always
//   printed beside it — it never replaces a numeral, so it is hidden from VoiceOver.
//
// THE PICTURE
//   A deterministic seeded point cloud (Fibonacci sphere + seeded jitter; ~18 % interior points for
//   volume) on a sphere deformed by four low-frequency lobes and a soft ripple, rotated slowly (one turn
//   a minute) and tilted, shaded by a fake light from the upper left plus a rim light at the silhouette;
//   dot size and opacity by depth. Tints: green (Home), teal (Environment), violet (Mind & Focus / sleep),
//   amber (Metabolic Engine).
//
// COST (§2.1 rule 8 + the VISUAL DIRECTION performance block)
//   • ONE Canvas, rendered asynchronously; dots are bucketed into 10 paths (2 colours × 5 opacity steps)
//     → 10 fills per frame, not one per dot. No blur, no shadow, no material, no drawingGroup.
//   • The clock runs at ≤ 30 fps ONLY while `TelosFrameGate` says live: on screen (appear), not
//     scrolled away (`telosOffscreen`), not covered by a sheet (`noopBackgroundCovered`), and not posed
//     still (`NoopMotionState.poseStill` = Reduce Motion ‖ Low Power ‖ "Reduce motion in NOOP").
//     Otherwise one still frame (t = 0) that Core Animation keeps as a cached layer — zero per-frame cost.
//   • `clock: .burst(seconds:)` limits the clock to a window after appear / after a state change
//     (for screens held to the §2.1 "idle = 0 clocks" budget); `.still` never runs one.
//   • The point cloud and lobes are `static let` — built once per process, never per body evaluation.

// MARK: - Inputs and state

/// The day's inputs to the orb. Every field is optional; nil (or non-finite) means "not measured".
public struct TelosOrbInputs: Equatable, Sendable {
    /// Today's Level (unbounded; 100 = the wearer's own 95th percentile).
    public var level: Double?
    /// The wearer's own typical Level (e.g. a trailing median). nil while it is still forming.
    public var levelBaseline: Double?
    /// Charge / recovery, 0–100.
    public var charge: Double?
    /// Daily stress on the shared 0–3 scale.
    public var stress: Double?

    public init(level: Double? = nil, levelBaseline: Double? = nil, charge: Double? = nil, stress: Double? = nil) {
        self.level = level
        self.levelBaseline = levelBaseline
        self.charge = charge
        self.stress = stress
    }
}

/// What the orb draws. Build it with `TelosOrbMapping.state(for:)`.
public struct TelosOrbState: Equatable, Sendable {
    /// Radius multiplier (1 = the baseline / neutral size).
    public let size: Double
    /// 0…1 multiplier on dot and glow opacity.
    public let brightness: Double
    /// 0…1 deformation strength.
    public let turbulence: Double
    /// Seconds per breath.
    public let breathPeriod: Double
    /// How far above the drawn size range the Level runs, in range units (0 = within; 1.3 = 130 % of
    /// the range again). Drawn as extra outer orbits — never clipped away.
    public let overflow: Double
    /// Per-channel measurement flags.
    public let hasLevel: Bool
    public let hasCharge: Bool
    public let hasStress: Bool

    public init(size: Double, brightness: Double, turbulence: Double, breathPeriod: Double,
                overflow: Double, hasLevel: Bool, hasCharge: Bool, hasStress: Bool) {
        self.size = size
        self.brightness = brightness
        self.turbulence = turbulence
        self.breathPeriod = breathPeriod
        self.overflow = overflow
        self.hasLevel = hasLevel
        self.hasCharge = hasCharge
        self.hasStress = hasStress
    }

    /// How many of the three channels carry a real measurement.
    public var measuredCount: Int { (hasLevel ? 1 : 0) + (hasCharge ? 1 : 0) + (hasStress ? 1 : 0) }
    /// Nothing measured — the calm, desaturated orb.
    public var isNeutral: Bool { measuredCount == 0 }

    /// The calm neutral orb (no inputs).
    public static let neutral = TelosOrbMapping.state(for: TelosOrbInputs())
}

/// The pure input → picture mapping. Constants are public so the tests and the docs quote one source.
public enum TelosOrbMapping {
    /// ± this fraction of the wearer's own baseline spans the whole size range.
    public static let levelDeltaSpan: Double = 0.25
    /// Size at −span … +span.
    public static let sizeRange: ClosedRange<Double> = 0.88...1.12
    public static let neutralSize: Double = 1.0

    public static let brightnessRange: ClosedRange<Double> = 0.40...1.0
    public static let neutralBrightness: Double = 0.62

    public static let turbulenceRange: ClosedRange<Double> = 0.12...1.0
    /// Calm: the neutral turbulence is the bottom of the range.
    public static let neutralTurbulence: Double = 0.12

    /// Breath period, calm → most stressed.
    public static let calmBreathPeriod: Double = 8.0
    public static let stressedBreathPeriod: Double = 4.5

    /// The stress scale's top (the shared 0–3 scale is bounded by definition).
    public static let stressScaleTop: Double = 3.0

    public static func state(for inputs: TelosOrbInputs) -> TelosOrbState {
        // Level vs own baseline → size (+ overflow). Both must be real, and the baseline positive.
        var size = neutralSize
        var overflow = 0.0
        var hasLevel = false
        if let level = finite(inputs.level), let baseline = finite(inputs.levelBaseline), baseline > 0 {
            hasLevel = true
            let delta = level / baseline - 1
            let unit = min(max(delta / levelDeltaSpan, -1), 1)            // −1…1 across the drawn range
            let half = (sizeRange.upperBound - sizeRange.lowerBound) / 2
            size = neutralSize + unit * half
            overflow = max(0, delta - levelDeltaSpan) / levelDeltaSpan     // unbounded above
        }

        // Charge → brightness. The 0–100 score is bounded by definition.
        var brightness = neutralBrightness
        var hasCharge = false
        if let charge = finite(inputs.charge) {
            hasCharge = true
            let c = min(max(charge, 0), 100) / 100
            brightness = brightnessRange.lowerBound + c * (brightnessRange.upperBound - brightnessRange.lowerBound)
        }

        // Stress → turbulence + breath rate.
        var turbulence = neutralTurbulence
        var breath = calmBreathPeriod
        var hasStress = false
        if let stress = finite(inputs.stress) {
            hasStress = true
            let s = min(max(stress, 0), stressScaleTop) / stressScaleTop
            turbulence = turbulenceRange.lowerBound + s * (turbulenceRange.upperBound - turbulenceRange.lowerBound)
            breath = calmBreathPeriod + s * (stressedBreathPeriod - calmBreathPeriod)
        }

        return TelosOrbState(size: size, brightness: brightness, turbulence: turbulence, breathPeriod: breath,
                             overflow: overflow, hasLevel: hasLevel, hasCharge: hasCharge, hasStress: hasStress)
    }

    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}

// MARK: - Tint

/// The orb's colour family (second reference image).
public enum TelosOrbTint: Sendable, CaseIterable {
    /// Home / Nervous System — bioluminescent green with teal shadows.
    case green
    /// Environment — teal with green shadows.
    case teal
    /// Mind & Focus / sleep — violet with magenta shadows.
    case violet
    /// Metabolic Engine / fuel — orange with amber shadows.
    case amber

    var lit: Color {
        switch self {
        case .green:  return TelosColor.mint
        case .teal:   return TelosColor.teal
        case .violet: return TelosColor.violet
        case .amber:  return TelosColor.orange
        }
    }

    var shade: Color {
        switch self {
        case .green:  return TelosColor.teal
        case .teal:   return TelosColor.mint
        case .violet: return TelosColor.magenta
        case .amber:  return TelosColor.amber
        }
    }
}

// MARK: - Geometry (deterministic, pure)

/// One cloud point: a unit direction, its shell (1 = surface, < 1 = interior), and a size factor.
struct TelosOrbPoint: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let shell: Double
    let size: Double
    let isInterior: Bool
}

/// One low-frequency deformation lobe.
struct TelosOrbLobe: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let amplitude: Double
    let omega: Double
    let phase: Double
}

enum TelosOrbGeometry {
    /// The Home orb's cloud.
    static let heroCloud = cloud(count: 540, seed: 0x7E105_0B)
    /// The smaller tabs' cloud.
    static let compactCloud = cloud(count: 300, seed: 0x7E105_0C)
    /// The shared lobes (one organic shape family for every orb).
    static let lobes = makeLobes(count: 4, seed: 0x7E105_1B)
    /// Ambient dust around the hero / compact orb.
    static let heroDust = TelosParticleField.makeParticles(count: 36, seed: 0x7E105_D0, sizes: 0.6...1.6)
    static let compactDust = TelosParticleField.makeParticles(count: 14, seed: 0x7E105_D1, sizes: 0.6...1.4)

    /// A seeded point cloud on the unit sphere: a Fibonacci lattice (even coverage) with seeded
    /// jitter, ~18 % of points pulled inside for volume. Same seed → same cloud, on every launch.
    static func cloud(count: Int, seed: UInt64) -> [TelosOrbPoint] {
        let n = max(0, count)
        guard n > 0 else { return [] }
        var rng = TelosSeededRandom(seed: seed)
        let golden = Double.pi * (3 - 5.0.squareRoot())
        var out: [TelosOrbPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let yy = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let ring = max(0, 1 - yy * yy).squareRoot()
            let theta = golden * Double(i)
            var x = cos(theta) * ring + (rng.unit() - 0.5) * 0.08
            var y = yy + (rng.unit() - 0.5) * 0.08
            var z = sin(theta) * ring + (rng.unit() - 0.5) * 0.08
            let len = max((x * x + y * y + z * z).squareRoot(), 1e-9)
            x /= len; y /= len; z /= len
            let interior = rng.unit() < 0.18
            let shell = interior ? 0.45 + rng.unit() * 0.45 : 0.965 + rng.unit() * 0.035
            let size = 0.7 + rng.unit() * 0.6
            out.append(TelosOrbPoint(x: x, y: y, z: z, shell: shell, size: size, isInterior: interior))
        }
        return out
    }

    static func makeLobes(count: Int, seed: UInt64) -> [TelosOrbLobe] {
        var rng = TelosSeededRandom(seed: seed)
        return (0..<max(0, count)).map { _ in
            let u = rng.unit() * 2 - 1
            let phi = rng.unit() * 2 * Double.pi
            let r = max(0, 1 - u * u).squareRoot()
            return TelosOrbLobe(x: r * cos(phi), y: u, z: r * sin(phi),
                                amplitude: 0.16 + rng.unit() * 0.16,
                                omega: 0.25 + rng.unit() * 0.35,
                                phase: rng.unit() * 2 * Double.pi)
        }
    }

    /// The deformed radius along unit direction (x, y, z) at time `t`. `pulses` are the per-lobe pulse
    /// factors for this frame (computed once per frame, not per point). Calm orbs keep a gentle organic
    /// shape (35 % of the lobes); stress deepens the lobes and adds a surface ripple.
    static func radius(x: Double, y: Double, z: Double, lobes: [TelosOrbLobe], pulses: [Double],
                       turbulence: Double, breath: Double, time t: Double) -> Double {
        var bump = 0.0
        for i in lobes.indices {
            let l = lobes[i]
            let d = x * l.x + y * l.y + z * l.z
            if d > 0 { bump += l.amplitude * d * d * d * pulses[i] }
        }
        let ripple = 0.035 * sin(5.0 * x + 3.0 * z + t * 0.9) * sin(4.0 * y + 1.3 + t * 0.6)
        return 1 + bump * (0.35 + 0.65 * turbulence) + ripple * turbulence + breath
    }
}

// MARK: - The view

public struct TelosOrb: View {
    public enum Style: Sendable {
        /// The Home centrepiece: 540 points, two orbits with two travelling dots, ambient dust.
        case hero
        /// The other tabs' orb: 300 points, one orbit, one dot.
        case compact
    }

    /// When the frame clock may run (always further gated by `TelosFrameGate`).
    public enum Clock: Equatable, Sendable {
        /// Slow rotation + breathing while visible (the owner's direction for Home).
        case whileVisible
        /// Animate for `seconds` after appearing and after each state change, then rest.
        case burst(seconds: Double)
        /// Never animate (widgets, snapshots, lists).
        case still
    }

    private let state: TelosOrbState
    private let tint: TelosOrbTint
    private let style: Style
    private let clock: Clock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBackgroundCovered) private var covered
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var visible = false
    @State private var offscreen = false
    @State private var burstOpen = false
    @State private var appearCount = 0
    /// Live time counts from here, so a clock that resumes starts from the still pose (t = 0) instead
    /// of jumping to wherever wall-clock time would have put it.
    @State private var liveEpoch = Date()

    public init(state: TelosOrbState, tint: TelosOrbTint = .green, style: Style = .hero,
                clock: Clock = .whileVisible) {
        self.state = state
        self.tint = tint
        self.style = style
        self.clock = clock
    }

    public init(inputs: TelosOrbInputs, tint: TelosOrbTint = .green, style: Style = .hero,
                clock: Clock = .whileVisible) {
        self.init(state: TelosOrbMapping.state(for: inputs), tint: tint, style: style, clock: clock)
    }

    private var mode: TelosFrameGate.Mode {
        let requested: Bool
        let window: Bool
        switch clock {
        case .whileVisible:
            requested = true
            window = true
        case .burst:
            requested = true
            window = burstOpen
        case .still:
            requested = false
            window = false
        }
        return TelosFrameGate.mode(requested: requested, visible: visible, offscreen: offscreen,
                                   covered: covered, poseStill: motion.poseStill(reduceMotion),
                                   withinActiveWindow: window)
    }

    private var burstSeconds: Double {
        if case .burst(let seconds) = clock { return max(0, seconds) }
        return 0
    }

    public var body: some View {
        let live = mode == .live
        let state = self.state
        let style = self.style
        let lit = state.isNeutral ? TelosColor.textSecondary : tint.lit
        let shade = state.isNeutral ? TelosColor.textTertiary : tint.shade
        let epoch = liveEpoch
        TimelineView(.animation(minimumInterval: TelosFrameGate.minimumInterval, paused: !live)) { timeline in
            let t: Double = live ? max(0, timeline.date.timeIntervalSince(epoch)) : 0
            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                TelosOrbRenderer.draw(context: &context, size: size, time: t, state: state,
                                      lit: lit, shade: shade, style: style)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            visible = true
            appearCount &+= 1
        }
        .onDisappear { visible = false }
        .telosOffscreen { offscreen = $0 }
        .telosSettleWindow(on: BurstKey(state: state, appear: appearCount), duration: burstSeconds,
                           active: $burstOpen)
        .onChangeCompat(of: live) { isLive in
            if isLive { liveEpoch = Date() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A burst reopens on a state change AND on each appear.
    private struct BurstKey: Equatable {
        let state: TelosOrbState
        let appear: Int
    }
}

// MARK: - Renderer

enum TelosOrbRenderer {

    /// Fake light from the upper left, slightly in front (y up).
    private static let light: (x: Double, y: Double, z: Double) = {
        let v = (-0.45, 0.55, 0.70)
        let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / l, v.1 / l, v.2 / l)
    }()

    /// Opacity steps per colour bucket.
    static let levels = 5

    static func draw(context: inout GraphicsContext, size: CGSize, time t: Double, state: TelosOrbState,
                     lit: Color, shade: Color, style: TelosOrb.Style) {
        let dim = min(size.width, size.height)
        guard dim > 8 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let hero = style == .hero
        let cloud = hero ? TelosOrbGeometry.heroCloud : TelosOrbGeometry.compactCloud
        let lobes = TelosOrbGeometry.lobes
        let dust = hero ? TelosOrbGeometry.heroDust : TelosOrbGeometry.compactDust
        let base = Double(dim) * 0.24                      // pixel radius of the size-1 sphere
        let R = base * state.size
        let bright = state.brightness
        let dotScale = max(0.6, Double(dim) / 240)

        // Per-frame constants.
        let calmRate = 0.6 + 0.8 * state.turbulence
        let pulses = lobes.map { 0.85 + 0.15 * sin(t * $0.omega * calmRate + $0.phase) }
        let breath = t > 0 ? 0.03 * sin(2 * Double.pi * t / max(state.breathPeriod, 0.5)) : 0
        let yaw = 0.6 + t * 2 * Double.pi / 60
        let pitch = 0.35 + 0.05 * sin(t * 0.2)
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)

        // 1. Ambient dust (behind everything), one path.
        var dustPath = Path()
        for p in dust {
            let dx = CGFloat(sin(p.phase + t * p.speed)) * 2
            let dy = CGFloat(cos(p.phase * 1.3 + t * p.speed * 0.7)) * 2
            let d = CGFloat(p.size)
            dustPath.addEllipse(in: CGRect(x: CGFloat(p.x) * size.width + dx - d / 2,
                                           y: CGFloat(p.y) * size.height + dy - d / 2, width: d, height: d))
        }
        context.fill(dustPath, with: .color(lit.opacity(0.30 * bright)))

        // 2. The glow — one pre-composited radial gradient, no blur.
        let glowR = CGFloat(R * 1.9)
        context.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [lit.opacity(0.20 * bright),
                                                             lit.opacity(0.07 * bright), .clear]),
                                           center: c, startRadius: 0, endRadius: glowR))

        // 3. The baseline contour: where the orb sits on the wearer's usual day (Level present only).
        if state.hasLevel {
            let br = CGFloat(base * 1.08)
            context.stroke(Path(ellipseIn: CGRect(x: c.x - br, y: c.y - br, width: br * 2, height: br * 2)),
                           with: .color(lit.opacity(0.22)),
                           style: StrokeStyle(lineWidth: 0.6, dash: [1, 4]))
        }

        // 4. Orbits (behind the cloud) + the dots currently behind the orb.
        let orbits = orbitSpecs(hero: hero, dim: Double(dim))
        for o in orbits {
            context.stroke(o.path(center: c), with: .color(lit.opacity(0.10)), lineWidth: 2.2)
            context.stroke(o.path(center: c), with: .color(lit.opacity(0.42)), lineWidth: 0.7)
        }
        var dots: [(CGPoint, Bool)] = []
        for o in orbits.prefix(hero ? 2 : 1) { dots.append(o.dot(center: c, time: t)) }
        for (p, front) in dots where !front { drawOrbitDot(&context, at: p, color: lit, strength: 0.45) }

        // 5. The cloud, bucketed: [colour 0 = lit, 1 = shade][opacity step].
        var buckets = [Path](repeating: Path(), count: 2 * levels)
        let L = light
        for p in cloud {
            // Rotate the unit direction: yaw about Y, then pitch about X.
            let x1 = p.x * cy + p.z * sy
            let z1 = -p.x * sy + p.z * cy
            let y2 = p.y * cp - z1 * sp
            let z2 = p.y * sp + z1 * cp
            let r = TelosOrbGeometry.radius(x: p.x, y: p.y, z: p.z, lobes: lobes, pulses: pulses,
                                            turbulence: state.turbulence, breath: breath, time: t) * p.shell
            let px = Double(c.x) + x1 * r * R
            let py = Double(c.y) - y2 * r * R
            let front = (z2 + 1) / 2                         // 0 back … 1 front
            let lambert = max(0, x1 * L.x + y2 * L.y + z2 * L.z)
            let rim = p.isInterior ? 0 : pow(1 - max(0, z2), 2)
            var intensity = bright * (0.18 + 0.50 * lambert + 0.55 * rim) * (0.45 + 0.55 * front)
            if p.isInterior { intensity *= 0.45 }
            guard intensity > 0.04 else { continue }
            let step = min(levels - 1, Int(intensity * Double(levels)))
            let colour = lambert > 0.35 ? 0 : 1
            let d = CGFloat(max(0.6, (0.8 + 1.4 * front) * p.size * dotScale))
            let rect = CGRect(x: px - Double(d) / 2, y: py - Double(d) / 2, width: Double(d), height: Double(d))
            if d < 1.3 {
                buckets[colour * levels + step].addRect(rect)
            } else {
                buckets[colour * levels + step].addEllipse(in: rect)
            }
        }
        for colour in 0..<2 {
            let ink = colour == 0 ? lit : shade
            for step in 0..<levels {
                let path = buckets[colour * levels + step]
                if path.isEmpty { continue }
                context.fill(path, with: .color(ink.opacity((Double(step) + 0.5) / Double(levels))))
            }
        }

        // 6. Orbit dots in front of the orb.
        for (p, front) in dots where front { drawOrbitDot(&context, at: p, color: lit, strength: 1) }

        // 7. Overflow: each 25 % of baseline beyond the drawn size range adds a bright outer orbit.
        if state.overflow > 0 {
            let rings = min(3, Int(state.overflow.rounded(.up)))
            for k in 0..<rings {
                let o = OrbitSpec(rx: Double(dim) * 0.47, ry: Double(dim) * (0.08 + 0.035 * Double(k)),
                                  rotation: (40 + 55 * Double(k)) * Double.pi / 180, period: 0, phase: 0)
                context.stroke(o.path(center: c), with: .color(TelosColor.textPrimary.opacity(0.14)), lineWidth: 2.4)
                context.stroke(o.path(center: c), with: .color(lit.opacity(0.85)), lineWidth: 0.9)
            }
        }
    }

    // MARK: Orbits

    struct OrbitSpec {
        let rx: Double
        let ry: Double
        let rotation: Double
        let period: Double
        let phase: Double

        func path(center c: CGPoint) -> Path {
            Path(ellipseIn: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                .applying(CGAffineTransform(rotationAngle: CGFloat(rotation))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        }

        /// The travelling dot's position and whether it is in front of the orb (lower half of the
        /// tilted ellipse faces the viewer).
        func dot(center c: CGPoint, time t: Double) -> (CGPoint, Bool) {
            let a = phase + (period > 0 ? t * 2 * Double.pi / period : 0)
            let ex = rx * cos(a), ey = ry * sin(a)
            let x = ex * cos(rotation) - ey * sin(rotation)
            let y = ex * sin(rotation) + ey * cos(rotation)
            return (CGPoint(x: Double(c.x) + x, y: Double(c.y) + y), sin(a) > 0)
        }
    }

    static func orbitSpecs(hero: Bool, dim: Double) -> [OrbitSpec] {
        if hero {
            return [
                OrbitSpec(rx: dim * 0.46, ry: dim * 0.14, rotation: -16 * Double.pi / 180, period: 16, phase: 0.6),
                OrbitSpec(rx: dim * 0.40, ry: dim * 0.21, rotation: 28 * Double.pi / 180, period: 23, phase: 3.1),
            ]
        }
        return [OrbitSpec(rx: dim * 0.44, ry: dim * 0.13, rotation: -14 * Double.pi / 180, period: 18, phase: 0.9)]
    }

    private static func drawOrbitDot(_ context: inout GraphicsContext, at p: CGPoint, color: Color, strength: Double) {
        context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                     with: .color(color.opacity(0.28 * strength)))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)),
                     with: .color(color.opacity(strength)))
        context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                     with: .color(TelosColor.textPrimary.opacity(strength)))
    }
}

#if DEBUG
#Preview("TelosOrb — Home") {
    VStack(spacing: 24) {
        TelosOrb(inputs: TelosOrbInputs(level: 81, levelBaseline: 72, charge: 88, stress: 0.8))
            .frame(width: 220)
        HStack(spacing: 16) {
            TelosOrb(inputs: TelosOrbInputs(), style: .compact).frame(width: 110)
            TelosOrb(inputs: TelosOrbInputs(charge: 70, stress: 2.4), tint: .teal, style: .compact).frame(width: 110)
            TelosOrb(inputs: TelosOrbInputs(charge: 87), tint: .violet, style: .compact).frame(width: 110)
        }
        TelosOrb(inputs: TelosOrbInputs(level: 140, levelBaseline: 80, charge: 95), tint: .amber,
                 style: .compact, clock: .still)
            .frame(width: 110)
    }
    .padding(24)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
