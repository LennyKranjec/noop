import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Night detail (#today-hosted-cards)
//
// The Sleep tab's "Night detail" metric grid, extracted into a standalone view so it can ALSO be hosted
// in the Today tab. Both the Sleep tab and the Today host render THIS view from the SAME `SleepModel`, so
// the per-metric latest value / sparkline / typical delta can never diverge between the two surfaces (the
// parity contract). The seven series are computed once in `SleepModel.build` and read here.
//
// Telos 2.0 (coordinator decision 11): one attribute is a COMPACT tile, several per row — the grid is a
// `TelosTileGrid` of `TelosMetricTile`s (2–3 per row by width, one column at accessibility sizes), each
// hugging its content: glyph + label, numeral + unit, the vs-typical delta chip, a micro-sparkline, and
// the honest states (absent → "—" + reason, carried → "Carried · d MMM").

/// The "Night detail" card: Sleep Debt, Rest, Efficiency, Consistency, Hours vs Needed, Restorative and
/// Respiratory as compact tiles, rendered from the shared [SleepModel].
struct NightDetailCard: View {
    let model: SleepModel

    var body: some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean, all computed ONCE in
        // the model build — here we only read the memoized results.
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: String(localized: "vs your typical"))
            TelosTileGrid(maxColumns: 3) {
                // Sleep Debt leads: it is the actionable summary of the section.
                SleepMetricTile.debt(model.sleepDebt)
                SleepMetricTile.make("Rest", metric: model.performance, unit: "%",
                                     direction: .higherIsBetter, spark: TelosColor.rest, icon: "moon.fill")
                SleepMetricTile.make("Efficiency", metric: model.efficiency, unit: "%",
                                     direction: .higherIsBetter, spark: TelosColor.teal, icon: "waveform.path")
                SleepMetricTile.make("Consistency", metric: model.consistency, unit: "%",
                                     direction: .higherIsBetter, spark: TelosColor.lungs, icon: "clock")
                SleepMetricTile.make("Hours vs Needed", metric: model.hoursVsNeeded, unit: "%",
                                     direction: .higherIsBetter, spark: TelosColor.rest, icon: "scope")
                SleepMetricTile.make("Restorative", metric: model.restorative, unit: "%",
                                     direction: .higherIsBetter, spark: StrandPalette.sleepREM, icon: "sparkles")
                // Breathing rate has no better/worse direction overnight: the chip shows movement only.
                SleepMetricTile.make("Respiratory", metric: model.respiratory, unit: "rpm", digits: 1,
                                     direction: .neutral, spark: TelosColor.violet, icon: "lungs")
            }
        }
    }
}

// MARK: - The shared tile builder (Night detail + the hosted Hours-vs-Needed / Consistency cards)

/// One Sleep metric as a compact `TelosMetricTile`, built the SAME way on every surface that shows it so
/// the Sleep tab's grid and Today's hosted single-metric cards can never disagree.
enum SleepMetricTile {
    /// Which way is better for THIS metric — decided here, never inferred from the sign alone (§5.5).
    enum Direction { case higherIsBetter, lowerIsBetter, neutral }

    /// Latest value, delta vs the wearer's typical, 30-night sparkline. A carried prior-day value is
    /// stamped "Carried · d MMM" and gets no delta (#1946: never passed off as tonight's read). No value →
    /// "—" + "Not enough data yet"; a value with no typical → a "—" delta chip (not computed).
    static func make(_ label: LocalizedStringKey,
                     metric: SleepModel.Metric,
                     unit: String?,
                     digits: Int = 0,
                     direction: Direction,
                     spark: Color,
                     icon: String) -> TelosMetricTile {
        let carried: Date? = carriedDate(metric)
        let format: (Double) -> String = digits == 0 ? TelosFormat.integer : TelosFormat.decimal(digits)
        let chip: TelosDelta? = carried == nil ? delta(metric, unit: unit, digits: digits, direction: direction) : nil
        return TelosMetricTile(label,
                               value: metric.latest,
                               unit: unit,
                               format: format,
                               delta: chip,
                               absentReason: Text("Not enough data yet"),
                               carriedFrom: carried,
                               sparkline: sparkline(metric.series),
                               sparkColor: spark,
                               icon: icon,
                               iconTint: TelosColor.violetInk)
    }

    /// Sleep debt: minutes shown as "1h 20m", with the on-target / below-need WORD as its chip (the word,
    /// not colour alone, carries the status — `nightDetailDebtCaption`, the tested rule).
    static func debt(_ metric: SleepModel.Metric) -> TelosMetricTile {
        let carried: Date? = carriedDate(metric)
        let status: TelosDelta? = metric.latest.map { debt in
            TelosDelta(text: nightDetailDebtCaption(debt),
                       tone: debt < SleepDebt.onTargetBandMin ? .better : .worse)
        }
        return TelosMetricTile("Sleep Debt",
                               value: metric.latest,
                               format: { durationText($0) },
                               delta: status,
                               absentReason: Text("Not enough data yet"),
                               carriedFrom: carried,
                               sparkline: sparkline(metric.series),
                               sparkColor: TelosColor.violet,
                               icon: "arrow.down.right.circle",
                               iconTint: TelosColor.violetInk)
    }

    private static func delta(_ metric: SleepModel.Metric, unit: String?, digits: Int,
                              direction: Direction) -> TelosDelta? {
        guard let latest = metric.latest else { return nil }
        guard let typical = metric.typical, typical != 0 else { return .notComputed }
        let diff: Double = latest - typical
        let signed: String = TelosFormat.signedDelta(diff, digits: digits)
        let tone: TelosDeltaTone
        if signed.hasPrefix("\u{00B1}") || direction == .neutral {
            tone = .flat
        } else if (diff > 0) == (direction == .higherIsBetter) {
            tone = .better
        } else {
            tone = .worse
        }
        let suffix: String = unit == "%" ? "%" : ""
        return TelosDelta(text: signed + suffix, tone: tone)
    }

    /// The day a carried value came from, or nil when the value is today's own (or absent). Same rule as
    /// `SleepModel.carriedMetricCaption`.
    private static func carriedDate(_ metric: SleepModel.Metric) -> Date? {
        guard SleepModel.carriedMetricCaption(latestDay: metric.latestDay, latest: metric.latest) != nil,
              let key = metric.latestDay else { return nil }
        return dayKeyParser.date(from: key)
    }

    /// yyyy-MM-dd in the local zone (lenient, so a zone whose midnight is skipped still parses), so the
    /// carried label names the same calendar day the key does.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = true
        return f
    }()

    /// A sparkline needs at least two points; otherwise nil so the tile stays clean.
    static func sparkline(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    /// Minutes → "Xm" / "Yh Zm" (verbatim of `SleepView.durationText`).
    static func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return String(localized: "\(m)m") }
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

func nightDetailDebtCaption(_ debt: Double?) -> String {
    guard let debt else { return String(localized: "vs need") }
    return debt < SleepDebt.onTargetBandMin ? String(localized: "On target") : String(localized: "Below need")
}

func nightDetailDebtColor(_ debt: Double?) -> Color {
    guard let debt else { return StrandPalette.textPrimary }
    switch debt {
    case ..<SleepDebt.onTargetBandMin: return StrandPalette.statusPositive
    case ..<60: return StrandPalette.statusWarning
    default: return StrandPalette.statusCritical
    }
}
