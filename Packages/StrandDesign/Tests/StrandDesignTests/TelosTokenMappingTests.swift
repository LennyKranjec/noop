import XCTest
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import StrandDesign

/// The 1.x token NAMES resolve to the Telos 2.0 values (docs/DESIGN_V2.md §4, Appendix B), so the
/// unmodified app renders V2. Three layers:
///   1. the hex table (`TelosColor.Spec`) holds exactly the §4.1 values;
///   2. every re-pointed legacy name IS the V2 token (same stored value — identity, not a lookalike);
///   3. where the platform can resolve a dynamic colour, the Color really renders the table's hex in
///      each scheme (proves the `Color(light:dark:)` plumbing, not just the table).
/// Plus the numeric tokens (radii, spacing, opacity, tracking, elevation), fonts and motion curves.
final class TelosTokenMappingTests: XCTestCase {

    private typealias Pair = TelosColor.Pair
    private typealias Spec = TelosColor.Spec

    private var savedChartStyle: ChartStyle = .titanium
    private var savedAccent: AccentColor = .mint

    override func setUp() {
        super.setUp()
        // Other suites flip these globals; the default (titanium chart style, mint accent) is what the
        // re-pointing is defined for.
        savedChartStyle = StrandPalette.chartStyle
        savedAccent = StrandPalette.accentChoice
        StrandPalette.chartStyle = .titanium
        StrandPalette.accentChoice = .mint
    }

    override func tearDown() {
        StrandPalette.chartStyle = savedChartStyle
        StrandPalette.accentChoice = savedAccent
        super.tearDown()
    }

    // MARK: 1. The table holds the §4.1 values

    func testChromeTableMatchesSpec() {
        XCTAssertEqual(Spec.canvas, Pair(dark: "#0B0E11", light: "#F3F4F1"))
        XCTAssertEqual(Spec.surface, Pair(dark: "#13171B", light: "#FFFFFF"))
        XCTAssertEqual(Spec.surfaceRaised, Pair(dark: "#1A1F24", light: "#FFFFFF"))
        XCTAssertEqual(Spec.surfaceInset, Pair(dark: "#0F1215", light: "#E9EBE7"))
        XCTAssertEqual(Spec.line, Pair(dark: "#252B31", light: "#D8DBD5"))
        XCTAssertEqual(Spec.lineStrong, Pair(dark: "#39414A", light: "#B3B9B2"))
        XCTAssertEqual(Spec.lineSoft, Pair(dark: "#1B2025", light: "#E7E9E4"))
        XCTAssertEqual(Spec.textPrimary, Pair(dark: "#F2F4F3", light: "#111416"))
        XCTAssertEqual(Spec.textSecondary, Pair(dark: "#A9B0B4", light: "#4A5156"))
        XCTAssertEqual(Spec.textTertiary, Pair(dark: "#858D92", light: "#666D72"))
        XCTAssertEqual(Spec.textDisabled, Pair(dark: "#4E555B", light: "#A5AAA6"))
        // onDark* are unchanged from 1.x.
        XCTAssertEqual(Spec.onDarkPrimary, Pair.fixed("#F4F6F8"))
        XCTAssertEqual(Spec.onDarkSecondary, Pair.fixed("#C8CFD8"))
        XCTAssertEqual(Spec.onDarkTertiary, Pair.fixed("#8A94A4"))
    }

    func testAccentAndStatusTableMatchesSpec() {
        XCTAssertEqual(Spec.mint, Pair(dark: "#5FE0B5", light: "#0B7F63"))
        XCTAssertEqual(Spec.mintPressed, Pair(dark: "#8DEBCD", light: "#086A52"))
        XCTAssertEqual(Spec.onAccent, Pair(dark: "#062019", light: "#FFFFFF"))
        XCTAssertEqual(Spec.positive, Pair(dark: "#3FD68F", light: "#0A7F4F"))
        XCTAssertEqual(Spec.warning, Pair(dark: "#F2B03D", light: "#9A6100"))
        XCTAssertEqual(Spec.critical, Pair(dark: "#FF5A5F", light: "#C62A32"))
        // Precomputed-alpha tokens: accent @ 0.16, critical @ 0.10 dark / 0.07 light.
        XCTAssertEqual(Color.sRGBComponents(hex: Spec.mintMuted.dark).a, 0.16, accuracy: 0.005)
        XCTAssertEqual(Color.sRGBComponents(hex: Spec.mintMuted.light).a, 0.16, accuracy: 0.005)
        XCTAssertEqual(Color.sRGBComponents(hex: Spec.criticalWash.dark).a, 0.10, accuracy: 0.005)
        XCTAssertEqual(Color.sRGBComponents(hex: Spec.criticalWash.light).a, 0.07, accuracy: 0.005)
        XCTAssertEqual(String(Spec.mintMuted.dark.prefix(7)), Spec.mint.dark)
        XCTAssertEqual(String(Spec.mintMuted.light.prefix(7)), Spec.mint.light)
        XCTAssertEqual(String(Spec.criticalWash.dark.prefix(7)), Spec.critical.dark)
        XCTAssertEqual(String(Spec.criticalWash.light.prefix(7)), Spec.critical.light)
    }

    func testMetricIdentityTableMatchesSpec() {
        XCTAssertEqual(Spec.charge, Pair(dark: "#03E095", light: "#0F9D62"))
        XCTAssertEqual(Spec.chargeInk, Pair(dark: "#03E095", light: "#087F50"))
        XCTAssertEqual(Spec.effort, Pair(dark: "#4090E0", light: "#2A78C8"))
        XCTAssertEqual(Spec.effortInk, Pair(dark: "#4090E0", light: "#2468B0"))
        XCTAssertEqual(Spec.rest, Pair(dark: "#9D9BF2", light: "#6663D6"))
        XCTAssertEqual(Spec.restInk, Pair(dark: "#9D9BF2", light: "#6663D6"))
        XCTAssertEqual(Spec.restDeep, Pair(dark: "#5B57C9", light: "#4A46B0"))
        XCTAssertEqual(Spec.restBright, Pair(dark: "#B9B7F7", light: "#6663D6"))
        XCTAssertEqual(Spec.stress, Pair(dark: "#F0A020", light: "#C7891A"))
        XCTAssertEqual(Spec.stressInk, Pair(dark: "#F0A020", light: "#8F5E00"))
        XCTAssertEqual(Spec.heart, Pair(dark: "#FF6B81", light: "#D94C64"))
        XCTAssertEqual(Spec.heartInk, Pair(dark: "#FF6B81", light: "#B8354D"))
        XCTAssertEqual(Spec.lungs, Pair(dark: "#3FA9C9", light: "#1F7F9E"))
        XCTAssertEqual(Spec.muscle, Pair(dark: "#F08A4B", light: "#B5561C"))
        XCTAssertEqual(Spec.focus, Pair(dark: "#C39BFF", light: "#7A4FD0"))
        XCTAssertEqual(Spec.bestGold, Pair(dark: "#E5B84B", light: "#9A7310"))
        // "…Ink equals the fill in dark".
        for (fill, ink) in [(Spec.charge, Spec.chargeInk), (Spec.effort, Spec.effortInk), (Spec.rest, Spec.restInk),
                            (Spec.stress, Spec.stressInk), (Spec.heart, Spec.heartInk), (Spec.lungs, Spec.lungsInk),
                            (Spec.muscle, Spec.muscleInk), (Spec.focus, Spec.focusInk)] {
            XCTAssertEqual(fill.dark, ink.dark)
        }
    }

    func testDiagnosticRegisterMatchesSpec() {
        XCTAssertEqual(Spec.diagField, Pair.fixed("#000000"))
        XCTAssertEqual(Spec.diagCard, Pair.fixed("#121214"))
        XCTAssertEqual(Spec.diagLine, Pair.fixed("#2B2B2E"))
        XCTAssertEqual(Spec.diagText, Pair.fixed("#FFFFFF"))
        XCTAssertEqual(Spec.diagMuted, Pair.fixed("#8C8C8C"))
        XCTAssertEqual(Spec.diagAlarm.dark, Spec.critical.dark)
    }

    // MARK: 2. Legacy names ARE the V2 tokens

    func testNoopVisualStyleResolvesToV2() {
        XCTAssertEqual(NoopVisualStyle.canvas, TelosColor.canvas)
        XCTAssertEqual(NoopVisualStyle.surface, TelosColor.surface)
        XCTAssertEqual(NoopVisualStyle.surfaceTop, TelosColor.surface)      // the gradient collapses to flat
        XCTAssertEqual(NoopVisualStyle.surfaceBottom, TelosColor.surface)
        XCTAssertEqual(NoopVisualStyle.inset, TelosColor.surfaceInset)
        XCTAssertEqual(NoopVisualStyle.border, TelosColor.line)
        XCTAssertEqual(NoopVisualStyle.borderHighlight, TelosColor.lineStrong)
        XCTAssertEqual(NoopVisualStyle.divider, TelosColor.lineSoft)
        XCTAssertEqual(NoopVisualStyle.primaryText, TelosColor.textPrimary)
        XCTAssertEqual(NoopVisualStyle.secondaryText, TelosColor.textSecondary)
        XCTAssertEqual(NoopVisualStyle.tertiaryText, TelosColor.textTertiary)
        XCTAssertEqual(NoopVisualStyle.mint, TelosColor.mint)
        XCTAssertEqual(NoopVisualStyle.mintDeep, TelosColor.mint)
        XCTAssertEqual(NoopVisualStyle.mintGlow, TelosColor.mintPressed)
    }

    func testStrandPaletteChromeResolvesToV2() {
        XCTAssertEqual(StrandPalette.surfaceBase, TelosColor.canvas)
        XCTAssertEqual(StrandPalette.surfaceRaised, TelosColor.surface)
        XCTAssertEqual(StrandPalette.surfaceOverlay, TelosColor.surfaceRaised)
        XCTAssertEqual(StrandPalette.surfaceInset, TelosColor.surfaceInset)
        XCTAssertEqual(StrandPalette.hairline, TelosColor.line)
        XCTAssertEqual(StrandPalette.hairlineStrong, TelosColor.lineStrong)
        XCTAssertEqual(StrandPalette.hairlineSoft, TelosColor.lineSoft)
        XCTAssertEqual(StrandPalette.textPrimary, TelosColor.textPrimary)
        XCTAssertEqual(StrandPalette.textSecondary, TelosColor.textSecondary)
        XCTAssertEqual(StrandPalette.textTertiary, TelosColor.textTertiary)
        XCTAssertEqual(StrandPalette.onDarkPrimary, TelosColor.onDarkPrimary)
        XCTAssertEqual(StrandPalette.heroFill, TelosColor.surface)
        XCTAssertEqual(StrandPalette.heroBorder, TelosColor.line)
        XCTAssertEqual(StrandPalette.cardFillTop, TelosColor.surface)
        XCTAssertEqual(StrandPalette.cardFillBottom, TelosColor.surface)
        XCTAssertEqual(StrandPalette.glowAmbient, Color.clear)
        XCTAssertEqual(StrandPalette.goldDeepText, TelosColor.onAccent)
        XCTAssertEqual(StrandPalette.liquidHeart, TelosColor.heart)
    }

    func testAccentResolvesToV2Mint() {
        XCTAssertEqual(AccentColor.mint.accent, TelosColor.mint)
        XCTAssertEqual(AccentColor.mint.accentHover, TelosColor.mintPressed)
        XCTAssertEqual(AccentColor.mint.accentMuted, TelosColor.mintMuted)
        XCTAssertEqual(StrandPalette.accent, TelosColor.mint)
        XCTAssertEqual(StrandPalette.focusRing, TelosColor.mint)
        XCTAssertEqual(TelosColor.accent, TelosColor.mint)     // pass-through follows the choice
        // The frozen parts of Appearance.swift.
        XCTAssertEqual(AccentColor.storageKey, "accent.color")
        XCTAssertEqual(AccentColor.customHexKey, "accent.customHex")
        XCTAssertEqual(AccentColor.allCases.map(\.rawValue), ["mint", "whoopBlue", "custom"])
    }

    func testStatusAndIdentityResolveToV2InTheDefaultStyle() {
        XCTAssertEqual(StrandPalette.statusPositive, TelosColor.positive)
        XCTAssertEqual(StrandPalette.statusWarning, TelosColor.warning)
        XCTAssertEqual(StrandPalette.statusCritical, TelosColor.critical)
        XCTAssertEqual(StrandPalette.metricCyan, TelosColor.lungs)
        XCTAssertEqual(StrandPalette.restColor, TelosColor.rest)
        XCTAssertEqual(StrandPalette.restLine, TelosColor.rest)
        XCTAssertEqual(StrandPalette.restGlow, TelosColor.rest)
        XCTAssertEqual(StrandPalette.restDeep, TelosColor.restDeep)
        XCTAssertEqual(StrandPalette.restBright, TelosColor.restBright)
        XCTAssertEqual(DomainTheme.rest.color, TelosColor.rest)
    }

    func testClassicStyleKeepsItsOwnBranches() {
        StrandPalette.chartStyle = .classic
        XCTAssertEqual(StrandPalette.statusPositive, StrandPalette.cStatusPositive)
        XCTAssertEqual(StrandPalette.statusCritical, StrandPalette.cStatusCritical)
        XCTAssertEqual(StrandPalette.metricCyan, StrandPalette.cMetricCyan)
        XCTAssertEqual(StrandPalette.restColor, StrandPalette.cRestColor)
        XCTAssertNotEqual(StrandPalette.statusPositive, TelosColor.positive)
    }

    // MARK: 3. The Colors really render the table (where the platform can resolve them)

    private func resolvedHex(_ color: Color, dark: Bool) -> String? {
        #if canImport(AppKit)
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        var out: String?
        appearance.performAsCurrentDrawingAppearance {
            // Bridge AND resolve inside the appearance, so a dynamic provider answers for this scheme.
            let ns = NSColor(color)
            if let rgb = ns.usingColorSpace(.sRGB) {
                out = String(format: "#%02X%02X%02X",
                             Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()),
                             Int((rgb.blueComponent * 255).rounded()))
            }
        }
        return out
        #elseif canImport(UIKit) && !os(watchOS)
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        #else
        return nil
        #endif
    }

    func testLegacyNamesRenderTheV2HexInBothSchemes() throws {
        let cases: [(String, Color, Pair)] = [
            ("StrandPalette.surfaceBase", StrandPalette.surfaceBase, Spec.canvas),
            ("StrandPalette.surfaceRaised", StrandPalette.surfaceRaised, Spec.surface),
            ("StrandPalette.surfaceOverlay", StrandPalette.surfaceOverlay, Spec.surfaceRaised),
            ("StrandPalette.hairline", StrandPalette.hairline, Spec.line),
            ("StrandPalette.textTertiary", StrandPalette.textTertiary, Spec.textTertiary),
            ("NoopVisualStyle.mint", NoopVisualStyle.mint, Spec.mint),
            ("StrandPalette.statusCritical", StrandPalette.statusCritical, Spec.critical),
            ("StrandPalette.restColor", StrandPalette.restColor, Spec.rest),
            ("StrandPalette.goldDeepText", StrandPalette.goldDeepText, Spec.onAccent),
        ]
        guard resolvedHex(TelosColor.canvas, dark: true) != nil else {
            throw XCTSkip("this platform cannot resolve a dynamic Color in a test")
        }
        for (name, color, pair) in cases {
            XCTAssertEqual(resolvedHex(color, dark: true), pair.dark, "\(name) (dark)")
            XCTAssertEqual(resolvedHex(color, dark: false), pair.light, "\(name) (light)")
        }
    }

    // MARK: Numbers, type and motion

    func testMetricTokensAreRepointed() {
        XCTAssertEqual(NoopVisualStyle.cardRadius, 20)          // 22 → 20
        XCTAssertEqual(NoopVisualStyle.compactRadius, 14)       // 16 → 14
        XCTAssertEqual(NoopVisualStyle.sectionGap, 24)          // 26 → 24
        XCTAssertEqual(NoopVisualStyle.pagePadding, 16)
        XCTAssertEqual(NoopVisualStyle.rimWidth, 1)             // 0.8 → 1
        XCTAssertEqual(NoopVisualStyle.chipFillOpacity, 0.16)   // 0.14 → 0.16
        XCTAssertEqual(NoopVisualStyle.chipBorderOpacity, 0.32) // 0.30 → 0.32
        XCTAssertEqual(NoopMetrics.cardRadius, TelosRadius.card)
        XCTAssertEqual(NoopMetrics.sectionGap, TelosSpace.sectionGap)
        XCTAssertEqual(NoopMetrics.tabBarClearance, TelosSpace.tabBarClearance)
        XCTAssertEqual(StrandPalette.disabledOpacity, TelosOpacity.disabled)
        XCTAssertEqual(TelosRadius.hero, 24)
        XCTAssertEqual(TelosRadius.control, 12)
        XCTAssertEqual(TelosRadius.segment, 9)
        XCTAssertEqual(TelosRadius.plate, 8)
        XCTAssertEqual([TelosSpace.xxs, TelosSpace.xs, TelosSpace.s, TelosSpace.m, TelosSpace.l,
                        TelosSpace.xl, TelosSpace.xxl, TelosSpace.xxxl], [2, 4, 8, 12, 16, 24, 32, 48])
        XCTAssertEqual(TelosStroke.gauge(diameter: 20), 4, accuracy: 1e-9)   // clamp(d × 0.08, 4, 12)
        XCTAssertEqual(TelosStroke.gauge(diameter: 100), 8, accuracy: 1e-9)
        XCTAssertEqual(TelosStroke.gauge(diameter: 400), 12, accuracy: 1e-9)
    }

    func testElevationLadder() {
        // Cards, tiles, rows: flat in both schemes.
        XCTAssertEqual(NoopSurfaceElevation.resting.radius, 0)
        XCTAssertEqual(NoopSurfaceElevation.resting.shadowOpacity(dark: true), 0)
        XCTAssertEqual(NoopSurfaceElevation.resting.shadowOpacity(dark: false), 0)
        XCTAssertEqual(NoopSurfaceElevation.raised.radius, 10)  // 18 → 10
        XCTAssertEqual(NoopSurfaceElevation.raised.yOffset, 3)
        XCTAssertEqual(NoopSurfaceElevation.raised.shadowOpacity(dark: true), 0.30)
        XCTAssertEqual(NoopSurfaceElevation.raised.shadowOpacity(dark: false), 0.10)
        XCTAssertEqual(TelosElevation.overlay.radius, 28)
        XCTAssertEqual(TelosElevation.overlay.yOffset, 10)
        XCTAssertEqual(TelosElevation.overlay.shadowOpacity(dark: true), 0.45)
        XCTAssertEqual(TelosElevation.overlay.shadowOpacity(dark: false), 0.16)
    }

    func testTypographyIsRepointed() {
        XCTAssertEqual(StrandFont.title1, TelosType.title)
        XCTAssertEqual(StrandFont.title2, TelosType.title2)
        XCTAssertEqual(StrandFont.headline, TelosType.headline)
        XCTAssertEqual(StrandFont.body, TelosType.body)
        XCTAssertEqual(StrandFont.subhead, TelosType.subhead)
        XCTAssertEqual(StrandFont.caption, TelosType.caption)
        XCTAssertEqual(StrandFont.footnote, TelosType.footnote)
        XCTAssertEqual(StrandFont.overline, TelosType.scale)
        XCTAssertEqual(StrandFont.bodyNumber, TelosType.numeralS)
        XCTAssertEqual(StrandFont.captionNumber, TelosType.numeralXS)
        XCTAssertEqual(StrandFont.overlineTracking, 0.8)        // 0.45 → 0.8
        // The honesty glyphs.
        XCTAssertEqual(TelosType.absent, "\u{2014}")
        XCTAssertEqual(TelosType.minus, "\u{2212}")
    }

    func testMotionIsRepointed() {
        XCTAssertEqual(StrandMotion.interactive, TelosMotion.select)
        XCTAssertEqual(StrandMotion.gentle, TelosMotion.settle)
        XCTAssertEqual(StrandMotion.hero, TelosMotion.flow)
        XCTAssertEqual(StrandMotion.drawIn, TelosMotion.flow)
        XCTAssertEqual(StrandMotion.fade, TelosMotion.fade)
        XCTAssertEqual(StrandMotion.pulse, TelosMotion.beat)
        XCTAssertEqual(StrandMotion.breathPeriod, 5.5)
        XCTAssertEqual(StrandMotion.durationStandard, 0.20)
        XCTAssertEqual(NoopMotion.screen, TelosMotion.screen)
        XCTAssertEqual(NoopMotion.card, TelosMotion.settle)
        XCTAssertEqual(NoopMotion.value, TelosMotion.settle)
        XCTAssertEqual(NoopMotion.stagger, 0.035)
        XCTAssertEqual(NoopButtonMetrics.pressedScale, 0.97)
        XCTAssertEqual(NoopButtonMetrics.pressedOpacity, 0.88)
    }

    func testReduceMotionAlternatives() {
        // Every token has an answer under Reduce Motion; only fades (and the press opacity) survive.
        for token in TelosMotion.Token.allCases {
            let reduced = TelosMotion.animation(token, reduced: true)
            switch token {
            case .fade, .screen, .press:
                XCTAssertNotNil(reduced, "\(token) keeps a fade / opacity under Reduce Motion")
            default:
                XCTAssertNil(reduced, "\(token) must be instant under Reduce Motion")
            }
            XCTAssertNotNil(TelosMotion.animation(token, reduced: false))
        }
        XCTAssertEqual(TelosMotion.animation(.screen, reduced: true), TelosMotion.fade)
        XCTAssertNil(TelosMotion.gated(TelosMotion.settle, reduced: true))
        XCTAssertNil(TelosMotion.liveLoop(poseStill: true))
        XCTAssertNotNil(TelosMotion.liveLoop(poseStill: false))
        // Stagger: 0.035 s steps for the first four items only.
        XCTAssertEqual(TelosMotion.staggerDelay(index: 0), 0)
        XCTAssertEqual(TelosMotion.staggerDelay(index: 3), 0.105, accuracy: 1e-9)
        XCTAssertEqual(TelosMotion.staggerDelay(index: 12), TelosMotion.staggerDelay(index: 3))
    }

    // MARK: Preferences keep their keys and semantics

    func testCardOpacityPreferenceKeepsItsKeyAndClamps() {
        XCTAssertEqual(CardAppearancePrefs.opacityKey, "noop.cardOpacityPercent")
        XCTAssertEqual(CardAppearancePrefs.defaultPercent, 100)
        XCTAssertEqual(TelosOpacity.cardOpacity(percent: 100), 1.0)
        XCTAssertEqual(TelosOpacity.cardOpacity(percent: 85), 0.85, accuracy: 1e-9)
        XCTAssertEqual(TelosOpacity.cardOpacity(percent: 0), 0.55)      // clamped so text holds
        XCTAssertEqual(TelosOpacity.cardOpacity(percent: 150), 1.0)
        XCTAssertEqual(TelosOpacity.clampCardOpacity(.nan), 1.0)
        var env = EnvironmentValues()
        XCTAssertEqual(env.telosCardOpacity, 1.0)                        // default: solid
        env.telosCardOpacity = 0.2
        XCTAssertEqual(env.telosCardOpacity, 0.55)
    }

    func testHapticPreferenceIsTheAppWideKey() {
        // Must equal `SystemHaptics.prefKey` in Strand/Screens/SystemHaptics.swift (app target, so it
        // cannot be referenced from here) — one switch governs both.
        XCTAssertEqual(TelosHaptics.preferenceKey, "haptics.appWide")
    }
}
