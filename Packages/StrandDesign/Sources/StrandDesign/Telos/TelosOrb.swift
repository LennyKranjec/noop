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
//                                     orbitDots = ⌊level / 10⌋            one orbiting dot per 10 Level
//                                                                         points, NO cap: 2 orbits, a 3rd
//                                                                         past 12 dots; past 30 they pack
//                                                                         smaller instead of stopping.
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
//   lobes instead of part lobes, and NO orbiting dots without a Level). With EVERY input missing the
//   orb is the neutral dim still orb: desaturated grey, brightness 0.42, and NO motion at all. The exact numbers are always printed beside
//   the orb, so it is hidden from VoiceOver (it never replaces a numeral).
//
// THE PICTURE (unit space, blob radius ≈ 1 = `baseRadius` × the frame × size)
//   A core disc plus one disc per part at a fixed angle (sleep upper-left, focus upper-right, heart right,
//   muscle below, lungs left). The membrane is their SMOOTH union in polar form (a metaball-like smooth
//   maximum per direction, so core and lobes flow into each other), box-smoothed, with the cell's own
//   seeded low-frequency, asymmetric irregularity, then rippled by stress. Lobe tints fade to nothing at
//   their rims (no circle seams); ≤ 150 dots (an unevenly spaced, uneven-sized membrane skin + interior
//   stipple) coloured by the lobe they sit in; veins + nuclei on their own layer. Each part lobe large
//   enough carries the part's SF Symbol (`TelosOrbPart.symbolName`, ≥ 10 pt, flat light neutral on a
//   matte plate) so the organs are recognisable; smaller lobes and thumbnails keep a plain nucleus.
//
// MOTION — NO FRAME CLOCK, ONLY ANIMATED TRANSFORMS (owner: "a bit laggy")
//   • All geometry is built ONCE per data change (`TelosOrbForm.make`) and rasterised ONCE into four
//     `Equatable` canvases: backdrop (orbit lines, growth shells), core (tissue, dotted skin, membrane),
//     lobes (soft organ tints, stipple) and nuclei (veins, nuclei, part icons).
//   • Motion is ONE `@State` time value animated over a run (ease-in-out for a burst). Every
//     moving part reads it through a `GeometryEffect` — the body's anisotropic breath (the heart pulse,
//     squash-and-stretch) and sway; the lobes' drift and swell against the core (masked by the
//     membrane, so they stay inside it); each orbiting dot's travel along its ellipse (a translation of
//     a tiny pre-rendered dot; a static half-plane mask per orbit decides front / behind). SwiftUI's
//     animation engine interpolates at the display's own rate and calls those effects — a few sines —
//     with NO view body re-evaluated and NO canvas redrawn. There is no TimelineView.
//   • A `.burst(seconds:)` run starts on appear and on each data change (a change mid-run extends it,
//     no jump), eases in and eases back to the rest pose at its end (`TelosOrbPose.envelope`) — the
//     dots slow and hold where they are. It stops at once (rest pose) when the orb leaves the screen,
//     scrolls away, is covered, or Reduce Motion / Low Power / "Reduce motion in NOOP" apply. The
//     neutral orb and `.still` never move. `.whileVisible` chains open-ended runs while allowed.
//   • Value changes (size, brightness, turbulence, density) flow with `TelosMotion.flow` through an
//     `Animatable` layer — only while the value changes; instant under Reduce Motion.
//   • `TelosOrb` is `Equatable`: at `.equatable()` call sites a parent's unrelated state change skips it.
//
// COST (§2.1 rule 8): four canvases rendered asynchronously, each drawn once per data change; ≤ 150
// dots batched by colour × 3 opacity tiers; per display frame only transforms (≤ 120 moving dots); no
// blur, no shadow, no glow, no material, no drawingGroup.

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

    /// The part's SF Symbol — drawn on its lobe and used by every Level surface that names the part
    /// (the Level radar's set; the heart filled so it reads on the blob).
    public var symbolName: String {
        switch self {
        case .sleep:  return "moon.fill"
        case .heart:  return "heart.fill"
        case .lungs:  return "wind"
        case .muscle: return "figure.strengthtraining.traditional"
        case .focus:  return "bolt.fill"
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
    /// How many dots orbit the blob: one per 10 Level points (⌊level / 10⌋), unbounded; 0 without a Level.
    public let orbitDots: Int
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
    /// Level points per orbiting dot.
    public static let levelPerOrbitDot: Double = 10

    /// ⌊level / 10⌋ orbiting dots — no maximum (only an overflow guard for absurd values); 0 for a
    /// negative or non-finite Level.
    public static func orbitDots(level: Double) -> Int {
        guard level.isFinite, level > 0 else { return 0 }
        return Int(min((level / levelPerOrbitDot).rounded(.down), Double(Int.max / 4)))
    }

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
                                  orbitSpeed: orbit,
                                  orbitDots: growthValue == nil ? 0 : orbitDots(level: inputs.level ?? 0),
                                  assembly: assemblyFactor,
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
    /// The membrane's dotted skin (drawn with the membrane), batched by colour × tier.
    let skinDots: [TelosOrbDotBatch]
    /// The interior stipple (drawn with the lobes, so it drifts with them), batched by colour × tier.
    let interiorDots: [TelosOrbDotBatch]
    /// Every dot batch (≤ `TelosOrbGeometry.maxDots` dots in all).
    var dots: [TelosOrbDotBatch] { skinDots + interiorDots }
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

    /// Smooth maximum (polynomial smooth-union): equal to `max(a, b)` when they differ by more than `k`,
    /// and a rounded blend in between — the metaball-like joint between two lobes, with no crease.
    static func smoothMax(_ a: Double, _ b: Double, k: Double) -> Double {
        let h = max(k - abs(a - b), 0) / k
        return max(a, b) + h * h * k * 0.25
    }

    /// The membrane's own irregularity (seeded, low-frequency, asymmetric): the same slightly lopsided
    /// cell on every launch, present even when calm — a living shape, not a geometric one.
    static func irregularity(angle a: Double) -> Double {
        0.034 * sin(2 * a + 0.9) + 0.024 * sin(3 * a + 4.1) + 0.014 * sin(5 * a + 2.2)
    }

    /// The membrane: the lobes' SMOOTH union in polar form (`smoothMax`, so core and lobes flow into each
    /// other like metaballs), box-smoothed, given the cell's own low-frequency irregularity, then rippled
    /// by stress (`turbulence` 0…1). `owner` names the lobe that reaches furthest in each direction (the
    /// membrane dot there takes its colour).
    static func outline(lobes: [TelosOrbLobe], turbulence: Double,
                        samples n: Int = outlineSamples) -> (radii: [Double], owner: [Int]) {
        guard n > 0, !lobes.isEmpty else { return ([], []) }
        var raw = [Double](repeating: 0, count: n)
        var owner = [Int](repeating: 0, count: n)
        for k in 0..<n {
            let a = angle(k, n)
            var best = 0.0
            var blended = 0.0
            var who = 0
            for (i, lobe) in lobes.enumerated() {
                guard let t = hit(angle: a, lobe: lobe) else { continue }
                blended = blended > 0 ? smoothMax(blended, t, k: 0.22) : t
                if t > best {
                    best = t
                    who = i
                }
            }
            raw[k] = blended
            owner[k] = who
        }
        var radii = raw
        for _ in 0..<2 {
            var next = radii
            for k in 0..<n {
                var sum = 0.0
                for j in -3...3 { sum += radii[((k + j) % n + n) % n] }
                next[k] = sum / 7
            }
            radii = next
        }
        let ripple = min(max(turbulence.isFinite ? turbulence : 0, 0), 1)
        for k in 0..<n {
            let a = angle(k, n)
            radii[k] *= 1 + irregularity(angle: a)
                + ripple * (0.05 * sin(6 * a + 0.7) + 0.028 * sin(11 * a + 2.3))
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

        var skinBatches: [Int: Path] = [:]
        var innerBatches: [Int: Path] = [:]
        var count = 0
        func add(_ x: Double, _ y: Double, radius: Double, colorIndex: Int, tier: Int, interior: Bool) {
            guard count < maxDots else { return }
            let key = colorIndex * tiers + min(max(tier, 0), tiers - 1)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            if interior {
                innerBatches[key, default: Path()].addEllipse(in: rect)
            } else {
                skinBatches[key, default: Path()].addEllipse(in: rect)
            }
            count += 1
        }

        // 1. The membrane's dotted skin, just inside the outline, coloured by the lobe underneath.
        var skin = TelosOrbRandom(seed: 0x7E105_5C)
        let m = membraneDotCount(style)
        for k in 0..<m {
            let jitter = skin.unit(), inset = skin.unit(), sizeU = skin.unit()
            let tierU = skin.unit(), rank = skin.unit(), scatter = skin.unit()
            guard n > 0, rank < keep else { continue }
            // Uneven spacing, depth and size: a living skin, not a bead chain.
            let ang = 2 * Double.pi * (Double(k) + 0.1 + 0.8 * jitter) / Double(m)
            let idx = ((Int((ang / (2 * Double.pi) * Double(n)).rounded()) % n) + n) % n
            let rho = radii[idx] * (0.99 - 0.06 * inset) * (1 + unassembled * 0.5 * scatter)
            let tier = tierU < 0.25 ? 0 : (tierU < 0.65 ? 1 : 2)
            add(rho * cos(ang), rho * sin(ang), radius: dotR * (0.6 + 0.85 * sizeU * sizeU),
                colorIndex: lobes[owner[idx]].colorIndex, tier: tier, interior: false)
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
                radius: dotR * (0.6 + 0.5 * sizeU), colorIndex: lobe.colorIndex, tier: tierU < 0.55 ? 0 : 1,
                interior: true)
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

        func batched(_ dict: [Int: Path]) -> [TelosOrbDotBatch] {
            dict.keys.sorted().map { key in
                TelosOrbDotBatch(colorIndex: key / tiers, tier: key % tiers, path: dict[key] ?? Path())
            }
        }
        let veins = veinPaths.keys.sorted().map { TelosOrbVeinBatch(colorIndex: $0, path: veinPaths[$0] ?? Path()) }
        return TelosOrbForm(lobes: lobes, outline: radii, membrane: membranePath(radii: radii),
                            extent: radii.max() ?? coreRadius, skinDots: batched(skinBatches),
                            interiorDots: batched(innerBatches), dotCount: count, veins: veins,
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
    /// The lobes' own extra pulse (organs swelling slightly out of phase with the membrane).
    var nucleus: Double = 1
    /// The lobes' slow drift relative to the core, as a fraction of the orb's frame, and a slight turn.
    var driftX: Double = 0
    var driftY: Double = 0
    var driftRotation: Double = 0

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
    /// a uniform zoom), a slow sway that grows with stress, the lobes pulsing out of phase and drifting
    /// slowly against the core (inside the membrane, which masks them).
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
            nucleus: 1 + env * 0.03 * sin(phase + 1.8),
            driftX: env * 0.010 * sin(0.21 * t + 1.1),
            driftY: env * 0.008 * sin(0.17 * t + 2.4),
            driftRotation: env * 0.03 * sin(0.13 * t + 0.5))
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

public struct TelosOrb: View, Equatable {
    public enum Style: Sendable {
        /// The Home centrepiece: two orbits (a third past 12 orbiting dots).
        case hero
        /// The other tabs' orb: one orbit (a second past 6 orbiting dots), relatively larger dots.
        case compact
    }

    /// When the orb may move (always further gated by `TelosFrameGate`).
    public enum Clock: Equatable, Sendable {
        /// Breathing + orbit dots while visible.
        case whileVisible
        /// Move for `seconds` after appearing and after each data change, then settle to the rest pose.
        case burst(seconds: Double)
        /// Never move (widgets, snapshots, lists, history thumbnails).
        case still
    }

    /// Kept for callers that quote it: the old frame-clock cap. The orb no longer runs a frame clock —
    /// its motion is ONE animated time value interpolated by SwiftUI's animation engine at the display's
    /// own rate, which only moves transforms (see the file header).
    public static let frameInterval: Double = TelosFrameGate.clampedInterval(1.0 / 20.0)

    /// The length of one `.whileVisible` run (restarted when it ends while still allowed).
    static let openRunSeconds: Double = 600

    private let appearance: TelosOrbAppearance
    private let tint: TelosOrbTint
    private let style: Style
    private let clock: Clock

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBackgroundCovered) private var covered
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var visible = false
    @State private var offscreen = false
    @State private var appearCount = 0
    /// The animated values actually drawn (nil until first appear — then posed without animation).
    @State private var shown: TelosOrbAnimatedValues? = nil
    /// THE MOTION: one time value (seconds), animated linearly over a run. Every moving part reads it
    /// through a `GeometryEffect`, so a frame re-evaluates no view body and redraws no canvas.
    @State private var clockValue: Double = 0
    /// The clock value where the current motion began (the pose eases in from here).
    @State private var motionStart: Double = 0
    /// The current run: from → to, started at `runStartedAt`.
    @State private var runFrom: Double = 0
    @State private var runTo: Double = 0
    @State private var runStartedAt = Date.distantPast
    /// Bumped per run, so a stale end-of-run callback never touches a newer run.
    @State private var runToken = 0

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

    /// Equal inputs → SwiftUI skips this view entirely (`.equatable()` at the call site), so a parent's
    /// unrelated state change never re-renders the orb.
    public static func == (lhs: TelosOrb, rhs: TelosOrb) -> Bool {
        lhs.appearance == rhs.appearance && lhs.tint == rhs.tint && lhs.style == rhs.style && lhs.clock == rhs.clock
    }

    /// Whether motion is allowed right now: requested, on screen, not scrolled away, not covered, not
    /// posed still (Reduce Motion ‖ Low Power ‖ "Reduce motion in NOOP"), and not the neutral orb.
    private var allowed: Bool {
        let requested: Bool
        switch clock {
        case .whileVisible, .burst: requested = true
        case .still: requested = false
        }
        return TelosFrameGate.mode(requested: requested && !appearance.isNeutral, visible: visible,
                                   offscreen: offscreen, covered: covered,
                                   poseStill: motion.poseStill(reduceMotion)) == .live
    }

    private var runSeconds: Double {
        switch clock {
        case .burst(let seconds): return max(0, seconds)
        case .whileVisible: return Self.openRunSeconds
        case .still: return 0
        }
    }

    /// The envelope's burst length (from `motionStart`), or nil for an open-ended clock.
    private var envelopeLength: Double? {
        if case .burst = clock { return max(0, runTo - motionStart) }
        return nil
    }

    private var target: TelosOrbAnimatedValues { TelosOrbAnimatedValues(appearance) }

    public var body: some View {
        let values = shown ?? target
        TelosOrbLayer(size: values.size, brightness: values.brightness, turbulence: values.turbulence,
                      density: values.density, appearance: appearance,
                      palette: TelosOrbPalette.make(appearance: appearance, tint: tint),
                      style: style, clock: clockValue,
                      motion: TelosOrbMotion(start: motionStart, burst: envelopeLength,
                                             pulsePeriod: appearance.pulsePeriod))
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            visible = true
            appearCount &+= 1
            if shown == nil { shown = target }
        }
        .onDisappear {
            visible = false
            stopRun()
        }
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
        // A burst (re)starts on each appear and each data change; an open clock whenever it may run.
        .onChangeCompat(of: BurstKey(appearance: appearance, appear: appearCount)) { _ in
            startRun()
        }
        .onChangeCompat(of: allowed) { isAllowed in
            if !isAllowed {
                stopRun()
            } else if case .whileVisible = clock {
                startRun()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the clock is now (the in-flight animation's estimated position).
    private func clockNow(_ now: Date) -> Double {
        let span = runTo - runFrom
        guard span > 0 else { return clockValue }
        return min(runTo, runFrom + max(0, now.timeIntervalSince(runStartedAt)))
    }

    private func isRunning(_ now: Date) -> Bool {
        runTo > runFrom && now.timeIntervalSince(runStartedAt) < runTo - runFrom
    }

    /// Start a run, or extend the one in flight (a data change mid-burst keeps the pose where it is and
    /// moves the ease-out to the new end — no jump).
    private func startRun() {
        guard allowed else { return }
        let seconds = runSeconds
        guard seconds > 0 else { return }
        let now = Date()
        let current = clockNow(now)
        if !isRunning(now) { motionStart = clockValue }
        runFrom = current
        runTo = current + seconds
        runStartedAt = now
        runToken &+= 1
        let token = runToken
        let end = runTo
        // A burst eases in and out, so the orbit dots accelerate from rest and slow back to rest; an open
        // run is linear.
        let curve: Animation
        if case .burst = clock {
            curve = .easeInOut(duration: seconds)
        } else {
            curve = .linear(duration: seconds)
        }
        withAnimation(curve) { clockValue = end }
        if case .whileVisible = clock {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                if runToken == token, allowed { startRun() }
            }
        }
    }

    /// Stop now: the clock jumps to its run's end (the rest pose; the dots hold there).
    private func stopRun() {
        guard isRunning(Date()) else { return }
        runToken &+= 1
        var tx = Transaction()
        tx.disablesAnimations = true
        let end = runTo
        withTransaction(tx) { clockValue = end + 1e-6 }
        runFrom = end
        runTo = end
        motionStart = end
    }

    /// A burst restarts on a data change AND on each appear.
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

/// What the rasterised layers depend on. Their `Equatable` conformance compares only this, so nothing
/// but a data change redraws them.
struct TelosOrbDrawKey: Equatable {
    let size: Double
    let brightness: Double
    let turbulence: Double
    let density: Double
    let appearance: TelosOrbAppearance
    let style: TelosOrb.Style
    let palette: TelosOrbPalette
}

/// The motion's fixed parameters for the current run (the moving part is the clock value).
struct TelosOrbMotion: Equatable {
    /// The clock value the motion eased in from.
    let start: Double
    /// Burst length from `start` (the pose is back at rest there), or nil for an open-ended run.
    let burst: Double?
    let pulsePeriod: Double
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
    /// The motion clock's MODEL value; the effects below receive it animated.
    let clock: Double
    let motion: TelosOrbMotion

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
        let hero = style == .hero
        let layout = TelosOrbRenderer.dotLayout(count: appearance.orbitDots, hero: hero)
        let movingDots = layout.drawn <= TelosOrbRenderer.maxMovingDots
        let breath = TelosOrbBreathEffect(clock: clock, motion: motion, turbulence: turbulence, layer: .body)
        let drift = TelosOrbBreathEffect(clock: clock, motion: motion, turbulence: turbulence, layer: .lobes)
        GeometryReader { geo in
            let dim = Double(min(geo.size.width, geo.size.height))
            let orbits = TelosOrbRenderer.orbitSpecs(hero: hero, dim: dim, speed: appearance.orbitSpeed,
                                                     count: layout.orbitCount)
            ZStack {
                TelosOrbBackdropCanvas(key: key).equatable()
                if movingDots {
                    TelosOrbDotsLayer(orbits: orbits, perOrbit: layout.perOrbit, clock: clock, front: false,
                                      color: palette.accent, diameter: layout.diameter)
                }
                // The body breathes as one; inside it the lobes (tints, stipple, veins, nuclei, icons)
                // drift and swell against the core, masked by the membrane so they never leave it.
                ZStack {
                    TelosOrbCoreCanvas(key: key, form: form).equatable()
                    ZStack {
                        TelosOrbLobesCanvas(key: key, form: form).equatable()
                        TelosOrbNucleiCanvas(key: key, form: form).equatable()
                    }
                    .modifier(drift)
                    .mask { TelosOrbMembraneShape(membrane: form.membrane, size: size) }
                }
                .modifier(breath)
                if movingDots {
                    TelosOrbDotsLayer(orbits: orbits, perOrbit: layout.perOrbit, clock: clock, front: true,
                                      color: palette.accent, diameter: layout.diameter)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// The membrane (unit space) placed in a frame exactly as the canvases draw it — the lobes' mask.
private struct TelosOrbMembraneShape: Shape {
    let membrane: Path
    let size: Double

    func path(in rect: CGRect) -> Path {
        let r = TelosOrbRenderer.unitScale(dim: Double(min(rect.width, rect.height)), size: size)
        guard r.isFinite, r > 0 else { return Path() }
        return membrane.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .scaledBy(x: CGFloat(r), y: CGFloat(r)))
    }
}

/// Breathing, sway and lobe drift as a transform of an already-rasterised layer. Its only animatable
/// input is the clock, so SwiftUI's animation engine calls `effectValue` per display frame — a few
/// sines — and nothing is re-rendered.
private struct TelosOrbBreathEffect: GeometryEffect {
    enum Layer { case body, lobes }

    var clock: Double
    let motion: TelosOrbMotion
    let turbulence: Double
    let layer: Layer

    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pose = TelosOrbPose.at(elapsed: clock - motion.start, burst: motion.burst,
                                   pulsePeriod: motion.pulsePeriod, turbulence: turbulence)
        guard pose != .rest else { return ProjectionTransform() }
        let cx = size.width / 2, cy = size.height / 2
        let dim = Double(min(size.width, size.height))
        let t: CGAffineTransform
        switch layer {
        case .body:
            t = CGAffineTransform(translationX: cx, y: cy)
                .rotated(by: CGFloat(pose.rotation))
                .scaledBy(x: CGFloat(pose.scaleX), y: CGFloat(pose.scaleY))
                .translatedBy(x: -cx, y: -cy)
        case .lobes:
            t = CGAffineTransform(translationX: cx + CGFloat(pose.driftX * dim), y: cy + CGFloat(pose.driftY * dim))
                .rotated(by: CGFloat(pose.driftRotation))
                .scaledBy(x: CGFloat(pose.nucleus), y: CGFloat(pose.nucleus))
                .translatedBy(x: -cx, y: -cy)
        }
        return ProjectionTransform(t)
    }
}

/// One orbiting dot's travel along its ellipse: a translation per display frame from the animated
/// clock — the dot itself stays a round, pre-rendered view.
private struct TelosOrbDotEffect: GeometryEffect {
    var clock: Double
    let spec: TelosOrbRenderer.OrbitSpec
    let offset: Double

    var animatableData: Double {
        get { clock }
        set { clock = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let (p, _) = spec.dot(center: .zero, time: clock, offset: offset)
        return ProjectionTransform(CGAffineTransform(translationX: p.x, y: p.y))
    }
}

/// The orbiting dots on one side of the blob. Behind: every dot, dim. In front: every dot, masked to the
/// front half of its (tilted) orbit — a static mask, so which dots show in front changes with no per-frame
/// logic.
private struct TelosOrbDotsLayer: View {
    let orbits: [TelosOrbRenderer.OrbitSpec]
    let perOrbit: [Int]
    let clock: Double
    let front: Bool
    let color: Color
    let diameter: CGFloat

    var body: some View {
        ZStack {
            ForEach(orbits.indices, id: \.self) { o in
                let n = o < perOrbit.count ? perOrbit[o] : 0
                ZStack {
                    ForEach(0..<n, id: \.self) { j in
                        Circle()
                            .fill(color.opacity(front ? 0.75 : 0.3))
                            .frame(width: diameter, height: diameter)
                            .modifier(TelosOrbDotEffect(clock: clock, spec: orbits[o],
                                                        offset: 2 * Double.pi * Double(j) / Double(max(n, 1))))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask { TelosOrbFrontHalf(rotation: orbits[o].rotation, whole: !front) }
            }
        }
    }
}

/// The half-plane in front of an orbit (below its tilted major axis), or everything when `whole`.
private struct TelosOrbFrontHalf: Shape {
    let rotation: Double
    let whole: Bool

    func path(in rect: CGRect) -> Path {
        guard !whole else { return Path(rect) }
        let reach = Double(max(rect.width, rect.height)) * 2
        return Path(CGRect(x: -reach, y: 0, width: reach * 2, height: reach))
            .applying(CGAffineTransform(rotationAngle: CGFloat(rotation))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

/// Orbit lines, growth shells (and dense resting dots) — static; redrawn only when the key changes.
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

/// The core: tissue fill, dotted skin, membrane — rasterised once per key, then only transformed.
private struct TelosOrbCoreCanvas: View, Equatable {
    let key: TelosOrbDrawKey
    let form: TelosOrbForm

    static func == (lhs: TelosOrbCoreCanvas, rhs: TelosOrbCoreCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        let key = self.key
        let form = self.form
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            TelosOrbRenderer.drawCore(context: context, size: size, form: form, key: key)
        }
    }
}

/// The organs: soft lobe tints and the interior stipple.
private struct TelosOrbLobesCanvas: View, Equatable {
    let key: TelosOrbDrawKey
    let form: TelosOrbForm

    static func == (lhs: TelosOrbLobesCanvas, rhs: TelosOrbLobesCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        let key = self.key
        let form = self.form
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            TelosOrbRenderer.drawLobes(context: context, size: size, form: form, key: key)
        }
    }
}

/// The veins, nuclei and part icons.
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
        -> (context: GraphicsContext, px: Double, pointsPerUnit: Double)? {
        let dim = Double(min(size.width, size.height))
        guard dim > 8 else { return nil }
        let r = unitScale(dim: dim, size: scale)
        guard r.isFinite, r > 0.5 else { return nil }
        var ctx = context
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.scaleBy(x: CGFloat(r), y: CGFloat(r))
        return (ctx, 1 / r, r)
    }

    private static func disc(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// The core: a matte tissue fill inside the membrane, the dotted skin, and the membrane hairline.
    static func drawCore(context: GraphicsContext, size: CGSize, form: TelosOrbForm, key: TelosOrbDrawKey) {
        guard let unit = unitContext(context, size: size, scale: key.size) else { return }
        let ctx = unit.context
        let px = unit.px
        let b = key.brightness
        let palette = key.palette
        let core = palette.color(0)

        // 1. The tissue: a gentle falloff, never a glow.
        ctx.fill(form.membrane, with: .radialGradient(
            Gradient(colors: [core.opacity(0.14 * b), palette.shade.opacity(0.08 * b), palette.shade.opacity(0.06 * b)]),
            center: .zero, startRadius: 0, endRadius: CGFloat(max(form.extent, 0.1))))

        // 2. The dotted skin.
        for batch in form.skinDots {
            let alpha = tierAlpha[min(max(batch.tier, 0), tierAlpha.count - 1)]
            ctx.fill(batch.path, with: .color(palette.color(batch.colorIndex).opacity(alpha * b)))
        }

        // 3. The membrane: one crisp hairline (no halo); fainter while still assembling.
        let asm = form.assembly
        ctx.stroke(form.membrane, with: .color(palette.accent.opacity(0.42 * b * asm)), lineWidth: CGFloat(0.9 * px))
    }

    /// The organs: each lobe a soft tint that fades to nothing at its rim (no circle seam — the lobes
    /// melt into the core like metaballs; the membrane mask trims them), plus the interior stipple.
    static func drawLobes(context: GraphicsContext, size: CGSize, form: TelosOrbForm, key: TelosOrbDrawKey) {
        guard let unit = unitContext(context, size: size, scale: key.size) else { return }
        let ctx = unit.context
        let b = key.brightness
        let palette = key.palette
        for lobe in form.lobes.dropFirst() {
            let ink = palette.color(lobe.colorIndex)
            let reach = lobe.r * 1.15
            ctx.fill(disc(lobe.x, lobe.y, reach), with: .radialGradient(
                Gradient(stops: [
                    .init(color: ink.opacity(0.20 * b), location: 0),
                    .init(color: ink.opacity(0.13 * b), location: 0.55),
                    .init(color: ink.opacity(0), location: 1),
                ]),
                center: CGPoint(x: lobe.x, y: lobe.y), startRadius: 0, endRadius: CGFloat(reach)))
        }
        for batch in form.interiorDots {
            let alpha = tierAlpha[min(max(batch.tier, 0), tierAlpha.count - 1)]
            ctx.fill(batch.path, with: .color(palette.color(batch.colorIndex).opacity(alpha * b)))
        }
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
        // Nuclei: plain matte discs with a thin wall — no halo, no highlight. A part lobe big enough to hold
        // its glyph legibly carries the part's SF Symbol on a matte plate instead (flat, light neutral,
        // no glow), drawn here once per data change — so it breathes and sways with the layer for free.
        let pointsPerUnit = unit.pointsPerUnit
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        for (i, lobe) in form.lobes.enumerated() {
            let ink = palette.color(lobe.colorIndex)
            if let part = lobe.part, let side = glyphSide(lobeRadiusPoints: lobe.r * pointsPerUnit) {
                let plate = Double(side) * 0.78 / pointsPerUnit
                ctx.fill(disc(lobe.x, lobe.y, plate), with: .color(ink.opacity(0.34 * b)))
                ctx.stroke(disc(lobe.x, lobe.y, plate), with: .color(ink.opacity(0.45 * b)), lineWidth: CGFloat(0.7 * px))
                var symbol = context.resolve(Image(systemName: part.symbolName))
                symbol.shading = .color(TelosColor.textPrimary.opacity(0.9))
                let natural = symbol.size
                let fit = side / max(max(natural.width, natural.height), 1)
                let w = natural.width * fit, h = natural.height * fit
                let at = CGPoint(x: centre.x + CGFloat(lobe.x * pointsPerUnit), y: centre.y + CGFloat(lobe.y * pointsPerUnit))
                context.draw(symbol, in: CGRect(x: at.x - w / 2, y: at.y - h / 2, width: w, height: h))
                continue
            }
            let r = TelosOrbGeometry.nucleusRadius(lobe, isCore: i == 0)
            ctx.fill(disc(lobe.x, lobe.y, r), with: .color(ink.opacity(0.55 * b)))
            ctx.stroke(disc(lobe.x, lobe.y, r * 1.7), with: .color(ink.opacity(0.26 * b)), lineWidth: CGFloat(0.7 * px))
        }
    }

    /// Smallest legible lobe glyph, in points.
    static let minGlyphSide: CGFloat = 10
    /// Largest lobe glyph, in points (it labels the organ; it must not fill it).
    static let maxGlyphSide: CGFloat = 20

    /// The glyph's side for a lobe of `lobeRadiusPoints` on screen: 60 % of the radius, capped at
    /// `maxGlyphSide`; nil (no glyph, the plain nucleus instead) when that is under `minGlyphSide` — a
    /// small lobe or a small orb (the history thumbnails) never carries an illegible icon.
    static func glyphSide(lobeRadiusPoints r: Double) -> CGFloat? {
        guard r.isFinite, r > 0 else { return nil }
        let side = CGFloat(r * 0.6)
        return side >= minGlyphSide ? min(side, maxGlyphSide) : nil
    }

    static func drawBackdrop(context: GraphicsContext, size: CGSize, key: TelosOrbDrawKey) {
        let dim = Double(min(size.width, size.height))
        guard dim > 8 else { return }
        let ctx = context
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = key.palette.accent
        let hero = key.style == .hero

        // 1. The thin orbit lines: one hairline each, no halo (a third appears once the dots need it).
        let layout = dotLayout(count: key.appearance.orbitDots, hero: hero)
        let orbits = orbitSpecs(hero: hero, dim: dim, speed: key.appearance.orbitSpeed, count: layout.orbitCount)
        for o in orbits {
            ctx.stroke(o.path(center: c), with: .color(accent.opacity(0.26)), lineWidth: 0.7)
        }
        // A very high Level: more dots than are worth moving one by one — they rest here as dotted bands
        // (evenly spaced, so travel would barely show anyway).
        if layout.drawn > maxMovingDots {
            var band = Path()
            let d = layout.diameter
            for (p, _) in orbitDotPositions(orbits: orbits, perOrbit: layout.perOrbit, center: c, time: 0) {
                band.addEllipse(in: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d))
            }
            ctx.fill(band, with: .color(accent.opacity(0.55)))
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
        func dot(center c: CGPoint, time t: Double, offset: Double = 0) -> (CGPoint, Bool) {
            let a = phase + offset + (period > 0 ? t * 2 * Double.pi / period : 0)
            let ex = rx * cos(a), ey = ry * sin(a)
            let x = ex * cos(rotation) - ey * sin(rotation)
            let y = ex * sin(rotation) + ey * cos(rotation)
            return (CGPoint(x: Double(c.x) + x, y: Double(c.y) + y), sin(a) > 0)
        }
    }

    /// The orbits; `speed` (the effort ratio mapping) scales the dots' angular speed. `count` asks for
    /// more than the style's base orbits (hero 2 → 3, compact 1 → 2) when the dots need the room.
    static func orbitSpecs(hero: Bool, dim: Double, speed: Double, count: Int = 0) -> [OrbitSpec] {
        let s = max(speed.isFinite ? speed : TelosOrbAppearance.neutralOrbitSpeed, 0.05)
        let all: [OrbitSpec]
        let base: Int
        if hero {
            all = [
                OrbitSpec(rx: dim * 0.46, ry: dim * 0.14, rotation: -16 * Double.pi / 180, period: 16 / s, phase: 0.6),
                OrbitSpec(rx: dim * 0.40, ry: dim * 0.21, rotation: 28 * Double.pi / 180, period: 23 / s, phase: 3.1),
                OrbitSpec(rx: dim * 0.35, ry: dim * 0.27, rotation: -52 * Double.pi / 180, period: 29 / s, phase: 5.0),
            ]
            base = 2
        } else {
            all = [
                OrbitSpec(rx: dim * 0.44, ry: dim * 0.13, rotation: -14 * Double.pi / 180, period: 18 / s, phase: 0.9),
                OrbitSpec(rx: dim * 0.38, ry: dim * 0.21, rotation: 32 * Double.pi / 180, period: 25 / s, phase: 2.7),
            ]
            base = 1
        }
        return Array(all.prefix(min(max(base, count), all.count)))
    }

    /// How the orbiting dots are laid out.
    struct DotLayout: Equatable {
        /// Orbits in use (hero 2, or 3 past 12 dots; compact 1, or 2 past 6).
        let orbitCount: Int
        /// Dots per orbit, spread as evenly as the count allows.
        let perOrbit: [Int]
        /// Dot diameter in points: full size up to 30 dots, then smaller as they pack (never below 1.2).
        let diameter: CGFloat
        /// Dots actually drawn.
        let drawn: Int
    }

    /// Past this many dots they pack smaller instead of stopping.
    static let denseDotsAbove = 30
    /// Up to this many dots travel (each a tiny pre-rendered view moved by a transform); beyond it (a
    /// Level past 1,200) they rest as dotted bands on the backdrop.
    static let maxMovingDots = 120
    /// Past this many (a Level of 6,000) the orbits are solid dotted bands at the smallest dot size —
    /// the screen's resolution, not the data, is the limit; the explainer prints the exact count.
    static let maxDrawnDots = 600

    static func dotLayout(count: Int, hero: Bool) -> DotLayout {
        let n = max(0, count)
        let orbitCount = hero ? (n > 12 ? 3 : 2) : (n > 6 ? 2 : 1)
        let drawn = min(n, maxDrawnDots)
        let perOrbit = (0..<orbitCount).map { o in drawn / orbitCount + (o < drawn % orbitCount ? 1 : 0) }
        let full: Double = hero ? 4 : 3
        let diameter = n <= denseDotsAbove ? full : max(1.2, full * (Double(denseDotsAbove) / Double(n)).squareRoot())
        return DotLayout(orbitCount: orbitCount, perOrbit: perOrbit, diameter: CGFloat(diameter), drawn: drawn)
    }

    /// Every dot's position at time `t`, evenly spaced around its orbit, and whether it is in front.
    static func orbitDotPositions(orbits: [OrbitSpec], perOrbit: [Int], center: CGPoint,
                                  time t: Double) -> [(CGPoint, Bool)] {
        var out: [(CGPoint, Bool)] = []
        for (o, spec) in orbits.enumerated() where o < perOrbit.count && perOrbit[o] > 0 {
            let n = perOrbit[o]
            for j in 0..<n {
                out.append(spec.dot(center: center, time: t, offset: 2 * Double.pi * Double(j) / Double(n)))
            }
        }
        return out
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
