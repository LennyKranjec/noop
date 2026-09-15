import SwiftUI
import StrandAnalytics
import StrandDesign

// StreakStripView.swift — three numbers, each a flame.
//
// SwiftUI twin of the Android `StreakCard`. The flame is the whole point: a digit is information, a lit
// flame is something you do not want to put out, and that difference is why streaks work at all.
//
// THE FLAME SAYS WHETHER TODAY IS BANKED. Lit and breathing = today already counts. Dim and still = the
// streak is running but today is not secured yet, which is a nudge that costs no words. Cold grey =
// nothing running. A streak UI that looks identical whether or not today is done is a streak UI that
// cannot tell you the one thing you open it for.
//
// NO SECTION HEADER, and the strip is as short as three flames allow. A heading reading "Streaks" over
// three flames labelled with their own rules is a label for a label, and it cost the strip more height
// than the content it introduced.
//
// THE LABEL IS THE RULE, not the metric's name. "Sleep" says which number; "consistency > 80%" says what
// holds the flame lit, which is the only thing a streak label has to answer.

/// The strip's own inset. Tight: the flames are the content, and the card is a frame around them.
private let streakStripPadding: CGFloat = 10

struct StreakStripView: View {
    let streaks: [Streak]

    var body: some View {
        if !streaks.isEmpty {
            StrandCard(padding: streakStripPadding, cornerRadius: 16) {
                HStack(spacing: 0) {
                    ForEach(streaks, id: \.kind) { streak in
                        StreakFlame(streak: streak)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct StreakFlame: View {
    let streak: Streak

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    @State private var flickering = false

    private var lit: Bool { streak.days > 0 }

    /// Only a SECURED flame breathes. An animation on an at-risk streak would read as "all is well",
    /// which is the opposite of what an unsecured day means. The app-wide motion gate stills it too —
    /// battery saver and quiet-motion have to be able to stop an animation that would otherwise run for
    /// as long as the strip is on screen.
    private var breathes: Bool { streak.todaySecured && !motion.poseStill(reduceMotion) }

    private var tint: Color {
        if streak.todaySecured { return StrandPalette.statusWarning }
        if lit { return StrandPalette.statusWarning.opacity(0.45) }
        return StrandPalette.textTertiary.opacity(0.35)
    }

    var body: some View {
        VStack(spacing: 1) {
            // The flame and the count sit on ONE line. Stacked they cost three rows of height for two
            // figures, and the strip is meant to be glanced at rather than read.
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(tint)
                    .scaleEffect(breathes && flickering ? 1.06 : 0.92)
                    .opacity(lit ? 1 : 0.6)
                Text(lit ? "\(streak.days) d" : "-")
                    .font(StrandFont.footnote.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(lit ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Text(label)
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .onAppear {
            guard breathes else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                flickering = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The rule, spelled the same way the Android strings are.
    private var label: String {
        switch streak.kind {
        case .sleepConsistency: return "consistency > 80%"
        case .sleepDebt: return "debt < 1h"
        case .stressTime: return "stress < 6h"
        }
    }

    private var accessibilityLabel: String {
        guard lit else { return "\(label): no streak yet" }
        let secured = streak.todaySecured ? "today is secured" : "today is not secured yet"
        return "\(label): \(streak.days) days, \(secured)"
    }
}
