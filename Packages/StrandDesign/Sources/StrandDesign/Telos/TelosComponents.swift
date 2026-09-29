import SwiftUI

// MARK: - TelosComponents — the honesty components and small building blocks (docs/DESIGN_V2.md §5)
//
// THESE ARE HOW EVERY SCREEN SHOWS MISSING AND LOW-CONFIDENCE DATA. The contract, in one place:
//
//   • A value that does not exist is `AbsentValue` — "—" (U+2014, `TelosType.absent`) plus a REASON
//     in the same card. Never 0, never an en dash (U+2013), never blank, never a bare track with a fill.
//       AbsentValue(reason: "Strap not connected")
//   • A value below solid confidence carries a `ConfidenceTag`: `.calibrating` (dashed, tertiary —
//     visibly provisional; optionally "Calibrating (n of m)"), `.building` (warning ink). `.solid` is
//     not rendered on heroes/tiles; in a provenance row it reads "Solid" in tertiary.
//       ConfidenceTag(.calibrating(done: 2, total: 4))
//   • Where a reading came from, when, and over what window is the `ProvenanceRow` — always the LAST
//     row of a hero or detail card: SOURCE · HH:MM · N DAYS (+ confidence), SF Mono, tertiary.
//       ProvenanceRow(source: "Strap", updated: sample.date, window: Text("\(n) days"))
//   • The one way a primary number is shown is `MetricReadout` (label → numeral + unit → delta →
//     confidence → carried line / absent reason → provenance), one VoiceOver element. It never clamps
//     a value (coordinator decision 9: the Level and its parts are unbounded) and never counts up an
//     absent value; it counts up only when the value CHANGES, never on (re-)appear.
//   • A carried value (an earlier day shown because today has none) renders its numeral in
//     `textSecondary` with the existing "Carried · d MMM" line.
//
// Strings: every visible word here reuses an existing app-catalog key ("Solid", "Building",
// "Calibrating", "Calibrating (%lld of %lld)", "Carried · %@", "Updated %@", "No data", "Try again").
// Callers pass their own reasons as `Text` / `LocalizedStringKey`, so no new copy is introduced.
//
// Card opacity: `\.telosCardOpacity` replaces the per-card `@AppStorage` read. The app root reads the
// stored percent ONCE and injects it (`.telosCardOpacityFromPreferences()`); every card surface reads
// the environment value.

// MARK: - Card opacity (environment)

private struct TelosCardOpacityKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// The card-surface fill multiplier, 0.55…1.0 (the Settings "card transparency"). Default 1 (solid)
    /// until the app root injects the stored preference. Setting it clamps into range.
    var telosCardOpacity: Double {
        get { self[TelosCardOpacityKey.self] }
        set { self[TelosCardOpacityKey.self] = TelosOpacity.clampCardOpacity(newValue) }
    }
}

/// The ONE `@AppStorage` read of the card-opacity preference, placed once at the app root.
private struct TelosCardOpacityRoot: ViewModifier {
    @AppStorage(CardAppearancePrefs.opacityKey) private var percent: Int = CardAppearancePrefs.defaultPercent

    func body(content: Content) -> some View {
        content.environment(\.telosCardOpacity, TelosOpacity.cardOpacity(percent: percent))
    }
}

public extension View {
    /// Inject the card opacity from a percent you already hold (0–100; clamped to 55–100).
    func telosCardOpacity(percent: Int) -> some View {
        environment(\.telosCardOpacity, TelosOpacity.cardOpacity(percent: percent))
    }

    /// Read `CardAppearancePrefs.opacityKey` ONCE, here, and inject it for the whole subtree. Apply at
    /// the app root (FRAME), not per card. The stored key, its 0–100 semantics and its default (100)
    /// are unchanged; only where it is read moves.
    func telosCardOpacityFromPreferences() -> some View {
        modifier(TelosCardOpacityRoot())
    }
}

// MARK: - Formatting helpers

public enum TelosFormat {
    /// A whole number with locale grouping ("6,412"). Non-finite → "—".
    public static func integer(_ value: Double) -> String {
        guard value.isFinite else { return TelosType.absent }
        return value.rounded().formatted(.number.precision(.fractionLength(0)))
    }

    /// A fixed-decimals formatter ("3.1"). Non-finite → "—".
    public static func decimal(_ digits: Int) -> (Double) -> String {
        let places = max(0, digits)
        return { value in
            guard value.isFinite else { return TelosType.absent }
            return value.formatted(.number.precision(.fractionLength(places)))
        }
    }

    /// A signed delta with a TRUE minus (U+2212). |Δ| that rounds to zero at `digits` reads "±0" — so a
    /// flat delta and a missing one ("—") stay distinguishable. Non-finite → "—".
    public static func signedDelta(_ value: Double, digits: Int = 0) -> String {
        guard value.isFinite else { return TelosType.absent }
        let places = max(0, digits)
        var scale: Double = 1
        for _ in 0..<places { scale *= 10 }
        let rounded = (value * scale).rounded() / scale
        if rounded == 0 { return "\u{00B1}0" }
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(places)))
        return (rounded > 0 ? "+" : TelosType.minus) + magnitude
    }

    /// "12 Mar" — the carried-day label.
    public static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "07:12" (locale clock style).
    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}

// MARK: - Confidence

/// How far a score can be trusted. Map the app's `ScoreConfidence` onto this at the call site.
public enum TelosConfidence: Equatable, Sendable {
    /// Settled. Not shown on heroes / tiles.
    case solid
    /// Accruing nights; readable but still moving.
    case building
    /// Baseline still forming. Optional progress renders "Calibrating (n of m)".
    case calibrating(done: Int?, total: Int?)

    public var isSolid: Bool { self == .solid }

    /// The existing app-catalog label.
    public var label: Text {
        switch self {
        case .solid:
            return Text("Solid")
        case .building:
            return Text("Building")
        case .calibrating(let done, let total):
            if let done, let total {
                return Text("Calibrating (\(done) of \(total))")
            }
            return Text("Calibrating")
        }
    }
}

/// The confidence qualifier (§5.3). Height 20, `scale` text, 1 pt border.
/// `.calibrating` → tertiary ink, dashed border (provisional). `.building` → warning ink, solid border
/// @ 0.32, fill @ 0.10. `.solid` → nothing, unless `showsSolid` (detail provenance), then plain "Solid"
/// in tertiary.
public struct ConfidenceTag: View {
    private let confidence: TelosConfidence
    private let showsSolid: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ confidence: TelosConfidence, showsSolid: Bool = false) {
        self.confidence = confidence
        self.showsSolid = showsSolid
    }

    public var body: some View {
        switch confidence {
        case .solid:
            if showsSolid {
                confidence.label
                    .telosScale()
                    .textCase(.uppercase)
                    .foregroundStyle(TelosColor.tertiaryInk(for: contrast))
            }
        case .building:
            TelosTag(text: confidence.label, ink: TelosColor.warning, filled: true, dashed: false)
        case .calibrating:
            TelosTag(text: confidence.label, ink: TelosColor.tertiaryInk(for: contrast), filled: false, dashed: true)
        }
    }
}

// MARK: - Tag (static)

/// A static label capsule (§5.5): height ≥ 20, `scale` text UPPERCASE, 1 pt outline at 0.32, ink at
/// full strength. For source, BETA, DEBT, ASSOCIATION, RANDOMISED… `filled` adds a 0.10 wash;
/// `dashed` draws a [2, 2] provisional border.
public struct TelosTag: View {
    private let text: Text
    private let ink: Color
    private let filled: Bool
    private let dashed: Bool

    public init(_ title: LocalizedStringKey, ink: Color = TelosColor.textSecondary,
                filled: Bool = false, dashed: Bool = false) {
        self.init(text: Text(title), ink: ink, filled: filled, dashed: dashed)
    }

    public init(verbatim title: String, ink: Color = TelosColor.textSecondary,
                filled: Bool = false, dashed: Bool = false) {
        self.init(text: Text(verbatim: title), ink: ink, filled: filled, dashed: dashed)
    }

    public init(text: Text, ink: Color = TelosColor.textSecondary,
                filled: Bool = false, dashed: Bool = false) {
        self.text = text
        self.ink = ink
        self.filled = filled
        self.dashed = dashed
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        let dash: [CGFloat] = dashed ? [2, 2] : []
        return text
            .telosScale()
            .textCase(.uppercase)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, TelosSpace.s)
            .padding(.vertical, TelosSpace.xxs)
            .frame(minHeight: 20)
            .background(shape.fill(filled ? ink.opacity(TelosOpacity.wash) : Color.clear))
            .overlay(
                shape.strokeBorder(ink.opacity(TelosOpacity.border),
                                   style: StrokeStyle(lineWidth: TelosStroke.line, dash: dash))
            )
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Absent value

/// "—" plus a reason (§5.3). The dash sits in the numeral slot at `dashFont`; the reason is `footnote`
/// tertiary and is never truncated (write reasons that fit two lines at the default size). VoiceOver
/// reads "No data, <reason>".
public struct AbsentValue: View {
    public enum Arrangement: Sendable {
        /// Dash above reason (card / tile body).
        case stacked
        /// Dash and reason on one baseline (list rows, footers).
        case inline
    }

    private let reason: Text?
    private let dashFont: Font
    private let arrangement: Arrangement
    @Environment(\.colorSchemeContrast) private var contrast

    public init(reason: LocalizedStringKey?, dashFont: Font = TelosType.numeralS,
                arrangement: Arrangement = .stacked) {
        self.init(reasonText: reason.map { Text($0) }, dashFont: dashFont, arrangement: arrangement)
    }

    public init(verbatimReason: String?, dashFont: Font = TelosType.numeralS,
                arrangement: Arrangement = .stacked) {
        self.init(reasonText: verbatimReason.map { Text(verbatim: $0) }, dashFont: dashFont,
                  arrangement: arrangement)
    }

    public init(reasonText: Text?, dashFont: Font = TelosType.numeralS,
                arrangement: Arrangement = .stacked) {
        self.reason = reasonText
        self.dashFont = dashFont
        self.arrangement = arrangement
    }

    public var body: some View {
        let ink = TelosColor.tertiaryInk(for: contrast)
        Group {
            if arrangement == .inline {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                    Text(verbatim: TelosType.absent).font(dashFont).foregroundStyle(ink)
                    if let reason {
                        reason.font(TelosType.footnote).foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    Text(verbatim: TelosType.absent).font(dashFont).foregroundStyle(ink)
                    if let reason {
                        reason.font(TelosType.footnote).foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AbsentValue.spoken(reason))
    }

    /// "No data" or "No data, <reason>".
    static func spoken(_ reason: Text?) -> Text {
        guard let reason else { return Text("No data") }
        return Text("No data") + Text(verbatim: ", ") + reason
    }
}

// MARK: - Provenance

/// Where a reading came from, when, and over what window.
public struct TelosProvenance {
    public var source: Text?
    public var updated: Date?
    public var window: Text?
    public var confidence: TelosConfidence?

    public init(source: LocalizedStringKey? = nil, updated: Date? = nil, window: Text? = nil,
                confidence: TelosConfidence? = nil) {
        self.source = source.map { Text($0) }
        self.updated = updated
        self.window = window
        self.confidence = confidence
    }

    public init(sourceText: Text?, updated: Date? = nil, window: Text? = nil,
                confidence: TelosConfidence? = nil) {
        self.source = sourceText
        self.updated = updated
        self.window = window
        self.confidence = confidence
    }

    var isEmpty: Bool { source == nil && updated == nil && window == nil && confidence == nil }
}

/// `SOURCE · HH:MM · N DAYS` in `scaleNumber`, tertiary — always the last row of a hero or detail card.
/// The source is an outline tag; a non-nil confidence is appended (and reads "Solid" when solid). At
/// accessibility text sizes the parts stack instead of truncating.
public struct ProvenanceRow: View {
    private let provenance: TelosProvenance
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(source: LocalizedStringKey? = nil, updated: Date? = nil, window: Text? = nil,
                confidence: TelosConfidence? = nil) {
        self.provenance = TelosProvenance(source: source, updated: updated, window: window,
                                          confidence: confidence)
    }

    public init(_ provenance: TelosProvenance) {
        self.provenance = provenance
    }

    private enum Part {
        case source(Text)
        case time(Date)
        case window(Text)
        case confidence(TelosConfidence)
    }

    private var parts: [Part] {
        var out: [Part] = []
        if let s = provenance.source { out.append(.source(s)) }
        if let t = provenance.updated { out.append(.time(t)) }
        if let w = provenance.window { out.append(.window(w)) }
        if let c = provenance.confidence { out.append(.confidence(c)) }
        return out
    }

    public var body: some View {
        let ink = TelosColor.tertiaryInk(for: contrast)
        let items = parts
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, part in
                        partView(part, ink: ink)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: TelosSpace.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, part in
                        if index > 0 {
                            Text(verbatim: "\u{00B7}").font(TelosType.scaleNumber).foregroundStyle(ink)
                        }
                        partView(part, ink: ink)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func partView(_ part: Part, ink: Color) -> some View {
        switch part {
        case .source(let text):
            TelosTag(text: text, ink: ink)
        case .time(let date):
            Text(verbatim: TelosFormat.time(date))
                .font(TelosType.scaleNumber).foregroundStyle(ink)
        case .window(let text):
            text.font(TelosType.scaleNumber).textCase(.uppercase).foregroundStyle(ink)
        case .confidence(let c):
            ConfidenceTag(c, showsSolid: true)
        }
    }
}

// MARK: - Delta

public enum TelosDeltaTone: Sendable {
    /// Moved the way that is better FOR THIS METRIC (RHR down is better) — decided by the caller.
    case better
    case worse
    case flat
}

/// A delta for a `DeltaChip` (`TrendChip`). `text == nil` means "not computed" and renders "—"; a flat
/// delta must be passed as "±0" (see `TelosFormat.signedDelta`) so the two stay distinguishable.
public struct TelosDelta: Equatable {
    public let text: String?
    public let tone: TelosDeltaTone

    public init(text: String?, tone: TelosDeltaTone) {
        self.text = text
        self.tone = tone
    }

    /// No baseline to compare against — renders "—".
    public static let notComputed = TelosDelta(text: nil, tone: .flat)

    /// A numeric delta, formatted with a true minus and "±0" for flat.
    public static func value(_ delta: Double, digits: Int = 0, tone: TelosDeltaTone) -> TelosDelta {
        guard delta.isFinite else { return .notComputed }
        let text = TelosFormat.signedDelta(delta, digits: digits)
        return TelosDelta(text: text, tone: text == "\u{00B1}0" ? .flat : tone)
    }

    public var color: Color {
        switch tone {
        case .better: return TelosColor.positive
        case .worse:  return TelosColor.critical
        case .flat:   return TelosColor.textTertiary
        }
    }

    var displayText: String { text ?? TelosType.absent }
}

// MARK: - Counting numeral (shared by MetricReadout / TelosMetricTile)

/// Shows `value`, counting to a NEW value with `TelosMotion.countUp`. Never counts on appear or
/// re-appear (it snaps), and under Reduce Motion it always snaps. Font and colour come from outside.
struct TelosCountingNumeral: View {
    let value: Double
    let format: (Double) -> String
    @State private var shown: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(value: Double, format: @escaping (Double) -> String) {
        self.value = value
        self.format = format
    }

    var body: some View {
        TelosAnimatableNumber(number: shown ?? value, format: format)
            .onAppear { shown = value }
            .onChangeCompat(of: value) { newValue in
                if reduceMotion || shown == nil {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { shown = newValue }
                } else {
                    withAnimation(TelosMotion.countUp) { shown = newValue }
                }
            }
            .accessibilityHidden(true)
    }
}

private struct TelosAnimatableNumber: View, Animatable {
    var number: Double
    let format: (Double) -> String

    var animatableData: Double {
        get { number }
        set { number = newValue }
    }

    var body: some View {
        Text(verbatim: format(number))
            .lineLimit(1)
    }
}

// MARK: - Metric readout (the one way a primary number is shown)

/// The metric hero (§5.2). Left-aligned: `scale` label → numeral (`hero` or `numeralL`) + unit on one
/// baseline → delta → confidence tag (if not solid) → carried line / absent reason → provenance.
///
/// States come from the inputs, never from sentinels:
/// - value: `value` finite.
/// - carried: `carriedFrom` set — numeral `textSecondary` + "Carried · d MMM".
/// - calibrating / building: `confidence` — calibrating numeral in `textTertiary` + tag.
/// - absent: `value == nil` (or non-finite) — "—" in tertiary + `absentReason` in footnote.
/// - loading: `value == nil && isLoading` — "—" without a reason; after 1 s a small spinner in the
///   unit slot.
///
/// VoiceOver: one element — "<label>, <value> <unit>, <confidence>, Carried · <day>, Updated <time>".
public struct MetricReadout: View {
    public enum Size: Sendable {
        /// 56 pt hero numeral (one per screen).
        case hero
        /// 34 pt numeral.
        case large

        var style: TelosNumeralStyle {
            switch self {
            case .hero:  return .hero
            case .large: return .numeralL
            }
        }
    }

    private let label: Text
    private let value: Double?
    private let unit: String?
    private let size: Size
    private let format: (Double) -> String
    private let confidence: TelosConfidence
    private let carriedFrom: Date?
    private let absentReason: Text?
    private let isLoading: Bool
    private let delta: TelosDelta?
    private let provenance: TelosProvenance?
    private let ink: Color

    @ScaledMetric private var numeralSize: CGFloat
    @State private var showsSpinner = false
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ label: LocalizedStringKey,
                value: Double?,
                unit: String? = nil,
                size: Size = .large,
                format: @escaping (Double) -> String = TelosFormat.integer,
                confidence: TelosConfidence = .solid,
                carriedFrom: Date? = nil,
                absentReason: Text? = nil,
                isLoading: Bool = false,
                delta: TelosDelta? = nil,
                provenance: TelosProvenance? = nil,
                ink: Color = TelosColor.textPrimary) {
        self.label = Text(label)
        self.value = value
        self.unit = unit
        self.size = size
        self.format = format
        self.confidence = confidence
        self.carriedFrom = carriedFrom
        self.absentReason = absentReason
        self.isLoading = isLoading
        self.delta = delta
        self.provenance = provenance
        self.ink = ink
        let style = size.style
        self._numeralSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    private var finiteValue: Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private var numeralInk: Color {
        if case .calibrating = confidence { return TelosColor.tertiaryInk(for: contrast) }
        if carriedFrom != nil { return TelosColor.textSecondary }
        return ink
    }

    private var unitFont: Font {
        let style = size.style
        let capped: CGFloat = min(numeralSize, style.size * style.cap)
        return TelosType.unitFont(forNumeralSize: capped)
    }

    public var body: some View {
        let tertiary = TelosColor.tertiaryInk(for: contrast)
        VStack(alignment: .leading, spacing: TelosSpace.xs) {
            label
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xs) {
                if let v = finiteValue {
                    TelosCountingNumeral(value: v, format: format)
                        .telosNumeral(size.style)
                        .foregroundStyle(numeralInk)
                    if let unit {
                        Text(verbatim: unit).font(unitFont).foregroundStyle(TelosColor.textSecondary)
                    }
                } else {
                    Text(verbatim: TelosType.absent)
                        .telosNumeral(size.style)
                        .foregroundStyle(tertiary)
                    if isLoading && showsSpinner {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            if let delta {
                TrendChip(text: delta.displayText, color: delta.color)
            }
            if !confidence.isSolid {
                ConfidenceTag(confidence)
            }
            if finiteValue != nil, let carriedFrom {
                Text("Carried · \(TelosFormat.dayLabel(carriedFrom))")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
            }
            if finiteValue == nil, !isLoading, let absentReason {
                absentReason
                    .font(TelosType.footnote)
                    .foregroundStyle(tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let provenance, !provenance.isEmpty {
                ProvenanceRow(provenance)
            }
        }
        .task(id: isLoading) {
            showsSpinner = false
            guard isLoading else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { showsSpinner = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: Text {
        var t: Text
        if let v = finiteValue {
            t = Text(verbatim: format(v))
            if let unit { t = t + Text(verbatim: " " + unit) }
        } else {
            t = AbsentValue.spoken(isLoading ? nil : absentReason)
        }
        if !confidence.isSolid {
            t = t + Text(verbatim: ", ") + confidence.label
        }
        if finiteValue != nil, let carriedFrom {
            t = t + Text(verbatim: ", ") + Text("Carried · \(TelosFormat.dayLabel(carriedFrom))")
        }
        if let updated = provenance?.updated {
            t = t + Text(verbatim: ", ") + Text("Updated \(TelosFormat.time(updated))")
        }
        return t
    }
}

// MARK: - Press style

/// The house press feedback (§4.8 `press`): scale 0.97 + opacity 0.88 over 0.12 s; under Reduce
/// Motion the opacity alone.
public struct TelosPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(pressed && !reduceMotion ? TelosMotion.pressScale : 1)
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .animation(TelosMotion.press, value: pressed)
    }
}

// MARK: - Chip (selectable)

/// A selectable capsule (§5.5): 32 pt visual / 44 pt hit, `subhead` semibold, 12 pt side padding.
/// Off: `surfaceInset` + 1 pt `line`. On: `textPrimary` fill + `canvas` text. Plays the `select` haptic.
public struct TelosChip: View {
    private let title: Text
    private let isOn: Bool
    private let action: () -> Void

    public init(_ title: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) {
        self.title = Text(title)
        self.isOn = isOn
        self.action = action
    }

    public init(verbatim title: String, isOn: Bool, action: @escaping () -> Void) {
        self.title = Text(verbatim: title)
        self.isOn = isOn
        self.action = action
    }

    public var body: some View {
        let shape = Capsule(style: .continuous)
        return Button {
            TelosHaptics.play(.select)
            action()
        } label: {
            title
                .font(TelosType.subhead.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isOn ? TelosColor.canvas : TelosColor.textPrimary)
                .padding(.horizontal, TelosSpace.m)
                .frame(minHeight: 32)
                .background(shape.fill(isOn ? TelosColor.textPrimary : TelosColor.surfaceInset))
                .overlay(shape.strokeBorder(isOn ? Color.clear : TelosColor.line, lineWidth: TelosStroke.line))
                .frame(minHeight: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - List row

/// A list row (§5.8): min height 52; optional 28 pt icon plate (`surfaceInset` + `line`, symbol 15 pt
/// `textSecondary`, or `iconTint` for metric rows); title `body`; optional subtitle `footnote`
/// secondary; trailing value `numeralS` + unit and/or a trailing accessory (toggle); chevron 13 pt
/// tertiary when it navigates. Rows group inside ONE card with zero card padding (the row carries its
/// own 12 pt insets); separate them with `TelosListDivider`. Wrap in a `Button` with
/// `TelosRowButtonStyle` for the pressed fill.
public struct TelosListRow<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let systemImage: String?
    private let iconTint: Color?
    private let value: String?
    private let unit: String?
    private let showsChevron: Bool
    private let trailing: Trailing

    public init(_ title: LocalizedStringKey,
                subtitle: LocalizedStringKey? = nil,
                systemImage: String? = nil,
                iconTint: Color? = nil,
                value: String? = nil,
                unit: String? = nil,
                showsChevron: Bool = false,
                @ViewBuilder trailing: () -> Trailing) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.value = value
        self.unit = unit
        self.showsChevron = showsChevron
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: TelosSpace.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(TelosType.glyphRow)
                    .foregroundStyle(iconTint ?? TelosColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous)
                            .fill(TelosColor.surfaceInset)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous)
                            .strokeBorder(TelosColor.line, lineWidth: TelosStroke.line)
                    )
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                title
                    .font(TelosType.body)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    subtitle
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TelosSpace.s)
            if let value {
                HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xxs) {
                    Text(verbatim: value)
                        .font(TelosType.numeralS)
                        .foregroundStyle(TelosColor.textPrimary)
                    if let unit {
                        Text(verbatim: unit)
                            .font(TelosType.scale)
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                }
            }
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, TelosSpace.m)
        .padding(.vertical, TelosSpace.rowVertical)
        .frame(maxWidth: .infinity, minHeight: TelosSpace.rowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

public extension TelosListRow where Trailing == EmptyView {
    init(_ title: LocalizedStringKey,
         subtitle: LocalizedStringKey? = nil,
         systemImage: String? = nil,
         iconTint: Color? = nil,
         value: String? = nil,
         unit: String? = nil,
         showsChevron: Bool = false) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, iconTint: iconTint,
                  value: value, unit: unit, showsChevron: showsChevron, trailing: { EmptyView() })
    }
}

/// The pressed-row treatment: the row fill steps to `surfaceInset` while pressed. No scale (a row is
/// part of a list, not a floating control).
public struct TelosRowButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? TelosColor.surfaceInset : Color.clear)
    }
}

/// The in-card row separator: 1 pt `lineSoft`, inset to the title (52 = 12 inset + 28 plate + 12 gap
/// for icon rows; pass 12 for rows without an icon).
public struct TelosListDivider: View {
    private let leadingInset: CGFloat

    public init(leadingInset: CGFloat = 52) {
        self.leadingInset = leadingInset
    }

    public var body: some View {
        Rectangle()
            .fill(TelosColor.lineSoft)
            .frame(height: TelosStroke.line)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Empty / error state

/// The empty and recoverable-error states (§5.13), sized to their content (no reserved height).
/// `.empty` (never had data): 20 pt symbol tertiary, `headline`, one `subhead` line, one secondary
/// action. `.error`: the symbol in `warning`, one line, a ghost action (pass "Try again").
public struct TelosEmptyState: View {
    public enum Style: Sendable {
        case empty
        case error
    }

    private let systemImage: String
    private let title: Text
    private let message: Text?
    private let actionTitle: Text?
    private let style: Style
    private let action: (() -> Void)?

    public init(systemImage: String,
                title: LocalizedStringKey,
                message: LocalizedStringKey? = nil,
                actionTitle: LocalizedStringKey? = nil,
                style: Style = .empty,
                action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = Text(title)
        self.message = message.map { Text($0) }
        self.actionTitle = actionTitle.map { Text($0) }
        self.style = style
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            Image(systemName: systemImage)
                .font(TelosType.glyphEmpty)
                .foregroundStyle(style == .error ? TelosColor.warning : TelosColor.textTertiary)
                .accessibilityHidden(true)
            title
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message {
                message
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                if style == .error {
                    Button(action: action) { actionTitle }
                        .buttonStyle(NoopGhostButtonStyle())
                } else {
                    Button(action: action) { actionTitle }
                        .buttonStyle(NoopSecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
