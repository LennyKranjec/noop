import Foundation

// AITokenBudget.swift — how much of today's allowance the current model has spent.
//
// Groq's free tier is metered per DAY, per MODEL, in tokens. The ceiling is the thing a wearer actually
// runs into: the coach simply stops answering, mid-conversation, with a 429 and no warning — and the
// obvious reading of that is "the app is broken", not "the day's allowance is gone". A bar that fills
// as the day goes on turns a cliff into something you can see coming.
//
// COUNTED FROM THE PROVIDER'S OWN `usage`, never estimated from the text. A character-count estimate
// would be wrong by whatever the tokeniser does, wrong again for the system prompt and the grounding
// block, and wrong in the direction that matters — under-reporting, right up until the request that
// fails. A turn the provider did not report usage for adds NOTHING rather than a guess, and the reading
// says how many turns that was, so a silent under-count cannot masquerade as a comfortable margin.
//
// PER MODEL, because the allowance is. Switching from the 20b to the 120b does not spend one budget
// twice; it starts on the other one, and a single shared counter would show a number that belongs to
// neither.
//
// THE DAY IS THE DEVICE'S LOCAL DAY, which is not exactly the provider's reset. Groq resets on UTC
// midnight; using that here would move the bar at a time of day that means nothing to the wearer, and
// the bar is a warning rather than an invoice. The gap is named on screen rather than papered over.

enum AITokenBudget {

    /// The daily ceiling this is measured against.
    ///
    /// 200,000 is the figure the wearer gave, and it is what the free tier allows per model per day for
    /// the two `gpt-oss` models the coach defaults to. It is NOT read from the provider: Groq reports
    /// its per-minute token limit in a header and its per-day limit in the dashboard, so a number taken
    /// from the response would quietly be the wrong one.
    static let dailyLimit = 200_000

    /// Above this share, the reading turns to the warning colour. Four fifths leaves room to finish a
    /// conversation after noticing.
    static let warnAt = 0.80

    private static let usedKeyPrefix = "ai.tokens.used."
    private static let blindKeyPrefix = "ai.tokens.blind."
    private static let dayKeyPrefix = "ai.tokens.day."
    private static let limitKeyPrefix = "ai.tokens.limit."
    private static let syncedKeyPrefix = "ai.tokens.synced."

    /// One day's spend on one model.
    struct Reading: Equatable {
        let model: String
        let used: Int
        /// Turns this model answered today WITHOUT reporting their cost. See the note at the top: these
        /// are the reason `used` is a floor rather than a total.
        let unmetered: Int
        /// The day's ceiling. The provider's own figure once it has stated one, `dailyLimit` until then.
        let limit: Int
        /// When the provider last stated the day's real usage. Nil until it has. See `absorbProviderError`.
        let syncedAt: Date?

        var remaining: Int { max(0, limit - used) }
        var fraction: Double {
            guard limit > 0 else { return 0 }
            return min(1, Double(used) / Double(limit))
        }
        var isWarning: Bool { fraction >= AITokenBudget.warnAt }
        /// True when nothing has been spent AND nothing went unmetered — i.e. the model has not been
        /// used today at all, as opposed to used without a report.
        var isUntouched: Bool { used == 0 && unmetered == 0 }
    }

    /// Today, in the device's own civil day. Matches how the rest of the app keys a day.
    static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Bank what one turn cost.
    ///
    /// `tokens` is the provider's `usage.total_tokens`. A nil or non-positive figure is recorded as an
    /// UNMETERED turn instead of as zero — a turn that cost nothing did not happen, and writing a zero
    /// would make the counter claim completeness it does not have.
    static func record(model: String, tokens: Int?, _ d: UserDefaults = .standard) {
        let model = normalise(model)
        guard !model.isEmpty else { return }
        rollIfNeeded(model: model, d)
        if let tokens, tokens > 0 {
            d.set(d.integer(forKey: usedKeyPrefix + model) + tokens, forKey: usedKeyPrefix + model)
        } else {
            d.set(d.integer(forKey: blindKeyPrefix + model) + 1, forKey: blindKeyPrefix + model)
        }
    }

    /// Today's spend on `model`. Nil for an empty model name — there is nothing to report against.
    static func reading(model: String, _ d: UserDefaults = .standard) -> Reading? {
        let model = normalise(model)
        guard !model.isEmpty else { return nil }
        rollIfNeeded(model: model, d)
        let storedLimit = d.integer(forKey: limitKeyPrefix + model)
        let synced = d.double(forKey: syncedKeyPrefix + model)
        return Reading(model: model,
                       used: d.integer(forKey: usedKeyPrefix + model),
                       unmetered: d.integer(forKey: blindKeyPrefix + model),
                       limit: storedLimit > 0 ? storedLimit : dailyLimit,
                       syncedAt: synced > 0 ? Date(timeIntervalSince1970: synced) : nil)
    }

    /// Throw away this model's day. The wearer's own button, for when they know the provider's window
    /// has rolled and the local day has not.
    static func reset(model: String, _ d: UserDefaults = .standard) {
        let model = normalise(model)
        guard !model.isEmpty else { return }
        d.removeObject(forKey: usedKeyPrefix + model)
        d.removeObject(forKey: blindKeyPrefix + model)
        d.removeObject(forKey: syncedKeyPrefix + model)
        d.set(dayKey(), forKey: dayKeyPrefix + model)
    }

    /// Pull `usage.total_tokens` out of a chat response body.
    ///
    /// Tolerant on purpose: `usage` is absent on some OpenAI-compatible servers, present but partial on
    /// others, and a missing field here must read as "not reported" rather than as an error. Falls back
    /// to prompt + completion when the total is absent but the halves are not.
    static func totalTokens(in json: [String: Any]) -> Int? {
        guard let usage = json["usage"] as? [String: Any] else { return nil }
        if let total = (usage["total_tokens"] as? NSNumber)?.intValue, total > 0 { return total }
        let prompt = (usage["prompt_tokens"] as? NSNumber)?.intValue ?? 0
        let completion = (usage["completion_tokens"] as? NSNumber)?.intValue ?? 0
        let sum = prompt + completion
        return sum > 0 ? sum : nil
    }

    /// The same read, from one SSE `data:` payload.
    ///
    /// A streamed turn carries its usage only in the FINAL chunk, and only when the request asked for it
    /// (`stream_options.include_usage`). Every other chunk returns nil here, which is why this is a
    /// lookup rather than a parse failure.
    ///
    /// GROQ PUTS IT UNDER `x_groq`. Its final chunk carries `x_groq.usage`, not a top-level `usage`, and
    /// a reader that only looked at the top level counted every streamed Groq turn as unmetered — which is
    /// most of the coach's traffic, and a large part of why this count sat far below the dashboard's.
    static func totalTokens(inStreamPayload payload: String) -> Int? {
        guard payload.contains("\"usage\""),
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let top = totalTokens(in: json) { return top }
        if let groq = json["x_groq"] as? [String: Any] { return totalTokens(in: groq) }
        return nil
    }

    // MARK: - The provider's own figure

    /// Set today's figures to what the provider says they are.
    ///
    /// AUTHORITATIVE, so it REPLACES rather than adds: the provider's "used" already includes every turn
    /// this device counted, and every turn made anywhere else with the same key — the Android build,
    /// a script, the playground. Unmetered turns are cleared for the same reason; the provider has
    /// metered them.
    static func resync(model: String, used: Int, limit: Int, _ d: UserDefaults = .standard) {
        let model = normalise(model)
        guard !model.isEmpty, used >= 0, limit > 0 else { return }
        rollIfNeeded(model: model, d)
        d.set(used, forKey: usedKeyPrefix + model)
        d.set(0, forKey: blindKeyPrefix + model)
        d.set(limit, forKey: limitKeyPrefix + model)
        d.set(Date().timeIntervalSince1970, forKey: syncedKeyPrefix + model)
    }

    /// Read a provider error for a statement of the day's token usage, and resync from it if it is one.
    ///
    /// WHY THIS IS THE SYNC POINT. Groq does not publish daily token usage over its API: a normal reply
    /// carries requests-per-day and tokens-per-MINUTE in its headers, and the per-day figure lives only
    /// on the dashboard. The one place the API states it is the rejection when the day runs out —
    ///
    ///   Rate limit reached for model `openai/gpt-oss-20b` in organization `org_…` service tier
    ///   `on_demand` on tokens per day (TPD): Limit 200000, Used 199500, Requested 1200. …
    ///
    /// — which names the model, the window, the ceiling and the real usage. So that is read, whenever it
    /// arrives, and the local count and the limit both snap to it.
    ///
    /// ONLY THE DAILY TOKEN WINDOW. The same sentence shape reports per-minute limits ("tokens per minute
    /// (TPM)") and request limits, and syncing a day's counter to a minute's usage would be worse than
    /// not syncing at all.
    @discardableResult
    static func absorbProviderError(_ message: String, _ d: UserDefaults = .standard) -> Bool {
        let lower = message.lowercased()
        guard lower.contains("tokens per day") || lower.contains("(tpd)") else { return false }
        guard let model = between(message, "for model `", "`"),
              let limit = number(after: "Limit ", in: message),
              let used = number(after: "Used ", in: message)
        else { return false }
        resync(model: model, used: used, limit: limit, d)
        return true
    }

    /// The text between two markers, or nil.
    private static func between(_ text: String, _ open: String, _ close: String) -> String? {
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex)
        else { return nil }
        let inner = String(text[start.upperBound..<end.lowerBound])
        return inner.isEmpty ? nil : inner
    }

    /// The integer immediately after `label`, tolerating thousands separators.
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

    // MARK: - Private

    /// Drop yesterday's figures the first time today touches this model.
    ///
    /// Lazily, on read or write, rather than on a timer: the app is not running at midnight, and a
    /// counter that only rolls while the app is open would carry a stale day into the morning.
    private static func rollIfNeeded(model: String, _ d: UserDefaults) {
        let today = dayKey()
        guard d.string(forKey: dayKeyPrefix + model) != today else { return }
        d.removeObject(forKey: usedKeyPrefix + model)
        d.removeObject(forKey: blindKeyPrefix + model)
        // The sync time goes with the day; the LIMIT does not. The ceiling is a property of the plan,
        // not of the day, and a stated 200,000 is still 200,000 tomorrow.
        d.removeObject(forKey: syncedKeyPrefix + model)
        d.set(today, forKey: dayKeyPrefix + model)
    }

    /// Model ids are used verbatim as part of a preference key, so they are trimmed and lower-cased —
    /// "openai/gpt-oss-20b" and " openai/GPT-OSS-20b" are one allowance, not two.
    private static func normalise(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
