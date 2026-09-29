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

    static let question = "Which muscle group is most undertrained relative to their own recent weeks, and what should they do in their next session?"

    /// How many groups must have a frozen personal normal before the reading is a comparison rather than a
    /// guess. Below this the note says so instead of ranking two numbers against nothing.
    static let minBaselinesForVerdict = 3

    /// How many weekly figures the whole chart needs before the note is written at all. One week of volume
    /// on two groups is not a training history, and a confident paragraph about it is a fabrication.
    static let minGroupsForNote = 2

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
    static func fingerprint(_ loads: [MuscleGroup: Double],
                            priorWeek: [MuscleGroup: Double] = [:],
                            window: String = "") -> String {
        func digest(_ m: [MuscleGroup: Double]) -> String {
            m.map { (MuscleBaselineStore.androidName($0.key), $0.value) }
                .sorted { $0.0 < $1.0 }
                .map { "\($0.0):\(Int($0.1.rounded()))" }
                .joined(separator: ",")
        }
        // The WINDOW is part of the identity too: the note names its dates, so the same kilograms read over
        // a window that has since slid forward is a note whose first clause is wrong.
        let body = digest(loads) + "|" + digest(priorWeek) + "|" + window
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
        baselines: [MuscleGroup: MuscleBaseline],
        from: String? = nil,
        to: String? = nil,
        priorWeek: [MuscleGroup: Double] = [:]
    ) -> String {
        // THE WINDOW, NAMED. Without its dates the table was a set of timeless kilograms, and the note
        // said "this week" about a figure the reader could not place — the same undated-figure defect the
        // chat context had.
        let window: String
        if let from, let to {
            window = "\(from) to \(to) inclusive (7 local days, ending today)"
        } else {
            window = "the last 7 local days, ending today"
        }
        let withBaseline = loads.keys.filter { baselines[$0] != nil }.count
        let thin = withBaseline < minBaselinesForVerdict

        var s = ""
        s += "You are THE SYSTEM, reading this human's training log. Your tone is cold, precise and "
        s += "dryly funny, and your contempt is for the EXCUSE, never for the person.\n"
        s += "Below is their lifting volume per muscle group for \(window). Volume is TOTAL KILOGRAMS "
        s += "MOVED in that window (sets x reps x weight), not a weight on a bar. Where a group has a "
        s += "frozen personal normal, its z-score says how unusual this window is FOR THAT GROUP against "
        s += "that group's own history: 0 is a normal week for them, +2 unusually heavy, -2 unusually "
        s += "light. The previous 7 days are given beside it where known, so a direction is visible.\n"
        // THE LENGTH ASKED FOR AND THE LENGTH ALLOWED HAVE TO AGREE. This said "under 180 characters"
        // while `maxChars` allowed 620, so the panel was sized for a reading and the model was told to
        // write a caption — and it obeyed the prompt, which is why the note was one clipped thought.
        s += "Answer in THREE or FOUR sentences, 260 to 440 characters total. "
        if thin {
            // THIN DATA GETS AN HONEST NOTE, NOT A VERDICT. With fewer than a few frozen normals there is
            // nothing to be undertrained RELATIVE TO, and a confident ranking of two raw numbers is the
            // fabrication this app's rules forbid. So the instruction changes shape rather than the model
            // being left to bluff.
            s += "IMPORTANT: only \(withBaseline) of their groups has a personal normal yet, so you CANNOT "
            s += "say which group is undertrained relative to their own history — there is not enough "
            s += "history. Say that plainly in the first sentence. Then state what the log DOES show (which "
            s += "groups were trained at all in this window and which were not), and name the one concrete "
            s += "thing that would make the next reading possible: train the untrained groups so a normal "
            s += "can be established. Do NOT rank groups, do NOT call anything low or weak, and do NOT "
            s += "estimate a normal. "
        } else {
            s += "Name the group that is most UNDERTRAINED relative to their own recent weeks — the most "
            s += "negative z-score, or a group with real history that got nothing in this window. Say WHY "
            s += "that group's own figures make it that group. Then say exactly what to do in their NEXT "
            s += "SESSION in concrete terms: which group, how many working sets, and roughly what share of "
            s += "their usual load. Finally name one group that is genuinely fine, so the reading is not all "
            s += "correction. "
        }
        s += "A group marked \"no personal normal yet\" has no history to compare against: it is NOT low and "
        s += "NOT weak, and you must never describe it as either. Cite at most two figures, and only ones "
        s += "that appear below. NEVER invent a number. No heading, no preamble, no list, no markdown.\n\n"
        s += "VOLUME (total kg moved) FOR \(window.uppercased()):\n"
        for (group, kg) in loads.sorted(by: { $0.value > $1.value }) {
            var line = "- \(label(group)): \(Int(kg.rounded())) kg"
            if let baseline = baselines[group] {
                line += " (z \(fmt(baseline.z(kg))) vs their own normal)"
            } else {
                // Said explicitly: without a frozen normal there is nothing to be unusual against, and a
                // model left to guess would happily call it "low".
                line += " (no personal normal yet — not comparable, so never call it low)"
            }
            if let before = priorWeek[group] {
                line += ", previous 7 days \(Int(before.rounded())) kg"
            }
            s += line + "\n"
        }
        // The groups that got NOTHING are the interesting ones, and they are absent from the map above
        // rather than present at zero — so they are named here or they cannot be mentioned at all.
        let untouched = MuscleGroup.allCases.filter { loads[$0] == nil }
        if !untouched.isEmpty {
            s += "NOT TRAINED AT ALL IN THIS WINDOW (0 kg logged; a group with a personal normal and 0 kg is "
            s += "genuinely undertrained, a group without one is simply unknown): "
            s += untouched.map { g in
                baselines[g] != nil ? "\(label(g)) (has a normal)" : "\(label(g)) (no normal yet)"
            }.joined(separator: ", ") + "\n"
        }
        return s
    }

    private static func fmt(_ z: Double) -> String { String(format: "%+.1f", z) }

    /// Plain English names, so the prompt does not hand the model SCREAMING_SNAKE_CASE to echo back.
    static func label(_ group: MuscleGroup) -> String {
        MuscleBaselineStore.androidName(group).lowercased().replacingOccurrences(of: "_", with: " ")
    }
}
