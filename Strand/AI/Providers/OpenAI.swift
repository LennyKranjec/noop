import Foundation
import StrandAnalytics

struct OpenAIClient: AIProviderClient {

    /// Which OpenAI-format endpoint this instance talks to.
    ///
    /// Groq serves the same `/chat/completions` wire format under its own host, so it shares this client
    /// rather than getting a copy of it — one place to fix when the format moves, and no chance of the
    /// two drifting into subtly different request bodies.
    var provider: AIProvider = .openAI

    func send(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession
    ) async throws -> String {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        // Standard params first (gpt-4 family). Newer/reasoning models reject `temperature` and want
        // `max_completion_tokens`; if the provider 400s about either, retry with the modern shape.
        do {
            return try await chat(key: key, model: model, wire: wire, modernParams: false, session: session)
        } catch let AICoachError.server(code, detail) where code == 400 {
            let d = detail.lowercased()
            if d.contains("max_completion_tokens") || d.contains("max_tokens")
                || d.contains("temperature") || d.contains("unsupported") {
                return try await chat(key: key, model: model, wire: wire, modernParams: true, session: session)
            }
            throw AICoachError.server(code, detail)
        }
    }

    /// K1: Stream via `stream: true`. Same body as `send`, with `stream: true` added. SSE parsing
    /// via `SseDeltas.openAiDelta`. The modern-params retry on 400 is NOT streamed (rare path;
    /// falls back to `send`'s retry). Byte-parity pin in `SseDeltasTests.openAiReassembleMatchesFullReply`.
    func stream(
        key: String,
        model: String,
        systemPrompt: String,
        messages: [(role: ChatMessage.Role, content: String)],
        session: URLSession,
        onDelta: (String) -> Void
    ) async throws {
        var wire: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in messages { wire.append(["role": m.role.rawValue, "content": m.content]) }

        var body: [String: Any] = ["model": model, "messages": wire, "stream": true]
        body["temperature"] = 0.6
        body["max_tokens"] = 4096
        // ASK FOR THE BILL. A streamed turn reports no usage at all unless this is set, and the daily
        // allowance the coach runs on is metered in tokens — without it the budget reading would count
        // only the handful of turns that happen not to stream and then look comfortable right up to the
        // 429. Providers that do not know the option ignore it; it adds one final chunk, not a round trip.
        body["stream_options"] = ["include_usage": true]

        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        // A streamed turn's cost arrives in the LAST chunk, which carries no delta — so it is banked
        // here and the turn is only marked unmetered if no chunk ever carried one.
        var metered: Int?
        try await performStreamingRequest(req, session: session) { payload in
            if let delta = SseDeltas.openAiDelta(payload) {
                onDelta(delta)
            }
            if let tokens = AITokenBudget.totalTokens(inStreamPayload: payload) {
                metered = tokens
            }
        }
        AITokenBudget.record(model: model, tokens: metered)
    }

    func fetchModels(key: String, session: URLSession) async throws -> [String] {
        var req = URLRequest(url: AIProvider.openAI.modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        return parseModels(try await performRequest(req, session: session))
    }

    /// Pure: unwrap the `/models` body into chat-capable ids (gpt*/o*). No network — unit-tested.
    func parseModels(_ json: [String: Any]) -> [String] {
        guard let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return (id.hasPrefix("gpt") || id.hasPrefix("o")) ? id : nil
        }
    }

    // MARK: Private

    /// `modernParams`: use `max_completion_tokens`, drop `temperature` — required by reasoning models.
    private func chat(
        key: String,
        model: String,
        wire: [[String: Any]],
        modernParams: Bool,
        session: URLSession
    ) async throws -> String {
        var body: [String: Any] = ["model": model, "messages": wire]
        // #1074: 900 truncated detailed coaching replies mid-sentence; 4096 lets a full multi-section
        // reply complete (a cap, not a target — the system prompt keeps it short). Matches Gemini + Android.
        if modernParams {
            body["max_completion_tokens"] = 4096
        } else {
            body["temperature"] = 0.6
            body["max_tokens"] = 4096
        }

        var req = URLRequest(url: provider.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await performRequest(req, session: session)
        // BEFORE the content check. A 200 with no assistant text still spent the prompt, and not
        // counting it would make an empty-reply loop the cheapest-looking thing in the app.
        AITokenBudget.record(model: model, tokens: AITokenBudget.totalTokens(in: json))
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = (message["content"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw emptyReplyError(json)   // #1074: surface the provider's real error if the 200 body has one
        }
        return content
    }
}
