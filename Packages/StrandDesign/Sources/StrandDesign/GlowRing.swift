import SwiftUI

// MARK: - GlowRing — the thin luminous score ring (Telos 2.0, docs/DESIGN_V2.md §5.6 "Ring")
//
// The legacy initialiser (fraction / value / format / color / diameter / lineWidth) now draws the
// Telos instrument look (decision 19 — clinical restraint): a track in the metric hue at 16 %, ONE crisp
// thin arc in the metric hue (no halo, no glowing tip, no blur, no shadow) and a light centre numeral.
// Watch-safe (plain shapes). The type keeps its legacy name for source compatibility.
//
// `fraction` is still clamped to 0…1 here, because every existing caller passes a bounded 0–100 score
// already divided by its maximum. An UNBOUNDED value (the Level) must use `TelosRing`, which draws the
// overflow as further laps instead of clipping.
//
// Motion: the arc settles (`TelosMotion.settle`) only when the fraction CHANGES — never a draw-in on
// appear (§7.4) — and snaps under Reduce Motion. Idle cost: zero.

public struct GlowRing: View {

    /// Target fill, 0...1.
    public var fraction: Double
    /// The number shown in the centre.
    public var value: Double
    /// Formats the value into the centre string.
    public var format: (Double) -> String
    /// The arc colour (the metric identity hue).
    public var color: Color
    public var diameter: CGFloat
    /// The ring's footprint width. The crisp arc is drawn thinner inside it.
    public var lineWidth: CGFloat

    public init(fraction: Double, value: Double, format: @escaping (Double) -> String,
                color: Color, diameter: CGFloat, lineWidth: CGFloat) {
        self.fraction = fraction
        self.value = value
        self.format = format
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    /// The centre-number font for a ring of the given diameter — the light Telos numeral at
    /// `diameter * 0.34`. Exposed so an EMPTY / carried / "No data" ring (which doesn't draw a
    /// `GlowRing`) renders its centre text in the exact same size + weight as a filled ring.
    public static func centerFont(diameter: CGFloat) -> Font {
        TelosType.numeralFont(size: diameter * 0.34, weight: .light)
    }

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
    private var coreWidth: CGFloat { max(1.5, lineWidth * 0.6) }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(TelosOpacity.fill), lineWidth: coreWidth)
            // One crisp arc in the metric hue — no halo stroke, no glowing tip (decision 19).
            GlowRingArc(fraction: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: coreWidth, lineCap: .round))

            Text(format(value))
                .font(Self.centerFont(diameter: diameter))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .padding(.horizontal, lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .animation(motion.poseStill(reduceMotion) ? nil : TelosMotion.settle, value: clamped)
    }
}

/// The arc from 12 o'clock clockwise, on the frame's inscribed circle (the legacy geometry).
private struct GlowRingArc: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(max(fraction, 0), 1)
        guard f > 0.0005 else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        return p
    }
}

