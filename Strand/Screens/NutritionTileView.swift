import SwiftUI
import StrandDesign
import StrandImport

// NutritionTileView.swift — today's macros, on Today.
//
// SwiftUI twin of the Android `NutritionTile`. An energy dial reading kcal, and three rings for fat,
// carbohydrate and protein.
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
// THE DIAL SHOWS NO PROGRESS, because there is no calorie TARGET in this app. It draws its scale and
// carries the figure; lighting an arbitrary share of it would invent the goal.
//
// AN ABSENT MACRO IS A DASH, not a zero. "You ate no fat today" is a claim; "your diary has not been
// opened" is the truth, and only the second one is ever knowable here.

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

    @State private var macros = DayMacros()
    @State private var loaded = false

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                // Centred title between two hairlines, as the reference tile heads its card.
                HStack(spacing: 12) {
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                    Text("Nutrition")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize()
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                }

                HStack(spacing: 12) {
                    EnergyDial(kcal: macros.kcal)
                        .frame(width: 108, height: 108)
                    HStack(spacing: 0) {
                        MacroRing(label: "Fat", grams: macros.fatG,
                                  tint: StrandPalette.metricCyan, icon: "drop.fill")
                            .frame(maxWidth: .infinity)
                        MacroRing(label: "Carbs", grams: macros.carbsG,
                                  tint: StrandPalette.metricAmber, icon: "leaf.fill")
                            .frame(maxWidth: .infinity)
                        MacroRing(label: "Protein", grams: macros.proteinG,
                                  tint: StrandPalette.metricRose, icon: "fish.fill")
                            .frame(maxWidth: .infinity)
                    }
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

    /// The four keys, read across every source that writes them.
    ///
    /// NEWEST WINS PER FIELD. A day's macros are a running total, so a later write is the fuller one —
    /// and the two writers (the health store's live read and a CSV import) both write whole days.
    private func load() async {
        func newest(_ key: String) async -> Double? {
            let today = Repository.localDayKey(Date())
            var best: Double?
            for source in [HealthKitNutritionSourceId, NutritionCsvImporter.sourceId] {
                let rows = await repo.series(key: key, source: source, days: 2)
                if let v = rows.last(where: { $0.day == today })?.value { best = v }
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

/// The tick dial from the stress card, reading kcal — one instrument language across Today.
private struct EnergyDial: View {
    let kcal: Double?

    private let ticks = 36
    private let startDeg: Double = 140
    private let spanDeg: Double = 260

    var body: some View {
        ZStack {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = radius * 0.96
                let inner = radius * 0.74
                let colour = kcal == nil
                    ? StrandPalette.textTertiary.opacity(0.25)
                    : StrandPalette.metricAmber.opacity(0.85)
                for i in 0..<ticks {
                    let t = Double(i) / Double(ticks - 1)
                    let angle = (startDeg + spanDeg * t) * .pi / 180
                    var path = Path()
                    path.move(to: CGPoint(x: centre.x + cos(angle) * inner, y: centre.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: centre.x + cos(angle) * outer, y: centre.y + sin(angle) * outer))
                    context.stroke(path, with: .color(colour),
                                   style: StrokeStyle(lineWidth: max(1.5, radius * 0.05), lineCap: .round))
                }
            }
            VStack(spacing: 0) {
                Text(kcal.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(kcal == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text("kcal")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

private struct MacroRing: View {
    let label: String
    let grams: Double?
    let tint: Color
    let icon: String

    private var ringColour: Color { grams == nil ? StrandPalette.textTertiary.opacity(0.4) : tint }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .strokeBorder(ringColour, lineWidth: 2)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ringColour)
            }
            .frame(width: 44, height: 44)
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(grams == nil ? StrandPalette.textTertiary : tint)
            Text(grams.map { "\(Int($0.rounded())) g" } ?? "–")
                .font(StrandFont.captionNumber)
                .foregroundStyle(grams == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }
}
