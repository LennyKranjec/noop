import SwiftUI
import StrandAnalytics
import StrandDesign

// LevelTimelineSheetView.swift — where the level has been.
//
// SwiftUI twin of the Android `LevelTimelineSheet`. The radar at the top, one line for the level, the
// same range control the app's other daily charts use, and — behind a disclosure — the five parts the
// level is made of, each as its own line.
//
// IT IS A SHEET, NOT A SCREEN. It opens at half height with the app still visible behind it, because
// this is a thing you glance at and dismiss, not a place you go. A full-screen presentation made it a
// sixth tab that happened to have a close button.
//
// THE LINE IS RE-COMPUTED, NOT STORED. Each day is the formula run over the data as it stood that day,
// against the ONE frozen scale. A cached level would have been measured against whatever scale existed
// on the day it was written, and the curve would then show the yardstick moving as though the body had.
//
// THE Y-AXIS IS PINNED TO 0–100, which is the level's real domain, and LABELLED. Auto-scaling would
// redraw a steady month as a mountain range; a fixed scale with no rules leaves the reader unable to
// say whether the line is sitting at 40 or at 80. The gridlines are what turn the one into the other.
//
// THE CHART ANSWERS A TOUCH. Dragging along it names the day and the figure under your finger — a line
// with three date labels can say the shape of a month and cannot say what happened on the ninth.
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

/// The radar inside the sheet. Bigger than the strip's, because here it is the subject rather than a
/// badge — and big enough for the gold best-ring to be readable against the live web.
private let expandedRadarDiameter: CGFloat = 200

struct LevelTimelineSheetView: View {
    @ObservedObject var model: LevelBarModel
    let repo: Repository

    @EnvironmentObject private var coach: AICoachEngine

    @Environment(\.dismiss) private var dismiss
    @State private var span: LevelSpan = .month
    /// The system's own daily line about the weighting. Nil until one has been written — the panel then
    /// falls back to reading the breakdown itself rather than showing a placeholder.
    @State private var note: String?
    /// The point under the finger, while a drag is in progress.
    @State private var touched: LevelPoint?
    /// Whether the five-part breakdown is open.
    @State private var showParts = false

    /// Where the rules are drawn. Quarters of the level's range — five lines is an axis, nine is graph
    /// paper.
    private let ticks = [0, 25, 50, 75, 100]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    radar
                    header
                    if !model.missing.isEmpty { missingCard }

                    Picker("", selection: $span) {
                        ForEach(LevelSpan.allCases) { s in Text(s.label).tag(s) }
                    }
                    .pickerStyle(.segmented)

                    chart
                    readout

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

                    partsDisclosure
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Level")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        // HALF HEIGHT FIRST, so the app stays visible behind it — see the note at the top. Dragging it
        // up is how the five-part breakdown gets room without the sheet having to be a screen.
        .presentationDetentsCompat()
        .task(id: span.rawValue) { await model.loadHistory(repo: repo, spanDays: span.rawValue) }
        .task(id: model.trend?.now?.level) { await loadNote() }
    }

    /// What the level was computed without, and what would bring each one in.
    private var missingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.statusWarning)
                Text("MISSING VALUES")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            Text("Today's level is computed without these. Their weight goes to the parts that have data, so the level is partial rather than low.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(model.missing) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(item.hint)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.3), lineWidth: 1))
    }

    /// The radar, at its full size, with the personal best around it.
    private var radar: some View {
        LevelRadarView(
            breakdown: model.trend?.now,
            diameter: expandedRadarDiameter,
            countUpKey: 0,
            best: model.partBests.isEmpty ? nil : model.partBests
        )
        .frame(maxWidth: .infinity)
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

    /// The day and figure under the finger, or the span's own summary when nothing is touched.
    private var readout: some View {
        HStack {
            if let touched {
                Text(scrubLabel(touched.day))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Text("\(Int(touched.level.rounded()))")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                Text("Touch the line to read a day.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
            }
        }
        .frame(height: 18)
    }

    /// The five parts, each as its own line on the same 0–100 axis.
    ///
    /// COLLAPSED BY DEFAULT. The level is the answer; the parts are the working, and a panel that opens
    /// showing six charts asks the reader to find the one they came for.
    private var partsDisclosure: some View {
        DisclosureGroup(isExpanded: $showParts) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LevelPart.allCases, id: \.rawValue) { part in
                    PartSparkView(part: part, history: model.history, best: model.partBests[part])
                }
            }
            .padding(.top, 8)
        } label: {
            Text("The five parts")
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .tint(StrandPalette.accent)
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

    /// The system's line, written at most once a day and only when the level has actually moved.
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

                    // The touched day: a rule down the chart and a dot on the line.
                    if let touched, let index = model.history.firstIndex(where: { $0.day == touched.day }) {
                        let width = geo.size.width - axisGutter
                        let x = axisGutter + width * CGFloat(index) / CGFloat(Swift.max(values.count - 1, 1))
                        Rectangle()
                            .fill(StrandPalette.textTertiary.opacity(0.45))
                            .frame(width: 1, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                        Circle()
                            .fill(StrandPalette.accent)
                            .frame(width: 7, height: 7)
                            .position(x: x, y: yFor(touched.level, in: geo.size.height))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            touched = point(at: value.location.x, width: geo.size.width)
                        }
                        .onEnded { _ in touched = nil }
                )
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

    /// The point nearest an x position, so a touch anywhere on the plot lands on a real day rather than
    /// interpolating one that was never scored.
    private func point(at x: CGFloat, width: CGFloat) -> LevelPoint? {
        guard model.history.count > 1 else { return model.history.first }
        let plot = Swift.max(width - axisGutter, 1)
        let t = Swift.min(Swift.max((x - axisGutter) / plot, 0), 1)
        let index = Int((t * CGFloat(model.history.count - 1)).rounded())
        return model.history[Swift.min(Swift.max(index, 0), model.history.count - 1)]
    }

    /// The y pixel for a level, on the plot's own inset — the same inset the line is drawn with, so a
    /// rule and the curve cannot sit at different heights for the same number.
    /// The plotted domain: at least 0–100, widened to whatever the span actually reached, because the
    /// level has no ceiling or floor any more and a clamped axis would flatten the best days onto the
    /// top rule.
    private var domain: (lo: Double, hi: Double) {
        let levels = model.history.map(\.level)
        return (Swift.min(0, levels.min() ?? 0), Swift.max(100, levels.max() ?? 100))
    }

    private func yFor(_ value: Double, in height: CGFloat) -> CGFloat {
        let inset: CGFloat = 6
        let usable = Swift.max(height - inset * 2, 1)
        let d = domain
        let t = (value - d.lo) / Swift.max(d.hi - d.lo, 1)
        return inset + (1 - CGFloat(t)) * usable
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
        return Self.axisFormatter.string(from: date)
    }

    /// The day under the finger, WITH its weekday: a level read back while scrubbing is mostly asked
    /// "was that the Monday after the long run", and a bare date makes the wearer count.
    private func scrubLabel(_ key: String) -> String {
        guard let date = LevelWiring.date(from: key) else { return key }
        return Self.scrubFormatter.string(from: date)
    }

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private static let scrubFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()
}

/// One part's line, at a glance.
///
/// Small on purpose: five of these stacked are a BREAKDOWN, and five full charts would be five screens.
/// The figure on the right is where the part stands today; the gold pip is its best over the span.
private struct PartSparkView: View {
    let part: LevelPart
    let history: [LevelPoint]
    let best: Double?

    private var values: [Double] { history.compactMap { $0.parts[part] } }

    /// At least 0–100, widened to what the part actually reached — a part has no ceiling any more.
    private var partDomain: (lo: Double, hi: Double) {
        let all = values + (best.map { [$0] } ?? [])
        return (Swift.min(0, all.min() ?? 0), Swift.max(100, all.max() ?? 100))
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: levelPartSymbol(part))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(levelPartTint(part))
                Text(levelPartLabel(part))
                    .font(StrandFont.overline)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(width: 78, alignment: .leading)

            GeometryReader { geo in
                if values.count >= 2 {
                    ZStack {
                        // The part's best over the span, as a gold rule — the same comparison the radar
                        // draws, in the one place a line chart can carry it.
                        if let best {
                            Rectangle()
                                .fill(radarBestGold.opacity(0.55))
                                .frame(height: 1)
                                .position(x: geo.size.width / 2,
                                          y: (1 - CGFloat((best - partDomain.lo) / max(partDomain.hi - partDomain.lo, 1))) * geo.size.height)
                        }
                        Path { path in
                            for (i, v) in values.enumerated() {
                                let x = geo.size.width * CGFloat(i) / CGFloat(Swift.max(values.count - 1, 1))
                                let y = (1 - CGFloat((v - partDomain.lo) / max(partDomain.hi - partDomain.lo, 1))) * geo.size.height
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(levelPartTint(part), lineWidth: 1.5)
                    }
                } else {
                    // Said rather than drawn flat: a part with one scored day has no shape, and a level
                    // line across the middle would claim it had been steady.
                    Text("not enough scored days")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(height: 28)

            Text(values.last.map { "\(Int($0.rounded()))" } ?? "–")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

private extension View {
    /// Half height first, with the app visible behind. `presentationDetents` is iOS 16 / macOS 13, but
    /// the macOS sheet ignores detents entirely, so this is an iOS-only shape rather than a shim.
    @ViewBuilder
    func presentationDetentsCompat() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteractionCompat()
        #else
        self
        #endif
    }

    /// Let the app behind the half-height sheet stay usable, where the OS allows it.
    @ViewBuilder
    func presentationBackgroundInteractionCompat() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) {
            self.presentationBackgroundInteraction(.enabled(upThrough: .medium))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
