import Foundation

// QuestNaming.swift — reading a quest's name and taunt back out of a model's answer.
//
// Pure + deterministic so it is unit-testable without a model or an app target, and so it behaves
// identically to the Android twin `com.noop.ai.QuestGenerator` (the cross-platform parity contract).
//
// The trigger already decided there is a problem and what the directive is. The model is asked for the
// two parts that should never be the same twice: a TITLE and a TAUNT.
//
// WHY THOSE TWO AND NOTHING ELSE. A generated target is a fabricated number, and a generated trigger is
// a model inventing a reason to nag. Both are things this app does not do. A generated NAME costs
// nothing if it is silly, and it is the difference between "Step goal" and something the wearer
// actually looks at. Everything below is written so a model that ignores the format entirely still
// leaves a usable quest: the target and the XP were never its to decide.

public enum QuestNaming {

    /// Titles longer than this are a model rambling, not a name.
    public static let maxTitleChars = 42

    /// The taunt is typed out letter by letter with a haptic per letter, so length is felt, not read.
    public static let maxTauntChars = 180

    /// The two lines a naming consists of.
    public struct Written: Equatable, Sendable {
        public let title: String
        public let taunt: String

        public init(title: String, taunt: String) {
            self.title = title
            self.taunt = taunt
        }
    }

    /// Read the naming out of `answer`, or nil when it was not a naming at all.
    ///
    /// Tolerant on purpose. A missing TAUNT is survivable — the caller has a written fallback — but a
    /// missing TITLE means the answer was something else entirely, so the whole thing is discarded.
    /// Better a stock name than a stray sentence used as a quest title.
    public static func parse(_ answer: String) -> Written? {
        let lines = answer
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let title = lines.lazy.compactMap({ capture($0, label: "title") }).first,
              !title.isEmpty
        else { return nil }

        let taunt = lines.lazy.compactMap { capture($0, label: "taunt") }.first ?? ""
        return Written(title: String(title.prefix(maxTitleChars)),
                       taunt: String(taunt.prefix(maxTauntChars)))
    }

    /// Pull `LABEL: value` off one line, tolerating Markdown around either half.
    ///
    /// The asterisks may sit on EITHER side of the colon: a model told to write "TITLE:" and also told
    /// to use Markdown produces `**TITLE:** x` about as often as `**TITLE**: x`, and a parser that only
    /// allows one of the two silently loses half the answers. Written by hand rather than with
    /// NSRegularExpression so it behaves the same on Linux, where the ICU regex engine differs.
    private static func capture(_ line: String, label: String) -> String? {
        var rest = Substring(line)
        rest = strip(rest, of: "*")
        guard rest.lowercased().hasPrefix(label) else { return nil }
        rest = rest.dropFirst(label.count)
        rest = strip(rest, of: "*")
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()
        return clean(String(rest))
    }

    /// Drop leading whitespace and any run of `character`.
    private static func strip(_ text: Substring, of character: Character) -> Substring {
        var out = text.drop { $0.isWhitespace }
        out = out.drop { $0 == character }
        return out.drop { $0.isWhitespace }
    }

    /// Trim the wrapping a model puts around a value it was told not to wrap.
    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t*\"\u{201C}\u{201D}"))
    }

    /// Which body systems a directive plausibly touches, read off the words in it.
    ///
    /// Used for the DAILY quest, whose directive is free text from the mission writer; a side quest's
    /// rewards come from its trigger, which knows exactly what it asked for. Coarse keyword matching,
    /// and deliberately so — the alternative is asking the model, which would let it claim a
    /// physiological effect, and this app does not do that.
    ///
    /// Matched in a fixed order so the returned list is identical to the Kotlin twin's, which builds a
    /// `LinkedHashSet` in the same sequence. Both English and German stems, because the directive is
    /// written in the wearer's own language.
    public static func rewards(forDirective text: String) -> [QuestReward] {
        let t = text.lowercased()
        var out: [QuestReward] = []

        func addIfAny(_ needles: [String], _ rewards: [QuestReward]) {
            guard needles.contains(where: t.contains) else { return }
            for reward in rewards where !out.contains(reward) { out.append(reward) }
        }

        addIfAny(["sleep", "bed", "nap", "lights out", "schlaf"], [.sleep])
        addIfAny(["breath", "meditat", "calm", "mindful", "atem"], [.brain, .stress])
        addIfAny(["run", "walk", "steps", "zone 2", "cardio", "cycle", "swim", "row"], [.heart, .lungs])
        addIfAny(["lift", "strength", "squat", "press", "mobility", "stretch", "dehn"], [.muscle])

        // A directive that matches nothing still improves something, and an empty reward row reads as a
        // bug rather than as modesty.
        return out.isEmpty ? [.heart] : out
    }

    // MARK: - Fallbacks
    //
    // Used when the model could not be reached at all — not installed, busy with the wearer's own
    // conversation, out of budget. A system that stays silent because its writer was busy is a system
    // that misses the day it was needed, so the quest still goes out under a written name.

    public static func fallbackTitle(triggerId: String) -> String {
        switch triggerId {
        case "overreach": return "Enforced Downtime"
        case "short-sleep": return "Debt Collection"
        case "sedentary": return "Proof of Life"
        case "idle-streak": return "Cold Start"
        case "hrv-dip": return "System Reset"
        case "daily": return "Today's Directive"
        default: return "Directive"
        }
    }

    public static func fallbackTaunt(triggerId: String) -> String {
        switch triggerId {
        case "overreach": return "You trained like the data was someone else's. It is not."
        case "short-sleep": return "The night was short. The consequences will not be."
        case "sedentary": return "The step counter checked twice. It stands by its findings."
        case "idle-streak": return "Four days. Your heart rate has forgotten what you look like."
        case "hrv-dip": return "Your nervous system filed a complaint. This is the response."
        default: return "The numbers spoke. This is what they said."
        }
    }
}
