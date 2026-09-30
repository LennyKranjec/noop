import SwiftUI
import StrandAnalytics
import StrandDesign

// QuestViews.swift — the clock, the strip and the review sheet.
//
// SwiftUI twins of the Android `QuestCountdown` / `QuestStrip` / `QuestReviewCard`. The pop-up — the
// part that interrupts — is `QuestPopupView` in its own file.
//
// TELOS 2.0 (PROGRESS part B): restyled WITHOUT restructuring. The strip's root is still one `VStack` with
// the penalty board as its first child and the ONE `.sheet(item:)` on that root; chips are glass capsules
// (the gear chip lit in the accent), the review sheet sits on the solid canvas. Tokens only.

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

    /// A once-a-second schedule on whole-second boundaries. A `TimelineView` rather than a
    /// `Timer.publish(...).autoconnect()` created in `init`: that built (and connected) a fresh run-loop
    /// timer every time a parent re-rendered this view, and kept firing while the app was in the
    /// background. The fixed start date keeps the schedule identical across re-inits.
    private static let everySecond = PeriodicTimelineSchedule(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)

    private func tint(_ remaining: Int64) -> Color {
        if remaining <= 0 { return TelosColor.critical }
        if remaining <= questUrgentMs { return TelosColor.warning }
        return TelosColor.mint
    }

    var body: some View {
        TimelineView(Self.everySecond) { _ in
            // Re-read the clock rather than subtracting 1000: a doze, a long frame or a backgrounded app
            // would otherwise leave the countdown telling a comfortable lie.
            let remaining = quest.remainingMs(now: nowMs())
            HStack(spacing: 6) {
                if showIcon {
                    Image(systemName: "timer")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(tint(remaining))
                }
                Text(Quest.formatRemaining(remaining))
                    .font(TelosType.numeralFont(size: fontSize, weight: .medium))
                    .foregroundStyle(tint(remaining))
            }
        }
    }
}

func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

// MARK: - The quests you are carrying
//
// A row of chips: the gear the day is running in, then what has been accepted and not yet finished.
//
// ONE LINE, HORIZONTALLY SCROLLED. The strip is a reminder, not a list view: it costs the screen its
// vertical space, so it takes one row and no more, and the row disappears entirely when there is nothing
// to say. Tapping a quest chip opens the review sheet, which is where a quest can actually be declared
// finished — and that sheet hangs off the strip's ROOT, not off the row, because the row is what the
// sheet's own actions make disappear. See the note on `body`.
//
// THE GEAR LEADS THE ROW. The wearer picked Steady, Push or Relentless in the morning flow, and every
// target on the chips behind it was scaled by that choice — so the choice has to be visible next to
// them, or the numbers look arbitrary. A day with NO choice shows no chip: `QuestModeStore` returns nil
// for a morning the wearer was never asked, and a default would be the app claiming they picked one.

struct QuestStripView: View {
    @ObservedObject private var store = QuestStore.shared
    @ObservedObject private var modes = QuestModeStore.shared
    /// The game layer's books — the pinned penalties board and the XP chip read it.
    @ObservedObject private var penalties = QuestPenaltyStore.shared
    /// For judging closed quests on their data (`QuestPenaltyAssessor`). The same environment object the
    /// review sheet's progress panel already reads.
    @EnvironmentObject private var repo: Repository
    /// What the strip's ONE sheet is showing — a quest under review, or the penalty record.
    @State private var sheet: StripSheet?

    /// Everything the strip's single presenter can show. One enum behind one `.sheet(item:)`, so adding
    /// the penalty record did not add a second presenter to this view (see the note on `body`).
    enum StripSheet: Identifiable {
        case review(Quest)
        case history

        var id: String {
            switch self {
            case .review(let quest): return "review-" + quest.id
            case .history: return "history"
            }
        }
    }

    /// The quest day — the same key the quests carry and the morning flow recorded the choice under.
    private var dayKey: String { DailyMissionStore.dayKey() }

    /// The gear picked for today, or nil when the wearer was never asked.
    private var mode: QuestDifficulty? { modes.mode(for: dayKey) }

    // ONE PRESENTER, UNCONDITIONAL, AT THE ROOT.
    //
    // WHAT WAS WRONG. The review sheet hung off the `ScrollView` INSIDE `if there is something to draw`.
    // Resolving the last active quest from that sheet — which is exactly what the sheet is for, and what
    // its own `QuestAutoComplete.run` does when the goal is already met — empties the row, so on a day
    // with no gear chip the whole branch was replaced and the presenter was torn down MID-REVIEW: the
    // sheet vanished, or never appeared at all. A presenter has to outlive its own content.
    //
    // SO THE ROOT IS ALWAYS THERE and the conditional lives one level in. Deliberately a `VStack` and not
    // a `Group`: a modifier on a Group is applied per CHILD, so an empty branch would leave the sheet
    // attached to nothing — the wake-buzz sheet was moved off a Group for that exact reason. Empty, the
    // VStack is zero-height, like the always-present leaves above this strip in Today's section list.
    //
    // AND THERE IS ONLY ONE. Neither the gear chip nor a quest chip presents anything of its own — a chip
    // sets `sheet` and nothing else — so there is no second sheet on this view for the last one to win
    // over. The penalty record goes through the SAME presenter (`StripSheet.history`). The day's plan
    // summary is not a sheet from here either: it is an overlay on the shell (`RootTabView` →
    // `DiagnosticAlertView`), which no change to this row can tear down.
    //
    // PENALTIES / DEBT IS PINNED ABOVE THE QUESTS. What was missed, when, by how much and what it cost —
    // plus any make-up still open — comes first, so yesterday's miss is read before today's directives.
    // It is its own child of the root, so the board appearing or clearing cannot touch the presenter.
    var body: some View {
        VStack(spacing: TelosSpace.s) {
            if QuestPenaltyBoard.hasContent(ledger: penalties.ledger, today: dayKey) {
                QuestPenaltyBoard(ledger: penalties.ledger, today: dayKey) { sheet = .history }
            }
            if Self.hasContent(mode: mode, activeCount: store.active.count, ledgerChip: showsLedgerChip) { row }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .review(let quest):
                QuestReviewSheet(quest: quest) { sheet = nil }
            case .history:
                QuestPenaltyHistorySheet(today: dayKey) { sheet = nil }
            }
        }
        // JUDGE WHAT HAS CLOSED, on its data. Keyed on the pending queue so a freshly swept quest is judged
        // at once, and repeated every few minutes while Today is up so data that lands late is read.
        .task(id: penalties.pendingSignature) {
            while !Task.isCancelled {
                await QuestPenaltyAssessor.run(repo: repo)
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
    }

    /// Whether the XP chip has anything to say: a balance, a streak, or a record to open.
    private var showsLedgerChip: Bool {
        let l = penalties.ledger
        return l.balance != 0 || l.streak > 0 || !l.history(today: dayKey).isEmpty
    }

    /// Whether the strip has anything to DRAW.
    ///
    /// Pure, and deliberately NOT what decides whether the review presenter exists — see the note on
    /// `body`. A day whose quests have all resolved keeps its gear chip (the wearer did pick a gear, and
    /// that is worth saying); a day that was never asked and carries nothing draws nothing at all, rather
    /// than an empty card.
    static func hasContent(mode: QuestDifficulty?, activeCount: Int, ledgerChip: Bool = false) -> Bool {
        mode != nil || activeCount > 0 || ledgerChip
    }

    /// The row itself — one concrete view, so nothing about it can replace the presenter above it.
    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TelosSpace.s) {
                if let mode { GearChip(difficulty: mode) }
                ForEach(store.active, id: \.id) { quest in
                    QuestChip(quest: quest) {
                        TelosHaptics.play(.select)
                        sheet = .review(quest)
                    }
                }
                if showsLedgerChip {
                    QuestLedgerChip(ledger: penalties.ledger) {
                        TelosHaptics.play(.select)
                        sheet = .history
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// The gear the day is running in. Read-only: the choice belongs to the morning, and a chip that could
/// silently re-roll the day's targets from Today would be a different feature.
private struct GearChip: View {
    let difficulty: QuestDifficulty

    private var symbol: String {
        switch difficulty {
        case .steady: return "tortoise.fill"
        case .push: return "figure.run"
        case .relentless: return "flame.fill"
        }
    }

    var body: some View {
        let shape = Capsule(style: .continuous)
        // A flat, neutral read-out chip (decision 19): no tinted wash, no gradient edge.
        HStack(spacing: TelosSpace.xs) {
            Image(systemName: symbol)
                .font(TelosType.glyphChevron)
                .foregroundStyle(TelosColor.textSecondary)
            Text(difficulty.title.uppercased())
                .telosScale()
                .foregroundStyle(TelosColor.textPrimary)
        }
        .padding(.horizontal, TelosSpace.m)
        .frame(minHeight: 32)
        .background(shape.fill(TelosColor.glassFill))
        .overlay(shape.strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
        .frame(minHeight: TelosSpace.hitTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Today's gear: \(difficulty.title)"))
    }
}

/// So a quest can drive a `.sheet(item:)` without a wrapper type.
extension Quest: Identifiable {}

private struct QuestChip: View {
    let quest: Quest
    let onTap: () -> Void

    var body: some View {
        let shape = Capsule(style: .continuous)
        return Button(action: onTap) {
            HStack(spacing: TelosSpace.xs) {
                // The first reward icon stands for the quest: a chip has room for one mark, and the
                // whole set is on the review sheet a tap away. The wearer's own task shows a person
                // instead — the one mark that says "you asked for this", kept quiet on purpose.
                if quest.kind == .custom {
                    Image(systemName: "person.fill")
                        .font(TelosType.glyphDelta)
                        .foregroundStyle(TelosColor.textTertiary)
                        .accessibilityLabel(Text("Your task"))
                } else if let reward = quest.rewards.first {
                    Image(systemName: questRewardIcon(reward))
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(questRewardTint(reward))
                }
                Text(quest.title)
                    .telosScale()
                    // The daily quest is tinted; side quests are not. One accent on the strip keeps the
                    // eye on the thing that is supposed to happen today, however many side quests ride
                    // along.
                    .foregroundStyle(quest.kind == .daily ? TelosColor.mint : TelosColor.textSecondary)
                    .lineLimit(1)
                // The clock, at chip scale and without its icon — the row is already a row of small
                // things, and a second glyph per chip turns the strip into a toolbar.
                QuestCountdownView(quest: quest, fontSize: 11, showIcon: false)
            }
            .padding(.horizontal, TelosSpace.m)
            .frame(minHeight: 32)
            .background(shape.fill(TelosColor.glassFill))
            .overlay(shape.strokeBorder(TelosColor.glassEdge, lineWidth: TelosStroke.line))
            .frame(minHeight: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
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
    /// NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    /// actions. Observing it re-rendered the whole view per chunk while any generation ran.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @EnvironmentObject private var router: NavRouter

    /// How much of the taunt is shown (always all of it since decision 19). See `TypewriterText`.
    @State private var typed = 0

    private var isCustom: Bool { quest.kind == .custom }

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            if isCustom {
                Label("BY YOU · VIA THE COACH", systemImage: "person.fill")
                    .font(TelosType.scale)
                    .tracking(TelosType.Tracking.scale)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            PGOverline("Quest", ink: TelosColor.mint)
            Text(quest.title)
                .font(TelosType.title2)
                .foregroundStyle(TelosColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !quest.taunt.isEmpty {
                TypewriterText(text: quest.taunt, shown: $typed)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            Text(quest.target)
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.mint)
                .fixedSize(horizontal: false, vertical: true)
            QuestCountdownView(quest: quest)

            HStack(spacing: TelosSpace.s) {
                ForEach(quest.rewards, id: \.rawValue) { reward in
                    QuestRewardGlyph(reward: reward)
                }
            }

            // ASK ABOUT IT. The directive lands in the transcript as the system's own opening line and
            // the coach opens on it, so a follow-up has something to be a follow-up TO. Nothing is sent:
            // the sentence already exists, and spending a round trip to restate it would be a request
            // for nothing.
            Button {
                TelosHaptics.play(.select)
                coach.surfaceQuest(title: quest.title, target: quest.target, taunt: quest.taunt)
                onClose()
                router.openCoach()
            } label: {
                Label("Ask the system about this", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopSecondary)

            // NO "MARK IT DONE" for a system quest. It closes itself when the data meets its goal — see
            // `QuestAutoComplete` — so what sits here is where the data stands, not a button asking the
            // wearer to vouch for themselves. The wearer's OWN task is the exception: they set it, most
            // of what people ask for ("stretch after lunch") is nothing a sensor sees, and vouching for
            // a bar you set yourself is the whole point of it. One with a goal still closes on its own.
            if !isCustom || quest.goal != nil {
                QuestProgressPanel(quest: quest)
            }
            if isCustom {
                Button {
                    TelosHaptics.play(.commit)
                    store.checkOff(id: quest.id)
                    onClose()
                } label: {
                    Label("Mark it done", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.noopPrimary)
            }

            // ABANDONING IS CONCEDING, NOT ESCAPING. An accepted system quest given up here is still judged
            // on its data at the deadline it would have had (`QuestStore.abandon`) — otherwise "Abandon it"
            // would be a button that deletes the penalty. The label says so.
            Button {
                TelosHaptics.play(.select)
                if isCustom {
                    store.removeCustom(id: quest.id)
                } else {
                    store.abandon(id: quest.id)
                }
                onClose()
            } label: {
                Text(isCustom ? "Remove task" : "Abandon it (still judged at the deadline)")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TelosPressButtonStyle())

            Spacer(minLength: 0)
        }
        .padding(TelosSpace.l)
        .background(TelosColor.canvas.ignoresSafeArea())
        #if os(iOS)
        .presentationBackground(TelosColor.canvas)
        #endif
    }
}

/// Where the data stands against an open quest's goal.
private struct QuestProgressPanel: View {
    let quest: Quest

    @EnvironmentObject private var repo: Repository
    @State private var line: String?

    var body: some View {
        HStack(alignment: .top, spacing: TelosSpace.s) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(TelosType.glyphChevron)
                .foregroundStyle(TelosColor.mint)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                PGOverline("CHECKED AUTOMATICALLY")
                Text(line ?? " ")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TelosSpace.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pgInsetBand()
        .task(id: quest.id) { await load() }
    }

    private func load() async {
        guard let goal = quest.effectiveGoal else {
            line = "This directive names nothing the app can measure, so it cannot close itself. It "
                + "will run out on its own clock."
            return
        }
        if goal.metric.resolvesNextMorning {
            line = "Read from tonight's sleep. It closes itself tomorrow morning if the night meets it."
            return
        }
        // Run the check as well as reading it: opening the sheet is a reason to look, and a quest that
        // is already met should close now rather than on the next refresh.
        await QuestAutoComplete.run(repo: repo)
        let evidence = await QuestAutoComplete.gather(repo: repo, day: quest.dayKey)
        line = "So far: " + goal.summary(evidence) + " It closes itself the moment the data meets it."
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
    case .heart: return TelosColor.heart
    case .lungs: return TelosColor.lungs
    case .brain: return TelosColor.focusInk
    case .muscle: return TelosColor.muscle
    case .sleep: return TelosColor.rest
    case .stress: return TelosColor.stress
    }
}


/// One reward mark: the system's glyph in its identity colour on a small glass disc (34 pt).
struct QuestRewardGlyph: View {
    let reward: QuestReward
    var dimmed = false

    var body: some View {
        Image(systemName: questRewardIcon(reward))
            .font(TelosType.glyphRow)
            .foregroundStyle(questRewardTint(reward).opacity(dimmed ? 0.45 : 1))
            .frame(width: 34, height: 34)
            .background(Circle().fill(questRewardTint(reward).opacity(TelosOpacity.wash)))
            .overlay(Circle().strokeBorder(questRewardTint(reward).opacity(TelosOpacity.border), lineWidth: TelosStroke.hair))
            .accessibilityLabel(Text(questRewardLabel(reward)))
    }
}

// MARK: - The (retired) typewriter
//
// DECISION 19 (owner, 2026-09-30 — clinical restraint): no typewriter effect, no per-letter haptic ticks.
// The type keeps its name and API (every surface that shows a taunt uses it), but the whole line is shown
// at once, in every mode, from the first frame. `shown` is still set to the full length so callers that
// gate a button on "the line has been shown" keep working.

struct TypewriterText: View {
    let text: String
    @Binding var shown: Int

    var body: some View {
        Text(text)
            .task(id: text) { await run() }
    }

    /// Mark the whole line as shown — no per-letter reveal, no ticks (decision 19).
    private func run() async {
        shown = text.count
    }
}
