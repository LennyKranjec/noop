import Foundation
import StrandAnalytics

// CustomTaskWriter.swift — the coach turning the wearer's sentence into a task.
//
// Same request path as every other headless generation (`AICoachEngine.generateOneShot`), so the
// provider, the model, the clock-and-weather block and the rate limits are the chat's own. The context
// is the NON-biometric half the chat always carries — routines and memory (`sessionConstraints`) — plus
// the list of what is already on today's strip, so "another one like this morning's" means something.
// No metrics are sent, which is why this runs without the data-consent toggle, exactly as the chat does.
//
// The answer is strict JSON (`CustomTaskParser.responseFormat`); the parse is tolerant and the fallback
// is the wearer's own words, so tapping send always produces a task to preview.

@MainActor
enum CustomTaskWriter {

    /// A draft for `request`. Never nil: no provider, no network or an unreadable answer all fall back.
    static func draft(for request: String, coach: AICoachEngine,
                      now: Date = Date()) async -> CustomTaskDraft {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = await coach.generateOneShot(
            systemPrompt: systemPrompt(onStrip: QuestStore.shared.active),
            question: "The wearer asks: \(trimmed)",
            requiresDataConsent: false)
        return CustomTaskParser.resolve(
            // Not truncated: a reasoning model writes its JSON LAST, and every field is capped by the
            // parser anyway.
            answer: answer,
            userText: trimmed,
            now: now)
    }

    static func systemPrompt(onStrip: [Quest], _ defaults: UserDefaults = .standard) -> String {
        var s = ""
        s += "You are the wearer's coach. They describe a task they want on today's list; you turn it "
        s += "into ONE clear, doable task. Write the title and detail in the SAME language they wrote in. "
        s += "Plain and friendly, no taunts, no medical claims.\n\n"
        s += CustomTaskParser.responseFormat + "\n\n"
        s += "Rules:\n"
        s += "- \"metric\" only when the task IS one of those measured quantities (steps walked, minutes "
        s += "of logged training, minutes of meditation or breathing, water drunk, WHOOP day strain 0-21, "
        s += "hours of sleep tonight, asleep by a time, asleep N minutes earlier, a journal entry). "
        s += "Anything else — stretching, a reminder, a chore, a meal — has metric null and target null; "
        s += "the wearer ticks it off themselves.\n"
        s += "- \"target\" is the wearer's own number. Never invent one: no number given means null. "
        s += "WATER_ML is in millilitres, BEDTIME_BY is \"HH:MM\".\n"
        s += "- \"due\" only when they name a time or a moment (\"after lunch\", \"before 18:00\", "
        s += "\"tonight\"): the local 24h time it should be done by, using the current time and their "
        s += "routines below. Otherwise null.\n"
        s += "- Never mock them. If the request involves pain, injury or illness, keep it plain."
        let open = onStrip.prefix(8).map { "- \($0.title): \($0.target)" }
        if !open.isEmpty {
            s += "\n\nAlready on today's list:\n" + open.joined(separator: "\n")
        }
        let constraints = AICoachEngine.sessionConstraints(defaults)
        if !constraints.isEmpty { s += "\n\n" + constraints }
        return s
    }
}
