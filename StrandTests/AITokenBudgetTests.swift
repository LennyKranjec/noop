import XCTest
@testable import Strand

/// The daily token allowance the coach runs on.
///
/// Two things here are worth more than the arithmetic:
///
///   * AN UNREPORTED TURN IS NOT A FREE TURN. A provider that returns no `usage` must leave the count
///     alone and be counted as unmetered, so the reading can say it is a floor. Recording a zero would
///     make the budget claim a completeness it does not have — and it would claim it most loudly in
///     exactly the case where the wearer is about to hit a 429 with no warning.
///   * THE ALLOWANCE IS PER MODEL. Switching models does not spend one budget twice.
final class AITokenBudgetTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AITokenBudgetTests-\(UUID().uuidString)")
    }

    func testUsageAccumulatesAcrossTurns() {
        AITokenBudget.record(model: "openai/gpt-oss-20b", tokens: 1_200, defaults)
        AITokenBudget.record(model: "openai/gpt-oss-20b", tokens: 800, defaults)
        let r = AITokenBudget.reading(model: "openai/gpt-oss-20b", defaults)
        XCTAssertEqual(r?.used, 2_000)
        XCTAssertEqual(r?.unmetered, 0)
        XCTAssertEqual(r?.remaining, AITokenBudget.dailyLimit - 2_000)
    }

    func testATurnWithNoReportedUsageIsCountedAsUnmeteredNotAsZero() {
        AITokenBudget.record(model: "m", tokens: nil, defaults)
        AITokenBudget.record(model: "m", tokens: 0, defaults)
        let r = AITokenBudget.reading(model: "m", defaults)
        XCTAssertEqual(r?.used, 0)
        XCTAssertEqual(r?.unmetered, 2)
        // It HAS been used today, so the pill must show rather than read as a fresh morning.
        XCTAssertEqual(r?.isUntouched, false)
    }

    func testEachModelKeepsItsOwnAllowance() {
        AITokenBudget.record(model: "openai/gpt-oss-20b", tokens: 5_000, defaults)
        AITokenBudget.record(model: "openai/gpt-oss-120b", tokens: 900, defaults)
        XCTAssertEqual(AITokenBudget.reading(model: "openai/gpt-oss-20b", defaults)?.used, 5_000)
        XCTAssertEqual(AITokenBudget.reading(model: "openai/gpt-oss-120b", defaults)?.used, 900)
    }

    func testTheSameModelSpeltDifferentlyIsOneAllowance() {
        AITokenBudget.record(model: "openai/gpt-oss-20b", tokens: 100, defaults)
        AITokenBudget.record(model: "  openai/GPT-OSS-20b ", tokens: 100, defaults)
        XCTAssertEqual(AITokenBudget.reading(model: "openai/gpt-oss-20b", defaults)?.used, 200)
    }

    func testAnEmptyModelNameRecordsNothingAndReadsNothing() {
        AITokenBudget.record(model: "   ", tokens: 500, defaults)
        XCTAssertNil(AITokenBudget.reading(model: "", defaults))
    }

    func testFractionIsClampedAndTheWarningTripsAtFourFifths() {
        AITokenBudget.record(model: "m", tokens: AITokenBudget.dailyLimit * 3, defaults)
        let r = AITokenBudget.reading(model: "m", defaults)
        XCTAssertEqual(r?.fraction, 1)
        XCTAssertEqual(r?.remaining, 0)
        XCTAssertEqual(r?.isWarning, true)

        AITokenBudget.record(model: "n", tokens: Int(Double(AITokenBudget.dailyLimit) * 0.5), defaults)
        XCTAssertEqual(AITokenBudget.reading(model: "n", defaults)?.isWarning, false)
    }

    func testYesterdaysFiguresAreDroppedTheFirstTimeTodayTouchesTheModel() {
        AITokenBudget.record(model: "m", tokens: 9_000, defaults)
        // Backdate the stored day, which is exactly what a relaunch the next morning looks like.
        defaults.set("2000-01-01", forKey: "ai.tokens.day.m")
        XCTAssertEqual(AITokenBudget.reading(model: "m", defaults)?.used, 0)
    }

    func testResetThrowsAwayTheDay() {
        AITokenBudget.record(model: "m", tokens: 9_000, defaults)
        AITokenBudget.record(model: "m", tokens: nil, defaults)
        AITokenBudget.reset(model: "m", defaults)
        let r = AITokenBudget.reading(model: "m", defaults)
        XCTAssertEqual(r?.used, 0)
        XCTAssertEqual(r?.unmetered, 0)
        XCTAssertEqual(r?.isUntouched, true)
    }

    // MARK: - Reading the provider's own figure

    func testTotalTokensPrefersTheTotalAndFallsBackToTheHalves() {
        XCTAssertEqual(AITokenBudget.totalTokens(in: ["usage": ["total_tokens": 1_234]]), 1_234)
        XCTAssertEqual(
            AITokenBudget.totalTokens(in: ["usage": ["prompt_tokens": 900, "completion_tokens": 100]]),
            1_000)
    }

    func testAMissingOrEmptyUsageBlockReportsNothingRatherThanZero() {
        XCTAssertNil(AITokenBudget.totalTokens(in: [:]))
        XCTAssertNil(AITokenBudget.totalTokens(in: ["usage": [:] as [String: Any]]))
        XCTAssertNil(AITokenBudget.totalTokens(in: ["usage": ["total_tokens": 0]]))
    }

    // MARK: - Syncing to the provider's own figure

    func testAGroqDailyLimitRejectionResyncsTheCountAndTheLimit() {
        AITokenBudget.record(model: "openai/gpt-oss-20b", tokens: 3_000, defaults)
        let message = "Rate limit reached for model `openai/gpt-oss-20b` in organization `org_01abc` "
            + "service tier `on_demand` on tokens per day (TPD): Limit 200000, Used 199500, "
            + "Requested 1200. Please try again in 7m12s."
        XCTAssertTrue(AITokenBudget.absorbProviderError(message, defaults))
        let r = AITokenBudget.reading(model: "openai/gpt-oss-20b", defaults)
        // REPLACED, not added: the provider's figure already includes this device's 3,000 and whatever
        // the same key spent anywhere else.
        XCTAssertEqual(r?.used, 199_500)
        XCTAssertEqual(r?.limit, 200_000)
        XCTAssertNotNil(r?.syncedAt)
    }

    func testAPerMinuteRejectionDoesNotTouchTheDaysCount() {
        AITokenBudget.record(model: "m", tokens: 3_000, defaults)
        let message = "Rate limit reached for model `m` in organization `org_x` service tier `on_demand` "
            + "on tokens per minute (TPM): Limit 8000, Used 7900, Requested 900."
        XCTAssertFalse(AITokenBudget.absorbProviderError(message, defaults))
        XCTAssertEqual(AITokenBudget.reading(model: "m", defaults)?.used, 3_000)
    }

    func testAStatedLimitSurvivesTheNextDay() {
        AITokenBudget.resync(model: "m", used: 50_000, limit: 500_000, defaults)
        defaults.set("2000-01-01", forKey: "ai.tokens.day.m")
        let r = AITokenBudget.reading(model: "m", defaults)
        XCTAssertEqual(r?.used, 0)
        XCTAssertEqual(r?.limit, 500_000)
        XCTAssertNil(r?.syncedAt)
    }

    func testGroqsStreamedUsageUnderItsOwnKeyIsCounted() {
        XCTAssertEqual(AITokenBudget.totalTokens(
            inStreamPayload: #"{"choices":[],"x_groq":{"id":"req_1","usage":{"total_tokens":913}}}"#), 913)
    }

    func testAStreamChunkOnlyReportsWhenItCarriesUsage() {
        XCTAssertNil(AITokenBudget.totalTokens(
            inStreamPayload: #"{"choices":[{"delta":{"content":"hi"}}]}"#))
        XCTAssertNil(AITokenBudget.totalTokens(inStreamPayload: "[DONE]"))
        XCTAssertEqual(AITokenBudget.totalTokens(
            inStreamPayload: #"{"choices":[],"usage":{"total_tokens":42}}"#), 42)
    }
}
