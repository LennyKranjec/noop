#if !os(watchOS)
// The chart-hover toolkit (tooltips, crosshair, nearest-point) is for pointer/cursor charts the
// watch never shows; excluded on watchOS, iOS/macOS unchanged.
import SwiftUI

// MARK: - Chart Hover Toolkit (reusable across every visualization)
//
// A shared, instrument-grade hover affordance: a small dark tooltip card that
// names the exact datum under the cursor, plus geometry helpers for crosshairs
// and nearest-point lookup. Every StrandDesign visualization inherits the same
// look so nothing is ever a static, unexplained colour.
//
// Design tokens only: surfaceOverlay background, hairline border, StrandFont +
// StrandPalette text, StrandMotion fade-in. Never hardcode hex.

// MARK: - ChartTooltip

/// A small dark read-out card shown near the cursor while hovering a chart.
/// Renders a bold primary value line and a secondary label/date line.
public struct ChartTooltip: View {

    /// The bold value line (e.g. "62 ms", "Recovery 88").
    public var value: String
    /// The secondary context line (e.g. a formatted date, stage clock, index).
    public var label: String?
    /// An optional accent swatch shown as a leading dot (e.g. the sampled
    /// gradient colour for that datum) so the tooltip explains the colour.
    public var accent: Color?

    public init(value: String, label: String? = nil, accent: Color? = nil) {
        self.value = value
        self.label = label
        self.accent = accent
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let accent {
                // Luminous swatch: a faint wide dot under the solid one (no shadow).
                ZStack {
                    Circle().fill(accent.opacity(0.3)).frame(width: 12, height: 12)
                    Circle().fill(accent).frame(width: 7, height: 7)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(StrandFont.captionNumber)
                    .fontWeight(.semibold)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let label {
                    Text(label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        // Telos callout (§5.7): opaque `surfaceRaised` + a 1 pt luminous glass hairline, radius 10. No
        // shadow and no material — it sits over a live chart.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TelosColor.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line)
                )
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label != nil ? "\(value), \(label!)" : value)
    }
}

// MARK: - Tooltip positioning

/// Position a tooltip near an anchor point while keeping it inside `container`.
/// Estimates the tooltip's size, then flips/clamps so it never spills off-edge.
public struct ChartTooltipPlacement {

    /// Compute the tooltip centre for an anchor (typically the highlighted point
    /// or the cursor), given the tooltip's measured size and the chart bounds.
    /// Prefers to sit above-and-right of the anchor, flipping when near an edge.
    public static func position(
        anchor: CGPoint,
        tooltipSize: CGSize,
        in container: CGSize,
        gap: CGFloat = 12
    ) -> CGPoint {
        let halfW = tooltipSize.width / 2
        let halfH = tooltipSize.height / 2

        // Default: above the anchor.
        var y = anchor.y - gap - halfH
        if y - halfH < 0 {
            // Not enough room above — drop below.
            y = anchor.y + gap + halfH
        }
        y = min(max(y, halfH), max(halfH, container.height - halfH))

        // Default: centred on the anchor x, clamped to bounds.
        var x = anchor.x
        x = min(max(x, halfW), max(halfW, container.width - halfW))

        return CGPoint(x: x, y: y)
    }

    /// The callout PINNED TO THE TOP EDGE of the plot (§5.7): vertically it sits just inside
    /// `plotTop`; horizontally it sits beside the anchor (right by default, flipped left when it would
    /// spill past the right edge), so it never covers the scrubbed point. Clamped inside `container`.
    public static func pinnedTop(
        anchorX: CGFloat,
        tooltipSize: CGSize,
        in container: CGSize,
        plotTop: CGFloat = 0,
        gap: CGFloat = 10
    ) -> CGPoint {
        let halfW = tooltipSize.width / 2
        let halfH = tooltipSize.height / 2
        let y = min(max(plotTop + halfH + 2, halfH), max(halfH, container.height - halfH))
        var x = anchorX + gap + halfW
        if x + halfW > container.width { x = anchorX - gap - halfW }
        x = min(max(x, halfW), max(halfW, container.width - halfW))
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Nearest-point lookup

/// Geometry helpers for mapping a hover location to the nearest datum.
public enum ChartHoverMath {

    /// Index of the sample whose x-position (evenly spaced across `width`) is
    /// closest to `x`. Returns nil for an empty series.
    public static func nearestIndex(toX x: CGFloat, count: Int, width: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        guard count > 1, width > 0 else { return 0 }
        let step = width / CGFloat(count - 1)
        let raw = Int((x / step).rounded())
        return min(max(raw, 0), count - 1)
    }

    /// Index of the point in `xs` (arbitrary x-positions) closest to `x`.
    public static func nearestIndex(toX x: CGFloat, xs: [CGFloat]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, px) in xs.enumerated() {
            let d = abs(px - x)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Index of the point in an ASCENDING-by-date series whose date is nearest `date`, by binary search.
    /// Ties snap to the EARLIER point. Returns nil for an empty series.
    ///
    /// The scrub readout snaps to a REAL sample rather than interpolating between two of them: a value
    /// read off the line between Tuesday and Thursday is a number the data never contained, and an
    /// invented reading is worse than a snapped one. Same rule and same tie-break as `CompareView`'s
    /// `nearestEntry`, so every scrubbable chart names the same day for the same finger position.
    public static func nearestIndex(toDate date: Date, dates: [Date]) -> Int? {
        guard !dates.isEmpty else { return nil }
        // Lower bound: first entry whose date is >= the cursor date.
        var lo = 0, hi = dates.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if dates[mid] < date { lo = mid + 1 } else { hi = mid }
        }
        if lo == 0 { return 0 }
        if lo == dates.count { return dates.count - 1 }
        let before = dates[lo - 1], after = dates[lo]
        return date.timeIntervalSince(before) <= after.timeIntervalSince(date) ? lo - 1 : lo
    }

    // MARK: Touch-scrub axis decision

    /// How far a finger must travel before a touch drag over a chart is classified.
    ///
    /// Small enough that a scrub engages within a couple of millimetres — the user reads it as immediate —
    /// and large enough that a tap, including the jitter a real thumb adds to one, never reaches the
    /// decision at all. That is what leaves a chart inside a `NavigationLink` its tap-to-open.
    public static let scrubMinimumDistance: CGFloat = 8

    /// Which gesture a touch drag over a chart belongs to. Decided ONCE from the first translation that
    /// clears `scrubMinimumDistance`, then held for the rest of that drag so a scrub that curves upward
    /// mid-stroke doesn't hand itself to the scroll view halfway through (or vice versa).
    public enum ScrubAxis: Equatable, Sendable {
        /// No movement past `scrubMinimumDistance` yet — neither owner claimed, nothing drawn.
        case undecided
        /// Mostly sideways: the chart scrubs. A vertical `ScrollView` does not claim cross-axis movement,
        /// so the page stays put on its own.
        case horizontal
        /// Mostly up/down: the enclosing `ScrollView` owns it and the chart must leave the crosshair
        /// alone, so the page scrolls exactly as it did before the chart became scrubbable.
        case vertical
    }

    /// Classify a drag by its translation.
    ///
    /// Distance is the straight line, matching `DragGesture(minimumDistance:)`, so the gesture's own gate
    /// and this decision fire on the same movement. A perfect diagonal goes to `.vertical`: an enclosing
    /// scroll view is the safer owner of an ambiguous drag, because a page that refuses to scroll is far
    /// more noticeable than a crosshair that doesn't appear.
    public static func scrubAxis(translation: CGSize,
                                 minimumDistance: CGFloat = scrubMinimumDistance) -> ScrubAxis {
        let dx = abs(translation.width), dy = abs(translation.height)
        guard (dx * dx + dy * dy).squareRoot() >= minimumDistance else { return .undecided }
        return dx > dy ? .horizontal : .vertical
    }
}

// MARK: - Crosshair rule

/// A thin vertical crosshair line drawn at a given x with a hairline-strong
/// stroke. Shared by TrendChart / Sparkline so the rule reads identically.
struct CrosshairRule: View {
    var x: CGFloat
    var height: CGFloat
    /// §5.7: a solid 1 pt rule in `textSecondary` (softened so it never outshines the data line).
    var color: Color = TelosColor.textSecondary.opacity(0.7)

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: height))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1))
        .allowsHitTesting(false)
    }
}

// MARK: - Highlighted point dot

/// A small accented dot used to mark the highlighted sample on a line.
struct HighlightDot: View {
    var color: Color
    /// §5.7: a 7 pt point with a 2 pt `surface` ring. No halo (decision 19).
    var diameter: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .fill(TelosColor.surface)
                .frame(width: diameter + 4, height: diameter + 4)
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - "Now" end-cap

/// The crisp "now" marker pinned to a trend line's latest point: a flat dot in the line colour on a
/// 2 pt `surface` ring — no tinted outer rings, no bright core (decision 19). Positioned by `TrendChart`
/// inside its own plot coordinate space so it sits exactly on the curve (#458).
struct NowCapDot: View {
    var color: Color

    var body: some View {
        ZStack {
            Circle().fill(TelosColor.surface).frame(width: 11, height: 11)
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Tooltip overlay container

/// Wraps a tooltip so its measured size feeds back into placement. Fades in
/// with StrandMotion and positions itself within `container` near `anchor`.
struct PositionedTooltip: View {
    var anchor: CGPoint
    var container: CGSize
    var tooltip: ChartTooltip
    /// true = the §5.7 callout pinned to the plot's top edge beside the point (TrendChart,
    /// OverviewHRChart); false = the legacy above/below-the-anchor placement (rings, sparklines, strips).
    var pinnedTop: Bool = false
    /// The plot's top edge in `container` coordinates (pinned placement only).
    var plotTop: CGFloat = 0

    @State private var measured: CGSize = .zero

    private var placement: CGPoint {
        let size = measured == .zero ? CGSize(width: 90, height: 40) : measured
        if pinnedTop {
            return ChartTooltipPlacement.pinnedTop(anchorX: anchor.x, tooltipSize: size,
                                                   in: container, plotTop: plotTop)
        }
        return ChartTooltipPlacement.position(anchor: anchor, tooltipSize: size, in: container)
    }

    var body: some View {
        tooltip
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { measured = g.size }
                        .onChangeCompat(of: g.size) { measured = $0 }
                }
            )
            .position(placement)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("ChartTooltip") {
    VStack(spacing: 24) {
        ChartTooltip(value: "Recovery 88", label: "Tue 3 Jun", accent: StrandPalette.recoveryColor(88))
        ChartTooltip(value: "62 ms", label: "HRV · sample 14")
        ChartTooltip(value: "18.7", label: "STRAIN · all-out", accent: StrandPalette.strainColor(18.7))
    }
    .padding(40)
    .frame(width: 320, height: 240)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
#endif
