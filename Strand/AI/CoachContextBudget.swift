import Foundation

// CoachContextBudget.swift — how big a coach request is ALLOWED to be, and what gets left out to make it.
//
// THE FAILURE THIS EXISTS FOR. A wearer on Groq's on-demand tier has 8,000 tokens per MINUTE across every
// request. One State-tile refresh asked for 8,646 in a single request and was refused with a 413:
//
//   Request too large for model `openai/gpt-oss-120b` … on tokens per minute (TPM): Limit 8000,
//   Requested 8646, please reduce your message size and try again.
//
// The context builders had no idea how much they were spending. `buildFullContext()` appended every block
// it could find — the day frame, the three scores, the whole level formula, fourteen days of every metric,
// ten workouts, ten sections of CoachExtraContext including the dream journal, the routines and the memory
// file — and then the caller stapled its own grounding and a thousand-token system prompt on top. There was
// no number anywhere in that path, so nothing could notice.
//
// SO EVERY REQUEST NOW CARRIES A CEILING, and the context is assembled to fit it:
//
// 1. The caller states a budget for the WHOLE request (system prompt + context + question), because that is
//    what the provider meters. A budget over the context alone is the mistake that produced 8,646.
// 2. Blocks are declared with a VALUE for that request. The State tile's value order is not the chat's:
//    the tile needs today's figures and the schedule, and does not need the dream journal.
// 3. When the budget will not take everything, blocks are degraded CHEAPEST-VALUE-FIRST — summarised where
//    a block has a short form, dropped where it does not.
// 4. What was shortened or dropped is STATED, in one line. A trimmed context a model reads as a complete
//    one is how "you have logged no meditation" gets said about a block that was simply left out.
//
// THE ESTIMATE IS THE EXISTING ONE: four characters per token, the same yardstick
// `AICoachEngine.estimatedTokens` has always used. It is rough, and it is rough in a known direction —
// so the budgets below leave room rather than the estimator pretending to precision.

// MARK: - The yardstick

enum CoachTokens {

    /// Characters per token. The standard rough heuristic, and the one this app already estimated with.
    static let charsPerToken = 4

    /// Rough token count for a string. Rounded UP: a budget that rounds down is a budget that is
    /// occasionally exceeded, and the whole point here is the ceiling.
    static func estimate(_ text: String) -> Int {
        (text.count + charsPerToken - 1) / charsPerToken
    }

    /// The same, for several pieces of one request.
    static func estimate(_ pieces: [String]) -> Int {
        pieces.reduce(0) { $0 + estimate($1) }
    }
}

// MARK: - One block of grounding

/// One labelled piece of a context, with what it is worth to THIS request and a shorter form if it has one.
struct CoachContextBlock: Equatable {
    /// A few words, for the trimmed-context note. Written for the model to read, so plain English.
    let name: String
    /// Higher is kept longer. Ties keep declaration order, so the reading order a prompt was written for
    /// is never reshuffled by the budget.
    let value: Int
    let full: String
    /// A shorter form of the SAME information, or nil when the block can only be dropped whole.
    let short: String?

    init(name: String, value: Int, full: String, short: String? = nil) {
        self.name = name
        self.value = value
        self.full = full
        self.short = short
    }

    var isEmpty: Bool { full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// What the assembler produced, and what it had to give up to produce it.
struct CoachContextFit: Equatable {
    let text: String
    /// Block names that were sent in their short form, in value order.
    let shortened: [String]
    /// Block names that were left out entirely, in value order.
    let dropped: [String]
    /// The estimated tokens of the WHOLE request this fit was computed against (reserve + context).
    let requestTokens: Int
    /// True when nothing had to be given up.
    var isComplete: Bool { shortened.isEmpty && dropped.isEmpty }
}

enum CoachContextBudget {

    /// The separator between blocks — the same blank line `buildFullContext` always used.
    static let separator = "\n\n"

    /// Characters held back for the trimmed-context note, so adding the note cannot itself overrun the
    /// budget it is reporting. Generous: the note names the blocks it lost.
    static let noteReserveChars = 420

    /// Assemble `blocks` into a context that fits `budget` tokens for the whole request.
    ///
    /// `reserved` is every other token the request will carry — the system prompt's own prose, the clock
    /// block, the question. It is subtracted first, because the provider meters the request and not the
    /// grounding.
    ///
    /// DETERMINISTIC, and that is the point: the same inputs drop the same blocks in the same order, which
    /// is what makes this testable and what stops one refresh sending a block the next one silently omits.
    static func fit(_ blocks: [CoachContextBlock], budget: Int, reserved: Int) -> CoachContextFit {
        let present = blocks.filter { !$0.isEmpty }
        // Value order for DEGRADING; declaration order for WRITING. Sorted with the index as the tie-break
        // so the order is total and stable (Swift's sort is not guaranteed stable on its own).
        let byValue = present.enumerated()
            .sorted { ($0.element.value, $0.offset) < ($1.element.value, $1.offset) }
            .map(\.offset)

        // available = the budget, less everything else in the request, less room for the note.
        let available = max(0, budget - reserved - noteReserveChars / CoachTokens.charsPerToken)

        enum State { case full, short, gone }
        var state = [State](repeating: .full, count: present.count)

        func cost() -> Int {
            var total = 0
            for (i, b) in present.enumerated() {
                switch state[i] {
                case .full: total += CoachTokens.estimate(b.full)
                case .short: total += CoachTokens.estimate(b.short ?? "")
                case .gone: break
                }
            }
            // One separator between each kept block.
            let kept = state.filter { if case .gone = $0 { return false } else { return true } }.count
            return total + max(0, kept - 1) * CoachTokens.estimate(separator)
        }

        // PASS 1 — summarise, cheapest value first. A block with no short form is left alone here: losing
        // it whole is a bigger step than shortening something else, so it waits for pass 2.
        for i in byValue where cost() > available {
            if present[i].short != nil { state[i] = .short }
        }
        // PASS 2 — drop, cheapest value first, whatever is still standing.
        for i in byValue where cost() > available {
            state[i] = .gone
        }

        var pieces: [String] = []
        var shortened: [String] = []
        var dropped: [String] = []
        for (i, b) in present.enumerated() {
            switch state[i] {
            case .full: pieces.append(b.full)
            case .short:
                pieces.append(b.short ?? "")
            case .gone: break
            }
        }
        // Reported in value order — worst loss first is the order a reader cares about.
        for i in byValue.reversed() {
            switch state[i] {
            case .short: shortened.append(present[i].name)
            case .gone: dropped.append(present[i].name)
            case .full: break
            }
        }
        var text = pieces.joined(separator: separator)
        if let line = note(shortened: shortened, dropped: dropped) {
            text += separator + line
        }
        return CoachContextFit(text: text, shortened: shortened, dropped: dropped,
                               requestTokens: reserved + CoachTokens.estimate(text))
    }

    /// The one line that says the context is not the whole picture. nil when it is.
    ///
    /// WHY IT IS THERE AT ALL. A model handed a trimmed context reads it as a complete one and reasons from
    /// the absence — "you have not meditated this week" about a section that was dropped for size. The note
    /// turns that into the abstention the rest of the app is held to.
    static func note(shortened: [String], dropped: [String]) -> String? {
        guard !shortened.isEmpty || !dropped.isEmpty else { return nil }
        var s = "CONTEXT TRIMMED TO FIT THIS REQUEST. "
        if !shortened.isEmpty { s += "Shortened: " + shortened.joined(separator: ", ") + ". " }
        if !dropped.isEmpty { s += "Left out: " + dropped.joined(separator: ", ") + ". " }
        s += "What is missing here is NOT missing from their data: never say a figure is absent, or that "
        s += "they did not do something, because it is not above — say you were not given it."
        return s
    }
}

// MARK: - What each request is allowed to spend

/// The ceiling for one kind of request, in tokens of the WHOLE request.
///
/// THE NUMBERS ARE CHOSEN AGAINST THE SMALLEST ALLOWANCE THIS APP HAS SEEN: 8,000 tokens per minute, shared
/// by every request. The State tile's merged request plus a halved retry has to fit inside one minute of
/// that with room to spare, which is what `stateTile` is sized for — not for how much context would be nice.
enum CoachRequestBudget: String, CaseIterable {
    /// The chat. One request at a time, and the wearer is waiting, so it may be the largest.
    case chat
    /// The morning brief.
    case brief
    /// A day ritual (morning / midday / evening) and the quest it raises.
    case ritual
    /// The State tile's one merged request: the mission line and the workout list together.
    case stateTile
    /// The mission on its own, when nothing else is asking (`ensureDailyMission`).
    case mission
    /// A workout the wearer asked for through the "+".
    case customWorkout
    /// A one-line note over a chart (level, muscle). These build their own small prompts; the budget is a
    /// ceiling, not a target.
    case note
    /// Naming a quest, or writing up a custom task. No biometric grounding at all.
    case naming

    /// The nominal ceiling, before the account's own allowance is taken into account.
    var tokens: Int {
        switch self {
        case .chat:          return 5_200
        case .brief:         return 3_400
        case .ritual:        return 2_600
        // MEASURED, not chosen: the merged writer's instruction is about 1,580 tokens and cannot be trimmed
        // (it is what the coach is asked to DO), the clock block and the question another 170, and the lean
        // grounding about 1,800. 3,800 fits all of it with a little room; anything under about 3,600 starts
        // dropping the routines and the stress curve, which the prompt's own rules read.
        case .stateTile:     return 3_800
        case .mission:       return 2_600
        case .customWorkout: return 2_400
        case .note:          return 1_400
        // The custom-task writer shares this: its prompt is the rules, today's strip and the (capped) memory
        // file, which measures around 1,300 tokens. 1,000 would have flagged the normal case as an overrun.
        case .naming:        return 1_400
        }
    }

    /// The largest share of a per-minute allowance any single request may take.
    ///
    /// A LITTLE UNDER A HALF, which is the arithmetic for ONE request and its retry: 0.45 plus half of that
    /// is 0.675 of the minute, leaving a third spare. It was a third while the State tile sent two requests
    /// in parallel; merging them into one (`StatePlanWriter`) is what bought the room, and keeping the
    /// tighter share now would spend that gain on dropping blocks the prompt reads.
    static let maxShareOfPerMinuteLimit = 0.45

    /// The smallest budget worth sending. Below this the grounding is gone and the answer would be a guess,
    /// so the request is sized here and the trimmed-context note says what is missing.
    static let floor = 900

    /// The ceiling held down to what this account actually allows.
    ///
    /// The provider's own stated per-minute token limit wins over the nominal figure above whenever there is
    /// one — that is the whole point of remembering it. With no stated limit the nominal figure stands: it is
    /// sized for the smallest tier seen, so it is the safe guess rather than an optimistic one.
    func resolved(model: String, _ d: UserDefaults = .standard) -> Int {
        guard let perMinute = AIProviderTokenLimit.perMinute(model: model, d) else { return tokens }
        let share = Int(Double(perMinute) * Self.maxShareOfPerMinuteLimit)
        return max(Self.floor, min(tokens, share))
    }

    /// Half the budget, for the one automatic retry after a 413 or a 429. Never below the floor.
    static func halved(_ budget: Int) -> Int { max(floor, budget / 2) }
}

// MARK: - The per-minute limit this account actually has

/// The provider's stated tokens-per-minute limit, remembered per MODEL.
///
/// PER MODEL AND NOT PER PROVIDER + MODEL, because the allowance is per model and because the only place
/// the figure ever arrives — the refusal message — names the model and not the provider. Keying on
/// something the message does not state would mean guessing, and this is the same key `AITokenBudget` and
/// `AIRateLimit` already use for the same reason.
///
/// WHY NOT `AIRateLimit`. That reads the `x-ratelimit-*` headers of a response, which is the right source
/// when there IS a response — but the request that gets refused for being too large never produces one the
/// app can size the NEXT one from, and the refusal itself states the limit in prose:
///
///   … on tokens per minute (TPM): Limit 8000, Requested 8646, …
///
/// So that sentence is read, and the figure is kept. `AIRateLimit`'s header reading still runs and is still
/// the better source; this fills the gap where the only thing that arrived was the refusal.
///
/// ONLY THE PER-MINUTE TOKEN WINDOW. The same sentence shape reports tokens per DAY (which
/// `AITokenBudget.absorbProviderError` reads, for a completely different purpose) and requests per minute.
/// Sizing a request against a day's allowance would be worse than sizing it against a guess.
enum AIProviderTokenLimit {

    private static let prefix = "ai.tpm."

    static func key(model: String) -> String {
        prefix + model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The remembered per-minute token limit, or nil when the provider has never stated one.
    static func perMinute(model: String, _ d: UserDefaults = .standard) -> Int? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = d.integer(forKey: key(model: trimmed))
        return value > 0 ? value : nil
    }

    static func record(model: String, limit: Int, _ d: UserDefaults = .standard) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return }
        d.set(limit, forKey: key(model: trimmed))
    }

    static func forget(model: String, _ d: UserDefaults = .standard) {
        d.removeObject(forKey: key(model: model))
    }

    /// Read a provider error for a per-minute TOKEN limit and remember it. Returns what it read, or nil.
    ///
    /// THE MODEL COMES FROM THE MESSAGE, never from the caller. The one place this is called from
    /// (`performRequest`) is a shared HTTP helper that has no idea which model it is carrying, and a limit
    /// filed under the wrong model would resize a request that never had that limit. A message that names
    /// no model is READ — the numbers still go into the failure note — but nothing is stored from it.
    @discardableResult
    static func absorb(_ message: String, _ d: UserDefaults = .standard) -> ProviderLimitStatement? {
        guard let statement = parse(message) else { return nil }
        if let named = statement.model { record(model: named, limit: statement.limit, d) }
        return statement
    }

    /// What a "request too large" / per-minute rate-limit message states.
    struct ProviderLimitStatement: Equatable {
        /// The model the message names, when it names one.
        let model: String?
        /// `Limit N`.
        let limit: Int
        /// `Requested N`, when the message states it.
        let requested: Int?

        /// The numbers, for the failure note. Kept short: it goes on a tile.
        var sentence: String {
            requested.map { "limit \(limit) tokens/min, this request asked for \($0)" }
                ?? "limit \(limit) tokens/min"
        }
    }

    /// Pull the per-minute token limit out of a provider message. nil unless it is clearly about that
    /// window — "tokens per minute" or "(TPM)".
    static func parse(_ message: String) -> ProviderLimitStatement? {
        let lower = message.lowercased()
        guard lower.contains("tokens per minute") || lower.contains("(tpm)") else { return nil }
        guard let limit = number(after: "limit ", in: lower), limit > 0 else { return nil }
        return ProviderLimitStatement(model: between(message, "model `", "`"),
                                      limit: limit,
                                      requested: number(after: "requested ", in: lower))
    }

    /// The text between two markers, or nil.
    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex)
        else { return nil }
        let inner = String(text[start.upperBound..<end.lowerBound])
        return inner.isEmpty ? nil : inner
    }

    /// The integer immediately after `label`, tolerating thousands separators. `text` is expected
    /// lower-cased, as is `label`.
    private static func number(after label: String, in text: String) -> Int? {
        guard let start = text.range(of: label) else { return nil }
        var digits = ""
        for c in text[start.upperBound...] {
            if c.isNumber { digits.append(c) }
            else if c == "," && !digits.isEmpty { continue }
            else { break }
        }
        return Int(digits)
    }
}
