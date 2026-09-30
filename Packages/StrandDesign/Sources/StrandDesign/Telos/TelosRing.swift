import SwiftUI

// MARK: - TelosRing — the thin luminous ring (docs/DESIGN_V2.md §5.6 "Ring", VISUAL DIRECTION)
//
// The reference's REST / CHARGE / EFFORT rings, the "87 % OPTIMAL" ring, the Training Coach "ZONE 2"
// ring and Mind & Focus: a thin track in the metric's own hue, a crisp thin progress arc from 12 o'clock
// clockwise, a light numeral in the centre and an optional caption word ("OPTIMAL") in the hue.
// Decision 19 (clinical restraint): no halo stroke and no glowing tip — the arc alone carries the value.
//
// HONEST OVERFLOW (coordinator decision 9). `scale` is ONE LAP, not a maximum: a value of 134 on a
// scale of 100 draws a completed first lap (dimmed) plus a second, brighter lap inset inside it to
// 34 %, with a lap tick at 12 o'clock — never an arc clipped at 100. Up to `TelosRingMath.maxDrawnLaps`
// laps are drawn as concentric arcs; past that the rings stay full and a "3.7×" lap label states the
// rest. The centre numeral is always the real value, unclamped.
//
// States: value · calibrating (dotted arc — visibly provisional) · carried (arc at half opacity) ·
// absent (dashed bare track + "—"; never a zero arc) · negative values draw no arc (a ring cannot show
// below zero) while the numeral still prints the real number.
//
// Cost (§2.1 rule 8): shapes only — no Canvas, no clock, no blur, no shadow, no halo (decision 19).
// The arc animates with `TelosMotion.settle` ONLY when the value
// changes (never on appear — §7.4), and instantly under Reduce Motion. Idle cost: zero.
// Watch-safe (plain shapes), so widgets and the watch can use it.

public enum TelosRingMath {

    /// The most concentric laps drawn before the lap label takes over.
    public static let maxDrawnLaps = 3

    /// `value / scale` as laps (1 = one full turn). nil for an absent or non-finite value or a
    /// non-positive / non-finite scale. Negative values are 0 laps (no arc; the numeral stays honest).
    /// NOT clamped above: 1.34 is 1.34 laps.
    public static func laps(value: Double?, scale: Double) -> Double? {
        guard let value, value.isFinite, scale.isFinite, scale > 0 else { return nil }
        return max(0, value / scale)
    }

    /// How much of lap `index` (0 = outermost) is filled for a total of `laps`: 0…1.
    public static func fraction(ofLap index: Int, laps: Double) -> Double {
        guard laps.isFinite else { return 0 }
        return min(max(laps - Double(index), 0), 1)
    }

    /// The fill of every DRAWN lap, outermost first: `[0.5]`, `[1]`, `[1, 0.34]`, `[1, 1]`, and at most
    /// `maxDrawn` entries (3.7 laps → `[1, 1, 1]` plus the lap label).
    public static func lapFractions(_ laps: Double, maxDrawn: Int = maxDrawnLaps) -> [Double] {
        let limit = max(1, maxDrawn)
        guard laps.isFinite, laps > 0 else { return [0] }
        let count = min(limit, max(1, Int(laps.rounded(.up))))
        return (0..<count).map { fraction(ofLap: $0, laps: laps) }
    }

    /// True when the value runs past one lap (the overflow is drawn, never clipped).
    public static func overflows(_ laps: Double) -> Bool {
        laps.isFinite && laps > 1 + 1e-9
    }

    /// True when there are more laps than are drawn — the lap label must say how many.
    public static func exceedsDrawnLaps(_ laps: Double, maxDrawn: Int = maxDrawnLaps) -> Bool {
        laps.isFinite && laps > Double(max(1, maxDrawn)) + 1e-9
    }

    /// The default ring stroke for a diameter: thin (≈ 5.5 % of d), 2…9 pt.
    public static func defaultLineWidth(diameter: CGFloat) -> CGFloat {
        min(max(diameter * 0.055, 2), 9)
    }

    /// Radial distance between two laps' centre lines.
    public static func lapStep(lineWidth: CGFloat) -> CGFloat {
        lineWidth * 1.9
    }

    /// Centre-line radius of lap `index` inside a square of side `diameter`. The outermost lap keeps a
    /// 1.3 × lineWidth margin (it once held a halo; kept so every ring's layout is unchanged).
    public static func radius(forLap index: Int, diameter: CGFloat, lineWidth: CGFloat) -> CGFloat {
        let outer = diameter / 2 - lineWidth * 1.3
        return max(0, outer - CGFloat(max(0, index)) * lapStep(lineWidth: lineWidth))
    }

    /// The angle (radians, 0 = 3 o'clock, clockwise in screen space) at `fraction` of a lap.
    public static func angle(atFraction fraction: Double) -> Double {
        (-90 + 360 * fraction) * Double.pi / 180
    }

    /// Where the arc of `laps` ends (its tip), in a square of side `diameter`.
    public static func tipPoint(laps: Double, diameter: CGFloat, lineWidth: CGFloat,
                                maxDrawn: Int = maxDrawnLaps) -> CGPoint {
        let drawn = lapFractions(laps, maxDrawn: maxDrawn)
        let index = drawn.count - 1
        let f = drawn[index]
        let r = radius(forLap: index, diameter: diameter, lineWidth: lineWidth)
        let a = angle(atFraction: f)
        return CGPoint(x: diameter / 2 + r * CGFloat(cos(a)), y: diameter / 2 + r * CGFloat(sin(a)))
    }
}

// MARK: - Shapes (animatable on `laps`)

/// One lap's arc. Animating `laps` animates every lap consistently (lap 2 only starts filling once
/// lap 1 is full), so an overflow reads as the arc winding on, not as a second arc popping in.
struct TelosLapArc: Shape {
    var laps: Double
    let lapIndex: Int
    let lineWidth: CGFloat

    var animatableData: Double {
        get { laps }
        set { laps = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let f = TelosRingMath.fraction(ofLap: lapIndex, laps: laps)
        guard f > 0.0005 else { return path }
        let d = min(rect.width, rect.height)
        let r = TelosRingMath.radius(forLap: lapIndex, diameter: d, lineWidth: lineWidth)
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f), clockwise: false)
        return path
    }
}

/// A dot at the end of the innermost drawn lap. No longer drawn by `TelosRing` (decision 19: no
/// glowing tip); kept for callers that mark an arc's end deliberately.
struct TelosRingTip: Shape {
    var laps: Double
    let lineWidth: CGFloat
    let dotDiameter: CGFloat

    var animatableData: Double {
        get { laps }
        set { laps = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard laps > 0.004 else { return path }
        let d = min(rect.width, rect.height)
        let p = TelosRingMath.tipPoint(laps: laps, diameter: d, lineWidth: lineWidth)
        let ox = rect.midX - d / 2, oy = rect.midY - d / 2
        let r = dotDiameter / 2
        path.addEllipse(in: CGRect(x: ox + p.x - r, y: oy + p.y - r, width: dotDiameter, height: dotDiameter))
        return path
    }
}

/// The bare track circle of lap 0.
struct TelosRingTrack: Shape {
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        let r = TelosRingMath.radius(forLap: 0, diameter: d, lineWidth: lineWidth)
        return Path(ellipseIn: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
    }
}

/// A short radial tick across the ring at `fraction` of a lap (the target caret / the lap tick).
struct TelosRingTick: Shape {
    let fraction: Double
    let lineWidth: CGFloat
    /// How far inward the tick reaches, in laps (1 = down to lap 2's centre line).
    let depthLaps: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let d = min(rect.width, rect.height)
        let outer = TelosRingMath.radius(forLap: 0, diameter: d, lineWidth: lineWidth) + lineWidth * 0.9
        let inner = TelosRingMath.radius(forLap: 0, diameter: d, lineWidth: lineWidth)
            - lineWidth * 0.9 - TelosRingMath.lapStep(lineWidth: lineWidth) * depthLaps
        let a = TelosRingMath.angle(atFraction: fraction)
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: c.x + outer * CGFloat(cos(a)), y: c.y + outer * CGFloat(sin(a))))
        path.addLine(to: CGPoint(x: c.x + max(0, inner) * CGFloat(cos(a)), y: c.y + max(0, inner) * CGFloat(sin(a))))
        return path
    }
}

// MARK: - The ring

public struct TelosRing: View {
    private let value: Double?
    private let scale: Double
    private let color: Color
    private let diameter: CGFloat
    private let lineWidth: CGFloat
    private let format: (Double) -> String
    private let unit: String?
    private let caption: Text?
    private let captionColor: Color?
    private let target: Double?
    private let confidence: TelosConfidence
    private let isCarried: Bool
    private let showsValue: Bool
    private let animatesChanges: Bool
    private let axLabel: Text?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    /// The laps currently drawn. nil until first appear (then set WITHOUT animation — no draw-in).
    @State private var shownLaps: Double? = nil

    /// - Parameters:
    ///   - value: the reading (nil / non-finite = absent: dashed bare track + "—").
    ///   - scale: the value that makes ONE lap (100 for a 0–100 score, 21 for WHOOP Effort; for the
    ///     unbounded Level, 100 = the wearer's own 95th percentile). Values beyond it draw more laps.
    ///   - color: the metric identity hue (track at 16 %, arc, caption).
    ///   - diameter: the ring's square frame.
    ///   - lineWidth: nil = `TelosRingMath.defaultLineWidth(diameter:)` (thin).
    ///   - format: the centre numeral (count-up on a NEW value only).
    ///   - unit: a small suffix after the numeral ("%"). Not localised — pass a symbol.
    ///   - caption: an optional word under the numeral ("OPTIMAL"), in `captionColor ?? color`.
    ///   - target: an optional target on the SAME scale, drawn as a hollow tick across the track.
    ///   - confidence: `.calibrating` draws a dotted (provisional) arc.
    ///   - isCarried: a value carried from an earlier day — arc at half opacity.
    ///   - showsValue: false = no centre content (the caller overlays its own).
    ///   - animatesChanges: false = a value change jumps (small static gauges in rows).
    ///   - accessibilityLabel: what VoiceOver names the ring (the value is read as its value).
    public init(value: Double?,
                scale: Double = 100,
                color: Color,
                diameter: CGFloat,
                lineWidth: CGFloat? = nil,
                format: @escaping (Double) -> String = TelosFormat.integer,
                unit: String? = nil,
                caption: Text? = nil,
                captionColor: Color? = nil,
                target: Double? = nil,
                confidence: TelosConfidence = .solid,
                isCarried: Bool = false,
                showsValue: Bool = true,
                animatesChanges: Bool = true,
                accessibilityLabel: Text? = nil) {
        self.value = value.flatMap { $0.isFinite ? $0 : nil }
        self.scale = scale
        self.color = color
        self.diameter = max(diameter, 1)
        self.lineWidth = lineWidth ?? TelosRingMath.defaultLineWidth(diameter: diameter)
        self.format = format
        self.unit = unit
        self.caption = caption
        self.captionColor = captionColor
        self.target = target
        self.confidence = confidence
        self.isCarried = isCarried
        self.showsValue = showsValue
        self.animatesChanges = animatesChanges
        self.axLabel = accessibilityLabel
    }

    private var targetLaps: Double? { TelosRingMath.laps(value: value, scale: scale) }

    public var body: some View {
        let laps = shownLaps ?? targetLaps ?? 0
        ZStack {
            rings(laps: laps)
            if showsValue { centre }
        }
        .frame(width: diameter, height: diameter)
        .onAppear { shownLaps = targetLaps ?? 0 }
        .onChangeCompat(of: targetLaps) { newLaps in
            let next = newLaps ?? 0
            // Reduce Motion / Low Power / quiet motion (§7.5): fills jump to value.
            if !animatesChanges || motion.poseStill(reduceMotion) || shownLaps == nil {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { shownLaps = next }
            } else {
                withAnimation(TelosMotion.settle) { shownLaps = next }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(axLabel ?? caption ?? Text(verbatim: ""))
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Rings

    @ViewBuilder
    private func rings(laps: Double) -> some View {
        let settledLaps = targetLaps ?? 0
        let drawnCount = TelosRingMath.lapFractions(max(settledLaps, laps)).count
        let calibrating: Bool = {
            if case .calibrating = confidence { return true }
            return false
        }()
        let arcOpacity: Double = isCarried ? 0.5 : 1
        let arcStyle = calibrating
            ? StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [0.001, lineWidth * 1.9])
            : StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            if targetLaps == nil {
                // Absent: a dashed bare track — visibly "no reading", never a zero arc.
                TelosRingTrack(lineWidth: lineWidth)
                    .stroke(TelosColor.lineStrong,
                            style: StrokeStyle(lineWidth: max(1, lineWidth * 0.35), dash: [2, 3]))
            } else {
                TelosRingTrack(lineWidth: lineWidth)
                    .stroke(color.opacity(TelosOpacity.fill), lineWidth: lineWidth)
                ForEach(0..<drawnCount, id: \.self) { index in
                    let isLast = index == drawnCount - 1
                    // Completed earlier laps dim so the live lap reads on top.
                    let lapOpacity = (isLast ? 1.0 : 0.5) * arcOpacity
                    // ONE crisp arc in the metric hue — no halo, no gradient sheen (decision 19).
                    TelosLapArc(laps: laps, lapIndex: index, lineWidth: lineWidth)
                        .stroke(color.opacity(lapOpacity), style: arcStyle)
                }
                if TelosRingMath.overflows(settledLaps) {
                    // The lap tick at 12 o'clock: the arc wrapped, it was not clipped.
                    TelosRingTick(fraction: 0, lineWidth: lineWidth,
                                  depthLaps: CGFloat(min(drawnCount - 1, TelosRingMath.maxDrawnLaps - 1)))
                        .stroke(TelosColor.textPrimary.opacity(0.7), lineWidth: 1)
                }
            }
            if let target, let targetFraction = TelosRingMath.laps(value: target, scale: scale) {
                TelosRingTick(fraction: targetFraction.truncatingRemainder(dividingBy: 1), lineWidth: lineWidth,
                              depthLaps: 0)
                    .stroke(TelosColor.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Centre

    private var numeralSize: CGFloat { diameter * 0.26 }

    @ViewBuilder
    private var centre: some View {
        VStack(spacing: max(1, diameter * 0.015)) {
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    TelosCountingNumeral(value: value, format: format)
                        .font(TelosType.numeralFont(size: numeralSize, weight: .light))
                        .foregroundStyle(isCarried ? TelosColor.textSecondary : TelosColor.textPrimary)
                    if let unit {
                        Text(verbatim: unit)
                            .font(TelosType.numeralFont(size: numeralSize * 0.55, weight: .light))
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            } else {
                Text(verbatim: TelosType.absent)
                    .font(TelosType.numeralFont(size: numeralSize, weight: .light))
                    .foregroundStyle(TelosColor.textTertiary)
            }
            if let caption {
                let size = min(11, max(8, diameter * 0.075))
                caption
                    .font(.system(size: size, weight: .semibold))
                    .tracking(size * 0.14)
                    .textCase(.uppercase)
                    .foregroundStyle(captionColor ?? color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if let laps = targetLaps, TelosRingMath.exceedsDrawnLaps(laps) {
                Text(verbatim: laps.formatted(.number.precision(.fractionLength(1))) + "\u{00D7}")
                    .font(TelosType.numeralFont(size: max(9, diameter * 0.07), weight: .medium))
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, lineWidth * 2.2)
        .frame(maxWidth: diameter - lineWidth * 4)
        .allowsHitTesting(false)
    }

    private var accessibilityValue: Text {
        guard let value else { return Text("No data", bundle: .module) }
        return Text(verbatim: format(value) + (unit ?? ""))
    }
}

#if DEBUG
#Preview("TelosRing") {
    VStack(spacing: 24) {
        HStack(spacing: 20) {
            TelosRing(value: 97, color: TelosColor.rest, diameter: 110, unit: "%", caption: Text(verbatim: "REST"))
            TelosRing(value: 88, color: TelosColor.charge, diameter: 110, unit: "%", caption: Text(verbatim: "CHARGE"))
            TelosRing(value: 67.7, color: TelosColor.effort, diameter: 110, format: TelosFormat.decimal(1),
                      target: 72)
        }
        HStack(spacing: 20) {
            TelosRing(value: 134, color: TelosColor.charge, diameter: 110, caption: Text(verbatim: "LEVEL"))
            TelosRing(value: nil, color: TelosColor.charge, diameter: 110, caption: Text(verbatim: "CHARGE"))
            TelosRing(value: 42, color: TelosColor.rest, diameter: 110,
                      confidence: .calibrating(done: 2, total: 4))
        }
    }
    .padding(32)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
