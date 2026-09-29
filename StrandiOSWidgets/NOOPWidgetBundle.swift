import WidgetKit
import SwiftUI

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
