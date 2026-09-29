import SwiftUI

// MARK: - Card surface (Telos 2.0) + StrandCard
//
// The card surface (§5.1): ONE flat `surface` fill, continuous corners (radius `card` 20) and a single
// 1 pt `line` edge — NO shadow in either scheme, no gradient, no wash. A `tint` draws only a 3 pt top
// edge in the tint at 0.6. `.frostedCardSurface(tint:…)` is the one place the look lives so StrandCard /
// NoopCard / ad-hoc surfaces all share it.
//
// Card transparency comes from the ENVIRONMENT (`\.telosCardOpacity`, injected once at the app root by
// `.telosCardOpacityFromPreferences()`), not from a per-card `@AppStorage`: 1.x subscribed every card on
// screen to UserDefaults, so every write anywhere re-evaluated every card. The name "frosted" is kept
// for API stability; there is no material or blur.

public extension View {
    /// Apply the card surface as a background. `tint` draws the 3 pt identity top edge; nil is the plain
    /// flat surface. `washStrength` scales the edge's opacity (kept for API stability).
    func frostedCardSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        washStrength: Double = 1.0
    ) -> some View {
        background(FrostedCardSurface(tint: tint, cornerRadius: cornerRadius, washStrength: washStrength))
    }
}

/// The card background fill and edge. Standalone so it can be a `.background { }` (animation never
/// reaches the card's content subtree — #104). No drop shadow.
public struct FrostedCardSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var washStrength: Double
    /// Card transparency (0.55…1), set once at the root. Reading the environment invalidates this view
    /// only when that value changes — never on an unrelated UserDefaults write.
    @Environment(\.telosCardOpacity) private var cardOpacity

    public init(tint: Color? = nil, cornerRadius: CGFloat = NoopVisualStyle.cardRadius, washStrength: Double = 1.0) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    public var body: some View {
        NoopPanelSurface(
            tint: tint?.opacity(max(0, min(1, washStrength))),
            cornerRadius: cornerRadius,
            elevated: false,
            surfaceOpacity: TelosOpacity.clampCardOpacity(cardOpacity)
        )
    }
}

// MARK: - StrandCard (§9.4 Cards)
//
// The card container — the V2 flat surface; the PUBLIC API is unchanged (padding, cornerRadius, tint,
// content). Defaults hug content (coordinator decision 11): padding 12, no minimum height. Keeps the
// macOS hover lift via `.strandCardHover()` (iOS draws none).

public struct StrandCard<Content: View>: View {

    public var padding: CGFloat
    public var cornerRadius: CGFloat
    public var tint: Color?
    @ViewBuilder public var content: () -> Content

    public init(
        padding: CGFloat = TelosSpace.cardPadding,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(tint: tint, cornerRadius: cornerRadius)
            .strandCardHover(cornerRadius: cornerRadius)
    }
}

// MARK: - Hover lift modifier

/// The pointer hover treatment: a `lineStrong` edge plus a small lift. macOS ONLY — V2 draws no hover
/// on iOS (§4.6: cards cast no shadow; an iPad pointer must not make a card float).
public struct StrandCardHover: ViewModifier {
    public var cornerRadius: CGFloat
    @State private var hovering = false

    public init(cornerRadius: CGFloat = NoopVisualStyle.cardRadius) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        #if os(macOS)
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: TelosStroke.line)
                    .opacity(hovering ? 1 : 0)
            )
            .shadow(
                color: hovering ? TelosElevation.raised.shadowColor : .clear,
                radius: hovering ? TelosElevation.raised.radius : 0,
                x: 0,
                y: hovering ? TelosElevation.raised.yOffset : 0
            )
            .offset(y: hovering ? -1 : 0)
            .animation(TelosMotion.select, value: hovering)
            .onHover { hovering = $0 }
        #else
        content
        #endif
    }
}

public extension View {
    /// Apply the Strand card hover lift (macOS only; a no-op on iOS and watchOS).
    func strandCardHover(cornerRadius: CGFloat = NoopVisualStyle.cardRadius) -> some View {
        modifier(StrandCardHover(cornerRadius: cornerRadius))
    }
}

// MARK: - Touch press feedback (iOS) — the V2 `press` token.
//
// `.onHover` never fires on a touchscreen, so tappable cards/rows feel dead on iPhone. This gives the
// house press state (§4.8 `press`: scale 0.97 + opacity 0.88, easeOut 0.12 s) plus a `lineStrong` edge;
// under Reduce Motion the scale is dropped and the opacity alone carries the press. Exposed two ways —
// a ButtonStyle for Button/NavigationLink-as-card (the `.plain` replacement), and a `.strandPressable()`
// modifier for `.onTapGesture`-driven cards.

/// Drop-in replacement for `.buttonStyle(.plain)` on full-card Buttons / NavigationLinks.
public struct StrandPressableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = TelosMotion.pressScale) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: TelosStroke.line)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(TelosMotion.press, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Backs `.strandPressable()` — a press-down state for cards driven by `.onTapGesture`
/// (no Button). A 0-distance drag tracks the finger; @GestureState auto-resets on release
/// or when a parent scroll claims the gesture.
public struct StrandPressableModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = TelosMotion.pressScale) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(pressed ? TelosMotion.pressOpacity : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: TelosStroke.line)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(TelosMotion.press, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
    }
}

public extension View {
    /// Subtle touch press-down feedback for a tappable card/row that uses `.onTapGesture`
    /// (not a Button). For Buttons/NavigationLinks, use `StrandPressableButtonStyle` instead.
    func strandPressable(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = TelosMotion.pressScale) -> some View {
        modifier(StrandPressableModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

#if DEBUG && !os(watchOS)
#Preview("StrandCard") {
    VStack(spacing: 16) {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep performance").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("87").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text("%").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
                }
                Text("7h 42m asleep · 92% efficiency")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        StrandCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resting HR").strandOverline()
                    Text("51 bpm").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Sparkline(values: (0..<30).map { i -> Double in 50 + 4 * sin(Double(i) / 5) })
                    .frame(width: 120, height: 40)
            }
        }
        Text("Hover the cards to see the lift.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(28)
    .frame(width: 420, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
