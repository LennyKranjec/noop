#if os(iOS)
import SwiftUI
import StrandDesign

// TelosTabBar.swift — the floating faux-glass tab bar of the reference (`docs/design-ref/telos-v2-today.jpg`):
// Home · Biometrics · Focus · System · More, the selected item lit by the glowing pill.
//
// IT FULLY REPLACES THE SYSTEM BAR, which the shell hides (`.toolbar(.hidden, for: .tabBar)`) — so every job
// the platform bar did is done here, explicitly:
//   • selection, and a tap on the ALREADY-selected item → the shell's reselect (pop to root / scroll to top);
//   • the Focus item's "today's meditation is still open" mark (`.badge` only works on system tab items, so
//     it is drawn) with the SAME VoiceOver wording the system item carried, and its gentle symbol pulse;
//   • the System item's working glyph and its finished-elsewhere bounce;
//   • content clearance: the shell insets every tab's safe area by `TelosTabBarMetrics.contentInset`, so a
//     screen's last card and the Coach's input row are never hidden under the bar;
//   • the keyboard: the shell hides the bar (and drops the inset) while the keyboard is up, as the system bar
//     is hidden behind it;
//   • Dynamic Type: the bar's own text is capped at xLarge (it is chrome in a fixed-height bar, as the system
//     bar's is), and a long-press shows the item in the Large Content Viewer — the platform's answer for
//     exactly this kind of bar.
//
// COST (§2.1 rule 8): static. Faux glass = an opaque-enough ground fill + the translucent glass fill + the
// gradient hairline + the top glow — no material, no blur. ONE shadow on the bar (a small static chrome
// element) and the glowing pill's own one small shadow: two of the three allowed on screen. The Focus pulse
// and the System bounce are the platform's symbol effects (nothing of ours loops); the pulse runs only while
// the caller says it may (`pulsing` is false in the background, under Reduce Motion / Low Power / quiet
// motion, and while Focus is the open tab).

enum TelosTabBarMetrics {
    /// The bar's own height.
    static let height: CGFloat = 64
    /// Gap between the bar and the bottom safe-area edge (the home indicator).
    static let bottomGap: CGFloat = 6
    /// Gap between the bar and the screen's side edges.
    static let sideInset: CGFloat = 12
    /// The bar's corner radius — large and soft, as the reference.
    static let radius: CGFloat = 30
    /// How much bottom safe area the shell reserves on every tab so content clears the bar.
    static let contentInset: CGFloat = height + bottomGap
}

/// One item of the bar.
struct TelosTabItem: Identifiable {
    let tag: Int
    let title: LocalizedStringKey
    let systemImage: String
    /// What VoiceOver reads instead of the title (the Focus item while its mark is up). nil = the title.
    var a11yLabel: LocalizedStringKey? = nil
    /// Draw the attention mark ("!") in the icon's corner.
    var showsMark: Bool = false
    /// Breathe the symbol (the platform `.pulse`) while true.
    var pulsing: Bool = false
    /// Bounce the symbol once each time this changes (the System item's finished-elsewhere pop).
    var bounceTrigger: Int = 0

    var id: Int { tag }
}

struct TelosTabBar: View {
    let items: [TelosTabItem]
    let selected: Int
    /// Called with the tapped tag — including the already-selected one (the shell decides reselect).
    let onSelect: (Int) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TelosTabBarMetrics.radius, style: .continuous)
        HStack(spacing: TelosSpace.xxs) {
            ForEach(items) { item in
                TelosTabButton(item: item, isSelected: item.tag == selected) {
                    TelosHaptics.play(.select, action: "tab.\(item.tag)")
                    onSelect(item.tag)
                }
            }
        }
        .padding(.horizontal, TelosSpace.xs)
        .frame(height: TelosTabBarMetrics.height)
        .background {
            // Faux glass over live content: the ground at 94 % keeps the labels legible over whatever
            // scrolls beneath (there is no blur to do that job), the glass fill + top glow give it the
            // reference's lift, the gradient hairline its luminous edge.
            shape.fill(TelosColor.canvasDeep.opacity(0.94))
                .overlay(shape.fill(TelosColor.glassFill))
                .overlay(shape.fill(TelosColor.glassTopGlow))
                .overlay(shape.strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
                .telosElevation(.raised)
        }
        .padding(.horizontal, TelosTabBarMetrics.sideInset)
        .padding(.bottom, TelosTabBarMetrics.bottomGap)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .contain)
    }
}

private struct TelosTabButton: View {
    let item: TelosTabItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text(item.a11yLabel ?? item.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityShowsLargeContentViewer {
            Label(item.title, systemImage: item.systemImage)
        }
    }

    @ViewBuilder private var label: some View {
        let content = VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                    .symbolEffect(.pulse, options: .repeating, isActive: item.pulsing)
                    .symbolEffect(.bounce, value: item.bounceTrigger)
                    .frame(height: 22)
                if item.showsMark {
                    mark.offset(x: 7, y: -4)
                }
            }
            Text(item.title)
                .font(.system(.caption2, design: .default, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isSelected ? TelosColor.mint : TelosColor.textSecondary)
        .padding(.horizontal, TelosSpace.s)
        .padding(.vertical, TelosSpace.xs)

        if isSelected {
            // The glowing pill of the reference. `padded: false`: the item already sizes itself.
            content.telosGlowingPill(TelosColor.mint, isActive: true, padded: false)
        } else {
            content.frame(minHeight: TelosSpace.hitTarget)
        }
    }

    /// The attention mark: the system badge's job, drawn. Hidden from VoiceOver — the item's label says it.
    private var mark: some View {
        Text(verbatim: "!")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(TelosColor.onAccent)
            .frame(width: 14, height: 14)
            .background(Circle().fill(TelosColor.critical))
            .accessibilityHidden(true)
    }
}
#endif
