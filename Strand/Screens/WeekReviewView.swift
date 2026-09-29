import SwiftUI
import StrandAnalytics
import StrandDesign

// WeekReviewView.swift — the Monday review (HEALTH_V2 S3 §3.6): last week's plan vs done, trends, the ONE
// suggested change and the trial status. Deterministic content from `WeekReview`; the coach narrates the
// same struct (`WeekReview.coachBlock`). No push notification exists for it.
//
// Tokens only; the BODY design package decides the final layout (MetricReadout-led, DESIGN_V2 §6.14).
// COST: static; no animation.

struct WeekReviewView: View {
    let review: WeekReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Week review")).strandOverline()
            Text(review.weekStart + " – " + review.weekEnd)
                .font(StrandFont.mono(12))
                .foregroundStyle(StrandPalette.textTertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "One change for this week"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(review.suggestion.text)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(review.components, id: \.component) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(Self.tint(c.status))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(WeekReview.componentLine(c))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(review.trendLines, id: \.self) { line in
                Text(line)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(WeekReview.vo2Line(review.vo2, review.vo2Abstention))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let trial = review.trialStatus {
                Text(trial)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
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
