import XCTest
import SwiftUI
@testable import StrandDesign

/// WCAG contrast for every text / graphic token of the Telos 2.0 palette (docs/DESIGN_V2.md "VISUAL
/// DIRECTION" + §4.1) against every ground it is drawn on, in BOTH schemes (§2.4: text ≥ 4.5:1,
/// non-text UI ≥ 3:1).
///
/// The grounds include the GLASS tiles: `glassFill` / `glassRaised` are translucent, so they are
/// composited over the ground behind them (`canvas` and the deeper `canvasDeep`) exactly as rendered.
/// Computed on the hex strings in `TelosColor.Spec` — pure and deterministic. The whole matrix is swept
/// and the set of failing pairs compared with `knownGaps` (currently EMPTY: every pair passes): a new
/// failure fails the suite, and a listed gap that has been fixed fails it too, so the list never lies.
final class TelosContrastTests: XCTestCase {

    private typealias Pair = TelosColor.Pair
    private typealias Spec = TelosColor.Spec
    private typealias RGB = (r: Double, g: Double, b: Double)

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

    private func luminance(_ c: RGB) -> Double {
        0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func rgb(_ hexValue: String) -> RGB {
        let c = Color.sRGBComponents(hex: hexValue)
        return (c.r, c.g, c.b)
    }

    /// `fg` (may carry alpha) composited over the opaque colour `bg` (sRGB "over"), as rendered.
    private func composite(_ fg: String, over bg: RGB) -> RGB {
        let f = Color.sRGBComponents(hex: fg)
        return (f.r * f.a + bg.r * (1 - f.a),
                f.g * f.a + bg.g * (1 - f.a),
                f.b * f.a + bg.b * (1 - f.a))
    }

    private func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Contrast of `fg` drawn on the opaque ground `bg`.
    private func contrast(_ fg: String, on bg: RGB) -> Double {
        ratio(composite(fg, over: bg), bg)
    }

    private func contrast(_ fg: String, onHex bg: String) -> Double {
        contrast(fg, on: rgb(bg))
    }

    // MARK: The grounds

    /// Every ground text and graphics sit on, per scheme: the bare ground (both ends of its depth), the
    /// glass tile over each end, the raised glass layer, and the opaque surfaces.
    private func grounds(_ scheme: Scheme) -> [(String, RGB)] {
        let canvas = rgb(hex(Spec.canvas, scheme))
        let deep = rgb(hex(Spec.canvasDeep, scheme))
        return [
            ("canvas", canvas),
            ("canvasDeep", deep),
            ("glass/canvas", composite(hex(Spec.glassFill, scheme), over: canvas)),
            ("glass/canvasDeep", composite(hex(Spec.glassFill, scheme), over: deep)),
            ("glassRaised/canvasDeep", composite(hex(Spec.glassRaised, scheme), over: deep)),
            ("surface", rgb(hex(Spec.surface, scheme))),
            ("surfaceRaised", rgb(hex(Spec.surfaceRaised, scheme))),
        ]
    }

    // MARK: The matrix

    private struct Check {
        let id: String
        let fg: String
        let bg: RGB
        let minimum: Double
    }

    private let textMinimum = 4.5
    private let graphicMinimum = 3.0

    /// Every token that is used AS TEXT.
    private let textTokens: [(String, Pair)] = [
        ("textPrimary", Spec.textPrimary), ("textSecondary", Spec.textSecondary),
        ("textTertiary", Spec.textTertiary), ("mint", Spec.mint),
        ("positive", Spec.positive), ("warning", Spec.warning), ("critical", Spec.critical),
        ("chargeInk", Spec.chargeInk), ("effortInk", Spec.effortInk), ("restInk", Spec.restInk),
        ("stressInk", Spec.stressInk), ("heartInk", Spec.heartInk), ("lungsInk", Spec.lungsInk),
        ("muscleInk", Spec.muscleInk), ("focusInk", Spec.focusInk), ("violetInk", Spec.violetInk),
        ("magentaInk", Spec.magentaInk), ("amber", Spec.amber), ("teal", Spec.teal),
    ]

    /// Every token that is used as a GRAPHIC (ring, arc, particle, series, dot, focus ring).
    private let graphicTokens: [(String, Pair)] = [
        ("charge", Spec.charge), ("effort", Spec.effort), ("rest", Spec.rest), ("stress", Spec.stress),
        ("heart", Spec.heart), ("lungs", Spec.lungs), ("muscle", Spec.muscle), ("focus", Spec.focus),
        ("bestGold", Spec.bestGold), ("mint", Spec.mint), ("glow", Spec.glow), ("positive", Spec.positive),
        ("warning", Spec.warning), ("critical", Spec.critical), ("teal", Spec.teal),
        ("violet", Spec.violet), ("magenta", Spec.magenta), ("amber", Spec.amber), ("orange", Spec.orange),
    ]

    private func matrix() -> [Check] {
        var checks: [Check] = []
        for scheme in Scheme.allCases {
            let s = scheme.rawValue
            let all = grounds(scheme)
            for (name, token) in textTokens {
                for (groundName, ground) in all {
                    checks.append(Check(id: "\(name)/\(groundName)/\(s)", fg: hex(token, scheme),
                                        bg: ground, minimum: textMinimum))
                }
            }
            for (name, token) in graphicTokens {
                for (groundName, ground) in all {
                    checks.append(Check(id: "\(name)-graphic/\(groundName)/\(s)", fg: hex(token, scheme),
                                        bg: ground, minimum: graphicMinimum))
                }
            }
            // Text inside wells: field text and unselected segment labels.
            for (name, token) in [("textPrimary", Spec.textPrimary), ("textSecondary", Spec.textSecondary)] {
                checks.append(Check(id: "\(name)/surfaceInset/\(s)", fg: hex(token, scheme),
                                    bg: rgb(hex(Spec.surfaceInset, scheme)), minimum: textMinimum))
            }
            // The primary button label on the accent (rest and pressed).
            for (bgName, bg) in [("mint", Spec.mint), ("mintPressed", Spec.mintPressed)] {
                checks.append(Check(id: "onAccent/\(bgName)/\(s)", fg: hex(Spec.onAccent, scheme),
                                    bg: rgb(hex(bg, scheme)), minimum: textMinimum))
            }
        }
        // The diagnostic register is dark-only (scheme-invariant hex).
        let fields: [(String, Pair)] = [("diagField", Spec.diagField), ("diagCard", Spec.diagCard)]
        let diagInks: [(String, Pair)] = [("diagText", Spec.diagText), ("diagMuted", Spec.diagMuted),
                                          ("diagAlarm", Spec.diagAlarm), ("mint", Spec.mint)]
        for (bgName, bg) in fields {
            for (name, ink) in diagInks {
                checks.append(Check(id: "\(name)/\(bgName)/diag", fg: ink.dark, bg: rgb(bg.dark), minimum: textMinimum))
            }
        }
        return checks
    }

    /// Pairs allowed below their minimum, with the floor they must still clear and why. EMPTY: the
    /// 2.0 palette was tuned until every pair in the matrix passes in both schemes.
    private let knownGaps: [String: (floor: Double, reason: String)] = [:]

    // MARK: Tests

    func testContrastMetricMatchesKnownValues() {
        XCTAssertEqual(contrast("#FFFFFF", onHex: "#000000"), 21.0, accuracy: 0.01)
        XCTAssertEqual(contrast("#777777", onHex: "#777777"), 1.0, accuracy: 0.0001)
        // Alpha composites: a 50 % white over black is mid-grey, not white.
        XCTAssertLessThan(contrast("#FFFFFF80", onHex: "#000000"), 21.0)
    }

    /// The two failures the spec names (§2.4) are fixed by the re-pointed values.
    func testTheTwoNamedFailuresAreFixed() {
        // 1.x tertiary text on the 1.x dark card, and the 1.x light mint on white: both under AA.
        XCTAssertLessThan(contrast("#7D7F88", onHex: "#2A2C34"), 4.5)
        XCTAssertLessThan(contrast("#149A78", onHex: "#FFFFFF"), 4.5)
        // V2 values on the V2 glass tiles, both schemes.
        for scheme in Scheme.allCases {
            let glass = composite(hex(Spec.glassFill, scheme), over: rgb(hex(Spec.canvas, scheme)))
            XCTAssertGreaterThanOrEqual(contrast(hex(Spec.textTertiary, scheme), on: glass), 4.5,
                                        "textTertiary on glass (\(scheme))")
            XCTAssertGreaterThanOrEqual(contrast(hex(Spec.mint, scheme), on: glass), 4.5,
                                        "mint on glass (\(scheme))")
        }
        XCTAssertEqual(NoopVisualStyle.tertiaryText, TelosColor.textTertiary)
        XCTAssertEqual(AccentColor.mint.accent, TelosColor.mint)
    }

    func testEveryTextAndGraphicPairMeetsWCAG() {
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

    /// The penalty block's wash: critical ink and primary text on `criticalWash` over a glass tile.
    func testCriticalWashKeepsItsTextReadable() {
        for scheme in Scheme.allCases {
            let glass = composite(hex(Spec.glassFill, scheme), over: rgb(hex(Spec.canvas, scheme)))
            let washed = composite(hex(Spec.criticalWash, scheme), over: glass)
            for (name, ink) in [("critical", Spec.critical), ("textPrimary", Spec.textPrimary)] {
                let r = contrast(hex(ink, scheme), on: washed)
                XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) on criticalWash (\(scheme)) = \(r)")
            }
        }
    }

    /// `textDisabled` is deliberately below AA (disabled labels only, never information).
    func testDisabledTextIsNotAnInformationColour() {
        for scheme in Scheme.allCases {
            XCTAssertLessThan(contrast(hex(Spec.textDisabled, scheme), onHex: hex(Spec.surface, scheme)), 4.5)
        }
    }

    /// The dark ground is near-black and the glass reads as a lift above it; the opaque steps are ordered.
    func testGroundAndGlassHierarchy() {
        let canvas = rgb(Spec.canvas.dark)
        let glass = composite(Spec.glassFill.dark, over: canvas)
        XCTAssertLessThan(luminance(canvas), 0.005, "the dark ground stays near-black")
        XCTAssertLessThan(luminance(canvas), luminance(glass))
        XCTAssertLessThan(luminance(rgb(Spec.canvas.dark)), luminance(rgb(Spec.surface.dark)))
        XCTAssertLessThan(luminance(rgb(Spec.surface.dark)), luminance(rgb(Spec.surfaceRaised.dark)))
        XCTAssertLessThan(luminance(rgb(Spec.canvas.light)), luminance(rgb(Spec.surface.light)))
        // The glass fill is translucent (≈ 6–10 % white) in dark.
        let alpha = Color.sRGBComponents(hex: Spec.glassFill.dark).a
        XCTAssertGreaterThanOrEqual(alpha, 0.06)
        XCTAssertLessThanOrEqual(alpha, 0.10)
    }
}
