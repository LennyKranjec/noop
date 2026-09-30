import SwiftUI

// MARK: - BevelGauge — the open 240° gauge primitive, Telos 2.0 luminous look
//
// TELOS 2.0 (INS), restrained per decision 19: same geometry and public API; a thin track in the
// gauge's own hue and ONE crisp ramp arc — no halo stroke, no glowing tip, no tinted inner disc, no blur,
// no shadow — and light numerals. The arc still animates only via the caller's `animatedFraction`
// (callers settle it on a value change). Idle cost: zero.
//
// Original notes (geometry unchanged):
// The shared instrument behind RecoveryRing and StrainGauge: a 240° open gauge with
//   • a soft frosted inner disc (subtle radial fill, hairline rim)
//   • a faint full-span track ring carved from `surfaceInset` (the Titanium "well")
//   • a gradient-stroked progress arc (AngularGradient over the domain ramp:
//     Charge=green, Effort=blue, Rest=slate-blue — caller-supplied score tokens; WHOOP, no gold)
//   • a clean end-cap dot at the arc tip (small white core, very faint shadow) — NO outer bloom
//   • a centred SF Pro **Rounded** bold number with an "of N" caption + state word
//
// It owns no domain logic — callers pass the fraction, the stroke gradient, the tip
// colour, and the centre read-out strings. RecoveryRing / StrainGauge keep their own
// public init signatures and delegate their visuals here, so every screen re-skins
// without any call-site change.

public struct BevelGauge: View {

    /// Fill fraction 0...1 of the 240° span.
    public var fraction: Double
    /// Angular gradient stops for the progress arc (the domain ramp).
    public var stops: [Gradient.Stop]
    /// Colour of the glowing end-cap + state word (usually the ramp sampled at `fraction`).
    public var tipColor: Color
    /// Big centred number, already formatted (e.g. "87" or "12.4").
    public var numberText: String
    /// Small caption under the number (e.g. "of 100" / "of 21"). nil hides it.
    public var captionText: String?
    /// State word above/below the number (e.g. "PRIMED"). nil hides it.
    public var stateText: String?
    /// Optional supporting line under the read-out.
    public var supporting: String?
    public var diameter: CGFloat
    public var lineWidth: CGFloat
    public var showsLabel: Bool
    /// Animated draw-in fraction supplied by the caller (so it owns the @State + animation).
    public var animatedFraction: Double
    /// Whether the bloom is at full (vs resting) intensity — caller drives the breathe pulse.
    public var bloomActive: Bool

    public init(
        fraction: Double,
        stops: [Gradient.Stop],
        tipColor: Color,
        numberText: String,
        captionText: String? = nil,
        stateText: String? = nil,
        supporting: String? = nil,
        diameter: CGFloat = 200,
        lineWidth: CGFloat = 16,
        showsLabel: Bool = true,
        animatedFraction: Double,
        bloomActive: Bool = true
    ) {
        self.fraction = fraction
        self.stops = stops
        self.tipColor = tipColor
        self.numberText = numberText
        self.captionText = captionText
        self.stateText = stateText
        self.supporting = supporting
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.showsLabel = showsLabel
        self.animatedFraction = animatedFraction
        self.bloomActive = bloomActive
    }

    private let arcSpanDegrees: Double = 240
    private var startAngle: Angle { .degrees(150) }
    private var endAngle: Angle { .degrees(150 + arcSpanDegrees) }

    private var gradient: Gradient { Gradient(stops: stops) }
    /// The crisp arc is thinner than the footprint `lineWidth`.
    private var coreWidth: CGFloat { max(2, lineWidth * 0.55) }

    public var body: some View {
        ZStack {
            // STATIC BACKDROP: the frosted inner disc + the faint full-span track. Neither depends on
            // `animatedFraction`, so SwiftUI/CoreAnimation already caches it as an unchanged layer and
            // does NOT re-render it when only the arc animates. No .drawingGroup() — a per-instance
            // offscreen flatten cost more than it saved (it was part of the v7.0.2 lag regression).
            staticBackdrop
                .frame(width: diameter, height: diameter)

            // LIVE LAYER: the gradient progress arc + end-cap, kept OUTSIDE the drawingGroup so the
            // shape's `animatableData` still animates smoothly (a drawingGroup would freeze it).
            animatedArc

            if showsLabel { centerLabel }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The non-animating backdrop: the faint full-span track "well" (no tinted inner disc — decision 19).
    private var staticBackdrop: some View {
        // Thin full-span track in the gauge's own hue.
        arcShape(to: 1.0)
            .stroke(tipColor.opacity(TelosOpacity.fill),
                    style: StrokeStyle(lineWidth: coreWidth, lineCap: .round))
    }

    /// The live layer: ONE crisp ramp arc driven by `animatedFraction` — no halo, no glowing tip.
    private var animatedArc: some View {
        arcShape(to: animatedFraction)
            .stroke(
                AngularGradient(gradient: gradient, center: .center,
                                startAngle: startAngle, endAngle: endAngle),
                style: StrokeStyle(lineWidth: coreWidth, lineCap: .round)
            )
    }

    // Design Reset (WHOOP): NO outer bloom. Fill-contrast carries the arc edge, so the ring reads as a
    // clean, crisp Material instrument rather than a skeuomorphic glow. `bloomActive` stays in the
    // signature (callers still pass it) but no longer renders. The track lives in `staticBackdrop` and
    // the filled arc in `animatedArc` (see `body`); the glowing end-cap tip is gone (decision 19).

    private var centerLabel: some View {
        VStack(spacing: 2) {
            Text(numberText)
                .font(TelosType.numeralFont(size: diameter * 0.30, weight: .light))
                .foregroundStyle(StrandPalette.textPrimary)
                .contentTransition(.numericText())
            if let captionText {
                Text(captionText)
                    .font(TelosType.numeralFont(size: diameter * 0.085, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let stateText {
                // Scale the state word WITH the gauge, like the number (0.30·d) and caption (0.085·d).
                // `min(11, …)` pins it to the original 11pt overline on the large solo-hero rings (≥130pt)
                // — byte-identical there — and shrinks it on the small three-up rings, where a fixed 11pt
                // word overflowed the arc and collided with the number/caption. Uses a *scaled overline*
                // (not rounded()) so Dynamic-Type text-scaling is preserved. Thanks @claypilat (#403).
                let stateSize = min(11, diameter * 0.085)
                Text(stateText)
                    .font(StrandFont.overlineScaled(stateSize))
                    .tracking(StrandFont.overlineTracking * stateSize / 11)
                    .foregroundStyle(tipColor)
                    .padding(.top, 2)
            }
            if let supporting {
                Text(supporting)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: diameter * 0.78)
                    .padding(.top, 2)
            }
        }
    }

    private func arcShape(to fraction: Double) -> RecoveryArc {
        RecoveryArc(startAngle: startAngle, spanDegrees: arcSpanDegrees,
                    fraction: fraction, lineWidth: lineWidth)
    }
}

#if DEBUG
#Preview("BevelGauge") {
    HStack(spacing: 24) {
        BevelGauge(
            fraction: 0.78, stops: StrandPalette.recoveryStops,
            tipColor: StrandPalette.recoveryColor(78), numberText: "78",
            captionText: "of 100", stateText: "PRIMED",
            diameter: 200, animatedFraction: 0.78
        )
        BevelGauge(
            fraction: 0.55, stops: StrandPalette.strainStops,
            tipColor: StrandPalette.strainColor(55), numberText: "11.6",
            captionText: "of 21", stateText: "MODERATE",
            diameter: 200, animatedFraction: 0.55
        )
    }
    .padding(40)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
