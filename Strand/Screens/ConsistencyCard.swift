import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Consistency (#today-hosted-cards)
//
// The Sleep tab surfaces "Consistency" only as a StatTile inside the Night-detail metric grid — there is
// no standalone renderer for it. This card gives that single metric its own hostable view so it can be
// surfaced in the Today tab on its own. Both the Sleep tab tile and this hosted card read the SAME
// `SleepModel.consistency` metric (latest / typical / series) — the bedtime-onset-spread score that also
// honours the imported-consistency preference and is byte-identical to Android's `consistencySeries` — so
// the number, the vs-typical caption and the sparkline can never diverge between the two surfaces (the
// parity contract). The tile presentation (value / caption / accent / sparkline) is a verbatim lift of the
// `NightDetailCard` "Consistency" tile, so the hosted card reads byte-identically to the Sleep-tab tile.

/// The "Consistency" card. Renders the wearer's latest sleep-consistency percentage against their personal
/// typical from the shared [SleepModel], as a single full-width StatTile with its sparkline and vs-typical
/// caption — the same presentation the Night-detail grid uses for this metric.
struct ConsistencyCard: View {
    let model: SleepModel

    var body: some View {
        // The metric (latest %, typical mean, history series) is computed ONCE in the model build and
        // read here — the same memoized result the Night-detail grid reads for its tile.
        let cons = model.consistency

        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Consistency", overline: "Sleep")
            // Telos 2.0: the SAME compact tile the Night-detail grid builds for this metric
            // (`SleepMetricTile`), so the hosted value, delta and states match it exactly.
            SleepMetricTile.make("Consistency", metric: cons, unit: "%",
                                 direction: .higherIsBetter, spark: TelosColor.lungs, icon: "clock")
        }
    }
}
