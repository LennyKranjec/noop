import SwiftUI
import MarkdownUI
import StrandDesign

/// The MarkdownUI theme for Coach replies.
///
/// LLM chat replies (OpenAI / Anthropic / Gemini) arrive as GitHub-flavored
/// Markdown — overwhelmingly bold, bullet/numbered lists, `###` headings, and the
/// occasional table for a weekly plan. This theme renders that set in the Telos 2.0
/// voice (§6.9): prose at `body` (SF Pro 17), headings at `headline` (17 semibold —
/// a `#` must not shout inside a reply), code in SF Mono on `surfaceInset`, and
/// tables in the qualifier voice (SF Mono at ≈ `scaleNumber`) with `lineSoft`
/// hairlines. MarkdownUI sizes are points, so they follow the token sizes at the
/// Large text size.
extension Theme {
    static let strand = Theme()
        // Base body text — `TelosType.body` (SF Pro 17 / regular).
        .text {
            ForegroundColor(TelosColor.textPrimary)
            FontSize(17)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(TelosColor.textPrimary)
            BackgroundColor(TelosColor.surfaceInset)
        }
        .link {
            ForegroundColor(StrandPalette.accent)
        }
        // Headings: h1–h3 land at `headline` (17 / semibold), h4 at `subhead` weight,
        // h5–h6 as the secondary small labels.
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(TelosColor.textPrimary)
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(TelosColor.textPrimary)
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 12, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                    ForegroundColor(TelosColor.textPrimary)
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(15)
                    ForegroundColor(TelosColor.textPrimary)
                }
        }
        .heading5 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                    ForegroundColor(TelosColor.textSecondary)
                }
        }
        .heading6 { configuration in
            configuration.label
                .markdownMargin(top: 10, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(12)
                    ForegroundColor(TelosColor.textSecondary)
                }
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 8)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.2))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .markdownTextStyle {
                    ForegroundColor(TelosColor.textSecondary)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(TelosColor.lineStrong)
                        .frame(width: TelosStroke.data)
                }
                .markdownMargin(top: 4, bottom: 8)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                    }
                    .padding(TelosSpace.s)
            }
            .background(TelosColor.surfaceInset)
            .clipShape(RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous)
                .strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
            .markdownMargin(top: 4, bottom: 8)
        }
        .thematicBreak {
            TelosColor.lineSoft
                .frame(height: TelosStroke.line)
                .markdownMargin(top: 10, bottom: 10)
        }
        // Compact on a phone: smaller cell text and tighter padding, and a table wider than the bubble
        // scrolls sideways (like a code block) instead of blowing the layout up. The system prompt asks
        // the model to avoid tables altogether; this is only the safety net for when one arrives anyway.
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: TelosColor.lineSoft))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(Color.clear, TelosColor.surfaceInset)
                    )
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                // The qualifier voice (`scaleNumber`: SF Mono ≈ 11–12 pt): tables in a reply are figures.
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    FontSize(.em(0.7))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .relativeLineSpacing(.em(0.15))
        }
}
