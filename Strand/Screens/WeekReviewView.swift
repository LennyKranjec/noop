import SwiftUI
import StrandAnalytics
import StrandDesign

// WeekReviewView.swift — the Monday review (HEALTH_V2 S3 §3.6): last week's plan vs done, trends, the ONE
// suggested change and the trial status. Deterministic content from `WeekReview`; the coach narrates the
// same struct (`WeekReview.coachBlock`). No push notification exists for it.
//
// Layout (DESIGN_V2 §6.14, BODY): MetricReadout-led — the week's aerobic minutes as the lead reading (the
// component the plan is built around), then the one change, the per-component rows with a status line as
// well as a dot (never colour alone), the trend lines, VO₂max as an integer with its ±band (H15, the line
// comes from `WeekReview.vo2Line`), the trial status and the Look ahead entry (decision 13).
// COST: static; no animation.

struct WeekReviewView: View {
    let review: WeekReview

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "Week review"))
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                Spacer(minLength: TelosSpace.s)
                Text(review.weekStart + " – " + review.weekEnd)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }

            if let aerobic = review.components.first(where: { $0.component == .aerobic }) {
                // The lead reading. A week without a measurement abstains with the component's own line
                // (which carries its reason), never a zero.
                MetricReadout("Aerobic",
                              value: aerobic.done,
                              unit: "min",
                              absentReason: Text(verbatim: WeekReview.componentLine(aerobic)),
                              provenance: Self.targetProvenance(aerobic),
                              ink: Self.tint(aerobic.status))
            }

            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                Text(String(localized: "One change for this week"))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textSecondary)
                Text(review.suggestion.text)
                    .font(TelosType.headline)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(review.components, id: \.component) { c in
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Circle()
                        .fill(Self.tint(c.status))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(WeekReview.componentLine(c))
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(review.trendLines, id: \.self) { line in
                Text(line)
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(WeekReview.vo2Line(review.vo2, review.vo2Abstention))
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let trial = review.trialStatus {
                Text(trial)
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Look ahead (decision 13): where the current trend and the plan lead. Pushes inside the host's
            // navigation (the Health tab); the destination hands `LookAheadView` the model it needs.
            NavigationLink {
                LookAheadDestination()
            } label: {
                TelosListRow("Look ahead", systemImage: "chart.line.uptrend.xyaxis",
                             iconTint: TelosColor.mint, showsChevron: true)
            }
            .buttonStyle(TelosRowButtonStyle())
        }
    }

    /// "/ 130 min" — the week's (effective) target, when the plan had one.
    static func targetProvenance(_ c: ComponentResult) -> TelosProvenance? {
        guard let target = c.effectiveTarget ?? c.planned, target.isFinite else { return nil }
        return TelosProvenance(sourceText: nil, window: Text(verbatim: "/ \(Int(target.rounded())) min"))
    }

    /// Status dots. A miss uses the warning tone, not the critical one: a missed week is information for
    /// the next plan, not an alarm. "Not measured" and "no target" stay neutral.
    static func tint(_ s: ComponentStatus) -> Color {
        switch s {
        case .met: return StrandPalette.statusPositive
        case .partly: return StrandPalette.metricAmber
        case .missed: return StrandPalette.statusWarning
        case .notMeasured, .notAsked: return StrandPalette.textTertiary
        }
    }
}
