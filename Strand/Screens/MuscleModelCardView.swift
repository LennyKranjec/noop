import SwiftUI
import StrandAnalytics
import StrandDesign
import StrandImport

// MuscleModelCardView.swift — where the lifting volume went, by muscle group.
//
// SwiftUI twin of the Android `MuscleModelCard`.
//
// WHAT IT READS. The lifting importer attributes every counted set's volume load (weight × reps) to the
// muscles that moved it and banks a daily per-muscle total under `muscle_volume_<group>` on the
// "lifting" source. This card sums that over a trailing window. NOTHING here derives a number from
// heart rate: a strap cannot see which muscle did the work, so with no lifting log imported the whole
// body sits unlit and the card says so rather than shading it from strain.
//
// WHAT THE COLOUR MEANS. Each group is shaded by its Z-SCORE against its OWN frozen normal — how
// unusual this week's volume is for that muscle, on a constant scale that runs from two standard
// deviations below to two above. Mid-scale is a normal week; the top is a week twice its usual swing
// above one. Because the ends are constants and the norm never moves, a colour means the same thing
// next year as it does today, and the same thing on a calf as on a chest.
//
// IT USED TO BE A RANKING — each group as a share of the heaviest group that week — and a ranking
// re-scales itself every time you look at it: train nothing but chest and the chest is scarlet; train
// everything hard and the chest is the same scarlet. The colour could not say whether a week was heavy.
//
// A GROUP WITH NO FROZEN NORM YET falls back to that old relative shading, because a muscle needs a
// month of history before "normal for it" is a thing this app can honestly claim. The card says so in a
// line under the figure rather than letting the two scales sit side by side unannounced.
//
// A MUSCLE WITH TWO MOVERS IS COUNTED IN BOTH, so the column does not sum to the session's volume load
// and must never be presented as a split of it.
//
// THE FIGURE IS A DRAWING, NOT GEOMETRY. `body_front` / `body_back` are anatomical line art, prepared
// as WHITE-ON-TRANSPARENT so the card can tint them to the palette instead of being stuck with the
// source's grey — which is what lets the same asset sit on a dark card without a pale rectangle round
// it. Each group is its own mask cut from that same drawing, so the colour lands on the muscle's real
// outline rather than on an ellipse approximating it. The assets are the Android lane's, byte for byte.

/// How far back the card totals. A week is the usual training cycle and the Trends tab's own unit.
private let muscleWindowDays = 7

/// How far back the baseline derivation looks. Deliberately generous: the scale is frozen forever, so
/// it is worth reading everything the wearer has rather than the last training block.
private let muscleHistoryDays = 5 * 365

/// The shared canvas the figures and every mask are drawn on.
///
/// ONE ASPECT FOR BOTH SIDES. The two source drawings are the same height but different widths, so
/// scaling each to a fixed width made the broader back figure shorter — the card showed the same person
/// at two sizes depending on which way he was facing. Both are scaled by one factor and padded to this
/// canvas, which is also what lets a mask be composited over the figure with no offsets at all.
private let bodyAspect: CGFloat = 695.0 / 2100.0

/// How tall the figure is drawn.
///
/// A fixed height rather than an aspect on the width: the legend beside it is nine rows, and letting
/// the taller of the two decide left the body either clipped by the text above and below or stretched
/// to fill space it did not need. The column beside the figure takes this same height, so the height IS
/// the note's ceiling.
private let figureHeight: CGFloat = 372

/// The body view being shown. The back carries the muscles the front cannot (lats, glutes, hams).
private enum BodySide: String, CaseIterable, Identifiable {
    case front, back
    var id: String { rawValue }
    var label: String { self == .front ? "Front" : "Back" }
    var bodyImage: String { self == .front ? "body_front" : "body_back" }
}

/// This week's per-group volume, and the frozen scale it is judged against.
private struct MuscleLoads: Equatable {
    var thisWeek: [MuscleGroup: Double] = [:]
    var baselines: [MuscleGroup: MuscleBaseline] = [:]
}

struct MuscleModelCardView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var coach: AICoachEngine

    @State private var side: BodySide = .front
    @State private var loaded: MuscleLoads?
    @State private var note: String?
    /// Why there is no note, when the reason is something the wearer can fix. Nil when there IS one, or
    /// when the absence is not actionable.
    @State private var unavailableReason: String?

    private var data: [MuscleGroup: Double] { loaded?.thisWeek ?? [:] }

    private var scale: LoadScale {
        LoadScale(baselines: loaded?.baselines ?? [:], peak: data.values.max() ?? 0)
    }

    var body: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: 12) {
                header
                figureAndLegend
                footnote
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Muscle load")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Volume load per group, last 7 days")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Picker("", selection: $side) {
                ForEach(BodySide.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }

    // THE FIGURE GETS ITS OWN HEIGHT, and the column beside it takes the same one. Before this the two
    // shared a row and the figure took the height the LEGEND forced — nine legend rows are taller than a
    // 0.33-aspect body at this width, so the head and the feet were pushed under the title above and the
    // line below.
    //
    // THE LEGEND IS PINNED TO THE TOP of that column rather than centred in it, which is what opens the
    // space in the bottom right for the system's own reading of the chart.
    private var figureAndLegend: some View {
        HStack(alignment: .top, spacing: 12) {
            BodyCanvas(side: side, loads: data, scale: scale)
                .frame(height: figureHeight)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                // RANKED BY VOLUME, heaviest first, on both sides. The mask order is an ANATOMICAL order
                // — it is how the drawing is layered — and reading it as a ranking was the natural
                // mistake to make: the eye takes the top row for the biggest number. Sorting makes the
                // list say what it looks like it says.
                //
                // A group with no volume sorts last rather than being dropped, so the side's full
                // vocabulary is still visible and an untrained muscle is a visible blank.
                ForEach(rankedGroups, id: \.self) { group in
                    MuscleLegendRow(group: group, kg: data[group], scale: scale)
                }
                SystemNotePanel(text: note, unavailable: unavailableReason)
                Spacer(minLength: 0)
            }
            // MIN height, not a fixed one. The note reads the whole training week and now says more
            // than a caption, and a FIXED height meant the panel had exactly the room the legend left
            // over — about nine lines — and silently CLIPPED anything past it. The reading was being
            // written and then cut.
            //
            // A minimum keeps everything the fixed height bought: the column still matches the figure,
            // so the blank bottom-right corner is filled by the note before anything grows, and the
            // legend stays pinned to the top. It only differs once the note outgrows that corner, and
            // then the card grows DOWNWARD into the page rather than the text disappearing.
            .frame(minHeight: figureHeight, alignment: .top)
            .frame(maxWidth: .infinity)
        }
    }

    private var rankedGroups: [MuscleGroup] {
        masks(for: side).map(\.group).sorted { (data[$0] ?? -1) > (data[$1] ?? -1) }
    }

    @ViewBuilder
    private var footnote: some View {
        if loaded != nil && data.isEmpty {
            Text("No lifting log imported yet, so nothing here is lit. Import one from Data Sources.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else if loaded != nil && data.keys.contains(where: { scale.baselines[$0] == nil }) {
            // Said out loud: two scales are on screen, and the wearer should not have to guess which
            // groups are being judged against their own normal and which are still only ranked.
            Text("Some groups do not have a personal normal yet — those are shaded against this week's "
                 + "heaviest instead.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Reading the banked per-muscle totals

    /// Sum each group's `muscle_volume_<group>` rows over the trailing window, resolve the frozen scale,
    /// and ask for the note.
    ///
    /// A group with no rows in the window is ABSENT from the map, not zero: "you did not train it" and
    /// "you have no lifting log at all" are the same blank here, and the card says which by whether the
    /// whole map came back empty.
    ///
    /// The full history is read ONLY while some group is still unfrozen: once the scale has settled —
    /// which it does permanently, a month in — every open costs the seven-day read and nothing else.
    private func load() async {
        // EXACTLY seven calendar days, ending today. The seconds-offset read spans eight and would make
        // this card disagree with the Android one for the same import — which is precisely the kind of
        // quiet difference the parity contract exists to prevent.
        let calendar = Calendar.current
        let today = Date()
        let weekFrom = calendar.date(byAdding: .day, value: -(muscleWindowDays - 1), to: today) ?? today
        let todayKey = Repository.localDayKey(today)

        var week: [MuscleGroup: Double] = [:]
        for group in MuscleGroup.allCases {
            let rows = await repo.series(key: group.volumeKey, source: LiftingImporter.sourceId,
                                         from: Repository.localDayKey(weekFrom), to: todayKey)
            let sum = rows.reduce(0) { $0 + $1.value }
            if sum > 0 { week[group] = sum }
        }

        var baselines = MuscleBaselineStore.read()
        if MuscleBaselineStore.needsDerivation() {
            var history: [MuscleGroup: [Double]] = [:]
            let historyFrom = calendar.date(byAdding: .day, value: -muscleHistoryDays, to: today) ?? today
            for group in MuscleGroup.allCases where baselines[group] == nil {
                let rows = await repo.series(key: group.volumeKey, source: LiftingImporter.sourceId,
                                             from: Repository.localDayKey(historyFrom), to: todayKey)
                guard !rows.isEmpty else { continue }
                var daily: [String: Double] = [:]
                for row in rows { daily[row.day, default: 0] += row.value }
                history[group] = MuscleBaselines.rollingWindows(daily: daily, days: muscleWindowDays)
            }
            baselines = MuscleBaselineStore.resolve { history }
        }

        loaded = MuscleLoads(thisWeek: week, baselines: baselines)
        await loadNote(loads: week, baselines: baselines)
    }

    /// The stored note first, so an unchanged week paints immediately; only a changed fingerprint
    /// reaches the model.
    private func loadNote(loads: [MuscleGroup: Double], baselines: [MuscleGroup: MuscleBaseline]) async {
        guard !loads.isEmpty else {
            note = nil
            return
        }
        // WHY THE PANEL WAS EMPTY. The note is written by the coach, and the coach needs a provider and
        // the data consent. With neither set the generation returns nil and the panel simply did not
        // appear — which reads as a broken feature rather than as an un-set-up one. Say which it is.
        guard coach.isConfigured, coach.dataConsent else {
            note = nil
            unavailableReason = coach.isConfigured
                ? "Turn on data access in System to have the coach read this chart."
                : "Connect a model in System to have the coach read this chart."
            return
        }
        unavailableReason = nil
        let fingerprint = MuscleCoachNote.fingerprint(loads)
        if let stored = MuscleCoachNote.stored(fingerprint: fingerprint) {
            note = stored
            return
        }
        let answer = await coach.generateOneShot(
            systemPrompt: MuscleCoachNote.systemPrompt(loads: loads, baselines: baselines),
            question: MuscleCoachNote.question)
        guard let answer else { return }
        let clipped = String(answer.prefix(MuscleCoachNote.maxChars))
        MuscleCoachNote.write(clipped, fingerprint: fingerprint)
        note = clipped
    }
}

// MARK: - The system's own reading of the chart

/// In the corner the legend no longer fills.
///
/// ITS OWN SURFACE, one step down from the card's, so it reads as something laid IN the panel rather
/// than as another line of the legend — the wearer should be able to tell at a glance which numbers the
/// app measured and which sentence a model wrote about them.
///
/// ABSENT RATHER THAN EMPTY when there is no note: no consent, no provider configured, or an empty
/// answer. A placeholder would be a promise the card cannot keep.
private struct SystemNotePanel: View {
    let text: String?
    /// Shown INSTEAD of the note when there is a reason the wearer can act on. An empty corner says
    /// nothing; "connect a model" says what to do.
    var unavailable: String?

    var body: some View {
        if let unavailable, text == nil {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.top, 1)
                Text(unavailable)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 8)
        } else if let text, !text.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.top, 1)
                // MARKDOWN, like every other line the model writes in this app. It is told not to use
                // it, but a model told not to use markdown still emits the occasional **bold**, and raw
                // asterisks on screen read as a bug rather than as emphasis.
                Text(markdown(text))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, 8)
        }
    }

    private func markdown(_ raw: String) -> AttributedString {
        (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(raw)
    }
}

// MARK: - The legend

private struct MuscleLegendRow: View {
    let group: MuscleGroup
    let kg: Double?
    let scale: LoadScale

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(scale.color(group, kg, litOpacity: 1, unlitOpacity: 0.35))
                .frame(width: 8, height: 8)
            Text(MuscleCoachNote.label(group).capitalizedFirst)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(kg.map { "\(Int($0.rounded())) kg" } ?? "–")
                .font(StrandFont.captionNumber)
                .foregroundStyle(kg == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        }
    }
}

// MARK: - The colour scale

/// How a kilogram figure becomes a position on the colour ramp.
///
/// ONE type so the body and the legend dot cannot disagree: they used to work the arithmetic out
/// separately, which was fine while it was one division and would not have stayed fine.
private struct LoadScale {
    let baselines: [MuscleGroup: MuscleBaseline]
    /// Heaviest group this week, for the groups whose own normal is not frozen yet.
    let peak: Double

    func fraction(_ group: MuscleGroup, _ kg: Double) -> Double {
        if let frozen = baselines[group] { return MuscleBaselines.fraction(frozen, kg) }
        return peak > 0 ? kg / peak : 0
    }

    /// Shade for a group's load. Nil or zero load = unlit.
    func color(_ group: MuscleGroup, _ kg: Double?, litOpacity: Double, unlitOpacity: Double) -> Color {
        guard let kg, kg > 0 else { return StrandPalette.textTertiary.opacity(unlitOpacity) }
        return StrandPalette.effortTint(fraction: fraction(group, kg)).opacity(litOpacity)
    }
}

// MARK: - The body

/// One muscle group's own shape, on this side of the body.
///
/// Each is an alpha mask cut from the same drawing the figure comes from — the real outline of the real
/// muscle, not an ellipse approximating where it sits. A group is ONE mask even when it is several
/// bellies (a quadriceps is four), because the card colours groups and the runtime has no reason to
/// know how many muscles make one up.
///
/// Front and back carry different sets: a lat cannot be seen from the front, a pec cannot be seen from
/// the back, and offering a group on a side that does not show it would paint nothing and read as a bug.
private struct MuscleMask {
    let group: MuscleGroup
    let image: String
}

private func masks(for side: BodySide) -> [MuscleMask] {
    switch side {
    case .front:
        return [
            .init(group: .shoulders, image: "muscle_front_shoulders"),
            .init(group: .chest, image: "muscle_front_chest"),
            .init(group: .upperBack, image: "muscle_front_upper_back"),
            .init(group: .biceps, image: "muscle_front_biceps"),
            .init(group: .triceps, image: "muscle_front_triceps"),
            .init(group: .forearms, image: "muscle_front_forearms"),
            .init(group: .abs, image: "muscle_front_abs"),
            .init(group: .quadriceps, image: "muscle_front_quadriceps"),
            .init(group: .calves, image: "muscle_front_calves"),
        ]
    case .back:
        return [
            .init(group: .shoulders, image: "muscle_back_shoulders"),
            .init(group: .upperBack, image: "muscle_back_upper_back"),
            .init(group: .lats, image: "muscle_back_lats"),
            .init(group: .triceps, image: "muscle_back_triceps"),
            .init(group: .forearms, image: "muscle_back_forearms"),
            .init(group: .lowerBack, image: "muscle_back_lower_back"),
            .init(group: .glutes, image: "muscle_back_glutes"),
            .init(group: .hamstrings, image: "muscle_back_hamstrings"),
            .init(group: .calves, image: "muscle_back_calves"),
        ]
    }
}

private struct BodyCanvas: View {
    let side: BodySide
    let loads: [MuscleGroup: Double]
    let scale: LoadScale

    var body: some View {
        ZStack {
            // THE LOAD GOES UNDER THE LINE ART. Painted on top, the colour swallows the very contours it
            // is meant to be highlighting and the figure turns into flat blobs; underneath, the drawing's
            // own shading reads through it and a loaded muscle looks lit rather than stickered.
            ForEach(masks(for: side), id: \.image) { mask in
                let fill = scale.color(mask.group, loads[mask.group], litOpacity: 0.88, unlitOpacity: 0)
                Image(mask.image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(fill)
            }
            Image(side.bodyImage)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(StrandPalette.textSecondary.opacity(0.55))
        }
        .aspectRatio(bodyAspect, contentMode: .fit)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
