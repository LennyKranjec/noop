import SwiftUI
import StrandAnalytics
import StrandDesign

// VitalTrioCardView.swift — heart, lungs and sleep, directly under the muscle model.
//
// SwiftUI twin of the Android `VitalTrioCard`. Three of the level's five parts, each as its own tile:
// the three-day mean, a vertical bar against the part's frozen optimum, what it is WORTH to the level,
// and which way it has moved.
//
// NO HEADING OF THEIR OWN. The figure above already says what this part of the screen is, and a title
// here would label a label.
//
// THE THIRD TILE IS THE SLEEP DOOR. A full-width button whose only job was to open the thing shown
// directly above it has been removed — it could have been the thing itself, and now is.
//
// THE SHARE IS THE POINT OF THE FOOTER. A lungs score of 20 looks worse than a sleep score of 60 and is
// worth a third as much level; without the share the three tiles invite exactly that misreading.

struct VitalTrioCardView: View {
    /// The level snapshot the strip already computed — passed in rather than recomputed, because this
    /// screen sits under the same bar and two independent computations of one number is how they drift.
    let trend: LevelTrendSnapshot?
    let onOpenSleep: () -> Void

    private static let parts: [LevelPart] = [.heart, .lungs, .sleep]

    var body: some View {
        HStack(spacing: NoopMetrics.gap) {
            ForEach(Self.parts, id: \.rawValue) { part in
                VitalTileView(
                    part: part,
                    component: trend?.now?.components.first { $0.part == part },
                    previous: trend?.threeDaysAgo?.components.first { $0.part == part }?.score,
                    total: trend?.now,
                    onTap: part == .sleep ? onOpenSleep : nil
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct VitalTileView: View {
    let part: LevelPart
    let component: LevelComponent?
    let previous: Double?
    let total: LevelBreakdown?
    let onTap: (() -> Void)?

    private var score: Double? { component?.score }

    /// What this metric is worth to the level, as a percentage of the whole.
    private var share: Double? {
        guard let component, let total, total.raw > 0 else { return nil }
        return component.contribution / total.raw * 100
    }

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 8) {
            // Header: the glyph and the metric's name.
            HStack(spacing: 6) {
                Image(systemName: levelPartIcon(part))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(levelPartLabel(part))
                    .font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }

            // Body: the three-day mean, and the vertical bar beside it.
            HStack(alignment: .center) {
                Text(score.map { "\(Int($0.rounded()))" } ?? "–")
                    .font(score != nil ? StrandFont.title2 : StrandFont.footnote)
                    .foregroundStyle(score != nil ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                OptimumBar(fraction: (score ?? 0) / 100, tint: levelPartTint(part), lit: score != nil)
            }

            // Footer: what it is worth, and which way it is going.
            Text(share.map { "\(Int($0.rounded()))% of level" } ?? " ")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            HStack(spacing: 2) {
                Text("lvl \(score.map { Int($0.rounded()) } ?? 0)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                TrendArrow(now: score, then: previous)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))

        if let onTap {
            Button {
                SystemHaptics.play(.tap)
                onTap()
            } label: { tile }
            .buttonStyle(.plain)
        } else {
            tile
        }
    }
}

/// The vertical bar, filled from the bottom.
///
/// Empty at the metric's frozen floor and full at its frozen optimum. Two stacked shapes rather than a
/// progress view so the unfilled part keeps its own colour, which is what makes the fill legible at this
/// size.
private struct OptimumBar: View {
    let fraction: Double
    let tint: Color
    let lit: Bool

    private let width: CGFloat = 10
    private let height: CGFloat = 56

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack(alignment: .bottom) {
            Capsule().fill(StrandPalette.surfaceInset)
            if lit, clamped > 0 {
                Capsule().fill(tint).frame(height: height * clamped)
            }
        }
        .frame(width: width, height: height)
    }
}

/// Better or worse than the three-day mean three days ago, and BY HOW MANY POINTS.
///
/// The number is the point, exactly as in the level strip's own trend chips: an arrow alone answers
/// "better or worse" and leaves the size of it to the imagination, and on a 0–100 score the difference
/// between +1 and +9 is the difference between noise and a week that worked.
///
/// NOTHING WHEN NOTHING MOVED. A move under one point is rounding on this scale, and a flat dash beside
/// a "0" fills the row with the news that there is no news.
private struct TrendArrow: View {
    let now: Double?
    let then: Double?

    var body: some View {
        if let now, let then {
            let delta = now - then
            let points = Int(delta.rounded())
            if abs(delta) >= 1, points != 0 {
                let up = delta > 0
                let tint = up ? StrandPalette.statusPositive : StrandPalette.statusCritical
                HStack(spacing: 1) {
                    Image(systemName: up ? "arrow.up" : "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                    // SIGNED, because an unsigned "4" beside a down arrow states the same thing twice
                    // and invites the reader to work out which of the two is the right way round.
                    Text(points > 0 ? "+\(points)" : "\(points)")
                        .font(StrandFont.caption)
                        .foregroundStyle(tint)
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - The level parts' vocabulary
//
// Shared with the level strip, so a part cannot wear one colour in the bar and another on this card.

func levelPartIcon(_ part: LevelPart) -> String {
    switch part {
    case .sleep: return "moon.zzz.fill"
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

func levelPartLabel(_ part: LevelPart) -> String {
    switch part {
    case .sleep: return "SLEEP"
    case .heart: return "HEART"
    case .lungs: return "LUNGS"
    case .muscle: return "MUSCLE"
    case .focus: return "FOCUS"
    }
}
