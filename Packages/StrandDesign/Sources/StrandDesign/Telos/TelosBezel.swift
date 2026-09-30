import SwiftUI

// MARK: - TelosBezel — the radial scale / dial (docs/DESIGN_V2.md §5.6 "Radial scale / dial")
//
// The tick bezel on its own, for dials: body clock, stress 0–3, the zone dial, and the fine graduated
// ring around the Home "87 % OPTIMAL" ring. Minor ticks are hairlines, major ticks are longer; an
// optional band arc marks a typical range; the value caret sits at the exact fraction.
//
// Honesty: a value outside `range` is NOT pinned silently to the edge — the caret sits at the edge
// and is drawn HOLLOW with an outward notch, so "beyond the scale" reads differently from "at the
// end of the scale". Absent (nil / non-finite) draws the ticks only, dashed, with no caret.
//
// Cost (§2.1 rule 8): ONE Canvas, drawn once (no clock) — Core Animation caches the layer; it redraws
// only when an input changes. Watch-safe.

public enum TelosBezelMath {

    /// One tick: its angle in degrees (0 = 3 o'clock, clockwise) and whether it is a major tick.
    public struct Tick: Equatable, Sendable {
        public let degrees: Double
        public let isMajor: Bool
    }

    /// The ticks of a bezel spanning `spanDegrees` from `startDegrees`, with `majorCount` major
    /// intervals and `minorPerMajor` minor subdivisions per interval. A full 360° bezel does not
    /// repeat its first tick at the end.
    public static func ticks(majorCount: Int, minorPerMajor: Int,
                             startDegrees: Double = -90, spanDegrees: Double = 360) -> [Tick] {
        let majors = max(1, majorCount)
        let minors = max(1, minorPerMajor)
        let steps = majors * minors
        let closed = abs(spanDegrees) >= 360 - 1e-9
        let last = closed ? steps - 1 : steps
        return (0...last).map { i in
            Tick(degrees: startDegrees + spanDegrees * Double(i) / Double(steps), isMajor: i % minors == 0)
        }
    }

    /// Where a value sits on the scale: the drawable fraction (0…1) and whether it lies outside
    /// the range (then the caret is drawn hollow at the edge). nil for absent / non-finite input or
    /// an empty range.
    public static func position(of value: Double?, in range: ClosedRange<Double>)
        -> (fraction: Double, outOfRange: Bool)? {
        guard let value, value.isFinite, range.upperBound > range.lowerBound,
              range.lowerBound.isFinite, range.upperBound.isFinite else { return nil }
        let raw = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return (min(max(raw, 0), 1), raw < 0 || raw > 1)
    }
}

public struct TelosBezel: View {
    /// A typical-range band drawn as a faint arc inside the ticks.
    public struct Band: Equatable {
        public var range: ClosedRange<Double>
        public var color: Color
        public init(range: ClosedRange<Double>, color: Color) {
            self.range = range
            self.color = color
        }
    }

    private let value: Double?
    private let range: ClosedRange<Double>
    private let color: Color
    private let majorCount: Int
    private let minorPerMajor: Int
    private let startDegrees: Double
    private let spanDegrees: Double
    private let bands: [Band]
    private let target: Double?

    /// - Parameters:
    ///   - value: the reading on `range` (nil = absent: dashed ticks, no caret).
    ///   - range: the dial's scale (e.g. 0...3 for stress).
    ///   - color: the caret / band hue.
    ///   - majorCount / minorPerMajor: tick density (default 4 × 5 → 20 ticks).
    ///   - startDegrees / spanDegrees: -90 / 360 = a full dial from 12 o'clock; 150 / 240 = an open gauge.
    ///   - bands: typical-range arcs.
    ///   - target: an optional hollow target caret.
    public init(value: Double?,
                range: ClosedRange<Double>,
                color: Color = TelosColor.textPrimary,
                majorCount: Int = 4,
                minorPerMajor: Int = 5,
                startDegrees: Double = -90,
                spanDegrees: Double = 360,
                bands: [Band] = [],
                target: Double? = nil) {
        self.value = value
        self.range = range
        self.color = color
        self.majorCount = majorCount
        self.minorPerMajor = minorPerMajor
        self.startDegrees = startDegrees
        self.spanDegrees = spanDegrees
        self.bands = bands
        self.target = target
    }

    public var body: some View {
        let ticks = TelosBezelMath.ticks(majorCount: majorCount, minorPerMajor: minorPerMajor,
                                         startDegrees: startDegrees, spanDegrees: spanDegrees)
        let position = TelosBezelMath.position(of: value, in: range)
        let targetPosition = TelosBezelMath.position(of: target, in: range)
        Canvas { context, size in
            let d = min(size.width, size.height)
            guard d > 4 else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = d / 2 - 1
            func point(_ degrees: Double, _ r: CGFloat) -> CGPoint {
                let a = degrees * Double.pi / 180
                return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            }

            // Bands (typical ranges) — a faint arc just inside the ticks.
            for band in bands {
                guard let lo = TelosBezelMath.position(of: band.range.lowerBound, in: range),
                      let hi = TelosBezelMath.position(of: band.range.upperBound, in: range) else { continue }
                var arc = Path()
                arc.addArc(center: c, radius: outer - TelosStroke.majorTickLength - 3,
                           startAngle: .degrees(startDegrees + spanDegrees * lo.fraction),
                           endAngle: .degrees(startDegrees + spanDegrees * hi.fraction), clockwise: false)
                context.stroke(arc, with: .color(band.color.opacity(TelosOpacity.fill)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }

            // Ticks: minors in ONE path, majors in ONE path (two strokes per draw).
            var minor = Path()
            var major = Path()
            for tick in ticks {
                let length = tick.isMajor ? TelosStroke.majorTickLength : TelosStroke.minorTickLength
                if tick.isMajor {
                    major.move(to: point(tick.degrees, outer))
                    major.addLine(to: point(tick.degrees, outer - length))
                } else {
                    minor.move(to: point(tick.degrees, outer))
                    minor.addLine(to: point(tick.degrees, outer - length))
                }
            }
            let dash: [CGFloat] = position == nil ? [1, 1.5] : []
            context.stroke(minor, with: .color(TelosColor.lineStrong),
                           style: StrokeStyle(lineWidth: TelosStroke.hair, dash: dash))
            context.stroke(major, with: .color(TelosColor.textTertiary),
                           style: StrokeStyle(lineWidth: TelosStroke.line, dash: dash))

            // Target caret — hollow, secondary ink.
            if let targetPosition {
                let deg = startDegrees + spanDegrees * targetPosition.fraction
                var caret = Path()
                caret.move(to: point(deg, outer + 0.5))
                caret.addLine(to: point(deg, outer - 9))
                context.stroke(caret, with: .color(TelosColor.textSecondary),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                context.stroke(caret, with: .color(TelosColor.canvas),
                               style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }

            // Value caret — 2 × 8 pt, with a faint halo. Hollow + notch when beyond the scale.
            if let position {
                let deg = startDegrees + spanDegrees * position.fraction
                var caret = Path()
                caret.move(to: point(deg, outer + 0.5))
                caret.addLine(to: point(deg, outer - 8.5))
                context.stroke(caret, with: .color(color.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
                if position.outOfRange {
                    context.stroke(caret, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    context.stroke(caret, with: .color(TelosColor.canvas),
                                   style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                    let outward = position.fraction >= 1 ? 1.0 : -1.0
                    var notch = Path()
                    notch.move(to: point(deg, outer - 4))
                    notch.addLine(to: point(deg + outward * 5, outer - 4))
                    context.stroke(notch, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                } else {
                    context.stroke(caret, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("TelosBezel") {
    HStack(spacing: 24) {
        TelosBezel(value: 1.2, range: 0...3, color: TelosColor.stress, majorCount: 3, minorPerMajor: 5,
                   bands: [.init(range: 0.5...1.5, color: TelosColor.stress)])
            .frame(width: 120)
        TelosBezel(value: 3.4, range: 0...3, color: TelosColor.stress, majorCount: 3)
            .frame(width: 120)
        TelosBezel(value: nil, range: 0...100)
            .frame(width: 120)
    }
    .padding(32)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
