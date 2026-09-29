import Foundation

// CoachDreamContext.swift — the night in the wearer's own words, for the coach.
//
// WHAT IT IS. Every morning's first open asks for the dream while it is still there, then seven
// four-option questions about the night (`DreamJournal.swift`). The answers were already mirrored into
// the journal as numbers; the wearer's own TEXT was on screen and, in the coach context, sat in a single
// unlabelled line in FRONT of every figure the coach reasons from. This is that block, done properly:
// after the numbers, dated, capped, and labelled with the night it describes.
//
// A DREAM BELONGS TO THE NIGHT, NOT TO THE DAY. `DreamEntry.day` is the WAKE day — the morning it was
// written on — so the entry is about the night that ENDED that morning, exactly like rest, sleep stages
// and night HRV (`CoachDayFrame.validityRules`). Unlabelled, "2026-09-29: I dreamt I missed a train"
// reads as a fact about that day, and a model asked what to do today answers with the train.
//
// ONLY WITH DATA ACCESS. Reached from `CoachExtraContext.block` alone, which is reached from
// `AICoachEngine.buildFullContext()` alone — the branch taken only when `dataConsent` is on. The
// no-consent branch sends the no-consent note plus `sessionConstraints()` (the routines and the memory
// file), and neither of those is ever written from a dream entry. With data access off, not one
// character of dream text leaves the device.
//
// NOT A MEASUREMENT. This is free text a person typed half-awake. It may be about their sleep, their
// stress or whatever they are working through, and on its own it is evidence of none of them — so the
// block says exactly that, in one line, where the model reads it.
//
// PURE. `entries`, `now` and the time zone are arguments, so every limit below is testable without a
// store and without a clock.

@MainActor
enum CoachDreamContext {

    /// How far back to read. Two weeks covers "lately" and "this week" without dragging last month into
    /// a context the model reads once; older entries are dropped entirely rather than trimmed.
    static let windowDays = 14

    /// The most entries listed, newest first. A wearer who writes every morning has fourteen in the
    /// window, and fourteen paragraphs of prose is the crowding-out this block is placed last to avoid.
    /// The remainder is COUNTED rather than the list quietly ending.
    static let maxEntries = 10

    /// Characters of one dream kept. Around 240 is two or three sentences — the shape of the night,
    /// not the whole retelling. A trimmed entry SAYS it was trimmed, so a cut-off sentence is not read
    /// as the end of the account.
    static let maxCharsPerEntry = 240

    /// Characters of dream TEXT across the whole block. The figures above it are the reason the coach
    /// can say anything useful at all; when the prose would exceed this, the OLDEST entries lose their
    /// text first (their answers, which are cheap and structured, still travel).
    static let maxCharsTotal = 1_200

    /// The most this block can add to one request, in characters: its two fixed paragraphs, the whole
    /// text budget, and 400 characters per listed entry for the date label, the seven answers at their
    /// longest, the quoting and the two "not listed" notes. `AICoachEngine.estimatedTokens` counts this
    /// so the draft estimate does not under-report by a whole block.
    ///
    /// A CEILING, and `CoachDreamContextTests` builds the worst case and asserts the real block fits
    /// inside it — an under-reporting estimate is the failure that only shows up as a 429.
    static var maxPromptChars: Int {
        header.count + instruction.count + maxCharsTotal + maxEntries * 400
    }

    /// What the rows are, and — the part that was missing — which night each one is about.
    static let header = """
    THEIR DREAM JOURNAL AND THE MORNING'S ANSWERS ABOUT THE NIGHT (their own words and taps, newest \
    first). Each entry was written on the MORNING it is dated with, and it is about THE NIGHT THAT \
    ENDED that morning. It is never a plan for that day, and never about today unless today is the \
    date on the line.
    """

    /// What the model is told to do with it. One rule, in the register of the other blocks'.
    static let instruction = """
    A dream and these answers are SUBJECTIVE SELF-REPORT, not a measurement. They may relate to sleep \
    quality, to stress, or to whatever the wearer is working through, and on their own they establish \
    none of it. Never turn dream content into a diagnosis, never name a condition or a disorder from \
    it, and never state it as a cause — refer to a dream only as their own account of the night, and \
    let the measured figures carry any claim about how they slept.
    """

    /// "the morning of Tuesday 2026-09-29 (the night that ENDED then)".
    ///
    /// The weekday is ENGLISH whatever the device language, like every other line the model reads, and
    /// is simply left off when the key cannot be parsed rather than guessed at.
    static func label(_ day: String, timeZone: TimeZone = .current) -> String {
        let named = date(fromKey: day, timeZone: timeZone)
            .map { "\(CoachDayFrame.weekday($0, timeZone: timeZone)) \(day)" } ?? day
        return "the morning of \(named) (the night that ENDED then)"
    }

    /// The block, or "" when there is nothing in the window worth a line.
    ///
    /// EMPTY MEANS NO BLOCK, never a heading with nothing under it: a header that says "their own words"
    /// above an empty list is an invitation to invent some.
    static func block(entries: [DreamEntry], now: Date = Date(), timeZone: TimeZone = .current) -> String {
        // Day arithmetic in the LOCAL calendar, not by adding 86,400 s: a DST boundary makes a day 23 or
        // 25 hours long, and on those two mornings a seconds-offset window is a day out.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let today = CoachDayFrame.key(now, timeZone: timeZone)
        let first = cal.date(byAdding: .day, value: -(windowDays - 1), to: now) ?? now
        let floor = CoachDayFrame.key(first, timeZone: timeZone)

        // A day key later than today is a clock change or a bad write, and "the night that ended
        // tomorrow morning" is nonsense — it is left out rather than labelled wrongly.
        let recent = entries
            .filter { $0.day >= floor && $0.day <= today && hasSomething($0) }
            .sorted { $0.day > $1.day }
        guard !recent.isEmpty else { return "" }

        var lines = [header]
        let listed = Array(recent.prefix(maxEntries))
        var spentChars = 0
        var budgetExhausted = false
        var textOmitted = 0

        for entry in listed {
            var line = "  " + label(entry.day, timeZone: timeZone) + ": "
            let answers = DreamJournalStore.summary(entry)
            line += answers.isEmpty ? "no answers given" : answers.joined(separator: "; ")
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let kept = String(text.prefix(maxCharsPerEntry))
                // ONCE THE BUDGET IS GONE IT STAYS GONE, so the count below is truthfully "the N
                // oldest". Letting a later short entry slip back in would make that sentence a lie.
                if budgetExhausted || spentChars + kept.count > maxCharsTotal {
                    budgetExhausted = true
                    textOmitted += 1
                } else {
                    spentChars += kept.count
                    line += kept.count < text.count
                        ? ". They wrote (trimmed): \"\(kept)…\""
                        : ". They wrote: \"\(kept)\""
                }
            }
            lines.append(line)
        }

        if recent.count > listed.count {
            lines.append("  (\(recent.count - listed.count) further entries in the last \(windowDays) "
                         + "days are not listed.)")
        }
        if textOmitted > 0 {
            lines.append("  (The written dream is left out for the \(textOmitted) oldest of these, to "
                         + "keep the figures above in view — their answers are all there. Do not treat "
                         + "that as \"they wrote nothing\".)")
        }
        lines.append(instruction)
        return lines.joined(separator: "\n")
    }

    /// An entry with neither words nor a single tap has nothing to tell the coach.
    private static func hasSomething(_ entry: DreamEntry) -> Bool {
        !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !DreamJournalStore.summary(entry).isEmpty
    }

    /// "yyyy-MM-dd" back to the noon of that local day — noon, so no time zone's DST shift can move it
    /// onto the day before.
    private static func date(fromKey day: String, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let midnight = f.date(from: day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(byAdding: .hour, value: 12, to: midnight) ?? midnight
    }
}
