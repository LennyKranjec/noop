import XCTest
@testable import Strand

/// WHY THIS FILE EXISTS. The wearer asked that the coach also read what they write in the dream journal.
/// The entries are intimate free text, written half-awake, and three things about sending them can go
/// wrong quietly: the date can be read as "today's plan" rather than as the night that ended that
/// morning; the prose can crowd the figures out of a context the model reads once; and it can leave the
/// device on a lane that is not gated on data access. Each of those is pinned below.
@MainActor
final class CoachDreamContextTests: XCTestCase {

    /// 2026-09-29 12:00 local in Berlin (CEST, UTC+2) — a Tuesday. Same instant `CoachDayFrameTests` uses.
    private let noon = Date(timeIntervalSince1970: 1_790_676_000)
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func entry(_ day: String, text: String = "", answers: [String: Int] = [:]) -> DreamEntry {
        DreamEntry(day: day, text: text, answers: answers, updatedAt: Date())
    }

    /// Every one of the seven questions answered, each at its longest option title — the worst case for
    /// the size of a line.
    private var fullAnswers: [String: Int] {
        ["recall": 1, "tone": 1, "rested": 2, "wakings": 0, "wake": 2, "screen": 1, "meal": 2]
    }

    private func block(_ entries: [DreamEntry]) -> String {
        CoachDreamContext.block(entries: entries, now: noon, timeZone: berlin)
    }

    // MARK: - Which night it is about

    /// THE CORE OF THE REPORT'S RISK. An entry dated 2026-09-29 is about the night that ENDED on the
    /// morning of 2026-09-29, and it has to say so on the line — not only in the header — or the model
    /// reads it as something about that day.
    func testEachEntryIsLabelledWithTheNightThatEndedThatMorning() {
        let s = block([entry("2026-09-29", text: "I missed a train.")])
        XCTAssertTrue(s.contains("the morning of Tuesday 2026-09-29 (the night that ENDED then)"), s)
    }

    /// The header says the same thing again, and says the entry is not a plan for its day.
    func testTheHeaderSaysItIsTheNightAndNotThatDaysPlan() {
        XCTAssertTrue(CoachDreamContext.header.contains("NIGHT THAT ENDED"), CoachDreamContext.header)
        XCTAssertTrue(CoachDreamContext.header.lowercased().contains("never a plan"),
                      CoachDreamContext.header)
    }

    /// The day frame, which every figure in the context is read by, carries the rule too — a reader that
    /// loses the block's own header still has it.
    func testTheDayFrameStatesWhichNightADreamBelongsTo() {
        let rules = CoachDayFrame.validityRules
        XCTAssertTrue(rules.contains("dream journal entry"), rules)
        XCTAssertTrue(rules.contains("NIGHT THAT ENDED"), rules)
        XCTAssertTrue(rules.lowercased().contains("never a measurement"), rules)
    }

    /// An unparseable key still gets its date and its night, just without the weekday. Guessing a
    /// weekday would be worse than omitting one.
    func testABadDayKeyKeepsTheDateAndTheNightButNotAWeekday() {
        let s = CoachDreamContext.label("not-a-date", timeZone: berlin)
        XCTAssertEqual(s, "the morning of not-a-date (the night that ENDED then)")
    }

    // MARK: - Ordering and the window

    func testEntriesAreListedNewestFirst() {
        let s = block([entry("2026-09-24", text: "older dream"),
                       entry("2026-09-29", text: "newer dream")])
        guard let newer = s.range(of: "newer dream"), let older = s.range(of: "older dream") else {
            return XCTFail("both entries should be listed: \(s)")
        }
        XCTAssertTrue(newer.lowerBound < older.lowerBound, s)
    }

    /// The window is `windowDays` counted in the LOCAL calendar and includes today: 2026-09-16 is the
    /// fourteenth day back and is in, 2026-09-15 is out.
    func testEntriesOlderThanTheWindowAreDroppedEntirely() {
        let s = block([entry("2026-09-16", text: "just inside the window"),
                       entry("2026-09-15", text: "one day too old"),
                       entry("2026-08-30", text: "last month")])
        XCTAssertTrue(s.contains("just inside the window"), s)
        XCTAssertFalse(s.contains("one day too old"), s)
        XCTAssertFalse(s.contains("last month"), s)
    }

    /// A day key after today is a clock change or a bad write. "The night that ended tomorrow morning"
    /// is nonsense, so the entry is left out rather than labelled wrongly.
    func testAFutureDatedEntryIsLeftOut() {
        let s = block([entry("2026-09-30", text: "tomorrow somehow"),
                       entry("2026-09-29", text: "today's entry")])
        XCTAssertFalse(s.contains("tomorrow somehow"), s)
        XCTAssertTrue(s.contains("today's entry"), s)
    }

    // MARK: - Nothing to say means no block

    /// No heading over an empty list: a header promising "their own words" with nothing under it is an
    /// invitation to invent some.
    func testAnEmptyJournalProducesNoBlockAtAll() {
        XCTAssertEqual(block([]), "")
    }

    func testAnEntryWithNeitherWordsNorTapsIsNotABlock() {
        XCTAssertEqual(block([entry("2026-09-29", text: "   \n ")]), "")
    }

    /// Taps but no words is still worth sending, and says so rather than leaving a dangling colon.
    func testAnswersWithoutWordsAreStillListed() {
        let s = block([entry("2026-09-29", answers: ["tone": 0])])
        XCTAssertTrue(s.contains("Dream tone: Nightmare"), s)
        XCTAssertFalse(s.contains("They wrote"), s)
    }

    /// Words without taps says so, so the model does not read the absence as an answer.
    func testWordsWithoutAnswersSayNoAnswersGiven() {
        let s = block([entry("2026-09-29", text: "A long corridor.")])
        XCTAssertTrue(s.contains("no answers given"), s)
        XCTAssertTrue(s.contains("\"A long corridor.\""), s)
    }

    /// The structured fields travel under the SAME question names the journal and Insights use, so the
    /// coach and the correlation screen are talking about the same thing.
    func testTheAnswersTravelUnderTheirJournalQuestionNames() {
        let s = block([entry("2026-09-29", answers: fullAnswers)])
        for question in DreamQuestions.all {
            XCTAssertTrue(s.contains(question.journalName + ": "), "\(question.journalName) missing: \(s)")
        }
    }

    // MARK: - The caps

    func testALongDreamIsTrimmedAndSaysItWasTrimmed() {
        let long = String(repeating: "a", count: 400) + "THE-TAIL"
        let s = block([entry("2026-09-29", text: long)])
        XCTAssertTrue(s.contains("They wrote (trimmed):"), s)
        XCTAssertFalse(s.contains("THE-TAIL"), s)
        XCTAssertTrue(s.contains(String(repeating: "a", count: CoachDreamContext.maxCharsPerEntry)), s)
        XCTAssertFalse(s.contains(String(repeating: "a", count: CoachDreamContext.maxCharsPerEntry + 1)), s)
    }

    /// A short dream is quoted whole, without the "(trimmed)" claim.
    func testAShortDreamIsNotMarkedTrimmed() {
        let s = block([entry("2026-09-29", text: "Short.")])
        XCTAssertTrue(s.contains("They wrote: \"Short.\""), s)
        XCTAssertFalse(s.contains("(trimmed)"), s)
    }

    /// Over the total text budget the OLDEST entries lose their text first, the count of them is stated,
    /// and their answers still travel. The newest morning — the one a question is most likely about — is
    /// the one that keeps its words.
    func testTheTotalTextBudgetDropsTheOldestTextFirst() {
        // Fourteen mornings, 2026-09-16 … 2026-09-29, each a full per-entry text of a distinct letter.
        let letters = Array("abcdefghijklmn")
        let entries = (0..<14).map { i -> DreamEntry in
            let day = String(format: "2026-09-%02d", 16 + i)
            return entry(day,
                         text: String(repeating: String(letters[i]),
                                      count: CoachDreamContext.maxCharsPerEntry),
                         answers: fullAnswers)
        }
        let s = block(entries)
        // 1200 / 240 = exactly five entries' worth of text, newest first: n, m, l, k, j.
        for kept in ["n", "m", "l", "k", "j"] {
            XCTAssertTrue(s.contains(String(repeating: kept, count: CoachDreamContext.maxCharsPerEntry)),
                          "the text of '\(kept)' should be kept: \(s)")
        }
        for dropped in ["i", "h", "g", "f", "e"] {
            XCTAssertFalse(s.contains(String(repeating: dropped, count: 40)),
                           "the text of '\(dropped)' should be dropped: \(s)")
        }
        // Ten entries are listed, five of them without their text: the note says five, not four or six.
        XCTAssertTrue(s.contains("left out for the 5 oldest"), s)
        // And it tells the model not to read that as "they wrote nothing".
        XCTAssertTrue(s.contains("they wrote nothing"), s)
        // The answers of a text-dropped entry are still there — ten dated lines in all.
        let dated = s.components(separatedBy: "\n").filter { $0.contains("the night that ENDED then") }
        XCTAssertEqual(dated.count, CoachDreamContext.maxEntries, s)
    }

    /// More entries in the window than the cap: the remainder is COUNTED, so the list does not quietly
    /// end and the model does not think it has seen the fortnight.
    func testEntriesBeyondTheCapAreCountedNotSilentlyDropped() {
        let entries = (0..<14).map { i in
            entry(String(format: "2026-09-%02d", 16 + i), answers: ["tone": 2])
        }
        let s = block(entries)
        XCTAssertTrue(s.contains("4 further entries in the last 14 days are not listed."), s)
    }

    /// THE GUARD ON THE TOKEN ESTIMATE. `maxPromptChars` is what `AICoachEngine.estimatedTokens` adds for
    /// this block; the worst case the builder can actually produce has to fit inside it, or the estimate
    /// under-reports and the first the wearer hears of it is a 429.
    func testTheWorstCaseBlockFitsInsideTheStatedCeiling() {
        let entries = (0..<14).map { i -> DreamEntry in
            entry(String(format: "2026-09-%02d", 16 + i),
                  text: String(repeating: "W", count: 4_000),
                  answers: fullAnswers)
        }
        let s = block(entries)
        XCTAssertLessThanOrEqual(s.count, CoachDreamContext.maxPromptChars,
                                 "worst case is \(s.count) chars, ceiling is \(CoachDreamContext.maxPromptChars)")
        XCTAssertGreaterThan(s.count, 0)
    }

    // MARK: - Usable, not just present

    /// One rule, in the register of the other blocks': self-report, never a diagnosis.
    func testTheBlockSaysDreamContentIsSelfReportAndNeverADiagnosis() {
        let s = block([entry("2026-09-29", text: "Falling.")])
        XCTAssertTrue(s.contains("SUBJECTIVE SELF-REPORT"), s)
        XCTAssertTrue(s.lowercased().contains("never turn dream content into a diagnosis"), s)
        XCTAssertTrue(s.lowercased().contains("stress"), s)
        XCTAssertTrue(s.lowercased().contains("sleep quality"), s)
    }

    /// The rule is the LAST thing in the block, where recency makes it stick — the same placement
    /// `CoachDayFrame.closingRule` exists for.
    func testTheRuleIsTheLastThingInTheBlock() {
        let s = block([entry("2026-09-29", text: "Falling.")])
        XCTAssertTrue(s.hasSuffix(CoachDreamContext.instruction), s)
    }

    // MARK: - Consent

    /// NO DREAM TEXT WITHOUT DATA ACCESS. The no-consent branch of `send` builds the no-consent note plus
    /// `sessionConstraints()` — the routines and the memory file — and nothing else. The dream block is
    /// reached only from `CoachExtraContext.block`, itself reached only from `buildFullContext()`, which
    /// is the consent branch. This pins the half a future edit could break: that the lane which goes out
    /// regardless carries none of it.
    func testTheNoConsentLaneCarriesNoDreamText() {
        let defaults = UserDefaults(suiteName: "CoachDreamConsentTests-\(UUID().uuidString)")!
        var routines = CoachRoutineSet()
        routines.wake = 7 * 60
        CoachRoutines.write(routines, defaults)

        let lane = AICoachEngine.sessionConstraints(defaults)
        // The routines DO ride it — this is the lane, not an empty string.
        XCTAssertTrue(lane.contains("Wakes at 07:00"), lane)
        // The dream block does not.
        XCTAssertFalse(lane.contains(CoachDreamContext.header), lane)
        XCTAssertFalse(lane.contains(CoachDreamContext.instruction), lane)
        XCTAssertFalse(lane.contains("the night that ENDED then"), lane)
        for question in DreamQuestions.all {
            XCTAssertFalse(lane.contains(question.journalName + ": "), lane)
        }
    }
}
