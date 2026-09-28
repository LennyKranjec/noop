import SwiftUI
import StrandDesign
import StrandImport

// StrengthProgressionDetailView.swift — one exercise, in full.
//
// THE CHART IS THE APP'S OWN `TrendChart` WITH `touchScrub`, not a second chart written for this screen.
// That component already carries the crosshair, the tooltip, the pointer-hover/touch-drag parity and the
// VoiceOver summary every other trend in NOOP uses, and a scrub that behaved differently here would be the
// same defect as two charts disagreeing — the wearer learns one gesture, not one per screen.
//
// THE POINTS ARE SESSIONS, NOT DAYS. A wearer trains a lift twice a week, so a day-indexed series would be
// five sixths gaps; `TrendChart` takes dates and plots what it is given, so the line runs session to
// session and the x-axis still says when.
//
// THE REASONING IS SHOWN, not summarised. A suggestion the wearer cannot check is a suggestion they have to
// take on trust, and the numbers behind this one are all things they did: last session's top set, the rep
// range their recent sets have run, and the smallest weight step their own history for this lift shows.

struct StrengthProgressionDetailView: View {
    let exercise: StrengthProgression.Exercise
    /// Today's charge as the card read it, passed down rather than re-read: one number, two surfaces.
    let todayCharge: Double?

    private var isLowCharge: Bool {
        guard let charge = todayCharge else { return false }
        return charge < StrengthProgressionSource.lowChargeThreshold
    }

    var body: some View {
        // THE NAME IS `verbatim`, and it is in the content rather than in the scaffold's `subtitle`.
        // `subtitle` is a `LocalizedStringKey`, and passing an exercise the wearer typed through one would
        // make their own word a translation key — it would come back unchanged today and would be a real
        // defect the day a lift happened to be named something the catalog holds.
        ScreenScaffold(title: "Progression") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                Text(verbatim: exercise.name)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let reason = exercise.abstained {
                    abstentionCard(reason)
                } else {
                    chartCard
                    suggestionCard
                    historyCard
                }
                exclusionsCard
            }
        }
    }

    // MARK: - The chart

    private var chartCard: some View {
        let points = exercise.e1rmSeries.map { TrendPoint(date: $0.date, value: $0.value) }
        let values = points.map(\.value)
        // The domain is padded off the data rather than anchored at zero: a bench press moving 82 → 86 kg is
        // invisible on a 0…86 axis, and this chart's whole job is showing that four kilograms.
        let lo = (values.min() ?? 0) * 0.94
        let hi = (values.max() ?? 1) * 1.04
        return ChartCard(
            title: "Estimated one-rep max",
            subtitle: subtitle,
            trailing: exercise.currentE1rmKg.map { StrengthProgressionCopy.kgUnit($0) },
            chart: {
                TrendChart(points: points,
                           gradient: StrandPalette.recoveryGradient,
                           showsArea: true,
                           height: NoopMetrics.chartHeight,
                           showsHover: true,
                           touchScrub: true,
                           valueFormat: { StrengthProgressionCopy.kgUnit($0) },
                           accessibilityLabel: String(localized: "Estimated one-rep max by session"),
                           yDomain: lo < hi ? lo...hi : nil)
            },
            footer: { footerStats })
    }

    /// Epley is the headline; Brzycki is named beside it so the figure is attributable to a formula rather
    /// than presented as a measurement.
    private var subtitle: String {
        guard let current = exercise.currentE1rmKg, let date = exercise.currentDate else {
            return String(localized: "Epley, from sets of 1–\(StrengthProgression.maxReps) reps")
        }
        guard let brzycki = exercise.currentBrzyckiKg else {
            return String(localized: "Epley · \(StrengthProgressionCopy.kgUnit(current)) on \(StrengthProgressionCopy.day(date))")
        }
        // NOT localized, and deliberately so: two surnames, two formatted weights and a locale-formatted
        // date, separated by the app's own middle dot. There is no word in it to translate, and a catalog
        // key whose four translations are byte-identical to the English is a translation of nothing — the
        // audit counts exactly that as an untranslated echo, correctly.
        return "Epley \(StrengthProgressionCopy.kgUnit(current)) · Brzycki \(StrengthProgressionCopy.kgUnit(brzycki)) · \(StrengthProgressionCopy.day(date))"
    }

    private var footerStats: some View {
        ChartFooter([
            ("Best ever", exercise.bestEverE1rmKg.map { StrengthProgressionCopy.kgUnit($0) } ?? "—"),
            ("Top set", topSetText),
            // READABLE sessions, not every session this exercise appeared in: that is the count
            // `minSessions` is measured against, and printing the larger number would have the card say
            // "not enough sessions yet — 2 of 3" beside a footer claiming five.
            ("Sessions", "\(exercise.e1rmSeries.count)"),
            ("Step", exercise.incrementKg.map { StrengthProgressionCopy.kgUnit($0) } ?? "—"),
        ])
    }

    /// "90 kg × 5", or an em dash. NOT the set with the best estimate — the heaviest one, which is the set a
    /// wearer would name if asked what they lifted.
    private var topSetText: String {
        guard let kg = exercise.topWorkingWeightKg else { return "—" }
        guard let reps = exercise.topWorkingReps else { return StrengthProgressionCopy.kgUnit(kg) }
        return "\(StrengthProgressionCopy.kgUnit(kg)) × \(reps)"
    }

    // MARK: - The suggestion, with its reasoning

    @ViewBuilder
    private var suggestionCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next session").strandOverline()
                if let suggestion = exercise.suggestion {
                    Text(StrengthProgressionCopy.suggestion(suggestion))
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ForEach(StrengthProgressionCopy.reasons(for: exercise), id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text(line)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if isLowCharge {
                        Text("Charge is low today — this step can wait for a better day.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // THE HONEST END OF THE LINE. Reached when the rep range is topped out and the history
                    // shows a single weight for this lift, so there is no step to infer — and inventing a
                    // conventional 2.5 kg would be this app guessing at a machine it has never seen.
                    Text("No step to suggest yet: your recent sets are at the top of their rep range and this lift's history shows only one weight, so there is no increment to infer.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                trendLines
            }
        }
    }

    /// Every trend window that has a fit, each labelled with its own length. A window with fewer than two
    /// sessions is absent rather than shown as zero.
    @ViewBuilder
    private var trendLines: some View {
        let windows = StrengthProgression.trendWindowsWeeks.sorted().compactMap { exercise.trends[$0] }
        if !windows.isEmpty {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 0) {
                ForEach(windows, id: \.windowWeeks) { trend in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(trend.windowWeeks) weeks")
                            .textCase(.uppercase)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(StrengthProgressionCopy.signedKg(trend.deltaKg))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Per-session history

    private var historyCard: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Session history").strandOverline()
                // Newest first: the wearer is looking for what they did last time, which a chronological
                // list would put at the bottom of a year of rows.
                ForEach(Array(exercise.sessions.reversed().enumerated()), id: \.offset) { _, point in
                    sessionRow(point)
                }
            }
        }
    }

    private func sessionRow(_ point: StrengthProgression.SessionPoint) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StrengthProgressionCopy.day(point.date))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 92, alignment: .leading)
            // A session with no readable set shows an em dash in every column rather than a zero: it
            // happened, and the app could not estimate from it.
            Text(topSet(point))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(point.volumeKg > 0 ? StrengthProgressionCopy.kgUnit(point.volumeKg) : "—")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(point.bestE1rmKg.map { StrengthProgressionCopy.kgUnit($0) } ?? "—")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 76, alignment: .trailing)
        }
    }

    private func topSet(_ point: StrengthProgression.SessionPoint) -> String {
        guard let kg = point.topSetKg else { return "—" }
        guard let reps = point.topSetReps else { return StrengthProgressionCopy.kgUnit(kg) }
        return "\(StrengthProgressionCopy.kgUnit(kg)) × \(reps)"
    }

    // MARK: - Abstention and exclusions

    private func abstentionCard(_ reason: StrengthProgression.Abstention) -> some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Not enough to go on").strandOverline()
                Text(StrengthProgressionCopy.abstention(reason))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing is estimated from thin data — no provisional figure, no greyed-out number.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var exclusionsCard: some View {
        let lines = StrengthProgressionCopy.exclusions(exercise)
        if !lines.isEmpty {
            StrandCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Left out of the estimate").strandOverline()
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
