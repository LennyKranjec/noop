import SwiftUI
import StrandDesign

// TodayTrioHeroView.swift — the three scores, as rings.
//
// SwiftUI twin of the Android `TodayTrioHero`. Sleep, Recovery and Strain across the top of Today, each
// a ring with its figure in the middle, hairline dividers between them, and a footer strip carrying the
// day and where the numbers came from.
//
// WHAT THE ARC SHOWS IS THE VALUE, and that is a deliberate departure from the design this was drawn
// from. That design puts a hatched band on the strain ring with white caps at its ends — a TARGET
// RANGE, which is a feature that app has and this one does not. Reproducing the band would have drawn a
// recommendation with no number behind it. The arc here is the reading itself, on the same geometry, in
// the same weight; the day's optimum is a single notch, which this app can actually compute.
//
// STRAIN IS ON WHOOP'S OWN 0-21 SCALE, never a percentage. The tile shows WHOOP's figures under WHOOP's
// name, and restating 14.9 as "71 %" would be this app putting their number into units they do not use.
//
// AN ABSENT SCORE IS DRAWN AS "–", with its ring left as bare track. Not zero: a day with no recovery
// reading and a day whose recovery was genuinely nil are different statements, and only the second is a
// number.
//
// THE FOOTER'S RIGHT SIDE ANSWERS "ARE THESE CURRENT?". Three scores with no provenance invite exactly
// one question, so the source the day was resolved from sits there.

/// WHOOP's strain ceiling. Their scale is 0–21, not 0–100, and the ring's arc is read against it.
let whoopStrainMax: Double = 21

/// One ring's worth of input.
struct HeroScore: Identifiable {
    let id: Int
    let label: LocalizedStringKey
    let text: String
    /// 0–1 for the arc, or nil when the day has no reading.
    let fraction: Double?
    let tint: Color
    /// An optional reference mark on the ring, 0–1 on the same scale as `fraction`.
    ///
    /// The strain ring uses it for the day's OPTIMAL strain, so the arc can be read against the target
    /// rather than against nothing: a 15.0 means something different on a 92 % recovery than on a 19 %,
    /// and the number alone cannot say which.
    let mark: Double?

    init(id: Int, label: LocalizedStringKey, text: String, fraction: Double?, tint: Color, mark: Double? = nil) {
        self.id = id
        self.label = label
        self.text = text
        self.fraction = fraction
        self.tint = tint
        self.mark = mark
    }
}

struct TodayTrioHeroView: View {
    let scores: [HeroScore]
    /// The day these figures are actually from, when it is NOT the day on screen.
    ///
    /// The footer used to carry the date unconditionally, and that was redundant — the day selector at
    /// the top of Today already says which day you are looking at. It is not redundant in one case: when
    /// WHOOP has not scored today yet and the rings are showing last night's numbers. Removing the row
    /// outright would have taken the honesty with the repetition, so what survives is only the part that
    /// says something the screen does not.
    var carriedFrom: String? = nil
    /// The sky, on the footer's own line. Nil drops the row entirely: a failed lookup shows nothing
    /// rather than a guess.
    var weather: WeatherNow? = nil
    let onTapScore: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(scores.enumerated()), id: \.element.id) { index, score in
                    if index > 0 {
                        // The hairline between rings, inset top and bottom so it reads as a divider
                        // rather than as a full-height column rule.
                        Rectangle()
                            .fill(StrandPalette.hairline.opacity(0.7))
                            .frame(width: 1, height: 96)
                    }
                    HeroRingView(score: score)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            StrandHaptic.selection.play()
                            onTapScore(index)
                        }
                }
            }
            .padding(.vertical, 16)

            // NO SOURCE BADGE: "WHOOP" under three rings labelled with WHOOP's own scores is a
            // caption for a caption. And no date, EXCEPT when the figures are carried — see `carriedFrom`.
            if let carriedFrom {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                    // IT SAYS WHAT IT IS: a repeat, with the date it is a repeat OF. The old wording
                    // led with the absence — "today is not scored yet" — which reads as broken data
                    // rather than as the deliberate carry it is, and which is now only ever shown when
                    // this app has nothing of its own for today either.
                    Text("Repeating \(carriedFrom) — nothing scored for today yet")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceBase.opacity(0.55))
            }
            // THE SKY, under the day. It is here rather than on a card of its own because it is not a
            // metric — it is context for the three above it, and for what the coach suggests doing
            // about them. The row is absent when the lookup failed; an invented forecast would be the
            // kind of plausible number this app refuses to print.
            if let weather {
                HStack(spacing: 6) {
                    Image(systemName: weather.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Text("\(Int(weather.temperatureC.rounded()))°C · \(weather.summary)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 0)
                    // NOW AND PEAK, because the two answer different questions: what it is like to step
                    // outside right now, and whether the middle of the day is worth avoiding.
                    Image(systemName: "sun.max")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(uvTint(weather.uvIndex))
                    Text(String(format: "UV %.1f · peak %.1f", weather.uvIndex, weather.uvPeak))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 9)
                .background(StrandPalette.surfaceBase.opacity(0.55))
                .accessibilityElement(children: .combine)
            }
        }
        // CLIPPED to the card's own curve: the footer is a plain filled row, and a fill does not know
        // about the rounded card it sits in — its square corners would poke past the curve at the bottom.
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// The UV figure's own colour. The WHO bands, because they are the ones the number is quoted against
/// everywhere else a wearer will have met it.
private func uvTint(_ uv: Double) -> Color {
    switch uv {
    case ..<3: return StrandPalette.statusPositive
    case ..<6: return StrandPalette.statusWarning
    default: return StrandPalette.statusCritical
    }
}

private struct HeroRingView: View {
    let score: HeroScore

    private let ringSize: CGFloat = 92
    private let stroke: CGFloat = 9

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // The inner disc, which is what gives the reference its dial look — the figure sits ON
                // something rather than floating in a hole.
                Circle()
                    .fill(StrandPalette.surfaceRaised.opacity(0.55))
                    .padding(stroke * 1.05)

                Circle()
                    .stroke(StrandPalette.surfaceInset, lineWidth: stroke)

                if let fraction = score.fraction, fraction > 0 {
                    Circle()
                        .trim(from: 0, to: min(max(fraction, 0), 1))
                        .stroke(score.tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                        // Starts at twelve and runs clockwise, which is the direction a dial is read.
                        .rotationEffect(.degrees(-90))
                }

                // THE TARGET NOTCH, drawn LAST so it sits ON the arc rather than under it. Beneath, an
                // arc that had passed the optimum would cover the very line that says so — exactly the
                // day the mark matters most.
                if let mark = score.mark, mark > 0 {
                    Rectangle()
                        .fill(StrandPalette.textPrimary.opacity(0.85))
                        .frame(width: 2.5, height: stroke + 2)
                        .offset(y: -(ringSize - stroke) / 2)
                        .rotationEffect(.degrees(360 * min(max(mark, 0), 1)))
                }

                Text(score.text)
                    .font(.system(size: 24, weight: .bold))
                    // Tabular figures, for the same reason the level has them: these count up, and
                    // proportional digits make the number shuffle sideways as they do.
                    .monospacedDigit()
                    .foregroundStyle(
                        score.fraction == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary
                    )
            }
            .frame(width: ringSize, height: ringSize)

            Text(score.label)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
        }
    }
}

/// A whole-number percentage, or "–" when the day has no reading.
func heroPercent(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "–"
}

/// The 0–1 arc fraction for a score. Nil stays nil, so the ring is left as bare track.
func heroFraction(_ value: Double?, max maximum: Double = 100) -> Double? {
    value.map { Swift.min(Swift.max($0 / maximum, 0), 1) }
}
