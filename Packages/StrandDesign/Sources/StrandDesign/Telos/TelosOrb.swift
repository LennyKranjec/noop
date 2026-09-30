import SwiftUI

// MARK: - TelosOrb — the living "organ" blob (docs/DESIGN_V2.md VISUAL DIRECTION: Today / Home centrepiece)
//
// A soft, matte, irregular cell cluster — one LOBE ("organ") per Level part around a core body, a
// dotted membrane skin, faint inner veins running from the core to each lobe's nucleus, thin orbit
// ellipses with small plain dots travelling along them (docs/design-ref/telos-v2-today.jpg). It is
// NOT a planet: no sphere shading, no highlight, no latitude/longitude, no rings around a ball. And it
// is clinical, not a toy (decision 19): no glow halo, no sparkle, no glowing dots; the part hues are
// muted data tints. It is an
// INSTRUMENT, not decoration (owner direction): every visible property is bound to a real number through
// ONE pure mapping, `TelosOrbAppearance.from(_:)`, and the Today hero's tap opens a legend of exactly
// these channels with today's values (`OrbExplainerSheet` in the app).
//
// THE DATA MAPPING (pure, unit-tested — TelosInstrumentTests)
//
//   input (TelosOrbInputs)            → appearance                        rule
//   ────────────────────────────────  ─────────────────────────────────  ─────────────────────────────────
//   level (unbounded, 100 = own P95)  growth = log2(1 + level/100)       strictly increasing, NO maximum.
//                                     size   0.72 → 1.12 over 0…100,      keeps growing slowly past 100
//                                            then +0.06 per growth unit   (never clamped);
//                                     density 55 % → 100 % of the dots    past the reference range each
//                                     outerShells = growth − 1            growth unit adds a dotted shell.
//   partShares (sleep/heart/lungs/    the LOBES: one organ per part,      shares normalised; lobe AREA ∝
//   muscle/focus → share of level)    in its levelPartTint hue            share; an absent part has no lobe.
//   stress (0–3)                      turbulence 0.12 → 1.0               calm = smooth membrane, stressed
//                                                                         = rippled membrane + more sway.
//   heartRateBpm (resting / rolling)  pulse period = 6 × 60 / bpm s       breathes with the heart, slowed
//                                                                         6× (60 bpm → a 6 s breath).
//   charge (0–100)                    tissue opacity (brightness)         the body reads denser with a
//                                     0.40 → 1.0                          higher Charge; never a glow.
//   effortRatio (effort / target,     orbit-dot speed 0.4 + 0.8 × ratio   unbounded (a 2× effort day
//   unbounded)                                                            spins them at 2×).
//   confidence                        assembly: solid 1 · building 0.8 ·  provisional = sparser, dimmer,
//                                     calibrating 0.35…0.8 (n of m)       dots still drifting in, faint
//                                                                         membrane.
//
//   ABSENT INPUTS NEVER INVENT A VALUE: a missing channel rests at its calm neutral (size 0.92, density
//   0.8, turbulence 0.12, an 8 s breath, brightness 0.55, orbit speed 0.6, the tint's own unlabelled
//   lobes instead of part lobes). With EVERY input missing the orb is the neutral dim still orb:
//   desaturated grey, brightness 0.42, and NO clock at all. The exact numbers are always printed beside
//   the orb, so it is hidden from VoiceOver (it never replaces a numeral).
//
// THE PICTURE (unit space, blob radius ≈ 1 = `baseRadius` × the frame × size)
//   A core disc plus one disc per part at a fixed angle (sleep upper-left, focus upper-right, heart right,
//   muscle below, lungs left). The membrane is the union's outline sampled in polar form, box-smoothed
//   so the creases between lobes round off, then rippled by stress. Lobes are soft radial fills clipped
//   to the membrane with a faint inner rim; ≤ 150 dots (a membrane row + interior stipple) coloured by
//   the lobe they sit in; veins + nuclei on their own layer.
//
// MOTION — PER FRAME ONLY TRANSFORMS (owner: the app lags)
//   • All geometry is built ONCE per data change (`TelosOrbForm.make`) and rasterised ONCE into two
//     `Equatable` canvases (body, nuclei) plus a static backdrop (orbit lines, growth shells). A frame
//     changes only view TRANSFORMS: an anisotropic breathing scale (the heart pulse, squash-and-stretch),
//     a slight sway (more under stress), the nuclei's own out-of-phase pulse, and the two orbit dots'
//     offsets. No canvas redraws per frame.
//   • Value changes (size, brightness, turbulence, density) flow with `TelosMotion.flow` through an
//     `Animatable` layer — only while the value changes; instant under Reduce Motion.
//   • The ambient clock runs at ≤ 20 fps (`TelosOrb.frameInterval`) ONLY while `TelosFrameGate` says
//     live: on screen, not scrolled away (`telosOffscreen`), not under a sheet (`noopBackgroundCovered`),
//     not posed still (`NoopMotionState.poseStill` = Reduce Motion ‖ Low Power ‖ "Reduce motion in NOOP"),
//     and not the neutral orb. A `.burst` clock eases its motion in and back out to the rest pose inside
//     its window (`TelosOrbPose.envelope`), so the still frame after it never snaps.
//   • `clock: .burst(seconds:)` confines the clock to a window after appear / after a data change (for
//     screens held to the §2.1 "idle = 0 clocks" budget — Today uses 8 s); `.still` never runs one.
//
// COST (§2.1 rule 8): three canvases rendered asynchronously, each drawn once per data change; ≤ 150
// dots batched by colour × 3 opacity tiers (≤ 18 fills); no blur, no shadow, no glow, no material, no
// drawingGroup.

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
    /// Tissue + dot opacity multiplier (Charge). Never drawn as a glow.
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

/// The orb's own tiny deterministic generator (SplitMix64), so the dots are the same on every launch.
struct TelosOrbRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func unit() -> Double {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}

/// One lobe of the blob, in unit space (y down). Index 0 of a form's lobes is always the core body.
/// `part` is nil for the core and for the tint's own unlabelled lobes (no part shares given).
struct TelosOrbLobe: Equatable {
    let part: TelosOrbPart?
    /// Into `TelosOrbPalette.colors`: 0 = the core / tint, 1… = the parts in `TelosOrbPart.allCases` order.
    let colorIndex: Int
    let x: Double
    let y: Double
    let r: Double
}

/// Dots of one colour and one opacity tier, batched into one path (one fill).
struct TelosOrbDotBatch: Equatable {
    let colorIndex: Int
    let tier: Int
    let path: Path
}

/// Veins of one colour, batched into one path (one stroke pair).
struct TelosOrbVeinBatch: Equatable {
    let colorIndex: Int
    let path: Path
}

/// Everything the orb draws, built ONCE per data change and only transformed per frame.
struct TelosOrbForm: Equatable {
    /// [0] = the core, then one lobe per part with a share (or the tint's three unlabelled lobes).
    let lobes: [TelosOrbLobe]
    /// The membrane's polar radii, `TelosOrbGeometry.outlineSamples` samples from angle 0 (unit space).
    let outline: [Double]
    /// The membrane outline as a smooth closed path (unit space).
    let membrane: Path
    /// The largest outline radius.
    let extent: Double
    /// ≤ `TelosOrbGeometry.maxDots` dots, batched by colour × tier.
    let dots: [TelosOrbDotBatch]
    /// How many dots the batches hold.
    let dotCount: Int
    /// Veins from the core to each lobe's nucleus.
    let veins: [TelosOrbVeinBatch]
    /// 1 = assembled; < 1 = provisional (fainter membrane, dots drifting in).
    let assembly: Double
}

enum TelosOrbGeometry {
    /// Membrane samples around the full turn.
    static let outlineSamples = 96
    /// The hard dot budget (owner: the app lags).
    static let maxDots = 150
    /// The core body's radius (unit space).
    static let coreRadius = 0.60
    /// Opacity tiers the dots are batched into.
    static let tiers = 3

    static func membraneDotCount(_ style: TelosOrb.Style) -> Int { style == .hero ? 78 : 54 }
    static func interiorDotCount(_ style: TelosOrb.Style) -> Int { style == .hero ? 66 : 42 }
    /// Dot radius in unit space (the compact orb is drawn smaller, so its dots are relatively larger).
    static func dotRadius(_ style: TelosOrb.Style) -> Double { style == .hero ? 0.019 : 0.026 }

    // MARK: Lobes

    /// Where each part's lobe sits (radians in screen coordinates: 0 = right, π/2 = down) and which way
    /// its vein bends. Fixed, so a part's organ is always in the same place on every orb.
    static func anchor(_ part: TelosOrbPart) -> (angle: Double, bend: Double) {
        switch part {
        case .sleep:  return (-128 * Double.pi / 180, 0.18)
        case .focus:  return (-48 * Double.pi / 180, -0.14)
        case .heart:  return (18 * Double.pi / 180, 0.16)
        case .muscle: return (96 * Double.pi / 180, -0.12)
        case .lungs:  return (168 * Double.pi / 180, 0.15)
        }
    }

    /// The palette slot of a part's colour.
    static func colorIndex(of part: TelosOrbPart) -> Int {
        1 + (TelosOrbPart.allCases.firstIndex(of: part) ?? 0)
    }

    /// A lobe's radius for its normalised share: area grows with the share (radius ∝ √share, plus a small
    /// floor so a thin share is still a visible organ). 0 for no share — an absent part has no lobe.
    static func lobeRadius(share: Double) -> Double {
        guard share.isFinite, share > 0 else { return 0 }
        return 0.14 + 0.95 * min(share, 1).squareRoot()
    }

    /// How far a lobe's centre sits from the core's: bigger organs bulge further out.
    static func lobeDistance(radius r: Double) -> Double { 0.40 + 0.28 * r }

    /// The core plus one lobe per part with a share; with no shares, the tint's three unlabelled lobes
    /// (one organic shape family, in the single tint colour — no part is implied).
    static func lobes(for appearance: TelosOrbAppearance) -> [TelosOrbLobe] {
        var out = [TelosOrbLobe(part: nil, colorIndex: 0, x: 0, y: 0, r: coreRadius)]
        let parts = TelosOrbPart.allCases.filter { (appearance.partWeights[$0] ?? 0) > 0 }
        if parts.isEmpty {
            let neutral: [(degrees: Double, r: Double)] = [(-115, 0.48), (5, 0.44), (120, 0.40)]
            for lobe in neutral {
                let a = lobe.degrees * Double.pi / 180
                let d = lobeDistance(radius: lobe.r)
                out.append(TelosOrbLobe(part: nil, colorIndex: 0, x: d * cos(a), y: d * sin(a), r: lobe.r))
            }
            return out
        }
        for part in parts {
            let r = lobeRadius(share: appearance.partWeights[part] ?? 0)
            let a = anchor(part).angle
            let d = lobeDistance(radius: r)
            out.append(TelosOrbLobe(part: part, colorIndex: colorIndex(of: part), x: d * cos(a), y: d * sin(a), r: r))
        }
        return out
    }

    /// A nucleus's radius (unit space).
    static func nucleusRadius(_ lobe: TelosOrbLobe, isCore: Bool) -> Double {
        isCore ? 0.10 : 0.05 + 0.06 * lobe.r
    }

    // MARK: Membrane

    static func angle(_ k: Int, _ n: Int) -> Double { 2 * Double.pi * Double(k) / Double(max(n, 1)) }

    /// Distance from the origin to where a ray at `angle` leaves the lobe's disc; nil if it misses.
    static func hit(angle: Double, lobe l: TelosOrbLobe) -> Double? {
        let ux = cos(angle), uy = sin(angle)
        let b = ux * l.x + uy * l.y
        let c = l.x * l.x + l.y * l.y - l.r * l.r
        let disc = b * b - c
        guard disc >= 0 else { return nil }
        let t = b + disc.squareRoot()
        return t > 0 ? t : nil
    }

    /// The membrane: the union of the lobes in polar form, box-smoothed twice (±4 samples) so the creases
    /// between lobes round off like a soft cell, then rippled by stress (`turbulence` 0…1). `owner` names
    /// the lobe that reaches furthest in each direction (the membrane dot there takes its colour).
    static func outline(lobes: [TelosOrbLobe], turbulence: Double,
                        samples n: Int = outlineSamples) -> (radii: [Double], owner: [Int]) {
        guard n > 0, !lobes.isEmpty else { return ([], []) }
        var raw = [Double](repeating: 0, count: n)
        var owner = [Int](repeating: 0, count: n)
        for k in 0..<n {
            let a = angle(k, n)
            var best = 0.0
            var who = 0
            for (i, lobe) in lobes.enumerated() {
                if let t = hit(angle: a, lobe: lobe), t > best {
                    best = t
                    who = i
                }
            }
            raw[k] = best
            owner[k] = who
        }
        var radii = raw
        for _ in 0..<2 {
            var next = radii
            for k in 0..<n {
                var sum = 0.0
                for j in -4...4 { sum += radii[((k + j) % n + n) % n] }
                next[k] = sum / 9
            }
            radii = next
        }
        let ripple = min(max(turbulence.isFinite ? turbulence : 0, 0), 1)
        for k in 0..<n {
            let a = angle(k, n)
            radii[k] *= 1 + ripple * (0.05 * sin(6 * a + 0.7) + 0.028 * sin(11 * a + 2.3))
        }
        return (radii, owner)
    }

    /// A smooth closed path through the polar radii (quadratic curves through the midpoints).
    static func membranePath(radii: [Double]) -> Path {
        let n = radii.count
        var path = Path()
        guard n >= 3 else { return path }
        func point(_ k: Int) -> (x: Double, y: Double) {
            let i = k % n
            let a = angle(i, n)
            return (radii[i] * cos(a), radii[i] * sin(a))
        }
        func mid(_ k: Int) -> CGPoint {
            let p = point(k), q = point(k + 1)
            return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
        }
        path.move(to: mid(0))
        for k in 1...n {
            let c = point(k)
            path.addQuadCurve(to: mid(k), control: CGPoint(x: c.x, y: c.y))
        }
        path.closeSubpath()
        return path
    }

    // MARK: The form

    /// Builds the whole picture for one set of values. Pure and deterministic (seeded): the same inputs
    /// always give the same form, and a dot keeps its place as `density` changes (every dot draws its
    /// random numbers whether or not it is kept).
    static func form(appearance a: TelosOrbAppearance, turbulence: Double, density: Double,
                     style: TelosOrb.Style) -> TelosOrbForm {
        let lobes = self.lobes(for: a)
        let (radii, owner) = outline(lobes: lobes, turbulence: turbulence)
        let n = radii.count
        let assembly = min(max(a.assembly.isFinite ? a.assembly : 1, 0), 1)
        let unassembled = 1 - assembly
        let keep = density.isFinite ? density : 0
        let dotR = dotRadius(style)

        var batches: [Int: Path] = [:]
        var count = 0
        func add(_ x: Double, _ y: Double, radius: Double, colorIndex: Int, tier: Int) {
            guard count < maxDots else { return }
            let key = colorIndex * tiers + min(max(tier, 0), tiers - 1)
            batches[key, default: Path()].addEllipse(in: CGRect(x: x - radius, y: y - radius,
                                                                width: radius * 2, height: radius * 2))
            count += 1
        }

        // 1. The membrane's dotted skin, just inside the outline, coloured by the lobe underneath.
        var skin = TelosOrbRandom(seed: 0x7E105_5C)
        let m = membraneDotCount(style)
        for k in 0..<m {
            let jitter = skin.unit(), inset = skin.unit(), sizeU = skin.unit()
            let tierU = skin.unit(), rank = skin.unit(), scatter = skin.unit()
            guard n > 0, rank < keep else { continue }
            let ang = 2 * Double.pi * (Double(k) + 0.2 + 0.6 * jitter) / Double(m)
            let idx = ((Int((ang / (2 * Double.pi) * Double(n)).rounded()) % n) + n) % n
            let rho = radii[idx] * (0.985 - 0.045 * inset) * (1 + unassembled * 0.5 * scatter)
            let tier = tierU < 0.25 ? 0 : (tierU < 0.65 ? 1 : 2)
            add(rho * cos(ang), rho * sin(ang), radius: dotR * (0.75 + 0.55 * sizeU),
                colorIndex: lobes[owner[idx]].colorIndex, tier: tier)
        }

        // 2. Interior stipple, spread over the lobes by area; dimmer tiers.
        var stipple = TelosOrbRandom(seed: 0x7E105_1D)
        let areas = lobes.map { $0.r * $0.r }
        let totalArea = areas.reduce(0, +)
        for _ in 0..<interiorDotCount(style) {
            let pick = stipple.unit(), angU = stipple.unit(), radU = stipple.unit(), sizeU = stipple.unit()
            let tierU = stipple.unit(), rank = stipple.unit(), scatter = stipple.unit()
            guard totalArea > 0, rank < keep else { continue }
            var chosen = lobes.count - 1
            var acc = 0.0
            for (i, area) in areas.enumerated() {
                acc += area / totalArea
                if pick < acc { chosen = i; break }
            }
            let lobe = lobes[chosen]
            let ang = angU * 2 * Double.pi
            let rad = radU.squareRoot() * lobe.r * 0.82
            let push = 1 + unassembled * 0.4 * scatter
            add((lobe.x + rad * cos(ang)) * push, (lobe.y + rad * sin(ang)) * push,
                radius: dotR * (0.6 + 0.5 * sizeU), colorIndex: lobe.colorIndex, tier: tierU < 0.55 ? 0 : 1)
        }

        // 3. Veins: a bent line from near the core's centre to each lobe's nucleus, with one short branch.
        var veinPaths: [Int: Path] = [:]
        for lobe in lobes.dropFirst() {
            let len = (lobe.x * lobe.x + lobe.y * lobe.y).squareRoot()
            guard len > 1e-6 else { continue }
            let nx = -lobe.y / len, ny = lobe.x / len
            let bend = lobe.part.map { anchor($0).bend } ?? 0.12
            let p0 = (x: lobe.x * 0.12, y: lobe.y * 0.12)
            let c = (x: lobe.x * 0.5 + nx * bend * len, y: lobe.y * 0.5 + ny * bend * len)
            let s = 0.65
            let bx = (1 - s) * (1 - s) * p0.x + 2 * (1 - s) * s * c.x + s * s * lobe.x
            let by = (1 - s) * (1 - s) * p0.y + 2 * (1 - s) * s * c.y + s * s * lobe.y
            let out = atan2(lobe.y, lobe.x) + (bend >= 0 ? 0.9 : -0.9)
            var path = veinPaths[lobe.colorIndex, default: Path()]
            path.move(to: CGPoint(x: p0.x, y: p0.y))
            path.addQuadCurve(to: CGPoint(x: lobe.x, y: lobe.y), control: CGPoint(x: c.x, y: c.y))
            path.move(to: CGPoint(x: bx, y: by))
            path.addLine(to: CGPoint(x: lobe.x + cos(out) * lobe.r * 0.62, y: lobe.y + sin(out) * lobe.r * 0.62))
            veinPaths[lobe.colorIndex] = path
        }

        let dots = batches.keys.sorted().map { key in
            TelosOrbDotBatch(colorIndex: key / tiers, tier: key % tiers, path: batches[key] ?? Path())
        }
        let veins = veinPaths.keys.sorted().map { TelosOrbVeinBatch(colorIndex: $0, path: veinPaths[$0] ?? Path()) }
        return TelosOrbForm(lobes: lobes, outline: radii, membrane: membranePath(radii: radii),
                            extent: radii.max() ?? coreRadius, dots: dots, dotCount: count, veins: veins,
                            assembly: assembly)
    }
}

// MARK: - Pose (the only per-frame work)

/// The per-frame transform of the rasterised layers. Pure.
struct TelosOrbPose: Equatable {
    var scaleX: Double = 1
    var scaleY: Double = 1
    /// Radians.
    var rotation: Double = 0
    /// The nuclei layer's own extra pulse.
    var nucleus: Double = 1

    /// The rest pose: what every still frame draws.
    static let rest = TelosOrbPose()
    /// Seconds a live run takes to ease in.
    static let easeIn: Double = 1.0
    /// Seconds a burst takes to ease back out to the rest pose.
    static let easeOut: Double = 1.5

    /// Motion amplitude 0…1 at `elapsed` s into a live run: eases in over `easeIn`; a burst of `burst` s
    /// also eases back out over its last `easeOut` s and is exactly 0 at its end — so the still frame
    /// the clock rests on is the pose the burst finished in (no snap).
    static func envelope(elapsed t: Double, burst: Double?) -> Double {
        guard t.isFinite, t > 0 else { return 0 }
        var e = min(1, t / easeIn)
        if let burst {
            guard burst.isFinite, burst > 0 else { return 0 }
            e = min(e, max(0, (burst - t) / min(easeOut, burst / 2)))
        }
        return e * e * (3 - 2 * e)
    }

    /// The pose at `elapsed` s: an anisotropic breath at the heart-pulse period (squash-and-stretch, not
    /// a uniform zoom), a slow sway that grows with stress, and the nuclei pulsing out of phase.
    static func at(elapsed t: Double, burst: Double?, pulsePeriod: Double, turbulence: Double) -> TelosOrbPose {
        let env = envelope(elapsed: t, burst: burst)
        guard env > 0 else { return .rest }
        let turb = min(max(turbulence.isFinite ? turbulence : 0, 0), 1)
        let period = pulsePeriod.isFinite ? max(pulsePeriod, 0.5) : TelosOrbAppearance.neutralPulsePeriod
        let phase = 2 * Double.pi * t / period
        let swayRate = 0.30 + 0.35 * turb
        return TelosOrbPose(
            scaleX: 1 + env * (0.024 * sin(phase) + 0.010 * turb * sin(1.7 * t + 0.4)),
            scaleY: 1 + env * (0.024 * sin(phase + 0.9) + 0.010 * turb * sin(1.3 * t + 2.1)),
            rotation: env * (0.03 + 0.05 * turb) * sin(swayRate * t),
            nucleus: 1 + env * 0.04 * sin(phase + 1.8))
    }
}

// MARK: - Palette

/// The colours a form paints with: slot 0 = the core / tint, 1… = the five parts in
/// `TelosOrbPart.allCases` order (their `levelPartTint` hues).
struct TelosOrbPalette: Equatable {
    let colors: [Color]
    /// The core gradient's outer colour.
    let shade: Color
    /// The membrane, orbit lines, orbit dots and shells.
    let accent: Color

    func color(_ index: Int) -> Color { colors.indices.contains(index) ? colors[index] : accent }

    static func make(appearance: TelosOrbAppearance, tint: TelosOrbTint) -> TelosOrbPalette {
        if appearance.isNeutral {
            return TelosOrbPalette(colors: [TelosColor.textSecondary]
                                       + TelosOrbPart.allCases.map { _ in TelosColor.textTertiary },
                                   shade: TelosColor.textTertiary, accent: TelosColor.textSecondary)
        }
        return TelosOrbPalette(colors: [tint.lit] + TelosOrbPart.allCases.map(\.color),
                               shade: tint.shade, accent: tint.lit)
    }
}

// MARK: - The view

public struct TelosOrb: View {
    public enum Style: Sendable {
        /// The Home centrepiece: two orbits with two travelling dots.
        case hero
        /// The other tabs' orb: one orbit, one dot, relatively larger dots.
        case compact
    }

    /// When the ambient frame clock may run (always further gated by `TelosFrameGate`).
    public enum Clock: Equatable, Sendable {
        /// Breathing + orbit dots while visible.
        case whileVisible
        /// Run for `seconds` after appearing and after each data change, then rest on a still frame.
        case burst(seconds: Double)
        /// Never run (widgets, snapshots, lists, history thumbnails).
        case still
    }

    /// The orb's frame-clock cap: 20 fps. The motion is slow (a breath is seconds long), and every frame
    /// only moves transforms, so 20 fps reads as smooth.
    public static let frameInterval: Double = TelosFrameGate.clampedInterval(1.0 / 20.0)

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
    /// Live time counts from here, so a clock that resumes starts from the pose it rested in.
    @State private var liveEpoch = Date()
    /// Orbit-dot time banked by earlier live runs, so the dots resume where they stopped (no jump back).
    @State private var restTime: Double = 0

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

    /// The burst length the motion eases out within, or nil for an open-ended clock.
    private var burstEnvelope: Double? {
        if case .burst(let seconds) = clock { return max(0, seconds) }
        return nil
    }

    private var target: TelosOrbAnimatedValues { TelosOrbAnimatedValues(appearance) }

    public var body: some View {
        let live = mode == .live
        let values = shown ?? target
        TelosOrbLayer(size: values.size, brightness: values.brightness, turbulence: values.turbulence,
                      density: values.density, appearance: appearance,
                      palette: TelosOrbPalette.make(appearance: appearance, tint: tint),
                      style: style, live: live, epoch: liveEpoch, restTime: restTime, burst: burstEnvelope)
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
            if isLive {
                liveEpoch = Date()
            } else {
                restTime += max(0, Date().timeIntervalSince(liveEpoch))
            }
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

/// What the rasterised layers depend on. Their `Equatable` conformance compares only this, so a frame
/// tick (which changes nothing here) never redraws them.
struct TelosOrbDrawKey: Equatable {
    let size: Double
    let brightness: Double
    let turbulence: Double
    let density: Double
    let appearance: TelosOrbAppearance
    let style: TelosOrb.Style
    let palette: TelosOrbPalette
}

/// The host. `Animatable`, so a data change interpolates the form for the duration of the `flow` spring
/// only (the form is rebuilt per animation frame then, and never otherwise).
struct TelosOrbLayer: View, Animatable {
    var size: Double
    var brightness: Double
    var turbulence: Double
    var density: Double
    let appearance: TelosOrbAppearance
    let palette: TelosOrbPalette
    let style: TelosOrb.Style
    let live: Bool
    let epoch: Date
    let restTime: Double
    let burst: Double?

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
        let form = TelosOrbGeometry.form(appearance: appearance, turbulence: turbulence, density: density,
                                         style: style)
        let key = TelosOrbDrawKey(size: size, brightness: brightness, turbulence: turbulence, density: density,
                                  appearance: appearance, style: style, palette: palette)
        let live = self.live
        let epoch = self.epoch
        let restTime = self.restTime
        let burst = self.burst
        let pulsePeriod = appearance.pulsePeriod
        let sway = turbulence
        let accent = palette.accent
        let hero = style == .hero
        let orbitSpeed = appearance.orbitSpeed
        GeometryReader { geo in
            let dim = Double(min(geo.size.width, geo.size.height))
            let orbits = TelosOrbRenderer.orbitSpecs(hero: hero, dim: dim, speed: orbitSpeed)
            TimelineView(.animation(minimumInterval: TelosOrb.frameInterval, paused: !live)) { timeline in
                let elapsed: Double = live ? max(0, timeline.date.timeIntervalSince(epoch)) : 0
                let pose = TelosOrbPose.at(elapsed: elapsed, burst: burst, pulsePeriod: pulsePeriod,
                                           turbulence: sway)
                let dots = orbits.map { $0.dot(center: .zero, time: restTime + elapsed) }
                ZStack {
                    TelosOrbBackdropCanvas(key: key).equatable()
                    TelosOrbDots(dots: dots, front: false, color: accent)
                    TelosOrbBodyCanvas(key: key, form: form).equatable()
                        .scaleEffect(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))
                        .rotationEffect(.radians(pose.rotation))
                    TelosOrbNucleiCanvas(key: key, form: form).equatable()
                        .scaleEffect(x: CGFloat(pose.scaleX * pose.nucleus), y: CGFloat(pose.scaleY * pose.nucleus))
                        .rotationEffect(.radians(pose.rotation * 1.3))
                    TelosOrbDots(dots: dots, front: true, color: accent)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// The orbit dots: plain views moved by `offset` — no canvas redraw. Each dot is drawn in both slots
/// (behind / in front of the blob) and shown in the one its position calls for.
private struct TelosOrbDots: View {
    let dots: [(CGPoint, Bool)]
    let front: Bool
    let color: Color

    var body: some View {
        ZStack {
            ForEach(dots.indices, id: \.self) { i in
                TelosOrbDot(color: color, strength: front ? 1 : 0.4)
                    .offset(x: dots[i].0.x, y: dots[i].0.y)
                    .opacity(dots[i].1 == front ? 1 : 0)
            }
        }
    }
}

/// A plain small dot — no halo, no highlight.
private struct TelosOrbDot: View {
    let color: Color
    let strength: Double

    var body: some View {
        Circle().fill(color.opacity(0.75 * strength)).frame(width: 4, height: 4)
    }
}

/// Orbit lines and growth shells — static; redrawn only when the key changes.
private struct TelosOrbBackdropCanvas: View, Equatable {
    let key: TelosOrbDrawKey

    static func == (lhs: TelosOrbBackdropCanvas, rhs: TelosOrbBackdropCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        let key = self.key
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            TelosOrbRenderer.drawBackdrop(context: context, size: size, key: key)
        }
    }
}

/// The body: fills, lobes, dots, membrane — rasterised once per key, then only transformed.
private struct TelosOrbBodyCanvas: View, Equatable {
    let key: TelosOrbDrawKey
    let form: TelosOrbForm

    static func == (lhs: TelosOrbBodyCanvas, rhs: TelosOrbBodyCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        let key = self.key
        let form = self.form
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            TelosOrbRenderer.drawBody(context: context, size: size, form: form, key: key)
        }
    }
}

/// The veins and nuclei — their own layer, so they can pulse out of phase with the membrane.
private struct TelosOrbNucleiCanvas: View, Equatable {
    let key: TelosOrbDrawKey
    let form: TelosOrbForm

    static func == (lhs: TelosOrbNucleiCanvas, rhs: TelosOrbNucleiCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        let key = self.key
        let form = self.form
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            TelosOrbRenderer.drawNuclei(context: context, size: size, form: form, key: key)
        }
    }
}

// MARK: - Renderer

enum TelosOrbRenderer {

    /// Pixel radius of the size-1 blob as a fraction of the frame's shorter side.
    static let baseRadius: Double = 0.23
    /// Dot opacity per tier (muted: data tints, not lights).
    static let tierAlpha: [Double] = [0.28, 0.46, 0.70]

    /// Pixels per unit for a frame and a size.
    static func unitScale(dim: Double, size: Double) -> Double { dim * baseRadius * size }

    /// A copy of `context` with the origin at the centre and one unit = the blob's radius, or nil when
    /// the frame is too small to draw.
    private static func unitContext(_ context: GraphicsContext, size: CGSize, scale: Double)
        -> (context: GraphicsContext, px: Double)? {
        let dim = Double(min(size.width, size.height))
        guard dim > 8 else { return nil }
        let r = unitScale(dim: dim, size: scale)
        guard r.isFinite, r > 0.5 else { return nil }
        var ctx = context
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: CGFloat(r), y: CGFloat(r))
        return (ctx, 1 / r)
    }

    private static func disc(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    static func drawBody(context: GraphicsContext, size: CGSize, form: TelosOrbForm, key: TelosOrbDrawKey) {
        guard let unit = unitContext(context, size: size, scale: key.size) else { return }
        let ctx = unit.context
        let px = unit.px
        let b = key.brightness
        let palette = key.palette
        let core = palette.color(0)

        // 1. The body: a matte tissue fill inside the membrane (a gentle falloff, never a glow).
        ctx.fill(form.membrane, with: .radialGradient(
            Gradient(colors: [core.opacity(0.14 * b), palette.shade.opacity(0.08 * b), palette.shade.opacity(0.06 * b)]),
            center: .zero, startRadius: 0, endRadius: CGFloat(max(form.extent, 0.1))))

        // 2. The organs: muted tints with a faint inner wall, clipped to the membrane.
        var inner = ctx
        inner.clip(to: form.membrane)
        for lobe in form.lobes.dropFirst() {
            let ink = palette.color(lobe.colorIndex)
            inner.fill(disc(lobe.x, lobe.y, lobe.r), with: .radialGradient(
                Gradient(colors: [ink.opacity(0.18 * b), ink.opacity(0.11 * b), ink.opacity(0.05 * b)]),
                center: CGPoint(x: lobe.x, y: lobe.y), startRadius: 0, endRadius: CGFloat(lobe.r)))
            inner.stroke(disc(lobe.x, lobe.y, max(lobe.r - 2 * px, 0)),
                         with: .color(ink.opacity(0.22 * b)), lineWidth: CGFloat(0.7 * px))
        }

        // 3. The dots: ≤ 18 batched fills.
        for batch in form.dots {
            let alpha = tierAlpha[min(max(batch.tier, 0), tierAlpha.count - 1)]
            ctx.fill(batch.path, with: .color(palette.color(batch.colorIndex).opacity(alpha * b)))
        }

        // 4. The membrane: one crisp hairline (no halo); fainter while still assembling.
        let asm = form.assembly
        ctx.stroke(form.membrane, with: .color(palette.accent.opacity(0.42 * b * asm)), lineWidth: CGFloat(0.9 * px))
    }

    static func drawNuclei(context: GraphicsContext, size: CGSize, form: TelosOrbForm, key: TelosOrbDrawKey) {
        guard let unit = unitContext(context, size: size, scale: key.size) else { return }
        let ctx = unit.context
        let px = unit.px
        let b = key.brightness
        let palette = key.palette
        for batch in form.veins {
            ctx.stroke(batch.path, with: .color(palette.color(batch.colorIndex).opacity(0.38 * b)),
                       lineWidth: CGFloat(0.8 * px))
        }
        // Nuclei: plain matte discs with a thin wall — no halo, no highlight.
        for (i, lobe) in form.lobes.enumerated() {
            let r = TelosOrbGeometry.nucleusRadius(lobe, isCore: i == 0)
            let ink = palette.color(lobe.colorIndex)
            ctx.fill(disc(lobe.x, lobe.y, r), with: .color(ink.opacity(0.55 * b)))
            ctx.stroke(disc(lobe.x, lobe.y, r * 1.7), with: .color(ink.opacity(0.26 * b)), lineWidth: CGFloat(0.7 * px))
        }
    }

    static func drawBackdrop(context: GraphicsContext, size: CGSize, key: TelosOrbDrawKey) {
        let dim = Double(min(size.width, size.height))
        guard dim > 8 else { return }
        let ctx = context
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = key.palette.accent
        let hero = key.style == .hero

        // 1. The thin orbit lines: one hairline each, no halo.
        for o in orbitSpecs(hero: hero, dim: dim, speed: key.appearance.orbitSpeed) {
            ctx.stroke(o.path(center: c), with: .color(accent.opacity(0.26)), lineWidth: 0.7)
        }

        // 2. Growth shells: each growth unit past the reference range adds one tilted dotted shell (the
        //    Level is unbounded — the orb grows outward instead of clipping). A partial unit draws its
        //    shell at that fraction's opacity.
        let shells = key.appearance.outerShells
        if shells > 0 {
            let count = Int(shells.rounded(.up))
            for k in 0..<count {
                let strength = min(1, shells - Double(k))
                let rx = dim * (0.40 + 0.035 * Double(k))
                let ry = rx * 0.34
                let rot = (30 + 47 * Double(k)) * Double.pi / 180
                var shell = Path()
                let n = 56
                for j in 0..<n {
                    let a0 = Double(j) / Double(n) * 2 * Double.pi
                    let ex = rx * cos(a0), ey = ry * sin(a0)
                    let x = Double(c.x) + ex * cos(rot) - ey * sin(rot)
                    let y = Double(c.y) + ex * sin(rot) + ey * cos(rot)
                    shell.addEllipse(in: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8))
                }
                ctx.fill(shell, with: .color(accent.opacity(0.55 * strength)))
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
        let s = max(speed.isFinite ? speed : TelosOrbAppearance.neutralOrbitSpeed, 0.05)
        if hero {
            return [
                OrbitSpec(rx: dim * 0.46, ry: dim * 0.14, rotation: -16 * Double.pi / 180, period: 16 / s, phase: 0.6),
                OrbitSpec(rx: dim * 0.40, ry: dim * 0.21, rotation: 28 * Double.pi / 180, period: 23 / s, phase: 3.1),
            ]
        }
        return [OrbitSpec(rx: dim * 0.44, ry: dim * 0.13, rotation: -14 * Double.pi / 180, period: 18 / s, phase: 0.9)]
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
