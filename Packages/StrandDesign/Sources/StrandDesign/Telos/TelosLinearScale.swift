import SwiftUI

// MARK: - TelosLinearScale — segmented bars, gradient bars, the load wave, luminous micro-sparklines
//
// The small linear instruments of the reference screens:
//   • `TelosSegmentedBar`       — Nervous System "Focus ▮▮▮▮▮▮▮▮▮▯ 92 %": pips lit to the value.
//   • `TelosGradientBar`        — Metabolic Engine "Glucose / Fat / Ketones": a gradient fill with a
//                                 luminous head.
//   • `TelosLoadWave`           — Environment "Environmental Load": an organic filled wave.
//   • `TelosLuminousSparkline`  — the crisp micro-sparkline under compact numbers (125 bpm ⌇); no
//                                 halo, no glowing head (decision 19).
//
// Shared honesty rules (§2.3, coordinator decision 9):
//   • absent (nil / non-finite) → an empty track; the caller prints "—" + reason. Never a zero fill.
//   • `scale` is ONE full bar, not a maximum: a value past it fills the bar AND draws the overflow as a
//     thin second "lap" line along the top plus an end notch — never clipped at 100 %.
//   • lines break at gaps (non-finite values) and never bridge them; smoothing never passes beyond the
//     real data (midpoint quadratics stay inside each point's neighbours — no overshoot).
//
// Cost (§2.1 rule 8): shapes and single Canvases, no clock, no blur, no shadow. Bars animate their fill
// with `TelosMotion.settle` only when the value changes (never on appear), instantly under Reduce
// Motion. Everything else is static. Watch-safe.

public enum TelosScaleMath {

    /// How a segmented bar lights up.
    public struct Segments: Equatable, Sendable {
        /// Fully lit pips.
        public let lit: Int
        /// The fill (0…1) of the pip after the lit ones (0 when none is partial).
        public let partial: Double
        /// The value ran past the scale — every pip lit and the overflow marker drawn.
        public let overflow: Bool
        /// No reading: nothing lit.
        public let absent: Bool
    }

    /// The fill for `value` on `scale` across `count` pips.
    public static func segments(value: Double?, scale: Double, count: Int) -> Segments {
        let n = max(1, count)
        guard let f = fraction(value: value, scale: scale) else {
            return Segments(lit: 0, partial: 0, overflow: false, absent: true)
        }
        if f > 1 + 1e-9 { return Segments(lit: n, partial: 0, overflow: true, absent: false) }
        let exact = f * Double(n)
        let lit = min(n, Int(exact.rounded(.down) + 1e-9))
        let partial = lit < n ? exact - Double(lit) : 0
        return Segments(lit: lit, partial: max(0, min(1, partial)), overflow: false, absent: false)
    }

    /// `value / scale`, unclamped above (negative → 0). nil for absent / non-finite / bad scale.
    public static func fraction(value: Double?, scale: Double) -> Double? {
        guard let value, value.isFinite, scale.isFinite, scale > 0 else { return nil }
        return max(0, value / scale)
    }

    /// A bar's drawable split: the main fill (0…1) and the overflow "second lap" (0…1, 0 when within
    /// scale). Beyond two laps the overflow line stays full and `beyondSecondLap` says so.
    public static func bar(value: Double?, scale: Double) -> (fill: Double, overflow: Double, beyondSecondLap: Bool)? {
        guard let f = fraction(value: value, scale: scale) else { return nil }
        return (min(f, 1), min(max(f - 1, 0), 1), f > 2 + 1e-9)
    }

    /// Runs of consecutive finite values (index ranges). A lone finite value is a run of one.
    public static func finiteRuns(_ values: [Double]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int? = nil
        for (i, v) in values.enumerated() {
            if v.isFinite {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s...(i - 1))
                start = nil
            }
        }
        if let s = start { runs.append(s...(values.count - 1)) }
        return runs
    }

    /// A smooth path through `points` built from midpoint quadratics: each curve segment runs between
    /// two midpoints with the data point as its control, so it lies inside the triangle of those three
    /// points — it can NEVER overshoot the data's local extremes (unlike Catmull-Rom). The path starts
    /// on the first point and ends on the last.
    public static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

// MARK: - Segmented bar

/// Pips lit to the value (Nervous System "Focus 92 %"). The partial pip is lit at its fraction's
/// opacity. Overflow lights every pip and adds a bright notch after the last one.
public struct TelosSegmentedBar: View {
    private let value: Double?
    private let scale: Double
    private let count: Int
    private let color: Color
    private let height: CGFloat

    public init(value: Double?, scale: Double = 100, segments: Int = 10,
                color: Color = TelosColor.mint, height: CGFloat = 6) {
        self.value = value
        self.scale = scale
        self.count = max(1, segments)
        self.color = color
        self.height = max(2, height)
    }

    public var body: some View {
        let fill = TelosScaleMath.segments(value: value, scale: scale, count: count)
        HStack(spacing: max(1.5, height * 0.4)) {
            ForEach(0..<count, id: \.self) { i in
                let opacity: Double = {
                    if fill.absent { return 0 }
                    if i < fill.lit { return 1 }
                    if i == fill.lit { return fill.partial }
                    return 0
                }()
                ZStack {
                    Capsule(style: .continuous).fill(color.opacity(TelosOpacity.fill))
                    if opacity > 0 {
                        Capsule(style: .continuous).fill(color.opacity(opacity))
                    }
                }
            }
            if fill.overflow {
                Capsule(style: .continuous)
                    .fill(TelosColor.textPrimary)
                    .frame(width: max(2, height * 0.45))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Gradient bar

/// The fill shape (animatable on the fraction).
struct TelosBarFill: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(max(fraction, 0), 1)
        guard f > 0.0005 else { return Path() }
        let w = max(rect.height, rect.width * CGFloat(f))
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height),
                    cornerRadius: rect.height / 2, style: .continuous)
    }
}

/// A gradient fill (Metabolic Engine). `colors` run left → right across the WHOLE track (so a fuller
/// bar shows more of the ramp). No glowing head dot (decision 19) — the fill's end is the reading.
public struct TelosGradientBar: View {
    private let value: Double?
    private let scale: Double
    private let colors: [Color]
    private let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var shown: Double? = nil

    public init(value: Double?, scale: Double = 100, colors: [Color], height: CGFloat = 6) {
        self.value = value
        self.scale = scale
        self.colors = colors.isEmpty ? [TelosColor.mint] : colors
        self.height = max(2, height)
    }

    private var target: (fill: Double, overflow: Double, beyondSecondLap: Bool)? {
        TelosScaleMath.bar(value: value, scale: scale)
    }

    public var body: some View {
        let bar = target
        let fill = shown ?? bar?.fill ?? 0
        let head = colors[colors.count - 1]
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(head.opacity(TelosOpacity.fill))
                if bar != nil {
                    TelosBarFill(fraction: fill)
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                }
                if let bar, bar.overflow > 0 {
                    // The second lap: a thin bright line along the top edge, to the overflow fraction.
                    Capsule(style: .continuous)
                        .fill(TelosColor.textPrimary.opacity(bar.beyondSecondLap ? 1 : 0.85))
                        .frame(width: max(2, w * CGFloat(bar.overflow)), height: max(1, height * 0.28))
                        .offset(y: -height * 0.36)
                }
            }
        }
        .frame(height: height)
        .onAppear { shown = bar?.fill ?? 0 }
        .onChangeCompat(of: bar?.fill) { newFill in
            let next = newFill ?? 0
            if motion.poseStill(reduceMotion) || shown == nil {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { shown = next }
            } else {
                withAnimation(TelosMotion.settle) { shown = next }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Load wave

/// The Environment screen's organic load wave: a smoothed, filled wave with a luminous crest line and
/// a glowing dot on the latest reading. Gaps (non-finite values) break the wave. The vertical scale is
/// `range` when given, else the data's own min…max with 12 % headroom.
public struct TelosLoadWave: View {
    private let values: [Double]
    private let color: Color
    private let range: ClosedRange<Double>?

    public init(values: [Double], color: Color = TelosColor.mint, range: ClosedRange<Double>? = nil) {
        self.values = values
        self.color = color
        self.range = range
    }

    public var body: some View {
        Canvas { context, size in
            TelosLoadWave.draw(values: values, range: range, color: color, context: &context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The points of each finite run, mapped into `size`.
    static func runPoints(values: [Double], range: ClosedRange<Double>?, size: CGSize) -> [[CGPoint]] {
        let finite = values.filter { $0.isFinite }
        guard values.count >= 2, let lo0 = finite.min(), let hi0 = finite.max(), size.width > 0 else { return [] }
        var lo = range?.lowerBound ?? lo0
        var hi = range?.upperBound ?? hi0
        if range == nil {
            let pad = max((hi - lo) * 0.12, 0.5)
            lo -= pad
            hi += pad
        }
        let span = max(hi - lo, 1e-9)
        let step = size.width / CGFloat(values.count - 1)
        return TelosScaleMath.finiteRuns(values).map { run in
            run.map { i in
                CGPoint(x: CGFloat(i) * step,
                        y: size.height - CGFloat((values[i] - lo) / span) * size.height)
            }
        }
    }

    static func draw(values: [Double], range: ClosedRange<Double>?, color: Color,
                     context: inout GraphicsContext, size: CGSize) {
        let runs = runPoints(values: values, range: range, size: size)
        for pts in runs {
            guard let first = pts.first, let last = pts.last else { continue }
            if pts.count == 1 {
                context.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)),
                             with: .color(color))
                continue
            }
            let crest = TelosScaleMath.smoothPath(pts)
            var area = crest
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.addLine(to: CGPoint(x: first.x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.32), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(crest, with: .color(color),
                           style: StrokeStyle(lineWidth: TelosStroke.strong, lineCap: .round, lineJoin: .round))
        }
        // A flat dot on the latest reading (only when the series ENDS on a real value). No halo.
        if let lastValue = values.last, lastValue.isFinite, let head = runs.last?.last {
            context.fill(Path(ellipseIn: CGRect(x: head.x - 2, y: head.y - 2, width: 4, height: 4)),
                         with: .color(color))
        }
    }
}

// MARK: - Luminous micro-sparkline

/// The micro-sparkline (Training Coach "125 bpm ⌇", Mind & Focus band readouts): a crisp 1.5 pt line
/// and a flat last-point dot — no halo, no glow (decision 19). Straight segments between REAL points
/// (no interpolation, no overshoot); non-finite values break the line (shared geometry with the P1
/// `TelosMicroSparkline`, so both agree on every point). Scale is the series' own min…max.
public struct TelosLuminousSparkline: View {
    private let values: [Double]
    private let color: Color
    private let lineWidth: CGFloat

    public init(values: [Double], color: Color = TelosColor.mint, lineWidth: CGFloat = TelosStroke.strong) {
        self.values = values
        self.color = color
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            TelosSparklinePath(values: values)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            TelosSparklineHead(values: values, diameter: lineWidth * 2)
                .fill(color)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Linear scales") {
    VStack(alignment: .leading, spacing: 18) {
        TelosSegmentedBar(value: 92, segments: 10, color: TelosColor.mint).frame(width: 120)
        TelosSegmentedBar(value: 118, segments: 10, color: TelosColor.mint).frame(width: 120)
        TelosGradientBar(value: 62, colors: [TelosColor.mint.opacity(0.6), TelosColor.mint]).frame(width: 220)
        TelosGradientBar(value: 134, colors: [TelosColor.orange.opacity(0.6), TelosColor.orange]).frame(width: 220)
        TelosLoadWave(values: [3, 4, 3.2, 5, 6.5, .nan, 4, 3.5, 4.8, 4.2], color: TelosColor.mint)
            .frame(width: 220, height: 60)
        TelosLuminousSparkline(values: [120, 124, 118, 130, 125, 127], color: TelosColor.mint)
            .frame(width: 80, height: 22)
    }
    .padding(28)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
