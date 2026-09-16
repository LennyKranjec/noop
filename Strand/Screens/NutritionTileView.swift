import SwiftUI
import StrandDesign
import StrandImport

// NutritionTileView.swift — today's macros, on Today.
//
// Rebuilt to the reference tile: the title and its arrow across the top, an arc gauge on the left
// carrying the day's energy, and the three macros to its right over a dot matrix.
//
// THE DOTS ARE THE BAR. Each macro's row of dots fills left to right with how much of it has been
// eaten, which is a progress bar that does not pretend to more precision than it has — a solid bar
// invites reading a percentage off its edge, and a macro target is a soft thing.
//
// IT READS WHAT IS STORED, and the platform tops the store up. A food diary is filled in across the day
// — breakfast at eight, dinner at nine — so a figure banked once is wrong by lunchtime; on iOS the
// shell asks HealthKit for today's macros on every refresh and this tile then reads the result. That
// split is deliberate: the tile is shared with macOS, which has no HealthKit, and a view that reached
// for a platform store could not live in shared code.
//
// TWO SOURCES, ONE FIGURE PER FIELD. A CSV import and the health store write the same four keys under
// different sources; the newest value for each field wins, because a day's macros are a running total
// and the later write is the fuller one.
//
// THE GAUGE SHOWS NO PROGRESS, because there is no calorie TARGET in this app. It draws its scale and
// carries the figure; lighting an arbitrary share of it would invent the goal. The macro dots DO fill,
// because a macro target is derivable from body mass — and when it is not, they stay unlit.
//
// AN ABSENT MACRO IS "0g" ONLY WHEN THE DIARY WAS OPENED. With nothing logged at all the tile says so
// in words underneath rather than printing three zeros, because "you ate no fat today" is a claim and
// "your diary has not been opened" is the truth.

/// One day's macros, all four independently absent-able.
struct DayMacros: Equatable {
    var kcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?

    var isEmpty: Bool { kcal == nil && proteinG == nil && carbsG == nil && fatG == nil }
}

struct NutritionTileView: View {
    @EnvironmentObject var repo: Repository

    /// Bumped by the shell when a platform read has topped up the store, so the tile re-reads.
    let refreshKey: Int
    var onOpen: (() -> Void)? = nil

    @State private var macros = DayMacros()
    @State private var loaded = false

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 14) {
                header
                HStack(alignment: .center, spacing: 16) {
                    EnergyArc(kcal: macros.kcal)
                        .frame(width: 96, height: 96)
                    macroColumns
                }
                if loaded, macros.isEmpty {
                    Text("Nothing logged today. Macros arrive from any app that writes food to "
                         + "Apple Health, or from a nutrition CSV in Data Sources.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(repo.refreshSeq)-\(refreshKey)") { await load() }
    }

    private var header: some View {
        HStack {
            Text("Today's foods")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            if let onOpen {
                Button(action: onOpen) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open nutrition")
            }
        }
    }

    private var macroColumns: some View {
        HStack(alignment: .top, spacing: 12) {
            MacroColumn(icon: "drop.fill", grams: macros.fatG,
                        target: 70, tint: StrandPalette.metricCyan, label: "Fat")
            MacroColumn(icon: "leaf.fill", grams: macros.carbsG,
                        target: 250, tint: StrandPalette.metricAmber, label: "Carbs")
            MacroColumn(icon: "fish.fill", grams: macros.proteinG,
                        target: 140, tint: StrandPalette.metricRose, label: "Protein")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The four keys, read across every source that writes them.
    ///
    /// NEWEST WINS PER FIELD. A day's macros are a running total, so a later write is the fuller one —
    /// and the two writers (the health store's live read and a CSV import) both write whole days.
    private func load() async {
        let today = Repository.localDayKey(Date())
        func newest(_ key: String) async -> Double? {
            var best: Double?
            for source in [HealthKitNutritionSourceId, NutritionCsvImporter.sourceId] {
                let rows = await repo.series(key: key, source: source, from: today, to: today)
                if let v = rows.last?.value { best = v }
            }
            return best
        }
        macros = DayMacros(
            kcal: await newest(NutritionCsvImporter.Keys.caloriesIn),
            proteinG: await newest(NutritionCsvImporter.Keys.proteinG),
            carbsG: await newest(NutritionCsvImporter.Keys.carbsG),
            fatG: await newest(NutritionCsvImporter.Keys.fatG))
        loaded = true
    }
}

/// The source the platform health read banks macros under.
///
/// Spelled here rather than reached for: `HealthKitBridge` is iOS-only and this tile is shared, so the
/// id crosses the boundary as a string. It MUST match `HealthKitBridge.nutritionSourceId`.
let HealthKitNutritionSourceId = "apple-health-nutrition"

/// One macro: its glyph, its figure, and the dotted bar underneath.
private struct MacroColumn: View {
    let icon: String
    let grams: Double?
    /// A rough daily target, only ever used to decide how much of the dotted bar is lit. Never shown as
    /// a number, because it is a rule of thumb and printing it would dress one up as a prescription.
    let target: Double
    let tint: Color
    let label: String

    private var lit: Bool { (grams ?? 0) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(lit ? tint : StrandPalette.textTertiary)
                Text(grams.map { "\(Int($0.rounded()))g" } ?? "0g")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(lit ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            DotBar(fraction: min(max((grams ?? 0) / target, 0), 1), tint: tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label): \(Int((grams ?? 0).rounded())) grams"))
    }
}

/// A row of dots that fills left to right.
///
/// Two ranks rather than one: a single line of dots at this width reads as a dotted rule, and the
/// second rank is what makes it read as a quantity. Unlit dots keep their own colour so the bar has a
/// visible full length to be a fraction OF.
private struct DotBar: View {
    let fraction: Double
    let tint: Color

    private let columns = 14
    private let ranks = 2
    private let dot: CGFloat = 3
    private let spacing: CGFloat = 3

    var body: some View {
        let litColumns = Int((Double(columns) * fraction).rounded())
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(0..<ranks, id: \.self) { _ in
                HStack(spacing: spacing) {
                    ForEach(0..<columns, id: \.self) { column in
                        Circle()
                            .fill(column < litColumns ? tint : StrandPalette.textTertiary.opacity(0.22))
                            .frame(width: dot, height: dot)
                    }
                }
            }
        }
    }
}

/// The energy gauge: a three-quarter arc with the figure inside it.
///
/// An ARC, not the tick dial the stress card uses — the reference tile draws a smooth ring, and the two
/// instruments answer different questions: ticks read as a scale you count along, an arc as a vessel.
private struct EnergyArc: View {
    let kcal: Double?

    private let startDeg: Double = 135
    private let sweepDeg: Double = 270
    private let lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                var track = Path()
                track.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                             radius: min(rect.width, rect.height) / 2,
                             startAngle: .degrees(startDeg),
                             endAngle: .degrees(startDeg + sweepDeg),
                             clockwise: false)
                // ONE STROKE, unlit. There is no calorie target here, so there is no share of the arc
                // that could honestly be filled — the ring carries the scale and the number carries the
                // reading.
                context.stroke(track,
                               with: .color(kcal == nil
                                            ? StrandPalette.textTertiary.opacity(0.22)
                                            : StrandPalette.textTertiary.opacity(0.38)),
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            VStack(spacing: 0) {
                Text(kcal.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(kcal == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("kcal")
                    .font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}
