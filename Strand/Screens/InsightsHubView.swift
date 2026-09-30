import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - What moves you (the Insights hub)
//
// The n-of-1 "what goes with YOUR nights" surface — pure association on the wearer's own logged nights, never
// advice, diagnosis or cause.
//
// HEALTH_V2 (PROGRESS package, 2.0):
//   • H12 — the ranked feed is the habit model (`HabitAnalysisStore` → `HabitAssociation` rows), the same
//     report the Habits hub and the coach's habit summary read. `EffectRanker` (best of three uncorrected
//     lags, mislabelled lags) stays in StrandAnalytics for parity but is no longer displayed anywhere here.
//   • H11 — the alcohol / caffeine dose-response cards and the evening "damage forecast" are gone: nothing
//     writes the dose rows they read, so every dose was 1 and the "personal" slope was the population prior.
//     They come back only when a dose writer exists (not in 2.0).
//   • Every row carries an ASSOCIATION tag, or TRIAL-TESTED + the verdict word when a finished trial covers
//     the habit — only a trial may say "helped".
//
// COST: static. One `refreshIfDue` per data refresh (the store itself runs at most once a day).

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @ObservedObject private var analysis = HabitAnalysisStore.shared
    @ObservedObject private var trials = HabitTrialStore.shared

    var body: some View {
        ScreenScaffold(title: "Insights",
                       subtitle: "Patterns in your own data: association, not cause.",
                       lazy: true) {
            VStack(alignment: .leading, spacing: TelosSpace.sectionGap) {
                moversSection
                trialsEntry
                methodNote
            }
        }
        .task(id: repo.refreshSeq) { await analysis.refreshIfDue(repo: repo) }
    }

    // MARK: - What moves you (habit associations)

    @ViewBuilder
    private var moversSection: some View {
        VStack(alignment: .leading, spacing: TelosSpace.sectionHeaderGap) {
            SectionHeader("What moves you", overline: "Habits · your nights")
            if let report = analysis.report {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "calendar")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.teal)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(report.windowStart) → \(report.windowEnd)")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                    Spacer(minLength: 0)
                    Text(verbatim: "\(report.rows.count) HABITS")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textTertiary)
                }
                if report.rows.isEmpty {
                    StrandCard {
                        TelosEmptyState(systemImage: "wand.and.sparkles",
                                        title: "Not enough nights yet",
                                        message: "Each habit needs nights both with and without it before its pattern can be read. Keep logging in the journal and the Tonight log.")
                    }
                } else {
                    ForEach(Array(report.rows.enumerated()), id: \.element.habit) { index, row in
                        HabitAssociationCard(row: row, tested: trialCovering(row.habit))
                            .staggeredAppear(index: index)
                    }
                }
            } else {
                StrandCard {
                    AbsentValue(reason: "The habit analysis runs once a day, after the morning's data lands.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// The newest finished trial that tested `habit` with a verdict.
    private func trialCovering(_ habit: HabitId) -> HabitTrialRecord? {
        trials.finished.first { $0.entry?.linkedHabits.contains(habit) == true && $0.result?.verdict != nil }
    }

    // MARK: - Into the trials (the only thing that can say "helped")

    @ViewBuilder
    private var trialsEntry: some View {
        #if os(iOS)
        NavigationLink {
            HabitsHubView()
        } label: {
            StrandCard(tint: TelosColor.teal) {
                HStack(spacing: TelosSpace.m) {
                    Image(systemName: "flask")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(TelosColor.teal)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(TelosColor.teal.opacity(TelosOpacity.wash)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        PGOverline("Habit trials", ink: TelosColor.teal)
                        Text("A pattern is not proof. Test one habit ON and OFF on your own nights, and get a verdict with its interval.")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: TelosSpace.s)
                    Image(systemName: "chevron.right")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityElement(children: .combine)
        #endif
    }

    // MARK: - Method / honesty note

    private var methodNote: some View {
        StrandCard {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                PGOverline("How to read this")
                Text(String(localized: "Everything here is a pattern in your own logged nights: an estimate with its interval against a change big enough to matter, never a cause or a diagnosis. Nights without an entry are left out, not counted as a \u{201C}no\u{201D}. Only a finished trial can say a habit helped. Approximations, not WHOOP\u{2019}s scores; not a medical device."))
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers (kept: Today's classic view maps confidence through this)

    /// Map the engine's ScoreConfidence tier to the design-system ScoreState pill.
    static func scoreState(_ c: ScoreConfidence) -> ScoreState {
        switch c {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func hubPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights Hub") {
    InsightsHubView()
        .environmentObject(hubPreviewRepo())
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}
#endif
