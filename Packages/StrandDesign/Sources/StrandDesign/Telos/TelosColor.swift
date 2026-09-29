import SwiftUI

// MARK: - TelosColor — the Telos 2.0 colour tokens (docs/DESIGN_V2.md §4.1)
//
// ONE SOURCE OF TRUTH FOR EVERY V2 COLOUR. Each token is declared twice, deliberately:
//
//   • `TelosColor.Spec.<token>` — the hex PAIR (dark / light) as plain strings. A dynamic SwiftUI
//     `Color` cannot be read back in a test, so the strings are what `TelosContrastTests` computes
//     WCAG ratios on and what `TelosTokenMappingTests` pins. Change a value HERE and the tests see it.
//   • `TelosColor.<token>` — the `Color` built from that pair, once (`static let`: a dynamic
//     provider is allocated per construction, so a computed token would allocate per access — §2.1
//     rule 6). Every other colour in the package (the legacy `StrandPalette` / `NoopVisualStyle`
//     names included) is a re-pointed alias of one of these, never a second copy of the hex.
//
// Usage rules (binding, §4.1):
//   • The accent is CHROME ONLY (links, toggles, selection, focus ring, primary button, live dot). It
//     never encodes data and never fills a data surface. `TelosColor.accent` follows the user's accent
//     choice (Settings ▸ Appearance); `TelosColor.mint` is the stored default value.
//   • Status colours (`positive` / `warning` / `critical`) are never used as metric identity.
//   • Metric identity: `<metric>` is the GRAPHIC fill (≥ 3:1 on `surface`), `<metric>Ink` is the TEXT
//     variant (≥ 4.5:1 on `surface`). In dark they are the same hex.
//   • Increase Contrast: use `tertiaryInk(for:)` / `lineInk(for:)` so `textTertiary → textSecondary`
//     and `line → lineStrong` when the wearer asks for more contrast.
//   • Data ramps (recovery / strain / sleep stages / HR zones / stress gradient / classic branches) are
//     NOT here — they are measurements, not chrome, and stay in `StrandPalette` unchanged.

public enum TelosColor {

    /// A dark / light hex pair. 6-digit `#RRGGBB`, or 8-digit `#RRGGBBAA` when the token carries its
    /// own opacity (precomputed so a call site never stacks `.opacity()` on a dynamic colour).
    public struct Pair: Hashable, Sendable {
        public let dark: String
        public let light: String
        public init(dark: String, light: String) {
            self.dark = dark
            self.light = light
        }
        /// A scheme-invariant pair (the same hex in both schemes).
        public static func fixed(_ hex: String) -> Pair { Pair(dark: hex, light: hex) }
    }

    // MARK: - The hex table (testable)

    public enum Spec {
        // Chrome
        public static let canvas        = Pair(dark: "#0B0E11", light: "#F3F4F1")
        public static let surface       = Pair(dark: "#13171B", light: "#FFFFFF")
        public static let surfaceRaised = Pair(dark: "#1A1F24", light: "#FFFFFF")
        public static let surfaceInset  = Pair(dark: "#0F1215", light: "#E9EBE7")
        public static let line          = Pair(dark: "#252B31", light: "#D8DBD5")
        public static let lineStrong    = Pair(dark: "#39414A", light: "#B3B9B2")
        public static let lineSoft      = Pair(dark: "#1B2025", light: "#E7E9E4")
        public static let textPrimary   = Pair(dark: "#F2F4F3", light: "#111416")
        public static let textSecondary = Pair(dark: "#A9B0B4", light: "#4A5156")
        public static let textTertiary  = Pair(dark: "#858D92", light: "#666D72")
        public static let textDisabled  = Pair(dark: "#4E555B", light: "#A5AAA6")
        // Text on a permanently dark surface (the over-sky title) — unchanged from 1.x.
        public static let onDarkPrimary   = Pair.fixed("#F4F6F8")
        public static let onDarkSecondary = Pair.fixed("#C8CFD8")
        public static let onDarkTertiary  = Pair.fixed("#8A94A4")

        // Accent (the mint default; WHOOP blue / custom stay in `AccentColor`)
        public static let mint        = Pair(dark: "#5FE0B5", light: "#0B7F63")
        public static let mintPressed = Pair(dark: "#8DEBCD", light: "#086A52")
        /// mint @ 0.16 (0x29 = 41/255 = 0.161).
        public static let mintMuted   = Pair(dark: "#5FE0B529", light: "#0B7F6329")
        public static let onAccent    = Pair(dark: "#062019", light: "#FFFFFF")

        // Status (default chart style; `ChartStyle.classic` keeps its own branches in StrandPalette)
        public static let positive     = Pair(dark: "#3FD68F", light: "#0A7F4F")
        public static let warning      = Pair(dark: "#F2B03D", light: "#9A6100")
        public static let critical     = Pair(dark: "#FF5A5F", light: "#C62A32")
        /// critical @ 0.10 dark (0x1A) / @ 0.07 light (0x12).
        public static let criticalWash = Pair(dark: "#FF5A5F1A", light: "#C62A3212")

        // Metric identity — fill, and the text ink (== fill in dark)
        public static let charge     = Pair(dark: "#03E095", light: "#0F9D62")
        public static let chargeInk  = Pair(dark: "#03E095", light: "#087F50")
        public static let effort     = Pair(dark: "#4090E0", light: "#2A78C8")
        public static let effortInk  = Pair(dark: "#4090E0", light: "#2468B0")
        public static let rest       = Pair(dark: "#9D9BF2", light: "#6663D6")
        public static let restInk    = Pair(dark: "#9D9BF2", light: "#6663D6")
        public static let restDeep   = Pair(dark: "#5B57C9", light: "#4A46B0")
        public static let restBright = Pair(dark: "#B9B7F7", light: "#6663D6")
        public static let stress     = Pair(dark: "#F0A020", light: "#C7891A")
        public static let stressInk  = Pair(dark: "#F0A020", light: "#8F5E00")
        public static let heart      = Pair(dark: "#FF6B81", light: "#D94C64")
        public static let heartInk   = Pair(dark: "#FF6B81", light: "#B8354D")
        public static let lungs      = Pair(dark: "#3FA9C9", light: "#1F7F9E")
        public static let lungsInk   = Pair(dark: "#3FA9C9", light: "#1F7F9E")
        public static let muscle     = Pair(dark: "#F08A4B", light: "#B5561C")
        public static let muscleInk  = Pair(dark: "#F08A4B", light: "#B5561C")
        public static let focus      = Pair(dark: "#C39BFF", light: "#7A4FD0")
        public static let focusInk   = Pair(dark: "#C39BFF", light: "#7A4FD0")
        /// "The only gold" — personal bests only. Graphic use (no text variant is specified).
        public static let bestGold   = Pair(dark: "#E5B84B", light: "#9A7310")

        // Diagnostic register (dark-only screens: morning flow, full-screen alerts, moments)
        public static let diagField = Pair.fixed("#000000")
        public static let diagCard  = Pair.fixed("#121214")
        public static let diagLine  = Pair.fixed("#2B2B2E")
        public static let diagText  = Pair.fixed("#FFFFFF")
        public static let diagMuted = Pair.fixed("#8C8C8C")
        /// The alarm colour on the diagnostic field = `critical`'s dark value.
        public static let diagAlarm = Pair.fixed("#FF5A5F")
    }

    // MARK: - Chrome

    public static let canvas        = Color(telos: Spec.canvas)
    public static let surface       = Color(telos: Spec.surface)
    public static let surfaceRaised = Color(telos: Spec.surfaceRaised)
    public static let surfaceInset  = Color(telos: Spec.surfaceInset)
    public static let line          = Color(telos: Spec.line)
    public static let lineStrong    = Color(telos: Spec.lineStrong)
    public static let lineSoft      = Color(telos: Spec.lineSoft)
    public static let textPrimary   = Color(telos: Spec.textPrimary)
    public static let textSecondary = Color(telos: Spec.textSecondary)
    public static let textTertiary  = Color(telos: Spec.textTertiary)
    /// Disabled labels only — never information (it is deliberately below 4.5:1).
    public static let textDisabled  = Color(telos: Spec.textDisabled)
    public static let onDarkPrimary   = Color(hex: Spec.onDarkPrimary.dark)
    public static let onDarkSecondary = Color(hex: Spec.onDarkSecondary.dark)
    public static let onDarkTertiary  = Color(hex: Spec.onDarkTertiary.dark)

    // MARK: - Accent

    /// The stored mint default (what `AccentColor.mint` resolves to).
    public static let mint        = Color(telos: Spec.mint)
    public static let mintPressed = Color(telos: Spec.mintPressed)
    public static let mintMuted   = Color(telos: Spec.mintMuted)
    /// Text / glyphs ON an accent fill (the primary button label).
    public static let onAccent    = Color(telos: Spec.onAccent)

    /// The wearer's chrome accent (mint / WHOOP blue / custom). A pass-through to the one place that
    /// knows the choice, so new code honours the setting without a second branch.
    public static var accent: Color { StrandPalette.accent }
    /// Pressed / hover variant of the wearer's accent.
    public static var accentPressed: Color { StrandPalette.accentHover }
    /// Muted accent fill (selected rows, chips).
    public static var accentMuted: Color { StrandPalette.accentMuted }

    // MARK: - Status

    public static let positive     = Color(telos: Spec.positive)
    public static let warning      = Color(telos: Spec.warning)
    public static let critical     = Color(telos: Spec.critical)
    /// The penalty block / alert-field wash. Precomputed alpha — do not add `.opacity()`.
    public static let criticalWash = Color(telos: Spec.criticalWash)

    // MARK: - Metric identity

    public static let charge     = Color(telos: Spec.charge)
    public static let chargeInk  = Color(telos: Spec.chargeInk)
    public static let effort     = Color(telos: Spec.effort)
    public static let effortInk  = Color(telos: Spec.effortInk)
    public static let rest       = Color(telos: Spec.rest)
    public static let restInk    = Color(telos: Spec.restInk)
    public static let restDeep   = Color(telos: Spec.restDeep)
    public static let restBright = Color(telos: Spec.restBright)
    public static let stress     = Color(telos: Spec.stress)
    public static let stressInk  = Color(telos: Spec.stressInk)
    public static let heart      = Color(telos: Spec.heart)
    public static let heartInk   = Color(telos: Spec.heartInk)
    public static let lungs      = Color(telos: Spec.lungs)
    public static let lungsInk   = Color(telos: Spec.lungsInk)
    public static let muscle     = Color(telos: Spec.muscle)
    public static let muscleInk  = Color(telos: Spec.muscleInk)
    public static let focus      = Color(telos: Spec.focus)
    public static let focusInk   = Color(telos: Spec.focusInk)
    public static let bestGold   = Color(telos: Spec.bestGold)

    // MARK: - Diagnostic register (scheme-invariant; render under a forced dark scheme)

    public static let diagField = Color(hex: Spec.diagField.dark)
    public static let diagCard  = Color(hex: Spec.diagCard.dark)
    public static let diagLine  = Color(hex: Spec.diagLine.dark)
    public static let diagText  = Color(hex: Spec.diagText.dark)
    public static let diagMuted = Color(hex: Spec.diagMuted.dark)
    public static let diagAlarm = Color(hex: Spec.diagAlarm.dark)
    /// The signal colour on the diagnostic field is the wearer's accent (was a private blue #2E75FF).
    public static var diagSignal: Color { StrandPalette.accent }

    // MARK: - Increase Contrast (§2.4)

    /// `textTertiary`, or `textSecondary` when the wearer asked for increased contrast.
    public static func tertiaryInk(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? textSecondary : textTertiary
    }

    /// `line`, or `lineStrong` when the wearer asked for increased contrast.
    public static func lineInk(for contrast: ColorSchemeContrast) -> Color {
        contrast == .increased ? lineStrong : line
    }
}

extension Color {
    /// Build a dynamic colour from a `TelosColor.Pair` (dark / light).
    init(telos pair: TelosColor.Pair) {
        self.init(light: pair.light, dark: pair.dark)
    }
}
