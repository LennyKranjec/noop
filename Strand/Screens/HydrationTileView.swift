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
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                WaterFill(fraction: fraction)

                Text("\(formatML(shownML)) / \(formatML(Double(goalML)))")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(12)

                // The buttons take the place the reference tile gives its caption.
                HStack(spacing: 12) {
                    WaterButton(icon: "minus", label: "Remove a glass") { change(-glassML) }
                    WaterButton(icon: "plus", label: "Add a glass") { change(glassML) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
            }
            .frame(height: waterTileHeight)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: "\(repo.refreshSeq)-\(repo.hydrationSeq)-\(refreshKey)") { await load() }
    }

    private func load() async {
        goalML = repo.hydrationGoalML(profileSex: profile.sex)
        storedML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        shownML = storedML
    }

    private func change(_ deltaML: Int) {
        SystemHaptics.play(.tap)
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// The liquid.
///
/// THE MOVEMENT IS THE POINT, and a single sine is what made the Android version read as a cardboard
/// cut-out sliding back and forth. Each sheet sums several components at unrelated wavelengths and
/// speeds, so no two crests line up the same way twice and the surface never visibly repeats. Layers are
/// drawn back to front, each deeper, slower and darker than the one in front — a far surface moves less
/// across your field of view than a near one, and that difference is what the eye reads as depth.
///
/// STILL WHEN THE APP IS ASKED TO BE STILL. Reduce Motion, battery saver and quiet-motion all stop it,
/// and a stopped wave is a flat waterline rather than a frozen crest.
private struct WaterFill: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private var still: Bool { motion.poseStill(reduceMotion) }

    /// The water's own blue. Deeper than the palette's cyan and with a lift at the surface, because a
    /// flat fill reads as a coloured rectangle — the gradient is what makes it read as a body of liquid
    /// with a top to it.
    private var deep: Color { Color(.sRGB, red: 0.06, green: 0.36, blue: 0.62, opacity: 1) }
    private var bright: Color { Color(.sRGB, red: 0.30, green: 0.71, blue: 0.96, opacity: 1) }

    var body: some View {
        TimelineView(.animation(minimumInterval: still ? nil : 1.0 / 30, paused: still)) { timeline in
            Canvas { context, size in
                let t = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let clamped = min(max(fraction, 0), 1)
                let surfaceY = size.height * (1 - clamped)
                let amplitude = still ? 0 : size.height * 0.03

                // THE MEASURE LINES, behind the water and across the whole tile. Dashed rather than
                // solid: a solid rule at a quarter of the tile reads as a target, and there is no
                // hydration target being drawn here — these are a scale to judge the level against,
                // which is exactly what a dashed rule says and a solid one does not.
                for share in [0.25, 0.5, 0.75] {
                    var rule = Path()
                    let y = size.height * (1 - share)
                    rule.move(to: CGPoint(x: 0, y: y))
                    rule.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(rule, with: .color(StrandPalette.hairlineStrong),
                                   style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                }

                func sheet(depth: Double, speed: Double, offset: Double, opacity: Double, wobble: Double) {
                    let swell = amplitude * 0.45 * sin(t * 0.23 * speed + offset)
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    let steps = 48
                    var crest = size.height
                    for i in 0...steps {
                        let x = size.width * Double(i) / Double(steps)
                        let phase = x / size.width * .pi * 2
                        let y = surfaceY + depth + swell
                            + amplitude * wobble * sin(phase * 1.0 + t * 0.9 * speed + offset)
                            + amplitude * wobble * 0.5 * sin(phase * 2.3 + t * 1.4 * speed)
                            + amplitude * wobble * 0.25 * sin(phase * 3.7 - t * 0.7 * speed)
                        crest = Swift.min(crest, y)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    // Lit at the surface, dark at the bottom — the gradient runs from the highest crest
                    // this sheet reaches to the floor of the tile, so the sheen stays ON the water as the
                    // level rises rather than sitting at a fixed height.
                    context.fill(path, with: .linearGradient(
                        Gradient(colors: [bright.opacity(opacity * 1.15), deep.opacity(opacity)]),
                        startPoint: CGPoint(x: 0, y: crest),
                        endPoint: CGPoint(x: 0, y: size.height)))
                }

                // Back to front: deeper, slower, fainter behind.
                sheet(depth: 6, speed: 0.6, offset: 1.7, opacity: 0.38, wobble: 0.6)
                sheet(depth: 3, speed: 0.85, offset: 0.6, opacity: 0.52, wobble: 0.8)
                sheet(depth: 0, speed: 1.0, offset: 0.0, opacity: 0.72, wobble: 1.0)

                // THE GLINT along the waterline. One bright hairline on the front sheet's crest, which
                // is the whole difference between "blue shape" and "wet".
                if clamped > 0.02 {
                    var glint = Path()
                    let steps = 48
                    for i in 0...steps {
                        let x = size.width * Double(i) / Double(steps)
                        let phase = x / size.width * .pi * 2
                        let y = surfaceY
                            + amplitude * sin(phase + t * 0.9)
                            + amplitude * 0.5 * sin(phase * 2.3 + t * 1.4)
                            + amplitude * 0.25 * sin(phase * 3.7 - t * 0.7)
                        if i == 0 { glint.move(to: CGPoint(x: x, y: y)) }
                        else { glint.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    context.stroke(glint, with: .color(.white.opacity(0.42)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
