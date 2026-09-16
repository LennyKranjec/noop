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

    /// One day's spend on one model.
    struct Reading: Equatable {
        let model: String
        let used: Int
        /// Turns this model answered today WITHOUT reporting their cost. See the note at the top: these
        /// are the reason `used` is a floor rather than a total.
        let unmetered: Int

        var limit: Int { AITokenBudget.dailyLimit }
        var remaining: Int { max(0, AITokenBudget.dailyLimit - used) }
        var fraction: Double {
            guard AITokenBudget.dailyLimit > 0 else { return 0 }
            return min(1, Double(used) / Double(AITokenBudget.dailyLimit))
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
        return Reading(model: model,
                       used: d.integer(forKey: usedKeyPrefix + model),
                       unmetered: d.integer(forKey: blindKeyPrefix + model))
    }

    /// Throw away this model's day. The wearer's own button, for when they know the provider's window
    /// has rolled and the local day has not.
    static func reset(model: String, _ d: UserDefaults = .standard) {
        let model = normalise(model)
        guard !model.isEmpty else { return }
        d.removeObject(forKey: usedKeyPrefix + model)
        d.removeObject(forKey: blindKeyPrefix + model)
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
    static func totalTokens(inStreamPayload payload: String) -> Int? {
        guard payload.contains("\"usage\""),
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return totalTokens(in: json)
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
        d.set(today, forKey: dayKeyPrefix + model)
    }

    /// Model ids are used verbatim as part of a preference key, so they are trimmed and lower-cased —
    /// "openai/gpt-oss-20b" and " openai/GPT-OSS-20b" are one allowance, not two.
    private static func normalise(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
