import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Hours vs Needed (#today-hosted-cards)
//
// The Sleep tab surfaces "Hours vs Needed" only as a StatTile inside the Night-detail metric grid — there
// is no standalone renderer for it. This card gives that single metric its own hostable view so it can be
// surfaced in the Today tab on its own. Both the Sleep tab tile and this hosted card read the SAME
// `SleepModel.hoursVsNeeded` metric (latest / typical / series), so the number, the vs-typical caption and
// the sparkline can never diverge between the two surfaces (the parity contract). The tile presentation
// (value / caption / accent / sparkline) is a verbatim lift of the `NightDetailCard` "Hours vs Needed"
// tile, so the hosted card reads byte-identically to the Sleep-tab tile.

/// The "Hours vs Needed" card. Renders the wearer's latest hours-vs-needed percentage against their
/// personal typical from the shared [SleepModel], as the compact tile (sparkline +
/// vs-typical delta) — the same presentation the Night-detail grid uses for this metric.
struct HoursVsNeededCard: View {
    let model: SleepModel

    var body: some View {
        // The metric (latest %, typical mean, history series) is computed ONCE in the model build and
        // read here — the same memoized result the Night-detail grid reads for its tile.
        let need = model.hoursVsNeeded

        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("Hours vs Needed", overline: "Sleep")
            // Telos 2.0: the SAME compact tile the Night-detail grid builds for this metric
            // (`SleepMetricTile`), so the hosted value, delta and states match it exactly.
            SleepMetricTile.make("Hours vs Needed", metric: need, unit: "%",
                                 direction: .higherIsBetter, spark: TelosColor.rest, icon: "scope")
        }
    }
}
