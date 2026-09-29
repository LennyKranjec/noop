import Foundation
import Combine
import OSLog
import Security
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - AI Coach (the one networked feature, strictly opt-in, bring-your-own-key)
//
// NOOP is offline by design. This file is the single exception: when the user pastes their OWN
// API key for a provider they choose, NOOP can send a compact text summary of their metrics plus
// their question to that provider and surface coaching advice. Nothing leaves the device until a
// key is set AND a question is asked. We never embed our own key, never auto-send, and only ever
// transmit the small text context built in `buildContext()` + the running chat, no raw streams.
//
// Pure macOS: Foundation + URLSession + Security (Keychain). Compiles on macOS 13, Swift 5.
// Provider wire formats live in Providers/: OpenAI.swift, Anthropic.swift, Gemini.swift.

/// One-line privacy note the UI should display verbatim near the composer / settings.
public let aiCoachPrivacyNote =
    "Private by default: nothing is sent until you add your own key and ask a question - only a short text summary of your metrics goes to the provider you pick."

// MARK: - Chat model

/// One turn in the coaching conversation.
struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant }
    let id: UUID
    let role: Role
    let text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

// MARK: - Secure key storage (Keychain)

/// Keychain Services wrapper for the user's API key. Uses a generic-password item under a fixed
/// service so the key never lands in UserDefaults, a plist, or on disk in the clear.
enum AIKeyStore {
    private static let service = "com.noop.aicoach"
    private static let account = "api-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// UserDefaults key recording which provider the stored API key belongs to, so one provider's key
    /// is never sent to another provider's endpoint (above all the arbitrary user-typed Custom URL).
    private static let ownerKey = "ai.keyProvider"

    /// The provider the stored key was saved for, or nil for a legacy key saved before this tracking.
    static var ownerProvider: String? { UserDefaults.standard.string(forKey: ownerKey) }

    /// Store (or replace) the API key for `owner`. Empty/whitespace input is treated as a clear.
    /// Returns true once the key is in the Keychain (or was cleared); false if the Keychain write
    /// failed, in which case the owner marker is left untouched so it never points at a key that
    /// isn't actually stored (#872). The live `read()`/`hasKey` gating already reads the real
    /// Keychain, so this is defensive tidying of the discarded write result, not a behaviour change.
    @discardableResult
    static func save(_ key: String, owner: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Delete any existing item first so we always insert a single, fresh value.
        SecItemDelete(baseQuery as CFDictionary)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { return false }
        UserDefaults.standard.set(owner, forKey: ownerKey)
        return true
    }

    /// Read the stored API key, or nil if none is set.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    /// Remove any stored API key.
    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: ownerKey)
    }
}

// MARK: - Log

/// The coach's own log line.
///
/// WHY AT ALL. Every headless generation used to fail into a bare nil, so a wearer reporting "it says the
/// coach is not reachable" left nothing behind to read: not the status code, not the provider, not even
/// whether a request was made. One line per failure, with the non-localised `logReason`, costs nothing
/// and is the difference between a diagnosis and a guess.
///
/// NO SECRETS, EVER. The key, the prompt and the wearer's data never appear here — only the reason token,
/// the provider and the model id.
@MainActor
enum CoachLog {

    private static let log = Logger(subsystem: "com.noop.strand", category: "coach")

    /// The last few reasons, newest last. In memory only (a failure reason is not worth a store write),
    /// and readable so a test can assert that the real reason was recorded rather than swallowed.
    private(set) static var recent: [String] = []
    private static let recentLimit = 12

    static func ai(_ line: String) {
        log.info("\(line, privacy: .public)")
        recent.append(line)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
    }

    static func resetForTesting() { recent = [] }
}

// MARK: - Errors

/// User-facing failure reasons mapped to clear, non-crashing messages.
enum AICoachError: LocalizedError {

    /// Whether an HTTP status means the stored key itself was turned away, as opposed to the provider
    /// being busy, broken, or asked for something it does not have.
    ///
    /// Named rather than left as two literals in two switches because it is the hinge the key-repair
    /// affordance hangs on, and it decides what the wearer is told to go and do. Widen it and a rate
    /// limit starts demanding a new key; narrow it and the trap this exists to remove comes straight
    /// back. Byte-identical twin of the Kotlin `AiCoach.isKeyRejection`.
    static func isKeyRejection(_ status: Int) -> Bool { status == 401 || status == 403 }

    case noKey
    /// The coach is set up but the wearer has not granted data access, so a grounded generation cannot run.
    /// Its own case because "add a key" and "turn on data access" are two different things to go and do, and
    /// reporting the second as the first sends someone who already has a key looking for one.
    case dataAccessOff
    case emptyQuestion
    case badKey
    /// The provider refused the request for size or for rate. CARRIES ITS MESSAGE: a per-minute token
    /// limit states the numbers ("Limit 8000, Requested 8646") and those numbers are the only thing that
    /// tells the wearer — or the next request — what this account actually allows. Throwing them away is
    /// what made every 429 read as "wait a moment and try again" when the real fix was a smaller request.
    case rateLimited(String)
    case server(Int, String)
    case network(String)
    case decode
    case emptyReply(String)   // #1074: verbatim provider-error / empty-reply text (byte-parity with Android emptyReplyMessage)
    case keySaveFailed
    case badCustomURL(String)
    /// A stored key that belongs to ANOTHER provider than the one selected, so `resolvedKey` refuses to
    /// send it. Its own case because the symptom — a configured coach that answers nothing — used to be
    /// indistinguishable from a network failure, and the fix is "re-enter the key for this provider",
    /// which no network message says. Carries the provider the key was saved for.
    case keyForOtherProvider(String)
    /// The request was cancelled (the task that asked for it went away). NOT a failure of the coach, and
    /// must never be reported as one: it is the one "nil" that means "nobody is waiting any more".
    case cancelled
    /// The request ran out of time. Told apart from a general network error because the remedy differs
    /// (retry, versus check the connection) and because a slow local LLM hits this constantly.
    case timedOut

    /// A stable, non-localised token for the log. The message the wearer reads is localised and may be
    /// rewritten; a log line is grepped, so it must not be.
    var logReason: String {
        switch self {
        case .noKey: return "no-key"
        case .dataAccessOff: return "data-access-off"
        case .emptyQuestion: return "empty-question"
        case .badKey: return "key-rejected"
        case .rateLimited: return "rate-limited"
        case .server(let code, _): return "provider-error-\(code)"
        case .network: return "network"
        case .decode: return "unreadable-reply"
        case .emptyReply: return "empty-reply"
        case .keySaveFailed: return "key-save-failed"
        case .badCustomURL: return "bad-server-url"
        case .keyForOtherProvider(let owner): return "key-for-\(owner)"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed-out"
        }
    }

    /// Worth trying again by itself (a transient condition), as opposed to something the wearer has to
    /// go and change first.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .network, .decode, .timedOut, .cancelled: return true
        case .server(let code, _): return code >= 500 || code == 408 || code == 409
        case .noKey, .dataAccessOff, .emptyQuestion, .badKey, .emptyReply, .keySaveFailed, .badCustomURL,
             .keyForOtherProvider:
            return false
        }
    }

    /// Whether the provider refused this request for its SIZE or its RATE — the two failures a smaller
    /// request can actually fix, and the only two worth retrying automatically.
    ///
    /// 413 and 429 are one category here on purpose. Groq reports an over-large request as a 413 ("Request
    /// too large … on tokens per minute (TPM): Limit 8000, Requested 8646") and a too-frequent one as a 429,
    /// and from the app's side the remedy is the same: ask for less. 408 and the 5xx family are transient in
    /// a different way — a smaller request does not help them — so they are deliberately not here.
    var isTooLargeOrRateLimited: Bool {
        switch self {
        case .rateLimited: return true
        case .server(let code, _): return code == 413 || code == 429
        default: return false
        }
    }

    /// The failure to report after the one automatic retry ALSO failed.
    ///
    /// The provider's own sentence is kept verbatim, because it carries the numbers — the limit and what was
    /// requested — and those are the only things that say what to do next. The retry is stated in front of
    /// it: telling the wearer one attempt failed when two did, at two different sizes, is the same dishonesty
    /// as reporting a rate limit as "couldn't reach the coach".
    static func retryExhausted(_ error: AICoachError, first: Int, second: Int) -> AICoachError {
        let prefix = "Asked for \(first) tokens, was refused, retried at \(second) and was refused again."
        switch error {
        case .rateLimited(let detail):
            return .rateLimited(detail.isEmpty ? prefix : prefix + " " + detail)
        case .server(let code, let detail):
            return .server(code, detail.isEmpty ? prefix : prefix + " " + detail)
        default:
            return error
        }
    }

    /// Map a thrown error to a case. `URLSession` reports a cancelled or timed-out request as a
    /// `URLError`, and Swift concurrency as a `CancellationError`; both used to arrive here wrapped in
    /// `.network(localizedDescription)`, which is how "the screen went away mid-request" ended up being
    /// shown to the wearer as "couldn't reach the coach".
    static func from(_ error: any Error) -> AICoachError {
        if let e = error as? AICoachError { return e }
        if error is CancellationError { return .cancelled }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            default: return .network(u.localizedDescription)
            }
        }
        return .network(error.localizedDescription)
    }

    var errorDescription: String? {
        switch self {
        case .badCustomURL(let message):
            return message
        case .keyForOtherProvider(let owner):
            return "The stored API key was saved for \(owner), so it is not sent to the provider you have "
                + "selected. Paste a key for this provider, or switch back."
        case .cancelled:
            return "That request was cancelled before it finished."
        case .timedOut:
            return "The provider took too long to answer. Try again."
        case .dataAccessOff:
            return "Turn on \"Let the coach use my data\" to have it read your numbers."
        case .noKey:
            return "Add your own API key first to use the coach."
        case .keySaveFailed:
            return "Couldn't save the key to the Keychain. The key was not stored, so try again."
        case .emptyQuestion:
            return "Type a question for the coach."
        case .badKey:
            return "That API key was rejected. Check the key and the provider you selected."
        case .rateLimited(let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider is rate-limiting requests right now\(extra). Wait a moment and try again."
        case .server(let code, let detail):
            let extra = detail.isEmpty ? "" : " - \(detail)"
            return "The provider returned an error (\(code))\(extra)."
        case .network(let detail):
            return "Network problem: \(detail). The coach is the only feature that needs the internet."
        case .decode:
            return "Couldn't read the provider's reply. Try again."
        case .emptyReply(let message):
            return message
        }
    }
}

// MARK: - Engine

/// Drives the AI Coach: holds the chat, the chosen provider/model, the secure key, and performs the
/// networked request. `@MainActor` so all `@Published` mutations are main-thread; the actual HTTP
/// call hops off-main via `URLSession`'s async API and results are applied back on the main actor.
@MainActor
final class AICoachEngine: ObservableObject {

    // Published state the UI binds to.
    @Published var messages: [ChatMessage] = []

    /// Local day the current transcript was last written on; nil while it is empty. Drives the day
    /// boundary in `send` — see `isStaleConversation`. Kotlin twin: `CoachViewModel.conversationDay`.
    private var conversationDay: Int?
    @Published var sending = false

    /// True while ANY generation is in flight, including the headless ones.
    ///
    /// `sending` covers only the visible chat. The mission, the muscle note, the level's daily line and
    /// a quest's naming all run without a transcript, and the tab bar's own busy state has to mean "the
    /// system is working" rather than "you are mid-conversation" — otherwise the glyph sits still
    /// through the one case where the wearer has no other way to tell anything is happening.
    ///
    /// A COUNT, not a flag: two headless generations can overlap (opening Today asks for the mission and
    /// the quest naming in the same breath), and a boolean would be cleared by whichever finished first.
    @Published private(set) var backgroundWork = 0

    /// Whether the shell should show the system as working.
    var isWorking: Bool { sending || backgroundWork > 0 }

    @Published var errorText: String?

    /// Whether the last failure was the provider turning the stored key away, as opposed to a rate
    /// limit, a server fault or the network.
    ///
    /// It exists because the rejection message tells the wearer to check their key while the screen
    /// offers no way to reach it: the coach shows the chat as soon as ANY key is stored, and a wrong
    /// key is still a stored key, so the only route back was a Disconnect that also throws the
    /// conversation away. This lets the error carry the field with it.
    ///
    /// It QUALIFIES `errorText` rather than standing on its own, and the view reads it only inside the
    /// branch that renders one, so it cannot leave a key editor open under no error. Assigned on every
    /// failure, so a rejection followed by a rate limit stops claiming to be a rejection. Twin of the
    /// Kotlin `CoachViewModel.keyRejected`.
    @Published var keyRejected = false

    /// #1862: a question handed over by the Today Coach launcher sheet, for `CoachView` to send on appear.
    ///
    /// The launcher owns no send, stream, error or consent surface of its own — duplicating those is how a
    /// second chat UI drifts from the first. It collects a question and hands it here; the Coach screen,
    /// which already has all of that, consumes it exactly once and clears it. Nil is the normal state, and
    /// setting it performs NO network work by itself.
    @Published var pendingPrompt: String?
    @Published var provider: AIProvider {
        didSet {
            guard provider != oldValue else { return }
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            // Reset the model list to the new provider's built-in options.
            availableModels = provider.modelOptions
            // Keep the model valid for the newly-selected provider.
            if !provider.modelOptions.contains(model) {
                model = provider.defaultModel
            }
            // The message names a provider ("That API key was rejected", after a request only THIS
            // provider saw), so it cannot survive switching to a different one. Harmless while only the
            // chat rendered it; wrong now that the setup card does too, which is where switching
            // happens. Twin of the Kotlin `selectProvider`.
            errorText = nil
            keyRejected = false
        }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) }
    }
    /// The model ids offered in the picker. Seeded from `provider.modelOptions`, reset when the
    /// provider changes, and optionally extended by `refreshModels()` with the provider's live list.
    @Published var availableModels: [String] = []
    /// Explicit permission for the coach to read & transmit the user's biometric data. OFF by
    /// default, until this is true, NO metrics are included in any request (only the question).
    @Published var dataConsent: Bool {
        didSet { UserDefaults.standard.set(dataConsent, forKey: Self.consentKey) }
    }
    /// Base URL for the Custom (OpenAI-compatible) provider, e.g. `http://localhost:11434/v1` for a
    /// local LLM server. Only used when `provider == .custom`. Persisted so it survives relaunch.
    @Published var customBaseURL: String {
        didSet { UserDefaults.standard.set(customBaseURL, forKey: AIProvider.customBaseURLKey) }
    }
    @Published var customAuthHeader: CustomAIAuthHeader {
        didSet { UserDefaults.standard.set(customAuthHeader.rawValue, forKey: AIProvider.customAuthHeaderKey) }
    }
    /// Whether the user has committed the Custom provider (tapped Connect with a base URL). Lets the
    /// keyless local path reach the chat without a stored key, while avoiding a flip mid-typing.
    @Published var customConnected: Bool {
        didSet { UserDefaults.standard.set(customConnected, forKey: Self.customConnectedKey) }
    }
    /// SECOND opt-in (v5): also fold a SUMMARY of the new on-device signals, your strongest n-of-1
    /// correlations and your Lab Book markers, into the coach context. OFF by default and gated behind
    /// `dataConsent` too, so it never adds anything without both consents. Summary-only: a few one-line
    /// sentences, NEVER raw readings, the anonymity / no-raw-egress posture is preserved.
    @Published var includeOnDeviceSignals: Bool {
        didSet { UserDefaults.standard.set(includeOnDeviceSignals, forKey: Self.onDeviceSignalsKey) }
    }

    /// K11: THIRD opt-in — send a chart image alongside the text when using Gemini's multimodal
    /// API. OFF by default and gated behind `dataConsent` too. Only active when the provider is
    /// Gemini (the only provider with multimodal support in the app). When on, the Coach composer
    /// shows an "Attach chart" toggle; the rendered chart is sent as inline_data to Gemini.
    @Published var multimodalChartEnabled: Bool {
        didSet { UserDefaults.standard.set(multimodalChartEnabled, forKey: Self.multimodalChartKey) }
    }

    private let repo: Repository
    private let session: URLSession

    private static let providerKey = "ai.provider"
    private static let modelKey = "ai.model"
    private static let consentKey = "ai.dataConsent"
    private static let customConnectedKey = "ai.customConnected"
    private static let onDeviceSignalsKey = "ai.includeOnDeviceSignals"
    private static let multimodalChartKey = "ai.multimodalChartEnabled"
    /// UserDefaults key holding the user's EDITED system prompt. Absent (or blank) means "use the
    /// built-in default". Small text key, never a secret, so plain UserDefaults is fine. Read FRESH
    /// per request (see `systemPrompt`) so an edit takes effect on the very next message.
    static let systemPromptKey = "ai.systemPrompt"

    /// The built-in system prompt that frames every request. Anonymous, frames the assistant only as a
    /// coach. Exposed (read-only) so the UI's "Reset to default" can restore it and show it when nothing
    /// custom is stored. Editing the live prompt overrides this via `systemPromptKey`.
    static let defaultSystemPrompt = """
    You are an elite, supportive recovery and performance coach with a real training methodology. \
    You may be given a summary of the user's own wearable data (charge 0-100, effort 0-100, rest 0-100, \
    sleep duration and its deep/REM/light breakdown, sleep efficiency, HRV, resting heart rate) and \
    recent workouts. Charge is the daily recovery/readiness score, effort is the daily cardiovascular \
    load score, and rest is the nightly sleep-quality score. A dash in the data means that value was \
    NOT MEASURED that day — say so rather than treating it as a zero. \
    Coach using autoregulation:
    • Readiness → prescription: charge 67-100 = green light to build/push, higher effort is fine; \
    34-66 = maintain, quality over volume, keep it controlled; 0-33 = active recovery only \
    (Zone 2, mobility, extra sleep) and protect against accumulating effort debt.
    • Workout optimisation: progressive overload, polarised ~80/20 intensity, space hard sessions, \
    program deloads/periodisation, and treat sleep as the single biggest recovery lever.
    • Always cite the user's ACTUAL numbers, give a concrete plan (today and the week ahead), and \
    be specific, punchy and motivating - like a coach who knows them.
    • EVERY FIGURE BELONGS TO ONE DAY, and the data says which. Charge/recovery is the state of one \
    specific MORNING and expires with that day; effort is a running total for its own day; the sleep \
    figures belong to the night that ENDED on that date. Name the date of a figure you cite, and never \
    call a row "today" unless it is today's. For a question about tomorrow or any later day: nothing is \
    measured for it yet, so reason from the trends, their plan and the schedule, never restate today's \
    charge or effort as if it applied, and say plainly which parts cannot be known yet.
    If no data is provided, coach generally and invite them to turn on data access for personalised \
    advice. You are NOT a doctor - never diagnose; suggest a professional for genuine health concerns.
    Format replies in simple Markdown, chat-sized: short paragraphs, **bold** for key numbers, \
    bullet or numbered lists for plans (a week-ahead plan too: one short bullet per day), ### headings \
    only when structure genuinely helps. Replies are read on a phone: avoid Markdown tables, at most one \
    very small table (3 columns or fewer, 4 rows or fewer) and only if truly necessary. No code blocks.
    """

    /// The system prompt actually sent, read FRESH from UserDefaults on every request so an edit in
    /// the settings takes effect on the next message, with no engine rebuild. A blank/absent stored
    /// value falls back to `defaultSystemPrompt`, so a user who clears it never sends an empty prompt.
    var systemPrompt: String {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return Self.defaultSystemPrompt
    }

    /// The system prompt a request actually goes out with: the framing (the wearer's, or a one-shot
    /// caller's), then the moment it is asked in — weekday, local date and time, the sky now and
    /// today's forecast (`CoachClock.situationBlock`).
    ///
    /// THE SYSTEM PROMPT, NOT THE DATA CONTEXT. The context rides only the FIRST user turn of a chat
    /// (see `wireMessages`), so a time stamped there is hours stale by the afternoon's follow-up; the
    /// system prompt is rebuilt on every request. And it is ONE seam — `callProvider`, `streamProvider`
    /// and `generateOneShot` all pass through it — so the chat, the brief, the rituals, the mission and
    /// the quest names each carry the block exactly once, consent or not (none of it is biometric).
    ///
    /// NEVER WAITS ON THE NETWORK. The weather is read from the cache; a stale cache only kicks a
    /// background refresh, which the next request picks up.
    func requestSystemPrompt(_ base: String, now: Date = Date()) -> String {
        Self.refreshWeatherIfStale()
        return base + "\n\n" + CoachClock.situationBlock(
            now: now, weather: WeatherService.lastKnown, forecast: WeatherService.lastKnownForecast)
    }

    /// The tokens a request carries BESIDE its grounding: the framing prose, the clock-and-weather block
    /// every request's system prompt gains, and the question.
    ///
    /// This is the number every budgeted caller has to subtract before it decides how much grounding fits.
    /// It is computed from the real strings rather than estimated, because the framing is the one part that
    /// cannot be trimmed — a budget that under-reserves it overruns by exactly the amount it guessed wrong.
    func reservedTokens(framing: String, question: String, now: Date = Date()) -> Int {
        CoachTokens.estimate(requestSystemPrompt(framing, now: now)) + CoachTokens.estimate(question)
    }

    /// True while a background weather refresh is in flight, so a burst of requests (a ritual and its
    /// quest, back to back) asks the sky once.
    private static var weatherRefreshInFlight = false

    /// Kick a weather refresh when the cached reading is past `WeatherService.staleAfter`. Fire and
    /// forget: the request that noticed goes out with what the cache holds.
    private static func refreshWeatherIfStale() {
        guard WeatherService.cached == nil, !weatherRefreshInFlight else { return }
        weatherRefreshInFlight = true
        Task {
            await WeatherService.refresh()
            weatherRefreshInFlight = false
        }
    }

    /// The user's stored prompt override, or the default when nothing custom is set. The UI binds its
    /// editor to this: writing persists the override; writing a blank string clears it (back to default).
    var customSystemPrompt: String {
        get { systemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultSystemPrompt {
                UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
            } else {
                UserDefaults.standard.set(newValue, forKey: Self.systemPromptKey)
            }
            objectWillChange.send()
        }
    }

    /// True when the user has an edited prompt that differs from the built-in default, gates the
    /// "Reset to default" affordance in the UI.
    var hasCustomSystemPrompt: Bool {
        let stored = UserDefaults.standard.string(forKey: Self.systemPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(stored ?? "").isEmpty && stored != Self.defaultSystemPrompt
    }

    /// Restore the built-in system prompt by clearing the stored override.
    func resetSystemPrompt() {
        UserDefaults.standard.removeObject(forKey: Self.systemPromptKey)
        objectWillChange.send()
    }

    /// Contextual suggestion chips for the composer, derived from today's bands via `CoachSuggestions`.
    /// Reads only on-device `repo.days`; pure, byte-identical to the Android twin. Returns the stable
    /// generic fallback when there is no usable data for today.
    var suggestions: [String] { CoachSuggestions.suggestions(for: repo.days.last, recent: repo.days) }

    /// K7: Follow-up suggestion chips shown after each assistant reply. These are generic
    /// conversational follow-ups (not data-derived) so the user can dig deeper without typing.
    /// Byte-identical to the Android twin's `followUpSuggestions`.
    static let followUpSuggestions: [String] = [
        "Tell me more about that",
        "What should I do next?",
        "How does today compare to this week?",
        "Give me a specific action plan",
    ]

    /// K12: Rough token estimate for the next send, based on the current draft + context size.
    /// Uses the standard ~4 chars/token heuristic. This is an estimate only — actual token counts
    /// vary by tokenizer. Returns nil when the engine isn't configured (no context to estimate).
    func estimatedTokens(forDraft draft: String) -> Int? {
        guard isConfigured else { return nil }
        // THE WHOLE REQUEST, not one part of it, and CAPPED BY THE BUDGET the chat is actually held to.
        // The old sum guessed a flat 750 tokens for "the data context" — measured, it is five to six
        // THOUSAND — and the figure under the composer therefore said a request was small right up to the
        // 413 that said it was not. The context is now assembled to `CoachRequestBudget.chat`, so the
        // honest estimate is the reserve plus whatever the budget lets the grounding be.
        let reserved = reservedTokens(framing: systemPrompt, question: draft)
            + windowedMessages().reduce(0) { $0 + CoachTokens.estimate($1.text) }
        guard dataConsent else { return reserved + CoachTokens.estimate(Self.sessionConstraints()) }
        // THE GROUNDING IS NOT REBUILT HERE. This runs on every keystroke, and assembling the context means
        // several store reads and `CoachExtraContext`'s whole pass — the reason the old version guessed a
        // flat 750 tokens rather than measuring. So the LAST assembled context's real size is used
        // (`lastContextTokens`), and until one has been assembled the budget's own remainder stands in,
        // which is what the next request will be trimmed to anyway.
        let budget = CoachRequestBudget.chat.resolved(model: model)
        let grounding = lastContextTokens ?? max(0, budget - reserved)
        return min(max(reserved, budget), reserved + grounding)
    }

    /// The estimated tokens of the last context `buildFullContext(budget:reserved:)` assembled.
    ///
    /// Kept so the composer's figure can be the real one without rebuilding the context per keystroke. Nil
    /// until the first grounded request of the session.
    private(set) var lastContextTokens: Int?

    /// Used in place of the metrics context when the user has NOT granted data access.
    private let noConsentNote = """
    NOTE: The user has not granted access to their biometric data. Coach generally and encourage \
    them to enable "Let the coach use my data" for guidance tailored to their real numbers.
    """

    init(repo: Repository, session: URLSession = .shared) {
        self.repo = repo
        self.session = session

        // Restore persisted provider / model (falling back to sane defaults).
        let storedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        self.provider = storedProvider

        let storedModel = UserDefaults.standard.string(forKey: Self.modelKey)
        // A persisted custom id is honoured even if it's not in the built-in list.
        if let storedModel, !storedModel.isEmpty {
            self.model = storedModel
        } else {
            self.model = storedProvider.defaultModel
        }

        // Seed the picker with the provider's built-in options; include any persisted custom id.
        var seeded = storedProvider.modelOptions
        if let storedModel, !storedModel.isEmpty, !seeded.contains(storedModel) {
            seeded.insert(storedModel, at: 0)
        }
        self.availableModels = seeded

        self.dataConsent = UserDefaults.standard.bool(forKey: Self.consentKey)
        self.customBaseURL = UserDefaults.standard.string(forKey: AIProvider.customBaseURLKey) ?? ""
        self.customAuthHeader = AIProvider.customAuthHeader
        self.customConnected = UserDefaults.standard.bool(forKey: Self.customConnectedKey)
        self.includeOnDeviceSignals = UserDefaults.standard.bool(forKey: Self.onDeviceSignalsKey)
        self.multimodalChartEnabled = UserDefaults.standard.bool(forKey: Self.multimodalChartKey)
    }

    // MARK: Key management

    /// True when a key is present in the Keychain.
    var hasKey: Bool { AIKeyStore.read() != nil }

    /// True once the coach can actually send: a stored key for the cloud providers, or, for the
    /// Custom (local) provider, a committed base URL (a key is optional there, as local servers
    /// usually need none). Gates the setup card vs. the live chat.
    var isConfigured: Bool { provider == .custom ? customConnected : hasKey }

    /// The key to send with a request: the stored key, or an empty string for the keyless Custom
    /// provider. `nil` means "not configured", the caller surfaces `.noKey`.
    private var resolvedKey: String? {
        try? resolveKey()
    }

    /// The key, or the REASON there is none.
    ///
    /// `resolvedKey` returning a bare nil is how a coach that is `isConfigured` but has a key stored for
    /// a different provider ended up reported as "couldn't reach the coach": every caller read nil as
    /// "the request failed". The two nils are different problems with different remedies, so they are
    /// told apart here, once, and every caller gets the reason.
    func resolveKey() throws -> String {
        if let k = AIKeyStore.read() {
            // Only send the stored key to the provider it was SAVED for, never Bearer one provider's
            // key (e.g. a cloud OpenAI/Anthropic secret) to another provider's endpoint, above all the
            // arbitrary user-typed Custom URL. A legacy key with no recorded owner is assumed to belong
            // to a cloud provider, so it is never auto-sent to Custom.
            let owner = AIKeyStore.ownerProvider
            if owner == provider.rawValue { return k }
            if owner == nil && provider != .custom { return k }
            if provider == .custom { return "" }
            let name = owner.flatMap { AIProvider(rawValue: $0)?.displayName } ?? owner ?? "another provider"
            throw AICoachError.keyForOtherProvider(name)
        }
        if provider == .custom { return "" }
        throw AICoachError.noKey
    }

    /// Commit the Custom (local) provider once the user has entered a server URL. Optionally stores a
    /// key first if they pasted one. Pulls the server's live model list so the picker isn't empty.
    func connectCustom() {
        let url = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        errorText = nil
        customConnected = true
        // Pull the server's model list; if the user hasn't picked one yet, default to the first.
        Task {
            await refreshModels()
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let first = availableModels.first {
                model = first
            }
        }
    }

    /// Disconnect entirely: forget any stored key and un-commit the Custom provider. The base URL is
    /// kept so reconnecting pre-fills it.
    func disconnect() {
        AIKeyStore.clear()
        customConnected = false
        // Retire the transcript with the connection. Kotlin has done this since the method existed
        // (CoachViewModel.disconnect) and this side never did, so returning to the setup screen on Apple
        // left the whole conversation sitting behind it — including whatever the user had told a coach
        // they were in the middle of disconnecting from.
        messages = []
        conversationDay = nil
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    /// Store the user's pasted key securely. Clears any prior error. If the Keychain write fails the
    /// key is NOT saved, so surface that to the UI instead of silently proceeding (#872).
    func setKey(_ key: String) {
        guard AIKeyStore.save(key, owner: provider.rawValue) else {
            errorText = AICoachError.keySaveFailed.errorDescription
            objectWillChange.send()
            return
        }
        errorText = nil
        // A stored key is no longer the rejected one. Deliberately leaves the transcript alone:
        // correcting a mistyped key is not a reason to lose the conversation, which is what routing
        // this through `disconnect` used to cost. Twin of the Kotlin `saveKey`.
        keyRejected = false
        objectWillChange.send() // `hasKey` is computed; nudge SwiftUI to re-read it.
        // #288: do NOT auto-fetch the provider's model list on key-save. For a cloud provider that GET
        // egresses to the provider the MOMENT a key is saved (IP + request timing + key-validity) — before
        // any send, in an app that is zero-network by default. The picker shows the curated models; the LIVE
        // list is pulled only when the user taps Refresh (an explicit action that is its own consent) or
        // sends. Local Custom servers still refresh on Connect.
    }

    /// Forget the stored key.
    func clearKey() {
        AIKeyStore.clear()
        // Same reasoning as `disconnect`: clearing the key returns the user to the setup screen, and
        // Kotlin empties the transcript when it does. Leaving it meant a "clear my key" on Apple removed
        // the credential and kept the conversation.
        messages = []
        conversationDay = nil
        // The error belongs to the connection being retired, so it goes with it. Kotlin has cleared it
        // here since the method existed and this side never did: harmless while only the chat rendered
        // an error, and a visible defect the moment the setup card does too, because the card this
        // returns to would open carrying "That API key was rejected" above an empty key field, reading
        // as a verdict on the key about to be typed.
        errorText = nil
        keyRejected = false
        objectWillChange.send()
    }

    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Test seam (DEBUG only): lets a test stand in for the live `fetchModels` network call so it can
    /// control timing and which provider's ids come back. Production never sets this, so the real path
    /// below is byte-identical in release builds.
    #if DEBUG
    var fetchModelsOverride: ((_ provider: AIProvider, _ key: String) async throws -> [String])?
    #endif

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    func refreshModels() async {
        guard let key = resolvedKey else {
            errorText = AICoachError.noKey.errorDescription
            return
        }
        errorText = nil

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                errorText = AICoachError.decode.errorDescription
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
        } catch let e as AICoachError {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider else { return }
            // Typed first, because this used to report EVERY failure as a network problem, including a
            // key the provider had just turned away. Refresh is one of the two places a wrong key shows
            // itself, and it was the one that blamed the wrong thing: the wearer read "Network problem"
            // and went looking at their connection. It now says what happened and, for a rejection,
            // opens the field to fix it.
            errorText = e.errorDescription
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
            return
        } catch {
            guard provider == capturedProvider else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
            return
        }
    }

    // MARK: Sending

    /// Hard rolling cap on the STORED transcript. The network payload is separately windowed by
    /// `windowedMessages()` (`maxHistoryMessages`); this bounds the in-memory `messages` array — and the
    /// SwiftUI transcript rendered from it — so a long-lived session can't grow it without bound. `coach`
    /// is a single app-lifetime instance on `AppModel`, so before this an active chat grew `messages`
    /// until the process was killed: the "gets laggy the longer the app runs, reopening fixes it, feels
    /// like RAM" report. Cap >> the wire window, so it never changes what's sent. (parity with Android)
    private static let maxStoredMessages = 40
    private func appendMessage(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxStoredMessages {
            messages.removeFirst(messages.count - Self.maxStoredMessages)
        }
    }

    // MARK: - K2: persisted conversation history

    /// Guards `loadPersistedMessagesIfNeeded()` so it only ever runs once per app launch, even if the
    /// Coach screen's `.task` re-fires (e.g. a tab re-select).
    private var didLoadPersistedMessages = false

    /// Load the conversation persisted by a PRIOR launch (PRD-K2), so relaunching doesn't lose it.
    /// Called from the Coach screen's `.task` (mirroring `startBriefIfNeeded`) rather than `init`,
    /// which is synchronous and runs for every screen the app builds, not just Coach. Best-effort: a
    /// store failure just leaves the transcript empty, matching pre-K2 behaviour — never crashes.
    func loadPersistedMessagesIfNeeded() async {
        guard !didLoadPersistedMessages else { return }
        didLoadPersistedMessages = true
        guard messages.isEmpty, let store = await repo.storeHandle() else { return }
        guard let rows = try? await store.coachMessages(), !rows.isEmpty else { return }
        // Recover the day this transcript was last written on FROM THE ROWS. `conversationDay` lives in
        // memory, so a process restart brought it back nil, and `isStaleConversation(nil, ...)` is false
        // by design (nothing sent yet is never stale), which meant a restored conversation from any
        // previous day was never retired, by `send` or by anything else (#2087).
        let newest = rows.map(\.createdAt).max() ?? 0
        let lastDay = Self.localEpochDay(Date(timeIntervalSince1970: TimeInterval(newest)))
        // Retire by NOT restoring. The next append replaces the stored rows wholesale, so nothing is
        // deleted here and a transcript is never destroyed by merely opening the screen.
        guard !Self.isStaleConversation(lastEpochDay: lastDay, todayEpochDay: Self.localEpochDay()) else {
            return
        }
        messages = rows
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { ChatMessage(id: UUID(uuidString: $0.id) ?? UUID(),
                                role: ChatMessage.Role(rawValue: $0.role) ?? .user,
                                text: $0.text) }
        conversationDay = lastDay
    }

    /// Replace the ENTIRE persisted conversation with the current in-memory `messages`. Called once
    /// per completed send/brief (not per streamed chunk) so a streamed reply's several in-place text
    /// mutations don't hammer the store. Fire-and-forget; a store failure never blocks the UI — the
    /// in-memory transcript (what the user sees) is unaffected either way.
    private func persistMessages() {
        let snapshot = messages
        let providerId = provider.rawValue
        Task {
            guard let store = await repo.storeHandle() else { return }
            let rows = snapshot.enumerated().map { index, m in
                CoachMessageRow(id: m.id.uuidString, role: m.role.rawValue, text: m.text,
                                 provider: providerId, createdAt: Int(Date().timeIntervalSince1970),
                                 orderIndex: index)
            }
            try? await store.replaceCoachMessages(rows)
        }
    }

    /// The Coach toolbar's "Clear conversation" action: wipes both the in-memory transcript and the
    /// persisted table. Fire-and-forget on the store side; the in-memory clear is immediate.
    func clearConversation() {
        messages = []
        // A new thread is a new subject: the quest that opened the last one is not the subject of this
        // one, and carrying it would have the coach answering about a directive the wearer has left.
        activeQuest = nil
        activeWorkoutDossier = nil
        wireOverrides = [:]
        droppedSummary = nil      // K13: reset the summary cache on clear
        droppedSummaryKey = []
        Task { try? await repo.storeHandle()?.clearCoachMessages() }
    }

    /// K5: surface a brief generated by the SCHEDULED morning-brief notification as the first Coach
    /// message, with no network call — called once when the app opens via a tap on that notification.
    /// No-op if a conversation already exists, so it never duplicates into an active chat.
    func surfaceScheduledBrief(_ text: String) {
        guard messages.isEmpty else { return }
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// K5: append an explicitly-generated brief (the Coach settings "Generate now" button) as a new
    /// assistant message, unconditionally — unlike `surfaceScheduledBrief`, this always appends so a
    /// mid-conversation tap still shows the fresh brief.
    func appendGeneratedBrief(_ text: String) {
        appendMessage(ChatMessage(role: .assistant, text: "Today's brief\n\n" + text))
        persistMessages()
    }

    /// Put a quest into the transcript as the system's own opening line, so the wearer can ask about it.
    ///
    /// APPENDED, NOT SENT. Nothing is asked of the provider here — the directive is already written, and
    /// the point of the button is to put it where a follow-up question can be asked ABOUT it. Spending a
    /// round trip to re-state a sentence the app already has would be a request for nothing.
    ///
    /// It does not clear the conversation. A wearer who was mid-thread and taps a quest is adding to that
    /// thread, and a button that silently wiped it would be the most expensive thing on the screen.
    func surfaceQuest(title: String, target: String, taunt: String) {
        var text = "**" + title.uppercased() + "**\n\n" + target
        if !taunt.isEmpty { text += "\n\n" + taunt }
        appendMessage(ChatMessage(role: .assistant, text: text))
        // MARKED AS CONTEXT, not just dropped into the transcript.
        //
        // Putting the directive in as an assistant turn makes it VISIBLE, and that was the whole of it
        // before: a follow-up rode a history that happened to contain a quest-shaped message, with
        // nothing telling the model that the question is ABOUT it. As the conversation grew, the
        // dropped-message summary could also retire that turn and take the quest with it.
        //
        // Held separately and rebuilt into every context from here on, so "how long should that take?"
        // has an antecedent even twenty turns later.
        activeQuest = QuestContext(title: title, target: target, taunt: taunt)
        persistMessages()
    }

    /// The quest the wearer opened the coach from, if any. Cleared with the conversation, because a new
    /// thread is a new subject.
    struct QuestContext: Equatable {
        let title: String
        let target: String
        let taunt: String

        /// The block the model is given. Named as a directive rather than as data, because that is what
        /// it is: the app has already told the wearer to do this, and the coach is being asked about a
        /// commitment that exists rather than being invited to invent one.
        var promptBlock: String {
            var s = "THE QUEST THIS CONVERSATION IS ABOUT.\n"
            s += "The system has already issued this directive to them and it is on screen right now. "
            s += "Any question that follows is about THIS unless they plainly change the subject. "
            s += "Do not re-issue it, do not invent a different one, and do not congratulate them for "
            s += "it — it is not done yet.\n"
            s += "- Title: " + title + "\n"
            s += "- What it asks: " + target + "\n"
            if !taunt.isEmpty { s += "- How it was put to them: " + taunt + "\n" }
            return s
        }
    }

    @Published private(set) var activeQuest: QuestContext?

    /// The workout the wearer asked "AI feedback" on in Today (`WorkoutFeedbackDossier`), held like
    /// `activeQuest`: rebuilt into every context of the thread, cleared with the conversation. Set via
    /// `beginWorkoutFeedback`.
    @Published var activeWorkoutDossier: String?

    /// K11: An optional chart image (base64-encoded PNG) to send with the next user message.
    /// Set by the composer's "Attach chart" toggle when multimodal is enabled and the provider
    /// is Gemini. Consumed (cleared) on the next send. nil when no image is attached.
    @Published var pendingChartImage: String?

    /// Send a question: append it, build the metrics context, call the chosen provider with the
    /// system prompt + context + running history, parse the reply, append it. Never throws/crashes;
    /// failures land in `errorText`.
    func send(_ userText: String, wireText: String? = nil) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { errorText = AICoachError.emptyQuestion.errorDescription; return }
        // The REASON there is no key, not a blanket `.noKey`: a key saved for another provider is a
        // different thing to go and fix, and reporting it as "add your own API key first" sent wearers
        // who already had one round in circles.
        let key: String
        do {
            key = try resolveKey()
        } catch {
            errorText = AICoachError.from(error).errorDescription
            return
        }

        // A transcript from an earlier local day is retired before the new turn is appended (#1542,
        // Kotlin twin merged first). `messages` outlives a night — the engine is held for the app's
        // lifetime — so without this the coach answers TODAY's question inside YESTERDAY's
        // conversation. The DATA was never stale: buildFullContext() re-reads on every send. It is the
        // assistant's own earlier turns stating yesterday's figures, and the model staying consistent
        // with them, which reads as "the coach only talks about my imported data" after a night of
        // fresh strap data.
        //
        // Placed AFTER the guards on purpose: a send that never happens must not wipe a transcript.
        let today = Self.localEpochDay()
        if Self.isStaleConversation(lastEpochDay: conversationDay, todayEpochDay: today) {
            messages = []
        }
        conversationDay = today

        errorText = nil
        let userMessage = ChatMessage(role: .user, text: trimmed)
        // A named analysis shows its short name in the thread and sends its full brief on the wire.
        if let wireText, !wireText.isEmpty { wireOverrides[userMessage.id] = wireText }
        appendMessage(userMessage)
        sending = true
        // K2: persist once the turn is fully settled (success, mid-stream error, or empty-stream
        // removal) — not per streamed chunk, so a long reply doesn't hammer the store.
        defer { sending = false; persistMessages() }

        // Build the data context once and prepend it to the FIRST user turn we send. We send the
        // full running history so follow-ups stay coherent; the context only needs to ride the
        // earliest user message.
        // Include the user's data ONLY with explicit consent; otherwise send a note instead of numbers.
        // THE ROUTINES AND THE MEMORY RIDE EVERY SESSION, consent or not. Neither is biometric data —
        // they are what the wearer told the coach about their day and what it wrote down itself — so
        // withholding them without data access would only make the plans collide with the day they
        // are for. With consent they are already part of `buildFullContext`.
        // THE BUDGET COUNTS THE WHOLE REQUEST, not just this block: the system prompt with its clock and
        // weather, every turn of the running history, and the question the wearer just typed all go on the
        // wire beside it, and the provider meters the sum. Reserving them here is what stops a long
        // conversation quietly adding a thousand tokens per turn until a request is refused.
        let reserved = reservedTokens(framing: systemPrompt, question: trimmed)
            + windowedMessages().reduce(0) { $0 + CoachTokens.estimate($1.text) }
        let context = dataConsent
            ? await buildFullContext(budget: CoachRequestBudget.chat.resolved(model: model),
                                     reserved: reserved).text
            : noConsentNote + "\n\n" + Self.sessionConstraints()
        // K13: if the conversation overflows the sliding window, summarize the dropped middle so
        // the model retains context continuity. Best-effort; failure degrades to the old gap.
        await summarizeDroppedMiddleIfNeeded(key: key)
        var wire = wireMessages(context: context)

        // K11: If a chart image is pending and the provider is Gemini, attach it to the last
        // user turn as inline_data. Non-Gemini providers can't accept images, so the image is
        // silently dropped (the text question still goes through). Cleared after consumption.
        let imageBase64 = pendingChartImage
        pendingChartImage = nil

        // K1: Stream the reply. Append a placeholder assistant message, then mutate its text as
        // chunks arrive by replacing the last element in `messages`. The transcript re-renders on
        // each update (SwiftUI binds to `messages`). On error mid-stream, keep the partial text and
        // append a "(stream interrupted)" marker — never a crash.
        let placeholder = ChatMessage(role: .assistant, text: "")
        appendMessage(placeholder)
        var accumulated = ""
        // PERF: every `messages` write re-parses the whole reply as Markdown in the transcript, and
        // providers stream many small chunks per frame. Coalesce to at most one write per ~16 ms; the
        // final text is always written below (success and error paths alike), and `finish()` on exit
        // guarantees a late flush can never overwrite it.
        let throttle = CoachStreamThrottle { text in
            // Replace the last message's text with the accumulated stream so far.
            if let lastIdx = self.messages.indices.last,
               self.messages[lastIdx].role == .assistant {
                self.messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant, text: text
                )
            }
        }
        defer { throttle.finish() }

        do {
            try await streamProvider(key: key, messages: wire, inlineImage: imageBase64) { delta in
                accumulated += delta
                throttle.submit(accumulated)
            }
            throttle.finish()
            // Finalize: apply the memory commands the reply carried and strip them, then trim. If the
            // stream produced nothing, show "(no reply)".
            let clean = CoachMemory.shared.apply(reply: accumulated)
            if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: clean.isEmpty ? "(no reply)" : clean
                )
            }
        } catch let e as AICoachError {
            // Mid-stream error: keep the partial text + an interrupted marker (PRD K1 acceptance).
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                // No text received at all — remove the empty placeholder.
                messages.remove(at: lastIdx)
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty, let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: partial + "\n\n*(stream interrupted)*"
                )
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages.remove(at: lastIdx)
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// Proactively generate "Today's brief" the first time the Coach opens, readiness + a training
    /// prescription + one recovery tip, without the user typing. Requires a key + data consent.
    /// K1: streams the brief the same way `send` does.
    /// The local day the opening brief last ran on. See `startBriefIfNeeded`.
    static let briefDayKey = "coach.openingBrief.day"

    /// Whether today's opening brief has already been written.
    static func briefAlreadyRanToday(_ d: UserDefaults = .standard, now: Date = Date()) -> Bool {
        d.string(forKey: briefDayKey) == Repository.localDayKey(now)
    }

    func startBriefIfNeeded() async {
        // ONCE A DAY, on the first session. The brief used to run whenever the transcript was empty —
        // which is also the state "New chat" leaves — so every fresh session opened on another full
        // briefing of the same day, at the cost of a round trip nobody asked for. The day's first
        // session gets it; a new chat after that starts blank.
        guard !Self.briefAlreadyRanToday() else { return }
        guard isConfigured, dataConsent, messages.isEmpty, !sending else { return }
        guard let key = resolvedKey else { return }
        errorText = nil
        sending = true
        defer { sending = false; persistMessages() }

        let context = await briefContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]

        let prefix = "Today's brief\n\n"
        let placeholder = ChatMessage(role: .assistant, text: prefix)
        appendMessage(placeholder)
        var accumulated = ""
        // PERF: coalesced like `send` — at most one `messages` write per ~16 ms; the final text is
        // always written below, and `finish()` on exit stops any late flush.
        let throttle = CoachStreamThrottle { text in
            if let lastIdx = self.messages.indices.last,
               self.messages[lastIdx].role == .assistant {
                self.messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant, text: prefix + text
                )
            }
        }
        defer { throttle.finish() }

        do {
            try await streamProvider(key: key, messages: wire) { delta in
                accumulated += delta
                throttle.submit(accumulated)
            }
            throttle.finish()
            let clean = CoachMemory.shared.apply(reply: accumulated)
            if clean.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(id: placeholder.id, role: .assistant, text: prefix + clean)
                // Marked only once a brief actually arrived: a failed round trip must not use up the
                // day's one brief.
                UserDefaults.standard.set(Repository.localDayKey(Date()), forKey: Self.briefDayKey)
            }
        } catch let e as AICoachError {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = e.errorDescription
            // Typed, never text-matched: the message is localized and the case is not.
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
        } catch {
            let partial = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            if partial.isEmpty {
                if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                    messages.remove(at: lastIdx)
                }
            } else if let lastIdx = messages.indices.last, messages[lastIdx].role == .assistant {
                messages[lastIdx] = ChatMessage(
                    id: placeholder.id, role: .assistant,
                    text: prefix + partial + "\n\n*(stream interrupted)*"
                )
            }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
        }
    }

    /// K5: The brief instruction shared by the interactive `startBriefIfNeeded()` (streamed into the
    /// chat) and the headless `generateBrief()` below (used by the scheduled morning-brief notification).
    /// Kept in one place so the two paths never drift.
    private static let briefInstruction = """
    Based on the data above, give me TODAY'S coaching brief in three short parts: \
    (1) my readiness in one line, citing charge, HRV and rest; \
    (2) exactly what training to do today and what to avoid; \
    (3) one specific thing to improve my charge. Be punchy and motivating.
    """

    /// The brief's grounding, to the brief's own budget.
    ///
    /// Its own seam because BOTH brief paths — the one that streams into the transcript and the headless
    /// one the scheduled notification uses — have to be the same size. They were two calls to
    /// `buildFullContext()` and one of them would have been the next thing to overrun.
    func briefContext() async -> String {
        let reserved = reservedTokens(framing: systemPrompt, question: Self.briefInstruction)
        return await buildFullContext(budget: CoachRequestBudget.brief.resolved(model: model),
                                      reserved: reserved).text
    }

    /// K5: Generate today's coaching brief WITHOUT touching the visible chat transcript. Used by the
    /// scheduled morning-brief notification (`CoachBriefScheduler`), which can run with no Coach screen
    /// open and must never append to (or duplicate into) `messages`. Non-streaming (a background/BGTask
    /// context has no UI to stream into). Returns nil when not configured/consented, on any network
    /// failure, or when the reply is empty — the caller treats nil as "brief unavailable"; never throws.
    func generateBrief() async -> String? {
        guard isConfigured, dataConsent, let key = resolvedKey else { return nil }
        let context = await briefContext()
        let wire: [(role: ChatMessage.Role, content: String)] =
            [(.user, context + "\n\n---\n\n" + Self.briefInstruction)]
        guard let reply = try? await callProvider(key: key, messages: wire) else { return nil }
        let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// Generate ONE answer under a caller-supplied framing, without touching the visible transcript.
    ///
    /// The seam every headless generation in the app goes through: today's mission, the muscle-load
    /// note, the level's daily remark. Each of those wants its own system prompt — a mission is not a
    /// brief and a muscle note is not either — and none of them may appear in the chat, because the
    /// wearer did not ask a question and a transcript that fills with things they never said is one
    /// they stop reading.
    ///
    /// NON-STREAMING, and it never throws. These run in the background with nothing to stream into and
    /// nothing to show an error to; nil means "not available right now", which every caller already has
    /// to handle for the un-configured case anyway.
    ///
    /// `grounding` is the data block. It is passed in rather than read here so a caller that needs a
    /// SPECIFIC grounding (the muscle note wants the muscle table, not the sleep summary) is not forced
    /// to send the whole context and hope the model picks the right half out of it.
    ///
    /// `requiresDataConsent: false` is for a caller that sends NO data block — only the wearer's own
    /// words and the non-biometric session constraints, exactly what the chat sends without consent
    /// (the custom-task writer). Every grounded caller keeps the default.
    ///
    /// `budget` is a CEILING THAT IS CHECKED, not one the prompt is trimmed to. It is for the writers whose
    /// prompts are already bounded by construction — the level note (five parts), the muscle note (one row
    /// per muscle group), a quest's name, a custom task — where there is no grounding to shorten and the
    /// useful thing is to NOTICE when one has grown past its share of a per-minute allowance. Overrunning is
    /// logged with both numbers and the request still goes out: a note the wearer has been shown before is
    /// worth more than a refusal, and the log is what turns "it stopped working" into a size to fix.
    ///
    /// A caller with grounding it CAN trim uses `generateOneShotResult(budget:build:)` instead, which
    /// assembles to the budget and retries once at half of it.
    func generateOneShot(systemPrompt: String, question: String,
                         budget: CoachRequestBudget? = nil,
                         requiresDataConsent: Bool = true) async -> String? {
        try? await generateOneShotResult(systemPrompt: systemPrompt, question: question,
                                         budget: budget,
                                         requiresDataConsent: requiresDataConsent).get()
    }

    /// The same one-shot generation, WITH the reason it failed.
    ///
    /// WHY THIS EXISTS. `generateOneShot` returns `String?`, and `try?` on the provider call threw every
    /// distinct failure away: a rejected key, a 429, a 500 with the provider's own message, an
    /// unreadable reply, a mis-typed Custom URL, a key saved for a different provider, a cancellation
    /// and a genuine loss of network all arrived at the caller as the same nil — which the State tile
    /// then reported, for all of them, as "Couldn't reach the coach". The reason is never guessed from
    /// nil again: it is carried here.
    ///
    /// Still never throws out of the actor: it returns a `Result`, so a caller that only wants the text
    /// keeps the `String?` shape above and a caller that has to TELL the wearer something gets the case.
    func generateOneShotResult(systemPrompt: String, question: String,
                               budget: CoachRequestBudget? = nil,
                               requiresDataConsent: Bool = true) async -> Result<String, AICoachError> {
        guard isConfigured else { return .failure(.noKey) }
        guard dataConsent || !requiresDataConsent else { return .failure(.dataAccessOff) }
        let key: String
        do {
            key = try resolveKey()
        } catch {
            return .failure(AICoachError.from(error))
        }
        // THE SIZE IS MEASURED WHETHER OR NOT IT CAN BE TRIMMED. Nothing used to count a one-shot request at
        // all, which is why a tile refresh grew to 8,646 tokens without a single line of the app noticing.
        if let budget {
            let ceiling = budget.resolved(model: model)
            let size = reservedTokens(framing: systemPrompt, question: question)
            if size > ceiling {
                CoachLog.ai("one-shot over budget: \(size) tokens vs \(ceiling) (\(budget.rawValue))")
            }
        }
        backgroundWork += 1
        defer { backgroundWork -= 1 }
        do {
            let reply = try await provider.client.send(
                key: key,
                model: model,
                systemPrompt: requestSystemPrompt(systemPrompt),
                messages: [(role: ChatMessage.Role.user, content: question)],
                session: session
            )
            let clean = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            // A 200 with nothing in it is its own failure, not a network one: it is usually a model id
            // the provider does not serve, and `emptyReplyError` already writes that sentence.
            guard !clean.isEmpty else {
                return .failure(.emptyReply(
                    "The provider returned an empty reply. If you set a custom model by hand, check "
                    + "that the model name is one the provider actually offers."))
            }
            return .success(clean)
        } catch {
            let mapped = AICoachError.from(error)
            CoachLog.ai("one-shot failed: \(mapped.logReason) · \(provider.rawValue)/\(model)")
            return .failure(mapped)
        }
    }

    /// A one-shot generation with an explicit TOKEN BUDGET, and one automatic retry at half of it.
    ///
    /// WHY THE CALLER HANDS OVER A CLOSURE instead of two finished strings. A 413 says "this request was too
    /// big"; the only useful response is to build a SMALLER one, and a finished string cannot be made
    /// smaller without guessing where to cut. So the caller says how to build the request AT A GIVEN BUDGET,
    /// this asks for it at the resolved budget, and on a refusal for size or rate asks for it again at half.
    ///
    /// ONE RETRY, NOT A LOOP. Two attempts at 3,800 and 1,900 tokens cost less than one at 8,646 did, and a
    /// third would be a request with no grounding left in it — at which point the honest thing is to report
    /// the failure with its numbers, which is what happens (`AICoachError.retryExhausted`).
    ///
    /// THE BUDGET IS FOR THE WHOLE REQUEST. `build` receives the ceiling and is responsible for fitting the
    /// system prompt, the grounding AND the question inside it — see `CoachContextBudget.fit`, whose
    /// `reserved` argument exists for exactly that. A budget spent on the grounding alone is the mistake
    /// that produced the 413.
    func generateOneShotResult(
        budget: CoachRequestBudget,
        requiresDataConsent: Bool = true,
        build: (Int) async -> (systemPrompt: String, question: String)
    ) async -> Result<String, AICoachError> {
        let first = budget.resolved(model: model)
        let built = await build(first)
        let attempt = await generateOneShotResult(systemPrompt: built.systemPrompt,
                                                 question: built.question,
                                                 requiresDataConsent: requiresDataConsent)
        guard case .failure(let error) = attempt, error.isTooLargeOrRateLimited else { return attempt }
        let second = CoachRequestBudget.halved(first)
        // A halved budget that is not actually smaller buys nothing, and re-sending the identical request
        // would be one more refusal for the same reason. Report the first failure instead.
        guard second < first else { return attempt }
        CoachLog.ai("one-shot refused at \(first) tokens (\(error.logReason)); retrying at \(second)")
        let retryBuilt = await build(second)
        let retry = await generateOneShotResult(systemPrompt: retryBuilt.systemPrompt,
                                                question: retryBuilt.question,
                                                requiresDataConsent: requiresDataConsent)
        guard case .failure(let again) = retry else { return retry }
        return .failure(AICoachError.retryExhausted(again, first: first, second: second))
    }

    /// Today's mission, generating it if today has none. Nil when it cannot be written.
    ///
    /// READ-THEN-GENERATE, keyed on the local day: the mission is one per day, so a screen that appears
    /// twice in an afternoon must not spend a round trip the second time. A mission written yesterday
    /// is deliberately not returned — see `DailyMissionStore.today`.
    @discardableResult
    func ensureDailyMission() async -> DailyMission? {
        if let existing = DailyMissionStore.today() { return existing }
        guard isConfigured, dataConsent else { return nil }
        // The same stress objective and day schedule the State tile's refresh plans by, so the automatic
        // mission keeps stress low too (down-regulation after hard sessions, morning meditation, a calm
        // wind-down) and respects the wearer's allowed workouts.
        let now = Date()
        let schedule = RoomClimatePlan.schedule(now: now)
        let choices = StateWorkoutChoicesStore.read()
        // BUDGETED, with one retry at half. The mission used to send the whole chat context and hope; on an
        // 8,000-tokens-per-minute key that was most of a minute's allowance for three sentences.
        let result = await generateOneShotResult(budget: .mission) { budget in
            // The schedule and the objective are part of the ASKING, not of the grounding that can be
            // trimmed — the mission has to name a clock time inside the day, and the level and stress aims
            // are what the mission is for. They are reserved with the framing.
            let tail = StateDayPlanContext.block(now: now, schedule: schedule) + "\n\n"
                + StateDayPlanContext.missionObjective(choices: choices)
            let reserved = self.reservedTokens(framing: DailyMissionWriter.systemPrompt(grounding: ""),
                                               question: DailyMissionWriter.question, now: now)
                + CoachTokens.estimate(tail)
            let fit = await self.buildFullContext(budget: budget, reserved: reserved)
            return (systemPrompt: DailyMissionWriter.systemPrompt(grounding: fit.text + "\n\n" + tail),
                    question: DailyMissionWriter.question)
        }
        guard case .success(let answer) = result,
              let mission = DailyMissionWriter.parse(answer, dayKey: DailyMissionStore.dayKey())
        else { return nil }
        DailyMissionStore.write(mission)
        return mission
    }

    /// The routines and the memory file — the part of the context that is not biometric data, and so is
    /// sent on every session whether or not data access is on.
    /// `memoryEntries` caps how many memory notes are listed. Nil is every note, which is what the chat
    /// sends — its context is assembled to a budget that can shorten or drop the block whole. A lean
    /// one-shot writer that appends this raw passes a cap; see `CoachMemory.promptSection(maxEntries:)`.
    static func sessionConstraints(memoryEntries: Int? = nil, _ d: UserDefaults = .standard) -> String {
        var parts: [String] = []
        if let routines = CoachRoutines.promptSection(d) { parts.append(routines) }
        parts.append(CoachMemory.shared.promptSection(maxEntries: memoryEntries))
        return parts.joined(separator: "\n\n")
    }

    /// NOOP's three scores (primary) and WHOOP's (secondary), per recent day.
    func threeScoresBlock() async -> String {
        func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
        var s = "THE THREE DAILY SCORES. NOOP's are Charge (recovery/readiness, 0-100), Effort (cardiovascular "
        s += "load, 0-100) and Rest (sleep quality, 0-100); call them Charge, Effort and Rest. FOR SLEEP AND "
        s += "RECOVERY, WHOOP's own figure WINS on any day WHOOP scored it: WHOOP can hold the strap overnight, "
        s += "and NOOP's Rest and Charge for such a night are computed from too little data and are wrong. "
        s += "Use NOOP's Charge/Rest only for days WHOOP has no recovery/sleep score. Effort: NOOP's first.\n"
        // EACH ROW IS LABELLED WITH ITS DAY AND WHAT THAT DAY IS. A newest-first list whose top row is
        // sometimes today and sometimes yesterday (the overnight has not synced) is how "your charge today
        // is 62" ended up being said about yesterday's morning.
        let todayKey = CoachDayFrame.key(Date())
        func dayTag(_ day: String) -> String { day == todayKey ? " (TODAY, still incomplete)" : "" }
        let own = await repo.noopRecentDays()
        if own.isEmpty {
            s += "NOOP's own scores: none computed for the last week.\n"
        } else {
            s += "NOOP (primary, newest first). Charge is the state of each date's MORNING; effort is that "
            s += "date's cumulative total:\n"
            for d in own.reversed() {
                s += "  \(d.day)\(dayTag(d.day)): charge \(pct(d.charge)), effort \(pct(d.effort)), rest \(pct(d.rest))\n"
            }
            if own.first(where: { $0.day == todayKey }) == nil, let newest = own.map(\.day).max() {
                s += "  NOTE: there is no row for today (\(todayKey)) yet — the newest is \(newest). "
                s += "Do not present \(newest)'s figures as today's.\n"
            }
        }
        let whoop = await repo.whoopRecentDays()
        if !whoop.isEmpty {
            s += "WHOOP's own figures (PRIMARY for recovery and sleep on the days listed; strain only where NOOP "
            s += "has no effort; always with WHOOP's names and scales: Recovery %, Strain 0-21, Sleep Score %):\n"
            for d in whoop.reversed() {
                s += "  \(d.day)\(dayTag(d.day)): recovery \(pct(d.recovery)), strain "
                s += (d.strain.map { String(format: "%.1f", $0) } ?? "—")
                s += ", sleep score \(pct(d.sleep))\n"
            }
        }
        return s
    }

    /// Full data context = the metrics summary + recent workouts (+ an OPT-IN on-device-signals summary
    /// when the second consent is on). Used when the user has granted data access.
    ///
    /// NOW ASSEMBLED TO A BUDGET. It used to append every block it could find and hand the result over,
    /// which is how one State-tile refresh came to ask a provider for 8,646 tokens against an 8,000-per-
    /// minute allowance and be refused. `budget` is the ceiling for the WHOLE request and `reserved` is
    /// everything else that request will carry — the system prompt, the clock block, the question — because
    /// that is what the provider meters. Blocks that will not fit are shortened or dropped cheapest-value-
    /// first and the fact is stated in the context itself (`CoachContextBudget`).
    ///
    /// The no-argument form keeps the chat's own budget, so every existing caller is unchanged.
    func buildFullContext() async -> String {
        await buildFullContext(budget: CoachRequestBudget.chat.resolved(model: model), reserved: 0).text
    }

    func buildFullContext(budget: Int, reserved: Int) async -> CoachContextFit {
        let fit = CoachContextBudget.fit(await contextBlocks(), budget: budget, reserved: reserved)
        lastContextTokens = CoachTokens.estimate(fit.text)
        if !fit.isComplete {
            CoachLog.ai("context trimmed to \(budget) (reserved \(reserved)): shortened "
                        + "\(fit.shortened.joined(separator: ", ")); dropped \(fit.dropped.joined(separator: ", "))")
        }
        return fit
    }

    /// The chat's context, as blocks with what each is worth.
    ///
    /// DECLARATION ORDER IS READING ORDER and is unchanged from the single string this replaces — the day
    /// frame first, then the figures contiguous, then the constraints, then the closing rule. The VALUES are
    /// new, and they are the chat's: a question can be about anything, so the dated figures outrank the
    /// prose, and the prose the wearer typed himself (routines, memory) outranks the app's own extras.
    func contextBlocks() async -> [CoachContextBlock] {
        var out: [CoachContextBlock] = []
        // WHICH DAY EACH FIGURE BELONGS TO, FIRST — before any number. Everything below is dated, and
        // nothing used to say what those dates meant, so a question about tomorrow was answered with
        // today's charge. See `CoachDayFrame`. Its short form is the same rules in one paragraph.
        out.append(CoachContextBlock(name: "the day-validity rules", value: 95,
                                     full: CoachDayFrame.block(),
                                     short: CoachDayFrame.compactBlock()))
        // THE SCORES THE COACH SPEAKS IN. NOOP's own Charge / Effort / Rest on 0–100 are the primary
        // figures — the ones the level, the quests and every screen are built on. WHOOP's own recovery,
        // strain and sleep score follow as a secondary reference, clearly labelled with their own names and
        // scales, so the model never quotes a WHOOP strain of 14 as an effort out of 100.
        out.append(CoachContextBlock(name: "the three daily scores", value: 90,
                                     full: await threeScoresBlock()))
        // The whole level formula. High value in the chat, which is asked how the level works; the FIRST
        // thing the State tile drops, because its own prompt carries the gaps it needs.
        out.append(CoachContextBlock(name: "the level and its formula", value: 45,
                                     full: CoachLevelContext.promptSection()))
        // THE ROUTINES AND THE MEMORY ARE AT THE END (below). They used to sit HERE, between the level and
        // the biometric table — several paragraphs of non-data prose splitting the figures into two halves,
        // which is exactly the crowding-out that makes a small model answer from the prose and not from the
        // numbers. The data is contiguous and the constraints follow it.
        out.append(CoachContextBlock(name: "the recent-days table", value: 85,
                                     full: buildContext(), short: shortHistoryBlock()))
        out.append(CoachContextBlock(name: "recent workouts", value: 70,
                                     full: await recentWorkoutsBlock(),
                                     short: await recentWorkoutsBlock(limit: 4)))
        // Derived stress: a single Baevsky Stress Index summary line over today's R-R, computed the same
        // way StressView does. Gated here under `dataConsent` (the caller only reaches this with consent
        // on), so it rides the SAME consent + text-only channel as the HRV/RHR summary, a derived number,
        // never raw R-R egress. Omitted when there aren't enough clean beats yet.
        if let line = await stressIndexLine() {
            out.append(CoachContextBlock(name: "today's stress index", value: 65, full: line))
        }
        // EVERYTHING ELSE THE APP HOLDS about the day and the week — journal, water, energy, streaks, stress
        // now and by the hour, quests, meditation, the level's gaps, VO₂max, strength, the bedroom and the
        // lights. See `CoachExtraContext`.
        //
        // THE DREAM JOURNAL IS ITS OWN BLOCK, and a cheaper one. It is the largest single piece of that
        // section and the only part of the whole context whose size the wearer controls by typing, so the
        // budget has to be able to take it back WITHOUT losing the water, the streaks and the level inputs
        // with it. Declared after, so it keeps the position it was deliberately given: last, behind every
        // figure, because several paragraphs of half-awake prose in front of the numbers is what makes a
        // small model answer from the story.
        let extra = await CoachExtraContext.block(repo: repo, includeDreams: false)
        if !extra.isEmpty {
            out.append(CoachContextBlock(name: "the day's other figures", value: 40, full: extra))
        }
        let dreams = CoachDreamContext.block(entries: DreamJournalStore.shared.entries)
        if !dreams.isEmpty {
            out.append(CoachContextBlock(name: "the dream journal", value: 25, full: dreams))
        }
        // THE QUEST ON SCREEN, when the coach was opened from one. The highest value there is: it is the
        // SUBJECT of the conversation, and a context that dropped it would answer about something else.
        if let activeQuest {
            out.append(CoachContextBlock(name: "the quest on screen", value: 100,
                                         full: activeQuest.promptBlock))
        }
        if let activeWorkoutDossier {
            out.append(CoachContextBlock(name: "the workout being reviewed", value: 100,
                                         full: activeWorkoutDossier))
        }
        // THE SKY RIDES THE SYSTEM PROMPT, not this block: the weather now and today's forecast go out
        // with every request (`requestSystemPrompt`), consent or not, so adding them here sends them twice.
        if includeOnDeviceSignals {
            let block = await onDeviceSignalsBlock()
            if !block.isEmpty {
                out.append(CoachContextBlock(name: "on-device signals and lab book", value: 35, full: block))
            }
        }
        // AFTER the figures, not in the middle of them: what the wearer told the coach about their week and
        // what it wrote down itself are constraints on the answer, not data to reason from.
        let constraints = Self.sessionConstraints()
        if !constraints.isEmpty {
            out.append(CoachContextBlock(name: "their routines and the memory file", value: 55,
                                         full: constraints))
        }
        // The last thing the model reads before the question. Short on purpose — it is a reminder of the
        // frame at the top, placed where recency makes it stick.
        out.append(CoachContextBlock(name: "the dating rule", value: 80, full: CoachDayFrame.closingRule))
        return out
    }

    /// The SHORT history: the last few days' three scores and the 30-day averages, without the fourteen-row
    /// per-metric table.
    ///
    /// WHAT IT IS FOR. `buildContext()` emits fourteen rows of eleven fields each — about 680 estimated
    /// tokens — which the chat earns and the State tile does not: the tile asks what is due in the next few
    /// hours, and "how has the week gone" is answered by five lines. This is that answer, and it is also
    /// `buildContext()`'s own short form when a chat request will not take the full table.
    ///
    /// ABSTAINS THE SAME WAY the table does: a dash is "not measured", said in the header, and a day with
    /// nothing in it still gets its row rather than being skipped.
    func shortHistoryBlock(days: Int = 5) -> String {
        let all = repo.days
        guard !all.isEmpty else {
            return "RECENT DAYS: no wearable data has been recorded yet. Say so rather than estimating."
        }
        let todayKey = CoachDayFrame.key(Date())
        var lines = ["RECENT DAYS (newest first) — charge(0-100), effort(0-100), rest/sleep(h), HRV(ms), "
                     + "RHR(bpm). A dash means NOT MEASURED, not zero. The date is the day the charge's "
                     + "MORNING fell on; the sleep and HRV figures are for the night that ENDED that morning:"]
        for d in Array(all.suffix(max(1, days))).reversed() {
            var parts = [d.day + ":"]
            parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
            parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
            parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
            parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
            parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
            let tag = d.day == todayKey ? "  TODAY, incomplete — " : "  "
            lines.append(tag + parts.joined(separator: ", "))
        }
        if !all.suffix(max(1, days)).contains(where: { $0.day == todayKey }) {
            lines.append("  (No row for today (\(todayKey)) yet — the newest row above is an EARLIER day.)")
        }
        let last30 = Array(all.suffix(30))
        lines.append("30-day averages: charge \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep \(avgSleepHours(last30))h"
                     + ", HRV \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm"
                     + ", steps \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day")
        return lines.joined(separator: "\n")
    }

    /// One derived stress line for the coach context: the Baevsky Stress Index for TODAY, read via the
    /// same device-aware repository R-R union as `StressView` and summarised EXACTLY as that screen does —
    /// the median of today's 5-minute windows (`StressIndex.medianWindowStressIndex(rr:)`, F8). One SI over
    /// the whole midnight → now series pooled sleep, exercise and rest into a single histogram and measured
    /// the day's HR spread rather than autonomic rigidity. Returns nil when the store is unavailable or no
    /// 5-minute window has enough beats, so the line is simply absent, never a fabricated value.
    /// Summary-only: the raw R-R never leaves the device.
    func stressIndexLine() async -> String? {
        guard let si = await stressIndexToday() else { return nil }
        return Self.stressIndexSummary(si: si)
    }

    /// The figure behind that line. Split out so the State tile's own grounding can put the SAME number in
    /// its own stress block instead of carrying a second copy of the read — one source per concern.
    func stressIndexToday(now: Date = Date()) async -> Double? {
        let cal = Calendar.current
        let from = Int(cal.startOfDay(for: now).timeIntervalSince1970)
        let to = Int(now.timeIntervalSince1970)
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        return StressIndex.medianWindowStressIndex(rr: rr)
    }

    /// Pure formatter for the derived stress line, kept separate so it is unit-testable without a store.
    /// One summary number, labelled, with a plain-English note that it's an autonomic-balance proxy.
    ///
    /// `nonisolated` because it touches nothing on the engine: the State tile's own grounding
    /// (`StateGrounding.stressBlock`) is pure and off the main actor, and it must use THIS sentence rather
    /// than a second copy of it.
    nonisolated static func stressIndexSummary(si: Double) -> String {
        "Stress (SI): \(Int(si.rounded())) (Baevsky Stress Index, median of 5-minute windows today; higher means more sympathetic / under load; an autonomic-balance proxy, not a clinical figure)."
    }

    /// A SUMMARY-ONLY block of the new on-device signals, the user's strongest n-of-1 correlations
    /// (lag-aware EffectRanker) and a one-line roll-up of their Lab Book markers. Plain sentences, never
    /// raw readings: this rides the same text channel as the metrics summary, so the no-raw-egress posture
    /// holds. Gated by the caller on the second opt-in; returns "" when there's nothing worth adding.
    func onDeviceSignalsBlock() async -> String {
        var lines: [String] = []

        // 1. Strongest behaviour→outcome associations (EffectRanker over the journal × Charge).
        let entries = await repo.journalEntries()
        // Yes days and NO days, kept apart. A day with no journal row for the question lands in
        // neither, so an unanswered day is never counted as a No (BehaviorInsights.effect).
        var byBehaviour: [String: Set<String>] = [:]
        var controls: [String: Set<String>] = [:]
        for e in entries {
            if e.answeredYes { byBehaviour[e.question, default: []].insert(e.day) }
            else { controls[e.question, default: []].insert(e.day) }
        }
        if !byBehaviour.isEmpty {
            let outcomeByDay = Dictionary(
                repo.days.compactMap { d in d.recovery.map { (d.day, $0) } },
                uniquingKeysWith: { _, last in last })
            let ranked = EffectRanker.rank(behaviors: byBehaviour, controls: controls,
                                           outcomeByDay: outcomeByDay, outcome: "Charge")
                .filter { $0.effect.significant }
                .prefix(3)
            if !ranked.isEmpty {
                lines.append("STRONGEST PERSONAL PATTERNS (the user's own data — association, not cause):")
                for r in ranked { lines.append("  • " + r.sentence()) }
            }
        }

        // 2. Lab Book markers roll-up (count + latest of a few, never the full history).
        if let store = await repo.storeHandle() {
            var markerSummaries: [String] = []
            for category in LabMarkerCategory.allCases {
                let rows = (try? await store.labMarkers(deviceId: repo.deviceId, category: category.rawValue)) ?? []
                let byKey = Dictionary(grouping: rows, by: { $0.markerKey })
                for (key, kRows) in byKey {
                    guard let latest = kRows.sorted(by: { $0.takenAt < $1.takenAt }).last else { continue }
                    let name = MarkerCatalog.definition(for: key)?.displayName ?? key
                    let value = latest.value.map { "\(LabBookFormat.value($0, key: key)) \(latest.unit)" } ?? latest.valueText ?? "—"
                    markerSummaries.append("\(name) \(value)")
                }
            }
            if !markerSummaries.isEmpty {
                lines.append("")
                lines.append("LAB BOOK (the user's own logged health numbers — not medical advice; do not interpret as clinical findings):")
                lines.append("  " + markerSummaries.prefix(8).joined(separator: ", "))
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Dispatch to the user's chosen provider client.
    private func callProvider(key: String,
                              messages: [(role: ChatMessage.Role, content: String)]) async throws -> String {
        try await provider.client.send(
            key: key,
            model: model,
            systemPrompt: requestSystemPrompt(Self.withMobileFormatting(systemPrompt)),
            messages: messages,
            session: session
        )
    }

    /// K1: Dispatch to the user's chosen provider client's streaming method. The default
    /// `AIProviderClient.stream` falls back to `send` + a single delta, so providers without
    /// streaming still work. K11: when an inline image is present, dispatches to
    /// `streamWithImage` instead (Gemini overrides it; others ignore the image).
    private func streamProvider(key: String,
                                messages: [(role: ChatMessage.Role, content: String)],
                                inlineImage: String? = nil,
                                onDelta: (String) -> Void) async throws {
        try await provider.client.streamWithImage(
            key: key,
            model: model,
            systemPrompt: requestSystemPrompt(Self.withMobileFormatting(systemPrompt)),
            messages: messages,
            inlineImage: inlineImage,
            session: session,
            onDelta: onDelta
        )
    }

    /// Sliding window over the chat: the FIRST user turn (it carries the metrics context) plus the most
    /// recent `maxHistoryMessages`, dropping the middle. Sending the whole growing history crowds out the
    /// reply on small-context local servers (Ollama defaults to a 2048-token window, the Custom
    /// provider's main use case) and balloons token cost/latency on cloud providers. (parity with Android)
    /// True when a transcript last written on `lastEpochDay` should be retired before a question asked
    /// on `todayEpochDay` — i.e. the conversation crossed into a new local day.
    ///
    /// STRICTLY forward (`>`, never `!=`): a clock that moves BACKWARDS — the user flying west, a
    /// timezone change, an NTP correction — must not wipe a conversation they are in the middle of.
    /// Only real elapsed days retire a transcript. A nil `lastEpochDay` (nothing sent yet) is never
    /// stale. Kotlin twin: `CoachViewModel.isStaleConversation`.
    ///
    /// `nonisolated` because it is a pure function of its arguments. AICoachEngine is @MainActor, so
    /// without this the rule inherits that isolation and cannot be called from a synchronous test —
    /// which is exactly how the first attempt at this twin failed to compile. Isolating a function
    /// that touches no state buys nothing and costs its testability.
    nonisolated static func isStaleConversation(lastEpochDay: Int?, todayEpochDay: Int) -> Bool {
        guard let lastEpochDay else { return false }
        return todayEpochDay > lastEpochDay
    }

    /// Days since the epoch in the LOCAL calendar. Kotlin computes the same value with
    /// `LocalDate.now().toEpochDay()`.
    ///
    /// Counted with calendar day arithmetic from `startOfDay`, not by dividing an interval by 86,400:
    /// a day is not always 86,400 seconds (DST), and the rule only needs a value that increments
    /// exactly once per local midnight and orders correctly. Injectable so the tests never depend on
    /// the machine's clock or zone.
    nonisolated static func localEpochDay(_ date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let epoch = Date(timeIntervalSince1970: 0)
        return calendar.dateComponents([.day], from: epoch, to: start).day ?? 0
    }

    ///
    /// K13: when the middle is dropped, a one-line summary of the dropped turns is prepended to the
    /// first user turn so the model retains context continuity (instead of seeing a gap). The summary
    /// is generated via the same provider, with a short prompt; on failure it degrades to the old
    /// behaviour (no summary, just the windowed set).
    private static let maxHistoryMessages = 10
    /// K13: the cached summary of the dropped middle, regenerated when the dropped set changes.
    private var droppedSummary: String?
    private var droppedSummaryKey: [String] = []

    private func windowedMessages() -> [ChatMessage] {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return messages }
        let recentStart = messages.count - Self.maxHistoryMessages
        // If the first user turn already falls inside the recent window, that window covers it.
        if firstUser >= recentStart { return Array(messages.suffix(Self.maxHistoryMessages)) }
        // K13: inject the summary of the dropped middle by prepending it to the first user turn,
        // so the model sees continuity instead of a gap. We don't use a separate system message
        // because the Role enum only has .user/.assistant (providers map those to API roles).
        var windowed = [messages[firstUser]]
        if let summary = droppedSummary {
            let first = windowed[0]
            windowed[0] = ChatMessage(id: first.id, role: first.role, text: "\(summary)\n\n---\n\n\(first.text)")
        }
        windowed.append(contentsOf: messages[recentStart...])
        return windowed
    }

    /// K13: When the conversation overflows the sliding window, summarize the dropped middle turns
    /// into a single system message. Called before each send when the window would drop messages.
    /// Best-effort: on any failure, leaves `droppedSummary` nil (the old gap behaviour).
    private func summarizeDroppedMiddleIfNeeded(key: String) async {
        guard messages.count > Self.maxHistoryMessages + 1,
              let firstUser = messages.firstIndex(where: { $0.role == .user }) else { return }
        let recentStart = messages.count - Self.maxHistoryMessages
        guard firstUser < recentStart else { return }

        // The dropped middle is messages[firstUser+1 ..< recentStart]. Cache on its identity so we
        // don't re-summarize the same set on every send.
        let dropped = Array(messages[(firstUser + 1)..<recentStart])
        let keySignature = dropped.map { "\($0.role.rawValue):\($0.text)" }
        guard droppedSummaryKey != keySignature else { return }
        droppedSummaryKey = keySignature

        // Build a compact transcript of the dropped turns for the summarizer.
        let transcript = dropped.map { m in
            "\(m.role == .user ? "User" : "Coach"): \(m.text)"
        }.joined(separator: "\n")

        let summaryPrompt = """
        Summarize the following conversation in 2-3 sentences, preserving the key advice and \
        any specific numbers or recommendations. This summary will be shown to you as context \
        for the ongoing conversation.\n\n\(transcript)
        """
        let wire: [(role: ChatMessage.Role, content: String)] = [
            (.user, "You are a concise summarizer. Summarize the conversation in 2-3 sentences.\n\n\(summaryPrompt)"),
        ]
        if let summary = try? await callProvider(key: key, messages: wire) {
            droppedSummary = "Summary of earlier conversation: \(summary.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// The chat as `(role, content)` pairs, with the metrics context prepended to the first user turn.
    private func wireMessages(context: String) -> [(role: ChatMessage.Role, content: String)] {
        var out: [(role: ChatMessage.Role, content: String)] = []
        var contextInjected = false
        for m in windowedMessages() {
            let text = wireOverrides[m.id] ?? m.text
            if m.role == .user && !contextInjected {
                contextInjected = true
                out.append((.user, context + "\n\n---\n\nQuestion: " + text))
            } else {
                out.append((m.role, text))
            }
        }
        return out
    }

    /// The full brief sent in place of a user turn's visible text, by message id (`CoachAnalysisPreset`).
    /// In memory only: after a relaunch an old analysis turn goes out as its name, which still reads as
    /// the question it was.
    private var wireOverrides: [UUID: String] = [:]

    // MARK: - Context builder

    /// Build a compact plain-text summary of the user's recent data: last ~14 days of
    /// recovery/strain/sleep-hours/HRV/restingHR where present, plus 30-day averages, plus a few
    /// recent workouts. Kept well under ~1500 tokens. If there's no data, it says so.
    func buildContext() -> String {
        let days = repo.days // oldest → newest
        var lines: [String] = ["USER BIOMETRIC SUMMARY (the user's own wearable data):"]

        guard !days.isEmpty else {
            return """
            USER BIOMETRIC SUMMARY:
            No wearable data is available yet. Acknowledge this and give general, encouraging guidance \
            while inviting the user to sync their device so future advice can reference real numbers.
            """
        }

        // Last ~14 days, newest first for readability.
        let recent = Array(days.suffix(14)).reversed()
        let todayKey = CoachDayFrame.key(Date())
        lines.append("")
        lines.append("Recent days (newest first) — charge(0-100), effort(0-100), rest/sleep(h), "
                     + "deep/REM/light(h), eff(%), HRV(ms), RHR(bpm). A dash means NOT MEASURED, not zero. "
                     + "The date on each row is the day the charge's MORNING fell on and the day the effort "
                     + "is the total for; the sleep figures are for the night that ENDED that morning:")
        for d in recent {
            // Said on the row itself: an unlabelled newest row is read as "now" whatever its date, which is
            // how yesterday's charge got quoted as today's.
            let tag = d.day == todayKey ? "  TODAY, incomplete — " : "  "
            lines.append(tag + dayLine(d))
        }
        if !recent.contains(where: { $0.day == todayKey }) {
            lines.append("  (No row for today (\(todayKey)) yet. The newest row above is an EARLIER day — "
                         + "do not present it as today.)")
        }

        // 30-day averages.
        let last30 = Array(days.suffix(30))
        lines.append("")
        lines.append("30-day averages:")
        lines.append("  charge: \(avgInt(last30.compactMap { $0.recovery }))"
                     + ", effort: \(avgOne(last30.compactMap { $0.strain }))"
                     + ", sleep: \(avgSleepHours(last30))h"
                     + ", HRV: \(avgInt(last30.compactMap { $0.avgHrv })) ms"
                     + ", RHR: \(avgInt(last30.compactMap { $0.restingHr.map(Double.init) })) bpm")
        // Additional vitals when present (#124, the coach used to see only recovery/strain/sleep/HRV/RHR).
        lines.append("  SpO2: \(avgInt(last30.compactMap { $0.spo2Pct }))%"
                     + ", respiration: \(avgOne(last30.compactMap { $0.respRateBpm }))/min"
                     + ", skin-temp deviation: \(avgOne(last30.compactMap { $0.skinTempDevC }))°C"
                     + ", steps: \(avgInt(last30.compactMap { $0.steps.map(Double.init) }))/day"
                     // `activeKcalEst` is the day's TOTAL energy estimate (resting + active) despite its name.
                     + ", total energy: \(avgInt(last30.compactMap { $0.activeKcalEst }))kcal/day")

        return lines.joined(separator: "\n")
    }

    /// Append recent workouts to an existing context string. Async (workouts are read from the store),
    /// so callers that want workouts in the context can await this and feed the result to `send`'s
    /// flow via the chat, kept separate so `buildContext()` stays synchronous per the spec.
    /// TEN, not six. Six was set when the only sessions here were the ones logged in this app; the
    /// WHOOP cloud now contributes every session the wearer recorded on the strap, and a keen week runs
    /// past six — at which point the block silently became "the last four days" while still being
    /// introduced to the model as the last thirty.
    func recentWorkoutsBlock(limit: Int = 10) async -> String {
        let rows = await repo.workoutRows(days: 30) // newest first
        guard !rows.isEmpty else { return "Recent workouts: none recorded in the last 30 days." }
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let distanceSystem = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        var lines = ["Recent workouts (newest first):"]
        for w in rows.prefix(limit) {
            var parts = ["  \(dateString(w.startTs)) \(w.sport)"]
            if let dur = w.durationS { parts.append("\(Int((dur / 60).rounded())) min") }
            if let s = w.strain { parts.append("effort \(String(format: "%.1f", s))") }
            if let hr = w.avgHr { parts.append("avg HR \(hr)") }
            if let kcal = w.energyKcal { parts.append("\(Int(kcal.rounded())) kcal") }
            if let dist = w.distanceM {
                parts.append(UnitFormatter.distanceFromMeters(dist, system: distanceSystem))
            }
            lines.append(parts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Formatting helpers

    /// `internal`, not private, so `AICoachSleepContextTests` can assert the emitted line directly.
    /// Swift's `buildContext()` takes no arguments (it reads the repo), unlike the Kotlin twin which is
    /// handed the day list — so without this the formatter has no seam and the Swift half of a change
    /// with fifteen Kotlin tests would ship untested.
    func dayLine(_ d: DailyMetric) -> String {
        var parts: [String] = [d.day + ":"]
        parts.append("charge " + (d.recovery.map { "\(Int($0.rounded()))" } ?? "—"))
        parts.append("effort " + (d.strain.map { String(format: "%.1f", $0) } ?? "—"))
        parts.append("rest " + (d.totalSleepMin.map { String(format: "%.1fh", $0 / 60) } ?? "—"))
        // The stage breakdown and efficiency, which the coach could not see at all: a user asked why it
        // said it had no access to sleep stages, and it was answering honestly — `rest 7.8h` was every
        // word it got about a night. These four sit on the SAME DailyMetric the line already reads, so
        // nothing new is plumbed; they were simply never included. (#124 widened this context once
        // before, for the same reason.)
        //
        // Always emitted, "—" when absent, like every other field here. A night with no staging then
        // says so rather than going quiet, which matters more than line length: the alternative — only
        // appending stages when present — gives the model a schema that changes shape between days and
        // invites it to read a missing field as a zero.
        parts.append("deep " + hoursOrDash(d.deepMin))
        parts.append("REM " + hoursOrDash(d.remMin))
        parts.append("light " + hoursOrDash(d.lightMin))
        parts.append("eff " + efficiencyPercentOrDash(d.efficiency))
        parts.append("HRV " + (d.avgHrv.map { "\(Int($0.rounded()))ms" } ?? "—"))
        parts.append("RHR " + (d.restingHr.map { "\($0)bpm" } ?? "—"))
        return parts.joined(separator: ", ")
    }

    /// Minutes as "1.4h", or "—" when the night has no value. Matches the `rest` field's format so a
    /// stage total and the total it is part of read on the same scale.
    private func hoursOrDash(_ minutes: Double?) -> String {
        minutes.map { String(format: "%.1fh", $0 / 60) } ?? "—"
    }

    /// Efficiency as a percentage, NORMALISING the stored value first.
    ///
    /// `DailyMetric.efficiency` is not reliably a 0–1 fraction: it "arrives as % on some import paths",
    /// which `SleepView` and `StagesCard` each guard against inline with this same `> 1.5` test. A bare
    /// `* 100` would therefore hand the coach "eff 9400%" for an imported night — and a model given a
    /// nonsense number reasons about it confidently rather than ignoring it.
    ///
    /// 1.5 rather than 1.0 because a genuine fraction can exceed 1.0 only by floating-point noise, while
    /// a genuine percentage is 30–100 and nowhere near the threshold. Android's two copies of this guard
    /// split at 1.0 instead, which is a pre-existing divergence and not this change's to settle.
    func efficiencyPercentOrDash(_ raw: Double?) -> String {
        guard var e = raw, e > 0 else { return "—" }
        if e > 1.5 { e /= 100 }
        guard e > 0, e <= 1 else { return "—" }
        return "\(Int((e * 100).rounded()))%"
    }

    private func avgOne(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return String(format: "%.1f", xs.reduce(0, +) / Double(xs.count))
    }

    private func avgInt(_ xs: [Double]) -> String {
        guard !xs.isEmpty else { return "—" }
        return "\(Int((xs.reduce(0, +) / Double(xs.count)).rounded()))"
    }

    private func avgSleepHours(_ days: [DailyMetric]) -> String {
        let mins = days.compactMap { $0.totalSleepMin }
        guard !mins.isEmpty else { return "—" }
        return String(format: "%.1f", (mins.reduce(0, +) / Double(mins.count)) / 60)
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

/// Coalesces a streamed reply's `messages` writes to at most one per ~16 ms (one frame). Each write
/// re-renders the transcript and re-parses the whole reply as Markdown, and providers deliver many small
/// chunks per frame. A chunk that lands inside the window marks the latest text pending and schedules a
/// single trailing flush, so a stream that pauses still shows everything it has sent. `finish()` stops
/// all further writes — callers always write the FINAL text themselves after the stream ends, so the
/// settled message is byte-identical to the unthrottled path.
@MainActor
final class CoachStreamThrottle {
    private static let interval: TimeInterval = 0.016
    private let publish: (String) -> Void
    private var latest = ""
    private var lastPublish: TimeInterval = -.infinity
    private var pending = false
    private var finished = false

    init(publish: @escaping (String) -> Void) {
        self.publish = publish
    }

    func submit(_ text: String) {
        guard !finished else { return }
        latest = text
        guard !pending else { return }   // a trailing flush is already scheduled; it will take `latest`
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastPublish
        if elapsed >= Self.interval {
            lastPublish = now
            publish(text)
        } else {
            pending = true
            let delay = Self.interval - elapsed
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                self?.flushPending()
            }
        }
    }

    func finish() {
        finished = true
        pending = false
    }

    private func flushPending() {
        guard pending, !finished else { return }
        pending = false
        lastPublish = ProcessInfo.processInfo.systemUptime
        publish(latest)
    }
}
