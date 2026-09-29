import SwiftUI
import StrandAnalytics
import StrandDesign

// QuestPenaltyViews.swift — the price of a missed quest, where it can be seen.
//
// THE BOARD sits pinned at the TOP of the quest strip on Today, above the quests still running: what was
// missed, when, by how much, what it cost, and any make-up still open. It stays until the make-up is
// cleared or the item ages out (`QuestPenaltyRules.pinnedDays`), so the wearer meets yesterday's miss
// before today's directives, not after.
//
// THE RECORD is the last 30 days of it, one tap away, with the metric missed most at the top — the
// pattern is the useful part.
//
// Every sentence on both is written by the ledger (`QuestJudgement.costText` and friends), so the board,
// the record, the failure card and the day's card cannot describe the same miss four different ways.
//
// GAME LAYER ONLY, and the board says so: penalties move XP, the streak and make-ups — never the
// measured Level.

/// The line every penalty surface ends on. One sentence, so it cannot drift between them.
let questPenaltyLevelNote = "Penalties move XP, streaks and make-ups only. Your Level is measured from your "
    + "body, and a missed quest never changes it."

/// PENALTIES / DEBT — pinned above the quests.
struct QuestPenaltyBoard: View {
    let ledger: QuestLedger
    let today: String
    let onHistory: () -> Void

    private var red: Color { StrandPalette.statusCritical }

    /// Whether the board has anything to draw: a recent judgement, an open make-up, or a quest still
    /// waiting on its data. Pure, for the strip's layout decision and its test.
    static func hasContent(ledger: QuestLedger, today: String) -> Bool {
        !ledger.pending.isEmpty || !ledger.pinned(today: today).isEmpty
    }

    var body: some View {
        let pinned = ledger.pinned(today: today)
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(ledger.pending, id: \.questId) { subject in
                QuestAwaitingRow(subject: subject)
            }
            ForEach(pinned) { judgement in
                QuestPenaltyRow(judgement: judgement, today: today)
            }
            Text(questPenaltyLevelNote)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(red.opacity(0.45), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(red)
            Text("PENALTIES / DEBT")
                .font(StrandFont.overline)
                .tracking(1.4)
                .foregroundStyle(red)
            Spacer(minLength: 6)
            Text(ledger.balanceText)
                .font(StrandFont.overline)
                .monospacedDigit()
                .foregroundStyle(ledger.balance < 0 ? red : StrandPalette.textSecondary)
            Button(action: onHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Penalty record"))
        }
    }
}

/// One judged quest: when, what, the reading, the price and why, the streak, the make-up.
struct QuestPenaltyRow: View {
    let judgement: QuestJudgement
    let today: String

    private var red: Color { StrandPalette.statusCritical }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(QuestPenaltyText.when(judgement.dayKey, today: today) + " · " + judgement.title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(judgement.detailText)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !judgement.reasonText.isEmpty {
                    Text(judgement.reasonText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let streak = judgement.streakText {
                    Text(streak)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(red)
                }
                if let debt = judgement.debtText {
                    Text(debt)
                        .font(StrandFont.caption)
                        .foregroundStyle(judgement.debt?.state == .open
                                         ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(judgement.costText)
                .font(StrandFont.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(judgement.outcome == .penalised ? red : StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A closed quest still waiting on its data. No penalty until the data says so.
private struct QuestAwaitingRow: View {
    let subject: QuestJudgementSubject

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(subject.title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(nowMs() < subject.judgeAfterMs
                     ? "Abandoned. Still judged on the data at its deadline."
                     : "Window closed. Judged on the data when it lands. No penalty until then.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("PENDING")
                .font(StrandFont.overline)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// The game layer at chip size, on the quest row: the balance and the streak. Opens the record.
struct QuestLedgerChip: View {
    let ledger: QuestLedger
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ledger.balance < 0 ? StrandPalette.statusCritical : StrandPalette.accent)
                Text(ledger.balanceText)
                    .font(StrandFont.overline)
                    .monospacedDigit()
                    .foregroundStyle(ledger.balance < 0 ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                if ledger.streak > 0 {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusWarning)
                    Text("\(ledger.streak)")
                        .font(StrandFont.overline)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(StrandPalette.surfaceInset, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("XP and streak. Opens the penalty record."))
    }
}

/// The last 30 days: the books, the metric missed most, and every judgement.
struct QuestPenaltyHistorySheet: View {
    let today: String
    let onClose: () -> Void

    @ObservedObject private var penalties = QuestPenaltyStore.shared

    private var red: Color { StrandPalette.statusCritical }

    var body: some View {
        let ledger = penalties.ledger
        let history = ledger.history(today: today)
        let counts = ledger.missCounts(today: today)
        let most = counts.first?.count ?? 1
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PENALTY RECORD · 30 DAYS")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                HStack(spacing: 10) {
                    stat("BALANCE", ledger.balanceText, ledger.balance < 0 ? red : StrandPalette.textPrimary)
                    stat("STREAK", "\(ledger.streak) · best \(ledger.bestStreak)", StrandPalette.textPrimary)
                }
                HStack(spacing: 10) {
                    stat("LOST", "\(QuestPenaltyText.signed(-ledger.netLost(today: today))) XP", red)
                    stat("WON BACK", "\(QuestPenaltyText.signed(ledger.restored(today: today))) XP",
                         StrandPalette.statusPositive)
                }

                if !counts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MISSED MOST")
                            .font(StrandFont.overline)
                            .tracking(1.4)
                            .foregroundStyle(StrandPalette.textTertiary)
                        ForEach(counts, id: \.metric) { count in
                            HStack(spacing: 8) {
                                Text(count.metric.penaltyLabel)
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .frame(width: 110, alignment: .leading)
                                Capsule()
                                    .fill(red.opacity(0.7))
                                    .frame(width: max(6, 140 * CGFloat(count.count) / CGFloat(max(1, most))),
                                           height: 6)
                                Text("×\(count.count)")
                                    .font(StrandFont.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                    }
                }

                if history.isEmpty {
                    Text("Nothing missed in the last 30 days.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(history) { judgement in
                            QuestPenaltyRow(judgement: judgement, today: today)
                        }
                    }
                }

                Text(questPenaltyLevelNote)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    SystemHaptics.play(.tap)
                    onClose()
                } label: {
                    Text("Close")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(StrandFont.overline)
                .tracking(1.4)
                .foregroundStyle(StrandPalette.textTertiary)
            Text(value)
                .font(StrandFont.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
