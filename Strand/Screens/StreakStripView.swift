import SwiftUI
import StrandAnalytics
import StrandDesign

// StreakStripView.swift — four numbers, each with a plain status mark.
//
// SwiftUI twin of the Android `StreakCard`. The flame is the whole point: a digit is information, a lit
// flame is something you do not want to put out, and that difference is why streaks work at all.
//
// THE MARK SAYS WHETHER TODAY IS BANKED. A filled check = today already counts. An open ring = the run is
// going but today is not secured yet, which is a nudge that costs no words. Faint ring = nothing running.
// A streak UI that looks identical whether or not today is done is a streak UI that cannot tell you the one
// thing you open it for.
//
// NO SECTION HEADER, and the strip is as short as four flames allow.
//
// THE LABEL IS THE RULE, not the metric's name: "consistency > 80%" says what holds the flame lit.
//
// TELOS 2.0 + DECISION 19 (clinical restraint): a compact glass strip of neutral marks — no amber flames,
// no glow, nothing that loops. The glyph's fill and ink carry "secured / running / none". COST: static.

struct StreakStripView: View {
    let streaks: [Streak]

    var body: some View {
        if !streaks.isEmpty {
            StrandCard(padding: TelosSpace.s, cornerRadius: TelosRadius.tile) {
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

    private var lit: Bool { streak.days > 0 }

    private var tint: Color {
        if streak.todaySecured { return TelosColor.textPrimary }
        if lit { return TelosColor.textSecondary }
        return TelosColor.textTertiary.opacity(0.4)
    }

    private var symbol: String {
        if streak.todaySecured { return "checkmark.circle.fill" }
        return "circle"
    }

    var body: some View {
        VStack(spacing: TelosSpace.xxs) {
            // The mark and the count sit on ONE line: the strip is meant to be glanced at, not read.
            HStack(spacing: TelosSpace.xs) {
                Image(systemName: symbol)
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(tint)
                Text(verbatim: lit ? "\(streak.days) d" : TelosType.absent)
                    .font(TelosType.numeralXS)
                    .foregroundStyle(lit ? TelosColor.textPrimary : TelosColor.textTertiary)
                    .lineLimit(1)
            }
            Text(label)
                .telosScale()
                .foregroundStyle(TelosColor.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: TelosSpace.hitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The rule, spelled the same way the Android strings are.
    private var label: String {
        switch streak.kind {
        // Says the rule itself, so the flame can be read without a legend: both ends of the night,
        // each within half an hour of the night before.
        case .sleepConsistency: return "bed & wake ±30m"
        case .sleepDebt: return "debt < 1h"
        case .stressTime: return "stress < 1"
        case .journal: return "journal"
        }
    }

    private var accessibilityLabel: String {
        guard lit else { return "\(label): no streak yet" }
        let secured = streak.todaySecured ? "today is secured" : "today is not secured yet"
        return "\(label): \(streak.days) days, \(secured)"
    }
}
