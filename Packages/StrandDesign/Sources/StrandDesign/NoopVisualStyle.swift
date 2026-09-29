import SwiftUI

// MARK: - NOOP visual foundation (re-pointed to Telos 2.0)
//
// These are the 1.x token NAMES. Every screen still reads them, so in 2.0 they are ALIASES of the
// `Telos*` tokens (docs/DESIGN_V2.md §4, Appendix B): the unmodified app renders V2 surfaces, lines and
// text with no call-site edit. No name was removed or renamed. New and rewritten code uses `TelosColor` /
// `TelosSpace` / `TelosRadius` / `TelosStroke` / `TelosOpacity` / `TelosElevation` directly.
//
// V2 surfaces are FLAT: one fill + a 1 pt line, no gradient, no rim light, no shadow on anything in a
// scroll view. The old gradient/rim tokens stay compiled and now resolve to that flat look.

public enum NoopVisualStyle {
    // Surfaces — the gradient pair collapses to one flat `surface`.
    public static let canvas = TelosColor.canvas
    public static let surface = TelosColor.surface
    public static let surfaceTop = TelosColor.surface
    public static let surfaceBottom = TelosColor.surface
    public static let inset = TelosColor.surfaceInset

    public static let border = TelosColor.line
    public static let borderHighlight = TelosColor.lineStrong
    public static let divider = TelosColor.lineSoft

    public static let primaryText = TelosColor.textPrimary
    public static let secondaryText = TelosColor.textSecondary
    public static let tertiaryText = TelosColor.textTertiary

    // The mint accent family (#149A78 light failed AA on white; V2 mint is #0B7F63 / #5FE0B5).
    public static let mint = TelosColor.mint
    public static let mintDeep = TelosColor.mint
    public static let mintGlow = TelosColor.mintPressed

    public static let cardRadius: CGFloat = TelosRadius.card          // 22 → 20
    public static let compactRadius: CGFloat = TelosRadius.tile       // 16 → 14
    public static let pillRadius: CGFloat = TelosRadius.pill
    public static let pagePadding: CGFloat = TelosSpace.pageGutter    // 16
    public static let cardPadding: CGFloat = TelosSpace.cardPadding   // 16 → 12 (decision 11: hug content)
    public static let itemGap: CGFloat = TelosSpace.cardGap           // 12
    public static let sectionGap: CGFloat = TelosSpace.sectionGap     // 26 → 24

    // MARK: Rim / hairline weights — ONE source for every filled-surface edge.
    //
    // V2 has no top-lit rim: every edge is a flat 1 pt `line`. The opacity knobs stay (public API) at
    // 1.0 so any caller composing its own rim from them draws the flat line too.

    /// Top stop of the (retired) rim gradient — 1.0: the edge is flat.
    public static let rimTopOpacity: Double = 1.0
    /// Bottom stop of the (retired) rim gradient — 1.0: the edge is flat.
    public static let rimBottomOpacity: Double = 1.0
    /// Stroke width for a surface edge (card, control track, selected segment). 0.8 → 1.
    public static let rimWidth: CGFloat = TelosStroke.line
    /// Retired: `StrandPalette.hairlineSoft` is now the precomputed `TelosColor.lineSoft` (no opacity).
    public static let hairlineSoftOpacity: Double = 0.45

    // MARK: Tinted chip surfaces — the pills/badges/chips that borrow a hue.
    //
    // One fill + one border weight so a hue reads the same everywhere (`TelosOpacity.fill/border`).

    /// Fill opacity for a hue-tinted chip surface. 0.14 → 0.16.
    public static let chipFillOpacity: Double = TelosOpacity.fill
    /// Border opacity for a hue-tinted chip surface. 0.30 → 0.32.
    public static let chipBorderOpacity: Double = TelosOpacity.border

    /// The (retired) top-lit rim, now a FLAT `line` gradient (both stops equal) so every old call site
    /// strokes a plain 1 pt edge. Stored once rather than rebuilt per access.
    public static let rimGradient = LinearGradient(
        colors: [TelosColor.line, TelosColor.line],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// The surface-elevation ladder (1.x names, re-pointed to `TelosElevation`). `resting` — every card,
/// tile and row — is now FLAT: no shadow in either scheme (separation is fill + 1 pt line). `raised`
/// matches `TelosElevation.raised` (y 3, r 10, 0.30 / 0.10).
///
/// Named `NoopSurfaceElevation`, not `NoopElevation`: `Appearance.swift` already holds a
/// file-private `NoopElevation` ViewModifier (behind the currently-unused `.noopElevation(hovering:)`)
/// and a same-named public type would silently shadow it inside that file.
public enum NoopSurfaceElevation: Sendable {
    /// No shadow at all — a surface flush with its parent.
    case flat
    /// The resting card/panel level — flat in V2 (r 9 → 0).
    case resting
    /// A surface deliberately above its neighbours (popovers, floating chrome) — `TelosElevation.raised`.
    case raised

    /// The V2 elevation this level resolves to.
    public var telos: TelosElevation {
        switch self {
        case .flat, .resting: return .flat
        case .raised:         return .raised
        }
    }

    /// Blur radius of the cast shadow.
    public var radius: CGFloat { telos.radius }

    /// Vertical offset of the cast shadow (shadows always fall down — light comes from above).
    public var yOffset: CGFloat { telos.yOffset }

    /// Shadow opacity for the active appearance.
    public func shadowOpacity(dark: Bool) -> Double {
        telos.shadowOpacity(dark: dark)
    }

    /// The ready-made shadow colour for this level.
    public func shadowColor(dark: Bool) -> Color {
        .black.opacity(shadowOpacity(dark: dark))
    }
}

/// The house focus treatment: an accent ring on the control's own edge, drawn on top of whatever
/// fill or Liquid Glass the control already has. One modifier so a focused field looks the same
/// everywhere instead of each screen inventing a border swap — and so focus is never signalled by
/// colour alone (the ring is a shape change, visible to a user who cannot see the accent hue).
public struct NoopFocusRing: ViewModifier {
    public var isFocused: Bool
    public var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(isFocused: Bool, cornerRadius: CGFloat = NoopVisualStyle.compactRadius) {
        self.isFocused = isFocused
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            // `strokeBorder` insets by half the line width, so the ring stays inside the control's
            // own bounds and can never be clipped by a parent — and the width is constant (only the
            // opacity animates), so focusing never re-runs layout.
            //
            // The `.animation` sits INSIDE the overlay, not on `content` (the #104 lesson): an
            // animation node wrapping the content subtree re-animates whatever the control holds —
            // here, the text the user is typing — every time focus flips.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.focusRing, lineWidth: TelosStroke.focus)
                    .opacity(isFocused ? 1 : 0)
                    .animation(TelosMotion.animation(.select, reduced: reduceMotion), value: isFocused)
                    .allowsHitTesting(false)
            )
    }
}

public extension View {
    /// Draw the house focus ring when `isFocused`. Pass the control's own corner radius
    /// (`NoopVisualStyle.pillRadius` for a capsule) so the ring traces its real shape.
    func noopFocusRing(_ isFocused: Bool, cornerRadius: CGFloat = NoopVisualStyle.compactRadius) -> some View {
        modifier(NoopFocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

/// The shared card/panel surface, V2 (§5.1): ONE flat `surface` fill · a 1 pt `line` edge · no
/// gradient, no rim light, no wash. Cards cast NO shadow in either scheme; `elevated: true` (popovers,
/// floating chrome — never a card in a scroll view) uses `TelosElevation.raised`.
///
/// `tint` no longer washes the card: it draws only a 3 pt top edge in the tint at 0.6, so metric
/// identity marks a card without turning it into a coloured tile. `surfaceOpacity` multiplies the FILL
/// (the card-transparency setting); the edge stays fully drawn so the card never loses its outline.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double

    /// Height of the tint's top edge.
    static let tintEdgeHeight: CGFloat = 3
    /// Opacity of the tint's top edge.
    static let tintEdgeOpacity: Double = 0.6

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        if elevated {
            core.telosElevation(.raised)
        } else {
            core
        }
    }

    /// The flat surface. The tint edge (and the clip it needs) is only built when there IS a tint, so
    /// the common untinted card is exactly one fill and one stroke.
    @ViewBuilder private var core: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillOpacity: Double = min(max(surfaceOpacity, 0), 1)
        if let tint {
            shape
                .fill(TelosColor.surface.opacity(fillOpacity))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(tint.opacity(NoopPanelSurface.tintEdgeOpacity))
                        .frame(height: NoopPanelSurface.tintEdgeHeight)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
        } else {
            shape
                .fill(TelosColor.surface.opacity(fillOpacity))
                .overlay(shape.strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
        }
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers: a flat `surface` with a hairline
/// `line` divider at the bottom (the gradient ramp is retired).
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        TelosColor.surface
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TelosColor.line)
                    .frame(height: TelosStroke.hair)
            }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
