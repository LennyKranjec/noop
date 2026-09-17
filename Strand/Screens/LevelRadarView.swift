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
// A PART WITH NO DATA IS DRAWN AT THE CENTRE AND ITS GLYPH IS DIMMED. Not at some middle default: an
// unmeasured part is a hole in the shape, and filling it in would draw a body we did not measure.

/// The five axes, in the order they are drawn: clockwise from the top.
private let radarParts: [LevelPart] = [.sleep, .heart, .lungs, .muscle, .focus]

/// How long the count-up and the web reveal take. Long enough to read, short enough not to wait on.
private let levelSlotSeconds: Double = 0.9

/// Where the glyphs sit, as a fraction of the box — just inside the plate's corners.
private let glyphRadiusFraction: CGFloat = 0.37

/// The plate's lift. Enough to read as floating over the screen it hangs above, not as a card.
private let plateElevation: CGFloat = 10

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

    @State private var reveal: Double = 0
    @State private var shown: Int = 0

    private var level: Double? { breakdown?.level }

    var body: some View {
        ZStack {
            PentagonShape()
                .fill(StrandPalette.surfaceRaised)
                .shadow(color: .black.opacity(0.45), radius: plateElevation, y: 3)

            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) / 2 * 0.66
                let grid = StrandPalette.textTertiary.opacity(0.30)

                // Two rings, at a half and at full. More would be graph paper at this size; none at all
                // would leave the shape floating with nothing to be big or small against.
                for ring in [0.5, 1.0] {
                    var path = Path()
                    for i in radarParts.indices {
                        let point = radarVertex(centre: centre, radius: radius * ring, index: i)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    context.stroke(path, with: .color(grid), lineWidth: 1)
                }

                // The spokes, so a vertex reads as a measured axis rather than a corner of a blob.
                for i in radarParts.indices {
                    var spoke = Path()
                    spoke.move(to: centre)
                    spoke.addLine(to: radarVertex(centre: centre, radius: radius, index: i))
                    context.stroke(spoke, with: .color(grid), lineWidth: 1)
                }

                let scores = radarParts.map { part in
                    breakdown?.components.first { $0.part == part }?.score
                }
                guard scores.contains(where: { $0 != nil }) else { return }

                // NO CEILING ON THE SCORES, so none on the drawing: the outer grid ring is still the
                // wearer's own 100, and a part past it draws past it — up to the edge of the plate, where
                // the geometry has to stop. Below 0 collapses to the centre.
                let reach: Double = 1.25
                var web = Path()
                for i in radarParts.indices {
                    let frac = min(max((scores[i] ?? 0) / 100 * reveal, 0), reach)
                    let point = radarVertex(centre: centre, radius: radius * frac, index: i)
                    if i == 0 { web.move(to: point) } else { web.addLine(to: point) }
                }
                web.closeSubpath()

                // THE PERSONAL BEST, UNDER the live web and only where it is genuinely ahead of it.
                // Drawn first so the current shape sits on top: the reading is the subject, and the
                // best is the frame around it. Gold rather than another tint because nothing else in
                // this palette is gold, so it cannot be mistaken for one of the five parts.
                if let best {
                    var crown = Path()
                    for i in radarParts.indices {
                        let frac = min(max((best[radarParts[i]] ?? 0) / 100 * reveal, 0), reach)
                        let point = radarVertex(centre: centre, radius: radius * frac, index: i)
                        if i == 0 { crown.move(to: point) } else { crown.addLine(to: point) }
                    }
                    crown.closeSubpath()
                    context.stroke(crown, with: .color(radarBestGold.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                }

                context.fill(web, with: .color(StrandPalette.accent.opacity(0.16)))
                context.stroke(web, with: .color(StrandPalette.accent.opacity(0.75)), lineWidth: 1.5)
            }

            // The glyphs, one per axis, on the same geometry the canvas used.
            ForEach(Array(radarParts.enumerated()), id: \.offset) { index, part in
                let measured = breakdown?.components.first { $0.part == part }?.score != nil
                Image(systemName: levelPartSymbol(part))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(levelPartTint(part).opacity(measured ? 0.95 : 0.30))
                    .offset(glyphOffset(index: index))
            }

            levelNumber
        }
        .frame(width: diameter, height: diameter)
        .onAppear { runCountUp() }
        // `onChangeCompat`, not `onChange`: the two-parameter form needs macOS 14 and this target is
        // 13.0. The shim already exists for exactly this and is what the rest of the app uses.
        .onChangeCompat(of: countUpKey) { _ in runCountUp() }
        .onChangeCompat(of: level) { _ in runCountUp() }
    }

    /// The figure, counting up from zero on every open.
    ///
    /// A slot machine, and it earns its place: the level moves by a point or two a day, so a number that
    /// simply appears looks the same whether it changed or not. Spinning up to it makes the wearer READ
    /// it every time instead of glancing past it.
    ///
    /// MONOSPACED DIGITS are not decoration here. Proportional digits are different widths, so a number
    /// counting 0…80 through every digit in between jitters sideways the whole way up and lands somewhere
    /// other than where it started.
    private var levelNumber: some View {
        Text(level == nil ? "–" : "\(shown)")
            .font(.system(size: 30, weight: .black, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(level == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
    }

    private func glyphOffset(index: Int) -> CGSize {
        let r = diameter * glyphRadiusFraction
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(radarParts.count)
        return CGSize(width: r * CGFloat(cos(angle)), height: r * CGFloat(sin(angle)))
    }

    private func runCountUp() {
        guard let target = level.map({ Int($0.rounded()) }) else {
            reveal = 0
            shown = 0
            return
        }
        reveal = 0
        shown = 0
        withAnimation(.linear(duration: levelSlotSeconds)) { reveal = 1 }
        // Eased so it sprints through the middle and creeps onto the last few points, which is what
        // makes it read as landing rather than as stopping.
        let steps = min(34, max(target, 1) * 4)
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = 1 - (1 - t) * (1 - t)
            DispatchQueue.main.asyncAfter(deadline: .now() + levelSlotSeconds * t) {
                shown = Int((Double(target) * eased).rounded())
                if step == steps { shown = target }
            }
        }
    }
}

/// The SF Symbol for each part. Chosen to match the Android glyphs as closely as the two sets allow.
/// The personal-best ring's colour. A real gold, and the only gold in the app — see the note at the
/// draw site on why it is not one of the metric tints.
let radarBestGold = Color(.sRGB, red: 0xE5 / 255, green: 0xB8 / 255, blue: 0x4B / 255, opacity: 1)

func levelPartSymbol(_ part: LevelPart) -> String {
    switch part {
    case .sleep: return "moon.fill"
    case .heart: return "heart"
    case .lungs: return "wind"
    case .muscle: return "figure.strengthtraining.traditional"
    case .focus: return "bolt.fill"
    }
}

func levelPartTint(_ part: LevelPart) -> Color {
    switch part {
    case .sleep: return StrandPalette.restBright
    case .heart: return StrandPalette.statusCritical
    case .lungs: return StrandPalette.metricCyan
    case .muscle: return StrandPalette.statusWarning
    case .focus: return StrandPalette.accent
    }
}

/// The metric a lever names, in the wearer's language.
func levelDriverLabel(_ driver: LevelDriver) -> LocalizedStringKey {
    switch driver {
    case .restorativeSleep: return "deep + rem"
    case .sleepHrv: return "night hrv"
    case .sleepRegularity: return "regularity"
    case .hrv: return "hrv"
    case .rhr: return "rhr"
    case .vo2max: return "vo₂max"
    case .respRate: return "resp. rate"
    case .muscleVolume: return "volume"
    case .daytimeCalm: return "calm"
    case .meditation: return "meditation"
    }
}
