import SwiftUI
import StrandAnalytics
import StrandDesign

// QuestViews.swift — the clock, the strip and the review sheet.
//
// SwiftUI twins of the Android `QuestCountdown` / `QuestStrip` / `QuestReviewCard`. The pop-up — the
// part that interrupts — is `QuestPopupView` in its own file.

// MARK: - The clock on a quest
//
// A directive with no deadline is a suggestion. The countdown is most of what makes the difference:
// "8,000 steps" is advice; "8,000 steps in 14:22:07" is a quest.
//
// IT TICKS FROM THE WALL CLOCK, not from a counter it increments. A view that counts its own seconds
// drifts whenever the phone sleeps or the frame budget slips, and this is the one number on the screen
// the wearer can check against their own clock.
//
// The digits are monospaced-by-construction: `Quest.formatRemaining` zero-pads every field, so the row
// keeps its width as the numbers change rather than jittering once a second.

/// Under this much left, the clock turns to the warning colour. An hour is enough to still act.
private let questUrgentMs: Int64 = 60 * 60 * 1000

struct QuestCountdownView: View {
    let quest: Quest
    var fontSize: CGFloat = 18
    var showIcon = true

    @State private var remaining: Int64 = 0

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var tint: Color {
        if remaining <= 0 { return StrandPalette.statusCritical }
        if remaining <= questUrgentMs { return StrandPalette.statusWarning }
        return StrandPalette.accent
    }

    var body: some View {
        HStack(spacing: 6) {
            if showIcon {
                Image(systemName: "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(Quest.formatRemaining(remaining))
                .font(.system(size: fontSize, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .onAppear { remaining = quest.remainingMs(now: nowMs()) }
        .onReceive(tick) { _ in
            // Re-read the clock rather than subtracting 1000: a doze, a long frame or a backgrounded app
            // would otherwise leave the countdown telling a comfortable lie.
            remaining = quest.remainingMs(now: nowMs())
        }
        .onChangeCompat(of: quest.id) { _ in remaining = quest.remainingMs(now: nowMs()) }
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - The quests you are carrying
//
// A row of chips: what has been accepted and not yet finished.
//
// ONE LINE, HORIZONTALLY SCROLLED. The strip is a reminder, not a list view: it costs the screen its
// vertical space, so it takes one row and no more, and it disappears entirely when nothing is active.
// Tapping a chip opens the review sheet, which is where a quest can actually be declared finished.

struct QuestStripView: View {
    @ObservedObject private var store = QuestStore.shared
    @State private var reviewing: Quest?

    var body: some View {
        if !store.active.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.active, id: \.id) { quest in
                        QuestChip(quest: quest) {
                            SystemHaptics.play(.tap)
                            reviewing = quest
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .sheet(item: $reviewing) { quest in
                QuestReviewSheet(quest: quest) { reviewing = nil }
            }
        }
    }
}

/// So a quest can drive a `.sheet(item:)` without a wrapper type.
extension Quest: Identifiable {}

private struct QuestChip: View {
    let quest: Quest
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // The first reward icon stands for the quest: a chip has room for one mark, and the
                // whole set is on the review sheet a tap away.
                if let reward = quest.rewards.first {
                    Image(systemName: questRewardIcon(reward))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(questRewardTint(reward))
                }
                Text(quest.title)
                    .font(StrandFont.overline)
                    // The daily quest is tinted; side quests are not. One accent on the strip keeps the
                    // eye on the thing that is supposed to happen today, however many side quests ride
                    // along.
                    .foregroundStyle(quest.kind == .daily ? StrandPalette.accent : StrandPalette.textSecondary)
                    .lineLimit(1)
                // The clock, at chip scale and without its icon — the row is already a row of small
                // things, and a second glyph per chip turns the strip into a toolbar.
                QuestCountdownView(quest: quest, fontSize: 11, showIcon: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(StrandPalette.surfaceInset, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The review sheet
//
// The whole quest, and the button that finishes it. Finishing is the wearer's word — see
// `QuestPopupView` on why there is no verification — so the button says what it does plainly.

struct QuestReviewSheet: View {
    let quest: Quest
    let onClose: () -> Void

    @ObservedObject private var store = QuestStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(quest.title.uppercased())
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text(quest.taunt)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(quest.target)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            QuestCountdownView(quest: quest)

            HStack(spacing: 8) {
                ForEach(quest.rewards, id: \.rawValue) { reward in
                    Image(systemName: questRewardIcon(reward))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(questRewardTint(reward))
                        .frame(width: 34, height: 34)
                        .background(StrandPalette.surfaceInset, in: Capsule())
                        .accessibilityLabel(Text(questRewardLabel(reward)))
                }
            }

            Button {
                SystemHaptics.play(.confirm)
                store.setState(id: quest.id, state: .completed)
                onClose()
            } label: {
                Text("MARK IT DONE")
                    .font(StrandFont.headline)
                    .tracking(2)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(StrandPalette.surfaceBase)
            }
            .buttonStyle(.plain)

            Button {
                SystemHaptics.play(.tap)
                store.setState(id: quest.id, state: .declined)
                onClose()
            } label: {
                Text("Abandon it")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(StrandPalette.surfaceBase)
    }
}

// MARK: - Reward vocabulary
//
// The icons are a claim about WHICH systems a directive plausibly touches, never about how much — see
// `QuestReward`. Kept in one place so the chip, the sheet and the pop-up cannot disagree.

func questRewardIcon(_ reward: QuestReward) -> String {
    switch reward {
    case .heart: return "heart"
    case .lungs: return "wind"
    case .brain: return "brain.head.profile"
    case .muscle: return "figure.strengthtraining.traditional"
    case .sleep: return "moon.zzz.fill"
    case .stress: return "bolt.fill"
    }
}

func questRewardLabel(_ reward: QuestReward) -> String {
    switch reward {
    case .heart: return "Heart"
    case .lungs: return "Lungs"
    case .brain: return "Focus"
    case .muscle: return "Muscle"
    case .sleep: return "Sleep"
    case .stress: return "Stress"
    }
}

func questRewardTint(_ reward: QuestReward) -> Color {
    switch reward {
    case .heart: return StrandPalette.statusCritical
    case .lungs: return StrandPalette.metricCyan
    case .brain: return StrandPalette.accent
    case .muscle: return StrandPalette.statusWarning
    case .sleep: return StrandPalette.restColor
    case .stress: return StrandPalette.statusWarning
    }
}
