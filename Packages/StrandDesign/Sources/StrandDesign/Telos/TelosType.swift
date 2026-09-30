import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - TelosType — the Telos 2.0 type scale (docs/DESIGN_V2.md "VISUAL DIRECTION" + §4.2)
//
// THE VOICES (from the reference screens):
//   • LABELS are wide-tracked small caps — SF Pro semibold, UPPERCASE, +1.6 tracking ("REST",
//     "LEVEL", "TODAY'S MISSION"). `scale` / `label` / `labelLarge`, applied with `.telosScale()`.
//   • NUMBERS are large and LIGHT-to-regular SF Pro, tabular (`hero` medium 56, `numeralL` / `numeralM`
//     regular) — the instrument reads calm, not shouty.
//   • Prose is SF Pro. Timestamps, axis ticks and IDs stay SF Mono (`scaleNumber`).
//   • The wordmark is "T E L O S" in light SF Pro at +12 tracking with the "BIOLOGICAL OPTIMIZATION
//     ENGINE" subline (`TelosWordmark`). A ceremonial register (SF Pro Expanded) exists only on the
//     diagnostic screens and full-screen moments.
//
// How the tokens scale with Dynamic Type:
//   • Prose, labels and small numerals are native text-style fonts, so they resize live.
//   • The three big numerals (`hero` 56, `numeralL` 34, `numeralM` 24) have a size and a CAP. Their
//     live, capped form is the view modifier `.telosNumeral(.hero)` (an `@ScaledMetric`). The `Font`
//     properties of the same names are the SAME size resolved once at the moment of access (through
//     `UIFontMetrics` on iOS), for places that need a `Font` value. Prefer the modifier in views.
//   • Geometry-bound numerals (inside a ring / vessel) use `numeral(size:relativeTo:cap:)` so they can
//     never outgrow the gauge — at the cap the gauge grows or the layout switches (§2.4).
//
// Fixed-size faces (`scaleFixed`, the `glyph*` sizes) exist ONLY for chrome pinned to a fixed
// geometry (an 18 pt source badge, a 28 pt icon plate, a delta arrow). Never use them for prose.
//
// Absent data is `TelosType.absent` — U+2014 EM DASH, never "0", never an en dash (U+2013), never blank.

public enum TelosType {

    // MARK: Honesty glyphs

    /// The absent-value glyph: U+2014 EM DASH.
    public static let absent = "\u{2014}"
    /// True minus (U+2212) for signed deltas — a hyphen reads as a dash, not a sign.
    public static let minus = "\u{2212}"
    /// A unit follows its numeral at this fraction of the numeral size (minimum `minimumSize`).
    public static let unitScale: CGFloat = 0.55
    /// Minimum rendered size at default Dynamic Type (the level strip's 8–9 pt text goes).
    public static let minimumSize: CGFloat = 11

    // MARK: Numerals — SF Pro, light-to-regular, tabular

    /// 56 pt medium, scales with `.largeTitle`, capped at 1.3×. Resolved at access; prefer
    /// `.telosNumeral(.hero)` in views.
    public static var hero: Font { TelosNumeralStyle.hero.font }
    /// 34 pt regular, native `.largeTitle` (live). For the 1.4× cap use `.telosNumeral(.numeralL)`.
    public static let numeralL = Font.system(.largeTitle, design: .default, weight: .regular).monospacedDigit()
    /// 24 pt regular, scales with `.title2`, capped at 1.6×. Resolved at access; prefer
    /// `.telosNumeral(.numeralM)` in views.
    public static var numeralM: Font { TelosNumeralStyle.numeralM.font }
    /// 17 pt regular, native `.body`.
    public static let numeralS = Font.system(.body, design: .default, weight: .regular).monospacedDigit()
    /// 13 pt medium, native `.footnote`.
    public static let numeralXS = Font.system(.footnote, design: .default, weight: .medium).monospacedDigit()

    // MARK: Prose — SF Pro

    public static let title    = Font.system(.title, design: .default, weight: .bold)
    public static let title2   = Font.system(.title2, design: .default, weight: .semibold)
    public static let headline = Font.system(.headline, design: .default, weight: .semibold)
    public static let body     = Font.system(.body, design: .default, weight: .regular)
    public static let callout  = Font.system(.callout, design: .default, weight: .regular)
    public static let subhead  = Font.system(.subheadline, design: .default, weight: .regular)
    public static let footnote = Font.system(.footnote, design: .default, weight: .regular)
    public static let caption  = Font.system(.caption, design: .default, weight: .regular)

    // MARK: Qualifiers — SF Mono

    /// The LABEL voice: SF Pro semibold 12 (`.caption`), set UPPERCASE with `Tracking.scale` (+1.6) —
    /// the reference's wide-tracked small caps ("LEVEL", "TODAY'S MISSION"). The overline token.
    public static let scale = Font.system(.caption, design: .default, weight: .semibold)
    /// Alias of `scale`, for readers who look for "label".
    public static let label = scale
    /// The larger label under the hero rings ("REST", "CHARGE", "EFFORT"): SF Pro semibold 15
    /// (`.subheadline`), UPPERCASE, `Tracking.labelLarge`.
    public static let labelLarge = Font.system(.subheadline, design: .default, weight: .semibold)
    /// 11 pt mono regular, `.caption2`: axis ticks, timestamps, IDs, provenance.
    public static let scaleNumber = Font.system(.caption2, design: .monospaced, weight: .regular).monospacedDigit()

    // MARK: Ceremonial — SF Pro Expanded (diagnostic screens, full-screen moments)

    public static let diagnostic  = Font.system(.largeTitle, design: .default, weight: .black).width(.expanded)
    public static let diagnosticS = Font.system(.headline, design: .default, weight: .heavy).width(.expanded)

    // MARK: Fixed faces (fixed-geometry chrome only — never prose)

    /// The label voice at a fixed 11 pt, for chrome pinned to a fixed height (the 18 pt source badge).
    public static let scaleFixed = Font.system(size: 11, weight: .semibold, design: .default)
    /// The wordmark "T E L O S" (light, 20 pt, fixed: it is a logo).
    public static let wordmark = Font.system(size: 20, weight: .light, design: .default)
    /// The wordmark's subline (11 pt semibold, fixed; the 2.0 minimum size).
    public static let wordmarkSubline = Font.system(size: 11, weight: .semibold, design: .default)
    /// The delta arrow (9 pt).
    public static let glyphDelta = Font.system(size: 9, weight: .bold)
    /// Row / card chevrons (13 pt).
    public static let glyphChevron = Font.system(size: 13, weight: .semibold)
    /// The symbol inside a 28 pt row icon plate (15 pt).
    public static let glyphRow = Font.system(size: 15, weight: .medium)
    /// Field glyphs: search magnifier, clear button (16 pt).
    public static let glyphField = Font.system(size: 16, weight: .semibold)
    /// The empty-state symbol (20 pt).
    public static let glyphEmpty = Font.system(size: 20, weight: .regular)
    /// A 44 pt close / dismiss control's symbol (17 pt).
    public static let glyphControl = Font.system(size: 17, weight: .semibold)

    // MARK: Tracking

    public enum Tracking {
        public static let hero: CGFloat = -1.1
        public static let numeralL: CGFloat = -0.5
        public static let numeralM: CGFloat = -0.2
        /// The label / overline letter-spacing — wide-tracked small caps (1.x: 0.45).
        public static let scale: CGFloat = 1.6
        /// The large ring labels.
        public static let labelLarge: CGFloat = 2.4
        /// The wordmark's subline.
        public static let wordmarkSubline: CGFloat = 2.6
        public static let diagnostic: CGFloat = 0.5
        public static let diagnosticS: CGFloat = 1.0
        /// The TELOS wordmark.
        public static let wordmark: CGFloat = 12
    }

    // MARK: Builders

    /// A tabular SF Pro numeral at an exact point size (light-to-regular by default: the reference's
    /// calm large numbers). The one place a fixed-size numeral font is built, so call sites never spell
    /// `.system(size:)` themselves.
    public static func numeralFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: max(1, size), weight: weight, design: .default).monospacedDigit()
    }

    /// The unit that follows a numeral of `numeralSize`: mono medium at 0.55× (never below 11 pt).
    public static func unitFont(forNumeralSize numeralSize: CGFloat) -> Font {
        Font.system(size: max(minimumSize, numeralSize * unitScale), weight: .medium, design: .monospaced)
    }

    /// A geometry-bound numeral: `size` at the Large text size, scaled like `relativeTo`, clamped at
    /// `size × cap`. Resolved at the moment of the call (through `UIFontMetrics` on iOS; unscaled on
    /// macOS / watchOS, which have no app-controlled Dynamic Type here).
    public static func numeral(size: CGFloat,
                               relativeTo style: Font.TextStyle,
                               cap: CGFloat,
                               weight: Font.Weight = .regular) -> Font {
        numeralFont(size: scaledSize(size, relativeTo: style, cap: cap), weight: weight)
    }

    /// `size` scaled for the current content size category like `style`, never above `size × cap`
    /// and never below `size` × (the smallest Dynamic Type step's own ratio, which UIKit applies).
    public static func scaledSize(_ size: CGFloat, relativeTo style: Font.TextStyle, cap: CGFloat) -> CGFloat {
        #if os(iOS)
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(style))
        let scaled: CGFloat = metrics.scaledValue(for: size)
        return min(scaled, size * max(cap, 1))
        #else
        return size
        #endif
    }

    #if os(iOS)
    static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle:  return .largeTitle
        case .title:       return .title1
        case .title2:      return .title2
        case .title3:      return .title3
        case .headline:    return .headline
        case .subheadline: return .subheadline
        case .body:        return .body
        case .callout:     return .callout
        case .footnote:    return .footnote
        case .caption:     return .caption1
        case .caption2:    return .caption2
        default:           return .body
        }
    }
    #endif
}

// MARK: - Numeral styles (size + scaling + cap + tracking as one value)

/// A big-numeral style: base size at the Large text size, the text style it scales with, the cap,
/// weight and tracking. Apply with `.telosNumeral(_:)`.
public struct TelosNumeralStyle {
    public let size: CGFloat
    public let relativeTo: Font.TextStyle
    public let cap: CGFloat
    public let weight: Font.Weight
    public let tracking: CGFloat

    public init(size: CGFloat, relativeTo: Font.TextStyle, cap: CGFloat,
                weight: Font.Weight = .regular, tracking: CGFloat = 0) {
        self.size = size
        self.relativeTo = relativeTo
        self.cap = cap
        self.weight = weight
        self.tracking = tracking
    }

    public static let hero = TelosNumeralStyle(size: 56, relativeTo: .largeTitle, cap: 1.3,
                                               weight: .medium, tracking: TelosType.Tracking.hero)
    public static let numeralL = TelosNumeralStyle(size: 34, relativeTo: .largeTitle, cap: 1.4,
                                                   tracking: TelosType.Tracking.numeralL)
    public static let numeralM = TelosNumeralStyle(size: 24, relativeTo: .title2, cap: 1.6,
                                                   tracking: TelosType.Tracking.numeralM)
    /// A geometry-bound numeral (inside a vessel/ring). Scales like `.largeTitle` with the given cap.
    public static func geometryBound(size: CGFloat, cap: CGFloat) -> TelosNumeralStyle {
        TelosNumeralStyle(size: size, relativeTo: .largeTitle, cap: cap)
    }

    /// The style resolved once, now.
    public var font: Font {
        TelosType.numeral(size: size, relativeTo: relativeTo, cap: cap, weight: weight)
    }
}

/// Live, capped big-numeral font. `@ScaledMetric` re-renders the view when the text size changes.
private struct TelosNumeralModifier: ViewModifier {
    private let style: TelosNumeralStyle
    @ScaledMetric private var scaled: CGFloat

    init(style: TelosNumeralStyle) {
        self.style = style
        self._scaled = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let capped: CGFloat = min(scaled, style.size * max(style.cap, 1))
        return content
            .font(TelosType.numeralFont(size: capped, weight: style.weight))
            .tracking(style.tracking)
    }
}

public extension View {
    /// Apply a big-numeral style (`.hero`, `.numeralL`, `.numeralM`, or `.geometryBound(…)`): SF Pro,
    /// tabular, scaled with Dynamic Type up to the style's cap, with its tracking.
    func telosNumeral(_ style: TelosNumeralStyle) -> some View {
        modifier(TelosNumeralModifier(style: style))
    }
}

public extension Text {
    /// The label voice: SF Pro semibold 12 (`.caption`), +1.6 tracking. Returns `Text` so it can be
    /// concatenated; add `.textCase(.uppercase)` on the view for the overline form. The colour is left
    /// to the caller (overlines use `textTertiary` / `textSecondary`, tags use their tone).
    func telosScale() -> Text {
        self.font(TelosType.scale).tracking(TelosType.Tracking.scale)
    }
}
