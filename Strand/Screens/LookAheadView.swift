import SwiftUI
import StrandAnalytics
import StrandDesign

// LookAheadView.swift — "Look ahead" (DESIGN_V2 coordinator decision 13): where each figure is projected to
// be in 4 / 8 / 12 weeks on two scenarios side by side — "on your current trend" and "if you follow the
// plan" — every one drawn as a widening band, never a line.
//
// Reached from the Level breakdown, the Health tab and the weekly review (entry points: design packages).
// Built from existing token names only; the design packages restyle it without changing what it says.
//
// HONESTY RULES THIS SCREEN KEEPS:
//   * a band, never a single line; the band is computed (`ProjectionEngine`), with its coverage stated;
//   * "no clear trend" draws a FLAT band; "not enough history" draws nothing and says how many weeks;
//   * a horizon past the informative cap shows "—" with the cap, never a stretched band;
//   * the plan scenario names its basis: the plan's own targets, YOUR response, or a typical response
//     "not yours yet" (with the source);
//   * the Level is unbounded: the chart scales to the data and marks where 100 sits, nothing clips;
//   * copy says "projection", never "you will".
//
// COST: static. One refresh on appear; Canvas charts redraw only when the source publishes. No animation,
// no timer.

@MainActor
struct LookAheadView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var source = ProjectionSource.shared
    @State private var horizon = 8
    @State private var showMethod = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                if source.asOf == nil && source.isRefreshing {
                    Text("Working out the projections…")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(source.lookAheadMetrics, id: \.id) { m in
                    LookAheadRow(metric: m, horizon: horizon, source: source)
                }
                // Goals are reached from Look ahead too (decision 14). Pushes inside the host's navigation.
                NavigationLink {
                    GoalsView()
                } label: {
                    Text("Goals — set a target on a date and see how realistic it is")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.accent)
                }
                method
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(Text("Look ahead"))
        .task { await source.refresh(model: model) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projections from your own recent weeks. Each band holds about 80 % of likely outcomes — a projection, not a promise.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Horizon", selection: $horizon) {
                Text("4 weeks").tag(4)
                Text("8 weeks").tag(8)
                Text("12 weeks").tag(12)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 12) {
                legendSwatch(StrandPalette.textTertiary, "On your current trend")
                legendSwatch(StrandPalette.accent, "If you follow the plan")
            }
        }
    }

    private func legendSwatch(_ c: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.35)).frame(width: 14, height: 8)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var method: some View {
        StrandCard(padding: 12) {
            DisclosureGroup(isExpanded: $showMethod) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(LookAheadCopy.method, id: \.self) { line in
                        Text(line)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("How these projections are made").font(StrandFont.footnote)
            }
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
        StrandCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.displayName).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    if let c = source.current(metric) {
                        Text(metric.formatWithUnit(c.value))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Text(HealthAbsence.dash).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                switch trend {
                case .abstained(let why):
                    Text(HealthAbsence.dash + " " + why.text)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .projected(let p):
                    Text(p.trendLine)
                        .font(StrandFont.mono(12))
                        .foregroundStyle(StrandPalette.textTertiary)
                    ProjectionBandChart(metric: metric, currentWeek: p.currentWeek, history: p.window,
                                        trend: p.bands, plan: plan.projection?.bands ?? [])
                    scenarios(p, plan)
                }
            }
        }
    }

    @ViewBuilder
    private func scenarios(_ p: TrendProjection, _ plan: MetricPlan) -> some View {
        HStack(alignment: .top, spacing: 12) {
            column(title: "On your current trend", band: p.band(weeksAhead: horizon),
                   missing: "Past the \(p.horizonCap)-week horizon where the band stays informative")
            switch plan {
            case .projected(let pp):
                column(title: "If you follow the plan", band: pp.band(weeksAhead: horizon),
                       missing: "Past the \(p.horizonCap)-week horizon")
            case .abstained(let why):
                VStack(alignment: .leading, spacing: 2) {
                    Text("If you follow the plan").strandOverline()
                    Text(HealthAbsence.dash + " " + why)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let pp = plan.projection {
            Text(pp.basis.label)
                .font(StrandFont.caption)
                .foregroundStyle(pp.basis.isPrior ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if case .typicalResponse(let prior) = pp.basis {
                Text(prior.statement)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let e = metric.measurementError {
            Text("The estimate itself is only good to about ±\(Int(e)) \(metric.unit); the outer line shows that.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func column(title: LocalizedStringKey, band: ProjectionBand?, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).strandOverline()
            if let b = band {
                Text(metric.format(b.low) + "–" + metric.format(b.high) + (metric.unit.isEmpty ? "" : " " + metric.unit))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("projection for the week of \(b.weekStart)")
                    .font(StrandFont.mono(11))
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text(HealthAbsence.dash + " " + missing)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The band chart (shared with Goals)

/// Past weekly values as dots, then the projection bands widening to the right. Static Canvas. The y-axis
/// scales to the data (nothing is clipped; the Level's 100 is a labelled hairline, not a ceiling).
struct ProjectionBandChart: View {
    let metric: ProjectionMetricID
    let currentWeek: String
    let history: [WeeklyValue]
    let trend: [ProjectionBand]
    let plan: [ProjectionBand]
    /// A goal marker: weeks ahead and value.
    var targetWeeksAhead: Double? = nil
    var targetValue: Double? = nil
    var height: CGFloat = 92

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
        let pad = max((yMaxRaw - yMinRaw) * 0.08, 1e-6)
        let yMin = yMinRaw - pad
        let yMax = yMaxRaw + pad
        let xMin = min(pts.map { $0.x }.min() ?? -1, -1)
        let xMax = max(Double((trend + plan).map(\.weeksAhead).max() ?? 1), targetWeeksAhead ?? 0, 1)
        func px(_ x: Double) -> CGFloat { CGFloat((x - xMin) / (xMax - xMin)) * size.width }
        func py(_ y: Double) -> CGFloat { size.height - CGFloat((y - yMin) / (yMax - yMin)) * size.height }

        // "Now" hairline.
        var now = Path()
        now.move(to: CGPoint(x: px(0), y: 0))
        now.addLine(to: CGPoint(x: px(0), y: size.height))
        ctx.stroke(now, with: .color(StrandPalette.hairline), lineWidth: 1)

        // The Level's own 95th percentile, marked (never a ceiling).
        if metric.kind == .level || metric.kind == .levelPart, yMin < 100, yMax > 100 {
            var ref = Path()
            ref.move(to: CGPoint(x: 0, y: py(100)))
            ref.addLine(to: CGPoint(x: size.width, y: py(100)))
            ctx.stroke(ref, with: .color(StrandPalette.hairline), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text("100").font(StrandFont.mono(9)).foregroundColor(StrandPalette.textTertiary),
                     at: CGPoint(x: 2, y: py(100) - 6), anchor: .leading)
        }

        func band(_ bands: [ProjectionBand], _ color: Color) {
            guard bands.count >= 1 else { return }
            let sorted = bands.sorted { $0.weeksAhead < $1.weeksAhead }
            var area = Path()
            area.move(to: CGPoint(x: px(0), y: py(sorted[0].high)))
            for b in sorted { area.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.high))) }
            for b in sorted.reversed() { area.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.low))) }
            area.addLine(to: CGPoint(x: px(0), y: py(sorted[0].low)))
            area.closeSubpath()
            ctx.fill(area, with: .color(color.opacity(0.22)))
            if sorted.contains(where: { $0.outerLow != nil }) {
                var outer = Path()
                outer.move(to: CGPoint(x: px(0), y: py(sorted[0].outerHigh ?? sorted[0].high)))
                for b in sorted { outer.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.outerHigh ?? b.high))) }
                outer.move(to: CGPoint(x: px(0), y: py(sorted[0].outerLow ?? sorted[0].low)))
                for b in sorted { outer.addLine(to: CGPoint(x: px(Double(b.weeksAhead)), y: py(b.outerLow ?? b.low))) }
                ctx.stroke(outer, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        band(trend, StrandPalette.textTertiary)
        band(plan, StrandPalette.accent)

        for p in pts {
            let r: CGFloat = 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: px(p.x) - r, y: py(p.y) - r, width: 2 * r, height: 2 * r)),
                     with: .color(StrandPalette.textSecondary))
        }

        if let tx = targetWeeksAhead, let tv = targetValue {
            let c = CGPoint(x: px(tx), y: py(tv))
            var d = Path()
            d.move(to: CGPoint(x: c.x, y: c.y - 5))
            d.addLine(to: CGPoint(x: c.x + 5, y: c.y))
            d.addLine(to: CGPoint(x: c.x, y: c.y + 5))
            d.addLine(to: CGPoint(x: c.x - 5, y: c.y))
            d.closeSubpath()
            ctx.fill(d, with: .color(StrandPalette.accent))
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
