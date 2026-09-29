import XCTest
@testable import Strand

/// The arithmetic that stops a coach request being refused for its size.
///
/// THE BUG THESE PIN. One State-tile refresh asked a Groq on-demand key for 8,646 tokens against a limit of
/// 8,000 PER MINUTE, and was refused with a 413. Nothing in the app counted the size of a request, so nothing
/// could notice. These cover the counting, the order things are given up in, the line that says something was
/// given up, and the reading of the provider's own statement of the limit.
final class CoachContextBudgetTests: XCTestCase {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CoachContextBudgetTests-\(UUID().uuidString)")!
    }

    /// `chars` characters, so a block's cost in tokens is exactly `chars / 4`.
    private func block(_ name: String, _ value: Int, chars: Int, shortChars: Int? = nil) -> CoachContextBlock {
        CoachContextBlock(name: name, value: value,
                          full: String(repeating: "x", count: chars),
                          short: shortChars.map { String(repeating: "y", count: $0) })
    }

    // MARK: - The yardstick

    /// Four characters per token, the estimate this app already used — and ROUNDED UP, because a budget that
    /// rounds down is a budget that is occasionally exceeded.
    func testTheEstimateIsFourCharactersPerTokenRoundedUp() {
        XCTAssertEqual(CoachTokens.estimate(""), 0)
        XCTAssertEqual(CoachTokens.estimate("abcd"), 1)
        XCTAssertEqual(CoachTokens.estimate("abcde"), 2)
        XCTAssertEqual(CoachTokens.estimate(String(repeating: "x", count: 4_000)), 1_000)
    }

    // MARK: - Fitting

    /// Everything fits: nothing is shortened, nothing is dropped, and no note is added.
    func testAContextThatFitsIsSentWholeAndSaysNothingAboutTrimming() {
        let fit = CoachContextBudget.fit([block("a", 90, chars: 400), block("b", 50, chars: 400)],
                                         budget: 2_000, reserved: 100)
        XCTAssertTrue(fit.isComplete)
        XCTAssertTrue(fit.dropped.isEmpty)
        XCTAssertTrue(fit.shortened.isEmpty)
        XCTAssertFalse(fit.text.contains("CONTEXT TRIMMED"))
        XCTAssertTrue(fit.text.contains(String(repeating: "x", count: 400)))
    }

    /// THE RESERVE COUNTS. The same blocks and the same budget fit or do not fit depending on what ELSE the
    /// request carries — which is the whole correction: the provider meters the request, not the grounding.
    func testTheReserveIsSubtractedFromTheBudgetBeforeAnythingIsAssembled() {
        let blocks = [block("keep", 90, chars: 2_000), block("lose", 10, chars: 2_000)]
        let roomy = CoachContextBudget.fit(blocks, budget: 1_400, reserved: 0)
        // 1,400 − 790 reserved − 105 held back for the trim note (420 chars / 4) = 505 tokens: room for
        // exactly one 500-token block. The note's own room is part of the arithmetic — that is the point.
        let cramped = CoachContextBudget.fit(blocks, budget: 1_400, reserved: 790)
        XCTAssertTrue(roomy.isComplete, "1,000 tokens of blocks inside a 1,400 budget should fit")
        XCTAssertEqual(cramped.dropped, ["lose"], "with 790 reserved (and the note's room) there is room for one block")
        let tooCramped = CoachContextBudget.fit(blocks, budget: 1_400, reserved: 900)
        XCTAssertEqual(Set(tooCramped.dropped), ["keep", "lose"], "900 reserved leaves 395 — not even one block")
    }

    /// CHEAPEST VALUE FIRST, and a block with a short form is SHORTENED before a block without one is lost.
    func testBlocksAreSummarisedBeforeAnyAreDroppedAndCheapestValueGoesFirst() {
        let blocks = [
            block("today", 100, chars: 1_200),
            block("history", 70, chars: 1_200, shortChars: 200),
            block("memory", 30, chars: 1_200, shortChars: 200),
        ]
        // 1,200 tokens of blocks; a budget that leaves room for roughly 800.
        let fit = CoachContextBudget.fit(blocks, budget: 900, reserved: 0)
        XCTAssertEqual(fit.shortened, ["memory"], "the least valuable summarisable block goes first")
        XCTAssertTrue(fit.dropped.isEmpty, "nothing needed dropping once one block was shortened")
        XCTAssertTrue(fit.text.contains(String(repeating: "x", count: 1_200)), "the top block is untouched")
    }

    /// When summarising is not enough, blocks are DROPPED, still cheapest-value-first, and the most valuable
    /// one survives.
    ///
    /// The invariant asserted is the one that matters: nothing is dropped while something cheaper is still
    /// being sent. (The NOTE lists losses dearest-first, because that is the order a reader cares about;
    /// the ORDER THINGS ARE GIVEN UP IN is the opposite, and it is what this pins.)
    func testWhenSummarisingIsNotEnoughTheCheapestBlocksAreDroppedAndTheDearestSurvives() {
        let values = ["today": 100, "schedule": 95, "history": 70, "routines": 50, "memory": 30]
        let blocks = [
            block("today", 100, chars: 800),
            block("schedule", 95, chars: 800),
            block("history", 70, chars: 800, shortChars: 40),
            block("routines", 50, chars: 800),
            block("memory", 30, chars: 800),
        ]
        let fit = CoachContextBudget.fit(blocks, budget: 500, reserved: 0)
        XCTAssertTrue(fit.dropped.contains("memory"), "the least valuable block is the first one lost")
        XCTAssertTrue(fit.dropped.contains("routines"))
        XCTAssertFalse(fit.dropped.contains("today"), "the block the request is about is the last to go")
        // No survivor is cheaper than anything that was dropped.
        let keptFloor = blocks.filter { !fit.dropped.contains($0.name) }.map { values[$0.name]! }.min() ?? 0
        let droppedCeiling = fit.dropped.map { values[$0]! }.max() ?? 0
        XCTAssertGreaterThan(keptFloor, droppedCeiling,
                             "kept \(keptFloor) while dropping \(droppedCeiling) — out of value order")
        XCTAssertLessThanOrEqual(CoachTokens.estimate(fit.text), 500)
    }

    /// And the ONE thing given up when only one has to be is the cheapest, not whatever came last.
    func testExactlyOneBlockOverBudgetLosesTheCheapestOne() {
        let fit = CoachContextBudget.fit([
            block("dear", 100, chars: 800),
            block("cheap", 10, chars: 800),
            block("middling", 50, chars: 800),
        ], budget: 600, reserved: 0)
        XCTAssertEqual(fit.dropped, ["cheap"])
    }

    /// READING ORDER IS DECLARATION ORDER, not value order. The prompts were written for a particular order —
    /// which day it is, then the figures, then the closing rule — and the budget must not reshuffle them.
    func testTheKeptBlocksStayInDeclarationOrderWhateverTheirValues() {
        let fit = CoachContextBudget.fit([
            CoachContextBlock(name: "first", value: 10, full: "AAAA"),
            CoachContextBlock(name: "second", value: 100, full: "BBBB"),
            CoachContextBlock(name: "third", value: 50, full: "CCCC"),
        ], budget: 1_000, reserved: 0)
        let a = fit.text.range(of: "AAAA")!.lowerBound
        let b = fit.text.range(of: "BBBB")!.lowerBound
        let c = fit.text.range(of: "CCCC")!.lowerBound
        XCTAssertTrue(a < b && b < c, fit.text)
    }

    /// An empty block is not a block: it must not consume a separator or appear in the note.
    func testEmptyBlocksAreIgnoredEntirely() {
        let fit = CoachContextBudget.fit([
            CoachContextBlock(name: "blank", value: 10, full: "   \n "),
            CoachContextBlock(name: "real", value: 20, full: "DDDD"),
        ], budget: 1_000, reserved: 0)
        XCTAssertEqual(fit.text, "DDDD")
        XCTAssertTrue(fit.isComplete)
    }

    // MARK: - The note

    /// THE TRIMMED CONTEXT SAYS SO. A model handed a shortened context reads it as a complete one and reasons
    /// from the absence — "you have not meditated this week" about a block that was dropped for size. The note
    /// turns that into the abstention the rest of the app is held to.
    func testATrimmedContextCarriesOneLineNamingWhatWasLostAndForbiddingInferenceFromIt() {
        let fit = CoachContextBudget.fit([
            block("today's training state", 100, chars: 400),
            block("the dream journal", 20, chars: 8_000),
            block("the coach's memory file", 10, chars: 4_000, shortChars: 40),
        ], budget: 400, reserved: 0)
        XCTAssertTrue(fit.text.contains("CONTEXT TRIMMED"), fit.text)
        XCTAssertTrue(fit.text.contains("the dream journal"), fit.text)
        XCTAssertTrue(fit.text.lowercased().contains("never say a figure is absent"), fit.text)
        XCTAssertTrue(fit.text.lowercased().contains("say you were not given it"), fit.text)
    }

    /// The note names the shortened and the dropped SEPARATELY: a block that was summarised is still there,
    /// and telling the model it is gone would make it abstain on figures it was handed.
    func testTheNoteTellsShortenedApartFromDropped() {
        let line = CoachContextBudget.note(shortened: ["the history"], dropped: ["the dream journal"])
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("Shortened: the history"), line!)
        XCTAssertTrue(line!.contains("Left out: the dream journal"), line!)
        XCTAssertNil(CoachContextBudget.note(shortened: [], dropped: []))
    }

    /// The note is inside the budget, not on top of it. Otherwise the thing that reports the overrun causes
    /// one.
    func testTheAssembledTextIncludingTheNoteStaysInsideTheBudget() {
        for budget in [300, 600, 1_200, 2_000] {
            let fit = CoachContextBudget.fit([
                block("a", 100, chars: 6_000),
                block("b", 80, chars: 6_000, shortChars: 600),
                block("c", 40, chars: 6_000),
                block("d", 20, chars: 6_000, shortChars: 200),
            ], budget: budget, reserved: 50)
            XCTAssertLessThanOrEqual(fit.requestTokens, budget,
                                     "budget \(budget) produced a \(fit.requestTokens)-token request")
        }
    }

    // MARK: - Per-request ceilings

    /// THE ARITHMETIC THE WHOLE CHANGE EXISTS FOR. The tile's one merged request plus its retry at half have
    /// to fit inside one minute of the allowance the 413 was reported against — with room left over, because
    /// the chat or a ritual may ask in the same minute.
    func testTheStateTileBudgetPlusItsHalvedRetryFitsInsideEightThousandTokensPerMinute() {
        let d = defaults()
        AIProviderTokenLimit.record(model: "openai/gpt-oss-120b", limit: 8_000, d)
        let budget = CoachRequestBudget.stateTile.resolved(model: "openai/gpt-oss-120b", d)
        let retry = CoachRequestBudget.halved(budget)
        XCTAssertLessThan(budget + retry, 8_000,
                          "a request and its retry must leave room inside the minute")
        XCTAssertLessThan(budget, 4_000, "one request, under half the per-minute limit")
        // And it is smaller than the request that was actually refused.
        XCTAssertLessThan(budget, 8_646)
    }

    /// THE ACCOUNT'S OWN LIMIT WINS. Once the provider has stated one, the nominal ceiling is held down to a
    /// share of it rather than to a guess.
    func testAStatedPerMinuteLimitHoldsTheBudgetDown() {
        let d = defaults()
        let generous = CoachRequestBudget.chat.resolved(model: "m", d)
        AIProviderTokenLimit.record(model: "m", limit: 6_000, d)
        let held = CoachRequestBudget.chat.resolved(model: "m", d)
        XCTAssertLessThan(held, generous)
        XCTAssertLessThanOrEqual(Double(held), 6_000 * CoachRequestBudget.maxShareOfPerMinuteLimit + 1)
    }

    /// And a tiny stated limit never produces a request with nothing in it: the floor stands and the note
    /// says what is missing.
    func testAnAbsurdlySmallStatedLimitStillLeavesTheFloor() {
        let d = defaults()
        AIProviderTokenLimit.record(model: "m", limit: 200, d)
        XCTAssertEqual(CoachRequestBudget.stateTile.resolved(model: "m", d), CoachRequestBudget.floor)
        XCTAssertEqual(CoachRequestBudget.halved(CoachRequestBudget.floor), CoachRequestBudget.floor)
    }

    /// No stated limit, no invention: the nominal figure stands.
    func testWithNoStatedLimitTheNominalBudgetIsUsed() {
        let d = defaults()
        XCTAssertNil(AIProviderTokenLimit.perMinute(model: "never-seen", d))
        XCTAssertEqual(CoachRequestBudget.stateTile.resolved(model: "never-seen", d),
                       CoachRequestBudget.stateTile.tokens)
    }

    // MARK: - Reading the provider's own statement

    /// THE REAL MESSAGE, verbatim from the wearer's device.
    func testTheRealGroq413MessageIsReadForItsLimitAndItsRequestedSize() {
        let message = "Request too large for model `openai/gpt-oss-120b` in organization `org_abc` "
            + "service tier `on_demand` on tokens per minute (TPM): Limit 8000, Requested 8646, please "
            + "reduce your message size and try again."
        let parsed = AIProviderTokenLimit.parse(message)
        XCTAssertEqual(parsed?.limit, 8_000)
        XCTAssertEqual(parsed?.requested, 8_646)
        XCTAssertEqual(parsed?.model, "openai/gpt-oss-120b")
        XCTAssertTrue(parsed!.sentence.contains("8000"))
        XCTAssertTrue(parsed!.sentence.contains("8646"))
    }

    /// Absorbing it files the limit under the model the MESSAGE names, so the next request for that model is
    /// sized to what this account actually allows.
    func testAbsorbingTheMessageRemembersTheLimitForTheModelItNames() {
        let d = defaults()
        let message = "Request too large for model `openai/gpt-oss-120b` in organization `org_abc` on "
            + "tokens per minute (TPM): Limit 8000, Requested 8646, please reduce your message size."
        XCTAssertNotNil(AIProviderTokenLimit.absorb(message, d))
        XCTAssertEqual(AIProviderTokenLimit.perMinute(model: "openai/gpt-oss-120b", d), 8_000)
        XCTAssertNil(AIProviderTokenLimit.perMinute(model: "openai/gpt-oss-20b", d),
                     "one model's limit must not resize another")
    }

    /// ONLY THE PER-MINUTE TOKEN WINDOW. The same sentence shape reports tokens per DAY and requests per
    /// minute, and sizing a request against a day's allowance would be worse than sizing it against a guess.
    func testADailyTokenLimitAndARequestLimitAreNotReadAsAPerMinuteTokenLimit() {
        let d = defaults()
        let daily = "Rate limit reached for model `openai/gpt-oss-20b` in organization `org_abc` service "
            + "tier `on_demand` on tokens per day (TPD): Limit 200000, Used 199500, Requested 1200."
        let requests = "Rate limit reached for model `openai/gpt-oss-20b` on requests per minute (RPM): "
            + "Limit 30, Used 30, Requested 1."
        XCTAssertNil(AIProviderTokenLimit.parse(daily))
        XCTAssertNil(AIProviderTokenLimit.absorb(daily, d))
        XCTAssertNil(AIProviderTokenLimit.absorb(requests, d))
        XCTAssertNil(AIProviderTokenLimit.perMinute(model: "openai/gpt-oss-20b", d))
    }

    /// A message that states a per-minute token limit but names no model is READ — the numbers still reach
    /// the wearer — and nothing is stored, because there is no key to store it under.
    func testAMessageWithNoModelNameIsReadButNotStored() {
        let d = defaults()
        let statement = AIProviderTokenLimit.absorb(
            "Too many tokens on tokens per minute (TPM): Limit 8000, Requested 9000.", d)
        XCTAssertEqual(statement?.limit, 8_000)
        XCTAssertNil(statement?.model)
        XCTAssertNil(AIProviderTokenLimit.perMinute(model: "", d))
    }

    // MARK: - What a failed retry says

    /// 413 AND 429 ARE THE TWO A SMALLER REQUEST CAN FIX, and nothing else is retried automatically: a 500 or
    /// a timeout is not made better by sending less.
    func testOnlyASizeOrRateRefusalIsRetried() {
        XCTAssertTrue(AICoachError.server(413, "too large").isTooLargeOrRateLimited)
        XCTAssertTrue(AICoachError.server(429, "slow down").isTooLargeOrRateLimited)
        XCTAssertTrue(AICoachError.rateLimited("Limit 8000").isTooLargeOrRateLimited)
        for e in [AICoachError.server(500, "boom"), .timedOut, .network("offline"), .decode, .badKey,
                  .noKey, .cancelled] {
            XCTAssertFalse(e.isTooLargeOrRateLimited, e.logReason)
        }
    }

    /// A RETRY THAT ALSO FAILED SAYS SO, WITH BOTH SIZES, and keeps the provider's own sentence — the numbers
    /// in it are the only thing that says what to do next.
    func testAnExhaustedRetryReportsBothAttemptsAndKeepsTheProvidersNumbers() {
        let provider = "Request too large … on tokens per minute (TPM): Limit 8000, Requested 8646"
        let out = AICoachError.retryExhausted(.server(413, provider), first: 3_200, second: 1_600)
        let text = StateCoachFailure.notice(out)
        XCTAssertTrue(text.contains("3200"), text)
        XCTAssertTrue(text.contains("1600"), text)
        XCTAssertTrue(text.contains("Limit 8000"), text)
        XCTAssertTrue(text.contains("8646"), text)
        // The status code survives, so the note still reads as the provider's own refusal.
        XCTAssertEqual(out.logReason, "provider-error-413")
    }

    /// The same for a 429, whose message the app used to throw away entirely.
    func testAnExhaustedRateLimitRetryKeepsTheProvidersMessage() {
        let out = AICoachError.retryExhausted(.rateLimited("Limit 8000, Requested 8646"),
                                              first: 3_200, second: 1_600)
        XCTAssertEqual(out.logReason, "rate-limited")
        let text = StateCoachFailure.notice(out)
        XCTAssertTrue(text.contains("8646"), text)
        XCTAssertTrue(text.contains("1600"), text)
    }

    /// A failure a smaller request cannot fix travels through `retryExhausted` unchanged rather than gaining a
    /// sentence about sizes that had nothing to do with it.
    func testAnUnrelatedFailureIsNotDressedUpAsASizeProblem() {
        let out = AICoachError.retryExhausted(.badKey, first: 3_200, second: 1_600)
        XCTAssertEqual(out.logReason, "key-rejected")
        XCTAssertFalse(StateCoachFailure.notice(out).contains("3200"))
    }
}
