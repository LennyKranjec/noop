import WidgetKit
import SwiftUI
import StrandDesign

/// The widget extension entry point. Bundles the glanceable widget, the live-HR Live Activity,
/// the K10 Coach brief widget (stored morning brief on Lock Screen / Home Screen), and the
/// heart-rate trace widget (#1957), the stress curve widget (#2040), and the level tile.
///
/// Each widget has its OWN kind, so a wearer adds exactly the ones they want and the app can reload one
/// without rebuilding the others' timelines.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPLiveActivity()
        CoachBriefWidget()
        HeartRateWidget()
        StressWidget()
        TelosStripWidget()
        WaterWidget()
        LevelWidget()
    }
}

// MARK: - The Telos ground (shared by every Home-Screen widget in this extension)

/// The Telos 2.0 ground behind a Home-Screen widget: near-black `canvas` falling to `canvasDeep`, with
/// the reference's faint green-teal depth as a wash from the top-leading corner (DESIGN_V2 "VISUAL
/// DIRECTION"). Light mode gets the same tokens' pale pair, so nothing here branches on the scheme.
///
/// Lives here because every widget file uses it and the extension has no other shared UI file; the
/// widget target cannot see the app's `NoopPanelSurface`.
///
/// Cost: two static gradient fills, rasterised once per timeline entry (a widget is a still picture).
/// No blur, no material, no animation.
struct TelosWidgetGround: View {
    var body: some View {
        ZStack {
            TelosColor.groundGradient
            // The bioluminescent depth: `glassGlow` is mint at 8 % (dark) / 4 % (light), so this is a
            // whisper, not a spotlight. Cost: one radial fill.
            RadialGradient(colors: [TelosColor.glassGlow, Color.clear],
                           center: .topLeading, startRadius: 0, endRadius: 260)
        }
    }
}
