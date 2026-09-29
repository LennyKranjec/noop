import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography (§9.2) — re-pointed to Telos 2.0 (docs/DESIGN_V2.md §4.2)
//
// Three voices: numbers are SF Rounded, prose is SF Pro, anything that qualifies a number is SF Mono.
// The 1.x names are kept and re-pointed so the whole app takes the V2 voice with no call-site edit:
//   • the PROSE styles (`title1`, `title2`, `headline`, `body`, `subhead`, `caption`, `footnote`) are
//     SF Pro now (the `.rounded` design is dropped);
//   • `overline` is SF Mono medium (`TelosType.scale`) with `overlineTracking` 0.8 (was 0.45) — mono
//     is ~12 % wider, so each screen package re-checks its `strandOverline()` sites for truncation;
//   • `display` / `rounded` / `number` stay SF Rounded at a FIXED size — geometry-bound callers rely
//     on that. New numerals use `TelosType` / `.telosNumeral(_:)`.
//
// All numeric styles use `.monospacedDigit()` so live values don't reflow.

public enum StrandFont {

    // MARK: Family

    private static func roundedSystem(_ size: CGFloat, weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Scale (§9.2)

    /// Display 64–80 / Bold — the gauge score number. SF Rounded, fixed size (geometry-bound callers
    /// depend on it), tabular digits so a changing value never reflows.
    public static func display(_ size: CGFloat = 72) -> Font {
        roundedSystem(size, weight: .bold).monospacedDigit()
    }

    /// The tight tracking for big display numbers (≈ -0.04em). Apply alongside
    /// `display(_:)` at the use site, e.g. `.tracking(StrandFont.displayTracking(72))`.
    public static func displayTracking(_ size: CGFloat = 72) -> CGFloat {
        -size * 0.04
    }

    /// An SF Rounded numeric style at an arbitrary fixed size/weight — the house numeral. Tabular so
    /// live values align.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        roundedSystem(size, weight: weight).monospacedDigit()
    }

    /// Title1 28 / Bold, SF Pro (`TelosType.title`). Scales with Dynamic Type.
    public static let title1 = TelosType.title

    /// Title2 22 / Semibold, SF Pro (`TelosType.title2`). Scales with Dynamic Type.
    public static let title2 = TelosType.title2

    /// Headline 17 / Semibold, SF Pro (`TelosType.headline`). Scales with Dynamic Type.
    public static let headline = TelosType.headline

    /// Body 17 / Regular, SF Pro (`TelosType.body`). Scales with Dynamic Type.
    public static let body = TelosType.body

    /// Subhead 15, SF Pro (`TelosType.subhead`). Scales with Dynamic Type.
    public static let subhead = TelosType.subhead

    /// Caption 12, SF Pro (`TelosType.caption`). Scales with Dynamic Type.
    public static let caption = TelosType.caption

    /// Footnote 13, SF Pro (`TelosType.footnote`). Scales with Dynamic Type.
    public static let footnote = TelosType.footnote

    /// Overline — SF Mono medium 11 (`TelosType.scale`), letter-spaced by `overlineTracking` (apply it at
    /// the use site; `strandOverline()` does it for you). Sparing ALL-CAPS labels. Scales with Dynamic
    /// Type.
    ///
    /// Also the face for compact status copy in constrained chrome (the Today header's sync capsule),
    /// used there WITHOUT the tracking — that is sentence case, not an overline, and the letter-spacing
    /// is what makes an overline read as one.
    public static let overline = TelosType.scale

    /// `overline` at a custom point size — the same SF Mono medium face and Dynamic-Type scaling
    /// (relativeTo `.caption2`), just a different base. Lets a caller shrink an ALL-CAPS label to fit a
    /// small container without losing accessibility text-scaling. (V2 minimum rendered size is 11 pt.)
    public static func overlineScaled(_ size: CGFloat) -> Font {
        #if os(watchOS)
        return Font.system(size: size, weight: .medium, design: .monospaced)
        #elseif canImport(UIKit)
        let base = UIFont.systemFont(ofSize: size, weight: .medium)
        let descriptor = base.fontDescriptor.withDesign(.monospaced) ?? base.fontDescriptor
        let mono = UIFont(descriptor: descriptor, size: size)
        return Font(UIFontMetrics(forTextStyle: .caption2).scaledFont(for: mono))
        #elseif canImport(AppKit)
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.monospaced),
              let mono = NSFont(descriptor: descriptor, size: size) else {
            return Font(base)
        }
        return Font(mono)
        #else
        return Font.system(size: size, weight: .medium, design: .monospaced)
        #endif
    }

    /// Mono 13 (SF Mono) — raw / log views. Tabular by nature.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    // MARK: Numeric variants (tabular digits)

    /// A numeric style at an arbitrary fixed size/weight, for live values — SF Rounded, tabular
    /// digits. This is the tile/value numeral.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        roundedSystem(size, weight: weight).monospacedDigit()
    }

    /// Body number — SF Rounded medium 17, tabular (`TelosType.numeralS`). Scales with Dynamic Type
    /// alongside its sibling `body` label so a value and its label stay matched.
    public static let bodyNumber = TelosType.numeralS

    /// Small number — SF Rounded medium 13, tabular (`TelosType.numeralXS`; was caption 12). Scales
    /// with Dynamic Type.
    public static let captionNumber = TelosType.numeralXS

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The ONE tracking for overline text (ALL-CAPS labels). Every caps label reads this —
    /// state pills, source badges and chart footers each used to carry their own 0.4/0.5, which
    /// is visible when two of them sit in the same row. V2: 0.45 → 0.8 (`TelosType.Tracking.scale`).
    public static let overlineTracking: CGFloat = TelosType.Tracking.scale
}

// MARK: - Text helpers

public extension Text {
    /// Style as an overline label: ALL-CAPS, SF Mono medium (V2 `scale`), `overlineTracking`, secondary text.
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .tracking(StrandFont.overlineTracking)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: an overline-styled label string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("88").font(StrandFont.display(72)).tracking(StrandFont.displayTracking(72)).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 1 / Bold 28").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Title 2 / Semibold 22").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Headline / Semibold 17").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body / Regular 15 — the thread of you, read in full.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Subhead 13").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Caption 12").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("Footnote 11").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Text("Overline").strandOverline()
            Text("0xAA 41 00 1c crc32=f3a1  mono 13").font(StrandFont.mono).foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 4) {
                Text("HRV").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("62").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                Text("ms").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 520, height: 620)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
