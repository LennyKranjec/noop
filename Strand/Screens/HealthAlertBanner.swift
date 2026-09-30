import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics
import Foundation

/// The strain/illness heads-up on Today, titled "Body off baseline" (HEALTH_V2 H8: the old "early
/// warning" implied a prediction). Wording and gating are the health package's (`localizedHealthAlertCopy`
/// below, `AppModel.healthAlert`); the layout is Today's: a critical-railed glass card (DESIGN_V2 §6.2
/// item 4, the §5.14 container) — a red rail, the title, the plain copy. Renders nothing when there is no
/// alert.
///
/// NARROW OBSERVATION (§2.1 rule 5): AppModel publishes 1–3×/s while a strap streams, and this banner needs
/// one field — so it reads `healthAlert` through a de-duplicated publisher into @State instead of observing
/// the whole model. The root is an always-present VStack so the subscription outlives an empty banner.
struct HealthAlertBanner: View {
    @Environment(\.appModelRef) private var appModelRef
    @State private var alert: AppModel.HealthAlert?

    var body: some View {
        VStack(spacing: 0) {
            if let alert {
                card(alert)
            }
        }
        .onReceive(alertPublisher) { next in
            if next != alert { alert = next }
        }
    }

    private var alertPublisher: AnyPublisher<AppModel.HealthAlert?, Never> {
        guard let model = resolvedAppModel(appModelRef) else { return Empty().eraseToAnyPublisher() }
        return model.$healthAlert.removeDuplicates().eraseToAnyPublisher()
    }

    private func card(_ alert: AppModel.HealthAlert) -> some View {
        let copy = localizedHealthAlertCopy(alert)
        let shape = RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous)
        return HStack(alignment: .top, spacing: TelosSpace.m) {
            // The rail: the one thing that makes this card read as "attention", without an alarm glyph wall.
            Capsule()
                .fill(TelosColor.critical)
                .frame(width: TelosStroke.rail)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "waveform.path.ecg")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(TelosColor.critical)
                        .accessibilityHidden(true)
                    Text("Body off baseline")
                        .telosScale()
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.critical)
                }
                Text(copy)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(TelosSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Faux glass with a critical wash — no material, no shadow (§2.1).
        .background(shape.fill(TelosColor.criticalWash))
        .background(NoopPanelSurface(tint: TelosColor.critical, cornerRadius: TelosRadius.card))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Body off baseline. \(copy)"))
    }
}

/// Home-facing rendering of the semantic illness result. Both Today variants share this banner,
/// so neither can accidentally expose the analytics engine's English notification copy.
func localizedHealthAlertCopy(_ alert: AppModel.HealthAlert) -> String {
    if alert.message == .raised {
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.activeLocale
        let signals = formatter.string(from: alert.firedSignals) ?? alert.firedSignals.joined(separator: ", ")
        return String(localized: "Your body looks strained. Signals up: \(signals). No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwellAgree {
        return String(localized: "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwell {
        return String(localized: "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.")
    }
    // The publisher gates the banner to raised/already-unwell. Keep the impossible fallback localized
    // and semantic rather than leaking `Result.copy` if a future caller bypasses that gate.
    return String(localized: "Nothing notable. Your signals look like their normal range.")
}
