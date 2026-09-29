#if os(iOS)
import SwiftUI
import AppIntents
import StrandDesign

/// Surfaces NOOP's already-registered App Intents (see StrandiOS/System/NOOPAppIntents.swift) in the
/// UI so users discover them. `NOOPShortcuts` auto-registers "Buzz Strap" and "Mark a Moment" with
/// Siri/Spotlight/Shortcuts, but nothing in-app advertised them — this is the iOS analogue of the
/// Mac's strap-double-tap-runs-a-Shortcut feature. Apple's `SiriTipView`/`ShortcutsLink` (iOS 16+)
/// do exactly that: tip the user on the spoken phrase and deep-link into the Shortcuts app, scoped to
/// this app automatically.
struct SiriShortcutsSettingsView: View {
    /// `SiriTipView` draws its own ✕ and dismisses by writing `false` into the binding it was given.
    /// Both of these were handed `.constant(true)`, so that write went nowhere and the ✕ did nothing —
    /// a visible control with no effect. Real state now backs it.
    ///
    /// DELIBERATELY `@State`, NOT `@AppStorage`: these two tips are the entire content of this screen,
    /// so a persisted dismissal would leave a wearer who tapped ✕ once looking at a settings page with
    /// nothing on it and no way to bring the phrases back. Session-scoped means the ✕ does exactly what
    /// it looks like it does while the screen is open, and the page is whole again next time.
    @State private var buzzTipVisible = true
    @State private var momentTipVisible = true

    var body: some View {
        ScreenScaffold(title: "Siri & Shortcuts",
                       subtitle: "Run NOOP actions hands-free.") {
            tips
            shortcutsCard
        }
    }

    private var tips: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Ready-made actions")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Buzz your strap or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap / automation. No setup needed.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                SiriTipView(intent: BuzzStrapIntent(), isVisible: $buzzTipVisible)
                    .siriTipViewStyle(.dark)
                SiriTipView(intent: MarkMomentIntent(), isVisible: $momentTipVisible)
                    .siriTipViewStyle(.dark)
            }
        }
    }

    private var shortcutsCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Build your own")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz the strap.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ShortcutsLink()
            }
        }
    }
}
#endif
