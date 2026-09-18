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
            // A COMPLETION FIRST. It is news about something already done, and an offer sitting on top
            // of it would ask for a new commitment before the last one had been acknowledged.
            if let completion = store.completions.first {
                QuestCompletedPopupView(completion: completion) { store.dismissCompletion() }
                    .id(completion.id)
                    .transition(.opacity)
            } else if let failure = store.failures.first {
                QuestFailedPopupView(failure: failure) { store.dismissFailure() }
                    .id("failed-" + failure.id)
                    .transition(.opacity)
            } else if let quest = store.offered {
                QuestPopupView(
                    quest: quest,
                    onAccept: { store.setState(id: quest.id, state: .active) },
                    onDismiss: { store.setState(id: quest.id, state: .declined) }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: store.offered?.id)
        .animation(.easeOut(duration: 0.25), value: store.completions.first?.id)
        .animation(.easeOut(duration: 0.25), value: store.failures.first?.id)
        // A WINDOW CAN CLOSE WITH NOTHING ELSE HAPPENING — no refresh, no sync — so the host checks the
        // clock itself once a minute while the app is open. Cheap: it only compares timestamps.
        .task {
            while !Task.isCancelled {
                store.sweepExpired()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }
}

// MARK: - The quest running out
//
// The completion card's twin in red: the same card, the same typed line, saying the window closed and
// the quest is gone. Nothing to accept or retry — the pop-up is the notice, and the quest has already
// been cancelled by the time it shows.

struct QuestFailedPopupView: View {
    let failure: QuestStore.Completion
    let onDismiss: () -> Void

    @State private var typed = 0
    @State private var hapticsOn = SystemHaptics.enabled

    private var quest: Quest { failure.quest }
    private var full: String { failure.summary }
    private var done: Bool { typed >= full.count }
    private var red: Color { StrandPalette.statusCritical }

    // THE DIRECTIVE POP-UP, IN RED. The same card the quest was offered on — the same header, the same
    // panel with the typed line, the same systems it touched, the same clock — now saying the clock ran
    // out. The quest is already cancelled when this shows; the only button acknowledges it.
    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.opacity(questScrimAlpha)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !done { typed = full.count } }

            card
                .padding(questScreenMargin)
        }
        .task(id: failure.id) { await run() }
    }

    /// The summon, then the typing, exactly as the offer does it.
    private func run() async {
        SystemHaptics.play(.summon)
        typed = 0
        let letters = Array(full)
        if hapticsOn { SystemHaptics.holdTickEngine(true) }
        defer { if hapticsOn { SystemHaptics.holdTickEngine(false) } }
        while typed < letters.count {
            try? await Task.sleep(nanoseconds: UInt64(typeInterval * 1_000_000_000))
            if Task.isCancelled { return }
            guard typed < letters.count else { return }
            let next = letters[typed]
            typed += 1
            if hapticsOn, !next.isWhitespace { SystemHaptics.tick() }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(red)
                Text("DIRECTIVE FAILED")
                    .font(StrandFont.headline.weight(.bold))
                    .tracking(3)
                    .foregroundStyle(StrandPalette.textPrimary)
            }

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
                    .foregroundStyle(red)
                    .strikethrough(true, color: red.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(red.opacity(0.35), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("WHAT IT WOULD HAVE TOUCHED")
                    .font(StrandFont.overline)
                    .tracking(1.4)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(spacing: 12) {
                    ForEach(quest.rewards, id: \.rawValue) { reward in
                        Image(systemName: questRewardIcon(reward))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(questRewardTint(reward).opacity(0.45))
                            .frame(width: 34, height: 34)
                            .background(StrandPalette.surfaceInset, in: Capsule())
                            .accessibilityLabel(Text(questRewardLabel(reward)))
                    }
                    Spacer(minLength: 0)
                    Text("+0 XP")
                        .font(StrandFont.headline.weight(.bold))
                        .foregroundStyle(red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Text("The window has closed.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(red)
                Text("00:00:00")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(red)
            }
            .frame(maxWidth: .infinity)

            Button {
                SystemHaptics.play(.tap)
                onDismiss()
            } label: {
                Text("UNDERSTOOD")
                    .font(StrandFont.headline.weight(.bold))
                    .tracking(4)
                    .foregroundStyle(done ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(done ? red : StrandPalette.surfaceInset,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .opacity(done ? 1 : 0.55)
                    .animation(.easeOut(duration: 0.25), value: done)
            }
            .buttonStyle(.plain)
            .disabled(!done)
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [red.opacity(0.16), StrandPalette.surfaceBase],
                startPoint: .top, endPoint: .bottom)
                .background(StrandPalette.surfaceRaised)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(red.opacity(0.70), lineWidth: 1)
        )
        .shadow(color: red.opacity(0.55), radius: questGlowRadius)
    }
}

// MARK: - The diagnostic screen
//
// THE WHOLE SCREEN, the way a diagnostic takes it: a dark, faintly red-gridded field, the warning line at
// the top, one glowing outline symbol for the subject, the name in heavy wide capitals, the line under
// it, one white button and a quieter second choice. The stress alarm uses it: high stress at rest is
// the one thing that interrupts whatever the wearer was doing.

struct DiagnosticAlertView: View {
    let overline: String
    let symbol: String
    let title: String
    let subtitle: String
    let message: String
    let primary: (label: String, action: () -> Void)
    var secondary: (label: String, action: () -> Void)? = nil
    /// Draw the symbol inside a thin glowing ring, the gauge look.
    var ringed = false

    @State private var typed = 0

    private let red = Color(.sRGB, red: 1.0, green: 0.23, blue: 0.23, opacity: 1)

    var body: some View {
        ZStack {
            Color(.sRGB, red: 0.07, green: 0.035, blue: 0.04, opacity: 1)
                .ignoresSafeArea()
            DiagnosticGrid()
                .stroke(red.opacity(0.07), lineWidth: 0.5)
                .ignoresSafeArea()
            RadialGradient(colors: [red.opacity(0.28), .clear], center: .center,
                           startRadius: 0, endRadius: 220)
                .offset(y: -120)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                    Text(overline)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .tracking(5)
                }
                .foregroundStyle(red)
                .padding(.top, 24)

                Spacer(minLength: 24)

                if ringed {
                    ZStack {
                        Circle()
                            .fill(RadialGradient(colors: [red.opacity(0.18), .clear], center: .center,
                                                 startRadius: 0, endRadius: 130))
                        Circle()
                            .strokeBorder(red.opacity(0.7), lineWidth: 2)
                            .shadow(color: red.opacity(0.6), radius: 10)
                        Image(systemName: symbol)
                            .font(.system(size: 92, weight: .light))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(red)
                            .shadow(color: red.opacity(0.9), radius: 12)
                            .shadow(color: red.opacity(0.5), radius: 26)
                    }
                    .frame(width: 250, height: 250)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 130, weight: .ultraLight))
                        .foregroundStyle(red)
                        .shadow(color: red.opacity(0.9), radius: 14)
                        .shadow(color: red.opacity(0.5), radius: 30)
                }

                Spacer(minLength: 24)

                Text(title.uppercased())
                    .font(.system(size: 38, weight: .black).width(.expanded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .shadow(color: .white.opacity(0.45), radius: 10)
                    .padding(.horizontal, 20)
                Text(subtitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 28)
                TypewriterText(text: message, shown: $typed)
                    .font(.system(size: 18))
                    .foregroundStyle(Color(white: 0.72))
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .padding(.horizontal, 28)

                Spacer(minLength: 24)

                Button {
                    SystemHaptics.play(.tap)
                    primary.action()
                } label: {
                    Text(primary.label)
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(3)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(Color.white, in: Capsule())
                        .shadow(color: .white.opacity(0.35), radius: 18)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 28)
                if let secondary {
                    Button {
                        SystemHaptics.play(.select)
                        secondary.action()
                    } label: {
                        Text(secondary.label)
                            .font(.system(size: 16, weight: .bold))
                            .tracking(3)
                            .foregroundStyle(Color(white: 0.7))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 28)
                    .padding(.top, 6)
                }
                Spacer().frame(height: 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { typed = message.count }
    }
}

/// The faint square grid behind a diagnostic screen.
private struct DiagnosticGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 32
        var x: CGFloat = 0
        while x <= rect.width {
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: rect.height)); x += step
        }
        var y: CGFloat = 0
        while y <= rect.height {
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: rect.width, y: y)); y += step
        }
        return p
    }
}

// MARK: - The quest closing itself
//
// The other half of the pop-up above: the system telling the wearer that it has seen the thing done.
// Same card, same blue, same typed line — it is the same voice closing the loop it opened.
//
// IT SAYS WHAT WAS MEASURED. "Quest complete" alone would be the app asking to be believed; the line
// underneath is the figure the data actually showed against the figure the quest asked for, written
// from the same evidence that closed it.

struct QuestCompletedPopupView: View {
    let completion: QuestStore.Completion
    let onDismiss: () -> Void

    @State private var typed = 0

    private var quest: Quest { completion.quest }

    /// The typed explanation: what was read, then how it was read.
    private var explanation: String {
        completion.summary + " Closed automatically — the system read it off your data, so there is "
            + "nothing for you to confirm."
    }

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.opacity(questScrimAlpha)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { typed = explanation.count }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusPositive)
                    Text("QUEST COMPLETE")
                        .font(StrandFont.headline.weight(.bold))
                        .tracking(3)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                VStack(spacing: 12) {
                    Text(quest.title.uppercased())
                        .font(StrandFont.title2)
                        .tracking(2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text(quest.target)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .multilineTextAlignment(.center)
                    TypewriterText(text: explanation, shown: $typed)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(StrandPalette.statusPositive.opacity(0.35), lineWidth: 1)
                )

                HStack(spacing: 12) {
                    ForEach(quest.rewards, id: \.rawValue) { reward in
                        Image(systemName: questRewardIcon(reward))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(questRewardTint(reward))
                            .frame(width: 34, height: 34)
                            .background(StrandPalette.surfaceInset, in: Capsule())
                            .accessibilityLabel(Text(questRewardLabel(reward)))
                    }
                    Spacer(minLength: 0)
                    Text("+\(quest.xp) XP")
                        .font(StrandFont.headline.weight(.bold))
                        .foregroundStyle(StrandPalette.statusPositive)
                }

                Button {
                    SystemHaptics.play(.tap)
                    onDismiss()
                } label: {
                    Text("ACKNOWLEDGED")
                        .font(StrandFont.headline.weight(.bold))
                        .tracking(4)
                        .foregroundStyle(StrandPalette.surfaceBase)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(StrandPalette.statusPositive,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(
                LinearGradient(
                    colors: [StrandPalette.statusPositive.opacity(0.14), StrandPalette.surfaceBase],
                    startPoint: .top, endPoint: .bottom)
                    .background(StrandPalette.surfaceRaised)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(StrandPalette.statusPositive.opacity(0.70), lineWidth: 1)
            )
            .shadow(color: StrandPalette.statusPositive.opacity(0.45), radius: questGlowRadius)
            .padding(questScreenMargin)
        }
        // The confirm cue, not the summon: this is the system handing something back, not asking.
        .task(id: completion.id) { SystemHaptics.play(.confirm) }
    }
}

extension View {
    /// Present the offered quest, if there is one, over whatever this is.
    func questHost() -> some View { modifier(QuestHostModifier()) }
}
