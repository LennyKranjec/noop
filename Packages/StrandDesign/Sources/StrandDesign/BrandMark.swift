import SwiftUI

// MARK: - BrandMark — the Telos logo mark (Telos 2.0 bioluminescent re-skin; API unchanged)
//
// TELOS 2.0 (INS), restrained per decision 19: a near-black disc with the neutral glass hairline, a thin
// crisp open ring in the accent (no halo) and a flat core dot (no glow). Static; no clock.
//
// Original notes:
// The app's identity glyph, rendered natively for use as a hero on onboarding,
// "about", and empty states. Per the design handoff ("Engraved" app-icon
// direction + the brand glyph spec):
//
//   • a circular DEEP-NAVY tile (Circle filled with the navy ramp, a faint top
//     sheen, and a 1px hairline rim), over which sits
//   • an OPEN GOLD recovery ring — an ~80% arc starting at 12 o'clock (-90°) and
//     sweeping clockwise, stroked with the gold ramp and round-capped (a THICK
//     stroke to match the app icon), and
//   • a solid GOLD CORE DOT centred ("on-device core").
//
// Gold-on-navy, matching the app icon (the maintainer's brand direction, 2026-06-15).
//
// It reads as the "O" in NOOP and as a small echo of the hero recovery ring.
// CLEAN and flat by design: no bloom, no shadow, no glow — the titanium does the
// depth via its gradient + sheen, the gold ring does the accent. Everything is
// driven off a single `size`, so the mark stays crisp from a 28pt list avatar up
// to a 120pt onboarding hero.

public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    // The open ring sweeps ~80% of a full turn, starting at 12 o'clock and going clockwise — the same
    // orientation as the score rings, so the two read as one family.
    private let openFraction: Double = 0.80
    private var startAngle: Angle { .degrees(-90) }

    // Proportions derived from `size` so the mark is resolution-independent.
    private var ringInset: CGFloat { size * 0.20 }
    /// The luminous core stroke — thin, like every Telos ring.
    private var ringWidth: CGFloat { max(1.5, size * 0.065) }
    private var ringDiameter: CGFloat { size - ringInset * 2 }
    private var coreDiameter: CGFloat { size * 0.16 }
    private var rimWidth: CGFloat { max(1, size * 0.008) }

    public var body: some View {
        ZStack {
            groundDisc
            luminousRing
            core
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Telos"))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Ground disc

    /// The near-black ground with the neutral glass hairline. Flat — no depth glow (decision 19).
    private var groundDisc: some View {
        Circle()
            .fill(TelosColor.canvas)
            .overlay(Circle().strokeBorder(TelosColor.glassEdge, lineWidth: rimWidth))
    }

    // MARK: Luminous open ring

    /// The open ~80% arc: one crisp stroke (`telosLuminousStroke` no longer draws a halo).
    private var luminousRing: some View {
        RecoveryArc(
            startAngle: startAngle,
            spanDegrees: 360 * openFraction,
            fraction: 1,
            lineWidth: ringWidth
        )
        .telosLuminousStroke(TelosColor.mint, lineWidth: ringWidth, haloOpacity: 0.24)
        .frame(width: ringDiameter, height: ringDiameter)
    }

    // MARK: Core

    /// The "on-device core" — a flat dot at the exact centre (no glow halo, decision 19).
    private var core: some View {
        Circle().fill(TelosColor.textPrimary)
            .frame(width: coreDiameter, height: coreDiameter)
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(TelosColor.canvas)
    .preferredColorScheme(.dark)
}
#endif
