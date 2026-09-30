import SwiftUI
import StrandDesign

// TodayTrioHeroView.swift — REST / CHARGE / EFFORT, the glass panel of three thin luminous rings.
//
// Telos 2.0 (DESIGN_V2 VISUAL DIRECTION, 1:1 with docs/design-ref/telos-v2-today.jpg): one faux-glass
// panel, three large thin `TelosRing`s with the value inside, the label below in wide-tracked caps, a
// small glyph and one secondary line. Same data and the same three destinations as before (Rest → Sleep,
// Charge → scoring guide, Effort → the Effort dossier).
//
// HONEST RINGS. An absent score is a dashed bare track with "—", never a zero arc. A carried score draws
// at half opacity and the footer names the day it is from. A provisional score (calibrating / building)
// carries its `ConfidenceTag` and, when calibrating, a dotted arc. Effort's day target is a hollow caret
// on the same axis, labelled "typical range" (HEALTH_V2 H2) — it is a population band on this morning's
// Charge, not the wearer's own ceiling. Rings are unbounded: an Effort past one lap wraps visibly.
//
// Cost (§2.1 rule 8): shapes only (`TelosRing`), no clock; a ring animates only when its value changes.

/// WHOOP's strain ceiling. Their scale is 0–21, not 0–100.
let whoopStrainMax: Double = 21

/// One ring's worth of input.
struct HeroScore: Identifiable {
    let id: Int
    let label: LocalizedStringKey
    /// The reading on `scale` (nil = absent).
    let value: Double?
    /// One lap of the ring (100 for the 0–100 scores).
    var scale: Double = 100
    /// The centre numeral (count-up on a new value only).
    var format: (Double) -> String = TelosFormat.integer
    var unit: String? = nil
    let tint: Color
    /// An optional target on the same scale (Effort's typical-range top).
    var target: Double? = nil
    /// The small glyph under the label.
    let glyph: String
    /// The secondary line under the glyph ("Asleep 7h 48m", "Solid", "Typical range ≤ 72").
    var secondary: String? = nil
    var confidence: TelosConfidence = .solid
    var isCarried: Bool = false
    /// The VoiceOver sentence for the ring (value, unit and confidence).
    let accessibilityText: String
}

struct TodayTrioHeroView: View {
    let scores: [HeroScore]
    /// The day these figures are actually from, when it is NOT the day on screen (a carried cloud day).
    var carriedFrom: String? = nil
    let onTapScore: (Int) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            if typeSize.isAccessibilitySize {
                // Large text: one row per score (a 44 pt ring beside the reading), so no number truncates.
                VStack(spacing: TelosSpace.m) {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, score in
                        Button { tap(index) } label: { HeroScoreRow(score: score) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(TelosSpace.l)
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(scores.enumerated()), id: \.element.id) { index, score in
                        if index > 0 {
                            // The hairline between rings, inset top and bottom.
                            Rectangle()
                                .fill(TelosColor.line)
                                .frame(width: TelosStroke.line)
                                .padding(.vertical, TelosSpace.l)
                        }
                        Button { tap(index) } label: { HeroRingColumn(score: score) }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, TelosSpace.l)
                .padding(.horizontal, TelosSpace.s)
            }

            if let carriedFrom {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                    // IT SAYS WHAT IT IS: a repeat, with the date it is a repeat OF.
                    Text("Repeating \(carriedFrom) — nothing scored for today yet")
                        .font(TelosType.scaleNumber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(TelosColor.textTertiary)
                .padding(.horizontal, TelosSpace.l)
                .padding(.vertical, TelosSpace.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TelosColor.surfaceInset.opacity(0.55))
            }
        }
        // Clipped to the panel's curve so the footer band's square corners never poke past it.
        .clipShape(RoundedRectangle(cornerRadius: TelosRadius.hero, style: .continuous))
    }

    private func tap(_ index: Int) {
        TelosHaptics.play(.select)
        onTapScore(index)
    }
}

/// One column: the ring, the caps label, the glyph and the secondary line.
private struct HeroRingColumn: View {
    let score: HeroScore
    private let ringSize: CGFloat = 96

    var body: some View {
        VStack(spacing: TelosSpace.s) {
            TelosRing(value: score.value, scale: score.scale, color: score.tint, diameter: ringSize,
                      format: score.format, unit: score.unit, target: score.target,
                      confidence: score.confidence, isCarried: score.isCarried)
            Text(score.label)
                .font(TelosType.labelLarge)
                .tracking(TelosType.Tracking.labelLarge)
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Image(systemName: score.glyph)
                .font(TelosType.glyphRow)
                .foregroundStyle(score.tint)
            if let secondary = score.secondary {
                Text(verbatim: secondary)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if !score.confidence.isSolid {
                ConfidenceTag(score.confidence)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: score.accessibilityText))
        .accessibilityAddTraits(.isButton)
    }
}

/// The large-text form: a compact ring beside the reading.
private struct HeroScoreRow: View {
    let score: HeroScore

    var body: some View {
        HStack(spacing: TelosSpace.m) {
            TelosRing(value: score.value, scale: score.scale, color: score.tint, diameter: 44,
                      format: score.format, target: score.target, confidence: score.confidence,
                      isCarried: score.isCarried, showsValue: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(score.label)
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textSecondary)
                Text(verbatim: score.value.map { score.format($0) + (score.unit ?? "") } ?? TelosType.absent)
                    .font(TelosType.numeralL)
                    .foregroundStyle(score.value == nil ? TelosColor.textTertiary : TelosColor.textPrimary)
                if let secondary = score.secondary {
                    Text(verbatim: secondary)
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !score.confidence.isSolid { ConfidenceTag(score.confidence) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(TelosType.glyphChevron)
                .foregroundStyle(TelosColor.textTertiary)
        }
        .frame(minHeight: TelosSpace.hitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: score.accessibilityText))
        .accessibilityAddTraits(.isButton)
    }
}

/// A whole-number percentage, or "—" when the day has no reading.
func heroPercent(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? TelosType.absent
}

/// The 0–1 arc fraction for a score. Nil stays nil, so the ring is left as bare track.
func heroFraction(_ value: Double?, max maximum: Double = 100) -> Double? {
    value.map { Swift.min(Swift.max($0 / maximum, 0), 1) }
}
