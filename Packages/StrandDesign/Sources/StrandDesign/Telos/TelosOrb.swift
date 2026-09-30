import SwiftUI

// MARK: - TelosOrb — the organic "life orb" (docs/DESIGN_V2.md VISUAL DIRECTION: Today / Home centrepiece)
//
// A glowing, slowly breathing 3-D-looking blob of dotted particles with thin orbit ellipses and small
// glowing dots travelling along them. It is an INSTRUMENT, not decoration (owner direction): every
// visible property is bound to a real number through ONE pure mapping, `TelosOrbAppearance.from(_:)`.
//
// THE DATA MAPPING (pure, unit-tested — TelosOrbTests)
//
//   input (TelosOrbInputs)            → appearance                        rule
//   ────────────────────────────────  ─────────────────────────────────  ─────────────────────────────────
//   level (unbounded, 100 = own P95)  growth = log2(1 + level/100)       strictly increasing, NO maximum.
//                                     size   0.72 → 1.12 over 0…100,      keeps growing slowly past 100
//                                            then +0.06 per growth unit   (never clamped);
//                                     density 55 % → 100 % of the cloud   past the reference range each
//                                     outerShells = growth − 1            growth unit adds a particle shell.
//   partShares (sleep/heart/lungs/    the cloud's COLOUR COMPOSITION:     shares normalised; each part
//   muscle/focus → share of level)    each part colours its share of the  paints a wedge of the blob in
//                                     points (levelPartTint hues)         its identity hue.
//   stress (0–3)                      turbulence 0.12 → 1.0               calm = smooth, stressed = lumpy
//                                                                         + surface ripple.
//   heartRateBpm (resting / rolling)  pulse period = 6 × 60 / bpm s       breathes with the heart, slowed
//                                                                         6× (60 bpm → a 6 s pulse).
//   charge (0–100)                    glow + dot brightness 0.40 → 1.0
//   effortRatio (effort / target,     orbit-dot speed 0.4 + 0.8 × ratio   unbounded (a 2× effort day
//   unbounded)                                                            spins them at 2×).
//   confidence                        assembly: solid 1 · building 0.8 ·  provisional = sparser, dimmer,
//                                     calibrating 0.35…0.8 (n of m)       dots still drifting in.
//
//   ABSENT INPUTS NEVER INVENT A VALUE: a missing channel rests at its calm neutral (size 0.92, density
//   0.8, turbulence 0.12, an 8 s pulse, brightness 0.55, orbit speed 0.6, single tint colour). With
//   EVERY input missing the orb is the neutral dim still orb: desaturated grey-green, brightness 0.42,
//   and NO clock at all. The exact numbers are always printed beside the orb, so it is hidden from
//   VoiceOver (it never replaces a numeral).
//
// THE PICTURE
//   A deterministic seeded point cloud (Fibonacci sphere + seeded jitter; ~18 % interior points for
//   volume) on a sphere deformed by four low-frequency lobes and a soft ripple, rotated slowly (one turn
//   a minute) and tilted, shaded by a fake light from the upper left plus a rim light at the silhouette;
//   dot size and opacity by depth. Tints for the other tabs: green, teal, violet, amber.
//
// MOTION
//   • Value changes (size, brightness, turbulence, density) animate with `TelosMotion.flow` through an
//     `Animatable` layer — only when the value changes; instant under Reduce Motion.
//   • The ambient clock (rotation, breathing, orbit dots) runs at ≤ 30 fps ONLY while `TelosFrameGate`
//     says live: on screen, not scrolled away (`telosOffscreen`), not under a sheet
//     (`noopBackgroundCovered`), not posed still (`NoopMotionState.poseStill` = Reduce Motion ‖ Low
//     Power ‖ "Reduce motion in NOOP"), and not the neutral orb. Otherwise ONE still frame (t = 0).
//   • `clock: .burst(seconds:)` confines the clock to a window after appear / after a data change (for
//     screens held to the §2.1 "idle = 0 clocks" budget); `.still` never runs one.
//
// COST (§2.1 rule 8): ONE Canvas, rendered asynchronously; dots are bucketed by colour × 4 opacity
// steps (≤ 20 fills per frame, not one per dot). No blur, no shadow, no material, no drawingGroup.
// The point cloud, lobes and dust are `static let` — built once per process.

// MARK: - Inputs

/// The five Level parts, in `levelPartTint` order (§4.1).
public enum TelosOrbPart: String, CaseIterable, Sendable {
    case sleep, heart, lungs, muscle, focus

    /// The part's identity hue (`levelPartTint`: sleep→rest, heart, lungs, muscle, focus).
    public var color: Color {
        switch self {
        case .sleep:  return TelosColor.rest
        case .heart:  return TelosColor.heart
        case .lungs:  return TelosColor.lungs
        case .muscle: return TelosColor.muscle
        case .focus:  return TelosColor.focus
        }
    }
}

/// The day's numbers the orb draws. Every field is optional; nil / non-finite means "not measured".
public struct TelosOrbInputs: Equatable, Sendable {
    /// Today's Level — unbounded (100 = the wearer's own 95th percentile, not a maximum).
    public var level: Double?
    /// Each Level part's share of the level (points or fractions — normalised here). Missing or
    /// non-positive parts are simply not painted; empty = the single tint.
    public var partShares: [TelosOrbPart: Double]
    /// Daily stress on the shared 0–3 scale.
    public var stress: Double?
    /// Heart rate in bpm. Pass a SLOW signal (resting HR, or a rolling average) — the pulse phase
    /// restarts when it changes, so a raw 1 Hz stream would make the breath stutter.
    public var heartRateBpm: Double?
    /// Charge / recovery, 0–100.
    public var charge: Double?
    /// Today's effort divided by today's target (1 = on target). Unbounded.
    public var effortRatio: Double?
    /// How settled the Level is.
    public var confidence: TelosConfidence

    public init(level: Double? = nil,
                partShares: [TelosOrbPart: Double] = [:],
                stress: Double? = nil,
                heartRateBpm: Double? = nil,
                charge: Double? = nil,
                effortRatio: Double? = nil,
                confidence: TelosConfidence = .solid) {
        self.level = level
        self.partShares = partShares
        self.stress = stress
        self.heartRateBpm = heartRateBpm
        self.charge = charge
        self.effortRatio = effortRatio
        self.confidence = confidence
    }
}

// MARK: - Appearance (the pure mapping)

/// What the orb draws. Build it with `TelosOrbAppearance.from(_:)`.
public struct TelosOrbAppearance: Equatable, Sendable {
    /// log2(1 + level / 100); nil when the Level is absent. Strictly increasing, unbounded.
    public let growth: Double?
    /// Radius multiplier of the drawn blob (1 ≈ the Home reference size).
    public let size: Double
    /// Growth beyond the reference range (0 within it). Each whole unit draws one more particle shell.
    public let outerShells: Double
    /// Fraction of the point cloud drawn, 0…1 (Level × confidence).
    public let density: Double
    /// Normalised part weights (sum 1). Empty = the single tint.
    public let partWeights: [TelosOrbPart: Double]
    /// 0.12…1 deformation strength.
    public let turbulence: Double
    /// Seconds per pulse.
    public let pulsePeriod: Double
    /// Dot + glow opacity multiplier.
    public let brightness: Double
    /// Orbit-dot angular speed multiplier.
    public let orbitSpeed: Double
    /// 1 = assembled (solid). < 1 = provisional: sparser, dimmer, dots still drifting in.
    public let assembly: Double
    /// Which channels carry a real measurement.
    public let hasLevel: Bool
    public let hasStress: Bool
    public let hasHeartRate: Bool
    public let hasCharge: Bool
    public let hasEffort: Bool

    /// Nothing measured: the neutral, dim, desaturated still orb.
    public var isNeutral: Bool {
        !hasLevel && partWeights.isEmpty && !hasStress && !hasHeartRate && !hasCharge && !hasEffort
    }

    // Constants (quoted by the header table and the tests).
    public static let referenceLevel: Double = 100
    public static let sizeAtZero: Double = 0.72
    public static let sizeAtReference: Double = 1.12
    /// Size added per growth unit past the reference (slow, never capped).
    public static let sizeBeyondSlope: Double = 0.06
    public static let neutralSize: Double = 0.92
    public static let densityAtZero: Double = 0.55
    public static let neutralDensity: Double = 0.8
    public static let turbulenceRange: ClosedRange<Double> = 0.12...1.0
    public static let stressScaleTop: Double = 3
    /// The heart's period is slowed this many times for the visual pulse.
    public static let pulseSlowdown: Double = 6
    public static let neutralPulsePeriod: Double = 8
    public static let brightnessRange: ClosedRange<Double> = 0.40...1.0
    public static let neutralBrightness: Double = 0.55
    /// The all-absent orb is dimmer still.
    public static let emptyBrightness: Double = 0.42
    public static let neutralOrbitSpeed: Double = 0.6

    /// The Level growth curve: log2(1 + level/100). 0 → 0, 100 → 1, 300 → 2, 700 → 3 … no maximum.
    public static func growth(level: Double) -> Double {
        log2(1 + max(0, level) / referenceLevel)
    }

    /// Drawn size for a growth value: linear 0.72 → 1.12 up to the reference, then +0.06 per unit.
    public static func size(growth g: Double) -> Double {
        g <= 1 ? sizeAtZero + (sizeAtReference - sizeAtZero) * g
               : sizeAtReference + sizeBeyondSlope * (g - 1)
    }

    /// The confidence → assembly factor.
    public static func assembly(for confidence: TelosConfidence) -> Double {
        switch confidence {
        case .solid:
            return 1
        case .building:
            return 0.8
        case .calibrating(let done, let total):
            guard let done, let total, total > 0 else { return 0.45 }
            let progress = min(max(Double(done) / Double(total), 0), 1)
            return 0.35 + 0.45 * progress
        }
    }

    public static func from(_ inputs: TelosOrbInputs) -> TelosOrbAppearance {
        let assemblyFactor = Self.assembly(for: inputs.confidence)

        // Level → growth, size, density, shells.
        var growthValue: Double? = nil
        var size = neutralSize
        var shells = 0.0
        var density = neutralDensity
        if let level = finite(inputs.level) {
            let g = growth(level: level)
            growthValue = g
            size = TelosOrbAppearance.size(growth: g)
            shells = max(0, g - 1)
            density = densityAtZero + (1 - densityAtZero) * min(g, 1)
        }
        density *= assemblyFactor

        // Part shares → normalised weights.
        var weights: [TelosOrbPart: Double] = [:]
        let valid = inputs.partShares.filter { $0.value.isFinite && $0.value > 0 }
        let total = valid.values.reduce(0, +)
        if total > 0 {
            for (part, share) in valid { weights[part] = share / total }
        }

        // Stress → turbulence.
        var turbulence = turbulenceRange.lowerBound
        let stress = finite(inputs.stress)
        if let stress {
            let s = min(max(stress, 0), stressScaleTop) / stressScaleTop   // the 0–3 scale is bounded
            turbulence = turbulenceRange.lowerBound + s * (turbulenceRange.upperBound - turbulenceRange.lowerBound)
        }

        // Heart rate → pulse period.
        var pulse = neutralPulsePeriod
        var hasHR = false
        if let bpm = finite(inputs.heartRateBpm), bpm > 0 {
            hasHR = true
            pulse = pulseSlowdown * 60 / bpm
        }

        // Charge → brightness.
        var brightness = neutralBrightness
        let charge = finite(inputs.charge)
        if let charge {
            let c = min(max(charge, 0), 100) / 100                        // the 0–100 score is bounded
            brightness = brightnessRange.lowerBound + c * (brightnessRange.upperBound - brightnessRange.lowerBound)
        }

        // Effort vs target → orbit speed (unbounded).
        var orbit = neutralOrbitSpeed
        let effort = finite(inputs.effortRatio)
        if let effort { orbit = 0.4 + 0.8 * max(0, effort) }

        let hasAnything = growthValue != nil || !weights.isEmpty || stress != nil || hasHR
            || charge != nil || effort != nil
        if !hasAnything { brightness = emptyBrightness }
        brightness *= 0.6 + 0.4 * assemblyFactor

        return TelosOrbAppearance(growth: growthValue, size: size, outerShells: shells,
                                  density: min(max(density, 0), 1), partWeights: weights,
                                  turbulence: turbulence, pulsePeriod: pulse, brightness: brightness,
                                  orbitSpeed: orbit, assembly: assemblyFactor,
                                  hasLevel: growthValue != nil, hasStress: stress != nil, hasHeartRate: hasHR,
                                  hasCharge: charge != nil, hasEffort: effort != nil)
    }

    private static func finite(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return v
    }
}

// MARK: - Tint

/// The orb's colour family when no part shares are given (second reference image).
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

/// One cloud point: a unit direction, its shell (1 = surface, < 1 = interior), a size factor, a hue
/// coordinate (longitude-based, so part colours form wedges that turn with the blob), a density rank
/// and an assembly scatter.
struct TelosOrbPoint: Equatable {
    let x: Double
    let y: Double
    let z: Double
    let shell: Double
    let size: Double
    let isInterior: Bool
    let hue: Double
    let rank: Double
    let scatter: Double
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

    /// A seeded point cloud on the unit sphere: a Fibonacci lattice (even coverage) with seeded jitter,
    /// ~18 % of points pulled inside for volume. Same seed → same cloud, on every launch.
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
            var hue = atan2(z, x) / (2 * Double.pi) + 0.5 + (rng.unit() - 0.5) * 0.06
            hue -= hue.rounded(.down)                                  // wrap into 0..<1
            let rank = rng.unit()
            let scatter = rng.unit()
            out.append(TelosOrbPoint(x: x, y: y, z: z, shell: shell, size: size, isInterior: interior,
                                     hue: hue, rank: rank, scatter: scatter))
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

    /// Which palette colour a point takes: by its hue coordinate against the cumulative part weights
    /// (`thresholds`, ascending, last = 1). Pure.
    static func colourIndex(hue: Double, thresholds: [Double]) -> Int {
        for (i, t) in thresholds.enumerated() where hue < t { return i }
        return max(0, thresholds.count - 1)
    }
}

// MARK: - Palette

/// The colours a frame paints with: the part hues by share (`thresholds` = cumulative weights), or the
/// tint's lit / shade pair split by the light (`thresholds == nil`).
struct TelosOrbPalette {
    let colors: [Color]
    let thresholds: [Double]?
    /// The colour of glow, orbits and shells.
    let accent: Color

    static func make(appearance: TelosOrbAppearance, tint: TelosOrbTint) -> TelosOrbPalette {
        if appearance.isNeutral {
            return TelosOrbPalette(colors: [TelosColor.textSecondary, TelosColor.textTertiary], thresholds: nil,
                                   accent: TelosColor.textSecondary)
        }
        let parts = TelosOrbPart.allCases.filter { (appearance.partWeights[$0] ?? 0) > 0 }
        if parts.isEmpty {
            return TelosOrbPalette(colors: [tint.lit, tint.shade], thresholds: nil, accent: tint.lit)
        }
        var cumulative = 0.0
        var thresholds: [Double] = []
        for part in parts {
            cumulative += appearance.partWeights[part] ?? 0
            thresholds.append(cumulative)
        }
        thresholds[thresholds.count - 1] = 1                  // guard float drift
        return TelosOrbPalette(colors: parts.map(\.color), thresholds: thresholds, accent: tint.lit)
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

    /// When the ambient frame clock may run (always further gated by `TelosFrameGate`).
    public enum Clock: Equatable, Sendable {
        /// Slow rotation + pulse while visible (the owner's direction for Home).
        case whileVisible
        /// Run for `seconds` after appearing and after each data change, then rest.
        case burst(seconds: Double)
        /// Never run (widgets, snapshots, lists).
        case still
    }

    private let appearance: TelosOrbAppearance
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
    /// The animated values actually drawn (nil until first appear — then posed without animation).
    @State private var shown: TelosOrbAnimatedValues? = nil
    /// Live time counts from here, so a clock that resumes starts from the still pose (t = 0) instead
    /// of jumping to wherever wall-clock time would have put it.
    @State private var liveEpoch = Date()

    public init(appearance: TelosOrbAppearance, tint: TelosOrbTint = .green, style: Style = .hero,
                clock: Clock = .whileVisible) {
        self.appearance = appearance
        self.tint = tint
        self.style = style
        self.clock = clock
    }

    public init(inputs: TelosOrbInputs, tint: TelosOrbTint = .green, style: Style = .hero,
                clock: Clock = .whileVisible) {
        self.init(appearance: TelosOrbAppearance.from(inputs), tint: tint, style: style, clock: clock)
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
        // The neutral orb (nothing measured) is a still orb: no motion without data (§7.1).
        return TelosFrameGate.mode(requested: requested && !appearance.isNeutral, visible: visible,
                                   offscreen: offscreen, covered: covered,
                                   poseStill: motion.poseStill(reduceMotion), withinActiveWindow: window)
    }

    private var burstSeconds: Double {
        if case .burst(let seconds) = clock { return max(0, seconds) }
        return 0
    }

    private var target: TelosOrbAnimatedValues { TelosOrbAnimatedValues(appearance) }

    public var body: some View {
        let live = mode == .live
        let values = shown ?? target
        let appearance = self.appearance
        let palette = TelosOrbPalette.make(appearance: appearance, tint: tint)
        let style = self.style
        let epoch = liveEpoch
        TimelineView(.animation(minimumInterval: TelosFrameGate.minimumInterval, paused: !live)) { timeline in
            let t: Double = live ? max(0, timeline.date.timeIntervalSince(epoch)) : 0
            TelosOrbLayer(size: values.size, brightness: values.brightness, turbulence: values.turbulence,
                          density: values.density, appearance: appearance, palette: palette,
                          style: style, time: t)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            visible = true
            appearCount &+= 1
            if shown == nil { shown = target }
        }
        .onDisappear { visible = false }
        .telosOffscreen { offscreen = $0 }
        .onChangeCompat(of: target) { next in
            // A data change: the form flows to its new value (never on appear; instant under Reduce
            // Motion or before the first appear).
            if motion.poseStill(reduceMotion) || shown == nil {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { shown = next }
            } else {
                withAnimation(TelosMotion.flow) { shown = next }
            }
        }
        .telosSettleWindow(on: BurstKey(appearance: appearance, appear: appearCount), duration: burstSeconds,
                           active: $burstOpen)
        .onChangeCompat(of: live) { isLive in
            if isLive { liveEpoch = Date() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A burst reopens on a data change AND on each appear.
    private struct BurstKey: Equatable {
        let appearance: TelosOrbAppearance
        let appear: Int
    }
}

/// The four values that flow on a data change.
struct TelosOrbAnimatedValues: Equatable {
    var size: Double
    var brightness: Double
    var turbulence: Double
    var density: Double

    init(_ a: TelosOrbAppearance) {
        size = a.size
        brightness = a.brightness
        turbulence = a.turbulence
        density = a.density
    }
}

/// The Canvas host. `Animatable`, so a data change interpolates the form frame by frame for the
/// duration of the `flow` spring only — then it rests.
struct TelosOrbLayer: View, Animatable {
    var size: Double
    var brightness: Double
    var turbulence: Double
    var density: Double
    let appearance: TelosOrbAppearance
    let palette: TelosOrbPalette
    let style: TelosOrb.Style
    let time: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { AnimatablePair(AnimatablePair(size, brightness), AnimatablePair(turbulence, density)) }
        set {
            size = newValue.first.first
            brightness = newValue.first.second
            turbulence = newValue.second.first
            density = newValue.second.second
        }
    }

    var body: some View {
        let frame = TelosOrbRenderer.Frame(size: size, brightness: brightness, turbulence: turbulence,
                                           density: density, time: time)
        let appearance = self.appearance
        let palette = self.palette
        let style = self.style
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, canvasSize in
            TelosOrbRenderer.draw(context: &context, size: canvasSize, frame: frame, appearance: appearance,
                                  palette: palette, style: style)
        }
    }
}

// MARK: - Renderer

enum TelosOrbRenderer {

    /// The per-frame values (the animated four + time).
    struct Frame {
        let size: Double
        let brightness: Double
        let turbulence: Double
        let density: Double
        let time: Double
    }

    /// Fake light from the upper left, slightly in front (y up).
    private static let light: (x: Double, y: Double, z: Double) = {
        let v = (-0.45, 0.55, 0.70)
        let l = (v.0 * v.0 + v.1 * v.1 + v.2 * v.2).squareRoot()
        return (v.0 / l, v.1 / l, v.2 / l)
    }()

    /// Opacity steps per colour bucket.
    static let levels = 4

    static func draw(context: inout GraphicsContext, size: CGSize, frame f: Frame,
                     appearance a: TelosOrbAppearance, palette: TelosOrbPalette, style: TelosOrb.Style) {
        let dim = min(size.width, size.height)
        guard dim > 8 else { return }
        let t = f.time
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let hero = style == .hero
        let cloud = hero ? TelosOrbGeometry.heroCloud : TelosOrbGeometry.compactCloud
        let lobes = TelosOrbGeometry.lobes
        let dust = hero ? TelosOrbGeometry.heroDust : TelosOrbGeometry.compactDust
        let base = Double(dim) * 0.24                      // pixel radius of the size-1 sphere
        let R = base * f.size
        let bright = f.brightness
        let accent = palette.accent
        let dotScale = max(0.6, Double(dim) / 240)

        // Per-frame constants (not per point).
        let calmRate = 0.6 + 0.8 * f.turbulence
        let pulses = lobes.map { 0.85 + 0.15 * sin(t * $0.omega * calmRate + $0.phase) }
        let breath = t > 0 ? 0.025 * sin(2 * Double.pi * t / max(a.pulsePeriod, 0.5)) : 0
        let yaw = 0.6 + t * 2 * Double.pi / 60
        let pitch = 0.35 + 0.05 * sin(t * 0.2)
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch)
        let unassembled = 1 - a.assembly

        // 1. Ambient dust (behind everything), one path.
        var dustPath = Path()
        for p in dust {
            let dx = CGFloat(sin(p.phase + t * p.speed)) * 2
            let dy = CGFloat(cos(p.phase * 1.3 + t * p.speed * 0.7)) * 2
            let d = CGFloat(p.size)
            dustPath.addEllipse(in: CGRect(x: CGFloat(p.x) * size.width + dx - d / 2,
                                           y: CGFloat(p.y) * size.height + dy - d / 2, width: d, height: d))
        }
        context.fill(dustPath, with: .color(accent.opacity(0.30 * bright)))

        // 2. The glow — one pre-composited radial gradient, no blur.
        let glowR = CGFloat(R * 1.9)
        context.fill(Path(ellipseIn: CGRect(x: c.x - glowR, y: c.y - glowR, width: glowR * 2, height: glowR * 2)),
                     with: .radialGradient(Gradient(colors: [accent.opacity(0.20 * bright),
                                                             accent.opacity(0.07 * bright), .clear]),
                                           center: c, startRadius: 0, endRadius: glowR))

        // 3. Orbits (behind the cloud) + the dots currently behind the orb. Dot speed = effort / target.
        let orbits = orbitSpecs(hero: hero, dim: Double(dim), speed: a.orbitSpeed)
        for o in orbits {
            context.stroke(o.path(center: c), with: .color(accent.opacity(0.10)), lineWidth: 2.2)
            context.stroke(o.path(center: c), with: .color(accent.opacity(0.42)), lineWidth: 0.7)
        }
        var dots: [(CGPoint, Bool)] = []
        for o in orbits { dots.append(o.dot(center: c, time: t)) }
        for (p, front) in dots where !front { drawOrbitDot(&context, at: p, color: accent, strength: 0.45) }

        // 4. The cloud, bucketed: [palette colour][opacity step].
        let colourCount = palette.colors.count
        var buckets = [Path](repeating: Path(), count: colourCount * levels)
        let L = light
        for p in cloud {
            guard p.rank < f.density else { continue }       // Level + confidence → how much is drawn
            // Rotate the unit direction: yaw about Y, then pitch about X.
            let x1 = p.x * cy + p.z * sy
            let z1 = -p.x * sy + p.z * cy
            let y2 = p.y * cp - z1 * sp
            let z2 = p.y * sp + z1 * cp
            var r = TelosOrbGeometry.radius(x: p.x, y: p.y, z: p.z, lobes: lobes, pulses: pulses,
                                            turbulence: f.turbulence, breath: breath, time: t) * p.shell
            // Provisional Level: dots have not all settled onto the surface yet.
            r *= 1 + unassembled * 0.45 * p.scatter
            let px = Double(c.x) + x1 * r * R
            let py = Double(c.y) - y2 * r * R
            let front = (z2 + 1) / 2                          // 0 back … 1 front
            let lambert = max(0, x1 * L.x + y2 * L.y + z2 * L.z)
            let rim = p.isInterior ? 0 : pow(1 - max(0, z2), 2)
            var intensity = bright * (0.18 + 0.50 * lambert + 0.55 * rim) * (0.45 + 0.55 * front)
            if p.isInterior { intensity *= 0.45 }
            guard intensity > 0.04 else { continue }
            let step = min(levels - 1, Int(intensity * Double(levels)))
            let colour: Int
            if let thresholds = palette.thresholds {
                colour = min(colourCount - 1, TelosOrbGeometry.colourIndex(hue: p.hue, thresholds: thresholds))
            } else {
                colour = lambert > 0.35 ? 0 : min(1, colourCount - 1)
            }
            let d = CGFloat(max(0.6, (0.8 + 1.4 * front) * p.size * dotScale))
            let rect = CGRect(x: px - Double(d) / 2, y: py - Double(d) / 2, width: Double(d), height: Double(d))
            if d < 1.3 {
                buckets[colour * levels + step].addRect(rect)
            } else {
                buckets[colour * levels + step].addEllipse(in: rect)
            }
        }
        for colour in 0..<colourCount {
            let ink = palette.colors[colour]
            for step in 0..<levels {
                let path = buckets[colour * levels + step]
                if path.isEmpty { continue }
                context.fill(path, with: .color(ink.opacity((Double(step) + 0.5) / Double(levels))))
            }
        }

        // 5. Orbit dots in front of the orb.
        for (p, front) in dots where front { drawOrbitDot(&context, at: p, color: accent, strength: 1) }

        // 6. Particle shells: each growth unit past the reference range adds one tilted shell of dots
        //    (the Level is unbounded — the orb grows outward instead of clipping). A partial unit draws
        //    its shell at that fraction's opacity.
        if a.outerShells > 0 {
            let count = Int(a.outerShells.rounded(.up))
            for k in 0..<count {
                let strength = min(1, a.outerShells - Double(k))
                let rx = Double(dim) * (0.40 + 0.035 * Double(k))
                let ry = rx * 0.34
                let rot = (30 + 47 * Double(k)) * Double.pi / 180 + t * 0.05
                var shell = Path()
                let n = 56
                for j in 0..<n {
                    let a0 = Double(j) / Double(n) * 2 * Double.pi
                    let ex = rx * cos(a0), ey = ry * sin(a0)
                    let x = Double(c.x) + ex * cos(rot) - ey * sin(rot)
                    let y = Double(c.y) + ex * sin(rot) + ey * cos(rot)
                    shell.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                }
                context.fill(shell, with: .color(accent.opacity(0.75 * strength)))
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

        /// The travelling dot's position and whether it is in front of the orb (the lower half of the
        /// tilted ellipse faces the viewer).
        func dot(center c: CGPoint, time t: Double) -> (CGPoint, Bool) {
            let a = phase + (period > 0 ? t * 2 * Double.pi / period : 0)
            let ex = rx * cos(a), ey = ry * sin(a)
            let x = ex * cos(rotation) - ey * sin(rotation)
            let y = ex * sin(rotation) + ey * cos(rotation)
            return (CGPoint(x: Double(c.x) + x, y: Double(c.y) + y), sin(a) > 0)
        }
    }

    /// The orbits; `speed` (the effort ratio mapping) scales the dots' angular speed.
    static func orbitSpecs(hero: Bool, dim: Double, speed: Double) -> [OrbitSpec] {
        let s = max(speed, 0.05)
        if hero {
            return [
                OrbitSpec(rx: dim * 0.46, ry: dim * 0.14, rotation: -16 * Double.pi / 180, period: 16 / s, phase: 0.6),
                OrbitSpec(rx: dim * 0.40, ry: dim * 0.21, rotation: 28 * Double.pi / 180, period: 23 / s, phase: 3.1),
            ]
        }
        return [OrbitSpec(rx: dim * 0.44, ry: dim * 0.13, rotation: -14 * Double.pi / 180, period: 18 / s, phase: 0.9)]
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
        TelosOrb(inputs: TelosOrbInputs(level: 81,
                                        partShares: [.sleep: 30, .heart: 22, .muscle: 20, .lungs: 12, .focus: 9],
                                        stress: 0.8, heartRateBpm: 52, charge: 88, effortRatio: 0.9))
            .frame(width: 220)
        HStack(spacing: 16) {
            TelosOrb(inputs: TelosOrbInputs(), style: .compact).frame(width: 110)
            TelosOrb(inputs: TelosOrbInputs(stress: 2.4, charge: 70), tint: .teal, style: .compact).frame(width: 110)
            TelosOrb(inputs: TelosOrbInputs(level: 60, charge: 87, confidence: .calibrating(done: 2, total: 7)),
                     tint: .violet, style: .compact).frame(width: 110)
        }
        TelosOrb(inputs: TelosOrbInputs(level: 420, charge: 95), tint: .amber, style: .compact, clock: .still)
            .frame(width: 110)
    }
    .padding(24)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
