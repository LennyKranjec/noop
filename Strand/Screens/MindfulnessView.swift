import SwiftUI

// MindfulnessView.swift — Focus.
//
// SwiftUI twin of the Android `MindfulnessScreen`. The Stress monitor, with the meditation log on top.
//
// WHAT WAS HERE BEFORE IS GONE on the Android lane: that tab was a LAYOUT PREVIEW, five sub-tabs of
// hand-written fixtures that read as features and were backed by nothing. The wearer asked for it to
// become the stress tab plus a meditation log, and a screen of invented numbers is exactly what this
// project refuses to ship, so it was deleted rather than kept alongside. This side never had the
// fixture screen; it gets the replacement directly.
//
// IT REUSES `StressView` rather than copying it. A literal clone would be ~1,700 duplicated lines whose
// two halves drift the first time either is touched — a fix landing on one tab and silently not the
// other. The heading, the subtitle and the leading card are the entire difference.

struct MindfulnessView: View {
    var body: some View {
        StressView(
            title: "Focus",
            subtitle: "Sit, and what the sitting does to the rest of it"
        ) {
            MeditationCardView()
        }
    }
}
