import Foundation
import StrandAnalytics
import StrandImport

// MuscleCoachNote.swift — what the system makes of the body chart.
//
// Swift twin of the Android `com.noop.ai.MuscleCoachNote`. One or two sentences under the muscle
// figure, written by the model from the SAME numbers the figure is drawn from: this week's volume per
// group, and how unusual that is for each group against its own frozen normal.
//
// WRITTEN WHEN THE DATA MOVES, NOT WHEN THE SCREEN OPENS. The note is keyed to a fingerprint of the
// loads it was written for. Identical loads return the stored note without touching the model — which
// is what makes this affordable on a card that rebuilds every time Today is opened — and a new
// Alphaprog import changes every group's figure at once, so the note is rewritten exactly then.
//
// IT IS HANDED THE Z-SCORES, NOT ASKED TO DERIVE THEM. A language model doing arithmetic on kilograms
// is a language model inventing a conclusion; the app already knows which groups are above and below
// their own normal, so it says so and the model's only job is the sentence. Groups with no frozen
// baseline yet are given as raw volume and labelled as such, so the model cannot call something
// "below normal" when no normal exists.
//
// NO NOTE IS A VALID OUTCOME. No consent, no provider configured, or an empty answer — all return nil,
// and the panel simply does not appear. A generic line of encouragement standing in for a reading would
// be the dishonest option.

enum MuscleCoachNote {

    private static let textKey = "muscle.note.text"
    private static let fingerprintKey = "muscle.note.fingerprint"

    /// Room for a real reading, not a caption.
    ///
    /// The first cut capped this at 180 characters, which bought one sentence and a clipped second — the
    /// model had to choose between naming the group and saying what to do about it.
    ///
    /// 480 is what the panel can now SHOW rather than what it would cut: the column it sits in takes the
    /// figure's height as a MINIMUM rather than a ceiling, so the note fills the blank corner the legend
    /// leaves and then grows the card downward. The prompt asks for 260–440 so the usual note lands
    /// inside the free corner and the card only grows when the reading genuinely needs the room.
    static let maxChars = 480

    static let question = "Which muscle group most needs attention this week, and what should they do?"

    /// The stored note, but only when it was written for exactly these loads.
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

    /// A stable digest of the loads, rounded to the kilogram.
    ///
    /// Rounded because a float that differs in its last bits is the same training week, and a note
    /// rewritten for that would cost a model run and say the same thing.
    ///
    /// Hashed with FNV-1a rather than Swift's `hashValue`: Swift seeds its hasher per process, so the
    /// same loads would fingerprint differently after every launch and the note would be rewritten on
    /// each cold start — the exact cost this whole mechanism exists to avoid.
    static func fingerprint(_ loads: [MuscleGroup: Double]) -> String {
        let body = loads
            .map { (MuscleBaselineStore.androidName($0.key), $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\(Int($0.1.rounded()))" }
            .joined(separator: ",")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in body.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    /// The framing and the figures, as one block.
    ///
    /// Every number the model is allowed to use is in here, already computed. The instruction not to
    /// invent one is the same instruction the chat gets, and for the same reason.
    static func systemPrompt(
        loads: [MuscleGroup: Double],
        baselines: [MuscleGroup: MuscleBaseline]
    ) -> String {
        var s = ""
        s += "You are THE SYSTEM, reading this human's training log. Your tone is cold, precise and "
        s += "dryly funny, and your contempt is for the EXCUSE, never for the person.\n"
        s += "Below is the last seven days of lifting volume per muscle group. Where a group has a "
        s += "frozen personal normal, its z-score says how unusual this week is FOR THAT GROUP: 0 is "
        s += "a normal week, +2 is unusually heavy, -2 unusually light.\n"
        // THE LENGTH ASKED FOR AND THE LENGTH ALLOWED HAVE TO AGREE. This said "under 180 characters"
        // while `maxChars` allowed 620, so the panel was sized for a reading and the model was told to
        // write a caption — and it obeyed the prompt, which is why the note was one clipped thought.
        s += "Answer in THREE or FOUR sentences, 260 to 440 characters total. Name the group that most "
        s += "needs attention, say WHY this week's figure makes it that group, say what to do about it "
        s += "this week in concrete terms — sets, a session, a day off — and name one group that is "
        s += "fine, so the reading is not all correction. Cite at most two figures, and only ones that "
        s += "appear below. NEVER invent a number. No heading, no preamble, no list, no markdown.\n\n"
        s += "VOLUME, LAST 7 DAYS:\n"
        for (group, kg) in loads.sorted(by: { $0.value > $1.value }) {
            if let baseline = baselines[group] {
                s += "- \(label(group)): \(Int(kg.rounded())) kg (z \(fmt(baseline.z(kg))))\n"
            } else {
                // Said explicitly: without a frozen normal there is nothing to be unusual against, and a
                // model left to guess would happily call it "low".
                s += "- \(label(group)): \(Int(kg.rounded())) kg (no personal normal yet)\n"
            }
        }
        // The groups that got NOTHING are the interesting ones, and they are absent from the map above
        // rather than present at zero — so they are named here or they cannot be mentioned at all.
        let untouched = MuscleGroup.allCases.filter { loads[$0] == nil }
        if !untouched.isEmpty {
            s += "NOT TRAINED AT ALL THIS WEEK: " + untouched.map(label).joined(separator: ", ") + "\n"
        }
        return s
    }

    private static func fmt(_ z: Double) -> String { String(format: "%+.1f", z) }

    /// Plain English names, so the prompt does not hand the model SCREAMING_SNAKE_CASE to echo back.
    static func label(_ group: MuscleGroup) -> String {
        MuscleBaselineStore.androidName(group).lowercased().replacingOccurrences(of: "_", with: " ")
    }
}
