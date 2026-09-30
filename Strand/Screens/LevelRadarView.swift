import SwiftUI
import StrandAnalytics
import StrandDesign

// LevelRadarView.swift — the level, drawn as its own five parts.
//
// SwiftUI twin of the Android `LevelRadar` / `LevelOverlayBar`. Same geometry, same constants, same
// behaviour: a pentagon with one vertex per weighted part, each pulled out from the centre by that
// part's score, the level counting up in the middle, and a pentagon plate under it.
//
// THE AXES ARE NOT WEIGHTED. Each vertex runs 0–100 on the part's own score, so the shape says where
// the wearer stands on each; the WEIGHTS are what turn those into the number in the middle. Scaling the
// axes by weight too would have drawn lungs as permanently stunted at 0.07 and read as a deficiency
// rather than as a small term.
//
// A PART WITH NO DATA IS A HOLLOW VERTEX AT THE CENTRE ON A DASHED SPOKE, its glyph dimmed. Not at some
// middle default: an unmeasured part is a hole in the shape, and filling it in would draw a body we did
// not measure.
//
// TELOS 2.0 (§5.6, FRAME) + DECISION 19 (clinical restraint): the plate is `surfaceRaised` with the `raised`
// elevation; the web is a crisp NEUTRAL line over a whisper fill (no green, no halo stroke); each measured
// vertex carries a dot in its part's identity colour (colour is for data); the personal best is a thin
// dashed `bestGold` line — the one flat gold mark. The level counts up with ONE
// `Animatable` numeral (no dispatch queue), posed at its value under Reduce Motion / Low Power / quiet
// motion. THE LEVEL IS UNBOUNDED (decision 9): a part past the plate's reach shrinks the whole scale — the
// wearer's own-100 ring included — so the shape stays honest instead of clipping at the edge.
//
// COST (§2.1 rule 8): one static `Canvas` redrawn when the breakdown or the reveal changes; the reveal and
// the count-up animate for 0.9 s on open / on a new level, then rest. Nothing loops.

/// The five axes, in the order they are drawn: clockwise from the top.
private let radarParts: [LevelPart] = [.sleep, .heart, .lungs, .muscle, .focus]

/// How long the count-up and the web reveal take. Long enough to read, short enough not to wait on.
private let levelSlotSeconds: Double = 0.9

/// Where the glyphs sit, as a fraction of the box — just inside the plate's corners.
private let glyphRadiusFraction: CGFloat = 0.37

/// How far past the wearer's own 100 a vertex may reach before the scale shrinks to keep it on the plate.
private let radarReach: Double = 1.25

/// A pentagon, point-up, built from the same vertex maths the axes use.
///
/// Shared by the plate and the grid so the two cannot drift: a plate rotated a few degrees off the
/// shape it carries looks like a mistake nobody can name.
struct PentagonShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for i in radarParts.indices {
            let point = radarVertex(centre: centre, radius: radius, index: i)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Vertex `index` of five, starting at the top and going clockwise.
private func radarVertex(centre: CGPoint, radius: CGFloat, index: Int) -> CGPoint {
    let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(radarParts.count)
    return CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
}

/// The divisor that keeps every vertex on the plate: 1 while all fractions fit inside the reach (1.25 × the
/// wearer's own 100), otherwise the largest fraction over the reach. Pure; never below 1 — the scale only
/// ever shrinks, it never clips.
func levelRadarScaleDivisor(_ fractions: [Double]) -> Double {
    let top = fractions.filter { $0.isFinite }.max() ?? 0
    return max(1, top / radarReach)
}

/// One pentagon, the level in its middle.
struct LevelRadarView: View {
    let breakdown: LevelBreakdown?
    let diameter: CGFloat
    /// Flipped once per app launch by the shell; changing it re-runs the count-up.
    let countUpKey: Int

    /// The best each part has ever scored, 0–100 per part.
    ///
    /// Drawn in GOLD around the live web, so the shape says not only where the wearer is but how far
    /// that is from their OWN best — which is the only comparison this app is willing to draw. Absent
    /// (the default) it is not drawn at all: a personal best needs history, and an invented ceiling
    /// would be a target nobody set.
    var best: [LevelPart: Double]? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    @State private var reveal: Double = 0
    @State private var shown: Double = 0

    private var level: Double? { breakdown?.level }

    var body: some View {
        ZStack {
            PentagonShape()
                .fill(TelosColor.surfaceRaised)
                .overlay(PentagonShape().stroke(TelosColor.glassEdge, lineWidth: TelosStroke.line))
                .telosElevation(.raised)

            Canvas { context, size in
                drawRadar(context: context, size: size)
            }

            // The glyphs, one per axis, on the same geometry the canvas used.
            ForEach(Array(radarParts.enumerated()), id: \.offset) { index, part in
                let measured = score(part) != nil
                Image(systemName: levelPartSymbol(part))
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundStyle(levelPartTint(part).opacity(measured ? 0.95 : 0.30))
                    .offset(glyphOffset(index: index))
            }

            levelNumber
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onAppear { runCountUp() }
        // `onChangeCompat`, not `onChange`: the two-parameter form needs macOS 14 and this target is
        // 13.0. The shim already exists for exactly this and is what the rest of the app uses.
        .onChangeCompat(of: countUpKey) { _ in runCountUp() }
        .onChangeCompat(of: level) { _ in runCountUp() }
    }

    private var glyphSize: CGFloat { min(max(diameter * 0.11, 9), 15) }

    private func score(_ part: LevelPart) -> Double? {
        breakdown?.components.first { $0.part == part }?.score
    }

    private func drawRadar(context: GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = min(size.width, size.height) / 2 * 0.66
        let grid = TelosColor.textTertiary.opacity(0.30)
        let scores: [Double?] = radarParts.map { score($0) }

        // THE SCALE ONLY SHRINKS (decision 9): the grid rings shrink with it, so a web past the old edge
        // reads as "past your own 100", not as a shape cut off at the plate.
        var fractions: [Double] = scores.map { ($0 ?? 0) / 100 }
        if let best {
            fractions += radarParts.map { (best[$0] ?? 0) / 100 }
        }
        let divisor = CGFloat(levelRadarScaleDivisor(fractions))

        // Two rings, at a half and at the wearer's own 100. More would be graph paper at this size.
        for ring in [CGFloat(0.5), CGFloat(1.0)] {
            var path = Path()
            for i in radarParts.indices {
                let point = radarVertex(centre: centre, radius: radius * ring / divisor, index: i)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            context.stroke(path, with: .color(grid), lineWidth: 0.75)
        }

        // The spokes: solid for a measured axis, DASHED for one with no data.
        for i in radarParts.indices {
            var spoke = Path()
            spoke.move(to: centre)
            spoke.addLine(to: radarVertex(centre: centre, radius: radius, index: i))
            let style = scores[i] == nil
                ? StrokeStyle(lineWidth: 0.75, dash: [2, 3])
                : StrokeStyle(lineWidth: 0.75)
            context.stroke(spoke, with: .color(grid), style: style)
        }

        guard scores.contains(where: { $0 != nil }) else { return }

        let shownReveal = CGFloat(reveal)
        func point(_ i: Int, _ value: Double?) -> CGPoint {
            let raw: Double = max((value ?? 0) / 100, 0)
            let frac: CGFloat = CGFloat(raw) * shownReveal / divisor
            return radarVertex(centre: centre, radius: radius * frac, index: i)
        }

        var web = Path()
        for i in radarParts.indices {
            let p = point(i, scores[i])
            if i == 0 { web.move(to: p) } else { web.addLine(to: p) }
        }
        web.closeSubpath()

        // THE PERSONAL BEST, UNDER the live web. Drawn first so the current shape sits on top: the
        // reading is the subject, and the best is the frame around it. Gold, the only gold in the app.
        if let best {
            var crown = Path()
            for i in radarParts.indices {
                let p = point(i, best[radarParts[i]])
                if i == 0 { crown.move(to: p) } else { crown.addLine(to: p) }
            }
            crown.closeSubpath()
            context.stroke(crown, with: .color(TelosColor.bestGold.opacity(0.85)),
                           style: StrokeStyle(lineWidth: TelosStroke.strong, dash: [3, 3]))
        }

        // The web: a neutral whisper fill, then ONE crisp neutral line — no halo, no green (decision 19).
        context.fill(web, with: .color(TelosColor.textPrimary.opacity(TelosOpacity.whisper)))
        context.stroke(web, with: .color(TelosColor.textPrimary.opacity(0.85)),
                       style: StrokeStyle(lineWidth: TelosStroke.strong, lineJoin: .round))

        // Vertex dots in each part's identity colour; an unmeasured part is a HOLLOW dot at the centre.
        let dot: CGFloat = diameter >= 120 ? 7 : 5
        for i in radarParts.indices {
            let tint = levelPartTint(radarParts[i])
            if scores[i] == nil {
                let r = CGRect(x: centre.x - dot / 2, y: centre.y - dot / 2, width: dot, height: dot)
                context.stroke(Path(ellipseIn: r), with: .color(tint.opacity(0.6)), lineWidth: 1)
            } else {
                let p = point(i, scores[i])
                let r = CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)
                context.fill(Path(ellipseIn: r), with: .color(tint))
            }
        }
    }

    /// The figure, counting up from zero on open and on a new level.
    ///
    /// It earns its place: the level moves by a point or two a day, so a number that simply appears looks
    /// the same whether it changed or not. Counting up to it makes the wearer READ it. ONE animatable
    /// numeral drives it (§5.6) — no queue of dispatched steps.
    ///
    /// MONOSPACED DIGITS are not decoration here: proportional digits jitter sideways while counting.
    private var levelNumber: some View {
        ZStack {
            if level == nil {
                Text(verbatim: TelosType.absent)
                    .font(TelosType.numeralFont(size: numeralSize, weight: .medium))
                    .foregroundStyle(TelosColor.textTertiary)
            } else {
                LevelCountingNumeral(value: shown)
                    .font(TelosType.numeralFont(size: numeralSize, weight: .semibold))
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: diameter * 0.62)
            }
            coverageCaption
        }
    }

    /// Geometry-bound (it lives inside the plate): scales with the plate, never with Dynamic Type.
    private var numeralSize: CGFloat { min(max(diameter * 0.35, 22), 48) }

    /// HOW MUCH OF THE FORMULA THE NUMBER ACTUALLY RESTS ON, said out loud whenever it is not all of it.
    ///
    /// AN OVERLAY, NOT A ROW UNDER THE NUMBER: the figure is the subject and must not move on the days
    /// this line is absent. Offset with the plate so it lands in the same place at any size.
    @ViewBuilder private var coverageCaption: some View {
        if let breakdown, level != nil, breakdown.isPartialCoverage {
            Text("\(breakdown.coveragePercent)% measured")
                .font(TelosType.scaleFixed)
                .monospacedDigit()
                .foregroundStyle(TelosColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: diameter * 0.8)
                .offset(y: diameter * 0.2)
        }
    }

    /// What VoiceOver reads for the radar: the level, how much of it is measured, and each part.
    private var accessibilityText: Text {
        guard let breakdown, let level else { return Text("Level, not scored yet") }
        var parts: [String] = []
        for part in radarParts {
            let name = levelPartLabel(part)
            if let s = score(part) {
                parts.append("\(name) \(Int(s.rounded()))")
            } else {
                parts.append("\(name) " + String(localized: "not measured"))
            }
        }
        let rounded = Int(level.rounded())
        let head = breakdown.isPartialCoverage
            ? String(localized: "Level \(rounded), \(breakdown.coveragePercent)% measured")
            : String(localized: "Level \(rounded)")
        return Text(verbatim: head + ". " + parts.joined(separator: ", "))
    }

    private func glyphOffset(index: Int) -> CGSize {
        let r = diameter * glyphRadiusFraction
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(radarParts.count)
        return CGSize(width: r * CGFloat(cos(angle)), height: r * CGFloat(sin(angle)))
    }

    private func runCountUp() {
        guard let target = level.map({ $0.rounded() }) else {
            reveal = 0
            shown = 0
            return
        }
        if motion.poseStill(reduceMotion) {
            // Posed at the value: no reveal, no count.
            reveal = 1
            shown = target
            return
        }
        reveal = 0
        shown = 0
        withAnimation(.easeOut(duration: levelSlotSeconds)) {
            reveal = 1
            shown = target
        }
    }
}

/// The level numeral, animatable: SwiftUI interpolates `value` and the text shows the whole number under it.
private struct LevelCountingNumeral: View, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: "\(Int(value.rounded()))")
            .monospacedDigit()
    }
}

/// The personal-best ring's colour: the design system's one gold (`TelosColor.bestGold`).
let radarBestGold = TelosColor.bestGold

/// The SF Symbol for each part. Chosen to match the Android glyphs as closely as the two sets allow.
func levelPartSymbol(_ part: LevelPart) -> String {
    switch part {
    case .sleep: return "moon.fill"
    case .heart: return "heart"
    case .lungs: return "wind"
    case .muscle: return "figure.strengthtraining.traditional"
    case .focus: return "bolt.fill"
    }
}

/// Each part's identity colour (TelosColor): sleep → rest, heart → heart, lungs → lungs, muscle → muscle,
/// focus → focus. Stored tokens — no per-access dynamic provider (§2.1 rule 6).
func levelPartTint(_ part: LevelPart) -> Color {
    switch part {
    case .sleep: return TelosColor.rest
    case .heart: return TelosColor.heart
    case .lungs: return TelosColor.lungs
    case .muscle: return TelosColor.muscle
    case .focus: return TelosColor.focus
    }
}

/// The metric a lever names, in the wearer's language.
///
/// `.meditation` keeps its label for exhaustiveness, but no Level surface shows it as a contributor
/// (decision 10): the lever clusters map a meditation driver to its part, and the breakdown shows the
/// meditation DEDUCTION as its own line.
func levelDriverLabel(_ driver: LevelDriver) -> LocalizedStringKey {
    switch driver {
    case .restorativeSleep: return "deep + rem"
    case .sleepHrv: return "night hrv"
    case .sleepRegularity: return "regularity"
    case .sleepDuration: return "sleep vs need"
    case .hrv: return "hrv"
    case .rhr: return "rhr"
    case .vo2max: return "vo₂max"
    case .respRate: return "resp. rate"
    case .strength: return "strength"
    case .trainingLoad: return "training load"
    case .daytimeCalm: return "calm"
    case .meditation: return "meditation"
    }
}
