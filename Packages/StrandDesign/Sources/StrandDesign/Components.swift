import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum NoopMetrics {
    public static let cardRadius: CGFloat = NoopVisualStyle.cardRadius
    public static let cardPadding: CGFloat = NoopVisualStyle.cardPadding
    public static let gap: CGFloat = NoopVisualStyle.itemGap
    public static let sectionGap: CGFloat = NoopVisualStyle.sectionGap
    public static let screenPadding: CGFloat = NoopVisualStyle.pagePadding
    public static let tileHeight: CGFloat = 96   // Design Reset: tighter metric tile
    // Key Metrics grid: one fixed height every tile snaps to, so a sparkline-and-caption tile and a
    // plain value tile read the same. maxHeight: .infinity can't equalise them inside a LazyVGrid (the
    // grid only offers a cell its content height, so there's nothing for the shorter tile to grow into),
    // so we pin a single height that clears the tallest layout (value + inline sparkline + caption).
    public static let keyMetricTileHeight: CGFloat = 122
    public static let chartHeight: CGFloat = 220
    /// Minimum macOS detail-sheet footprint for a scrollable editor/history surface.
    public static let detailSheetMinWidth: CGFloat = 520
    public static let detailSheetMinHeight: CGFloat = 620
    /// Canonical compact provenance-chip height; shared with overlays that align the chip to a border.
    public static let sourceBadgeHeight: CGFloat = 18
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar
    /// Canonical diameter for compact circular controls in dense header chrome.
    public static let compactControlSize: CGFloat = 36
    /// Expanded width of the compact charge-to-sync status capsule.
    public static let syncIndicatorExpandedWidth: CGFloat = 108
    /// Optical space between the sync ring and its transient label.
    public static let syncIndicatorLabelSpacing: CGFloat = 5
    /// Smallest readable scale for long localized labels inside the sync capsule.
    public static let syncIndicatorMinimumLabelScale: CGFloat = 0.72
    /// Even inset around the sync control before applying exact-bounds Liquid Glass, matching the inset
    /// the system's `.small` glass chrome gives the sibling header circles. Equal on both axes so the
    /// compact state stays circular.
    public static let syncIndicatorGlassPadding: CGFloat = 5
    /// Inset for the indicator's ring in BOTH states — the battery arc and the sync spinner share one
    /// radius, so the morph changes colour and sweep without the circle also resizing. Two different
    /// radii read as two different controls swapping places rather than one control changing state.
    public static let syncIndicatorArcInset: CGFloat = 2.5
    /// Width of the soft fade where long header text passes beneath trailing controls.
    public static let headerTextFadeWidth: CGFloat = 48
    /// Starting guess for the trailing footprint a header control row occupies, used ONLY until the host
    /// has measured its own cluster (see `headerTrailingControlFadeMask(reserving:)`). Four compact
    /// controls plus their gaps and the sync control's glass inset — deliberately not a fixed budget,
    /// because a cluster that gains a control must not silently start mis-fading the title beside it.
    public static let headerControlReserveWidth: CGFloat = 168

    // MARK: Standardised spacing scale (the ONE source of truth for margins)
    //
    // A 4pt-based ramp. Reach for these instead of literal numbers so every gap,
    // inset and margin lines up to the same grid. Note `cardPadding` (16) above is
    // the same value as `space4` — kept as a named alias for the existing call sites.
    public static let space1:  CGFloat = 4
    /// Optical separation for paired labels; structural layout still follows the 4-point ramp.
    public static let spaceHalf: CGFloat = 2
    public static let space2:  CGFloat = 8
    public static let space3:  CGFloat = 12
    public static let space4:  CGFloat = 16
    public static let space5:  CGFloat = 20
    public static let space6:  CGFloat = 24
    public static let space8:  CGFloat = 32
    public static let space10: CGFloat = 40

    // MARK: Named layout constants — the canonical margins/heights screens compose with.
    //
    // Telos 2.0 density (coordinator decision 11): the smaller steps are the default INSIDE cards —
    // cards hug their content, no decorative padding. See `TelosSpace` for the full scale.
    /// Horizontal page margin (the gutter on the left/right edge of a screen). Use via `.screenPadding()`.
    public static let screenHPadding: CGFloat = NoopVisualStyle.pagePadding
    /// Vertical gap between top-level page sections. 26 → 24.
    public static let sectionSpacing: CGFloat = NoopVisualStyle.sectionGap
    /// Interior padding inside a card's content (matches `cardPadding`). 16 → 12.
    public static let cardInnerPadding: CGFloat = TelosSpace.cardPadding
    /// Vertical gap between stacked elements INSIDE a card. 12 → 8.
    public static let cardInnerSpacing: CGFloat = TelosSpace.cardInner
    /// Vertical gap between rows in a list-style card (the row's own vertical padding in V2). 10 → 12.
    public static let rowSpacing: CGFloat = TelosSpace.rowVertical
    /// Standard interactive-control height (buttons, fields, segmented controls).
    public static let controlHeight: CGFloat = 48
    /// Standard one-pixel edge used by cards and compact controls.
    public static let hairlineWidth: CGFloat = 1
    /// Profile form dimensions shared by avatar and numeric controls.
    public static let profileAvatarDiameter: CGFloat = 44
    public static let formValueColumnWidth: CGFloat = 48
    public static let formWideValueColumnWidth: CGFloat = 64
    /// Compact metadata and explanatory-footer heights.
    public static let compactMetadataMinHeight: CGFloat = 24
    public static let compactHintMinHeight: CGFloat = 18
    /// Canonical thickness for compact horizontal indicator tracks.
    public static let indicatorTrackHeight: CGFloat = 8
    /// Fully-rounded corner radius — pills, chips, capsule buttons.
    public static let pillRadius: CGFloat = NoopVisualStyle.pillRadius
    /// Minimum desktop size for a navigation-based customization sheet.
    public static let editorSheetMinWidth: CGFloat = 440
    public static let editorSheetMinHeight: CGFloat = 600
}

// MARK: - Screen padding

public extension View {
    /// Apply the canonical horizontal page gutter (`NoopMetrics.screenHPadding`). The single
    /// source of truth for left/right screen margins — use this instead of a literal padding so
    /// every screen lines up to the same edge.
    func screenPadding() -> some View {
        self.padding(.horizontal, NoopMetrics.screenHPadding)
    }
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: the drag indicator (the touch affordance that says
    /// "swipe to dismiss") plus detents. macOS sheets are free-floating windows and must
    /// NOT receive this, so the helper is iOS-only and call sites stay shared via #if.
    /// `largeFirst == false` opens at .medium with .large reachable by dragging up (short
    /// forms); `true` opens full-height (long scrolls).
    ///
    /// V2 (§5.12): the sheet background is the solid `canvas` (no material) where the OS can set it
    /// (iOS 16.4+); earlier systems keep the system sheet background.
    @ViewBuilder
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        if #available(iOS 16.4, *) {
            self
                .presentationDragIndicator(.visible)
                .presentationDetents(largeFirst ? [.large] : [.medium, .large])
                .presentationBackground(TelosColor.canvas)
        } else {
            self
                .presentationDragIndicator(.visible)
                .presentationDetents(largeFirst ? [.large] : [.medium, .large])
        }
    }
}
#endif

// MARK: - Surface

/// The one card surface — the V2 flat card (§5.1: `surface` fill, 1 pt `line`, radius 20, no shadow,
/// fill × `\.telosCardOpacity`). PUBLIC API is unchanged (padding + content + optional `tint`, which
/// now draws only a 3 pt identity top edge). Default padding hugs content (12, decision 11).
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = NoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome (fill + border + shadow) lives in the background so its animation is
            // scoped to the card surface ONLY. It must never animate the content() subtree, or a
            // chart inside re-animates its line every time the cursor crosses the card. (#104)
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static resting frosted surface — no
    // hover @State, no .onHover tracking, no .animation node. That trims the modifier
    // count on every card, which multiplies across long scrolling lists. macOS adds the
    // hover emphasis border on top (with the #104 animation scoping) unchanged.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: TelosStroke.line).opacity(hover ? 1 : 0)
            )
            .animation(TelosMotion.select, value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let overline: LocalizedStringKey?; let title: LocalizedStringKey; let trailing: String?
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil) {
        self.title = title; self.overline = overline; self.trailing = trailing
    }
    public var body: some View {
        // V2 (§5.9): `scale` overline in `textTertiary` → `title2` title → trailing text.
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline {
                    Text(overline)
                        .telosScale()
                        .textCase(.uppercase)
                        .foregroundStyle(TelosColor.textTertiary)
                }
                Text(title).font(TelosType.title2).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

public struct StatTile<Accessory: View>: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent
    /// An optional trailing accessory laid out INLINE in the header row beside the label (e.g. a small
    /// ⓘ that opens a scoring guide). Inline placement — not a corner overlay — so it can never sit on
    /// top of the value, sparkline or trend chip on a narrow tile (#495). Defaults to nothing.
    @ViewBuilder var accessory: () -> Accessory

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
        self.accessory = accessory
    }

    public var body: some View {
        // V2 (§5.4 + decision 11): a compact tile — radius `tile` 14, padding 12, flat surface, NO tint
        // wash and NO minimum height (it hugs its content). `accent` colours the numeral only.
        // New single-attribute tiles should use `TelosMetricTile` (it carries the honesty states).
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            // Header row: the metric label, and (right-aligned) the optional accessory laid out in
            // flow so it reserves its own space rather than floating over the value below (#495).
            HStack(alignment: .top, spacing: 4) {
                Text(label)
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.textTertiary)
                Spacer(minLength: 0)
                accessory()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .telosNumeral(.numeralM)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                // Trend chip — the delta as a tinted pill with a direction arrow.
                if let delta { TrendChip(text: delta, color: deltaColor) }
            }
            // Sparkline isn't available on watchOS (it relies on chart-hover helpers); the watch
            // doesn't use StatTile, but guard the reference so the file still compiles there.
            #if !os(watchOS)
            if let sparkline, sparkline.count > 1 {
                Sparkline(values: sparkline, gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]))
                    .frame(height: 22)
                    .accessibilityHidden(true)
            }
            #endif
            if let caption {
                Text(caption).font(TelosType.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
            }
        }
        .padding(TelosSpace.tilePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No floor (decision 11). maxHeight: .infinity still lets a caller that DOES hand this tile a
        // bounded height (e.g. a grid pinned to NoopMetrics.keyMetricTileHeight) stretch it to fill; in an
        // unbounded parent it resolves to the content's own height.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.tile))
        // One VoiceOver stop per tile (label, value, caption, delta) instead of up
        // to four fragmented stops; the decorative sparkline is hidden above.
        .accessibilityElement(children: .combine)
    }
}

// Backward-compatible convenience: a StatTile with NO accessory (the common case) — every existing
// call site keeps working unchanged, and the type defaults `Accessory` to `EmptyView`.
public extension StatTile where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String, caption: String? = nil,
         accent: Color = StrandPalette.textPrimary, delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.init(label: label, value: value, caption: caption, accent: accent, delta: delta,
                  deltaColor: deltaColor, sparkline: sparkline, sparkColor: sparkColor,
                  accessory: { EmptyView() })
    }
}

// MARK: - Trend chip — a small tinted delta pill with a direction arrow.

/// A compact trend pill: an up/down/flat arrow + the delta text, tinted to `color`.
/// Inferred direction comes from a leading +/− in the text (else flat). Sits in the
/// corner of a StatTile or beside a metric value.
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        // No sign → a plain magnitude (e.g. a workout's "874 kcal"), not a trend: show NO direction
        // glyph. Previously this fell to "minus", whose leading dash read as a negative ("-874 kcal" — #41).
        return nil
    }
    public var body: some View {
        // V2 DeltaChip (§5.5): arrow 9 pt + signed value `numeralXS`, fill @ 0.16, no border. Pass "±0"
        // for a flat delta and "—" when none was computed (`TelosDelta` / `TelosFormat.signedDelta`).
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(TelosType.glyphDelta) }
            // One line, always: a long chip (e.g. a workout's kcal) truncates rather than wraps, so
            // the pill never grows a tile past its floor. Matches Android's unconditional ellipsize (#934).
            Text(text).font(TelosType.numeralXS).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        // Deliberately borderless (it sits inside a tile, beside a big value) but on the shared chip
        // fill weight, so a trend chip and a state pill in the same row read as one family.
        .background(color.opacity(NoopVisualStyle.chipFillOpacity), in: Capsule(style: .continuous))
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    var tint: Color? = nil
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight, tint: Color? = nil,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).strandOverline()
                        if let subtitle { Text(subtitle).font(TelosType.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(TelosType.numeralS).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Rectangle()
                        .fill(TelosColor.lineSoft)
                        .frame(height: TelosStroke.line)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    // An ALL-CAPS label IS an overline, so use the house helper instead of
                    // re-rolling uppercase + font + colour (it was bare `footnote`/tertiary, which
                    // read looser than the overline in the card header directly above it, and put
                    // 13pt tertiary text below the contrast the caps face wants).
                    Text(it.0).strandOverline()
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    /// Extra trailing inset reserved on the overline + status rows so a caller's
    /// `.overlay(alignment: .topTrailing)` (greeting + state pill) doesn't run over the
    /// card's own title text on a narrow screen (#69). Defaults to 0 — no effect unless set.
    var titleTrailingInset: CGFloat = 0
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil, titleTrailingInset: CGFloat = 0) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint; self.titleTrailingInset = titleTrailingInset
    }
    public var body: some View {
        // Defaults the card wash to the status colour so the coaching card sits in the
        // same colour world as the score it summarises (e.g. gold for Charge). The
        // insight card reads a touch stronger than a tile: an explicit hue wash
        // (.14 → .04) + a matching .22 hue border on top of the frosted surface.
        let hue = tint ?? statusColor
        // V2 flat card: identity is the coloured status word plus the card's 3 pt tint edge — no wash.
        // The status is a WORD, so it is set in the prose voice (`title`, SF Pro bold 28).
        return NoopCard(tint: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                    .padding(.trailing, titleTrailingInset)
                Text(status).font(TelosType.title).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, titleTrailingInset)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control, used everywhere)

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    /// When requested, keep the regular intrinsic control wherever it fits and fall back to
    /// equal-width segments inside the parent's available width on compact screens. This prevents
    /// long option sets from widening an entire page beyond the viewport while leaving the many
    /// shorter segmented controls byte-identical.
    let adaptsToAvailableWidth: Bool
    /// Per-segment availability (#943): a disabled segment stays visible (so users learn the
    /// option exists) but renders extra-dim and ignores taps; VoiceOver announces it dimmed.
    /// Defaults to everything enabled; ADDED additively, no existing call site touched.
    let isEnabled: (T) -> Bool
    let fillsAvailableWidth: Bool
    @Binding var selection: T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                label: @escaping (T) -> String) {
        self.init(items, selection: selection, adaptsToAvailableWidth: adaptsToAvailableWidth,
                  fillsAvailableWidth: fillsAvailableWidth,
                  isEnabled: { _ in true }, label: label)
    }
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                isEnabled: @escaping (T) -> Bool,
                label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.adaptsToAvailableWidth = adaptsToAvailableWidth
        self.fillsAvailableWidth = fillsAvailableWidth
        self.isEnabled = isEnabled
        self.label = label
    }
    @ViewBuilder
    public var body: some View {
        if fillsAvailableWidth {
            track(equalWidth: true)
        } else if adaptsToAvailableWidth {
            if dynamicTypeSize > .large {
                ScrollView(.horizontal, showsIndicators: false) {
                    track(equalWidth: false)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    track(equalWidth: false)
                    track(equalWidth: true)
                }
            }
        } else {
            track(equalWidth: false)
        }
    }

    private func track(equalWidth: Bool) -> some View {
        // V2 (§5.11): track 44 high (36 segment + 4 inner padding), radius 12, `surfaceInset` + 1 pt
        // `line`. Selected segment: radius 9, `surfaceRaised` + 1 pt `lineStrong`, NO shadow; label
        // `subhead` semibold `textPrimary`; unselected `textSecondary`; disabled `textDisabled` (and the
        // system "dimmed" trait via `.disabled`). Selection slides with `select`; Reduce Motion: instant.
        HStack(spacing: TelosSpace.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                let enabled = isEnabled(item)
                Button {
                    guard selection != item else { return }   // re-tapping the active segment stays silent
                    StrandHaptic.selection.play()
                    withAnimation(TelosMotion.animation(.select, reduced: reduceMotion)) { selection = item }
                } label: {
                    Text(label(item))
                        .font(TelosType.subhead.weight(.semibold))
                        .lineLimit(equalWidth ? 1 : nil)
                        // Range selection stays deliberately neutral so the control works above charts
                        // from every metric colour world without borrowing their green/blue/amber tint.
                        .foregroundStyle(sel ? TelosColor.textPrimary
                                             : (enabled ? TelosColor.textSecondary : TelosColor.textDisabled))
                        // Fill the segment height so the selected pill has EQUAL margins to the track
                        // on every side.
                        .frame(minWidth: equalWidth ? nil : 26,
                               maxWidth: equalWidth ? .infinity : nil,
                               maxHeight: .infinity)
                        .padding(.horizontal, equalWidth ? NoopMetrics.space1 : 10)
                        .background {
                            if sel {
                                let selectedShape = RoundedRectangle(cornerRadius: TelosRadius.segment, style: .continuous)
                                selectedShape
                                    .fill(TelosColor.surfaceRaised)
                                    .overlay(
                                        selectedShape.strokeBorder(TelosColor.lineStrong, lineWidth: TelosStroke.line)
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: TelosRadius.segment, style: .continuous))
                }
                // The shared press style (`press` token) — the one control used on every screen must
                // never feel dead while the selection animation catches up.
                .buttonStyle(StrandPressableButtonStyle(cornerRadius: TelosRadius.segment))
                .frame(maxWidth: equalWidth ? .infinity : nil)
                // A FLOOR, not a fixed height: the 36 pt segment grows with Dynamic Type instead of
                // clipping its label.
                .frame(minHeight: 36)
                .disabled(!enabled)
                // Announce the active range to VoiceOver and give a non-colour cue.
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .padding(TelosSpace.xs)
        .frame(maxWidth: equalWidth ? .infinity : nil)
        .background {
            let trackShape = RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
            trackShape
                .fill(TelosColor.surfaceInset)
                .overlay(trackShape.strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
        }
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        // `.frame(height:)` centres its content by default, so the label sits mid-capsule for free. Noted
        // because the Android twin pinned the same 18 with `heightIn` applied to the label itself, which
        // top-aligns — same number, different render. That one is matched to this, not the reverse.
        // The font stays FIXED (`TelosType.scaleFixed`, SF Mono 11 — the V2 minimum size): the capsule is
        // pinned to an 18pt height, so a Dynamic-Type-scaling face here would clip at large text sizes.
        // V2 (§5.3): an OUTLINE tag — no fill, 1 pt edge at 0.32, ink at full strength, `scale` voice.
        Text(text).textCase(.uppercase).font(TelosType.scaleFixed)
            .tracking(TelosType.Tracking.scale)
            .lineLimit(1)
            .padding(.horizontal, TelosSpace.s).frame(height: NoopMetrics.sourceBadgeHeight)
            .foregroundStyle(tint)
            .overlay(Capsule(style: .continuous)
                .strokeBorder(tint.opacity(NoopVisualStyle.chipBorderOpacity), lineWidth: TelosStroke.line))
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for whole-number-or-decimal entry on iOS: the decimal-pad
    /// keyboard (handles both integer Avg-HR and decimal calories). No-op on macOS
    /// (hardware keyboard), so the SAME shared view compiles on both. Pair with
    /// `.keyboardDoneToolbar(...)` on the enclosing view to add a Done button (the decimal
    /// pad has no return key).
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a single trailing "Done" button to the software-keyboard accessory bar that
    /// resigns the given focus binding. iOS-only; the keyboard toolbar is hosted by the
    /// keyboard itself, so it works inside a sheet with no NavigationStack. No-op on macOS.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Telos 2.0, §5.10) — the public API is unchanged; the look is V2.
//
// No gradient, no shadow on any button (the gold-gradient fill is retired). Height 50, radius
// `control` 12, `headline` label. Press = the `press` token (scale 0.97 + opacity 0.88; opacity only
// under Reduce Motion). Drop in via `.buttonStyle(.noopPrimary)` etc. on any `Button`.

/// Primary call-to-action: a solid accent fill with `onAccent` ink. Disabled: `lineStrong` fill,
/// `textDisabled` label.
public struct NoopPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
        return configuration.label
            .font(TelosType.headline)
            .foregroundStyle(isEnabled ? StrandPalette.goldDeepText : TelosColor.textDisabled)
            .padding(.vertical, TelosSpace.s).padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: NoopButtonMetrics.height)
            .background(shape.fill(isEnabled ? StrandPalette.accent : TelosColor.lineStrong))
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .scaleEffect(pressed && !reduceMotion ? TelosMotion.pressScale : 1)
            .animation(TelosMotion.press, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: `surfaceInset` well + 1 pt `line` edge + `textPrimary` label.
public struct NoopSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
        return configuration.label
            .font(TelosType.headline)
            .foregroundStyle(isEnabled ? TelosColor.textPrimary : TelosColor.textDisabled)
            .padding(.vertical, TelosSpace.s).padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: NoopButtonMetrics.height)
            .background(shape.fill(TelosColor.surfaceInset))
            .overlay(shape.strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .scaleEffect(pressed && !reduceMotion ? TelosMotion.pressScale : 1)
            .animation(TelosMotion.press, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost (tertiary): no fill, no border, accent `headline` label, 44 pt hit; pressed opacity 0.6.
public struct NoopGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(TelosType.headline)
            .foregroundStyle(isEnabled ? StrandPalette.accent : TelosColor.textDisabled)
            .padding(.horizontal, TelosSpace.m)
            .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
            .opacity(pressed ? 0.6 : 1)
            .animation(TelosMotion.press, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == NoopPrimaryButtonStyle {
    /// Solid accent primary CTA.
    static var noopPrimary: NoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: NoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopGhostButtonStyle {
    /// Borderless accent ghost button.
    static var noopGhost: NoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// The 1.x score-lifecycle chip, now drawn with the V2 confidence language (§5.3 / §5.5). Its API is
// unchanged: CALIBRATING = tertiary ink + DASHED border (visibly provisional), BUILDING = warning ink
// with a 0.10 wash, SOLID = tertiary (settled, quiet), LIVE = accent with the gated `live` dot.
// For new code prefer `ConfidenceTag` (which omits SOLID on heroes and tiles).

public enum ScoreState: Sendable, Equatable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's ink.
    public var color: Color {
        switch self {
        case .solid:        return TelosColor.textTertiary
        case .live:         return StrandPalette.accent
        case .building:     return TelosColor.warning
        case .calibrating:  return TelosColor.textTertiary
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip: dot 7 + `scale` label in the state's ink, capsule height at least 20, 1 pt
/// border at 0.32 (dashed for calibrating), a 0.10 wash for building. LIVE loops its dot (gated).
/// `text` overrides the default state label (e.g. "Building, 2 of 4").
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        let hue = state.color
        let shape = Capsule(style: .continuous)
        let dash: [CGFloat] = state == .calibrating ? [2, 2] : []
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(hue)
                .lineLimit(1)
        }
        .padding(.horizontal, TelosSpace.s).padding(.vertical, TelosSpace.xxs)
        .frame(minHeight: 20)
        .background(shape.fill(state == .building ? hue.opacity(TelosOpacity.wash) : Color.clear))
        .overlay(shape.strokeBorder(hue.opacity(TelosOpacity.border),
                                    style: StrokeStyle(lineWidth: TelosStroke.line, dash: dash)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// The status dot. When `pulsing` it runs the V2 `live` loop (opacity 1 to 0.35, 2 s): the one allowed
/// never-settling animation, and only while something is actually live. It poses still (a static dot)
/// under Reduce Motion, Low Power Mode or "Reduce motion in NOOP" via `NoopMotionState`, and stops the
/// moment `pulsing` turns off. No glow, no halo, no shadow.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    private var looping: Bool { pulsing && !poseStill }

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .opacity(dimmed ? 0.35 : 1)
            .animation(TelosMotion.liveLoop(poseStill: !looping), value: dimmed)
            .onAppear { dimmed = looping }
            .onChangeCompat(of: looping) { active in dimmed = active }
            .accessibilityHidden(true)
    }
}
