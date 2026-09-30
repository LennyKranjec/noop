import SwiftUI
import StrandAnalytics
import StrandDesign

// QuestPopupView.swift — the system interrupting.
//
// SwiftUI twin of the Android `QuestPopup`. A card over the app with the directive, what it is worth, and
// one button — the wearer has to answer it, which is the entire mechanism: a nudge that can be scrolled
// past is a nudge that is scrolled past.
//
// THE TAUNT IS SHOWN WHOLE (decision 19 — clinical restraint: no typewriter effect, no per-letter ticks).
// The summon haptic and the strap buzz still mark the arrival, once.
//
// IT DOES NOT FILL THE SCREEN. The card sits over a scrim so the app underneath stays visible around it.
//
// TELOS 2.0 (PROGRESS part B): restyled WITHOUT restructuring — the one host (`QuestHostModifier`) still
// decides what is on screen, in the same order (completion, failure, offer). Cards are the overlay-elevation
// card (radius 24, one neutral elevation shadow, a flat neutral hairline — no glow, no tinted top wash,
// decision 19); the quest world's hue is the effort blue, used only on its symbol and inset band.
//
// THE FAILURE CARD (HEALTH_V2 H3b/d, DESIGN_V2 §5.14 + coordinator decision 1): one card per day, red and
// consequential through its rail, its critical cost ink and its exact numbers — NOT through alarm: no
// per-letter ticks, no countdown, no 00:00:00, no strike-through, no warning triangle. The summary is shown
// whole, on as many lines as it needs, with the reading behind the miss and exactly what it cost.

/// Margins. Wide enough that the screen behind stays legible around the card.
private let questScreenMargin: CGFloat = 24

/// The modal cards' maximum width (§5.14: 360).
private let questCardMaxWidth: CGFloat = 360

/// The quest world's hue: the effort blue.
private var questBlue: Color { TelosColor.effort }

/// The scrim behind every quest card: black @ 0.5, no blur.
private var questScrim: some View {
    TelosColor.diagField.opacity(0.5).ignoresSafeArea()
}

/// The overlay-elevation card every quest pop-up shares: opaque `surface` (the app shows around it, not
/// through it), a flat neutral hairline and one neutral elevation shadow (§4.6 overlay). Decision 19: no
/// luminous hue edge, no tinted top glow, no radial glow behind. `hue` is kept for source compatibility.
private struct QuestCardSurface: ViewModifier {
    let hue: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous)
        return content
            .padding(TelosSpace.l)
            .frame(maxWidth: questCardMaxWidth)
            .background(shape.fill(TelosColor.surface))
            .overlay(shape.strokeBorder(TelosColor.lineStrong, lineWidth: TelosStroke.line))
            .telosElevation(.overlay)
    }
}

private extension View {
    func questCard(_ hue: Color) -> some View { modifier(QuestCardSurface(hue: hue)) }
}

struct QuestPopupView: View {
    let quest: Quest
    let onAccept: () -> Void
    let onDismiss: () -> Void
    /// Passed in rather than reached for: the strap lives behind the app model, and a pop-up that owned
    /// a BLE handle would be a screen that cannot be previewed or tested.
    var onSummonStrap: () -> Void = {}

    @State private var typed = 0

    /// NOT observed: the coach publishes on every streamed chunk, and this view only calls it from
    /// actions. Observing it re-rendered the whole view per chunk while any generation ran.
    @Environment(\.coachEngine) private var coachRef
    private var coach: AICoachEngine { requireCoach(coachRef) }
    @EnvironmentObject private var router: NavRouter

    private var full: String { quest.taunt }
    private var done: Bool { typed >= full.count }

    var body: some View {
        ZStack {
            questScrim
                // Taps on the scrim do nothing: the button is the only way out, because this is a decision
                // and not a toast.
                .contentShape(Rectangle())
                .onTapGesture { if !done { typed = full.count } }

            card
                .padding(questScreenMargin)
        }
        .task(id: quest.id) { await run() }
    }

    /// The summon, and the whole line at once (decision 19: no typewriter). One task keyed on the quest's
    /// id, so a re-render cannot re-summon.
    private func run() async {
        SystemHaptics.play(.summon)
        onSummonStrap()
        typed = full.count
    }

    private var card: some View {
        // WRAPS ITS CONTENT rather than filling the screen, so the card is only as tall as the quest
        // actually is and the app stays visible above and below it.
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            header
            body_
            rewardRow
            deadline
            acceptButton

            // ASK ABOUT IT, before deciding. The directive goes into the transcript as the system's own
            // opening line so a follow-up has something to be a follow-up to — and the quest stays
            // OFFERED, because asking a question about a commitment is not the same as making it.
            Button {
                TelosHaptics.play(.select)
                coach.surfaceQuest(title: quest.title, target: quest.target, taunt: quest.taunt)
                QuestOfferParking.shared.parkedOfferId = quest.id
                router.openCoach()
            } label: {
                Label("Ask about this", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopGhost)
            .disabled(!done)

            Button {
                TelosHaptics.play(.select)
                onDismiss()
            } label: {
                Text("Not today")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TelosPressButtonStyle())
            .disabled(!done)
        }
        .questCard(questBlue)
    }

    private var header: some View {
        HStack(spacing: TelosSpace.s) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(TelosType.glyphRow)
                .foregroundStyle(questBlue)
                .accessibilityHidden(true)
            Text("SYSTEM DIRECTIVE")
                .font(TelosType.labelLarge)
                .tracking(TelosType.Tracking.labelLarge)
                .foregroundStyle(TelosColor.textPrimary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    /// The body panel: name, the typed taunt, and the directive.
    private var body_: some View {
        VStack(spacing: TelosSpace.m) {
            Text(quest.title)
                .font(TelosType.title2)
                .foregroundStyle(TelosColor.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TypedLine(text: full, shown: typed)
            Text(quest.target)
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.mint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(TelosSpace.m)
        .pgInsetBand()   // neutral well — no tinted wash (decision 19)
    }

    /// What finishing it is worth: the systems it touches. The icons are a claim about WHICH systems,
    /// never about how much.
    private var rewardRow: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            PGOverline("WHAT IT TOUCHES")
            HStack(spacing: TelosSpace.m) {
                ForEach(quest.rewards, id: \.rawValue) { reward in
                    QuestRewardGlyph(reward: reward)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// THE CLOCK, and what runs out with it. Plain, and true: an accepted quest that runs out unmet is
    /// judged on its data and costs XP (`QuestPenaltyRules`) — a stated price, not an implied threat.
    private var deadline: some View {
        VStack(spacing: TelosSpace.xs) {
            Text("The window closes when the clock does. Accept it and miss it, and it costs XP.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            QuestCountdownView(quest: quest, fontSize: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var acceptButton: some View {
        Button {
            TelosHaptics.play(.commit)
            onAccept()
        } label: {
            Text("ACCEPT")
                .tracking(TelosType.Tracking.labelLarge)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.noopPrimary)
        // Until the line has finished typing there is nothing to accept yet — the wearer has not been
        // told what they are agreeing to.
        .disabled(!done)
    }
}

/// The taunt. Shown whole since decision 19.
private struct TypedLine: View {
    let text: String
    let shown: Int

    var body: some View {
        // Always the whole line (decision 19); `shown` is accepted for source compatibility.
        Text(text)
            .font(TelosType.subhead)
            .foregroundStyle(TelosColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

// MARK: - The host
//
// One place that decides whether a pop-up is on screen, so the shell can present it over every tab
// without each tab knowing about quests.

/// An offer the wearer is ASKING THE COACH about. The quest stays offered (asking is not deciding), but its
/// card must not sit over the chat that answers the question — the owner could not reach the chat behind it.
/// It is parked while the Coach is on screen and comes back the moment the wearer leaves the Coach.
@MainActor
final class QuestOfferParking: ObservableObject {
    static let shared = QuestOfferParking()
    @Published var parkedOfferId: String?
    @Published var coachVisible = false
}

struct QuestHostModifier: ViewModifier {
    @ObservedObject private var store = QuestStore.shared
    @ObservedObject private var parking = QuestOfferParking.shared
    @Environment(\.scenePhase) private var scenePhase

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
            } else if let quest = store.offered,
                      !(parking.coachVisible && parking.parkedOfferId == quest.id) {
                QuestPopupView(
                    quest: quest,
                    onAccept: { store.setState(id: quest.id, state: .active) },
                    onDismiss: { store.setState(id: quest.id, state: .declined) }
                )
                .transition(.opacity)
            }
        }
        .animation(TelosMotion.fade, value: store.offered?.id)
        .animation(TelosMotion.fade, value: store.completions.first?.id)
        .animation(TelosMotion.fade, value: store.failures.first?.id)
        // A WINDOW CAN CLOSE WITH NOTHING ELSE HAPPENING — no refresh, no sync — so the host checks the
        // clock itself once a minute while the app is open. Cheap: it only compares timestamps.
        // Tied to the scene: the loop stops when the app leaves the foreground (rather than waking the
        // process every minute in the background) and restarts on return — with an immediate sweep, so
        // anything that expired while away is caught at once.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                store.sweepExpired()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }
}

// MARK: - The quest running out (the failure card)
//
// RED AND CONSEQUENTIAL, NOT ALARMING (HEALTH_V2 H3b/d + coordinator decision 1). The same card family as
// the offer, now in critical: a 3 pt critical rail, the overline MISSED, the quest in plain `title2`, the
// whole summary on as many lines as it needs (no typewriter, no per-letter ticks), the reading behind it,
// and the price exactly as the ledger judged it — in critical ink. No countdown (the window has closed;
// "00:00:00" said nothing), no strike-through, no warning triangle. One acknowledgement button.
// Physiology / unmeasured quests read "No penalty" from the ledger itself and never in critical.

struct QuestFailedPopupView: View {
    let failure: QuestStore.Completion
    let onDismiss: () -> Void

    /// The penalty, as the ledger judged it. Observed: the card is usually up before the assessor has
    /// read the day's data, and the price lands on it the moment the judgement is made.
    @ObservedObject private var penalties = QuestPenaltyStore.shared

    private var judgement: QuestJudgement? { penalties.judgement(for: quest.id) }
    private var pending: Bool { penalties.isPending(quest.id) }
    private var charged: Bool { judgement?.outcome == .penalised }

    /// The figure in the corner: the price once judged, "PENDING" while the data is awaited, and "+0 XP"
    /// only for a quest nothing can judge (no goal).
    private var costText: String {
        if let judgement { return judgement.costText.uppercased() }
        if pending { return "PENDING" }
        return "+0 XP"
    }

    private var quest: Quest { failure.quest }
    private var red: Color { TelosColor.critical }

    var body: some View {
        ZStack {
            questScrim
                .contentShape(Rectangle())
            card
                .padding(questScreenMargin)
        }
        // ONE haptic for one event, from the vocabulary (the heavier penalty pattern) — never a tick per
        // letter. Keyed on the failure's id so a re-render cannot replay it.
        .task(id: failure.id) { TelosHaptics.play(.penalty) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: TelosSpace.m) {
            HStack(alignment: .center, spacing: TelosSpace.s) {
                Image(systemName: "arrow.down.right.circle")
                    .font(TelosType.glyphRow)
                    .foregroundStyle(red)
                    .accessibilityHidden(true)
                PGOverline("MISSED", ink: red)
                Spacer(minLength: TelosSpace.s)
                Text(verbatim: costText)
                    .font(TelosType.numeralS)
                    .foregroundStyle(charged ? red : TelosColor.textTertiary)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: TelosSpace.xs) {
                Text(quest.title)
                    .font(TelosType.title2)
                    .foregroundStyle(TelosColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(quest.target)
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // THE SUMMARY, WHOLE. Multi-line, shown at once — the consequence is carried by the numbers.
            Text(failure.summary)
                .font(TelosType.body)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // THE PRICE, SPELLED OUT: the reading behind the miss, how far short, which multipliers, the
            // streak, the make-up — or, for a quest the data never carried, that it is not being punished.
            penaltyPanel

            VStack(alignment: .leading, spacing: TelosSpace.s) {
                PGOverline("WHAT IT WOULD HAVE TOUCHED")
                HStack(spacing: TelosSpace.m) {
                    ForEach(quest.rewards, id: \.rawValue) { reward in
                        QuestRewardGlyph(reward: reward, dimmed: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                TelosHaptics.play(.select)
                onDismiss()
            } label: {
                Text("UNDERSTOOD")
                    .tracking(TelosType.Tracking.labelLarge)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.noopPrimary)
        }
        .overlay(alignment: .leading) {
            // The rail: the card's seriousness, drawn once, down the leading edge of the content.
            Capsule(style: .continuous)
                .fill(red)
                .frame(width: TelosStroke.rail)
                .offset(x: -TelosSpace.l + TelosStroke.rail)
                .accessibilityHidden(true)
        }
        .questCard(red)
    }

    @ViewBuilder
    private var penaltyPanel: some View {
        if let judgement {
            VStack(alignment: .leading, spacing: TelosSpace.xs) {
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
                if let streak = judgement.streakText {
                    Text(verbatim: streak.uppercased())
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(red)
                }
                if let debt = judgement.debtText {
                    Text(debt)
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(questPenaltyLevelNote)
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(TelosSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                            .fill(charged ? TelosColor.criticalWash : TelosColor.surfaceInset))
        } else if pending {
            Text("The penalty is decided by the data, not the clock. It lands here, and on Today's board, as soon as the day is read.")
                .font(TelosType.caption)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The diagnostic screen
//
// THE WHOLE SCREEN, the way a diagnostic takes it: the black diagnostic field, faintly critical-gridded,
// the overline at the top, one outline symbol for the subject, the name in heavy expanded capitals, the
// line under it, one white button and a quieter second choice. The stress alarm uses it (opt-in).
//
// TELOS 2.0 (DESIGN_V2 §5.12): tokens only (`diagField`, `diagAlarm` = critical, `diagText`/`diagMuted`,
// `diagnostic`/`diagnosticS`, the `scale` overline); the grid is `hair` critical @ 0.07. Decision 19: no
// radial glow, no red symbol shadow, no typewriter (`TypewriterText` shows the whole line); no summon
// haptic. API unchanged.

struct DiagnosticAlertView: View {
    let overline: String
    let symbol: String
    let title: String
    let subtitle: String
    let message: String
    let primary: (label: String, action: () -> Void)
    var secondary: (label: String, action: () -> Void)? = nil
    /// Draw the symbol inside a thin ring, the gauge look.
    var ringed = false

    @State private var typed = 0

    private var red: Color { TelosColor.diagAlarm }

    var body: some View {
        ZStack {
            TelosColor.diagField
                .ignoresSafeArea()
            DiagnosticGrid()
                .stroke(red.opacity(0.07), lineWidth: TelosStroke.hair)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "waveform.path.ecg")
                        .font(TelosType.glyphControl)
                        .accessibilityHidden(true)
                    Text(overline)
                        .font(TelosType.labelLarge)
                        .tracking(TelosType.Tracking.labelLarge)
                        .textCase(.uppercase)
                }
                .foregroundStyle(red)
                .padding(.top, TelosSpace.xl)

                Spacer(minLength: TelosSpace.xl)

                symbolView

                Spacer(minLength: TelosSpace.xl)

                Text(title.uppercased())
                    .font(TelosType.diagnostic)
                    .tracking(TelosType.Tracking.diagnostic)
                    .foregroundStyle(TelosColor.diagText)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, TelosSpace.l)
                Text(subtitle)
                    .font(TelosType.diagnosticS)
                    .tracking(TelosType.Tracking.diagnosticS)
                    .foregroundStyle(red)
                    .multilineTextAlignment(.center)
                    .padding(.top, TelosSpace.m)
                    .padding(.horizontal, TelosSpace.xl)
                TypewriterText(text: message, shown: $typed)
                    .font(TelosType.body)
                    .foregroundStyle(TelosColor.diagMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, TelosSpace.s)
                    .padding(.horizontal, TelosSpace.xl)

                Spacer(minLength: TelosSpace.xl)

                Button {
                    TelosHaptics.play(.commit)
                    primary.action()
                } label: {
                    Text(primary.label)
                        .font(TelosType.diagnosticS)
                        .tracking(TelosType.Tracking.diagnosticS)
                        .foregroundStyle(TelosColor.diagField)
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Capsule(style: .continuous).fill(TelosColor.diagText))
                }
                .buttonStyle(TelosPressButtonStyle())
                .padding(.horizontal, TelosSpace.xl)
                if let secondary {
                    Button {
                        TelosHaptics.play(.select)
                        secondary.action()
                    } label: {
                        Text(secondary.label)
                            .font(TelosType.headline)
                            .tracking(TelosType.Tracking.diagnosticS)
                            .foregroundStyle(TelosColor.diagMuted)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .padding(.horizontal, TelosSpace.xl)
                    .padding(.top, TelosSpace.xs)
                }
                Spacer().frame(height: TelosSpace.l)
            }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { typed = message.count }
    }

    @ViewBuilder
    private var symbolView: some View {
        if ringed {
            ZStack {
                Circle()
                    .strokeBorder(red.opacity(0.7), lineWidth: TelosStroke.data)
                Image(systemName: symbol)
                    .font(TelosType.numeralFont(size: 92, weight: .light))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(red)
            }
            .frame(width: 250, height: 250)
            .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(TelosType.numeralFont(size: 130, weight: .ultraLight))
                .foregroundStyle(red)
                .accessibilityHidden(true)
        }
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
// Same card family, in the positive green — the same voice closing the loop it opened.
//
// IT SAYS WHAT WAS MEASURED. "Quest complete" alone would be the app asking to be believed; the line
// underneath is the figure the data actually showed against the figure the quest asked for, written
// from the same evidence that closed it.

struct QuestCompletedPopupView: View {
    let completion: QuestStore.Completion
    let onDismiss: () -> Void

    @State private var typed = 0

    private var quest: Quest { completion.quest }

    /// What the completion pays. A make-up quest pays back its share of the penalty it was owed for —
    /// that is what the ledger credits (`QuestLedger.credit`), so that is what the card says.
    private var xpText: String {
        if QuestDebt.isDebtQuest(quest.id), let debt = QuestPenaltyStore.shared.debt(for: quest.id) {
            return "+\(debt.restoreXp) XP BACK"
        }
        return "+\(quest.xp) XP"
    }

    /// The explanation (shown whole): what was read, then how it was read.
    private var explanation: String {
        completion.summary + " Closed automatically — the system read it off your data, so there is "
            + "nothing for you to confirm."
    }

    var body: some View {
        ZStack {
            questScrim
                .contentShape(Rectangle())
                .onTapGesture { typed = explanation.count }

            VStack(alignment: .leading, spacing: TelosSpace.m) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "checkmark.seal")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(TelosColor.positive)
                        .accessibilityHidden(true)
                    PGOverline("QUEST COMPLETE", ink: TelosColor.positive)
                    Spacer(minLength: TelosSpace.s)
                    // A neutral figure, not a celebratory one (decision 19).
                    Text(verbatim: xpText)
                        .font(TelosType.numeralS)
                        .foregroundStyle(TelosColor.textPrimary)
                }
                .accessibilityElement(children: .combine)

                VStack(alignment: .leading, spacing: TelosSpace.s) {
                    Text(quest.title)
                        .font(TelosType.title2)
                        .foregroundStyle(TelosColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(quest.target)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    TypewriterText(text: explanation, shown: $typed)
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TelosSpace.m)
                .pgInsetBand()   // neutral well — no green wash (decision 19)

                HStack(spacing: TelosSpace.m) {
                    ForEach(quest.rewards, id: \.rawValue) { reward in
                        QuestRewardGlyph(reward: reward)
                    }
                }

                Button {
                    TelosHaptics.play(.select)
                    onDismiss()
                } label: {
                    Text("ACKNOWLEDGED")
                        .tracking(TelosType.Tracking.labelLarge)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.noopPrimary)
            }
            .questCard(TelosColor.positive)
            .padding(questScreenMargin)
        }
        // The success cue, not the summon: this is the system handing something back, not asking.
        .task(id: completion.id) { TelosHaptics.play(.success) }
    }
}

extension View {
    /// Present the offered quest, if there is one, over whatever this is.
    func questHost() -> some View { modifier(QuestHostModifier()) }
}
