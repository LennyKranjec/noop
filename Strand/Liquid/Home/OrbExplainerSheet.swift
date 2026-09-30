import SwiftUI
import StrandDesign
import StrandAnalytics

// OrbExplainerSheet.swift — "What shapes your orb", opened by tapping the orb on Today.
//
// The orb is an instrument (decision 18): every visible property is one of today's numbers. This sheet
// says which, in plain words, with TODAY's value beside each channel (the SAME `TelosOrbInputs` the orb
// was drawn from — never re-derived), "—" plus the reason when a channel is absent. Then how the orb has
// developed: the Level over the last 30 / 90 days and the orb as it stood ~90 days ago, ~30 days ago and
// now, drawn STILL from the Level ledger's stored breakdowns (`LevelLedger`, the same store the Level
// timeline reads). Honest history: only stored days are drawn; a gap is a gap, a missing snapshot says so.
//
// Clinical, data-first (decision 19): faux-glass cards on the canvas, a plain line chart, no glow.
//
// COST: one ledger read on open (a dictionary filter, ≤ ~100 entries); the header orb runs its 8 s burst
// clock once, the history orbs are `.still`.

struct OrbExplainerSheet: View {
    let inputs: TelosOrbInputs
    let breakdown: LevelBreakdown?
    /// The Level shown is a stand-in until today's night is in.
    let pending: Bool
    /// Opens the Level timeline (the host dismisses this sheet first).
    let onOpenTimeline: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var span: OrbHistorySpan = .month
    /// Stored days over the longest span (plus the snapshot tolerance), oldest first.
    @State private var history: [HomeHeroMapping.OrbHistoryDay] = []
    /// The day the history ends on: the day whose Level the headline shows.
    @State private var endDay: String?

    /// How far a snapshot may sit from its target day and still stand for it.
    private static let snapshotTolerance = 7

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TelosSpace.l) {
                    header
                    legendCard
                    developmentCard
                    timelineLink
                }
                .padding(TelosSpace.pageGutter)
            }
            .background(TelosColor.canvas.ignoresSafeArea())
            .navigationTitle(Text("Your orb"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .modifier(OrbExplainerPresentation())
        .task { load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            TelosOrb(inputs: inputs, tint: .green, style: .hero, clock: .burst(seconds: 8))
                .frame(height: 180)
                .frame(maxWidth: .infinity)
            Text("What shapes your orb")
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textPrimary)
            Text("Every part of the orb is one of today's numbers. It grows with your Level and has no upper limit.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Legend

    private var legendCard: some View {
        let rows = HomeHeroMapping.orbLegend(inputs: inputs, breakdown: breakdown, pending: pending)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(TelosColor.line)
                        .frame(height: TelosStroke.line)
                        .padding(.vertical, TelosSpace.s)
                }
                OrbLegendRowView(row: row)
            }
        }
        .padding(TelosSpace.l)
        .background(NoopPanelSurface(cornerRadius: TelosRadius.card))
    }

    // MARK: - Development

    private var developmentCard: some View {
        let end = endDay
        let points = end.map { HomeHeroMapping.orbChartPoints(history: history, endDay: $0, span: span.rawValue) } ?? []
        let snapshots = end.map {
            HomeHeroMapping.orbSnapshots(history: history, endDay: $0, daysBack: [90, 30, 0],
                                         tolerance: Self.snapshotTolerance)
        } ?? []
        return VStack(alignment: .leading, spacing: TelosSpace.m) {
            Text("How it has developed")
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textSecondary)

            Picker("Range", selection: $span) {
                ForEach(OrbHistorySpan.allCases) { s in Text(verbatim: s.label).tag(s) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if points.count >= 2 {
                OrbLevelChart(points: points, span: span.rawValue)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(chartSummary(points)))
                Text(verbatim: chartSummary(points))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Two points is the fewest that can be a line; one stored day is not a trend.
                Text(verbatim: points.count == 1
                     ? String(localized: "Only 1 scored day in this range, not enough for a line yet.")
                     : String(localized: "No scored days in this range yet."))
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }

            HStack(alignment: .top, spacing: TelosSpace.s) {
                ForEach(snapshots) { snapshot in
                    OrbSnapshotView(snapshot: snapshot, endDay: end)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, TelosSpace.s)

            Text("Past orbs show the Level and its parts only. Stress, pulse, Charge and effort are not stored per day.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TelosSpace.l)
        .background(NoopPanelSurface(cornerRadius: TelosRadius.card))
    }

    /// "23 scored days · low 41 · mean 58 · high 72" — the figures the line is drawn from.
    private func chartSummary(_ points: [HomeHeroMapping.OrbChartPoint]) -> String {
        let levels = points.map(\.level)
        let low = TelosFormat.integer(levels.min() ?? .nan)
        let high = TelosFormat.integer(levels.max() ?? .nan)
        let mean = TelosFormat.integer(levels.isEmpty ? .nan : levels.reduce(0, +) / Double(levels.count))
        return String(localized: "\(levels.count) scored days · low \(low) · mean \(mean) · high \(high)")
    }

    // MARK: - Link

    private var timelineLink: some View {
        Button(action: onOpenTimeline) {
            HStack(spacing: TelosSpace.s) {
                Image(systemName: "chart.xyaxis.line")
                    .font(TelosType.glyphRow)
                    .accessibilityHidden(true)
                Text("Open the Level timeline")
                    .font(TelosType.subhead.weight(.semibold))
                Spacer(minLength: TelosSpace.s)
                Image(systemName: "chevron.right")
                    .font(TelosType.glyphChevron)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(TelosColor.textPrimary)
            .padding(.horizontal, TelosSpace.l)
            .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            .background(NoopPanelSurface(cornerRadius: TelosRadius.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Load

    /// One read of the Level ledger: every stored day over the longest range plus the snapshot tolerance,
    /// ending on the day the headline shows. Nothing is scored here.
    @MainActor
    private func load() {
        let calendar = Calendar.current
        let end = LevelBarModel.shared.shownDay ?? LevelWiring.key(from: Date(), calendar: calendar)
        let reach = OrbHistorySpan.quarter.rawValue + Self.snapshotTolerance
        let start = LevelWiring.shift(end, -(reach - 1), calendar) ?? end
        history = LevelLedger.shared.entries(from: start, through: end).map { entry in
            HomeHeroMapping.OrbHistoryDay(day: entry.day,
                                          level: entry.level,
                                          partShares: HomeHeroMapping.partShares(entry.breakdown.components),
                                          provisional: entry.partial || entry.coverage < 0.999)
        }
        endDay = end
    }
}

/// The ranges offered.
private enum OrbHistorySpan: Int, CaseIterable, Identifiable {
    case month = 30
    case quarter = 90

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .month: return String(localized: "30 days")
        case .quarter: return String(localized: "90 days")
        }
    }
}

// MARK: - A legend row

private struct OrbLegendRowView: View {
    let row: HomeHeroMapping.OrbLegendRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.m) {
            Image(systemName: row.glyph)
                .font(TelosType.glyphRow)
                .foregroundStyle(row.part?.color ?? TelosColor.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Text(verbatim: row.title)
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.textPrimary)
                    Spacer(minLength: TelosSpace.s)
                    Text(verbatim: row.value ?? TelosType.absent)
                        .font(TelosType.numeralXS)
                        .foregroundStyle(row.value == nil ? TelosColor.textTertiary : TelosColor.textPrimary)
                        .multilineTextAlignment(.trailing)
                }
                Text(verbatim: row.detail)
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(row.title): \(row.value ?? String(localized: "not measured")). \(row.detail)"))
    }
}

// MARK: - A past orb

private struct OrbSnapshotView: View {
    let snapshot: HomeHeroMapping.OrbSnapshot
    let endDay: String?

    private static let side: CGFloat = 84

    var body: some View {
        VStack(spacing: TelosSpace.xs) {
            if let entry = snapshot.entry {
                TelosOrb(inputs: TelosOrbInputs(level: entry.level, partShares: entry.partShares,
                                                confidence: entry.provisional ? .building : .solid),
                         tint: .green, style: .compact, clock: .still)
                    .frame(width: Self.side, height: Self.side)
                Text(verbatim: String(localized: "Level \(TelosFormat.integer(entry.level))"))
                    .font(TelosType.numeralXS)
                    .foregroundStyle(TelosColor.textPrimary)
                Text(verbatim: dateLabel(entry.day))
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            } else {
                Circle()
                    .stroke(TelosColor.line, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .frame(width: Self.side * 0.6, height: Self.side * 0.6)
                    .frame(width: Self.side, height: Self.side)
                Text(verbatim: TelosType.absent)
                    .font(TelosType.numeralXS)
                    .foregroundStyle(TelosColor.textTertiary)
                Text("Nothing stored")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            Text(verbatim: title)
                .font(TelosType.caption.weight(.semibold))
                .foregroundStyle(TelosColor.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var title: String {
        snapshot.daysBack == 0
            ? String(localized: "Now")
            : String(localized: "\(snapshot.daysBack) days ago")
    }

    private func dateLabel(_ day: String) -> String {
        guard let date = LevelWiring.date(from: day) else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(AppLanguage.activeLocale))
    }

    private var accessibilityText: String {
        guard let entry = snapshot.entry else {
            return String(localized: "\(title): no Level stored")
        }
        return String(localized: "\(title): Level \(TelosFormat.integer(entry.level)), \(dateLabel(entry.day))")
    }
}

// MARK: - The chart

/// The Level over the range, placed by real date (a gap in the stored days is a gap in the line), with
/// labelled rules at 0 / 50 / 100 and the axis extended — never clipped — past 100 (the Level is unbounded).
private struct OrbLevelChart: View {
    let points: [HomeHeroMapping.OrbChartPoint]
    let span: Int

    private static let gutter: CGFloat = 28
    private static let height: CGFloat = 120

    /// The axis top: 100, or the next 25 above the highest stored Level.
    static func top(_ points: [HomeHeroMapping.OrbChartPoint]) -> Double {
        let high = points.map(\.level).max() ?? 0
        return high <= 100 ? 100 : (high / 25).rounded(.up) * 25
    }

    static func rules(top: Double) -> [Double] {
        top > 100 ? [0, 50, 100, top] : [0, 50, 100]
    }

    static func position(_ p: HomeHeroMapping.OrbChartPoint, span: Int, top: Double, size: CGSize) -> CGPoint {
        let width = max(size.width - gutter, 1)
        let x = gutter + width * CGFloat(p.index) / CGFloat(max(span - 1, 1))
        let clamped = min(max(p.level, 0), top)
        return CGPoint(x: x, y: size.height * CGFloat(1 - clamped / top))
    }

    var body: some View {
        let top = Self.top(points)
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(Self.rules(top: top), id: \.self) { rule in
                    HStack(spacing: 4) {
                        Text(verbatim: TelosFormat.integer(rule))
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textTertiary)
                            .frame(width: Self.gutter - 4, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Rectangle()
                            .fill(TelosColor.textTertiary.opacity(0.25))
                            .frame(height: TelosStroke.hair)
                    }
                    .offset(y: size.height * CGFloat(1 - rule / top) - 6)
                }
                Path { path in
                    var previous: Int? = nil
                    for p in points {
                        let at = Self.position(p, span: span, top: top, size: size)
                        if let previous, p.index - previous == 1 {
                            path.addLine(to: at)
                        } else {
                            path.move(to: at)
                        }
                        previous = p.index
                    }
                }
                .stroke(TelosColor.mint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                Path { path in
                    for p in points {
                        let at = Self.position(p, span: span, top: top, size: size)
                        path.addEllipse(in: CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3))
                    }
                }
                .fill(TelosColor.mint)
            }
        }
        .frame(height: Self.height)
    }
}

// MARK: - Presentation

private struct OrbExplainerPresentation: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        content.frame(minWidth: 440, minHeight: 620)
        #endif
    }
}
