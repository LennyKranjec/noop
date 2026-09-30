import SwiftUI

// MARK: - TelosMetricTile + TelosTileGrid — compact single-attribute tiles (coordinator decision 11)
//
// "No panel is bigger than what it shows." One attribute (HRV, resting HR, respiratory rate, SpO₂,
// skin temp, steps, water …) is a COMPACT TILE — label, number + unit, delta and/or confidence, an
// optional micro-sparkline — sized to its content and laid out several per row. Never a full-width
// card for one number.
//
//   TelosTileGrid {
//       TelosMetricTile("HRV", value: hrv, unit: "ms", delta: .value(hrvDelta, tone: .better),
//                       sparkline: last7)
//       TelosMetricTile("Resting HR", value: rhr, unit: "bpm", confidence: .building)
//       TelosMetricTile("SpO₂", value: nil, unit: "%", absentReason: Text("Strap not connected"))
//   }
//
// Honesty inside the tile is the same contract as `MetricReadout`: nil / non-finite → "—" + reason;
// calibrating → tertiary numeral + dashed tag; building → tag; carried → secondary numeral + "Carried ·
// d MMM"; the sparkline draws only real points (NaN breaks the line, < 2 points draws nothing).
//
// The grid picks 2, 3 or 4 columns from the width it is offered and the text size (the minimum tile
// width grows with Dynamic Type), drops to ONE column at accessibility sizes, and equalises heights
// per row. Tiles hug their content when used outside a grid.

// MARK: - Grid row-fill flag

private struct TelosTileFillsRowKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// Set by `TelosTileGrid` so its tiles stretch to the row's height; false everywhere else, so a
    /// tile outside a grid never grows past its content.
    var telosTileFillsRow: Bool {
        get { self[TelosTileFillsRowKey.self] }
        set { self[TelosTileFillsRowKey.self] = newValue }
    }
}

// MARK: - Tile

/// A compact metric tile: `scale` label → numeral (`numeralM`, capped) + unit → delta → micro-sparkline
/// → carried line / absent reason → confidence tag, with an optional thin accent glyph beside the
/// label. Radius `tile` (20), padding 12, the faux-glass surface honouring `\.telosCardOpacity`, no
/// minimum height. One VoiceOver element.
public struct TelosMetricTile: View {
    private let label: Text
    private let value: Double?
    private let unit: String?
    private let format: (Double) -> String
    private let confidence: TelosConfidence
    private let delta: TelosDelta?
    private let absentReason: Text?
    private let carriedFrom: Date?
    private let sparkline: [Double]?
    private let ink: Color
    private let sparkColor: Color?
    private let icon: String?
    private let iconTint: Color?

    @ScaledMetric(relativeTo: .title2) private var numeralSize: CGFloat = 24
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.telosTileFillsRow) private var fillsRow

    public init(_ label: LocalizedStringKey,
                value: Double?,
                unit: String? = nil,
                format: @escaping (Double) -> String = TelosFormat.integer,
                confidence: TelosConfidence = .solid,
                delta: TelosDelta? = nil,
                absentReason: Text? = nil,
                carriedFrom: Date? = nil,
                sparkline: [Double]? = nil,
                ink: Color = TelosColor.textPrimary,
                sparkColor: Color? = nil,
                icon: String? = nil,
                iconTint: Color? = nil) {
        self.label = Text(label)
        self.value = value
        self.unit = unit
        self.format = format
        self.confidence = confidence
        self.delta = delta
        self.absentReason = absentReason
        self.carriedFrom = carriedFrom
        self.sparkline = sparkline
        self.ink = ink
        self.sparkColor = sparkColor
        self.icon = icon
        self.iconTint = iconTint
    }

    private var finiteValue: Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private var numeralInk: Color {
        if case .calibrating = confidence { return TelosColor.tertiaryInk(for: contrast) }
        if carriedFrom != nil { return TelosColor.textSecondary }
        return ink
    }

    private var unitFont: Font {
        let style = TelosNumeralStyle.numeralM
        return TelosType.unitFont(forNumeralSize: min(numeralSize, style.size * style.cap))
    }

    private var drawableSparkline: [Double]? {
        guard let sparkline else { return nil }
        let finiteCount = sparkline.filter { $0.isFinite }.count
        return finiteCount >= 2 ? sparkline : nil
    }

    public var body: some View {
        let tertiary = TelosColor.tertiaryInk(for: contrast)
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                if let icon {
                    // The reference's thin accent glyph beside the label.
                    Image(systemName: icon)
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(iconTint ?? TelosColor.mint)
                        .accessibilityHidden(true)
                }
                label
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xxs) {
                if let v = finiteValue {
                    TelosCountingNumeral(value: v, format: format)
                        .telosNumeral(.numeralM)
                        .foregroundStyle(numeralInk)
                        .minimumScaleFactor(0.7)
                    if let unit {
                        Text(verbatim: unit)
                            .font(unitFont)
                            .foregroundStyle(TelosColor.textSecondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(verbatim: TelosType.absent)
                        .telosNumeral(.numeralM)
                        .foregroundStyle(tertiary)
                }
            }

            if let delta {
                TrendChip(text: delta.displayText, color: delta.color)
            }

            if finiteValue != nil, let points = drawableSparkline {
                TelosMicroSparkline(values: points, color: sparkColor ?? ink)
                    .frame(height: 16)
                    .accessibilityHidden(true)
            }

            if finiteValue == nil, let absentReason {
                absentReason
                    .font(TelosType.footnote)
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if finiteValue != nil, let carriedFrom {
                Text("Carried · \(TelosFormat.dayLabel(carriedFrom))")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !confidence.isSolid {
                ConfidenceTag(confidence)
            }
        }
        .padding(TelosSpace.tilePadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: fillsRow ? CGFloat.infinity : nil, alignment: .topLeading)
        .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.tile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: Text {
        var t: Text
        if let v = finiteValue {
            t = Text(verbatim: format(v))
            if let unit { t = t + Text(verbatim: " " + unit) }
        } else {
            t = AbsentValue.spoken(absentReason)
        }
        if let delta, let text = delta.text {
            t = t + Text(verbatim: ", " + text)
        }
        if !confidence.isSolid {
            t = t + Text(verbatim: ", ") + confidence.label
        }
        if finiteValue != nil, let carriedFrom {
            t = t + Text(verbatim: ", ") + Text("Carried · \(TelosFormat.dayLabel(carriedFrom))")
        }
        return t
    }
}

// MARK: - Micro-sparkline (static)

/// A static 1.5 pt line with a 4 pt last-point dot. Non-finite values BREAK the line (never bridged);
/// no animation, no gradient. Scale is the series' own min…max (a flat series draws mid-height).
struct TelosMicroSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack {
            TelosSparklinePath(values: values)
                .stroke(color, style: StrokeStyle(lineWidth: TelosStroke.strong, lineCap: .round, lineJoin: .round))
            TelosSparklineHead(values: values, diameter: 4)
                .fill(color)
        }
    }
}

/// Pure geometry shared by the line and its head (kept here so both agree on every point).
enum TelosSparklineGeometry {
    /// The point for each FINITE value (nil for a gap), mapped into `rect` with 2 pt vertical inset.
    static func points(_ values: [Double], in rect: CGRect) -> [CGPoint?] {
        let finite = values.filter { $0.isFinite }
        guard values.count >= 2, let lo = finite.min(), let hi = finite.max() else {
            return values.map { _ -> CGPoint? in nil }
        }
        let inset: CGFloat = 2
        let height = max(rect.height - inset * 2, 0)
        let span = hi - lo
        let stepX = rect.width / CGFloat(values.count - 1)
        var out: [CGPoint?] = []
        out.reserveCapacity(values.count)
        for (index, v) in values.enumerated() {
            guard v.isFinite else {
                out.append(nil)
                continue
            }
            let t: CGFloat = span > 0 ? CGFloat((v - lo) / span) : 0.5
            let x = rect.minX + CGFloat(index) * stepX
            let y = rect.maxY - inset - t * height
            out.append(CGPoint(x: x, y: y))
        }
        return out
    }
}

struct TelosSparklinePath: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var penDown = false
        for point in TelosSparklineGeometry.points(values, in: rect) {
            guard let point else {
                penDown = false
                continue
            }
            if penDown {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                penDown = true
            }
        }
        return path
    }
}

struct TelosSparklineHead: Shape {
    let values: [Double]
    let diameter: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = TelosSparklineGeometry.points(values, in: rect)
        guard let last = points.last, let point = last else { return path }
        let r = diameter / 2
        path.addEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: diameter, height: diameter))
        return path
    }
}

// MARK: - Grid

/// Lays compact tiles out 2, 3 or 4 per row from the offered width and the text size; ONE column at
/// accessibility text sizes (§2.4: reflow, never truncate). Heights are equal per row.
///
/// - Parameters:
///   - minTileWidth: the narrowest a tile may be at the Large text size (grows with Dynamic Type).
///   - spacing: gap between tiles, both axes (default 8).
///   - maxColumns: the most tiles per row (default 4).
public struct TelosTileGrid<Content: View>: View {
    private let minTileWidth: CGFloat
    private let spacing: CGFloat
    private let maxColumns: Int
    private let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(minTileWidth: CGFloat = TelosTileGridLayout.defaultMinTileWidth,
                spacing: CGFloat = TelosSpace.tileGap,
                maxColumns: Int = 4,
                @ViewBuilder content: () -> Content) {
        self.minTileWidth = minTileWidth
        self.spacing = spacing
        self.maxColumns = maxColumns
        self.content = content()
    }

    public var body: some View {
        let columns: Int = dynamicTypeSize.isAccessibilitySize ? 1 : maxColumns
        let width: CGFloat = minTileWidth * TelosTileGridLayout.widthScale(for: dynamicTypeSize)
        TelosTileGridLayout(minTileWidth: width, spacing: spacing, maxColumns: columns) {
            content
        }
        .environment(\.telosTileFillsRow, true)
    }
}

/// The grid's `Layout`. Public so a screen can use it directly with its own views.
public struct TelosTileGridLayout: Layout {
    /// The narrowest a compact tile may be at the Large text size.
    public static let defaultMinTileWidth: CGFloat = 104

    public var minTileWidth: CGFloat
    public var spacing: CGFloat
    public var maxColumns: Int

    public init(minTileWidth: CGFloat = TelosTileGridLayout.defaultMinTileWidth,
                spacing: CGFloat = TelosSpace.tileGap,
                maxColumns: Int = 4) {
        self.minTileWidth = minTileWidth
        self.spacing = spacing
        self.maxColumns = maxColumns
    }

    /// How much wider a tile must be at a larger text size, so numbers never truncate.
    public static func widthScale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: return 1.0
        case .xLarge:   return 1.1
        case .xxLarge:  return 1.2
        case .xxxLarge: return 1.3
        default:        return 1.6
        }
    }

    /// Columns for `count` tiles in `width`: as many `minTileWidth` tiles as fit, at least 1, at most
    /// `maxColumns` and never more than there are tiles. An unknown / infinite width uses the cap.
    public static func columns(forWidth width: CGFloat, minTileWidth: CGFloat, spacing: CGFloat,
                               maxColumns: Int, count: Int) -> Int {
        let cap = max(1, min(maxColumns, max(count, 1)))
        guard width.isFinite, width > 0, minTileWidth > 0 else { return cap }
        let fit = Int(((width + spacing) / (minTileWidth + spacing)).rounded(.down))
        return max(1, min(cap, fit))
    }

    private func resolvedWidth(_ proposal: ProposedViewSize, count: Int) -> CGFloat {
        if let w = proposal.width, w.isFinite { return max(w, 0) }
        let cols = max(1, min(maxColumns, count))
        return CGFloat(cols) * minTileWidth + CGFloat(cols - 1) * spacing
    }

    private func columnWidth(total: CGFloat, columns: Int) -> CGFloat {
        let gaps = CGFloat(max(columns - 1, 0)) * spacing
        return max((total - gaps) / CGFloat(max(columns, 1)), 0)
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, columnWidth: CGFloat) -> [CGFloat] {
        var heights: [CGFloat] = []
        var start = 0
        while start < subviews.count {
            let end = min(start + columns, subviews.count)
            var tallest: CGFloat = 0
            for index in start..<end {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
                tallest = max(tallest, size.height)
            }
            heights.append(tallest)
            start = end
        }
        return heights
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let width = resolvedWidth(proposal, count: count)
        let cols = TelosTileGridLayout.columns(forWidth: width, minTileWidth: minTileWidth,
                                               spacing: spacing, maxColumns: maxColumns, count: count)
        let colWidth = columnWidth(total: width, columns: cols)
        let heights = rowHeights(subviews, columns: cols, columnWidth: colWidth)
        let rowsHeight: CGFloat = heights.reduce(0, +)
        let gapsHeight: CGFloat = CGFloat(max(heights.count - 1, 0)) * spacing
        return CGSize(width: width, height: rowsHeight + gapsHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                              cache: inout ()) {
        let count = subviews.count
        guard count > 0 else { return }
        let cols = TelosTileGridLayout.columns(forWidth: bounds.width, minTileWidth: minTileWidth,
                                               spacing: spacing, maxColumns: maxColumns, count: count)
        let colWidth = columnWidth(total: bounds.width, columns: cols)
        let heights = rowHeights(subviews, columns: cols, columnWidth: colWidth)
        var y = bounds.minY
        for (row, rowHeight) in heights.enumerated() {
            for column in 0..<cols {
                let index = row * cols + column
                guard index < count else { break }
                let x = bounds.minX + CGFloat(column) * (colWidth + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      anchor: .topLeading,
                                      proposal: ProposedViewSize(width: colWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
    }
}
