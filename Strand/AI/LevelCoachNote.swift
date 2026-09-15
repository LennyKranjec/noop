import Foundation
import StrandAnalytics

// LevelCoachNote.swift — what the system makes of the level.
//
// Swift twin of the Android `com.noop.ai.LevelCoachNote`. One line at the head of the level panel,
// written from the SAME breakdown the radar is drawn from: each of the five parts, what it scored, and
// what it is actually worth to the number in the middle.
//
// IT COMMENTS ON THE WEIGHTING, which is the thing the radar cannot say on its own. A pentagon leaning
// toward sleep and muscle looks the same whether those two are carrying the level or merely happen to
// be the two that were measured; "strong sleep and training volume, but your lungs are giving back four
// points" is the sentence a shape cannot make.
//
// REWRITTEN WHEN THE LEVEL MOVES, and at most once a day. The note is keyed to a fingerprint of the day
// and the rounded figures, so a level that has not changed returns the stored line without touching the
// model — and a new day, or a new level, writes a new one. That is what the wearer asked for: a fresh
// comment with each new level.
//
// IT IS HANDED THE ARITHMETIC, NOT ASKED TO DO IT. Contribution and headroom are computed by the engine,
// in points of final level, and the model's only job is the sentence. A language model multiplying
// scores by weights is a language model inventing a conclusion.

enum LevelCoachNote {

    private static let textKey = "level.note.text"
    private static let fingerprintKey = "level.note.fingerprint"

    /// Two sentences at the head of a panel. Longer and it competes with the chart under it.
    static let maxChars = 240

    static let question = "Comment on how my metrics are carrying my level right now."

    /// The stored line, but only when it was written for exactly this level on this day.
    static func stored(fingerprint: String, _ d: UserDefaults = .standard) -> String? {
        guard d.string(forKey: fingerprintKey) == fingerprint,
              let text = d.string(forKey: textKey),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    static func write(_ text: String, fingerprint: String, _ d: UserDefaults = .standard) {
        d.set(text, forKey: textKey)
        d.set(fingerprint, forKey: fingerprintKey)
    }

    /// The day, the level, and each part's score, rounded.
    ///
    /// Rounded because a level that moved by a hundredth is the same level, and rewriting the line for
    /// that would cost a model run to say the same thing. The DAY is in the key so the note is refreshed
    /// each morning even on a body that has not moved — which is the "daily" the wearer asked for.
    static func fingerprint(_ breakdown: LevelBreakdown, today: String = DailyMissionStore.dayKey()) -> String {
        let parts = LevelPart.allCases.map { part -> String in
            let score = breakdown.components.first { $0.part == part }?.score
            return "\(part.rawValue.uppercased()):\(score.map { Int($0.rounded()) } ?? -1)"
        }.joined(separator: ",")
        return "\(today)|\(Int(breakdown.level.rounded()))|\(parts)"
    }

    /// The framing and the figures.
    ///
    /// Every number the model may use is here and already computed: the part's own 0–100 score, the
    /// POINTS OF LEVEL it currently contributes, and the points still on the table. Those last two are
    /// what "weighting" means — sleep at 0.30 and lungs at 0.07 are not comparable as scores, and a
    /// model shown only the scores would praise a lungs figure that is worth almost nothing.
    static func systemPrompt(_ breakdown: LevelBreakdown) -> String {
        var s = ""
        s += "You are THE SYSTEM, reading this human's level. Cold, precise, dryly funny; your contempt "
        s += "is for the EXCUSE and never for the person.\n"
        s += "Their LEVEL is \(Int(breakdown.level.rounded())) out of 100. It is a weighted blend of five "
        s += "parts. For each, below: its own score out of 100, the POINTS OF LEVEL it currently "
        s += "contributes, and the points it would add if it were perfect.\n"
        s += "Write ONE or TWO sentences, under 220 characters. Name the one or two parts CARRYING the "
        s += "level and the one costing it most, in that order, in the shape \"strong X and Y, "
        s += "but Z...\". Judge by POINTS, never by the bare score — a part with a small weight "
        s += "cannot carry anything. Cite at most two figures, and only ones below. NEVER invent a "
        s += "number. No heading, no preamble, no list, no markdown.\n\n"
        s += "THE FIVE PARTS:\n"
        for c in breakdown.components.sorted(by: { $0.contribution > $1.contribution }) {
            let name = label(c.part)
            if let score = c.score {
                s += "- \(name): scores \(Int(score.rounded()))/100, "
                s += String(format: "contributes %.1f points, %.1f points still available\n",
                            c.contribution, c.headroom)
            } else {
                // Said out loud: an unmeasured part is not a weak one, and a model left to infer would
                // call it weak. Its weight was redistributed over the parts that did score.
                s += "- \(name): not measured (excluded, its weight went to the others)\n"
            }
        }
        if breakdown.stepPenalty < 1 {
            s += String(format: "STEP PENALTY: %.1f points lost for a day under the step floor.\n",
                        breakdown.raw - breakdown.level)
        }
        return s
    }

    static func label(_ part: LevelPart) -> String {
        switch part {
        case .sleep: return "sleep"
        case .heart: return "heart"
        case .lungs: return "lungs"
        case .muscle: return "training volume"
        case .focus: return "focus"
        }
    }
}
