import SwiftUI
import Combine
import MarkdownUI
import StrandDesign

/// Coach, the one feature in NOOP that talks to the network.
///
/// It is strictly opt-in and bring-your-own-key: the user pastes their own OpenAI
/// or Anthropic API key (stored in the macOS Keychain by `AICoachEngine`), and only
/// a compact text summary of their metrics plus their question ever leaves the Mac.
/// Nothing is sent until a key is saved and a question asked.
///
/// This screen compiles against `AICoachEngine`'s public API (the macos-core agent's
/// contract): `hasKey`, `provider` / `provider.modelOptions`, `model`, `messages`,
/// `sending`, `errorText`, `setKey(_:)`, `clearKey()`, and `send(_:)`.
///
/// STREAMING RE-RENDERS ONLY THE LAST MESSAGE (Telos 2.0 §6.9, §2.1 rule 5). The engine republishes
/// `messages` up to ~60 times a second while a reply streams, and every publish used to re-evaluate this
/// whole screen: header, chips, composer and every bubble in the transcript. Now:
///   • `CoachView` is a thin shell. It holds the environment objects and hands them, by reference, to an
///     `Equatable` `CoachScreen`, so a publish re-runs only this three-line body and SwiftUI skips the
///     screen (same objects ⇒ equal).
///   • The screen's chrome reads ONE de-duplicated snapshot (`CoachChromeStore.chrome`: sending, error,
///     provider, model, counts…). A streamed chunk changes none of it, so the screen does not redraw.
///   • The transcript list observes only the ROW LIST (ids + roles, `CoachTranscriptModel`). Each bubble
///     observes its own text box; a chunk updates one box, so one leaf — the last reply — re-renders.
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine
    /// K8: used by "Save to Journal" — saves the coach advice as a journal entry with the text
    /// in the notes field, so it appears alongside other journal entries in Insights.
    @EnvironmentObject var repo: Repository
    /// Handed to the Habits hub the Coach links to (it routes back through it).
    @EnvironmentObject var router: NavRouter

    var body: some View {
        CoachScreen(coach: coach, repo: repo, router: router)
            .equatable()
            // A quest the wearer is asking about is parked while the chat is on screen (QuestOfferParking).
            .onAppear { QuestOfferParking.shared.coachVisible = true }
            .onDisappear {
                QuestOfferParking.shared.coachVisible = false
                QuestOfferParking.shared.parkedOfferId = nil
            }
    }
}

// MARK: - The chrome snapshot

/// Everything the Coach screen's chrome reads from the engine, as one value. Published only when it
/// CHANGES, so a streamed chunk (which changes only the last message's text) redraws nothing here.
private struct CoachChrome: Equatable {
    var isConfigured: Bool
    var sending: Bool
    var errorText: String?
    var keyRejected: Bool
    var provider: AIProvider
    var model: String
    var availableModels: [String]
    var hasMessages: Bool
    var lastIsAssistant: Bool
    var pendingPrompt: String?
    var dataConsent: Bool
    var suggestions: [String]

    @MainActor
    init(_ coach: AICoachEngine, previous: CoachChrome?, refreshSuggestions: Bool = false) {
        sending = coach.sending
        // `isConfigured` reads the Keychain (`hasKey`). The key cannot change while a reply streams, so
        // mid-send the last reading stands instead of a Keychain read per chunk.
        if sending, let previous {
            isConfigured = previous.isConfigured
        } else {
            isConfigured = coach.isConfigured
        }
        errorText = coach.errorText
        keyRejected = coach.keyRejected
        provider = coach.provider
        model = coach.model
        availableModels = coach.availableModels
        hasMessages = !coach.messages.isEmpty
        lastIsAssistant = coach.messages.last?.role == .assistant
        pendingPrompt = coach.pendingPrompt
        dataConsent = coach.dataConsent
        // Contextual chips from today's bands (`AICoachEngine.suggestions`): re-read when the days change
        // or when nothing is streaming; mid-send the chips are disabled anyway.
        if let previous, sending, !refreshSuggestions {
            suggestions = previous.suggestions
        } else {
            suggestions = coach.suggestions
        }
    }
}

/// Holds the snapshot and keeps it current: one subscription to the engine's change signal (delivered
/// after the change lands) and one to the day list (the chips' data). Built once per screen
/// (`@StateObject`), so the per-chunk shell re-evaluation never rebuilds it.
@MainActor
private final class CoachChromeStore: ObservableObject {
    @Published private(set) var chrome: CoachChrome
    private var subscriptions: Set<AnyCancellable> = []

    init(coach: AICoachEngine, repo: Repository) {
        chrome = CoachChrome(coach, previous: nil)
        coach.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coach] _ in
                guard let self, let coach else { return }
                self.sync(coach, refreshSuggestions: false)
            }
            .store(in: &subscriptions)
        repo.$days
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coach] _ in
                guard let self, let coach else { return }
                self.sync(coach, refreshSuggestions: true)
            }
            .store(in: &subscriptions)
    }

    func sync(_ coach: AICoachEngine, refreshSuggestions: Bool) {
        let next = CoachChrome(coach, previous: chrome, refreshSuggestions: refreshSuggestions)
        if next != chrome { chrome = next }
    }
}

// MARK: - The transcript's row list and per-message text

/// One message's text, observed by exactly one bubble.
@MainActor
private final class CoachMessageBox: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

/// The transcript as ROWS (id + role) plus a text box per message. `rows` publishes only when a message
/// is added, removed or reordered; a streamed chunk only updates the matching box.
@MainActor
private final class CoachTranscriptModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let role: ChatMessage.Role
    }

    @Published private(set) var rows: [Row] = []
    private var boxes: [UUID: CoachMessageBox] = [:]

    init(messages: [ChatMessage]) {
        apply(messages)
    }

    func box(for id: UUID) -> CoachMessageBox {
        if let box = boxes[id] { return box }
        let box = CoachMessageBox(text: "")
        boxes[id] = box
        return box
    }

    func apply(_ messages: [ChatMessage]) {
        var next: [UUID: CoachMessageBox] = [:]
        next.reserveCapacity(messages.count)
        for message in messages {
            if let box = boxes[message.id] {
                if box.text != message.text { box.text = message.text }
                next[message.id] = box
            } else {
                next[message.id] = CoachMessageBox(text: message.text)
            }
        }
        boxes = next
        let nextRows = messages.map { Row(id: $0.id, role: $0.role) }
        if nextRows != rows { rows = nextRows }
    }
}

// MARK: - The screen

private struct CoachScreen: View, Equatable {
    let coach: AICoachEngine
    let repo: Repository
    let router: NavRouter

    /// Same engine, same repository, same router ⇒ nothing to redraw. What changes inside them reaches
    /// this screen through `chromeStore`, the transcript model and the per-message boxes.
    static func == (lhs: CoachScreen, rhs: CoachScreen) -> Bool {
        lhs.coach === rhs.coach && lhs.repo === rhs.repo && lhs.router === rhs.router
    }

    @StateObject private var chromeStore: CoachChromeStore

    init(coach: AICoachEngine, repo: Repository, router: NavRouter) {
        self.coach = coach
        self.repo = repo
        self.router = router
        _chromeStore = StateObject(wrappedValue: CoachChromeStore(coach: coach, repo: repo))
    }

    private var chrome: CoachChrome { chromeStore.chrome }

    /// Draft text in the composer (the question being typed).
    /// K15: the composer draft is persisted to UserDefaults so it survives an app relaunch.
    /// Restored on first appear, saved on every change. Keyed identically to the Android twin.
    private static let draftKey = "coach.composerDraft"
    @State private var draft: String = UserDefaults.standard.string(forKey: "coach.composerDraft") ?? ""
    /// The pending debounced write of `draft`. See the `onChange` that owns it.
    @State private var draftSave: Task<Void, Never>?
    /// The corrected key, typed into the editor a rejection opens. Cleared on save so a secret does not
    /// sit in view state after it has been stored. Twin of the Kotlin `keyFix`.
    @State private var keyFix: String = ""
    @FocusState private var composerFocused: Bool

    /// K2: confirmation gate for the destructive "Clear conversation" action.
    @State private var showClearConfirm = false
    /// Today's spend on the current model, counted here. Held rather than computed in `body`: it lives
    /// in preferences, so nothing publishes a change and the view has to be told when to re-read.
    @State private var budget: AITokenBudget.Reading?
    /// What the provider itself said about its allowances on its last reply. Outranks `budget` when it
    /// is there — see `budgetGauge`.
    @State private var rateLimit: AIRateLimitReading?
    /// The ⋯ sheet holding consent, instructions, the brief and the connection.
    @State private var showCoachMenu = false
    /// The wearer's own tasks: describe one, the coach structures it, it lands on Today's quest strip.
    @State private var showTaskSheet = false
    /// The Habits hub and Goals, reached from the Coach (decision 3 / 14).
    @State private var showHabits = false
    @State private var showGoals = false
    /// The software keyboard is up. The dock's two chip rows step aside while it is (see `composerDock`).
    /// Read from the keyboard notifications rather than `composerFocused`, so the key-repair field raising
    /// the keyboard gets the same room.
    @State private var keyboardUp = false

    // K4: on-device voice input for the composer (iOS only). macOS gets a no-op stub via
    // `#if os(iOS)` guards — the shared file keeps compiling for both targets.
    #if os(iOS)
    @StateObject private var voiceInput = CoachVoiceInput()
    #endif

    // MARK: The screen
    //
    // THE CHAT IS THE WHOLE SCREEN, which is the Android lane's arrangement and the reason this no longer
    // goes through `ScreenScaffold`. That scaffold puts its content in a vertical scroll, which hands
    // children an unbounded height — and a docked composer needs the opposite: a known viewport to sit at
    // the bottom of. So the chat lays itself out, and the transcript is weighted against the input row.
    //
    // THE HEADER FLOATS; THE COMPOSER SITS ON AN OPAQUE BAND (§6.9: no glass — the transcript scrolls
    // under it). The transcript pads itself by exactly what each takes, so nothing is permanently hidden.
    //
    // EVERYTHING ELSE MOVED INTO A SHEET. Consent, the editable instructions, the morning brief, the
    // provider and the model are one ⋯ button.
    //
    // THE UNCONFIGURED STATE KEEPS THE SCAFFOLD. Setup is a form, a form wants a scroll, and there is no
    // conversation to give the screen to yet.

    var body: some View {
        Group {
            if chrome.isConfigured {
                chatScreen
            } else {
                ScreenScaffold(title: "System",
                               subtitle: "Ask about your charge, effort, rest and workouts, grounded in your own numbers.",
                               topBackground: liquidScaffoldSky()) {
                    CoachSetupCard(coach: coach)
                }
            }
        }
        .sheet(isPresented: $showCoachMenu) {
            CoachMenuSheet(coach: coach, onDone: { showCoachMenu = false })
                .environmentObject(coach)
        }
        // Environment passed explicitly: a sheet on macOS 13 does not inherit it.
        .sheet(isPresented: $showTaskSheet) {
            CustomTaskSheet { showTaskSheet = false }
                .environmentObject(coach)
        }
        .sheet(isPresented: $showHabits) {
            linkedScreen(title: "Habits", onDone: { showHabits = false }) { HabitsHubView() }
        }
        .sheet(isPresented: $showGoals) {
            linkedScreen(title: "Goals", onDone: { showGoals = false }) { GoalsView() }
        }
        // macOS only. On iOS these two live in `connectionMenu` (in the settings sheet) instead, because
        // this bar is hidden for a primary tab root and VISIBLE in the pillar sheet, so leaving them here
        // would render nothing on the Coach tab and a duplicate of the menu in the sheet. (#2206)
        #if os(macOS)
        .toolbar {
            if chrome.isConfigured {
                // K2: wipe the persisted + in-memory conversation. Confirmed, since it's destructive.
                ToolbarItem {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .help("Clear the saved conversation")
                    .accessibilityLabel("Clear conversation")
                    .disabled(!chrome.hasMessages)
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        coach.disconnect()
                    } label: {
                        Label("Disconnect", systemImage: "gearshape")
                    }
                    .help("Forget the saved key and disconnect")
                    .accessibilityLabel("Disconnect provider")
                }
            }
        }
        #endif
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { coach.clearConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the saved conversation from this device. Coach history is your own notes, not medical advice.")
        }
        // K2 + K5 ordering matters and every step gates on an EMPTY transcript, so this is ONE `.task`
        // running sequentially (separate `.task`s can interleave at their await points on the same
        // actor): restore whatever the prior launch persisted, THEN surface a brief the scheduled
        // notification already generated (if any), THEN the interactive first-open brief — so
        // `startBriefIfNeeded` only ever runs over the network when BOTH of the above left the
        // transcript genuinely empty.
        .task {
            await coach.loadPersistedMessagesIfNeeded()
            // Gated on the transcript BEFORE consuming. `consumeStoredBrief()` clears the unconsumed
            // flag, and `surfaceScheduledBrief` then drops the text if a transcript exists, so a brief
            // that arrived on a day with a conversation already open was consumed and thrown away, gone
            // for good. Android checked first and so only ever failed to SHOW it (#2087).
            if coach.messages.isEmpty, let stored = CoachBriefScheduler.consumeStoredBrief() {
                coach.surfaceScheduledBrief(stored)
            }
            CoachBriefScheduler.activateIfEnabled { await coach.generateBrief() }
            await coach.startBriefIfNeeded()
        }
        // #1862: a question handed over by the Today launcher sheet. Cleared BEFORE sending so a view
        // rebuild mid-flight cannot send it twice, and gated on `isConfigured` so an unconfigured handoff
        // (which the launcher does not produce, but a future caller might) degrades to showing setup
        // rather than a failed request. Keyed on the snapshot's copy of `pendingPrompt`, which follows
        // the engine's.
        .task(id: chrome.pendingPrompt) {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            // NOT awaited in this task: clearing `pendingPrompt` above changes this task's id, so SwiftUI
            // cancels it, and a send awaited here died with "cancelled" before the reply arrived. The
            // engine outlives the view, so the send runs on its own.
            let engine = coach
            Task { @MainActor in await engine.send(prompt) }
        }
        // K15: persist the composer draft so it survives an app relaunch.
        //
        // DEBOUNCED. A defaults write per keystroke is a synchronous write on the main thread for every
        // letter; the draft only has to survive a relaunch, and one write after the typing pauses does
        // that just as well.
        .onChangeCompat(of: draft) { newValue in
            draftSave?.cancel()
            draftSave = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                UserDefaults.standard.set(newValue, forKey: Self.draftKey)
            }
        }
        // K14: haptic feedback when a reply arrives (sending goes true → false).
        .onChangeCompat(of: chrome.sending) { isSending in
            if !isSending && !coach.messages.isEmpty {
                TelosHaptics.play(.settle)
            }
        }
        // A consent toggle AFTER the initial load re-checks the brief (the original `.task(id:)`
        // behaviour); the guard inside `startBriefIfNeeded` (messages.isEmpty) keeps this a no-op once
        // a conversation exists.
        .onChangeCompat(of: chrome.dataConsent) { _ in
            Task { await coach.startBriefIfNeeded() }
        }
        // THE CHAT SHOWS WHEN IT IS ASKED FOR. Everything that opens the Coach (`router.openCoach()`: the
        // Today launcher, a quest, a workout's feedback, the Habits hub's "Ask the coach") lands on this
        // tab. If one of this screen's own sheets is up, that request switches to a tab that is already
        // selected and leaves the sheet covering the conversation, and the Habits hub opened FROM here has
        // exactly such a button. So a coach request closes them. `$requestedDestination` publishes on
        // every assignment, before the shell resets it to nil; the replay on subscription is a no-op.
        .onReceive(router.$requestedDestination) { destination in
            guard destination == .coach else { return }
            showHabits = false
            showGoals = false
            showTaskSheet = false
            showCoachMenu = false
        }
        #if os(iOS)
        // The dock's chip rows step aside while the keyboard is up (see `composerDock`).
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if !keyboardUp { keyboardUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardUp { keyboardUp = false }
        }
        // A dictation left running when the wearer switches tab keeps the microphone open behind a
        // screen they can no longer see. The words so far are already in the draft.
        .onDisappear {
            if voiceInput.isRecording { voiceInput.stopTranscribing { _ in } }
        }
        #endif
    }

    /// A screen the Coach links to (Habits, Goals), in its own navigation stack with a Done button. The
    /// environment is passed explicitly: a sheet on macOS 13 does not inherit it.
    @ViewBuilder
    private func linkedScreen<Content: View>(title: LocalizedStringKey, onDone: @escaping () -> Void,
                                             @ViewBuilder content: () -> Content) -> some View {
        if let model = resolvedAppModel(nil) {
            NavigationStack {
                content()
                    .background(TelosColor.canvas.ignoresSafeArea())
                    .navigationTitle(Text(title))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
            }
            .environmentObject(model)
            .environmentObject(model.repo)
            .environmentObject(model.live)
            .environmentObject(model.profile)
            .environmentObject(coach)
            .environmentObject(router)
            #if os(iOS)
            .presentationBackground(TelosColor.canvas)
            #endif
        }
    }

    // MARK: - Connected state

    /// THE MODEL, one tap from the conversation — and at the BOTTOM of it.
    ///
    /// It started in the title row, which is exactly where the level strip's pentagon hangs a third of
    /// itself over every screen: the chip sat under it and could not be tapped. Above the composer it is
    /// out of the pentagon's way, and it is also nearer the thing it affects — switching between a fast
    /// model and a thorough one is what you do as you type a question, not while setting the screen up.
    private var modelChip: some View {
        HStack {
            Menu {
                Picker("Model", selection: Binding(get: { chrome.model }, set: { coach.model = $0 })) {
                    ForEach(chrome.availableModels, id: \.self) { m in Text(m).tag(m) }
                }
                Divider()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                }
                .disabled(!coach.hasKey)
            } label: {
                HStack(spacing: TelosSpace.xs) {
                    Image(systemName: "cpu")
                        .font(TelosType.glyphDelta)
                    Text(shortModelName)
                        .font(TelosType.scaleNumber)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(TelosType.glyphDelta)
                }
                .foregroundStyle(TelosColor.textSecondary)
                .padding(.horizontal, TelosSpace.m)
                .frame(minHeight: 28)
                .background(TelosColor.surfaceInset, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Model")
            Spacer(minLength: 0)
            budgetPill
        }
        // Re-read after every turn, and whenever the model changes — the reading lives in preferences
        // rather than on the engine, so nothing publishes it. `sending` is the trigger that matters:
        // it goes false exactly once a turn has been paid for.
        .onAppear { refreshBudget() }
        .onChangeCompat(of: chrome.sending) { _ in refreshBudget() }
        .onChangeCompat(of: chrome.model) { _ in refreshBudget() }
    }

    /// TODAY'S ALLOWANCE, beside the model it belongs to: TOKENS, out of the day's ceiling.
    ///
    /// The free tier is metered per model, and running out looks from the inside exactly like the app
    /// breaking: the coach stops answering, mid-conversation, with nothing said about why. A bar that
    /// fills as the day goes on is the difference between a cliff and a slope you can see.
    ///
    /// WHERE THE NUMBER COMES FROM, in order of authority:
    ///
    ///   1. A daily token window in the response headers, if the provider sends one — live and exact.
    ///   2. The provider's own statement of the day's usage, which Groq makes on a daily-limit rejection
    ///      ("tokens per day (TPD): Limit 200000, Used …"). The count snaps to it and stays synced.
    ///   3. The tokens this app's replies reported, summed.
    ///
    /// Groq's API does not publish daily token usage on an ordinary reply — its headers carry requests
    /// per DAY and tokens per MINUTE, and the per-day token figure lives on the dashboard — so between
    /// rejections (3) is what there is, and it cannot see what the same key spent elsewhere. The menu
    /// says which of the three is on screen.
    ///
    /// ALWAYS ON, including at zero on a fresh morning. A gauge that is absent exactly when the answer
    /// is "all of it" is a gauge you cannot learn to trust.
    @ViewBuilder
    private var budgetPill: some View {
        if let gauge = budgetGauge {
            Menu {
                Text(gauge.detail)
                if let budget, gauge.isLocal {
                    if budget.unmetered > 0 {
                        // SAID OUT LOUD. Those turns cost something the provider did not report, so the
                        // figure above is a floor. A budget that quietly under-counts is worse than none.
                        Text("\(budget.unmetered) turn(s) today reported no usage, so this is a floor.")
                    }
                    if let synced = budget.syncedAt {
                        Text("Last set to the provider's own figure at "
                             + synced.formatted(date: .omitted, time: .shortened) + ".")
                    } else {
                        Text("Not yet confirmed by the provider today. It states the real figure when "
                             + "the day's limit is reached, and this count snaps to it then.")
                    }
                }
                if let limits = rateLimit {
                    // EVERYTHING ELSE THE PROVIDER SAID on its last reply, spelled out — the window that
                    // bites first is not always the one on the bar.
                    if let r = limits.requests {
                        Text("Requests: \(r.remaining) of \(r.limit) left, resets in \(shortDuration(r.resetSeconds))")
                    }
                    if let t = limits.tokens, !t.isDaily {
                        Text("Tokens this minute: \(t.remaining.formatted()) of \(t.limit.formatted()) left")
                    }
                }
                Divider()
                Button {
                    AITokenBudget.reset(model: coach.model)
                    AIRateLimit.forget(model: coach.model)
                    refreshBudget()
                } label: {
                    Label("Reset the local count", systemImage: "arrow.counterclockwise")
                }
            } label: {
                HStack(spacing: TelosSpace.xs) {
                    // A short bar rather than a percentage: the question is "how much is left", which
                    // is a length, and a length is read without being parsed.
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(TelosColor.surfaceInset)
                            .overlay(Capsule().strokeBorder(TelosColor.line, lineWidth: TelosStroke.hair))
                            .frame(width: 34, height: 3)
                        Capsule()
                            .fill(gauge.isWarning ? TelosColor.warning : StrandPalette.accent)
                            .frame(width: max(2, 34 * CGFloat(gauge.fraction)), height: 3)
                    }
                    Text(gauge.label)
                        .font(TelosType.scaleNumber)
                        .foregroundStyle(gauge.isWarning ? TelosColor.warning : TelosColor.textTertiary)
                }
                .padding(.horizontal, TelosSpace.m)
                .frame(minHeight: 28)
                .background(TelosColor.surfaceInset, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Token allowance"))
            .accessibilityValue(Text(gauge.detail))
        }
    }

    /// What the bar draws, and where the numbers came from.
    private struct BudgetGauge {
        let label: String
        let detail: String
        let fraction: Double
        /// True when this is the local count rather than a live provider window.
        let isLocal: Bool
        var isWarning: Bool { fraction >= AITokenBudget.warnAt }
    }

    /// Tokens today, from the most authoritative source available — see `budgetPill`.
    private var budgetGauge: BudgetGauge? {
        if let tokens = rateLimit?.dailyTokens, let model = rateLimit?.model {
            return BudgetGauge(
                label: shortCount(tokens.used) + " / " + shortCount(tokens.limit),
                detail: "\(tokens.used.formatted()) of \(tokens.limit.formatted()) tokens used today on "
                    + "\(model), live from the provider.",
                fraction: tokens.fraction,
                isLocal: false)
        }
        guard let budget else { return nil }
        let origin = budget.syncedAt == nil
            ? "counted from this app's replies"
            : "synced to the provider's figure, plus this app's replies since"
        return BudgetGauge(
            label: shortCount(budget.used) + " / " + shortCount(budget.limit),
            detail: "\(budget.used.formatted()) of \(budget.limit.formatted()) tokens today on "
                + "\(budget.model), \(origin).",
            fraction: budget.fraction,
            isLocal: true)
    }

    /// "12.4k", "200k", "840". Thousands, because the exact token count of a conversation is not a
    /// number anybody acts on and six digits beside a model name is just noise; the precise figure is
    /// one tap away in the menu.
    private func shortCount(_ n: Int) -> String {
        if n >= 100_000 { return "\(n / 1000)k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    /// A reset window, as a person would say it.
    private func shortDuration(_ seconds: Double) -> String {
        if seconds >= 3600 { return "\(Int((seconds / 3600).rounded()))h" }
        if seconds >= 60 { return "\(Int((seconds / 60).rounded()))m" }
        return "\(Int(seconds.rounded()))s"
    }

    private func refreshBudget() {
        budget = AITokenBudget.reading(model: coach.model)
        rateLimit = AIRateLimit.reading(model: coach.model)
    }

    /// One round header button: a 32 pt icon disc (`surfaceInset` + `line`), the pre-2.0 size, in a
    /// 34 × 44 pt target. They sit in the title row and must not drift apart.
    ///
    /// NARROW ON PURPOSE. The level strip's pentagon hangs about 20 pt into the top of every tab, centred.
    /// Four 44 pt-wide buttons reached back under it on a 375–390 pt phone, and the pentagon (which takes
    /// taps: it opens the level timeline) swallowed the left one. At 34 pt with 2 pt gaps the four take
    /// 142 pt from the trailing edge and stay right of it, where the pre-2.0 row of three always sat.
    private func coachHeaderGlyph(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(TelosType.glyphRow)
            .foregroundStyle(TelosColor.textSecondary)
            .frame(width: 32, height: 32)
            .background(TelosColor.surfaceInset, in: Circle())
            .overlay(Circle().strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
            .frame(width: 34, height: TelosSpace.hitTarget)
            .contentShape(Rectangle())
    }

    private func coachHeaderButton(_ icon: String, _ label: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            coachHeaderGlyph(icon)
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text(label))
    }

    /// The model id with its vendor prefix dropped, so "openai/gpt-oss-20b" fits a header chip as
    /// "gpt-oss-20b". The full id is still what the picker shows and what is sent.
    private var shortModelName: String {
        let id = chrome.model
        return id.contains("/") ? String(id.split(separator: "/").last ?? "") : id
    }

    /// What the floating title row takes: the 44 pt buttons plus the padding around them. The transcript
    /// insets by exactly this, so the first message starts clear of the title instead of under it.
    private var coachTitleOverlayHeight: CGFloat { TelosSpace.hitTarget + TelosSpace.xs + TelosSpace.m }

    /// The full-screen chat: transcript underneath, title row floating over it, composer docked below.
    private var chatScreen: some View {
        ZStack(alignment: .top) {
            TelosColor.canvas.ignoresSafeArea()

            CoachTranscriptList(coach: coach, sending: chrome.sending, onSave: saveAdvice)
                // PUTTING THE KEYBOARD AWAY. On a phone the keyboard covers most of the reply, and the
                // composer's own Send is the only thing that used to dismiss it — so reading an answer
                // meant sending something first. Dragging the transcript now lowers it, and the keyboard
                // bar below carries an explicit Done for the case where there is nothing to scroll.
                .scrollDismissesKeyboard(.interactively)
                // The room the title takes, so the first message can still be scrolled clear of it.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: coachTitleOverlayHeight)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composerDock }

            titleOverlay
        }
    }

    /// Title and the header buttons, over a fade to the canvas so text scrolling under it does not collide.
    /// The fade is one static gradient (no material, no blur).
    private var titleOverlay: some View {
        HStack(alignment: .center, spacing: TelosSpace.xxs) {
            // Title only. A subtitle explains the screen to somebody who has already opened it, on
            // every visit, and takes a line the conversation wants.
            Text("System")
                .font(TelosType.title)
                .foregroundStyle(TelosColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: TelosSpace.s)
            // HABITS AND GOALS, one tap from the coach that plans toward them (decisions 3 and 14).
            Menu {
                Button {
                    showHabits = true
                } label: {
                    Label("Habits", systemImage: "flask")
                }
                Button {
                    showGoals = true
                } label: {
                    Label("Goals", systemImage: "flag.checkered")
                }
            } label: {
                coachHeaderGlyph("flask")
            }
            .accessibilityLabel(Text("Habits and goals"))
            // YOUR OWN TASKS. Describe one, the coach turns it into a task, it appears on Today.
            coachHeaderButton("checklist", "Your tasks") {
                TelosHaptics.play(.tap)
                showTaskSheet = true
            }
            coachHeaderButton("line.3.horizontal", "System settings") { showCoachMenu = true }
            // NO CONFIRMATION. "New chat" is not a destructive act in the sense a dialog is for: the
            // transcript is the app's own notes, the next question rebuilds the context from the same
            // data, and asking every time made starting a fresh thread a two-tap decision. The
            // destructive-sounding "Clear conversation" in the settings sheet keeps its dialog, because
            // that one is phrased as a deletion and is reached deliberately.
            coachHeaderButton("plus", "New chat") {
                TelosHaptics.play(.tap)
                coach.clearConversation()
            }
        }
        .padding(.leading, TelosSpace.l)
        .padding(.trailing, TelosSpace.s)
        .padding(.top, TelosSpace.xs)
        .padding(.bottom, TelosSpace.m)
        .background(
            LinearGradient(
                colors: [TelosColor.canvas, TelosColor.canvas.opacity(0.92), TelosColor.canvas.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// The composer, the chips above it, and the things that only appear when they have something to
    /// say — the pre-2.0 dock, in the pre-2.0 order, on an OPAQUE `surface` band with a hairline top edge
    /// (§6.9: no glass). Opaque on purpose: the transcript ENDS at the band instead of running on under
    /// the chips, so no chip ever sits on top of a line of the conversation.
    ///
    /// IT SITS ABOVE THE FLOATING TAB BAR, never under it: this is a bottom safe-area inset on the
    /// transcript, and the shell (`RootTabView.tab`) insets every tab root by the bar's height
    /// (`TelosTabBarMetrics.contentInset`), so the band's bottom edge is the bar's top edge. With the
    /// keyboard up the shell drops that inset and hides the bar, and the band rides the keyboard.
    ///
    /// COMPACT, SO THE CONVERSATION KEEPS THE SCREEN. The chip rows are 36 pt (32 pt chips) and the
    /// model row the same, as they were before 2.0 — four 44 pt rows plus the bar and the keyboard left
    /// a phone a sliver of transcript. While the keyboard is up the two chip rows step aside entirely
    /// (they are for starting a question, not for one being typed), so the band is just the model row
    /// and the input line; they come back the moment the keyboard goes. Chrome text is capped at
    /// xxLarge (as the tab bar caps its own) so a large text size cannot grow the band over the chat;
    /// the input line itself still scales fully.
    private var composerDock: some View {
        VStack(spacing: TelosSpace.s) {
            if let error = chrome.errorText, !error.isEmpty {
                CoachErrorBanner(message: error)
                // A rejected key is the one failure the wearer can act on from here. Rendered INSIDE the
                // error branch, never on its own flag, so it cannot outlive the message justifying it.
                if chrome.keyRejected { keyRepairPanel }
            }
            if !keyboardUp {
                // K7: follow-ups after a reply, the opening chips before one.
                Group {
                    if showFollowUpChips { followUpChips } else { suggestionChips }
                    analysisChips
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            }
            modelChip
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            composer
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let tokens = coach.estimatedTokens(forDraft: draft) {
                tokenEstimateBar(tokens)
            }
        }
        .padding(.horizontal, TelosSpace.l)
        .padding(.top, TelosSpace.s)
        .padding(.bottom, TelosSpace.xs)
        .background(TelosColor.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(TelosColor.line).frame(height: TelosStroke.line)
        }
    }

    /// The inline "your key was turned away, here is the field" repair, shown under a rejection.
    ///
    /// Saving goes through `setKey`, which replaces the stored key and leaves the transcript alone. The
    /// existing route was the Disconnect button, which also wipes the conversation and un-commits a
    /// custom provider: far more than correcting a typo asks for, and named for an outcome the wearer
    /// is trying to avoid. Twin of the Kotlin editor in `CoachChat`.
    private var keyRepairPanel: some View {
        StrandCard(padding: TelosSpace.m) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                Text("Paste the corrected key. Your conversation is kept.")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Paste your \(chrome.provider.displayName) API key", text: $keyFix)
                    .coachFieldStyle()
                    .onSubmit(saveRepairedKey)
                    .accessibilityLabel("Corrected API key")
                HStack {
                    NoopButton("Update key", systemImage: "key.fill", kind: .primary, action: saveRepairedKey)
                        .disabled(keyFix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
        }
    }

    /// Store the corrected key and drop it from view state. `setKey` clears the error and the rejection
    /// flag, which is what closes this panel.
    private func saveRepairedKey() {
        let trimmed = keyFix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyFix = ""
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TelosSpace.s) {
                ForEach(chrome.suggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        CoachChipLabel(text: prompt)
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .disabled(chrome.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// Named deep analyses: the chip shows only the name, the model gets the full brief.
    private var analysisChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TelosSpace.s) {
                ForEach(CoachAnalysisPreset.all) { preset in
                    Button {
                        sendAnalysis(preset)
                    } label: {
                        CoachChipLabel(text: preset.title, symbol: preset.symbol, emphasised: true)
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .disabled(chrome.sending)
                    .accessibilityLabel(Text("Analysis: \(preset.title)"))
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func sendAnalysis(_ preset: CoachAnalysisPreset) {
        guard !coach.sending else { return }
        composerFocused = false
        Task { await coach.send(preset.title, wireText: preset.instruction) }
    }

    /// K7: True when follow-up chips should show instead of the initial contextual chips —
    /// i.e. the transcript is non-empty, the last message is from the assistant, and a reply
    /// is not currently in flight.
    private var showFollowUpChips: Bool {
        chrome.hasMessages && chrome.lastIsAssistant && !chrome.sending
    }

    /// K7: Follow-up suggestion chips shown after each assistant reply, so the user can dig
    /// deeper without typing. Uses the static `AICoachEngine.followUpSuggestions` list.
    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TelosSpace.s) {
                ForEach(AICoachEngine.followUpSuggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        CoachChipLabel(text: prompt)
                    }
                    .buttonStyle(TelosPressButtonStyle())
                    .disabled(chrome.sending)
                    .accessibilityLabel("Follow-up prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// K12: A subtle token estimate shown below the composer when the draft is non-empty.
    /// Uses the ~4 chars/token heuristic — an estimate only, not an exact tokenizer count.
    private func tokenEstimateBar(_ tokens: Int) -> some View {
        HStack(spacing: TelosSpace.xs) {
            Image(systemName: "speedometer")
                .font(TelosType.glyphDelta)
                .foregroundStyle(TelosColor.textTertiary)
                .accessibilityHidden(true)
            Text("~\(tokens) tokens")
                .font(TelosType.scaleNumber)
                .foregroundStyle(TelosColor.textTertiary)
            if tokens > 8000 {
                Text("· may exceed small context windows")
                    .font(TelosType.scaleNumber)
                    .foregroundStyle(TelosColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, TelosSpace.xxs)
    }

    /// The input row: the field on `surfaceInset`, the voice button in the icon style, and Send in the
    /// accent. No frosted panel (the dock band is already opaque).
    private var composer: some View {
        HStack(alignment: .bottom, spacing: TelosSpace.s) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(TelosType.body)
                .foregroundStyle(TelosColor.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, TelosSpace.m)
                .padding(.vertical, 10)
                .frame(minHeight: TelosSpace.hitTarget)
                .background(TelosColor.surfaceInset,
                            in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : TelosColor.line,
                                  lineWidth: composerFocused ? TelosStroke.focus : TelosStroke.line))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")
                // iOS only: macOS has no software keyboard to dismiss, and `.keyboard` placement there
                // would draw a bar for a keyboard that is never presented.
                #if os(iOS)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer(minLength: 0)
                        Button {
                            composerFocused = false
                        } label: {
                            Label("Done", systemImage: "keyboard.chevron.compact.down")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityLabel("Hide the keyboard")
                    }
                }
                #endif

            // K4: on-device voice input (iOS only). macOS compiles this section out entirely.
            #if os(iOS)
            micButton
            #endif

            Button {
                send(draft)
            } label: {
                Group {
                    if chrome.sending {
                        ProgressView().controlSize(.small).tint(TelosColor.onAccent)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(TelosType.glyphControl)
                    }
                }
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .foregroundStyle(TelosColor.onAccent)
                .background(StrandPalette.accent,
                            in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
            }
            .buttonStyle(TelosPressButtonStyle())
            .disabled(chrome.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
    }

    // MARK: - K4: Voice input (iOS only)

    #if os(iOS)
    /// Mic button: starts/stops on-device speech recognition. Disabled when the locale lacks
    /// on-device support or permission is denied; tapping when permission is not yet determined
    /// triggers the system prompt.
    private var micButton: some View {
        Button {
            toggleVoice()
        } label: {
            Group {
                if voiceInput.isRecording {
                    Image(systemName: "stop.circle.fill")
                        .font(TelosType.glyphControl)
                        .foregroundStyle(TelosColor.critical)
                } else {
                    Image(systemName: "mic.fill")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(canUseVoice ? TelosColor.textSecondary : TelosColor.textTertiary)
                }
            }
            .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
            .background(TelosColor.surfaceInset, in: Circle())
            .overlay(Circle().strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
            .contentShape(Circle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .disabled(!micButtonEnabled)
        .help(voiceInput.statusMessage ?? "Ask out loud")
        .accessibilityLabel(voiceInput.isRecording ? "Stop voice input" : "Voice input")
        .accessibilityHint(voiceInput.statusMessage ?? "Transcribes your question on-device")
        // NO PERMISSION PROMPT ON APPEAR. This used to ask for speech + microphone access the moment the
        // chat was shown, so the first visit to the Coach opened with two system alerts over it, before
        // anyone had touched the mic. The button is enabled while the answer is undetermined, and its
        // first tap asks (`toggleVoice`).
    }

    /// Whether the mic button is tappable: not while sending, and only if voice is either
    /// already usable or permission hasn't been asked yet (first tap triggers the prompt).
    private var canUseVoice: Bool { voiceInput.canUseVoice }
    private var micButtonEnabled: Bool {
        !chrome.sending && (canUseVoice || voiceInput.authorization == .notDetermined)
    }

    private func toggleVoice() {
        if voiceInput.isRecording {
            voiceInput.stopTranscribing { finalText in
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    // Append to the draft (not replace) so a user can speak into existing text.
                    draft = draft.isEmpty ? trimmed : "\(draft) \(trimmed)"
                }
            }
        } else {
            // First tap with undetermined permission triggers the system prompt; if granted,
            // start transcribing immediately on the next tap. If already authorized, start now.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { state in
                    if state == .authorized {
                        voiceInput.startTranscribing { partial in
                            draft = partial
                        }
                    }
                }
            } else {
                voiceInput.startTranscribing { partial in
                    draft = partial
                }
            }
        }
    }
    #endif

    // MARK: - Actions

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    /// K8: Save a coach reply to the journal as a note, so it appears alongside other journal
    /// entries in Insights and can be reviewed later. Uses the existing journal API with a
    /// fixed question ("Coach advice") and the reply text in the notes field.
    private func saveAdvice(_ text: String) {
        let day = Repository.localDayKey(Date())
        let repo = self.repo
        Task {
            await repo.saveJournalAnswer(
                day: day,
                question: "Coach advice",
                answeredYes: true,
                notes: text
            )
        }
    }
}

// MARK: - The transcript

/// The conversation. Observes the ROW list only (`CoachTranscriptModel`), fed from the engine's
/// `messages` publisher; each bubble observes its own text. A streamed chunk re-renders one bubble.
private struct CoachTranscriptList: View {
    let coach: AICoachEngine
    let sending: Bool
    let onSave: (String) -> Void

    @StateObject private var model: CoachTranscriptModel

    init(coach: AICoachEngine, sending: Bool, onSave: @escaping (String) -> Void) {
        self.coach = coach
        self.sending = sending
        self.onSave = onSave
        _model = StateObject(wrappedValue: CoachTranscriptModel(messages: coach.messages))
    }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                emptyTranscript
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy so off-screen bubbles aren't all resident/laid-out at once; with the
                        // `maxStoredMessages` cap the transcript is already bounded, this keeps render cost flat.
                        LazyVStack(alignment: .leading, spacing: TelosSpace.l) {
                            ForEach(model.rows) { row in
                                CoachMessageRow(role: row.role, box: model.box(for: row.id), onSave: onSave)
                                    .id(row.id)
                            }
                            if sending {
                                typingIndicator.id("typing")
                            }
                        }
                        .padding(.horizontal, TelosSpace.l)
                        .padding(.vertical, TelosSpace.xxs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // #697 parity: this screen builds its OWN ScrollView rather than going through
                    // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression.
                    #if os(iOS)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    #endif
                    .onChangeCompat(of: model.rows.count) { _ in
                        scrollToEnd(proxy)
                    }
                    .onChangeCompat(of: sending) { _ in
                        scrollToEnd(proxy)
                    }
                }
            }
        }
        .onReceive(coach.$messages) { model.apply($0) }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            Text("Ask your first question")
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, TelosSpace.l)
        // FILLS THE VIEWPORT, not 180 points of it. The composer is a bottom safe-area inset on the
        // transcript, so a short empty state pulled it up to just under the text — the input line sat in
        // the middle of the screen for the first question and jumped to the bottom for the second.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var typingIndicator: some View {
        HStack(spacing: TelosSpace.s) {
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
            Text("Coach is thinking…")
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.leading, TelosSpace.m)
        .overlay(alignment: .leading) {
            Rectangle().fill(StrandPalette.accent).frame(width: TelosStroke.data)
        }
        .accessibilityLabel("Coach is thinking")
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(TelosMotion.fade) {
            if sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = model.rows.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// One message. Observes ONLY its own text box, so a streamed chunk re-renders this leaf and no other.
private struct CoachMessageRow: View {
    let role: ChatMessage.Role
    @ObservedObject var box: CoachMessageBox
    let onSave: (String) -> Void

    var body: some View {
        switch role {
        case .user:
            UserBubble(text: box.text)
        case .assistant:
            // EQUATABLE, SO A KEYSTROKE DOES NOT RE-RENDER THE CONVERSATION: a reply whose text has not
            // changed skips its body. Memory commands are hidden while a reply is still streaming; they
            // are stripped for good when it finishes (see `CoachMemory.apply`).
            AssistantBubble(text: CoachMemory.hidingCommands(box.text), onSave: onSave)
                .equatable()
        }
    }
}

/// The wearer's message: right-aligned on a `surfaceInset` bubble, radius 16, verbatim text (typed `*`
/// or `#` never turn into formatting).
private struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(TelosType.body)
                .foregroundStyle(TelosColor.textPrimary)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, TelosSpace.m)
                .padding(.vertical, 10)
                .background(TelosColor.surfaceInset,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
                .frame(maxWidth: 520, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You said: \(text)")
    }
}

/// One assistant reply: full width on the canvas with a 2 pt accent leading rail (§6.9), Markdown in the
/// V2 theme. `Equatable` on its text so an unchanged reply is never re-laid-out.
private struct AssistantBubble: View, Equatable {
    let text: String
    let onSave: (String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text }

    var body: some View {
        // LLM replies arrive as Markdown (bold, lists, headings, tables), rendered with the V2 theme.
        // K8: context menu (long-press / right-click) with Copy, Share, and Save actions.
        Markdown(text)
            .markdownTheme(.strand)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, TelosSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(StrandPalette.accent)
                    .frame(width: TelosStroke.data)
                    .accessibilityHidden(true)
            }
            // K8: Copy / Share / Save context menu on assistant replies.
            .contextMenu {
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    #else
                    UIPasteboard.general.string = text
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                ShareLink(item: text) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    onSave(text)
                } label: {
                    Label("Save to Journal", systemImage: "square.and.pencil")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said: \(text)")
    }
}

// MARK: - Small shared pieces

/// A prompt / analysis chip: capsule on `surfaceInset` with a hairline (an accent hairline for the named
/// analyses), 32 pt visual in a 36 pt row: the pre-2.0 density, so the dock does not eat the transcript.
private struct CoachChipLabel: View {
    let text: String
    var symbol: String? = nil
    var emphasised = false

    var body: some View {
        HStack(spacing: TelosSpace.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(TelosType.glyphDelta)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(TelosType.footnote)
                .lineLimit(1)
        }
        .foregroundStyle(emphasised ? TelosColor.textPrimary : TelosColor.textSecondary)
        .padding(.horizontal, TelosSpace.m)
        .frame(minHeight: 32)
        .background(TelosColor.surfaceInset, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous)
            .strokeBorder(emphasised ? StrandPalette.accent.opacity(0.45) : TelosColor.line,
                          lineWidth: TelosStroke.line))
        .frame(minHeight: 36)
        .contentShape(Rectangle())
    }
}

/// An error line from the engine: the warning glyph and the message in `critical` ink on its wash.
private struct CoachErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: TelosSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.critical)
                .accessibilityHidden(true)
            Text(message)
                .font(TelosType.subhead)
                .foregroundStyle(TelosColor.critical)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(TelosSpace.m)
        .background(TelosColor.criticalWash,
                    in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

/// The privacy line under the setup card and the settings sheet.
private struct CoachPrivacyFootnote: View {
    let provider: AIProvider

    var body: some View {
        Label {
            Text(provider == .custom
                 ? "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask."
                 : "This is the only feature that leaves \(Platform.deviceNounPhrase). It sends a summary of your metrics to \(provider.displayName) using your own key. Nothing is sent until you ask.")
                .font(TelosType.footnote)
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(TelosColor.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The setup / repair text field: `surfaceInset`, radius `control`, 1 pt `line`, 44 pt tall.
    func coachFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .font(TelosType.body)
            .foregroundStyle(TelosColor.textPrimary)
            .padding(.horizontal, TelosSpace.m)
            .padding(.vertical, 10)
            .frame(minHeight: TelosSpace.hitTarget)
            .background(TelosColor.surfaceInset,
                        in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                .strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
    }
}

/// A settings-sheet row card: the glass card with a toggle row inside (icon · title + line · switch).
private struct CoachToggleCard: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        StrandCard(padding: TelosSpace.m) {
            HStack(spacing: TelosSpace.m) {
                Image(systemName: icon)
                    .font(TelosType.glyphRow)
                    .foregroundStyle(isOn ? StrandPalette.accent : TelosColor.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(TelosColor.surfaceInset,
                                in: RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    Text(title)
                        .font(TelosType.subhead.weight(.semibold))
                        .foregroundStyle(TelosColor.textPrimary)
                    Text(detail)
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: TelosSpace.s)
                Toggle("", isOn: $isOn)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel(Text(accessibilityLabel))
            }
        }
    }
}

// MARK: - Setup (no key yet)

/// The one setup card (§6.9): provider as chips, fields on `surfaceInset` radius 12, the model, the key.
/// Observes the engine directly — nothing streams while the coach is unconfigured.
private struct CoachSetupCard: View {
    @ObservedObject var coach: AICoachEngine

    /// Pending key text (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field.
    @State private var customModelDraft: String = ""

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    var body: some View {
        StrandCard(padding: TelosSpace.l) {
            VStack(alignment: .leading, spacing: TelosSpace.l) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(TelosType.headline)
                        .foregroundStyle(TelosColor.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(TelosType.subhead)
                    .foregroundStyle(TelosColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider — as chips (§6.9), bound to the same `provider`.
                VStack(alignment: .leading, spacing: TelosSpace.s) {
                    Text("Provider").strandOverline()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TelosSpace.s) {
                            ForEach(AIProvider.allCases) { p in
                                TelosChip(verbatim: p.displayName, isOn: coach.provider == p) {
                                    coach.provider = p
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Provider")
                }

                // Server URL (Custom / local LLM only)
                if coach.provider == .custom {
                    VStack(alignment: .leading, spacing: TelosSpace.s) {
                        Text("Server URL").strandOverline()
                        TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                            .coachFieldStyle()
                            .disableAutocorrection(true)
                            .accessibilityLabel("Server URL")
                        Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves \(Platform.deviceNounPhrase).")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: TelosSpace.s) {
                        Text("Key header").strandOverline()
                        Picker("Key header", selection: $coach.customAuthHeader) {
                            ForEach(CustomAIAuthHeader.allCases) { header in
                                Text(header.displayName).tag(header)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .accessibilityLabel("Key header")
                        Text("Use Bearer for most local servers; use x-api-key for gateways that require the key in that header.")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Model
                modelSelector

                // Key
                VStack(alignment: .leading, spacing: TelosSpace.s) {
                    Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                    SecureField(coach.provider == .custom
                                ? "Only if your server requires one"
                                : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                        .coachFieldStyle()
                        .onSubmit { coach.provider == .custom ? connectCustom() : saveKey() }
                        .accessibilityLabel("API key")
                }

                HStack {
                    if coach.provider == .custom {
                        NoopButton("Connect", systemImage: "link", kind: .primary, action: connectCustom)
                            .disabled(coach.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        NoopButton("Save key", systemImage: "key.fill", kind: .primary, action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer()
                }

                // Whatever the last attempt from THIS card ran into. The setup card had no error line
                // at all, so every way it can fail before a key is committed failed silently: a Refresh
                // the provider turned away, a Connect to a server that wants auth. No repair affordance
                // beside it, unlike the chat: the key field is already on screen.
                if let error = coach.errorText, !error.isEmpty {
                    CoachErrorBanner(message: error)
                }

                Rectangle().fill(TelosColor.lineSoft).frame(height: TelosStroke.line)
                CoachPrivacyFootnote(provider: coach.provider)
            }
        }
    }

    /// Model selector: a Picker over `coach.availableModels` with a free-text "Custom…" path and a
    /// "Refresh models" button that fetches the provider's live list.
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                        .font(TelosType.footnote)
                        .labelStyle(.titleAndIcon)
                        .frame(minHeight: TelosSpace.hitTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .disabled(!coach.hasKey)
                .help("Fetch the available models from \(coach.provider.displayName) using your saved key")
                .accessibilityLabel("Refresh models from provider")
            }

            Picker("Model", selection: modelPickerSelection) {
                ForEach(coach.availableModels, id: \.self) { m in
                    Text(m).tag(m)
                }
                Divider()
                Text("Custom…").tag(customModelTag)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Model")

            if customModel {
                HStack(spacing: TelosSpace.s) {
                    TextField("Enter a model id", text: $customModelDraft)
                        .coachFieldStyle()
                        .onSubmit(applyCustomModel)
                        .accessibilityLabel("Custom model id")

                    Button("Use", action: applyCustomModel)
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Use custom model")
                }
            }
        }
    }

    /// Bridges the model Picker to `coach.model`, with a "Custom…" sentinel that opens the free-text
    /// field instead of selecting a real id.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { customModel ? customModelTag : coach.model },
            set: { newValue in
                if newValue == customModelTag {
                    customModel = true
                    if customModelDraft.isEmpty { customModelDraft = coach.model }
                } else {
                    customModel = false
                    coach.model = newValue
                }
            }
        )
    }

    private func applyCustomModel() {
        let trimmed = customModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setCustomModel(trimmed)
        customModel = false
    }

    private func saveKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        coach.setKey(trimmed)
        keyDraft = ""
    }

    /// Commit the Custom (local) provider: save an optional key, then connect on the entered URL.
    private func connectCustom() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            coach.setKey(trimmed)
            keyDraft = ""
        }
        coach.connectCustom()
    }
}

// MARK: - The settings sheet ("System settings")

/// Everything that used to sit above the transcript. One sheet, opened from the header, so the chat
/// screen is a chat screen. Observes the engine while it is open (the toggles bind to it).
private struct CoachMenuSheet: View {
    @ObservedObject var coach: AICoachEngine
    let onDone: () -> Void

    /// K2: confirmation gate for "Clear conversation", held HERE. It used to be raised on the chat
    /// underneath, and a dialog cannot present from a view that is covered by a sheet, so the menu item
    /// did nothing at all.
    @State private var showClearConfirm = false

    /// Whether the editable-system-prompt section is expanded. Collapsed by default.
    @State private var promptExpanded: Bool = false
    /// Working copy of the system prompt while editing, committed to the engine on change so an edit
    /// takes effect on the next send. Seeded from the engine when the editor opens.
    @State private var promptDraft: String = ""
    // K5: scheduled morning-brief notification settings (CoachBriefScheduler).
    @State private var briefEnabled: Bool = CoachBriefScheduler.isEnabled
    @State private var briefMinutes: Int = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: TelosSpace.m) {
                    connectedHeader
                    consentBar
                    // v5: a SECOND opt-in, only meaningful once data access is on.
                    if coach.dataConsent { onDeviceSignalsBar }
                    if coach.dataConsent && coach.provider == .gemini { multimodalChartBar }
                    systemPromptBar
                    morningBriefBar
                    CoachMemoryPanel()
                    CoachPrivacyFootnote(provider: coach.provider)
                }
                .padding(TelosSpace.l)
            }
            .background(TelosColor.canvas.ignoresSafeArea())
            .navigationTitle("System settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
            .confirmationDialog(
                "Clear conversation?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { coach.clearConversation() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the saved conversation from this device. Coach history is your own notes, not medical advice.")
            }
        }
        #if os(iOS)
        .presentationBackground(TelosColor.canvas)
        #endif
    }

    private var connectedHeader: some View {
        HStack(spacing: TelosSpace.s) {
            StatePill("\(coach.provider.displayName) · \(coach.model)", tone: .accent, showsDot: true)
            Spacer()
            if coach.sending {
                StatePill("Thinking", tone: .accent, pulsing: true)
            }
            #if os(iOS)
            connectionMenu
            #endif
        }
    }

    #if os(iOS)
    /// #2206: Clear conversation and Disconnect, drawn where iPhone can reach them.
    ///
    /// `RootTabView.tab(...)` wraps every primary tab root in a NavigationStack and applies
    /// `.toolbar(.hidden, for: .navigationBar)`, because each screen draws its own in-content header.
    /// So these two were being placed into a bar this platform never shows. Disconnect is the ONLY route
    /// back to the setup card, which is the only place an API key can be typed. A menu rather than a bare
    /// button because it needs two taps to reach a destructive action.
    ///
    /// Worth knowing before changing `disconnect()`: neither `hasKey` nor `isConfigured` is published,
    /// since `hasKey` reads the Keychain on each evaluation. The setup card reappears because
    /// `disconnect()` publishes (it clears the transcript and the error), which re-reads the chrome
    /// snapshot and with it `isConfigured`.
    private var connectionMenu: some View {
        Menu {
            Button {
                showClearConfirm = true
            } label: {
                Label("Clear conversation", systemImage: "trash")
            }
            .disabled(coach.messages.isEmpty)
            Button(role: .destructive) {
                coach.disconnect()
            } label: {
                Label("Disconnect", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(TelosType.headline)
                .foregroundStyle(TelosColor.textSecondary)
                .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Connection")
    }
    #endif

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    private var consentBar: some View {
        // The ON line NAMES what a session carries rather than saying "workouts" and leaving the reader
        // to guess how much that is: the sport, how long, how far and how hard, per session. This toggle
        // is the only place someone is asked to agree to it. Android says the same sentence (#2033).
        CoachToggleCard(
            icon: coach.dataConsent ? "lock.open.fill" : "lock.fill",
            title: "Let the coach use my data",
            detail: coach.dataConsent
                ? "On: your charge, rest, HRV and workouts are sent to the provider, each workout with its sport, duration, distance and heart rate."
                : "Off: the coach answers generally and sends none of your metrics.",
            accessibilityLabel: "Let the coach use my data",
            isOn: $coach.dataConsent)
    }

    /// The v5 second opt-in: the LAB BOOK summary. It no longer carries the wearer's patterns — those
    /// ride the habit summary that goes with data access (they replaced the raw 7-day journal dump,
    /// which was already sent under data access) — so the copy says the Lab Book and nothing more.
    /// Summary-only, never raw readings, so the no-raw-egress posture holds.
    private var onDeviceSignalsBar: some View {
        CoachToggleCard(
            icon: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist",
            title: "Also share my Lab Book",
            detail: coach.includeOnDeviceSignals
                ? "On: a short summary of your logged health numbers is added. Summaries only, never raw readings."
                : "Off: your Lab Book is not shared.",
            accessibilityLabel: "Also share my Lab Book with the coach",
            isOn: $coach.includeOnDeviceSignals)
    }

    /// K11: Third opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. Only shown when the provider is Gemini. OFF by default.
    private var multimodalChartBar: some View {
        CoachToggleCard(
            icon: coach.multimodalChartEnabled ? "photo.badge.checkmark" : "photo",
            title: "Send chart image to Gemini",
            detail: coach.multimodalChartEnabled
                ? "On: a chart snapshot of your trends is sent with each question. Gemini can analyze the visual."
                : "Off: only text is sent. Enable to let Gemini see your charts.",
            accessibilityLabel: "Send chart image to Gemini",
            isOn: $coach.multimodalChartEnabled)
    }

    /// Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
    /// reveals a TextEditor bound to the engine (edits persist to UserDefaults and take effect on the
    /// next message) plus a Reset-to-default control.
    private var systemPromptBar: some View {
        StrandCard(padding: TelosSpace.m) {
            VStack(alignment: .leading, spacing: promptExpanded ? TelosSpace.s : 0) {
                Button {
                    withAnimation(TelosMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: TelosSpace.m) {
                        Image(systemName: "text.alignleft")
                            .font(TelosType.glyphRow)
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : TelosColor.textTertiary)
                            .frame(width: 28, height: 28)
                            .background(TelosColor.surfaceInset,
                                        in: RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                            Text("Coach instructions")
                                .font(TelosType.subhead.weight(.semibold))
                                .foregroundStyle(TelosColor.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(TelosType.footnote)
                                .foregroundStyle(TelosColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: TelosSpace.s)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(TelosType.glyphChevron)
                            .foregroundStyle(TelosColor.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(TelosType.body)
                        .foregroundStyle(TelosColor.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(TelosSpace.s)
                        .background(TelosColor.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
                            .strokeBorder(TelosColor.line, lineWidth: TelosStroke.line))
                        .onChangeCompat(of: promptDraft) { newValue in
                            coach.customSystemPrompt = newValue
                        }
                        .accessibilityLabel("Coach instructions editor")

                    HStack {
                        Spacer()
                        Button {
                            coach.resetSystemPrompt()
                            promptDraft = coach.customSystemPrompt
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                                .font(TelosType.footnote)
                                .labelStyle(.titleAndIcon)
                                .frame(minHeight: TelosSpace.hitTarget)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(!coach.hasCustomSystemPrompt)
                        .accessibilityLabel("Reset coach instructions to default")
                    }
                }
            }
        }
    }

    /// K5: the scheduled morning-brief notification settings — enable toggle, time-of-day picker, and an
    /// explicit "Generate now" button.
    private var morningBriefBar: some View {
        StrandCard(padding: TelosSpace.m) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack(spacing: TelosSpace.m) {
                    Image(systemName: briefEnabled ? "sunrise.fill" : "sunrise")
                        .font(TelosType.glyphRow)
                        .foregroundStyle(briefEnabled ? StrandPalette.accent : TelosColor.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(TelosColor.surfaceInset,
                                    in: RoundedRectangle(cornerRadius: TelosRadius.plate, style: .continuous))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                        Text("Morning brief")
                            .font(TelosType.subhead.weight(.semibold))
                            .foregroundStyle(TelosColor.textPrimary)
                        Text(briefEnabled
                             ? "A local notification with today's readiness + training plan, generated on-device each morning."
                             : "Off: nothing is generated or sent on a schedule.")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: TelosSpace.s)
                    Toggle("", isOn: $briefEnabled)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Morning brief")
                }
                .onChangeCompat(of: briefEnabled) { on in
                    CoachBriefScheduler.setEnabled(on, generateBrief: { await coach.generateBrief() }) { outcome in
                        if outcome == .denied {
                            briefEnabled = false
                            briefStatus = "Notifications are off for NOOP — enable them in Settings first."
                        }
                    }
                }

                if briefEnabled {
                    Rectangle().fill(TelosColor.lineSoft).frame(height: TelosStroke.line)
                    HStack {
                        Text("Time")
                            .font(TelosType.subhead)
                            .foregroundStyle(TelosColor.textPrimary)
                        Spacer()
                        DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Morning brief time")
                    }
                    .frame(minHeight: TelosSpace.hitTarget)
                    Text("At \(Platform.deviceNounPhrase == "Mac" ? "this time" : "or soon after"), NOOP will use your key to generate today's brief. Best-effort: \(Platform.deviceNounPhrase) decides exactly when a backgrounded app wakes.")
                        .font(TelosType.caption)
                        .foregroundStyle(TelosColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton(briefGenerating ? "Generating…" : "Generate now", systemImage: "sparkles", kind: .secondary) {
                        generateBriefNow()
                    }
                    .disabled(briefGenerating)
                    if let briefStatus {
                        Text(briefStatus)
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.textTertiary)
                    }
                }
            }
        }
    }

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                var c = DateComponents()
                c.hour = briefMinutes / 60
                c.minute = briefMinutes % 60
                return Calendar.current.date(from: c) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                // A picker time always carries both components; 07:00 is the scheduler's own default.
                let m = (c.hour ?? 7) * 60 + (c.minute ?? 0)
                briefMinutes = m
                CoachBriefScheduler.setTimeMinutes(m, generateBrief: { await coach.generateBrief() })
            }
        )
    }

    private func generateBriefNow() {
        Task {
            briefGenerating = true
            briefStatus = nil
            defer { briefGenerating = false }
            let text = await CoachBriefScheduler.generateNow { await coach.generateBrief() }
            if let text {
                coach.appendGeneratedBrief(text)
            } else {
                briefStatus = "Couldn't generate a brief right now — check your key and data access."
            }
        }
    }
}

// MARK: - The coach's memory file

/// What the coach has written down, and a way to strike any of it.
///
/// The coach adds and removes entries itself as it talks; this is where the wearer sees exactly what it
/// is carrying from one session to the next, and removes anything wrong or out of date.
private struct CoachMemoryPanel: View {
    @ObservedObject private var memory = CoachMemory.shared

    var body: some View {
        StrandCard(padding: TelosSpace.m) {
            VStack(alignment: .leading, spacing: TelosSpace.s) {
                HStack {
                    Text("MEMORY")
                        .telosScale()
                        .foregroundStyle(TelosColor.textSecondary)
                    Spacer()
                    if !memory.items.isEmpty {
                        Button("Clear all", role: .destructive) { memory.clear() }
                            .font(TelosType.caption)
                            .frame(minHeight: TelosSpace.hitTarget)
                    }
                }
                Text("Notes the coach keeps between sessions — plans, injuries, what worked. It reads them "
                     + "at the start of every session and adds or removes them as it goes.")
                    .font(TelosType.footnote)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if memory.items.isEmpty {
                    Text("Nothing written yet.")
                        .font(TelosType.subhead)
                        .foregroundStyle(TelosColor.textTertiary)
                } else {
                    ForEach(memory.items) { item in
                        HStack(alignment: .top, spacing: TelosSpace.s) {
                            Text(item.text)
                                .font(TelosType.subhead)
                                .foregroundStyle(TelosColor.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                memory.remove(id: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(TelosColor.textTertiary)
                                    .frame(width: TelosSpace.hitTarget, height: TelosSpace.hitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete memory")
                        }
                    }
                }
            }
        }
    }
}
