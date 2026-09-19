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
                // whole set is on the review sheet a tap away. The wearer's own task shows a person
                // instead — the one mark that says "you asked for this", kept quiet on purpose.
                if quest.kind == .custom {
                    Image(systemName: "person.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityLabel(Text("Your task"))
                } else if let reward = quest.rewards.first {
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
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter

    /// How much of the taunt has been typed. See `TypewriterText`.
    @State private var typed = 0

    private var isCustom: Bool { quest.kind == .custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCustom {
                Label("BY YOU · VIA THE COACH", systemImage: "person.fill")
                    .font(StrandFont.overline)
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(quest.title.uppercased())
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            if !quest.taunt.isEmpty {
                TypewriterText(text: quest.taunt, shown: $typed)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
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

            // ASK ABOUT IT. The directive lands in the transcript as the system's own opening line and
            // the coach opens on it, so a follow-up has something to be a follow-up TO. Nothing is sent:
            // the sentence already exists, and spending a round trip to restate it would be a request
            // for nothing.
            Button {
                SystemHaptics.play(.tap)
                coach.surfaceQuest(title: quest.title, target: quest.target, taunt: quest.taunt)
                onClose()
                router.openCoach()
            } label: {
                Label("Ask the system about this", systemImage: "sparkles")
                    .font(StrandFont.footnote)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)

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
                    SystemHaptics.play(.tap)
                    store.checkOff(id: quest.id)
                    onClose()
                } label: {
                    Label("Mark it done", systemImage: "checkmark.circle.fill")
                        .font(StrandFont.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(StrandPalette.accent.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                SystemHaptics.play(.tap)
                if isCustom {
                    store.removeCustom(id: quest.id)
                } else {
                    store.setState(id: quest.id, state: .declined)
                }
                onClose()
            } label: {
                Text(isCustom ? "Remove task" : "Abandon it")
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

/// Where the data stands against an open quest's goal.
private struct QuestProgressPanel: View {
    let quest: Quest

    @EnvironmentObject private var repo: Repository
    @State private var line: String?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("CHECKED AUTOMATICALLY")
                    .font(StrandFont.overline)
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(line ?? " ")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    case .heart: return StrandPalette.statusCritical
    case .lungs: return StrandPalette.metricCyan
    case .brain: return StrandPalette.accent
    case .muscle: return StrandPalette.statusWarning
    case .sleep: return StrandPalette.restColor
    case .stress: return StrandPalette.statusWarning
    }
}


// MARK: - The typewriter
//
// The shared letter-by-letter reveal, with a haptic tick per letter. It lives here rather than inside the
// pop-up because every surface that shows a taunt types it: the pop-up that issues a quest, and the
// review sheet that revisits one. A line that typed itself when issued and simply appeared when reopened
// would read as two different systems.
//
// SPACES GET NO TICK. The finger feels a gap between words, which is what a space is.
//
// SKIPPABLE. Tapping finishes the line at once — a wearer who has read it already must never be made to
// sit through the animation.
//
// THE FULL STRING IS LAID OUT INVISIBLY UNDERNEATH, so the block does not change height as it fills.
// Text that reflows while it types is the thing that makes a typewriter effect feel cheap.

/// How long between letters. ~25/s: fast enough not to be a wait, slow enough to read as typing.
private let typewriterInterval: TimeInterval = 0.038

struct TypewriterText: View {
    let text: String
    @Binding var shown: Int

    @State private var hapticsOn = SystemHaptics.enabled

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text).foregroundStyle(Color.clear)
            Text(String(text.prefix(shown)))
        }
        .contentShape(Rectangle())
        .onTapGesture { shown = text.count }
        .task(id: text) { await run() }
    }

    private func run() async {
        shown = 0
        let letters = Array(text)
        // HELD OPEN FOR THE LINE. The engine idles out between letters otherwise, and each restart
        // costs more than the gap between two of them — which is most of why the ticks were not there.
        // `defer` rather than a close at the end: the sheet can be dismissed mid-type, and the task is
        // cancelled rather than finished.
        if hapticsOn { SystemHaptics.holdTickEngine(true) }
        defer { if hapticsOn { SystemHaptics.holdTickEngine(false) } }
        while shown < letters.count {
            try? await Task.sleep(nanoseconds: UInt64(typewriterInterval * 1_000_000_000))
            if Task.isCancelled { return }
            guard shown < letters.count else { return }
            let next = letters[shown]
            shown += 1
            if hapticsOn, !next.isWhitespace { SystemHaptics.tick() }
        }
    }
}
