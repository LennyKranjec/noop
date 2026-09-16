import Foundation

// AIRateLimit.swift — the provider's own ledger, as it reports it.
//
// `AITokenBudget` counts what THIS app has spent since it was installed, from the `usage` block of the
// replies it received. That is honest and it is also not the number on the dashboard: it cannot see a
// request made from anywhere else, it starts at zero on a reinstall, it rolls on the device's midnight
// rather than the provider's, and it has no idea what the allowance actually is — the 200,000 in it is
// a figure that was typed in, not one that was asked for.
//
// GROQ SENDS THE REAL ONE ON EVERY RESPONSE. Six headers, on the 429 as well as on the 200:
//
//   x-ratelimit-limit-requests / -remaining-requests / -reset-requests
//   x-ratelimit-limit-tokens   / -remaining-tokens   / -reset-tokens
//
// So the app does not have to keep score. It has to READ.
//
// WHICH WINDOW EACH PAIR DESCRIBES IS TAKEN FROM ITS OWN RESET, not assumed. Groq's request pair is
// usually per day and its token pair usually per minute, but that varies by tier and by model, and a
// bar labelled "today" that is in fact "this minute" is worse than no bar: it would sit near full all
// day and drop to nothing seconds before a 429. The reset field says how long the window has left, so a
// window with more than an hour to run is a daily one and a window with seconds is not. That reading is
// the provider's own, per response, per model.
//
// NOTHING IS INVENTED. No headers means no reading, and the pill falls back to the local tally, which
// is labelled as the local tally.

/// One window's worth of allowance, as the provider reports it.
struct AIRateLimitWindow: Equatable, Codable {
    let limit: Int
    let remaining: Int
    /// Seconds until this window resets, at the moment the response was received.
    let resetSeconds: Double

    var used: Int { max(0, limit - remaining) }
    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(limit)))
    }

    /// Whether this window is a day rather than a minute.
    ///
    /// AN HOUR IS THE DIVIDING LINE, and it is nowhere near either candidate: a per-minute window resets
    /// in under sixty seconds and a per-day one in up to twenty-four hours, so anything in between is
    /// already outside both and the classification cannot flip on a slow response.
    var isDaily: Bool { resetSeconds >= 3600 }
}

/// What one model's last response said about its allowances.
struct AIRateLimitReading: Equatable, Codable {
    let model: String
    let requests: AIRateLimitWindow?
    let tokens: AIRateLimitWindow?
    let receivedAt: Date

    /// The daily token window, when the provider reports one. This is the figure the wearer means by
    /// "tokens today"; when it is nil, the provider is metering tokens per minute and the day is
    /// measured in requests instead.
    var dailyTokens: AIRateLimitWindow? {
        guard let tokens, tokens.isDaily else { return nil }
        return tokens
    }

    /// The daily request window, when the provider reports one.
    var dailyRequests: AIRateLimitWindow? {
        guard let requests, requests.isDaily else { return nil }
        return requests
    }

    /// How old this reading is. A reading from yesterday describes yesterday's window, and showing it
    /// as today's would be the same lie the local counter was accused of.
    var age: TimeInterval { Date().timeIntervalSince(receivedAt) }

    /// Beyond this, the reading is not shown. Six hours: long enough that a coach used at breakfast
    /// still has a live figure at lunch, short enough that it cannot survive a night.
    static let maxAge: TimeInterval = 6 * 3600

    var isFresh: Bool { age < Self.maxAge && age > -60 }
}

enum AIRateLimit {

    private static let keyPrefix = "ai.ratelimit."

    /// Read one response's headers and bank whatever they said.
    ///
    /// A response with none of these headers leaves the STORED reading alone rather than clearing it: a
    /// provider that does not report limits must not wipe the last thing the one that does said, and a
    /// single proxy that strips headers must not blank a working gauge.
    static func record(model: String, headers: [String: String], _ d: UserDefaults = .standard) {
        let model = normalise(model)
        guard !model.isEmpty else { return }
        // LOWER-CASED HERE TOO, not only in the HTTP helper that usually hands these over. Header names
        // are case-insensitive and proxies re-spell them; a reader that depends on someone upstream
        // having normalised first is a reader that silently returns nothing the day it is called from
        // anywhere else.
        var headers = headers
        for (key, value) in headers where key != key.lowercased() {
            headers[key.lowercased()] = value
        }
        let requests = window(headers, "requests")
        let tokens = window(headers, "tokens")
        guard requests != nil || tokens != nil else { return }
        let reading = AIRateLimitReading(model: model, requests: requests, tokens: tokens,
                                         receivedAt: Date())
        if let data = try? JSONEncoder().encode(reading) {
            d.set(data, forKey: keyPrefix + model)
        }
    }

    /// The last reading for `model`, if there is a recent one.
    static func reading(model: String, _ d: UserDefaults = .standard) -> AIRateLimitReading? {
        let model = normalise(model)
        guard !model.isEmpty,
              let data = d.data(forKey: keyPrefix + model),
              let reading = try? JSONDecoder().decode(AIRateLimitReading.self, from: data),
              reading.isFresh
        else { return nil }
        return reading
    }

    static func forget(model: String, _ d: UserDefaults = .standard) {
        d.removeObject(forKey: keyPrefix + normalise(model))
    }

    // MARK: - Parsing

    /// One `limit` / `remaining` / `reset` triple. Nil unless the limit and the remainder are both
    /// present — half a window is not a window, and drawing a bar against a missing limit would mean
    /// choosing a denominator, which is exactly the invention this replaces.
    static func window(_ headers: [String: String], _ suffix: String) -> AIRateLimitWindow? {
        guard let limit = int(headers["x-ratelimit-limit-" + suffix]),
              let remaining = int(headers["x-ratelimit-remaining-" + suffix]),
              limit > 0
        else { return nil }
        return AIRateLimitWindow(limit: limit,
                                 remaining: max(0, min(limit, remaining)),
                                 resetSeconds: duration(headers["x-ratelimit-reset-" + suffix]) ?? 0)
    }

    /// A count. Some servers send a decimal here, so it is read as a number and rounded rather than
    /// parsed as an integer and dropped.
    static func int(_ raw: String?) -> Int? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Int(value.rounded())
    }

    /// Groq's own duration spelling: "7.66s", "2m59.56s", "1h2m3s", "300ms", and a bare "60" for
    /// seconds (which is what an OpenAI-compatible server sends where Groq sends a duration).
    ///
    /// WRITTEN OUT RATHER THAN REGEXED because the failure mode matters: a duration this does not
    /// understand returns nil, the window then reads as per-minute, and a daily allowance would be
    /// drawn as a minute's. Walking the string means every unit it accepts is one somebody chose.
    static func duration(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        if let bare = Double(text) { return bare }

        var total: Double = 0
        var number = ""
        var matched = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c.isNumber || c == "." {
                number.append(c)
                index = text.index(after: index)
                continue
            }
            // A UNIT WITH NO NUMBER IN FRONT OF IT IS NOT A DURATION. Without this, "soon" parsed as
            // zero seconds and passed for a real reading — and zero seconds is not a harmless default
            // here: it is what tells the window classifier "this resets immediately", which turns a
            // daily allowance into a per-minute one.
            guard let value = Double(number) else { return nil }
            number = ""
            if text[index...].hasPrefix("ms") {
                total += value / 1000
                index = text.index(index, offsetBy: 2)
            } else {
                switch c {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                index = text.index(after: index)
            }
            matched = true
        }
        // Trailing digits with no unit ("1h2") are a spelling nobody sends; the part that did parse is
        // returned rather than the whole reading being thrown away over it.
        return matched ? total : nil
    }

    private static func normalise(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
