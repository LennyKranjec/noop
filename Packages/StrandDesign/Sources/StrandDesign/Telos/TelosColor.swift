import SwiftUI

// MARK: - TelosColor — the Telos 2.0 colour tokens (docs/DESIGN_V2.md "VISUAL DIRECTION" + §4.1)
//
// THE LOOK: organic, bioluminescent, alien. A near-black ground with a faint green-teal depth
// (`canvas` → `canvasDeep`), luminous accents (bioluminescent green, teal, effort blue, pale rest blue,
// violet / magenta for mind and sleep, amber / orange for fuel, sun-yellow warning), "futuristic
// transparent glass" tiles (a translucent white fill + a luminous gradient hairline + a faint top glow).
// The app is DARK-FIRST; light mode keeps the same hues deepened on a pale ground so text still passes.
//
// ONE SOURCE OF TRUTH FOR EVERY V2 COLOUR. Each token is declared twice, deliberately:
//   • `TelosColor.Spec.<token>` — the hex PAIR (dark / light) as plain strings. A dynamic SwiftUI
//     `Color` cannot be read back in a test, so the strings are what `TelosContrastTests` computes WCAG
//     ratios on (translucent tokens are composited over their ground) and what the mapping tests pin.
//   • `TelosColor.<token>` — the `Color` built from that pair ONCE (`static let`; a computed dynamic
//     colour allocates a provider per access — §2.1 rule 6). The legacy `StrandPalette` /
//     `NoopVisualStyle` names are aliases of these, never a second copy of a hex.
//
// Usage rules:
//   • Cards are GLASS: `glassFill` over the ground + the `glassEdge` hairline (bright top-leading) + a
//     `glassGlow` at the top edge (see `NoopPanelSurface`). `surface` / `surfaceRaised` are the OPAQUE
//     equivalents for places that must not be see-through (sheets, the tab-bar fallback, popovers).
//   • The accent (`TelosColor.accent`, default = the bioluminescent `mint`) is chrome: links, toggles,
//     selection, focus, the primary button, the glowing pill, the live dot.
//   • Metric identity: `<metric>` is the GRAPHIC colour (rings, arcs, particles, series), `<metric>Ink`
//     the TEXT variant. Status colours (`positive` / `warning` / `critical`) are for state words.
//   • Increase Contrast: `tertiaryInk(for:)` / `lineInk(for:)`.
//   • Data ramps (recovery / strain / sleep stages / HR zones / stress gradient / classic branches) are
//     NOT here — they are measurements and stay in `StrandPalette` unchanged.

public enum TelosColor {

    /// A dark / light hex pair. 6-digit `#RRGGBB`, or 8-digit `#RRGGBBAA` when the token carries its own
    /// opacity (precomputed so a call site never stacks `.opacity()` on a dynamic colour).
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
        // Ground
        /// The screen ground (near-black with a whisper of green-teal).
        public static let canvas        = Pair(dark: "#05090A", light: "#EEF3F1")
        /// The far end of the ground's depth gradient / vignette.
        public static let canvasDeep    = Pair(dark: "#0B1214", light: "#E7EEEB")

        // Glass (translucent — composited over the ground)
        /// THE card fill: white at ~8 % over the dark ground (0x14 = 20/255); near-opaque white in light.
        public static let glassFill     = Pair(dark: "#FFFFFF14", light: "#FFFFFFE0")
        /// A raised glass layer (selected segment, popover inner card): white at ~12 %.
        public static let glassRaised   = Pair(dark: "#FFFFFF1F", light: "#FFFFFFF5")
        /// The luminous top-leading end of the glass hairline (a green-white at 40 %).
        public static let glassEdgeHigh = Pair(dark: "#BFFFE666", light: "#FFFFFFFF")
        /// The dim bottom-trailing end of the glass hairline.
        public static let glassEdgeLow  = Pair(dark: "#FFFFFF0D", light: "#0B121424")
        /// The faint inner glow at a glass tile's top edge (bioluminescent green at 8 % / 4 %).
        public static let glassGlow     = Pair(dark: "#3CF0A014", light: "#3CF0A00A")

        // Opaque surfaces (the glass look's solid equivalents)
        public static let surface       = Pair(dark: "#131A1B", light: "#FFFFFF")
        public static let surfaceRaised = Pair(dark: "#1B2425", light: "#FFFFFF")
        public static let surfaceInset  = Pair(dark: "#030607", light: "#E4EBE8")

        // Lines
        public static let line          = Pair(dark: "#1E2B2C", light: "#D2DDD9")
        public static let lineStrong    = Pair(dark: "#2F4644", light: "#AEBDB8")
        public static let lineSoft      = Pair(dark: "#142021", light: "#E3EAE7")

        // Text (secondary ≈ 60 % of primary over the ground)
        public static let textPrimary   = Pair(dark: "#E8F2F0", light: "#0C1614")
        public static let textSecondary = Pair(dark: "#9AA8A5", light: "#43524F")
        public static let textTertiary  = Pair(dark: "#8C9C99", light: "#5C6B68")
        public static let textDisabled  = Pair(dark: "#4A5654", light: "#A6B0AD")
        // Text on a permanently dark surface (the over-sky title) — unchanged from 1.x.
        public static let onDarkPrimary   = Pair.fixed("#F4F6F8")
        public static let onDarkSecondary = Pair.fixed("#C8CFD8")
        public static let onDarkTertiary  = Pair.fixed("#8A94A4")

        // Accent — the bioluminescent green (the "Mint" accent choice)
        public static let mint        = Pair(dark: "#3CF0A0", light: "#067A52")
        public static let mintPressed = Pair(dark: "#7CF7C2", light: "#05603F")
        /// mint @ 0.16 (0x29 = 41/255).
        public static let mintMuted   = Pair(dark: "#3CF0A029", light: "#067A5229")
        /// The glow colour under luminous green elements (the reference's #2BD98B).
        public static let glow        = Pair(dark: "#2BD98B", light: "#0E8A57")
        public static let onAccent    = Pair(dark: "#03140C", light: "#FFFFFF")

        // Status
        public static let positive     = Pair(dark: "#3CF0A0", light: "#067A52")
        public static let warning      = Pair(dark: "#FFC94A", light: "#8A6100")
        public static let critical     = Pair(dark: "#FF6468", light: "#C62A32")
        /// critical @ 0.10 dark (0x1A) / @ 0.07 light (0x12).
        public static let criticalWash = Pair(dark: "#FF64681A", light: "#C62A3212")

        // Luminous hues (the reference palette), fill + text ink
        public static let teal       = Pair(dark: "#3FD6D0", light: "#0A7571")
        public static let violet     = Pair(dark: "#8B5CFF", light: "#6A3FE0")
        public static let violetInk  = Pair(dark: "#A583FF", light: "#6A3FE0")
        public static let magenta    = Pair(dark: "#C45CFF", light: "#9A2FCF")
        public static let magentaInk = Pair(dark: "#D07CFF", light: "#9A2FCF")
        public static let amber      = Pair(dark: "#FFB547", light: "#8F5E00")
        public static let orange     = Pair(dark: "#FF8A3D", light: "#AA4914")

        // Metric identity — fill, and the text ink
        public static let charge     = Pair(dark: "#3CF0A0", light: "#0E8A57")
        public static let chargeInk  = Pair(dark: "#3CF0A0", light: "#067A52")
        public static let effort     = Pair(dark: "#3A8DFF", light: "#1F63D6")
        public static let effortInk  = Pair(dark: "#5AA2FF", light: "#1F63D6")
        public static let rest       = Pair(dark: "#A9C8FF", light: "#3D5FAE")
        public static let restInk    = Pair(dark: "#A9C8FF", light: "#3D5FAE")
        public static let restDeep   = Pair(dark: "#6F93E8", light: "#2E4C96")
        public static let restBright = Pair(dark: "#CFE0FF", light: "#3D5FAE")
        public static let stress     = Pair(dark: "#FFB547", light: "#B07412")
        public static let stressInk  = Pair(dark: "#FFB547", light: "#8F5E00")
        public static let heart      = Pair(dark: "#FF6B81", light: "#D94C64")
        public static let heartInk   = Pair(dark: "#FF6B81", light: "#B8354D")
        public static let lungs      = Pair(dark: "#3FD6D0", light: "#0A7571")
        public static let lungsInk   = Pair(dark: "#3FD6D0", light: "#0A7571")
        public static let muscle     = Pair(dark: "#FF8A3D", light: "#AA4914")
        public static let muscleInk  = Pair(dark: "#FF8A3D", light: "#AA4914")
        public static let focus      = Pair(dark: "#8B5CFF", light: "#6A3FE0")
        public static let focusInk   = Pair(dark: "#A583FF", light: "#6A3FE0")
        /// "The only gold" — personal bests only.
        public static let bestGold   = Pair(dark: "#E5B84B", light: "#8A6608")

        // Diagnostic register (dark-only screens: morning flow, full-screen alerts, moments)
        public static let diagField = Pair.fixed("#000000")
        public static let diagCard  = Pair.fixed("#0B1214")
        public static let diagLine  = Pair.fixed("#1E2B2C")
        public static let diagText  = Pair.fixed("#FFFFFF")
        public static let diagMuted = Pair.fixed("#8C9896")
        /// The alarm colour on the diagnostic field = `critical`'s dark value.
        public static let diagAlarm = Pair.fixed("#FF6468")
    }

    // MARK: - Ground, glass, surfaces, lines, text

    public static let canvas        = Color(telos: Spec.canvas)
    public static let canvasDeep    = Color(telos: Spec.canvasDeep)
    public static let glassFill     = Color(telos: Spec.glassFill)
    public static let glassRaised   = Color(telos: Spec.glassRaised)
    public static let glassEdgeHigh = Color(telos: Spec.glassEdgeHigh)
    public static let glassEdgeLow  = Color(telos: Spec.glassEdgeLow)
    public static let glassGlow     = Color(telos: Spec.glassGlow)
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

    /// The luminous glass hairline: bright top-leading → dim bottom-trailing. Stored once.
    public static let glassEdge = LinearGradient(
        colors: [glassEdgeHigh, glassEdgeLow],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// The faint inner glow along a glass tile's top edge (fades out by ~35 % of the height). Stored once.
    public static let glassTopGlow = LinearGradient(
        colors: [glassGlow, Color.clear],
        startPoint: .top,
        endPoint: UnitPoint(x: 0.5, y: 0.35)
    )

    /// The screen ground with its depth: `canvas` at the top falling to `canvasDeep`. Static; stored once.
    public static let groundGradient = LinearGradient(
        colors: [canvas, canvasDeep],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Accent

    /// The stored bioluminescent-green default (what `AccentColor.mint` resolves to).
    public static let mint        = Color(telos: Spec.mint)
    public static let mintPressed = Color(telos: Spec.mintPressed)
    public static let mintMuted   = Color(telos: Spec.mintMuted)
    /// The glow under luminous green elements.
    public static let glow        = Color(telos: Spec.glow)
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

    // MARK: - Luminous hues

    public static let teal       = Color(telos: Spec.teal)
    public static let violet     = Color(telos: Spec.violet)
    public static let violetInk  = Color(telos: Spec.violetInk)
    public static let magenta    = Color(telos: Spec.magenta)
    public static let magentaInk = Color(telos: Spec.magentaInk)
    public static let amber      = Color(telos: Spec.amber)
    public static let orange     = Color(telos: Spec.orange)

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
    /// The signal colour on the diagnostic field is the wearer's accent.
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
