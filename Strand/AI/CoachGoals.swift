import Foundation

// CoachGoals.swift — what the wearer is actually training for.
//
// Swift twin of the Android `com.noop.ai.CoachGoals`. Free text, written by the wearer, handed to the
// coach as context on every session. Not a structured goal model with a target, a deadline and a
// progress bar: the things people actually want are sentences ("get back under 20 min for 5k without
// wrecking my sleep", "stop skipping legs"), and a schema would have forced those into fields that
// lose the point.
//
// It is also the only place the coach learns anything the numbers cannot tell it. Charge, effort and
// sleep say how the body is; the goal says what it is FOR, and advice without it is generic by
// construction. The daily mission is generated from this plus the day's metrics, which is why a blank
// goal produces a noticeably blander mission.

enum CoachGoals {

    /// Same defaults key as the Android lane, so an exported settings blob reads the same on both.
    static let key = "coach.goals"

    /// Bounded because it rides in the system prompt, and every character there is prompt-processing
    /// time — on a local server, the kind the wearer waits through.
    static let maxChars = 600

    static func read(_ d: UserDefaults = .standard) -> String {
        (d.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ text: String, _ d: UserDefaults = .standard) {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
        if clean.isEmpty { d.removeObject(forKey: key) } else { d.set(clean, forKey: key) }
    }

    /// The goal block for the system prompt, or nil when nothing is set.
    ///
    /// Nil rather than a placeholder: "the user has not set a goal" is a sentence the model would then
    /// coach about, and the absence of a goal is not a thing to be coached about.
    static func promptSection(_ d: UserDefaults = .standard) -> String? {
        let goals = read(d)
        guard !goals.isEmpty else { return nil }
        return "THEIR GOALS, in their own words — everything you advise should serve these:\n\(goals)"
    }
}
