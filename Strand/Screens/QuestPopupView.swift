import SwiftUI
import StrandAnalytics
import StrandDesign

// QuestPopupView.swift — the system interrupting.
//
// SwiftUI twin of the Android `QuestPopup`. A full-screen overlay with a hard border, the directive,
// what it is worth, and one button — the wearer has to answer it, which is the entire mechanism: a
// nudge that can be scrolled past is a nudge that is scrolled past.
//
// THE TAUNT TYPES ITSELF, one letter at a time, with a tick of haptic per letter. That is the moment
// the wearer asked for — the bond between them and the machine made physical — and it is also why the
// tick is the weakest cue in `SystemHaptics`: at 25 letters a second, anything stronger is a drill.
//
// SKIPPABLE. Tapping anywhere while it types finishes the line at once. A wearer who has read it
// already must never be made to sit through the animation, and an unskippable cutscene is the fastest
// way to make a feature hated.
//
// IT DOES NOT FILL THE SCREEN. The first Android cut covered the display edge to edge over a 97 %
// scrim, which made the quest read as a separate app rather than as the system speaking over this one.
// It still cannot be scrolled past — the decision is the mechanism — but the app underneath stays
// visible around it.

/// How long between letters. ~25/s: fast enough not to be a wait, slow enough to read as typing.
private let typeInterval: TimeInterval = 0.038

/// Margins. Wide enough that the screen behind stays legible around the card.
private let questScreenMargin: CGFloat = 30

/// How much of the screen behind shows through.
///
/// Enough to place yourself, not enough to read by: the card is still the only thing with contrast, so
/// attention lands where it should while the app underneath stays visible.
private let questScrimAlpha: Double = 0.62

/// The glow's reach. A soft blue bloom off every corner, which is what makes it read as summoned.
private let questGlowRadius: CGFloat = 28

/// The quest world's blue.
///
/// `metricPurple` is this palette's WHOOP-Effort BLUE (#4A90E2 dark, #3A80D6 light) — the token's name
/// is a leftover and its value is not purple in either theme. Aliased here so this file reads as what
/// it draws, and so a future rename has one place to land.
private var questBlue: Color { StrandPalette.metricPurple }

struct QuestPopupView: View {
    let quest: Quest
    let onAccept: () -> Void
    let onDismiss: () -> Void
    /// Passed in rather than reached for: the strap lives behind the app model, and a pop-up that owned
    /// a BLE handle would be a screen that cannot be previewed or tested.
    var onSummonStrap: () -> Void = {}

    @State private var typed = 0
    /// Read ONCE, held for the whole animation: a preference lookup per letter would stutter the type.
    @State private var hapticsOn = SystemHaptics.enabled

    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter

    private var full: String { quest.taunt }
    private var done: Bool { typed >= full.count }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.opacity(questScrimAlpha)
                .ignoresSafeArea()
                // Tap anywhere to finish the typing early; once finished, taps do nothing (the button is
                // the only way out, because this is a decision and not a toast).
                .contentShape(Rectangle())
                .onTapGesture { if !done { typed = full.count } }

            card
                .padding(questScreenMargin)
        }
        .task(id: quest.id) { await run() }
    }

    /// The summon, then the typing. One task keyed on the quest's id, so a re-render cannot re-summon.
    private func run() async {
        SystemHaptics.play(.summon)
        onSummonStrap()
        typed = 0
        let letters = Array(full)
        // See `TypewriterText.run` — the engine is held open for the length of the line, or it idles
        // out between letters and the restarts swallow the ticks.
        if hapticsOn { SystemHaptics.holdTickEngine(true) }
        defer { if hapticsOn { SystemHaptics.holdTickEngine(false) } }
        while typed < letters.count {
            try? await Task.sleep(nanoseconds: UInt64(typeInterval * 1_000_000_000))
            if Task.isCancelled { return }
            // A tap may have skipped ahead while this was sleeping.
            guard typed < letters.count else { return }
            let next = letters[typed]
            typed += 1
            // Spaces get no tick: the finger feels a gap between words, which is what a space is.
            if hapticsOn, !next.isWhitespace { SystemHaptics.tick() }
        }
    }

    private var card: some View {
        // WRAPS ITS CONTENT rather than filling the screen, so the card is only as tall as the quest
        // actually is and the app stays visible above and below it.
        VStack(alignment: .leading, spacing: 12) {
            header
            body_
            rewardRow
            deadline
            acceptButton

            // ASK ABOUT IT, before deciding. The directive goes into the transcript as the system's own
            // opening line so a follow-up has something to be a follow-up to — and the quest stays
            // OFFERED, because asking a question about a commitment is not the same as making it.
            Button {
                SystemHaptics.play(.tap)
                coach.surfaceQuest(title: quest.title, target: quest.target, taunt: quest.taunt)
                router.openCoach()
            } label: {
                Label("Ask about this", systemImage: "sparkles")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!done)

            Button {
                SystemHaptics.play(.tap)
                onDismiss()
            } label: {
                Text("Not today")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!done)
        }
        .padding(16)
        .background(
            // A blue-lifted top so the card itself carries the colour, not just its edge.
            LinearGradient(
                colors: [questBlue.opacity(0.16), StrandPalette.surfaceBase],
                startPoint: .top, endPoint: .bottom)
                .background(StrandPalette.surfaceRaised)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(questBlue.opacity(0.70), lineWidth: 1)
        )
        // THE GLOW IS A COLOURED SHADOW, cast in the quest's own blue — so it blooms off all four
        // corners rather than being a border that happens to be thick.
        .shadow(color: questBlue.opacity(0.55), radius: questGlowRadius)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(questBlue)
            Text("SYSTEM DIRECTIVE")
                .font(StrandFont.headline.weight(.bold))
                .tracking(3)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    /// The body panel: name, the typed taunt, and the directive.
    private var body_: some View {
        VStack(spacing: 0) {
            Text(quest.title.uppercased())
                .font(StrandFont.title2)
                .tracking(2)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 12)
            TypedLine(text: full, shown: typed)
            Spacer().frame(height: 14)
            Text(quest.target)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.accent)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(questBlue.opacity(0.35), lineWidth: 1)
        )
    }

    /// What finishing it is worth: the systems it touches. The icons are a claim about WHICH systems,
    /// never about how much.
    private var rewardRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT IT TOUCHES")
                .font(StrandFont.overline)
                .tracking(1.4)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(spacing: 12) {
                ForEach(quest.rewards, id: \.rawValue) { reward in
                    Image(systemName: questRewardIcon(reward))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(questRewardTint(reward))
                        .frame(width: 34, height: 34)
                        .background(StrandPalette.surfaceInset, in: Capsule())
                        .accessibilityLabel(Text(questRewardLabel(reward)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// THE CLOCK, and what runs out with it. The warning is plain rather than threatening: the app has
    /// no way to impose a penalty, and implying one would be a threat it cannot keep.
    private var deadline: some View {
        VStack(spacing: 6) {
            Text("The window closes when the clock does.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .multilineTextAlignment(.center)
            QuestCountdownView(quest: quest, fontSize: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var acceptButton: some View {
        Button {
            SystemHaptics.play(.confirm)
            onAccept()
        } label: {
            Text("ACCEPT")
                .font(StrandFont.headline.weight(.bold))
                .tracking(4)
                .foregroundStyle(done ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(done ? StrandPalette.accent : StrandPalette.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The glow fades in with the button becoming live, so "you may answer now" is visible
                // from across the room rather than only legible up close.
                .opacity(done ? 1 : 0.55)
                .animation(.easeOut(duration: 0.25), value: done)
        }
        .buttonStyle(.plain)
        // Until the line has finished typing there is nothing to accept yet — the wearer has not been
        // told what they are agreeing to.
        .disabled(!done)
    }
}

/// The taunt, mid-type.
///
/// The full string is laid out invisibly underneath so the block does not change height as it fills —
/// text that reflows while it types is the thing that makes a typewriter effect feel cheap.
private struct TypedLine: View {
    let text: String
    let shown: Int

    var body: some View {
        ZStack {
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(Color.clear)
                .multilineTextAlignment(.center)
            Text(String(text.prefix(shown)))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - The host
//
// One place that decides whether a pop-up is on screen, so the shell can present it over every tab
// without each tab knowing about quests.

struct QuestHostModifier: ViewModifier {
    @ObservedObject private var store = QuestStore.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let quest = store.offered {
                QuestPopupView(
                    quest: quest,
                    onAccept: { store.setState(id: quest.id, state: .active) },
                    onDismiss: { store.setState(id: quest.id, state: .declined) }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.offered?.id)
    }
}

extension View {
    /// Present the offered quest, if there is one, over whatever this is.
    func questHost() -> some View { modifier(QuestHostModifier()) }
}
