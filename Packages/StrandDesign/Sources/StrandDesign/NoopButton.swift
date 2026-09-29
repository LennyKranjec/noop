import SwiftUI

// MARK: - NoopButton — the unified button system (Telos 2.0 values, §5.10)
//
// One button, four kinds, no glow. Beauty comes from a crisp filled accent, honest
// surface fills, restrained spacing and a subtle press — never neon, bloom or a halo.
// Every colour is a token from `StrandPalette`; every dimension reads off `NoopMetrics`.
//
// Two front doors:
//   • `NoopButton("Save", kind: .primary) { … }`     — the convenience view.
//   • `Button("Save") { … }.buttonStyle(NoopButtonStyle(.primary))`  — adopt on an
//     existing Button (e.g. a Menu/role button) without rewriting it.
//
// Labels are sentence-case (never ALL CAPS), single line, optical-centred with the
// optional leading icon as one unit, and degrade gracefully under Reduce Motion (the
// press scale drops; only the dim remains).

/// The four button roles. Colour + emphasis differ; geometry is identical across all four.
public enum NoopButtonKind: Sendable {
    /// Filled accent, `onAccent` label — the one primary action on a screen.
    case primary
    /// `surfaceInset` fill, primary-text label, 1 pt `line` edge — secondary actions.
    case secondary
    /// No fill, accent label — low-emphasis / inline actions.
    case tertiary
    /// The secondary shape with `critical` ink (V2) — destructive / irreversible actions; confirm via a system dialog.
    case destructive
}

// MARK: - Shared geometry / resolved styling

/// Fixed geometry shared by the convenience view and the ButtonStyle so the two paths
/// are pixel-identical. The single source of truth for button shape.
public enum NoopButtonMetrics {
    /// Button height (V2 §5.10: 50). A floor — the label may grow it at large text sizes.
    public static let height: CGFloat = 50
    /// Corner radius — the V2 `control` radius (14 → 12).
    public static let cornerRadius: CGFloat = TelosRadius.control
    /// Horizontal label inset.
    public static let hPadding: CGFloat = 18
    /// Spacing between a leading icon and the label.
    public static let iconSpacing: CGFloat = 8
    /// Label tracking — none in V2 (SF Pro `headline` is tracked by the system).
    public static let tracking: CGFloat = 0
    /// Apple's minimum touch target. The button never reports a hit area below this.
    public static let minHitTarget: CGFloat = TelosSpace.hitTarget
    /// Pressed scale — the `press` token (0.97). Reduce Motion collapses this to 1 (dim only).
    public static let pressedScale: CGFloat = TelosMotion.pressScale
    /// Pressed dim — the `press` token's opacity (0.82 → 0.88), applied in BOTH motion modes.
    public static let pressedOpacity: Double = TelosMotion.pressOpacity
    /// Disabled dim for non-primary kinds (0.4 → 0.45, `TelosOpacity.disabled`). A disabled PRIMARY
    /// instead draws the `lineStrong` fill with a `textDisabled` label.
    public static let disabledOpacity: Double = TelosOpacity.disabled
}

/// Resolves a `NoopButtonKind` to its concrete fill / label / border tokens. Internal
/// so the fill model stays in one place; both the style and the view read from here.
struct NoopButtonAppearance {
    let fill: Color?          // nil = no fill (tertiary)
    let label: Color
    let border: Color?        // nil = no hairline edge
    /// Whether a disabled state is drawn by fading the whole button (every kind but primary, which
    /// swaps to its own disabled fill and label instead).
    let dimsWhenDisabled: Bool

    /// V2 (§5.10): primary = accent fill + `onAccent`; secondary = `surfaceInset` + `line` +
    /// `textPrimary`; tertiary = accent label only; destructive = the SECONDARY shape with `critical`
    /// ink (confirm through a system dialog at the call site).
    init(_ kind: NoopButtonKind, enabled: Bool = true) {
        switch kind {
        case .primary:
            fill = enabled ? StrandPalette.accent : TelosColor.lineStrong
            label = enabled ? StrandPalette.goldDeepText : TelosColor.textDisabled
            border = nil
            dimsWhenDisabled = false
        case .secondary:
            fill = TelosColor.surfaceInset
            label = StrandPalette.textPrimary
            border = TelosColor.line
            dimsWhenDisabled = true
        case .tertiary:
            fill = nil
            label = StrandPalette.accent
            border = nil
            dimsWhenDisabled = true
        case .destructive:
            fill = TelosColor.surfaceInset
            label = TelosColor.critical
            border = TelosColor.line
            dimsWhenDisabled = true
        }
    }
}

// MARK: - The crisp background (no glow, ever)

/// The flat, glow-free button background: a filled (or unfilled) rounded rect with an
/// optional 1 pt edge. No shadow, no blur halo, no additive bloom — restraint only.
private struct NoopButtonBackground: View {
    let appearance: NoopButtonAppearance

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous)
        ZStack {
            if let fill = appearance.fill {
                shape.fill(fill)
            }
            if let border = appearance.border {
                shape.strokeBorder(border, lineWidth: TelosStroke.line)
            }
        }
    }
}

// MARK: - ButtonStyle (adopt on any existing Button)

/// Apply the NOOP button look to ANY `Button` — e.g. a role/`Menu` button you can't
/// replace with `NoopButton`. Honours Reduce Motion: the press scale drops to a dim-only
/// state. Pixel-identical to `NoopButton` since both share `NoopButtonMetrics`/appearance.
public struct NoopButtonStyle: ButtonStyle {
    private let kind: NoopButtonKind
    private let fullWidth: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: NoopButtonKind = .primary, fullWidth: Bool = false) {
        self.kind = kind
        self.fullWidth = fullWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        let appearance = NoopButtonAppearance(kind, enabled: isEnabled)
        let pressed = configuration.isPressed
        // Reduce Motion: no scale, dim only. Otherwise subtle scale + dim (the `press` token).
        let scale: CGFloat = (pressed && !reduceMotion) ? NoopButtonMetrics.pressedScale : 1
        let pressedOpacity: Double = pressed ? NoopButtonMetrics.pressedOpacity : 1
        let disabledOpacity: Double = (isEnabled || !appearance.dimsWhenDisabled) ? 1 : NoopButtonMetrics.disabledOpacity

        return configuration.label
            .labelStyle(.titleAndIcon)
            .font(TelosType.headline)
            .tracking(NoopButtonMetrics.tracking)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .foregroundStyle(appearance.label)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, NoopButtonMetrics.hPadding)
            .frame(minHeight: NoopButtonMetrics.height)
            .contentShape(Rectangle())
            .background(NoopButtonBackground(appearance: appearance))
            .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
            .opacity(pressedOpacity * disabledOpacity)
            .scaleEffect(scale)
            .animation(TelosMotion.press, value: pressed)
    }
}


// MARK: - NoopButton (the convenience view)

/// The unified button. A title (sentence-case `LocalizedStringKey`), an optional leading
/// SF Symbol, a `NoopButtonKind`, an optional `fullWidth`, and an action. Crisp, flat,
/// glow-free; subtle press; 44pt hit floor; Reduce-Motion aware.
///
/// ```swift
/// NoopButton("Save changes", systemImage: "checkmark", kind: .primary, fullWidth: true) {
///     save()
/// }
/// ```
public struct NoopButton: View {
    private let title: LocalizedStringKey
    private let systemImage: String?
    private let kind: NoopButtonKind
    private let fullWidth: Bool
    private let action: () -> Void

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        kind: NoopButtonKind = .primary,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.fullWidth = fullWidth
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            // The ButtonStyle owns the chrome (fill / colour / press / padding). The label here is
            // just the icon + word as one centred unit at the exact 8pt token spacing. When there's
            // no icon the HStack holds a single Text, so the word sits dead-centre with no phantom gap.
            HStack(spacing: NoopButtonMetrics.iconSpacing) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.medium)  // optically centres to the cap height of the label
                }
                Text(title)
            }
        }
        .buttonStyle(NoopButtonStyle(kind, fullWidth: fullWidth))
    }
}

#if DEBUG
#Preview("NoopButton") {
    ScrollView {
        VStack(spacing: NoopMetrics.rowSpacing) {
            NoopButton("Primary action", systemImage: "checkmark", kind: .primary) {}
            NoopButton("Secondary action", systemImage: "square.and.arrow.up", kind: .secondary) {}
            NoopButton("Tertiary action", kind: .tertiary) {}
            NoopButton("Delete recording", systemImage: "trash", kind: .destructive) {}

            Divider().overlay(StrandPalette.hairline)

            NoopButton("Full-width primary", systemImage: "bolt.fill", kind: .primary, fullWidth: true) {}
            NoopButton("Full-width secondary", kind: .secondary, fullWidth: true) {}

            // Adopting the style on a vanilla Button.
            Button("Adopted via NoopButtonStyle") {}
                .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))

            NoopButton("Disabled", kind: .primary) {}
                .disabled(true)
        }
        .screenPadding()
        .padding(.vertical, NoopMetrics.space6)
    }
    .frame(width: 380, height: 560)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
