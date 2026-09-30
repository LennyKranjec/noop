#if !os(watchOS)
// TrendChart is a Swift Charts view with .onContinuousHover (unavailable on watchOS); the watch
// never shows it, so the whole file is excluded there. iOS/macOS unchanged.
import SwiftUI
import Charts

// MARK: - Trend Chart (§9.4 Trends)
//
// A line/area chart whose line is gradient-stroked by value — reusable for
// recovery / HRV / RHR / strain trends. The gradient defaults to the recovery
// scale (so a recovery-over-time line travels deep-gold → pale-gold by daily
// score), but any gradient + value-range can be supplied — pass the blue sleep
// ramp for sleep, the teal HRV scale for HRV, the amber strain ramp for strain.

/// The index runs that `hrGapSegments` implies: one range per unbroken stretch, in order.
///
/// Charts can hand a segment id to the plotting library and let it split the line. A hand-drawn sparkline
/// cannot, so it needs the runs themselves to know where to lift the pen. Same rule, same source of truth,
/// rather than a second walk that could disagree with the first (#2082).
///
/// An empty input yields no runs. A run of one is still a run: a lone bucket between two gaps is real data
/// and a caller that drops it would be hiding a reading rather than a gap.
public func hrGapRuns(segments: [String]) -> [ClosedRange<Int>] {
    guard !segments.isEmpty else { return [] }
    var runs: [ClosedRange<Int>] = []
    var start = 0
    for i in 1..<segments.count where segments[i] != segments[i - 1] {
        runs.append(start...(i - 1))
        start = i
    }
    runs.append(start...(segments.count - 1))
    return runs
}

/// Segment ids for a bucketed time series, changing wherever the series SKIPS a bucket.
///
/// A bucket aggregate only emits rows for buckets that had samples, so an hour the strap was off simply
/// is not in the list. Without this the line joins the two neighbours across that hour and draws a
/// steady climb the wearer never had, which is a reading invented out of an absence. Handing these to
/// `TrendPoint.segment` renders the two sides as separate lines, so a gap looks like a gap.
///
/// A step of exactly one bucket is contiguous. Anything longer means at least one bucket held nothing,
/// and that is the break. No tolerance for "just one missing": a five-minute hole is still five minutes
/// of invention, and the stress trace made the same call when it stopped drawing through unscored hours.
///
/// Byte-identical twin of the Kotlin `hrGapSegmentIds`.
public func hrGapSegments(bucketTs: [Int], bucketSeconds: Int) -> [String] {
    var segment = 0
    return bucketTs.enumerated().map { i, ts in
        if i > 0, ts - bucketTs[i - 1] > bucketSeconds { segment += 1 }
        return String(segment)
    }
}

/// One point on a trend line.
public struct TrendPoint: Identifiable, Sendable {
    public var date: Date
    public var value: Double
    /// Sequential line-segment identity. Points with different ids are rendered as separate lines, so a
    /// metric can retain history without drawing a false transition across incompatible methods.
    public var segment: String

    /// Stable, content-derived identity (one point per date in a series). A random
    /// `UUID()` defeats Swift Charts' diffing — every render re-identifies all marks
    /// and replays the draw animation; keying on the date lets Charts diff by data.
    public var id: Date { date }

    public init(date: Date, value: Double, segment: String = "default") {
        self.date = date
        self.value = value
        self.segment = segment
    }
}

public struct TrendChart: View {

    public var points: [TrendPoint]
    /// The gradient the line/area is stroked with (defaults to the recovery scale).
    public var gradient: Gradient
    /// The value range mapped onto the gradient (0 → bottom color, max → top color).
    public var valueRange: ClosedRange<Double>
    /// Whether to draw the soft area fill below the line.
    public var showsArea: Bool
    /// Draw vertical bars from the axis baseline instead of the line + area + points. One value-ramp-
    /// filled `BarMark` per (down-sampled) sample. Display-only — the plotted series is identical; only
    /// the mark geometry changes. Default false (the classic line). `showsArea` is ignored in bar mode.
    public var showsBars: Bool

    /// Optional personal-baseline reference, drawn as a dashed rule UNDER the series.
    ///
    /// A reference the readings are judged against, not a second series, so it is dashed and faint. Nil
    /// (the default) draws nothing, and the rule rides the chart's own y domain, so a value outside the
    /// plotted range simply falls off it rather than being clamped to an edge it does not sit on.
    public var baselineValue: Double?
    public var height: CGFloat
    /// Whether hovering reveals a crosshair + tooltip for the nearest point.
    public var showsHover: Bool
    /// iPhone touch scrub: when true (and `showsHover`), dragging a finger sideways across the chart moves
    /// the crosshair under it, driving the SAME readout the Mac pointer hover drives.
    ///
    /// The drag engages on the first 8 pt of movement and the axis is decided from that same movement
    /// (`ChartHoverMath.scrubAxis`), which is what lets all three intents coexist on one chart inside a
    /// scrolling page of tappable cards: sideways scrubs, up/down is left to the enclosing `ScrollView`
    /// (a vertical scroll view never claims cross-axis movement, so a sideways drag doesn't fight it), and
    /// anything under 8 pt is not a drag at all, so a tap still reaches an enclosing `NavigationLink`.
    ///
    /// This deliberately does NOT gate on a long press. It used to: 0.25 s stationary within 8 pt, copied
    /// from `OverviewHRChart`, where the hold is load-bearing because the Deep Timeline's own pan and
    /// pinch own immediate movement. Here nothing competes for an immediate sideways drag, and the hold
    /// made a plain swipe — the one thing a reader actually does to a trend line — fail the gesture
    /// outright, so the chart appeared not to scrub at all.
    ///
    /// Off by default: a decorative or non-interactive copy of a chart shouldn't claim drags.
    public var touchScrub: Bool
    /// Formats a point's value for the tooltip's bold line (default: rounded int).
    public var valueFormat: (Double) -> String
    /// Formats a point's date for the tooltip's secondary line.
    public var dateFormat: (Date) -> String
    /// Optional human-readable series name for VoiceOver (e.g. "HRV trend"). When nil the
    /// element falls back to a generic "Trend" label so it's never unlabeled.
    public var accessibilityLabel: String?
    /// When set, draws a flat "now" marker on the most-recent point — IN the chart's own
    /// coordinate space (via the overlay proxy), so it sits exactly on the line. nil = no cap.
    /// (#458: an earlier sibling-overlay cap guessed the plot insets and floated off the line.)
    public var nowCapColor: Color?
    /// Y-axis domain when it should differ from `valueRange` — e.g. an axis fitted to the data
    /// window (with a little headroom) while the gradient stays anchored to the metric's full
    /// scale. nil = `valueRange`. Widening the TOP of this domain is how a caller keeps a peak
    /// curve and the top axis label clear of the plot clip (see #974); done purely in data space
    /// so it needs no macOS14/iOS17 plot-dimension padding API — works on our macOS13/iOS16 floor.
    public var yDomain: ClosedRange<Double>?

    /// Mean of all point values, computed once in `init` so the area fill's gradient
    /// stop doesn't run an O(n) reduce for every mark on every render.
    private let averageValue: Double

    /// One-line VoiceOver summary (count + mean + range), built once in `init`.
    private let a11ySummary: String

    public init(
        points: [TrendPoint],
        gradient: Gradient = StrandPalette.recoveryGradient,
        valueRange: ClosedRange<Double> = 0...100,
        showsArea: Bool = true,
        showsBars: Bool = false,
        baselineValue: Double? = nil,
        height: CGFloat = 220,
        showsHover: Bool = true,
        touchScrub: Bool = false,
        valueFormat: @escaping (Double) -> String = { String(Int($0.rounded())) },
        dateFormat: @escaping (Date) -> String = { TrendChart.defaultDateString($0) },
        accessibilityLabel: String? = nil,
        nowCapColor: Color? = nil,
        yDomain: ClosedRange<Double>? = nil
    ) {
        let sorted = points.sorted { $0.date < $1.date }
        self.points = sorted
        self.gradient = gradient
        self.valueRange = valueRange
        self.showsArea = showsArea
        self.showsBars = showsBars
        self.baselineValue = baselineValue
        self.height = height
        self.showsHover = showsHover
        self.touchScrub = touchScrub
        self.valueFormat = valueFormat
        self.dateFormat = dateFormat
        self.accessibilityLabel = accessibilityLabel
        self.nowCapColor = nowCapColor
        self.yDomain = yDomain
        let avg = sorted.isEmpty
            ? valueRange.lowerBound
            : sorted.map(\.value).reduce(0, +) / Double(sorted.count)
        self.averageValue = avg

        // The point set handed to the marks: full resolution up to the threshold, else min/max-bucketed
        // to ~the plot pixel width (pixel-identical line, far fewer GPU vertices). Computed once here.
        self.displayPoints = ChartDownsample.minMaxBucketed(sorted, threshold: ChartDownsample.markThreshold,
                                                            targetCount: ChartDownsample.targetVertices)

        // VoiceOver one-liner: count + mean + range — formatted with the SAME valueFormat the
        // tooltip uses, so units match. Computed once here, not per render.
        if sorted.isEmpty {
            self.a11ySummary = String(localized: "No data", bundle: .module)
        } else {
            let vals = sorted.map(\.value)
            let lo = vals.min()!, hi = vals.max()!
            self.a11ySummary = String(localized: "\(sorted.count) points, mean \(valueFormat(avg)), range \(valueFormat(lo)) to \(valueFormat(hi))", bundle: .module)
        }
    }

    /// The x-position the cursor is hovering, in chart-local coordinates.
    @State private var hoverX: CGFloat? = nil

    /// Series-id prefix of the retired halo copy (decision 19: no halo is drawn; kept as a name only).
    static let haloSeriesPrefix = "\u{2063}halo\u{2063}"
    /// Point marks are drawn only for series this short (§5.7).
    static let pointMarkLimit = 14

    /// Which way the touch drag in progress was resolved. Decided once per drag from its first 8 pt and
    /// reset on lift; `.horizontal` is also the "engaged" flag the engage haptic fires on.
    @State private var scrubAxis: ChartHoverMath.ScrubAxis = .undecided

    /// PERF: a 365-day (or longer) series feeds Swift Charts hundreds of LineMark/AreaMark vertices, each
    /// catmullRom-interpolated — far more than the ~360pt plot has pixels, so most are sub-pixel and pure
    /// draw cost. `displayPoints` is the point set actually handed to the marks: full resolution up to a
    /// threshold, else min/max-per-bucket down to roughly the plot pixel width. Min/max bucketing keeps
    /// every visible peak and trough, so the rendered line is pixel-identical on a normal-width chart.
    /// Computed ONCE in `init` (not per body/hover eval), so it's memoized on `points`; hover / now-cap /
    /// accessibility stay on the full-resolution `points` so those readouts are unchanged.
    private let displayPoints: [TrendPoint]

    private static let sharedDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()

    /// Default tooltip date format ("EEE d MMM"), exposed so it can seed the
    /// `dateFormat` default argument.
    public static func defaultDateString(_ date: Date) -> String {
        sharedDateFormatter.string(from: date)
    }

    private static let dayKeyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    /// Scrub/tooltip label for a point whose date is a DAY KEY parsed at UTC midnight (the Explore / Trends
    /// series: "yyyy-MM-dd" through a UTC parser). Weekday + day + month in the device locale's own order
    /// ("Fr., 18. Sept." / "Fri, Sep 18"). Formatting in UTC is what keeps the label on the day the point
    /// belongs to: the local-zone default would render a UTC-midnight date as the PREVIOUS day anywhere
    /// west of Greenwich. `locale` is injectable for tests only.
    public static func dayKeyDateString(_ date: Date, locale: Locale? = nil) -> String {
        guard let locale else { return dayKeyDateFormatter.string(from: date) }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f.string(from: date)
    }

    /// The REAL sample nearest `date` — never a value interpolated between two of them.
    /// Pure and `static` so a test can pin the snapping without rendering a chart.
    /// `sorted` must be ascending by date (`init` sorts, so `points` always is).
    static func nearestPoint(toDate date: Date, in sorted: [TrendPoint]) -> TrendPoint? {
        guard let i = ChartHoverMath.nearestIndex(toDate: date, dates: sorted.map(\.date)) else { return nil }
        return sorted[i]
    }

    /// The point nearest a given chart-local x, using the proxy to map back.
    private func nearestPoint(toX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> TrendPoint? {
        guard !points.isEmpty else { return nil }
        // Map the cursor x (relative to the plot area) back to a Date.
        let relX = x - plot.minX
        guard let date: Date = proxy.value(atX: relX) else { return nil }
        return Self.nearestPoint(toDate: date, in: points)
    }

    #if os(iOS)
    /// Touch scrub: drag sideways to move the crosshair, immediately.
    ///
    /// `CompareView`'s proven shape — an ordinary `DragGesture` with a small minimum distance, attached
    /// `.simultaneously` so the page keeps scrolling — plus the one thing `CompareView` doesn't need: an
    /// EXPLICIT axis decision. `CompareView`'s chart is not inside a tappable card, so it can leave the
    /// horizontal/vertical call to the scroll view. These charts are (every Trends small-multiple is a
    /// `NavigationLink`), so the axis is resolved here from the first 8 pt of travel and then held: a
    /// sideways drag scrubs, an up/down drag is dropped on the floor for the `ScrollView` to carry, and
    /// under 8 pt nothing happens at all so a tap still opens the metric.
    ///
    /// Because a `.vertical` drag never touches `hoverX`, a scroll that cancels this gesture (so `onEnded`
    /// never arrives) cannot leave a crosshair stranded on the chart.
    private var touchScrubGesture: some Gesture {
        DragGesture(minimumDistance: ChartHoverMath.scrubMinimumDistance, coordinateSpace: .local)
            .onChanged { drag in
                if scrubAxis == .undecided {
                    scrubAxis = ChartHoverMath.scrubAxis(translation: drag.translation)
                    // Mark the mode switch the instant the scrub claims the finger, as the hold used to.
                    if scrubAxis == .horizontal { StrandHaptic.selection.play() }
                }
                guard scrubAxis == .horizontal else { return }
                // Non-animating transaction, same reason as hover (#104 flicker).
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { hoverX = drag.location.x }
            }
            .onEnded { _ in
                scrubAxis = .undecided
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { hoverX = nil }
            }
    }
    #endif

    // Map data values onto the unit interval for gradient stops.
    private func unit(_ value: Double) -> Double {
        let lo = valueRange.lowerBound, hi = valueRange.upperBound
        guard hi > lo else { return 0 }
        return min(max((value - lo) / (hi - lo), 0), 1)
    }

    // A vertical gradient keyed to the value axis so the stroke color tracks value.
    private var valueGradient: LinearGradient {
        LinearGradient(gradient: gradient, startPoint: .bottom, endPoint: .top)
    }

    /// The Y domain actually applied to the axis + plot clip: the explicit `yDomain` when a caller
    /// supplied one (e.g. a data-fitted axis with top headroom), else the gradient's `valueRange`.
    /// Exposed internally so a unit test can pin the resolution without rendering the chart.
    var resolvedYDomain: ClosedRange<Double> { yDomain ?? valueRange }

    /// `resolvedYDomain`, floored at (or below) 0 in bar mode so a `BarMark`'s length stays
    /// proportional to its value — see the `.chartYScale` comment in `body` for why. Line mode is
    /// unaffected. Exposed internally alongside `resolvedYDomain` for the same test-without-rendering
    /// reason.
    var plotYDomain: ClosedRange<Double> {
        showsBars ? min(0, resolvedYDomain.lowerBound)...resolvedYDomain.upperBound : resolvedYDomain
    }

    public var body: some View {
        Chart {
            if let baselineValue {
                RuleMark(y: .value("Baseline", baselineValue))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(TelosColor.textTertiary.opacity(0.6))
            }
            if showsBars {
                // Bar mode: one value-ramp-filled BarMark per (down-sampled) sample, from the baseline.
                // The line, area and point marks are all replaced. The same `displayPoints` feed it, so a
                // dense window is min/max-bucketed to the vertex budget exactly as the line is; hover, the
                // axes, the domain and accessibility are unchanged (they read the full `points`).
                ForEach(displayPoints) { p in
                    BarMark(
                        x: .value("Date", p.date),
                        y: .value("Value", p.value)
                    )
                    .foregroundStyle(valueGradient)
                }
            } else {
                if showsArea {
                    ForEach(displayPoints) { p in
                        AreaMark(
                            x: .value("Date", p.date),
                            y: .value("Value", p.value),
                            series: .value("Segment", p.segment)
                        )
                        // `.monotone`, not `.catmullRom`: a monotone cubic never overshoots past the real
                        // samples, so the curve cannot show a peak or dip the data never contained.
                        .interpolationMethod(.monotone)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    StrandPalette.sample(stops: gradient.toStops(), at: unit(averageValue)).opacity(0.18),
                                    Color.clear
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                }
                // One crisp line per segment — no halo copy under it (decision 19).
                ForEach(displayPoints) { p in
                    LineMark(
                        x: .value("Date", p.date),
                        y: .value("Value", p.value),
                        series: .value("Segment", p.segment)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: TelosStroke.dataHero, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(valueGradient)
                }
                // Points only for short series (§5.7: n ≤ 14) — past that they crowd the luminous line
                // and cost the GPU a mark each; the line carries the data. The gate stays on the full
                // `points.count` (≤ 120 is never downsampled, so displayPoints == points here).
                if points.count <= Self.pointMarkLimit {
                    ForEach(displayPoints) { p in
                        PointMark(
                            x: .value("Date", p.date),
                            y: .value("Value", p.value)
                        )
                        .symbolSize(18)
                        .foregroundStyle(StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value)))
                    }
                }
            }
        }
        // Domain drives BOTH the axis extent and the plot clip. A caller that wants a top-of-range
        // peak (and the top axis label) to clear the clip passes a `yDomain` whose upper bound sits a
        // little above the data — pure data-space headroom, so no macOS14/iOS17 plot-dimension endPadding
        // API is needed (#974). The value→color gradient still keys off `valueRange`, unchanged.
        // Bars must read from a zero baseline to be truthful: a BarMark's length is only proportional to
        // its value when 0 is in the domain. The LINE uses a data-FITTED domain (often non-zero — e.g. an
        // RHR window of ~48…61) to show variation; reusing that for bars would float every bar near full
        // height with the real differences squashed into the top. So in bar mode we drop the floor to 0
        // (or below, should a caller ever plot negatives), matching Android's zero-based BarChart. The
        // upper bound (with the caller's headroom) is unchanged, so the line's domain is untouched.
        .chartYScale(domain: plotYDomain)
        // Clip the plot to its own bounds. The AreaMark gradient is drawn UNCLIPPED - on a spiky HR
        // curve the fill once bled down the page behind the cards below the chart. The plot sits on a
        // faint dark "glass" well (a flat fill - no material, no blur); clipping bounds every mark.
        .chartPlotStyle { plotArea in
            plotArea
                .background(TelosChartStyle.plotWell)
                .clipped()
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine(stroke: TelosChartStyle.gridStroke).foregroundStyle(TelosChartStyle.gridInk)
                AxisValueLabel().foregroundStyle(TelosColor.textTertiary)
                    .font(TelosType.scaleNumber)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: TelosChartStyle.gridStroke).foregroundStyle(TelosChartStyle.gridInk)
                AxisValueLabel().foregroundStyle(TelosColor.textTertiary)
                    .font(TelosType.scaleNumber)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    // The overlay's hit region. Everything else in this ZStack is conditional, so with
                    // nothing hovered and no `nowCapColor` the stack had NO children — a 0×0 layout, which
                    // `.contentShape(Rectangle())` below faithfully turned into a 0×0 hit shape. The
                    // scrub gesture and the pointer hover therefore had no area to land on at all on every
                    // caller that doesn't pass a now-cap (Explore, Apple Health, Mi Band: exactly the HRV
                    // and resting-HR charts reported as unscrubbable). Trends only worked because its
                    // now-cap dot happens to be a `.position`ed child, which fills the proposal.
                    // A greedy clear layer makes the region the chart's frame. Gated on `showsHover` so a
                    // deliberately non-interactive copy (the hosted Today card, the skin-temp cards) keeps
                    // its current zero-size, zero-hit overlay exactly as it is.
                    if showsHover { Color.clear }

                    if showsHover,
                       let hx = hoverX,
                       let p = nearestPoint(toX: hx, proxy: proxy, plot: plot),
                       let px = proxy.position(forX: p.date),
                       let py = proxy.position(forY: p.value) {
                        let cx = px + plot.minX
                        let cy = py + plot.minY
                        let color = StrandPalette.sample(stops: gradient.toStops(), at: unit(p.value))

                        // Vertical crosshair at the nearest x.
                        CrosshairRule(x: cx, height: geo.size.height)

                        // Highlighted dot on the line.
                        HighlightDot(color: color)
                            .position(x: cx, y: cy)

                        // Callout pinned to the top edge of the plot, beside the point (§5.7) - it never
                        // covers the point it names.
                        PositionedTooltip(
                            anchor: CGPoint(x: cx, y: cy),
                            container: geo.size,
                            tooltip: ChartTooltip(
                                value: valueFormat(p.value),
                                label: dateFormat(p.date),
                                accent: color
                            ),
                            pinnedTop: true,
                            plotTop: plot.minY
                        )
                    }

                    // "Now" end-cap on the latest point (#458). Positioned with the SAME proxy mapping the
                    // line uses (position(forX:/forY:) + plot origin), so it lands exactly on the curve —
                    // not via a sibling overlay guessing the axis insets, which floated it left/below.
                    if !showsBars, let capColor = nowCapColor, let last = points.last,
                       let px = proxy.position(forX: last.date),
                       let py = proxy.position(forY: last.value) {
                        NowCapDot(color: capColor)
                            .position(x: px + plot.minX, y: py + plot.minY)
                            .allowsHitTesting(false)
                    }
                }
                .animation(StrandMotion.fade, value: hoverX)
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    guard showsHover else { return }
                    // Update the hover position in a NON-animating transaction. Otherwise entering or
                    // leaving the chart flips hoverX inside an animated context, the body re-evaluates,
                    // and SwiftUI Charts re-runs the line's draw-on animation — flickering the curve to a
                    // flat baseline and back as the cursor crosses the plot edge (#104). The crosshair's
                    // own fade is the overlay's .animation(value: hoverX) above and is unaffected by this.
                    var tx = Transaction()
                    tx.disablesAnimations = true
                    withTransaction(tx) {
                        switch phase {
                        case .active(let location): hoverX = location.x
                        case .ended: hoverX = nil
                        }
                    }
                }
                #if os(iOS)
                // Touch scrub (see `touchScrub`). SIMULTANEOUS, not `.gesture`: the enclosing ScrollView's
                // pan and any enclosing NavigationLink must keep running alongside, so an up/down drag
                // still scrolls the page and a tap still opens the metric. The axis decision inside the
                // gesture is what keeps the two from contradicting each other. `.subviews` masks the
                // gesture entirely on the call sites that don't opt in, so their touch handling is
                // exactly as before.
                .simultaneousGesture(touchScrubGesture,
                                     including: (touchScrub && showsHover) ? .all : .subviews)
                #endif
            }
        }
        .frame(height: height)
        // NOTE: no outer `.clipped()` here. The PLOT is already clipped to its own bounds by
        // `.chartPlotStyle { plotArea.clipped() }` above (that's what contains the catmullRom overshoot +
        // the unclipped AreaMark bleed). An additional clip on the WHOLE chart also cropped the axis-label
        // gutter — cutting the top y-axis value (e.g. "90") in half and clipping the first/last x-axis
        // labels ("Apr 19"…"May") at the frame edges (#1019). Dropping it lets Swift Charts render the
        // reserved label regions in full; the marks stay contained by the plot clip, so nothing bleeds.
        // Collapse the Charts marks (line/area/points) into ONE meaningful VoiceOver element instead
        // of letting VoiceOver walk raw per-mark axis values with no series context. The decorative
        // stacked under-glow copy (showsHover:false, no label) is hidden so the same series isn't
        // double-announced; the crisp interactive copy passes showsHover:true (default) and speaks.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel.map(Text.init) ?? Text("Trend", bundle: .module))
        .accessibilityValue(Text(a11ySummary))
        .accessibilityHidden(!showsHover && accessibilityLabel == nil)
    }
}

// MARK: - Telos chart style (shared by TrendChart / OverviewHRChart)

/// The luminous chart look (§5.7 + VISUAL DIRECTION): a faint dotted grid and a dark glass plot well.
/// Strokes and inks are stored once (static lets); the well is a tiny static view.
enum TelosChartStyle {
    /// Faint dotted grid lines.
    static let gridStroke = StrokeStyle(lineWidth: TelosStroke.hair, dash: [1, 3])
    static let gridInk = TelosColor.lineStrong
    /// The plot's dark glass well: a flat translucent inset fill with rounded corners. No material.
    static var plotWell: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(TelosColor.surfaceInset.opacity(0.45))
    }
}

// MARK: - Chart downsampling (pure)
//
// Reduces a dense point series to roughly the plot's pixel width BEFORE it reaches Swift Charts, so the
// GPU draws ~one vertex per pixel instead of hundreds it can't resolve. Uses MIN/MAX-per-bucket: each
// bucket contributes its lowest and highest sample (in time order), so every visible peak and trough
// survives and the rendered envelope is identical at normal chart widths. First and last points are
// always kept so the line spans the full domain. Pure + deterministic — same input → same output.

enum ChartDownsample {
    /// Above this many points we downsample; at or below it the series is passed through untouched (so
    /// the common 7/30/90-day trends and the ≤60-point dotted series are byte-for-byte unchanged).
    static let markThreshold = 120
    /// Target drawn-vertex budget — a touch above a typical ~360pt plot so the line stays crisp.
    static let targetVertices = 400

    /// Min/max-bucketed copy of `points` when it exceeds `threshold`, else `points` unchanged.
    /// Assumes `points` is already sorted by date (both chart callers sort in their init).
    static func minMaxBucketed(_ points: [TrendPoint], threshold: Int, targetCount: Int) -> [TrendPoint] {
        let n = points.count
        guard n > threshold, n > 2, targetCount >= 4 else { return points }

        // Reserve the first and last; bucket the interior. Each bucket yields up to 2 vertices (min+max),
        // so aim for ~targetCount/2 buckets to land near the vertex budget.
        let first = points[0]
        let last = points[n - 1]
        let interior = n - 2
        let bucketCount = max(1, (targetCount - 2) / 2)
        guard bucketCount < interior else { return points }

        var out: [TrendPoint] = []
        out.reserveCapacity(targetCount)
        out.append(first)

        var lastEmittedDate = first.date
        for b in 0..<bucketCount {
            // Interior indices [1 ... n-2] split into `bucketCount` contiguous ranges.
            let lo = 1 + (b * interior) / bucketCount
            let hi = 1 + ((b + 1) * interior) / bucketCount // exclusive
            guard lo < hi else { continue }

            // Find the min-value and max-value samples in this bucket.
            var minIdx = lo, maxIdx = lo
            var i = lo + 1
            while i < hi {
                if points[i].value < points[minIdx].value { minIdx = i }
                if points[i].value > points[maxIdx].value { maxIdx = i }
                i += 1
            }

            // Emit the two extremes in chronological order, skipping duplicates (monotone bucket → one
            // point) and any whose date would not advance (keeps `id: Date` unique for ForEach).
            let lowFirst = minIdx <= maxIdx
            let aIdx = lowFirst ? minIdx : maxIdx
            let bIdx = lowFirst ? maxIdx : minIdx
            for idx in [aIdx, bIdx] {
                let p = points[idx]
                if p.date > lastEmittedDate {
                    out.append(p)
                    lastEmittedDate = p.date
                }
            }
        }

        if last.date > lastEmittedDate { out.append(last) }
        return out
    }
}

// MARK: - Gradient → stops bridge

extension Gradient {
    /// Reconstruct ordered stops from a Gradient. SwiftUI does not expose `.stops`
    /// directly on all paths, so we use the public `stops` mirror when present.
    func toStops() -> [Gradient.Stop] {
        // `Gradient.stops` is public on macOS 13+; expose for our sampler.
        self.stops
    }
}

#if DEBUG
private func sampleTrend(days: Int, base: Double, swing: Double) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<days).map { i in
        let date = cal.date(byAdding: .day, value: -(days - 1 - i), to: today)!
        let v = base + swing * sin(Double(i) / 3.0) + Double((i * 17) % 9) - 4
        return TrendPoint(date: date, value: max(0, v))
    }
}

#Preview("TrendChart — recovery") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Recovery — 30 days").strandOverline()
        Text("Hover the line: crosshair + dot + date/value tooltip.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(points: sampleTrend(days: 30, base: 62, swing: 22))
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}

#Preview("TrendChart — HRV") {
    VStack(alignment: .leading, spacing: 12) {
        Text("HRV (ms) — 30 days").strandOverline()
        Text("Hover to read each day's HRV in ms.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        TrendChart(
            points: sampleTrend(days: 30, base: 58, swing: 14),
            gradient: StrandPalette.recoveryGradient,
            valueRange: 20...100,
            showsArea: true,
            valueFormat: { "\(Int($0.rounded())) ms" }
        )
    }
    .padding(28)
    .frame(width: 720, height: 340)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
