import SwiftUI

// MARK: - TelosMetrics — space, radius, stroke, opacity, elevation (docs/DESIGN_V2.md §4.3–4.7)
//
// DENSITY (coordinator decision 11): nothing is bigger than what it shows. Inside cards the SMALLER
// steps are the default (`TelosSpace.m` 12 padding, `TelosSpace.s` 8 between elements); cards have no
// minimum height; one attribute is a compact tile (`TelosMetricTile`), never a full-width card.
//
// ELEVATION: everything in a scroll view is `flat` — cards, tiles, rows, chips and charts cast NO
// shadow in either scheme (separation comes from the translucent glass fill over the dark ground plus
// the luminous 1 pt glass edge). At most three shadowed views on screen, never one inside another
// (§2.1 rule 4); the glowing pill's single small shadow counts toward that.

// MARK: - Spacing (4-pt grid)

public enum TelosSpace {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let xxxl: CGFloat = 48

    /// Left/right page gutter on every screen, Today included (was 22 on Today).
    public static let pageGutter: CGFloat = l
    /// Card inner padding — the smaller step by default (decision 11; §4.3 said 16).
    public static let cardPadding: CGFloat = m
    /// Compact tile inner padding.
    public static let tilePadding: CGFloat = m
    /// Gap between cards and between tiles in a grid.
    public static let cardGap: CGFloat = m
    /// Gap between tiles inside a `TelosTileGrid`.
    public static let tileGap: CGFloat = s
    /// Gap between elements inside a card.
    public static let cardInner: CGFloat = s
    /// Gap between page sections.
    public static let sectionGap: CGFloat = xl
    /// Section header → its first card.
    public static let sectionHeaderGap: CGFloat = s
    /// List row vertical padding.
    public static let rowVertical: CGFloat = m
    /// List row minimum height.
    public static let rowMinHeight: CGFloat = 52
    /// Extra bottom scroll room so the last card clears the floating tab bar.
    public static let tabBarClearance: CGFloat = 76
    /// Minimum interactive hit target on every control (visuals may be smaller).
    public static let hitTarget: CGFloat = 44
}

// MARK: - Corner radii (all `.continuous`) — large and soft for the glass tiles (VISUAL DIRECTION: ~22–26)

public enum TelosRadius {
    public static let hero: CGFloat = 28
    public static let card: CGFloat = 24
    public static let tile: CGFloat = 20
    public static let control: CGFloat = 12
    public static let segment: CGFloat = 9
    public static let plate: CGFloat = 8
    /// Capsule. Use `Capsule(style: .continuous)` where possible; this is for APIs that take a radius.
    public static let pill: CGFloat = 999
}

// MARK: - Strokes

public enum TelosStroke {
    /// Chart grid, minor ticks.
    public static let hair: CGFloat = 0.5
    /// Card edge, dividers, track outline, major ticks.
    public static let line: CGFloat = 1
    /// Radar web, secondary series, whiskers.
    public static let strong: CGFloat = 1.5
    /// Primary chart series, interval line.
    public static let data: CGFloat = 2
    /// The one hero chart per screen.
    public static let dataHero: CGFloat = 2.5
    /// Focus ring.
    public static let focus: CGFloat = 2
    /// Penalty / alert leading rail.
    public static let rail: CGFloat = 3
    /// Tick lengths on bezels and scales.
    public static let minorTickLength: CGFloat = 3
    public static let majorTickLength: CGFloat = 6

    /// Ring / bezel arc width for a gauge of diameter `d`: clamp(d × 0.08, 4, 12).
    public static func gauge(diameter d: CGFloat) -> CGFloat {
        min(max(d * 0.08, 4), 12)
    }
}

// MARK: - Opacity

public enum TelosOpacity {
    public static let full: Double = 1
    public static let card: Double = 0.85
    public static let secondary: Double = 0.72
    public static let disabled: Double = 0.45
    public static let border: Double = 0.32
    public static let fill: Double = 0.16
    public static let wash: Double = 0.10
    public static let whisper: Double = 0.06

    /// The card-transparency setting is clamped to this range so text contrast holds (§4.7).
    public static let cardRange: ClosedRange<Double> = 0.55...1.0

    /// The stored card-opacity PERCENT (`CardAppearancePrefs.opacityKey`, 0–100, default 100) as the
    /// fill multiplier cards draw with, clamped to `cardRange`. The stored value is never rewritten.
    public static func cardOpacity(percent: Int) -> Double {
        let raw = Double(percent) / 100.0
        return min(max(raw, cardRange.lowerBound), cardRange.upperBound)
    }

    /// Clamp an already-fractional card opacity into `cardRange` (non-finite → fully opaque).
    public static func clampCardOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return cardRange.upperBound }
        return min(max(value, cardRange.lowerBound), cardRange.upperBound)
    }
}

// MARK: - Elevation

/// How high a surface sits. `flat` is the default for everything in a scroll view.
public enum TelosElevation: Sendable {
    /// No shadow: cards, tiles, rows, chips, charts.
    case flat
    /// Radar plate, popover, floating stress pill, pull-refresh vessel. y 3, r 10, 0.30 / 0.10.
    case raised
    /// Modal cards (quest failure card, alert card). y 10, r 28, 0.45 / 0.16.
    case overlay

    public var yOffset: CGFloat {
        switch self {
        case .flat:    return 0
        case .raised:  return 3
        case .overlay: return 10
        }
    }

    public var radius: CGFloat {
        switch self {
        case .flat:    return 0
        case .raised:  return 10
        case .overlay: return 28
        }
    }

    /// Black shadow opacity per scheme (the numbers the colours below are built from).
    public func shadowOpacity(dark: Bool) -> Double {
        switch self {
        case .flat:    return 0
        case .raised:  return dark ? 0.30 : 0.10
        case .overlay: return dark ? 0.45 : 0.16
        }
    }

    /// The shadow colour as ONE dynamic token (no `@Environment(\.colorScheme)` read per view).
    public var shadowColor: Color {
        switch self {
        case .flat:    return .clear
        case .raised:  return TelosElevation.raisedShadow
        case .overlay: return TelosElevation.overlayShadow
        }
    }

    // 0.30 → 0x4D, 0.10 → 0x1A, 0.45 → 0x73, 0.16 → 0x29.
    static let raisedShadow = Color(light: "#0000001A", dark: "#0000004D")
    static let overlayShadow = Color(light: "#00000029", dark: "#00000073")
}

public extension View {
    /// Apply an elevation. `.flat` adds no modifier at all (not a zero-radius shadow).
    @ViewBuilder
    func telosElevation(_ elevation: TelosElevation) -> some View {
        if elevation == .flat {
            self
        } else {
            self.shadow(color: elevation.shadowColor, radius: elevation.radius, x: 0, y: elevation.yOffset)
        }
    }
}
