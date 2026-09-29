import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // Neutral, low-chroma surfaces sampled from the supplied dark-mode reference.
    public static let canvas = Color(light: "#F3F4F6", dark: "#1D1E23")
    public static let surface = Color(light: "#FFFFFF", dark: "#2A2C34")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#30323B")
    public static let surfaceBottom = Color(light: "#F4F5F7", dark: "#282A31")
    public static let inset = Color(light: "#E8E9ED", dark: "#23252C")

    public static let border = Color(light: "#D8DAE0", dark: "#373A44")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#4B4E59")
    public static let divider = Color(light: "#E4E5E9", dark: "#383A43")

    public static let primaryText = Color(light: "#17181C", dark: "#F7F7FA")
    public static let secondaryText = Color(light: "#555861", dark: "#C3C4CA")
    public static let tertiaryText = Color(light: "#7D808A", dark: "#7D7F88")

    public static let mint = Color(light: "#149A78", dark: "#69DDB8")
    public static let mintDeep = Color(light: "#0D765C", dark: "#13A982")
    public static let mintGlow = Color(light: "#38C99E", dark: "#54E6BD")

    public static let cardRadius: CGFloat = 22
    public static let compactRadius: CGFloat = 16
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26

    // MARK: Rim / hairline weights — ONE source for every filled-surface edge.
    //
    // The same top-lit rim used to be hand-tuned per component (a card at .72/.52 @0.8pt, the
    // segmented track at .48/1.0 @0.8pt, its selected pill at .62 @0.75pt), so two adjacent
    // surfaces drew visibly different edges at the same nominal "hairline". Every rim reads
    // these now, which is also the only place to retune the edge weight globally.

    /// Top stop of the top-lit rim gradient (the lit edge).
    public static let rimTopOpacity: Double = 0.72
    /// Bottom stop of the top-lit rim gradient (the shaded edge).
    public static let rimBottomOpacity: Double = 0.52
    /// Stroke width for a rim edge on a filled surface (card, control track, selected pill).
    public static let rimWidth: CGFloat = 0.8
    /// Faint interior separator / grid-line weight — below a full hairline, above invisible.
    /// Use `StrandPalette.hairlineSoft` rather than re-deriving this at a call site.
    public static let hairlineSoftOpacity: Double = 0.45

    // MARK: Tinted chip surfaces — the pills/badges/chips that borrow a hue.
    //
    // These were .12/.28 (StatePill), .12/.32 (ScoreStatePill), .16/.34 (SourceBadge) and
    // .14/none (TrendChip): four weights for one idea, visibly mismatched when two chips sit
    // in the same row. One fill + one border weight now, so a hue reads the same everywhere.

    /// Fill opacity for a hue-tinted chip surface.
    public static let chipFillOpacity: Double = 0.14
    /// Border opacity for a hue-tinted chip surface.
    public static let chipBorderOpacity: Double = 0.30

    /// The one top-lit rim: a lit top edge falling to a shaded bottom edge. Stroke it with
    /// `rimWidth`. Shared by the card surface, the segmented track and its selected pill so the
    /// light in the scene comes from a single direction at a single strength.
    public static var rimGradient: LinearGradient {
        LinearGradient(
            colors: [borderHighlight.opacity(rimTopOpacity), border.opacity(rimBottomOpacity)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The surface-elevation ladder. "How high does this sit" is a named level instead of a shadow
/// triple copied between components, so elevation stays ordered and consistent — and it fixes a
/// real asymmetry: light mode used to draw `resting` and `raised` with the *same* shadow, so an
/// elevated surface read flat on paper while it read lifted on dark.
///
/// Named `NoopSurfaceElevation`, not `NoopElevation`: `Appearance.swift` already holds a
/// file-private `NoopElevation` ViewModifier (behind the currently-unused `.noopElevation(hovering:)`)
/// and a same-named public type would silently shadow it inside that file.
public enum NoopSurfaceElevation: Sendable {
    /// No shadow at all — a surface flush with its parent.
    case flat
    /// The resting card/panel level.
    case resting
    /// A surface deliberately above its neighbours (sheets, floating chrome, active panels).
    case raised

    /// Blur radius of the cast shadow.
    public var radius: CGFloat {
        switch self {
        case .flat:    return 0
        case .resting: return 9
        case .raised:  return 18
        }
    }

    /// Vertical offset of the cast shadow (shadows always fall down — light comes from above).
    public var yOffset: CGFloat {
        switch self {
        case .flat:    return 0
        case .resting: return 5
        case .raised:  return 10
        }
    }

    /// Shadow opacity for the active appearance. Dark needs a deeper shadow to separate two
    /// near-black surfaces; light needs less, but still needs the two levels to *differ*.
    public func shadowOpacity(dark: Bool) -> Double {
        switch self {
        case .flat:    return 0
        case .resting: return dark ? 0.18 : 0.10
        case .raised:  return dark ? 0.34 : 0.14
        }
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
                    .strokeBorder(StrandPalette.focusRing, lineWidth: 2)
                    .opacity(isFocused ? 1 : 0)
                    .animation(reduceMotion ? nil : StrandMotion.interactive, value: isFocused)
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

/// Shared card/panel treatment: a quiet vertical gradient, a top-lit rim, and deep soft elevation.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    @Environment(\.colorScheme) private var scheme

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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.055), tint.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(shape.strokeBorder(NoopVisualStyle.rimGradient, lineWidth: NoopVisualStyle.rimWidth))
            .shadow(
                color: elevation.shadowColor(dark: scheme == .dark),
                radius: elevation.radius,
                x: 0,
                y: elevation.yOffset
            )
            .opacity(surfaceOpacity)
    }

    /// `elevated` is the long-standing public flag; the ladder is what it means.
    private var elevation: NoopSurfaceElevation { elevated ? .raised : .resting }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoopVisualStyle.divider)
                .frame(height: 0.5)
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
