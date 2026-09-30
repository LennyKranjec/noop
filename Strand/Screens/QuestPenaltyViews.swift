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
//
// TELOS 2.0 (DESIGN_V2 §5.14, coordinator decision 1). Serious through the RAIL, the critical ink on the
// COST column and the exactness of the numbers — not through alarm: a glass tile with a 1 pt critical edge
// @ 0.45 and a 3 pt critical rail down its leading side; header glyph `arrow.down.right.circle`, the
// overline and the day's total cost in critical ink; at most three miss rows (then "+N more" into the
// record); an open make-up as its own wash sub-block with a DEBT tag and its deadline. No warning
// triangle, no strike-through, no 00:00:00, no shake, no haptic. The block never shows physiology or
// trial quests as a cost — the ledger reports those as "No penalty" (HEALTH_V2 penalty rules 1 and 3).
// COST: static; the only clock is a make-up's 1 s countdown leaf.

/// The line every penalty surface ends on. One sentence, so it cannot drift between them.
let questPenaltyLevelNote = "Penalties move XP, streaks and make-ups only. Your Level is measured from your "
    + "body, and a missed quest never changes it."

/// How many miss rows the pinned board shows before "+N more".
private let boardMaxRows = 3

/// PENALTIES / DEBT — pinned above the quests.
struct QuestPenaltyBoard: View {
    let ledger: QuestLedger
    let today: String
    let onHistory: () -> Void

    private var red: Color { TelosColor.critical }

    /// Whether the board has anything to draw: a recent judgement, an open make-up, or a quest still
    /// waiting on its data. Pure, for the strip's layout decision and its test.
    static func hasContent(ledger: QuestLedger, today: String) -> Bool {
        !ledger.pending.isEmpty || !ledger.pinned(today: today).isEmpty
    }

    /// XP the pinned misses took (the day's cost), as a positive number.
    static func pinnedCost(_ pinned: [QuestJudgement]) -> Int {
        pinned.filter { $0.outcome == .penalised }.reduce(0) { $0 + max(0, -$1.applied) }
    }

    var body: some View {
        let pinned = ledger.pinned(today: today)
        let openDebts = pinned.filter { $0.debt?.state == .open }
        let rows = Array(pinned.prefix(boardMaxRows))
        let more = pinned.count - rows.count
        let shape = RoundedRectangle(cornerRadius: TelosRadius.tile, style: .continuous)
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            header(cost: Self.pinnedCost(pinned))
            ForEach(ledger.pending, id: \.questId) { subject in
                QuestAwaitingRow(subject: subject)
                TelosListDivider(leadingInset: 0)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, judgement in
                if i > 0 { TelosListDivider(leadingInset: 0) }
                QuestPenaltyRow(judgement: judgement, today: today)
            }
            if more > 0 {
                Button {
                    TelosHaptics.play(.select)
                    onHistory()
                } label: {
                    Text("+\(more) more")
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.textSecondary)
                        .frame(minHeight: TelosSpace.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TelosPressButtonStyle())
            }
            ForEach(openDebts) { judgement in
                if let debt = judgement.debt {
                    QuestDebtBlock(debt: debt, onOpen: onHistory)
                }
            }
            Text(questPenaltyLevelNote)
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, TelosSpace.m)
        .padding(.trailing, TelosSpace.m)
        .padding(.leading, TelosSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(TelosColor.glassFill))
        .overlay(alignment: .leading) {
            // The rail: the block's seriousness, drawn once.
            Rectangle()
                .fill(red)
                .frame(width: TelosStroke.rail)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(red.opacity(0.45), lineWidth: TelosStroke.line))
    }

    private func header(cost: Int) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            HStack(alignment: .center, spacing: TelosSpace.s) {
                Image(systemName: "arrow.down.right.circle")
                    .font(TelosType.glyphRow)
                    .foregroundStyle(red)
                    .accessibilityHidden(true)
                PGOverline("PENALTIES / DEBT", ink: red)
                Spacer(minLength: TelosSpace.s)
                if cost > 0 {
                    Text(verbatim: "\(QuestPenaltyText.signed(-cost)) XP")
                        .font(TelosType.numeralXS)
                        .foregroundStyle(red)
                }
                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.textSecondary)
                        .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TelosPressButtonStyle())
                .accessibilityLabel(Text("Penalty record"))
            }
            .frame(minHeight: TelosSpace.hitTarget)
            Text(verbatim: ledger.balanceText)
                .font(TelosType.scaleNumber)
                .foregroundStyle(ledger.balance < 0 ? red : TelosColor.textTertiary)
        }
    }
}

/// One judged quest: when, what, the reading, the price and why, the streak, the make-up.
struct QuestPenaltyRow: View {
    let judgement: QuestJudgement
    let today: String

    private var red: Color { TelosColor.critical }
    private var charged: Bool { judgement.outcome == .penalised }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(judgement.title)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: QuestPenaltyText.when(judgement.dayKey, today: today).uppercased())
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
                Text(judgement.detailText)
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !judgement.reasonText.isEmpty {
                    Text(judgement.reasonText)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let debt = judgement.debtText {
                    Text(debt)
                        .font(TelosType.caption)
                        .foregroundStyle(judgement.debt?.state == .open ? TelosColor.textSecondary : TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: TelosSpace.s)
            // The cost column — the one place the critical ink carries the weight.
            VStack(alignment: .trailing, spacing: TelosSpace.xxs) {
                Text(verbatim: judgement.costText.uppercased())
                    .font(TelosType.numeralXS)
                    .foregroundStyle(charged ? red : TelosColor.textTertiary)
                if let streak = judgement.streakText {
                    Text(verbatim: streak.uppercased())
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(red)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, TelosSpace.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    /// "Missed: Walk 10,000 steps, Yesterday. 6,412 / 10,000 steps. Cost −100 XP. Daily streak broken · was 12."
    private var spoken: String {
        let when = QuestPenaltyText.when(judgement.dayKey, today: today)
        var parts: [String] = [
            charged ? String(localized: "Missed: \(judgement.title), \(when).")
                    : String(localized: "\(judgement.title), \(when)."),
            judgement.detailText,
            String(localized: "Cost \(judgement.costText)."),
        ]
        if let s = judgement.streakText { parts.append(s + ".") }
        if let d = judgement.debtText { parts.append(d + ".") }
        return parts.joined(separator: " ")
    }
}

/// An open make-up (debt) as its own wash sub-block: DEBT tag, what it asks, what clearing it gives back,
/// and its deadline when the make-up quest is on the board. Tapping opens the record.
private struct QuestDebtBlock: View {
    let debt: QuestDebt
    let onOpen: () -> Void

    var body: some View {
        let quest = QuestStore.shared.active.first { $0.id == debt.questId }
        return Button {
            TelosHaptics.play(.select)
            onOpen()
        } label: {
            HStack(alignment: .center, spacing: TelosSpace.s) {
                VStack(alignment: .leading, spacing: TelosSpace.xs) {
                    HStack(spacing: TelosSpace.s) {
                        TelosTag("Debt", ink: TelosColor.critical)
                        if let quest {
                            QuestCountdownView(quest: quest, fontSize: 11, showIcon: false)
                        }
                    }
                    Text(debt.target)
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "CLEARS \(QuestPenaltyText.signed(debt.restoreXp)) XP BACK")
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(TelosColor.textSecondary)
                }
                Spacer(minLength: TelosSpace.s)
                Image(systemName: "chevron.right")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(TelosSpace.m)
            .background(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                            .fill(TelosColor.criticalWash))
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Debt: \(debt.target). Clears \(debt.restoreXp) XP back."))
    }
}

/// A closed quest still waiting on its data. No penalty until the data says so.
private struct QuestAwaitingRow: View {
    let subject: QuestJudgementSubject

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(subject.title)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textPrimary)
                    .lineLimit(2)
                Text(nowMs() < subject.judgeAfterMs
                     ? "Abandoned. Still judged on the data at its deadline."
                     : "Window closed. Judged on the data when it lands. No penalty until then.")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: TelosSpace.s)
            TelosTag("PENDING", ink: TelosColor.textTertiary, dashed: true)
        }
        .padding(.vertical, TelosSpace.xs)
        .accessibilityElement(children: .combine)
    }
}

/// The game layer at chip size, on the quest row: the balance and the streak. Opens the record.
struct QuestLedgerChip: View {
    let ledger: QuestLedger
    let onTap: () -> Void

    var body: some View {
        let inRed = ledger.balance < 0
        let shape = Capsule(style: .continuous)
        return Button(action: onTap) {
            HStack(spacing: TelosSpace.xs) {
                // Neutral marks, not game icons (decision 19): the balance and the run length.
                Image(systemName: "plusminus.circle")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(inRed ? TelosColor.critical : TelosColor.textSecondary)
                Text(verbatim: ledger.balanceText)
                    .font(TelosType.numeralXS)
                    .foregroundStyle(inRed ? TelosColor.critical : TelosColor.textSecondary)
                if ledger.streak > 0 {
                    Image(systemName: "repeat")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.textTertiary)
                    Text(verbatim: "\(ledger.streak)")
                        .font(TelosType.numeralXS)
                        .foregroundStyle(TelosColor.textSecondary)
                }
            }
            .padding(.horizontal, TelosSpace.m)
            .frame(minHeight: 32)
            .background(shape.fill(TelosColor.glassFill))
            .overlay(shape.strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
            .frame(minHeight: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text("XP and streak. Opens the penalty record."))
    }
}

/// The last 30 days: the books, the metric missed most, and every judgement.
struct QuestPenaltyHistorySheet: View {
    let today: String
    let onClose: () -> Void

    @ObservedObject private var penalties = QuestPenaltyStore.shared

    private var red: Color { TelosColor.critical }

    var body: some View {
        let ledger = penalties.ledger
        let history = ledger.history(today: today)
        let counts = ledger.missCounts(today: today)
        let most = counts.first?.count ?? 1
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.l) {
                HStack {
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        PGOverline("PENALTY RECORD · 30 DAYS", ink: red)
                        Text("The books")
                            .font(TelosType.title2)
                            .foregroundStyle(TelosColor.textPrimary)
                    }
                    Spacer()
                    Button {
                        TelosHaptics.play(.select)
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(TelosType.glyphControl)
                            .foregroundStyle(TelosColor.textSecondary)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(TelosColor.surfaceInset))
                            .overlay(Circle().strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
                            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                            .contentShape(Circle())
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .accessibilityLabel(Text("Close"))
                }

                HStack(spacing: TelosSpace.s) {
                    stat("BALANCE", ledger.balanceText, ledger.balance < 0 ? red : TelosColor.textPrimary)
                    stat("STREAK", "\(ledger.streak) · best \(ledger.bestStreak)", TelosColor.textPrimary)
                }
                HStack(spacing: TelosSpace.s) {
                    stat("LOST", "\(QuestPenaltyText.signed(-ledger.netLost(today: today))) XP", red)
                    stat("WON BACK", "\(QuestPenaltyText.signed(ledger.restored(today: today))) XP",
                         TelosColor.positive)
                }

                if !counts.isEmpty {
                    VStack(alignment: .leading, spacing: TelosSpace.s) {
                        PGOverline("MISSED MOST")
                        ForEach(counts, id: \.metric) { count in
                            HStack(spacing: TelosSpace.s) {
                                Text(count.metric.penaltyLabel)
                                    .font(TelosType.footnote)
                                    .foregroundStyle(TelosColor.textPrimary)
                                    .frame(width: 110, alignment: .leading)
                                Capsule(style: .continuous)
                                    .fill(red.opacity(0.7))
                                    .frame(width: max(6, 140 * CGFloat(count.count) / CGFloat(max(1, most))),
                                           height: 6)
                                Text(verbatim: "×\(count.count)")
                                    .font(TelosType.scaleNumber)
                                    .foregroundStyle(TelosColor.textSecondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                if history.isEmpty {
                    Text("Nothing missed in the last 30 days.")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textSecondary)
                } else {
                    StrandCard {
                        VStack(alignment: .leading, spacing: TelosSpace.xs) {
                            ForEach(Array(history.enumerated()), id: \.element.id) { i, judgement in
                                if i > 0 { TelosListDivider(leadingInset: 0) }
                                QuestPenaltyRow(judgement: judgement, today: today)
                            }
                        }
                    }
                }

                Text(questPenaltyLevelNote)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TelosSpace.l)
        }
        .background(TelosColor.canvas.ignoresSafeArea())
        #if os(iOS)
        .presentationBackground(TelosColor.canvas)
        #endif
    }

    private func stat(_ label: LocalizedStringKey, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            PGOverline(label)
            Text(verbatim: value)
                .font(TelosType.numeralXS)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TelosSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: TelosRadius.control))
        .accessibilityElement(children: .combine)
    }
}
