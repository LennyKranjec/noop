import SwiftUI
import StrandAnalytics
import StrandDesign

// LevelTimelineSheetView.swift — where the level has been.
//
// SwiftUI twin of the Android `LevelTimelineSheet`. One line, the same range control the app's other
// daily charts use, and a labelled y-axis.
//
// THE LINE IS RE-COMPUTED, NOT STORED. Each day is the formula run over the data as it stood that day,
// against the ONE frozen scale. A cached level would have been measured against whatever scale existed
// on the day it was written, and the curve would then show the yardstick moving as though the body had.
//
// THE Y-AXIS IS PINNED TO 0–100, which is the level's real domain, and LABELLED. Auto-scaling would
// redraw a steady month as a mountain range; a fixed scale with no rules leaves the reader unable to
// say whether the line is sitting at 40 or at 80. The gridlines are what turn the one into the other.
//
// THE HEAD OF THE PANEL IS THE SYSTEM TALKING, not a label. A title saying "Level over time" says only
// what the chart underneath already shows; a line naming which parts are carrying the level and which
// is costing it says the thing the radar cannot.

/// The ranges offered, matching the app's other daily charts.
private enum LevelSpan: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case year = 365
    /// Everything stored. A ceiling rather than a true "all": the loader clamps the span to the
    /// earliest day that actually exists, so this asks for more than there is and gets what there is.
    case all = 3650

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .week: return "7d"
        case .month: return "30d"
        case .quarter: return "90d"
        case .year: return "1y"
        case .all: return "All"
        }
    }
}

/// The plot's left gutter: the axis labels live here so they never overlap the line they explain.
private let axisGutter: CGFloat = 26

struct LevelTimelineSheetView: View {
    @ObservedObject var model: LevelBarModel
    let repo: Repository

    @EnvironmentObject private var coach: AICoachEngine

    @Environment(\.dismiss) private var dismiss
    @State private var span: LevelSpan = .month
    /// The system's own daily line about the weighting. Nil until one has been written — the panel then
    /// falls back to reading the breakdown itself rather than showing a placeholder.
    @State private var note: String?

    /// Where the rules are drawn. Quarters of the level's range — five lines is an axis, nine is graph
    /// paper.
    private let ticks = [0, 25, 50, 75, 100]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header

                Picker("", selection: $span) {
                    ForEach(LevelSpan.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)

                chart

                if model.history.count >= 2 {
                    let values = model.history.map(\.level)
                    HStack {
                        foot("low", Int((values.min() ?? 0).rounded()))
                        Spacer()
                        foot("mean", Int((values.reduce(0, +) / Double(values.count)).rounded()))
                        Spacer()
                        foot("high", Int((values.max() ?? 0).rounded()))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Level")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task(id: span.rawValue) { await model.loadHistory(repo: repo, spanDays: span.rawValue) }
        .task(id: model.trend?.now?.level) { await loadNote() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
            Text(note ?? headline)
                .font(.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The system's line, written at most once a day and only when the level has actually moved.
    ///
    /// The stored one first, so an unchanged level paints immediately; only a changed fingerprint reaches
    /// the model. A nil answer leaves `headline` in place, which is the same sentence derived from the
    /// breakdown arithmetically — honest, if less pointed.
    private func loadNote() async {
        guard let breakdown = model.trend?.now else { return }
        let fingerprint = LevelCoachNote.fingerprint(breakdown)
        if let stored = LevelCoachNote.stored(fingerprint: fingerprint) {
            note = stored
            return
        }
        let answer = await coach.generateOneShot(
            systemPrompt: LevelCoachNote.systemPrompt(breakdown),
            question: LevelCoachNote.question)
        guard let answer else { return }
        let clipped = String(answer.prefix(LevelCoachNote.maxChars))
        LevelCoachNote.write(clipped, fingerprint: fingerprint)
        note = clipped
    }

    /// Which parts are carrying the level and which is costing it, from the breakdown itself.
    ///
    /// Read rather than interpreted: the components already carry their contribution in POINTS OF
    /// LEVEL, so naming the biggest and the most expensive is arithmetic that is already done. A part
    /// with a small weight cannot carry anything, which is why this never ranks by the bare score.
    private var headline: String {
        guard let breakdown = model.trend?.now else { return "Level over time" }
        let scored = breakdown.components.filter { $0.score != nil }
        guard !scored.isEmpty else { return "Level over time" }
        let carrying = scored.sorted { $0.contribution > $1.contribution }.prefix(2)
        let names = carrying.map { partName($0.part) }.joined(separator: " and ")
        guard let costing = scored.max(by: { $0.headroom < $1.headroom }), costing.headroom > 1 else {
            return "Carried by \(names)."
        }
        return "Carried by \(names) — \(partName(costing.part)) is costing you "
            + "\(Int(costing.headroom.rounded())) points."
    }

    private func partName(_ part: LevelPart) -> String {
        switch part {
        case .sleep: return "sleep"
        case .heart: return "heart"
        case .lungs: return "lungs"
        case .muscle: return "training volume"
        case .focus: return "focus"
        }
    }

    @ViewBuilder
    private var chart: some View {
        if model.loadingHistory {
            placeholder("Working it out…")
        } else if model.history.count < 2 {
            // Two points is the fewest that can be a line. One is a dot, and drawing it as a flat line
            // across the panel would say the level had been steady all month.
            placeholder("Not enough scored days yet.")
        } else {
            let values = model.history.map(\.level)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // The labelled rules, UNDER the line and on the same 0–100 domain it is plotted
                    // against, so the axis cannot disagree with the curve it explains.
                    ForEach(ticks, id: \.self) { tick in
                        HStack(spacing: 4) {
                            Text("\(tick)")
                                .font(.system(size: 10))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .frame(width: 22, alignment: .trailing)
                            Rectangle()
                                .fill(StrandPalette.textTertiary.opacity(0.40))
                                .frame(height: 1)
                        }
                        .offset(y: yFor(Double(tick), in: geo.size.height) - 6)
                    }

                    Path { path in
                        let width = geo.size.width - axisGutter
                        for (i, value) in values.enumerated() {
                            let x = axisGutter + width * CGFloat(i) / CGFloat(Swift.max(values.count - 1, 1))
                            let point = CGPoint(x: x, y: yFor(value, in: geo.size.height))
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                    }
                    .stroke(StrandPalette.accent, lineWidth: 2)
                }
            }
            .frame(height: 128)

            // Three dates, not thirty: the line is evenly spaced, so the ends and the middle place any
            // point by eye, and a label per day is unreadable at 90d and redundant at 7d.
            HStack {
                Text(dayLabel(model.history[0].day))
                Spacer()
                Text(dayLabel(model.history[model.history.count / 2].day))
                Spacer()
                Text(dayLabel(model.history[model.history.count - 1].day))
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.leading, axisGutter)
        }
    }

    /// The y pixel for a level, on the plot's own inset — the same inset the line is drawn with, so a
    /// rule and the curve cannot sit at different heights for the same number.
    private func yFor(_ value: Double, in height: CGFloat) -> CGFloat {
        let inset: CGFloat = 6
        let usable = Swift.max(height - inset * 2, 1)
        let clamped = Swift.min(Swift.max(value, 0), 100)
        return inset + (1 - CGFloat(clamped / 100)) * usable
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 128)
    }

    private func foot(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func dayLabel(_ key: String) -> String {
        guard let date = LevelWiring.date(from: key) else { return key }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
}
