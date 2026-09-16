import SwiftUI
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
struct CoachView: View {
    @EnvironmentObject var coach: AICoachEngine
    /// K8: used by "Save to Journal" — saves the coach advice as a journal entry with the text
    /// in the notes field, so it appears alongside other journal entries in Insights.
    @EnvironmentObject var repo: Repository

    /// Draft text in the composer (the question being typed).
    /// K15: the composer draft is persisted to UserDefaults so it survives an app relaunch.
    /// Restored on first appear, saved on every change. Keyed identically to the Android twin.
    private static let draftKey = "coach.composerDraft"
    @State private var draft: String = UserDefaults.standard.string(forKey: "coach.composerDraft") ?? ""
    /// Pending key text in the setup card (never persisted here, handed to `setKey`).
    @State private var keyDraft: String = ""
    /// The corrected key, typed into the editor a rejection opens. Separate from `keyDraft` so the
    /// setup card's own field is untouched, and cleared on save so a secret does not sit in view state
    /// after it has been stored. Twin of the Kotlin `keyFix`.
    @State private var keyFix: String = ""
    /// Whether the model selector is in free-text "Custom…" mode.
    @State private var customModel: Bool = false
    /// The id typed in the "Custom…" field.
    @State private var customModelDraft: String = ""
    /// Whether the editable-system-prompt section is expanded. Collapsed by default so the settings
    /// stay compact; most users never touch the prompt.
    @State private var promptExpanded: Bool = false
    /// Working copy of the system prompt while editing, committed to the engine on change so an edit
    /// takes effect on the next send. Seeded from the engine when the editor opens.
    @State private var promptDraft: String = ""
    @FocusState private var composerFocused: Bool

    // K5: scheduled morning-brief notification settings (CoachBriefScheduler).
    @State private var briefEnabled: Bool = CoachBriefScheduler.isEnabled
    @State private var briefMinutes: Int = CoachBriefScheduler.timeMinutes
    @State private var briefGenerating = false
    @State private var briefStatus: String?
    /// K2: confirmation gate for the destructive "Clear conversation" toolbar action.
    @State private var showClearConfirm = false
    /// Today's spend on the current model. Held rather than computed in `body`: it lives in
    /// preferences, so nothing publishes a change and the view has to be told when to re-read.
    @State private var budget: AITokenBudget.Reading?
    /// The ⋯ sheet holding consent, instructions, the brief and the connection.
    @State private var showCoachMenu = false

    // K4: on-device voice input for the composer (iOS only). macOS gets a no-op stub via
    // `#if os(iOS)` guards — the shared file keeps compiling for both targets.
    #if os(iOS)
    @StateObject private var voiceInput = CoachVoiceInput()
    #endif

    /// Sentinel tag for the "Custom…" entry in the model Picker.
    private let customModelTag = "__custom__"

    /// Contextual suggestion chips, derived from today's bands by `AICoachEngine.suggestions`
    /// (→ `CoachSuggestions`). Falls back to a stable generic set when there is no data. Recomputed
    /// on each body evaluation so a fresh sync immediately updates the chips.
    private var suggestions: [String] { coach.suggestions }

    // MARK: - The screen
    //
    // THE CHAT IS THE WHOLE SCREEN, which is the Android lane's arrangement and the reason this no longer
    // goes through `ScreenScaffold`. That scaffold puts its content in a vertical scroll, which hands
    // children an unbounded height — and a docked composer needs the opposite: a known viewport to sit at
    // the bottom of. So the chat lays itself out, and the transcript is weighted against the input row.
    //
    // THE HEADER AND THE COMPOSER FLOAT. Stacked in a column the header was a solid block the
    // conversation stopped underneath; as overlays the transcript runs the full height of the screen and
    // scrolls BEHIND both, which is what makes this feel like a conversation rather than a panel between
    // two bars. The transcript pads itself by exactly what each overlay takes, so nothing is permanently
    // hidden — it can all be scrolled clear.
    //
    // EVERYTHING ELSE MOVED INTO A SHEET. Consent, the editable instructions, the morning brief, the
    // provider and the model were five bars stacked above the transcript, re-explaining the screen on
    // every visit and taking the room the conversation wanted. They are one ⋯ button now.
    //
    // THE UNCONFIGURED STATE KEEPS THE SCAFFOLD. Setup is a form, a form wants a scroll, and there is no
    // conversation to give the screen to yet.

    var body: some View {
        Group {
            if coach.isConfigured {
                chatScreen
            } else {
                ScreenScaffold(title: "System",
                               subtitle: "Ask about your charge, effort, rest and workouts, grounded in your own numbers.",
                               topBackground: liquidScaffoldSky()) {
                    setupCard
                }
            }
        }
        .sheet(isPresented: $showCoachMenu) { coachMenuSheet }
        // macOS only. On iOS these two live in `connectionMenu` instead, because this bar is hidden for
        // a primary tab root and VISIBLE in the pillar sheet, so leaving them here would render nothing
        // on the Coach tab and a duplicate of the menu in the sheet. One control per platform, reachable
        // in both of iOS's presentations. The `#if` sits on the CHAIN rather than inside the builder:
        // `ToolbarContentBuilder` is not relied on to accept an empty body, and the one other
        // conditional toolbar here (CoupledView) always yields an item on both platforms. (#2206)
        #if os(macOS)
        .toolbar {
            if coach.isConfigured {
                // K2: wipe the persisted + in-memory conversation. Confirmed, since it's destructive.
                ToolbarItem {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear conversation", systemImage: "trash")
                    }
                    .help("Clear the saved conversation")
                    .accessibilityLabel("Clear conversation")
                    .disabled(coach.messages.isEmpty)
                }
                ToolbarItem {
                    Button(role: .destructive) {
                        coach.disconnect()
                        keyDraft = ""
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
        // rather than a failed request.
        .task(id: coach.pendingPrompt) {
            guard let prompt = coach.pendingPrompt, !prompt.isEmpty else { return }
            coach.pendingPrompt = nil
            guard coach.isConfigured else { return }
            await coach.send(prompt)
        }
        // K15: persist the composer draft so it survives an app relaunch.
        .onChangeCompat(of: draft) { newValue in
            UserDefaults.standard.set(newValue, forKey: Self.draftKey)
        }
        // K14: haptic feedback when a reply arrives (sending goes true → false).
        .onChangeCompat(of: coach.sending) { isSending in
            if !isSending && !coach.messages.isEmpty {
                triggerReplyHaptic()
            }
        }
        // A consent toggle AFTER the initial load re-checks the brief (the original `.task(id:)`
        // behaviour); the guard inside `startBriefIfNeeded` (messages.isEmpty) keeps this a no-op once
        // a conversation exists.
        .onChangeCompat(of: coach.dataConsent) { _ in
            Task { await coach.startBriefIfNeeded() }
        }
    }

    /// K5: the scheduled morning-brief notification settings — enable toggle, time-of-day picker, and an
    /// explicit "Generate now" button. Mirrors the `ScheduledDebugExport` settings row shape (TestCentreView).
    private var morningBriefBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: briefEnabled ? "sunrise.fill" : "sunrise")
                        .foregroundStyle(briefEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Morning brief").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(briefEnabled
                             ? "A local notification with today's readiness + training plan, generated on-device each morning."
                             : "Off: nothing is generated or sent on a schedule.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
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
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Time").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        DatePicker("", selection: briefTimeBinding, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityLabel("Morning brief time")
                    }
                    Text("At \(Platform.deviceNounPhrase == "Mac" ? "this time" : "or soon after"), NOOP will use your key to generate today's brief. Best-effort: \(Platform.deviceNounPhrase) decides exactly when a backgrounded app wakes.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    NoopButton(briefGenerating ? "Generating…" : "Generate now", systemImage: "sparkles", kind: .secondary) {
                        generateBriefNow()
                    }
                    .disabled(briefGenerating)
                    if let briefStatus {
                        Text(briefStatus).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
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

    /// Explicit, revocable permission for the coach to read & send the user's data. Off by default.
    /// A frosted Charge-tinted card so it reads as part of the green Coach world, not a flat panel.
    private var consentBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.dataConsent ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(coach.dataConsent ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Let the coach use my data")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    // The ON line NAMES what a session carries rather than saying "workouts" and
                    // leaving the reader to guess how much that is: the sport, how long, how far and how
                    // hard, per session. This toggle is the only place someone is asked to agree to it.
                    // Android says the same sentence (#2033).
                    Text(coach.dataConsent
                         ? "On: your charge, rest, HRV and workouts are sent to the provider, each workout with its sport, duration, distance and heart rate."
                         : "Off: the coach answers generally and sends none of your metrics.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.dataConsent)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Let the coach use my data")
            }
        }
    }

    /// The v5 second opt-in: include a SUMMARY of the new on-device signals (strongest n-of-1 patterns +
    /// Lab Book markers). Summary-only, never raw readings, so the no-raw-egress posture holds.
    private var onDeviceSignalsBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.includeOnDeviceSignals ? "checklist.checked" : "checklist")
                    .foregroundStyle(coach.includeOnDeviceSignals ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Also share my patterns & Lab Book")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.includeOnDeviceSignals
                         ? "On: a short summary of your strongest patterns and logged health numbers is added. Summaries only, never raw readings."
                         : "Off: only your core metrics are shared, not your patterns or Lab Book.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.includeOnDeviceSignals)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Also share my patterns and Lab Book with the coach")
            }
        }
    }

    /// K11: Third opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. Only shown when the provider is Gemini. OFF by default.
    private var multimodalChartBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(spacing: 10) {
                Image(systemName: coach.multimodalChartEnabled ? "photo.badge.checkmark" : "photo")
                    .foregroundStyle(coach.multimodalChartEnabled ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Send chart image to Gemini")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(coach.multimodalChartEnabled
                         ? "On: a chart snapshot of your trends is sent with each question. Gemini can analyze the visual."
                         : "Off: only text is sent. Enable to let Gemini see your charts.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.multimodalChartEnabled)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Send chart image to Gemini")
            }
        }
    }

    /// Editable system prompt, the instructions that frame the coach. Collapsed by default; expanding
    /// reveals a TextEditor bound to the engine (edits persist to UserDefaults and take effect on the
    /// next message) plus a Reset-to-default control. Lives inline in the existing settings, NOT a modal.
    private var systemPromptBar: some View {
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: promptExpanded ? 10 : 0) {
                Button {
                    withAnimation(StrandMotion.fade) {
                        promptExpanded.toggle()
                        if promptExpanded { promptDraft = coach.customSystemPrompt }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft")
                            .foregroundStyle(coach.hasCustomSystemPrompt ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coach instructions")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text(coach.hasCustomSystemPrompt
                                 ? "Customised. Your edited instructions frame every reply."
                                 : "Edit how the coach thinks and talks. Takes effect on your next message.")
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: promptExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(promptExpanded ? "Collapse coach instructions" : "Edit coach instructions")

                if promptExpanded {
                    TextEditor(text: $promptDraft)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 140, maxHeight: 240)
                        .padding(8)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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
                                .font(StrandFont.footnote)
                                .labelStyle(.titleAndIcon)
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

    // MARK: - Setup (no key yet)

    private var setupCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connect a provider")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                Text("Coach uses your own API key. Pick a provider, paste a key, and choose a model. Your key is stored securely in the Keychain and never leaves \(Platform.deviceNounPhrase) except as the request you make.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider").strandOverline()
                    Picker("Provider", selection: $coach.provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Provider")
                }

                // Server URL (Custom / local LLM only)
                if coach.provider == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").strandOverline()
                        TextField("http://localhost:11434/v1", text: $coach.customBaseURL)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
                            .disableAutocorrection(true)
                            .accessibilityLabel("Server URL")
                        Text("Any OpenAI-compatible server: Ollama, LM Studio, llama.cpp, or your own gateway. Stays on your network; nothing leaves \(Platform.deviceNounPhrase).")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
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
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Model
                modelSelector

                // Key
                VStack(alignment: .leading, spacing: 6) {
                    Text(coach.provider == .custom ? "API key (optional)" : "API key").strandOverline()
                    SecureField(coach.provider == .custom
                                ? "Only if your server requires one"
                                : "Paste your \(coach.provider.displayName) API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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
                // the provider turned away, a Connect to a server that wants auth. The wearer saw a
                // button do nothing. No repair affordance beside it, unlike the chat: the key field is
                // already on screen, which is the whole point of the card.
                if let error = coach.errorText, !error.isEmpty {
                    errorBanner(error)
                }

                Divider().overlay(StrandPalette.hairline)
                privacyFootnote
            }
        }
    }

    /// Model selector: a Picker over `coach.availableModels` with a free-text "Custom…" path and a
    /// "Refresh models" button that fetches the provider's live list.
    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").strandOverline()
                Spacer()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                        .font(StrandFont.footnote)
                        .labelStyle(.titleAndIcon)
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
                HStack(spacing: 8) {
                    TextField("Enter a model id", text: $customModelDraft)
                        .textFieldStyle(.plain)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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

    // MARK: - Connected state

    private var connectedHeader: some View {
        HStack(spacing: 10) {
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
    /// #2206: the same two actions the toolbar above carries, drawn where iPhone can reach them.
    ///
    /// `RootTabView.tab(...)` wraps every primary tab root in a NavigationStack and applies
    /// `.toolbar(.hidden, for: .navigationBar)`, because each screen draws its own in-content header.
    /// So Clear conversation and Disconnect were being placed into a bar this platform never shows, and
    /// rendered nowhere. Disconnect is the ONLY route back to the setup card, which is the only place
    /// an API key can be typed: `isConfigured` gates that card away the moment a key is saved. The
    /// result was a key that could be set once and then never changed, with reinstalling the app the
    /// only way out, which on an offline-first app costs the wearer their entire history.
    ///
    /// macOS keeps the toolbar and does not get this, so its behaviour is untouched. On iOS the toolbar
    /// route is withdrawn rather than kept alongside: CoachView is presented twice on this platform, as
    /// a primary tab whose bar is hidden and as a pillar sheet whose bar is NOT (it draws a Done button
    /// and only hides the bar's background). Keeping both would render nothing on the tab and two of
    /// everything in the sheet. One control, reachable in both presentations.
    ///
    /// A menu rather than a bare button because it needs two taps to reach a destructive action,
    /// matching the protection the toolbar's separation gives, and because both actions belong to the
    /// same connection.
    ///
    /// Worth knowing before changing `disconnect()`: neither `hasKey` nor `isConfigured` is published,
    /// since `hasKey` reads the Keychain on each evaluation. The setup card reappears because
    /// `disconnect()` ALSO assigns the published `messages`, which is what re-evaluates the body. A
    /// future disconnect that stopped clearing the transcript would clear the key and leave this screen
    /// showing a chat for a connection that no longer exists. macOS has depended on the same coupling
    /// since its toolbar button existed, so this is a latent edge being written down, not a new one.
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
                keyDraft = ""
            } label: {
                Label("Disconnect", systemImage: "gearshape")
            }
        } label: {
            // Same affordance DevicesView uses for its per-device menu, headline size included. The
            // size is not decoration here: the report this came from was that the option could not be
            // FOUND, so a control that matches the one the wearer has already learned, at a size worth
            // aiming at, is doing part of the work.
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityLabel("Connection")
    }
    #endif

    /// THE MODEL, one tap from the conversation — and at the BOTTOM of it.
    ///
    /// It started in the title row, which is exactly where the level strip's pentagon hangs a third of
    /// itself over every screen: the chip sat under it and could not be tapped. Above the composer it is
    /// out of the pentagon's way, and it is also nearer the thing it affects — switching between a fast
    /// model and a thorough one is what you do as you type a question, not while setting the screen up.
    private var modelChip: some View {
        HStack {
            Menu {
                Picker("Model", selection: modelPickerSelection) {
                    ForEach(coach.availableModels, id: \.self) { m in Text(m).tag(m) }
                }
                Divider()
                Button {
                    Task { await coach.refreshModels() }
                } label: {
                    Label("Refresh models", systemImage: "arrow.clockwise")
                }
                .disabled(!coach.hasKey)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 9, weight: .semibold))
                    Text(shortModelName)
                        .font(StrandFont.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(StrandPalette.surfaceInset, in: Capsule())
            }
            .accessibilityLabel("Model")
            Spacer(minLength: 0)
            budgetPill
        }
        // Re-read after every turn, and whenever the model changes — the reading lives in preferences
        // rather than on the engine, so nothing publishes it. `sending` is the trigger that matters:
        // it goes false exactly once a turn has been paid for.
        .onAppear { budget = AITokenBudget.reading(model: coach.model) }
        .onChangeCompat(of: coach.sending) { _ in budget = AITokenBudget.reading(model: coach.model) }
        .onChangeCompat(of: coach.model) { _ in budget = AITokenBudget.reading(model: coach.model) }
    }

    /// TODAY'S ALLOWANCE, beside the model it belongs to.
    ///
    /// The free tier is metered per model per day, and running out looks from the inside exactly like
    /// the app breaking: the coach stops answering, mid-conversation, with nothing said about why. A bar
    /// that fills as the day goes on is the difference between a cliff and a slope you can see.
    ///
    /// ALWAYS ON, including at zero on a fresh morning. The first cut hid it until the model had been
    /// used, on the grounds that an empty meter carries no information — but the thing it is there to
    /// answer is "how much have I got left", and a gauge that is absent exactly when the answer is "all
    /// of it" is a gauge you cannot learn to trust. It reads 0 / 200k and stays put.
    @ViewBuilder
    private var budgetPill: some View {
        if let budget {
            Menu {
                Text(budget.used.formatted() + " of " + budget.limit.formatted()
                     + " tokens used today on " + budget.model)
                if budget.unmetered > 0 {
                    // SAID OUT LOUD. Those turns cost something the provider did not report, so the
                    // figure above is a floor. A budget that quietly under-counts is worse than none.
                    Text("\(budget.unmetered) turn(s) today reported no usage, so this is a floor.")
                }
                Text("Counted on this device, and it resets at your own midnight — the provider's own "
                     + "window may roll at a different hour.")
                Divider()
                Button {
                    AITokenBudget.reset(model: coach.model)
                    self.budget = AITokenBudget.reading(model: coach.model)
                } label: {
                    Label("Reset today's count", systemImage: "arrow.counterclockwise")
                }
            } label: {
                HStack(spacing: 5) {
                    // A two-point bar rather than a percentage: the question is "how much is left",
                    // which is a length, and a length is read without being parsed.
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(StrandPalette.textTertiary.opacity(0.25))
                            .frame(width: 34, height: 3)
                        Capsule()
                            .fill(budget.isWarning ? StrandPalette.statusWarning : StrandPalette.accent)
                            .frame(width: max(2, 34 * CGFloat(budget.fraction)), height: 3)
                    }
                    Text(budgetLabel(budget))
                        .font(StrandFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(budget.isWarning
                                         ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(StrandPalette.surfaceInset, in: Capsule())
            }
            .accessibilityLabel(Text("Token budget"))
            .accessibilityValue(Text("\(budget.used) of \(budget.limit) tokens used today"))
        }
    }

    /// "12.4k / 200k". Thousands, because the exact token count of a conversation is not a number
    /// anybody acts on and six digits beside a model name is just noise; the precise figure is one tap
    /// away in the menu.
    private func budgetLabel(_ r: AITokenBudget.Reading) -> String {
        func k(_ n: Int) -> String {
            n >= 100_000 ? "\(n / 1000)k"
                : (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)")
        }
        return k(r.used) + " / " + k(r.limit)
    }

    /// One round header button. Three of them sit in the title row and they must not drift apart.
    private func coachHeaderButton(_ icon: String, _ label: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 34, height: 34)
                .background(StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// The model id with its vendor prefix dropped, so "openai/gpt-oss-20b" fits a header chip as
    /// "gpt-oss-20b". The full id is still what the picker shows and what is sent.
    private var shortModelName: String {
        let id = coach.model
        return id.contains("/") ? String(id.split(separator: "/").last ?? "") : id
    }

    /// What the floating title row takes: the 34pt buttons plus the padding around them. The transcript
    /// insets by exactly this, so the first bubble starts clear of the title instead of under it.
    private var coachTitleOverlayHeight: CGFloat { 34 + 8 + 18 }

    /// The full-screen chat: transcript underneath, title row and composer floating over it.
    private var chatScreen: some View {
        ZStack(alignment: .top) {
            StrandPalette.surfaceBase.ignoresSafeArea()

            transcript
                // The room the two overlays take, so the first and last bubble can still be scrolled
                // clear of them rather than sitting permanently underneath.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: coachTitleOverlayHeight)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composerDock }

            titleOverlay
        }
    }

    /// Title and the two header buttons, over a fade so text scrolling under it does not collide.
    private var titleOverlay: some View {
        HStack(alignment: .top) {
            // Title only. A subtitle explains the screen to somebody who has already opened it, on
            // every visit, and takes a line the conversation wants.
            Text("System")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: 8)
            coachHeaderButton("line.3.horizontal", "System settings") { showCoachMenu = true }
            // NO CONFIRMATION. "New chat" is not a destructive act in the sense a dialog is for: the
            // transcript is the app's own notes, the next question rebuilds the context from the same
            // data, and asking every time made starting a fresh thread a two-tap decision. The
            // destructive-sounding "Clear conversation" in the settings sheet keeps its dialog, because
            // that one is phrased as a deletion and is reached deliberately.
            coachHeaderButton("plus", "New chat") {
                SystemHaptics.play(.tap)
                coach.clearConversation()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [StrandPalette.surfaceBase,
                         StrandPalette.surfaceBase.opacity(0.92),
                         StrandPalette.surfaceBase.opacity(0)],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// The composer, the chips above it, and the things that only appear when they have something to say.
    private var composerDock: some View {
        VStack(spacing: 8) {
            if let error = coach.errorText, !error.isEmpty {
                errorBanner(error)
                // A rejected key is the one failure the wearer can act on from here. Rendered INSIDE the
                // error branch, never on its own flag, so it cannot outlive the message justifying it.
                if coach.keyRejected { keyRepairPanel }
            }
            // K7: follow-ups after a reply, the opening chips before one.
            if showFollowUpChips { followUpChips } else { suggestionChips }
            modelChip
            composer
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let tokens = coach.estimatedTokens(forDraft: draft) {
                tokenEstimateBar(tokens)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            LinearGradient(
                colors: [StrandPalette.surfaceBase.opacity(0),
                         StrandPalette.surfaceBase.opacity(0.92),
                         StrandPalette.surfaceBase],
                startPoint: .top, endPoint: .bottom)
        )
    }

    /// Everything that used to sit above the transcript. One sheet, opened from the header, so the chat
    /// screen is a chat screen.
    private var coachMenuSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    connectedHeader
                    consentBar
                    // v5: a SECOND opt-in, only meaningful once data access is on.
                    if coach.dataConsent { onDeviceSignalsBar }
                    if coach.dataConsent && coach.provider == .gemini { multimodalChartBar }
                    systemPromptBar
                    morningBriefBar
                    privacyFootnote
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("System settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showCoachMenu = false }
                }
            }
        }
    }

    private var transcript: some View {
        Group {
            if coach.messages.isEmpty {
                emptyTranscript
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy so off-screen bubbles aren't all resident/laid-out at once; with the
                        // `maxStoredMessages` cap the transcript is already bounded, this keeps render cost flat.
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(coach.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if coach.sending {
                                typingIndicator.id("typing")
                            }
                        }
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // #697 parity: this screen builds its OWN ScrollView rather than going through
                    // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
                    // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
                    // guard. `.basedOnSize` permits horizontal bounce only when content genuinely overflows
                    // the width, so nothing that is meant to scroll sideways is affected. (#1532 follow-up)
                    #if os(iOS)
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    #endif
                    // NO HEIGHT CAP any more. The transcript IS the screen now; capping it at 460 was
                    // right when it was one card in a scrolling column and is wrong when it owns the
                    // viewport — it would leave a band of empty canvas under a long conversation.
                    .onChangeCompat(of: coach.messages.count) { _ in
                        scrollToEnd(proxy)
                    }
                    .onChangeCompat(of: coach.sending) { _ in
                        scrollToEnd(proxy)
                    }
                }
            }
        }
    }

    private var emptyTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask your first question")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Coach reads a summary of your last two weeks plus 30-day averages and recent workouts, then answers in plain language. Try a suggestion below.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // FILLS THE VIEWPORT, not 180 points of it. The composer is a bottom safe-area inset on the
        // transcript, so a short empty state pulled it up to just under the text — the input line sat in
        // the middle of the screen for the first question and jumped to the bottom for the second.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: 520, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            // LLM replies arrive as Markdown (bold, lists, headings, tables),             // rendered with the chat-bubble-sized Strand theme. User bubbles stay
            // verbatim `Text` so typed `*`/`#` never turn into surprise formatting.
            // The reply sits on a frosted Charge-tinted surface, a card, not a flat box.
            // K8: context menu (long-press / right-click) with Copy, Share, and Save actions.
            HStack {
                Markdown(message.text)
                    .markdownTheme(.strand)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                    .frame(maxWidth: 560, alignment: .leading)
                    // K8: Copy / Share / Save context menu on assistant replies.
                    .contextMenu {
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                            #else
                            UIPasteboard.general.string = message.text
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        ShareLink(item: message.text) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            saveAdvice(message.text)
                        } label: {
                            Label("Save to Journal", systemImage: "square.and.pencil")
                        }
                    }
                Spacer(minLength: 48)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coach said: \(message.text)")
        }
    }

    private var typingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(StrandPalette.accent)
            Text("Coach is thinking…")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityLabel("Coach is thinking")
    }

    private func errorBanner(_ message: String) -> some View {
        StrandCard(padding: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(StrandPalette.statusCritical)
                    .accessibilityHidden(true)
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusCritical)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    /// The inline "your key was turned away, here is the field" repair, shown under a rejection.
    ///
    /// Saving goes through `setKey`, which replaces the stored key and leaves the transcript alone. The
    /// existing route was the Disconnect button, which also wipes the conversation and un-commits a
    /// custom provider: far more than correcting a typo asks for, and named for an outcome the wearer
    /// is trying to avoid. Twin of the Kotlin editor in `CoachChat`.
    private var keyRepairPanel: some View {
        StrandCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste the corrected key. Your conversation is kept.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Paste your \(coach.provider.displayName) API key", text: $keyFix)
                    .textFieldStyle(.plain)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    // Liquid tap response: the physical settle-inward every tappable liquid
                    // affordance gets, replacing the flat `.plain` press.
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Suggested prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// K7: True when follow-up chips should show instead of the initial contextual chips —
    /// i.e. the transcript is non-empty, the last message is from the assistant, and a reply
    /// is not currently in flight.
    private var showFollowUpChips: Bool {
        guard let last = coach.messages.last, !coach.sending else { return false }
        return last.role == .assistant
    }

    /// K7: Follow-up suggestion chips shown after each assistant reply, so the user can dig
    /// deeper without typing. Uses the static `AICoachEngine.followUpSuggestions` list.
    private var followUpChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AICoachEngine.followUpSuggestions, id: \.self) { prompt in
                    Button {
                        send(prompt)
                    } label: {
                        Text(prompt)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(LiquidPressStyle())
                    .disabled(coach.sending)
                    .accessibilityLabel("Follow-up prompt: \(prompt)")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// K12: A subtle token estimate shown below the composer when the draft is non-empty.
    /// Uses the ~4 chars/token heuristic — an estimate only, not an exact tokenizer count.
    private func tokenEstimateBar(_ tokens: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 10))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("~\(tokens) tokens")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
            if tokens > 8000 {
                Text("· may exceed small context windows")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.top, 2)
    }

    /// The input bar, a frosted overlay surface holding the field + Send, so the composer reads as a
    /// distinct docked surface above the canvas rather than two floating controls.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Coach about your data…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(composerFocused ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
                .onSubmit { send(draft) }
                .accessibilityLabel("Question")

            // K4: on-device voice input (iOS only). macOS compiles this section out entirely.
            #if os(iOS)
            micButton
            #endif

            // Docked icon-only send affordance: a crisp accent-filled square sized to the
            // composer row (not the full 48pt control height), so it routes through the same
            // token fill/label colours as the button system without overpowering the field.
            Button {
                send(draft)
            } label: {
                Group {
                    if coach.sending {
                        ProgressView().controlSize(.small).tint(StrandPalette.goldDeepText)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(width: 44, height: 38)
                .foregroundStyle(StrandPalette.goldDeepText)
                .background(StrandPalette.accent,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(coach.sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(8)
        .background(NoopPanelSurface(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(StrandPalette.hairline, lineWidth: 1))
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
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(StrandPalette.statusCritical)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canUseVoice ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                }
            }
            .frame(width: 36, height: 38)
            .background(StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!micButtonEnabled)
        .help(voiceInput.statusMessage ?? "Ask out loud")
        .accessibilityLabel(voiceInput.isRecording ? "Stop voice input" : "Voice input")
        .accessibilityHint(voiceInput.statusMessage ?? "Transcribes your question on-device")
        .task {
            // Pre-check on appear so the button reflects the right state without a tap.
            if voiceInput.authorization == .notDetermined {
                voiceInput.requestAuthorization { _ in }
            }
        }
    }

    /// Whether the mic button is tappable: not while sending, and only if voice is either
    /// already usable or permission hasn't been asked yet (first tap triggers the prompt).
    private var canUseVoice: Bool { voiceInput.canUseVoice }
    private var micButtonEnabled: Bool {
        !coach.sending && (canUseVoice || voiceInput.authorization == .notDetermined)
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

    private var privacyFootnote: some View {
        Label {
            Text(coach.provider == .custom
                 ? "Coach talks only to the server URL you set. Point it at a local model (Ollama, LM Studio, llama.cpp) to keep everything on your own machine. Nothing is sent until you ask."
                 : "This is the only feature that leaves \(Platform.deviceNounPhrase). It sends a summary of your metrics to \(coach.provider.displayName) using your own key. Nothing is sent until you ask.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

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

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !coach.sending else { return }
        draft = ""
        composerFocused = false
        Task { await coach.send(trimmed) }
    }

    /// K14: Trigger a subtle haptic when the Coach reply arrives. On iOS, a light impact feedback.
    /// macOS doesn't have an equivalent simple API, so it's a no-op there.
    private func triggerReplyHaptic() {
        #if os(iOS)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }

    /// K8: Save a coach reply to the journal as a note, so it appears alongside other journal
    /// entries in Insights and can be reviewed later. Uses the existing journal API with a
    /// fixed question ("Coach advice") and the reply text in the notes field.
    private func saveAdvice(_ text: String) {
        let day = Repository.localDayKey(Date())
        Task {
            await repo.saveJournalAnswer(
                day: day,
                question: "Coach advice",
                answeredYes: true,
                notes: text
            )
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(StrandMotion.fade) {
            if coach.sending {
                proxy.scrollTo("typing", anchor: .bottom)
            } else if let last = coach.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}
