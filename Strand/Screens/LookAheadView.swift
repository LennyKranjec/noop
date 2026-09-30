import SwiftUI
import StrandAnalytics
import StrandDesign

// LookAheadView.swift — "Look ahead" (DESIGN_V2 coordinator decision 13): where each figure is projected to
// be in 4 / 8 / 12 weeks on two scenarios side by side — "on your current trend" and "if you follow the
// plan" — every one drawn as a widening band, never a line on its own.
//
// Reached from the Level breakdown, the Health tab and the weekly review (entry points: design packages).
//
// HONESTY RULES THIS SCREEN KEEPS:
//   * a band, never a bare line; the band is computed (`ProjectionEngine`), with its coverage stated — the
//     luminous centre line is the band's own computed centre and is only ever drawn INSIDE its band;
//   * "no clear trend" draws a FLAT band; "not enough history" draws nothing and says how many weeks;
//   * a horizon past the informative cap shows "—" with the cap, never a stretched band;
//   * the plan scenario names its basis: the plan's own targets, YOUR response, or a typical response
//     "not yours yet" (with the source);
//   * the Level is unbounded: the chart scales to the data and marks where 100 sits, nothing clips;
//   * copy says "projection", never "you will".
//
// TELOS 2.0 (PROGRESS): glass cards tinted by the metric's identity, the horizon as chips, the two
// scenarios in two light colours (current trend = pale blue, solid edge; plan = bioluminescent green,
// dotted edge — so they differ without colour too), luminous centre lines, glowing history dots.
// COST: static. One refresh on appear; Canvas charts redraw only when the source publishes. No clock.

/// The two scenario colours, shared by the legend and the chart.
enum LookAheadStyle {
    static let trend: Color = TelosColor.rest
    static let plan: Color = TelosColor.mint

    /// The metric's identity hue (tints the card's top glow and the history dots).
    static func tint(_ m: ProjectionMetricID) -> Color {
        switch m.kind {
        case .level: return TelosColor.mint
        case .levelPart:
            switch m.levelPart {
            case .some(.sleep): return TelosColor.rest
            case .some(.heart): return TelosColor.heart
            case .some(.lungs): return TelosColor.lungs
            case .some(.muscle): return TelosColor.muscle
            case .some(.focus): return TelosColor.focus
            case .none: return TelosColor.mint
            }
        case .restingHR, .hrv: return TelosColor.heart
        case .vo2max: return TelosColor.lungs
        case .aerobicMinutes: return TelosColor.effort
        case .steps: return TelosColor.amber
        case .e1rm: return TelosColor.muscle
        case .sleepRegularity: return TelosColor.rest
        case .meditationMinutes: return TelosColor.violet
        }
    }
}

@MainActor
struct LookAheadView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var source = ProjectionSource.shared
    @State private var horizon = 8
    @State private var showMethod = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TelosSpace.cardGap) {
                header
                if source.asOf == nil && source.isRefreshing {
                    HStack(spacing: TelosSpace.s) {
                        ProgressView().controlSize(.small)
                        Text("Working out the projections…")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                }
                ForEach(source.lookAheadMetrics, id: \.id) { m in
                    LookAheadRow(metric: m, horizon: horizon, source: source)
                }
                // Goals are reached from Look ahead too (decision 14). Pushes inside the host's navigation.
                NavigationLink {
                    GoalsView()
                } label: {
                    TelosListRow("Goals", subtitle: "Set a target on a date and see how realistic it is",
                                 systemImage: "flag.checkered", iconTint: TelosColor.mint, showsChevron: true)
                        .background(NoopPanelSurface())
                }
                .buttonStyle(TelosPressButtonStyle())
                method
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.vertical, TelosSpace.l)
        }
        .background(TelosColor.groundGradient.ignoresSafeArea())
        .navigationTitle(Text("Look ahead"))
        .task { await source.refresh(model: model) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            PGOverline("Projection · your own weeks", ink: TelosColor.mint)
            Text("Projections from your own recent weeks. Each band holds about 80 % of likely outcomes — a projection, not a promise.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TelosSpace.xs) {
                TelosChip("4 weeks", isOn: horizon == 4) { horizon = 4 }
                TelosChip("8 weeks", isOn: horizon == 8) { horizon = 8 }
                TelosChip("12 weeks", isOn: horizon == 12) { horizon = 12 }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Horizon"))
            HStack(spacing: TelosSpace.m) {
                legendSwatch(LookAheadStyle.trend, dashed: false, "On your current trend")
                legendSwatch(LookAheadStyle.plan, dashed: true, "If you follow the plan")
            }
        }
    }

    private func legendSwatch(_ c: Color, dashed: Bool, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: TelosSpace.xs) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(c.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(c, style: StrokeStyle(lineWidth: TelosStroke.line, dash: dashed ? [2, 2] : [])))
                .frame(width: 16, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textSecondary)
        }
    }

    private var method: some View {
        StrandCard {
            DisclosureGroup(isExpanded: $showMethod) {
                VStack(alignment: .leading, spacing: TelosSpace.s) {
                    ForEach(LookAheadCopy.method, id: \.self) { line in
                        Text(line)
                            .font(TelosType.caption)
                            .foregroundStyle(TelosColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, TelosSpace.s)
            } label: {
                Text("How these projections are made")
                    .font(TelosType.subhead.weight(.semibold))
                    .foregroundStyle(TelosColor.textPrimary)
            }
            .tint(TelosColor.textSecondary)
        }
    }
}

// MARK: - One metric

@MainActor
struct LookAheadRow: View {
    let metric: ProjectionMetricID
    let horizon: Int
    @ObservedObject var source: ProjectionSource

    var body: some View {
        let trend = source.trend(metric)
        let plan = source.plan(metric)
        let tint = LookAheadStyle.tint(metric)
        StrandCard(tint: tint) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        PGOverline(verbatim: metric.displayName, ink: TelosColor.textSecondary)
                        if let c = source.current(metric) {
                            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                                Text(verbatim: metric.format(c.value))
                                    .telosNumeral(.numeralM)
                                    .foregroundStyle(TelosColor.textPrimary)
                                if !metric.unit.isEmpty {
                                    Text(verbatim: metric.unit)
                                        .font(TelosType.unitFont(forNumeralSize: 24))
                                        .foregroundStyle(TelosColor.textSecondary)
                                }
                            }
                            Text(verbatim: "WEEK OF \(c.weekStart)")
                                .font(TelosType.scaleNumber)
                                .foregroundStyle(TelosColor.textTertiary)
                        } else {
                            AbsentValue(reason: "No reading of this figure yet", dashFont: TelosType.numeralS, arrangement: .inline)
                        }
                    }
                    Spacer(minLength: TelosSpace.s)
                    if let p = trend.projection {
                        TelosTag(verbatim: p.verdict == .noClearTrend ? "FLAT" : (p.verdict == .rising ? "RISING" : "FALLING"),
                                 ink: tint)
                    }
                }
                .accessibilityElement(children: .combine)
                switch trend {
                case .abstained(let why):
                    AbsentValue(verbatimReason: why.text)
                case .projected(let p):
                    Text(p.trendLine)
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProjectionBandChart(metric: metric, currentWeek: p.currentWeek, history: p.window,
                                        trend: p.bands, plan: plan.projection?.bands ?? [],
                                        historyTint: tint)
                    scenarios(p, plan)
                }
            }
        }
    }

    @ViewBuilder
    private func scenarios(_ p: TrendProjection, _ plan: MetricPlan) -> some View {
        HStack(alignment: .top, spacing: TelosSpace.s) {
            column(title: "On your current trend", color: LookAheadStyle.trend, band: p.band(weeksAhead: horizon),
                   missing: "Past the \(p.horizonCap)-week horizon where the band stays informative")
            switch plan {
            case .projected(let pp):
                column(title: "If you follow the plan", color: LookAheadStyle.plan, band: pp.band(weeksAhead: horizon),
                       missing: "Past the \(p.horizonCap)-week horizon")
            case .abstained(let why):
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    PGOverline("If you follow the plan", ink: LookAheadStyle.plan)
                    AbsentValue(verbatimReason: why)
                }
                .padding(TelosSpace.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .pgInsetBand(tint: LookAheadStyle.plan)
            }
        }
        if let pp = plan.projection {
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                if pp.basis.isPrior {
                    TelosTag("Not yours yet", ink: TelosColor.warning)
                }
                Text(pp.basis.label)
                    .font(TelosType.caption)
                    .foregroundStyle(pp.basis.isPrior ? TelosColor.warning : TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .typicalResponse(let prior) = pp.basis {
                Text(prior.statement)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let e = metric.measurementError {
            Text("The estimate itself is only good to about ±\(Int(e)) \(metric.unit); the outer line shows that.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(title: LocalizedStringKey, color: Color, band: ProjectionBand?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            PGOverline(title, ink: color)
            if let b = band {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xxs) {
                    Text(verbatim: "\(metric.format(b.low))–\(metric.format(b.high))")
                        .font(TelosType.numeralS)
                        .foregroundStyle(TelosColor.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if !metric.unit.isEmpty {
                        Text(verbatim: metric.unit)
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                }
                Text("projection for the week of \(b.weekStart)")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                AbsentValue(verbatimReason: missing)
            }
        }
        .padding(TelosSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pgInsetBand(tint: color)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The band chart (shared with Goals)

/// Past weekly values as glowing dots, then the projection bands widening to the right, each with its own
/// computed centre as a luminous line inside it. Static Canvas. The y-axis scales to the data (nothing is
/// clipped; the Level's 100 is a labelled hairline, not a ceiling).
struct ProjectionBandChart: View {
    let metric: ProjectionMetricID
    let currentWeek: String
    let history: [WeeklyValue]
    let trend: [ProjectionBand]
    let plan: [ProjectionBand]
    /// A goal marker: weeks ahead and value.
    var targetWeeksAhead: Double? = nil
    var targetValue: Double? = nil
    var historyTint: Color = TelosColor.textSecondary
    var height: CGFloat = 116

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: &ctx, size: size)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        var s = metric.displayName
        if let last = trend.last {
            s += ", current-trend projection " + metric.format(last.low) + " to " + metric.format(last.high)
                + " in \(last.weeksAhead) weeks"
        }
        if let last = plan.last {
            s += ", plan projection " + metric.format(last.low) + " to " + metric.format(last.high)
        }
        return s
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let pts: [(x: Double, y: Double)] = history.compactMap { w -> (x: Double, y: Double)? in
            guard let x = ProjectionEngine.weeksAhead(of: w.weekStart, currentWeek: currentWeek) else { return nil }
            return (Double(x), w.value)
        }
        var ys: [Double] = pts.map { $0.y }
        for b in trend + plan {
            ys.append(b.outerLow ?? b.low)
            ys.append(b.outerHigh ?? b.high)
        }
        if let t = targetValue { ys.append(t) }
        guard let yMinRaw = ys.min(), let yMaxRaw = ys.max() else { return }
        let pad: Double = max((yMaxRaw - yMinRaw) * 0.08, 1e-6)
        let yMin: Double = yMinRaw - pad
        let yMax: Double = yMaxRaw + pad
        let xMinData: Double = pts.map { $0.x }.min() ?? -1
        let xMin: Double = min(xMinData, -1)
        let bandMax: Double = Double((trend + plan).map(\.weeksAhead).max() ?? 1)
        let xMax: Double = max(bandMax, targetWeeksAhead ?? 0, 1)
        let plotH: CGFloat = size.height - 12
        func px(_ x: Double) -> CGFloat { CGFloat((x - xMin) / (xMax - xMin)) * size.width }
        func py(_ y: Double) -> CGFloat { plotH - CGFloat((y - yMin) / (yMax - yMin)) * plotH }

        // Dotted horizontal grid (3 lines), labels trailing.
        for i in 1...3 {
            let v: Double = yMin + (yMax - yMin) * Double(i) / 4
            var g = Path()
            g.move(to: CGPoint(x: 0, y: py(v)))
            g.addLine(to: CGPoint(x: size.width, y: py(v)))
            ctx.stroke(g, with: .color(TelosColor.lineSoft), style: StrokeStyle(lineWidth: TelosStroke.hair, dash: [1, 3]))
            ctx.draw(Text(verbatim: metric.format(v)).font(TelosType.scaleNumber).foregroundColor(TelosColor.textTertiary),
                     at: CGPoint(x: size.width - 2, y: py(v) - 1), anchor: .bottomTrailing)
        }

        // "Now" hairline.
        var now = Path()
        now.move(to: CGPoint(x: px(0), y: 0))
        now.addLine(to: CGPoint(x: px(0), y: plotH))
        ctx.stroke(now, with: .color(TelosColor.lineStrong), lineWidth: TelosStroke.line)
        ctx.draw(Text("NOW").font(TelosType.scaleNumber).foregroundColor(TelosColor.textTertiary),
                 at: CGPoint(x: px(0), y: size.height), anchor: .bottom)

        // The Level's own 95th percentile, marked (never a ceiling).
        if metric.kind == .level || metric.kind == .levelPart, yMin < 100, yMax > 100 {
            var ref = Path()
            ref.move(to: CGPoint(x: 0, y: py(100)))
            ref.addLine(to: CGPoint(x: size.width, y: py(100)))
            ctx.stroke(ref, with: .color(TelosColor.lineStrong), style: StrokeStyle(lineWidth: TelosStroke.line, dash: [3, 3]))
            ctx.draw(Text(verbatim: "100").font(TelosType.scaleNumber).foregroundColor(TelosColor.textTertiary),
                     at: CGPoint(x: 2, y: py(100) - 2), anchor: .bottomLeading)
        }

        func band(_ bands: [ProjectionBand], _ color: Color, dotted: Bool) {
            guard !bands.isEmpty else { return }
            let sorted = bands.sorted { $0.weeksAhead < $1.weeksAhead }
            var area = Path()
            area.move(to: CGPoint(x: px(0), y: py(sorted[0].high)))
            for b in sorted { area.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.high))) }
            for b in sorted.reversed() { area.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.low))) }
            area.addLine(to: CGPoint(x: px(0), y: py(sorted[0].low)))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.30), color.opacity(0.10)]),
                                                 startPoint: CGPoint(x: px(0), y: 0),
                                                 endPoint: CGPoint(x: size.width, y: 0)))
            ctx.stroke(area, with: .color(color.opacity(0.55)),
                       style: StrokeStyle(lineWidth: TelosStroke.hair, dash: dotted ? [2, 2] : []))
            // The band's own computed centre, luminous (halo + core), inside the band.
            var centre = Path()
            centre.move(to: CGPoint(x: px(0), y: py(sorted[0].center)))
            for b in sorted { centre.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.center))) }
            ctx.stroke(centre, with: .color(color.opacity(0.22)),
                       style: StrokeStyle(lineWidth: TelosStroke.data * 3, lineCap: .round, lineJoin: .round))
            ctx.stroke(centre, with: .color(color),
                       style: StrokeStyle(lineWidth: TelosStroke.strong, lineCap: .round, lineJoin: .round,
                                          dash: dotted ? [4, 3] : []))
            if sorted.contains(where: { $0.outerLow != nil }) {
                var outer = Path()
                outer.move(to: CGPoint(x: px(0), y: py(sorted[0].outerHigh ?? sorted[0].high)))
                for b in sorted { outer.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.outerHigh ?? b.high))) }
                outer.move(to: CGPoint(x: px(0), y: py(sorted[0].outerLow ?? sorted[0].low)))
                for b in sorted { outer.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.outerLow ?? b.low))) }
                ctx.stroke(outer, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: TelosStroke.line, dash: [2, 3]))
            }
        }
        band(trend, LookAheadStyle.trend, dotted: false)
        band(plan, LookAheadStyle.plan, dotted: true)

        // History: glowing dots (halo + core, no blur).
        for p in pts {
            let c = CGPoint(x: px(p.x), y: py(p.y))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
                     with: .color(historyTint.opacity(0.18)))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
                     with: .color(historyTint))
        }

        if let tx = targetWeeksAhead, let tv = targetValue {
            let c = CGPoint(x: px(tx), y: py(tv))
            var d = Path()
            d.move(to: CGPoint(x: c.x, y: c.y - 6))
            d.addLine(to: CGPoint(x: c.x + 6, y: c.y))
            d.addLine(to: CGPoint(x: c.x, y: c.y + 6))
            d.addLine(to: CGPoint(x: c.x - 6, y: c.y))
            d.closeSubpath()
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22)),
                     with: .color(TelosColor.mint.opacity(0.18)))
            ctx.fill(d, with: .color(TelosColor.mint))
            ctx.draw(Text("TARGET").font(TelosType.scaleNumber).foregroundColor(TelosColor.mint),
                     at: CGPoint(x: min(c.x, size.width - 2), y: c.y - 9),
                     anchor: c.x > size.width - 40 ? .bottomTrailing : .bottom)
        }
    }
}

// MARK: - Copy

enum LookAheadCopy {
    /// The method, in plain words, with its sources. Shown under "How these projections are made".
    static let method: [String] = [
        "Each figure is reduced to one value per week (the median of the nights or days, or the week's total), and only complete weeks count.",
        "Current trend: a robust line through your last up to 12 weeks (Theil–Sen: the median of every pairwise slope), so one odd week can't swing it. A rank test (Mann–Kendall, 5 %) decides whether the trend can be told apart from noise; if it can't, the projection is flat.",
        "The band is a prediction interval for about 80 % of outcomes. It widens with the horizon because the slope itself is uncertain, and when the line is drawn flat the slope that was set aside still widens it.",
        "Horizons stop where the band would be more than 2.5× as wide as your week-to-week scatter alone: roughly as far ahead as you have weeks of history, and never past 12 weeks.",
        "Fewer than 6 weeks of values: no projection. Never a line from two points.",
        "If you follow the plan: aerobic minutes and steps follow the week plan's own ramp. Resting HR, HRV, VO₂max, the Level and its heart, lungs and muscle parts use YOUR past response to training dose when you have at least 8 paired weeks with the dose varying; otherwise a published typical response, labelled \"not yours yet\", with a wider band.",
        "Typical responses used: VO₂max +4.9 ml/kg/min from endurance training in controlled trials (Milanović 2015, Sports Med); resting HR about −6 bpm over a median 12 weeks (Reimers 2018, J Clin Med); strength gains that slow with training age (ACSM 2009 position stand; Rhea 2003). Individual responses vary widely (HERITAGE, Bouchard 1999).",
        "HRV and the Level have no typical response we can honestly borrow (HRV studies report standardised effects, not milliseconds; the Level is this app's own composite), so their plan scenario needs your own data.",
        "The sleep anchor and the day's gear are part of the plan but have no measured per-week effect size we could apply; they are not modelled rather than guessed.",
        "No ceilings or floors are invented. The Level is unbounded: 100 is your own 95th percentile, not a maximum. Minutes, steps and kilograms simply can't go below zero.",
        "VO₂max estimates carry about ±5 ml/kg/min of error on their own — more than a year of realistic change — shown as the outer dotted line.",
    ]
}
