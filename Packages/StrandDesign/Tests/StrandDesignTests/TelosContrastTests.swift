import XCTest
import SwiftUI
@testable import StrandDesign

/// WCAG contrast for every text / fill pair of the Telos 2.0 colour table (docs/DESIGN_V2.md §4.1),
/// against the surfaces each is drawn on, in BOTH schemes (§2.4: text ≥ 4.5:1, non-text UI ≥ 3:1).
///
/// Computed on the hex strings in `TelosColor.Spec` — a dynamic SwiftUI `Color` cannot be read back —
/// so this is pure and deterministic. It sweeps the WHOLE matrix and compares the set of failing pairs
/// with `knownGaps`: a NEW failure fails the suite, and so does a known gap that has been fixed (so the
/// list is never stale). Each known gap is also held to a floor so it can never quietly get worse.
final class TelosContrastTests: XCTestCase {

    private typealias Pair = TelosColor.Pair
    private typealias Spec = TelosColor.Spec

    private enum Scheme: String, CaseIterable {
        case dark, light
    }

    private func hex(_ pair: Pair, _ scheme: Scheme) -> String {
        scheme == .dark ? pair.dark : pair.light
    }

    // MARK: WCAG maths (sRGB relative luminance; 8-digit hex is composited over its background)

    private func linear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func luminance(r: Double, g: Double, b: Double) -> Double {
        0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// `fg` composited over the opaque `bg` (sRGB "over"), as rendered.
    private func composite(_ fg: String, over bg: String) -> (r: Double, g: Double, b: Double) {
        let f = Color.sRGBComponents(hex: fg)
        let k = Color.sRGBComponents(hex: bg)
        return (f.r * f.a + k.r * (1 - f.a),
                f.g * f.a + k.g * (1 - f.a),
                f.b * f.a + k.b * (1 - f.a))
    }

    private func ratio(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
        let la = luminance(r: a.r, g: a.g, b: a.b)
        let lb = luminance(r: b.r, g: b.g, b: b.b)
        let hi = max(la, lb)
        let lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// Contrast of `fg` drawn on `bg` (fg may carry alpha; bg is treated as opaque).
    private func contrast(_ fg: String, on bg: String) -> Double {
        let back = Color.sRGBComponents(hex: bg)
        return ratio(composite(fg, over: bg), (back.r, back.g, back.b))
    }

    // MARK: The matrix

    private struct Check {
        let id: String
        let fg: String
        let bg: String
        let minimum: Double
    }

    private let textMinimum = 4.5
    private let graphicMinimum = 3.0

    private let cardSurfaces: [(String, Pair)] = [
        ("canvas", Spec.canvas), ("surface", Spec.surface), ("surfaceRaised", Spec.surfaceRaised),
    ]

    /// Every token that is used AS TEXT on a card or the canvas.
    private let textTokens: [(String, Pair)] = [
        ("textPrimary", Spec.textPrimary), ("textSecondary", Spec.textSecondary),
        ("textTertiary", Spec.textTertiary), ("mint", Spec.mint),
        ("positive", Spec.positive), ("warning", Spec.warning), ("critical", Spec.critical),
        ("chargeInk", Spec.chargeInk), ("effortInk", Spec.effortInk), ("restInk", Spec.restInk),
        ("stressInk", Spec.stressInk), ("heartInk", Spec.heartInk), ("lungsInk", Spec.lungsInk),
        ("muscleInk", Spec.muscleInk), ("focusInk", Spec.focusInk),
    ]

    /// Every token that is used as a GRAPHIC (arc, fill, series, dot, focus ring) on a card.
    private let graphicTokens: [(String, Pair)] = [
        ("charge", Spec.charge), ("effort", Spec.effort), ("rest", Spec.rest), ("stress", Spec.stress),
        ("heart", Spec.heart), ("lungs", Spec.lungs), ("muscle", Spec.muscle), ("focus", Spec.focus),
        ("bestGold", Spec.bestGold), ("mint", Spec.mint), ("positive", Spec.positive),
        ("warning", Spec.warning), ("critical", Spec.critical),
    ]

    private func matrix() -> [Check] {
        var checks: [Check] = []
        for scheme in Scheme.allCases {
            let s = scheme.rawValue
            // Text on the canvas and on cards.
            for (name, token) in textTokens {
                for (bgName, bg) in cardSurfaces {
                    checks.append(Check(id: "\(name)/\(bgName)/\(s)", fg: hex(token, scheme),
                                        bg: hex(bg, scheme), minimum: textMinimum))
                }
            }
            // Text inside wells: field text and unselected segment labels.
            for (name, token) in [("textPrimary", Spec.textPrimary), ("textSecondary", Spec.textSecondary)] {
                checks.append(Check(id: "\(name)/surfaceInset/\(s)", fg: hex(token, scheme),
                                    bg: hex(Spec.surfaceInset, scheme), minimum: textMinimum))
            }
            // The primary button label on the accent (rest and pressed).
            for (bgName, bg) in [("mint", Spec.mint), ("mintPressed", Spec.mintPressed)] {
                checks.append(Check(id: "onAccent/\(bgName)/\(s)", fg: hex(Spec.onAccent, scheme),
                                    bg: hex(bg, scheme), minimum: textMinimum))
            }
            // A selected TelosChip: canvas-coloured text on a textPrimary fill.
            checks.append(Check(id: "canvas/textPrimary/\(s)", fg: hex(Spec.canvas, scheme),
                                bg: hex(Spec.textPrimary, scheme), minimum: textMinimum))
            // Graphics on cards.
            for (name, token) in graphicTokens {
                for (bgName, bg) in [("surface", Spec.surface), ("surfaceRaised", Spec.surfaceRaised)] {
                    checks.append(Check(id: "\(name)-graphic/\(bgName)/\(s)", fg: hex(token, scheme),
                                        bg: hex(bg, scheme), minimum: graphicMinimum))
                }
            }
        }
        // The diagnostic register is dark-only (scheme-invariant hex).
        let fields: [(String, Pair)] = [("diagField", Spec.diagField), ("diagCard", Spec.diagCard)]
        let diagInks: [(String, Pair)] = [("diagText", Spec.diagText), ("diagMuted", Spec.diagMuted),
                                          ("diagAlarm", Spec.diagAlarm)]
        for (bgName, bg) in fields {
            for (name, ink) in diagInks {
                checks.append(Check(id: "\(name)/\(bgName)/diag", fg: ink.dark, bg: bg.dark, minimum: textMinimum))
            }
            // The signal colour on the diagnostic field is the accent's dark value.
            checks.append(Check(id: "mint/\(bgName)/diag", fg: Spec.mint.dark, bg: bg.dark, minimum: textMinimum))
        }
        return checks
    }

    /// Pairs the §4.1 table itself leaves below its minimum, each with where it may NOT be used. A value
    /// is the floor the pair must still clear (so a gap can never widen unnoticed). Resolving one of these
    /// is a spec change for the coordinator — the table's exact values are binding for P1.
    private let knownGaps: [String: (floor: Double, reason: String)] = [
        "mint/canvas/light": (4.45, "4.497:1 — accent TEXT sits on cards; section-header text buttons on the light canvas are 0.003 short"),
        "restInk/canvas/light": (4.35, "4.40:1 — metric inks are for numerals on cards, not on the bare canvas"),
        "lungsInk/canvas/light": (4.10, "4.15:1 — as above (the level strip's lever labels on the canvas must use textSecondary in light)"),
        "muscleInk/canvas/light": (4.35, "4.41:1 — as above"),
        "stress-graphic/surface/light": (2.95, "2.99:1 — stress fill is 'unchanged' in §4.1 and misses the 3:1 non-text rule by 0.01"),
        "stress-graphic/surfaceRaised/light": (2.95, "2.99:1 — as above"),
    ]

    // MARK: Tests

    func testContrastMetricMatchesKnownValues() {
        XCTAssertEqual(contrast("#FFFFFF", on: "#000000"), 21.0, accuracy: 0.01)
        XCTAssertEqual(contrast("#777777", on: "#777777"), 1.0, accuracy: 0.0001)
        // Alpha composites: a 50 % white over black is mid-grey, not white.
        XCTAssertLessThan(contrast("#FFFFFF80", on: "#000000"), 21.0)
    }

    /// The two failures the spec names (§2.4) are fixed by the re-pointed values.
    func testTheTwoNamedFailuresAreFixed() {
        // 1.x tertiary text on the 1.x dark card, and the 1.x light mint on white: both under AA.
        XCTAssertLessThan(contrast("#7D7F88", on: "#2A2C34"), 4.5)
        XCTAssertLessThan(contrast("#149A78", on: "#FFFFFF"), 4.5)
        // V2 values on the V2 cards, both schemes.
        for scheme in Scheme.allCases {
            XCTAssertGreaterThanOrEqual(contrast(hex(Spec.textTertiary, scheme), on: hex(Spec.surface, scheme)), 4.5,
                                        "textTertiary on surface (\(scheme))")
            XCTAssertGreaterThanOrEqual(contrast(hex(Spec.mint, scheme), on: hex(Spec.surface, scheme)), 4.5,
                                        "mint on surface (\(scheme))")
        }
        // And the legacy names really resolve to them.
        XCTAssertEqual(NoopVisualStyle.tertiaryText, TelosColor.textTertiary)
        XCTAssertEqual(AccentColor.mint.accent, TelosColor.mint)
    }

    /// The whole matrix: every failing pair must be a listed known gap, and every known gap must still
    /// be a gap (fixed ones are removed from the list) and must hold its floor.
    func testEveryTextAndFillPairMeetsWCAGExceptTheListedGaps() {
        var failing: [String: Double] = [:]
        for check in matrix() {
            let r = contrast(check.fg, on: check.bg)
            if r < check.minimum { failing[check.id] = r }
        }
        let unexpected = failing.keys.filter { knownGaps[$0] == nil }.sorted()
        XCTAssertTrue(unexpected.isEmpty, "pairs under their WCAG minimum: " + unexpected.map {
            "\($0) = \(String(format: "%.2f", failing[$0] ?? 0)):1"
        }.joined(separator: ", "))

        for (id, gap) in knownGaps {
            guard let r = failing[id] else {
                XCTFail("\(id) now passes — remove it from knownGaps")
                continue
            }
            XCTAssertGreaterThanOrEqual(r, gap.floor, "\(id) fell below its floor (\(gap.reason))")
        }
    }

    /// The penalty block's wash: critical ink and primary text on `criticalWash` composited over the
    /// card surface, both schemes.
    func testCriticalWashKeepsItsTextReadable() {
        for scheme in Scheme.allCases {
            let card = hex(Spec.surface, scheme)
            let washed = composite(hex(Spec.criticalWash, scheme), over: card)
            for (name, ink) in [("critical", Spec.critical), ("textPrimary", Spec.textPrimary)] {
                let inkRGB = Color.sRGBComponents(hex: hex(ink, scheme))
                let r = ratio((inkRGB.r, inkRGB.g, inkRGB.b), washed)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) on criticalWash (\(scheme)) = \(r)")
            }
        }
    }

    /// `textDisabled` is deliberately below AA (disabled labels only, never information) — pinned so it
    /// is never mistaken for a readable tertiary.
    func testDisabledTextIsNotAnInformationColour() {
        for scheme in Scheme.allCases {
            XCTAssertLessThan(contrast(hex(Spec.textDisabled, scheme), on: hex(Spec.surface, scheme)), 4.5)
        }
    }

    /// The hierarchy that replaces shadows (§9.2): canvas < surface < surfaceRaised in dark, and the
    /// three steps are distinct colours in light (where surface and surfaceRaised are both white, the
    /// raised step is carried by elevation instead).
    func testSurfaceStepsAreOrdered() {
        func lum(_ hexValue: String) -> Double {
            let c = Color.sRGBComponents(hex: hexValue)
            return luminance(r: c.r, g: c.g, b: c.b)
        }
        XCTAssertLessThan(lum(Spec.canvas.dark), lum(Spec.surface.dark))
        XCTAssertLessThan(lum(Spec.surface.dark), lum(Spec.surfaceRaised.dark))
        XCTAssertLessThan(lum(Spec.canvas.light), lum(Spec.surface.light))
    }
}
