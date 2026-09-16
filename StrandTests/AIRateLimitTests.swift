import XCTest
@testable import Strand

/// The provider's own rate-limit headers.
///
/// The load-bearing claim here is the WINDOW CLASSIFICATION. Groq meters requests by the day and tokens
/// by the minute on the free tier, and which pair is which varies by tier and model — so the app reads
/// it off each pair's own reset rather than assuming. Getting that backwards would draw a bar labelled
/// "today" that is really "this minute": near full all day, empty seconds before a 429.
final class AIRateLimitTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AIRateLimitTests-\(UUID().uuidString)")
    }

    // MARK: - Durations

    func testGroqsOwnDurationSpellings() {
        XCTAssertEqual(AIRateLimit.duration("7.66s") ?? 0, 7.66, accuracy: 0.001)
        XCTAssertEqual(AIRateLimit.duration("2m59.56s") ?? 0, 179.56, accuracy: 0.001)
        XCTAssertEqual(AIRateLimit.duration("1h2m3s") ?? 0, 3723, accuracy: 0.001)
        XCTAssertEqual(AIRateLimit.duration("300ms") ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(AIRateLimit.duration("23h59m") ?? 0, 86_340, accuracy: 0.001)
        // A bare number is seconds — what an OpenAI-compatible server sends where Groq sends a duration.
        XCTAssertEqual(AIRateLimit.duration("60") ?? 0, 60, accuracy: 0.001)
    }

    func testMinutesAreNotReadAsMilliseconds() {
        // "2m" and "2ms" differ by a factor of 120,000, and reading one as the other is precisely the
        // mistake that would misclassify a daily window.
        XCTAssertEqual(AIRateLimit.duration("2m") ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(AIRateLimit.duration("2ms") ?? 0, 0.002, accuracy: 0.00001)
    }

    func testAnUnreadableDurationIsNilRatherThanZero() {
        XCTAssertNil(AIRateLimit.duration(nil))
        XCTAssertNil(AIRateLimit.duration(""))
        XCTAssertNil(AIRateLimit.duration("soon"))
    }

    // MARK: - Windows

    func testAWindowNeedsBothItsLimitAndItsRemainder() {
        XCTAssertNil(AIRateLimit.window(["x-ratelimit-limit-tokens": "6000"], "tokens"))
        XCTAssertNil(AIRateLimit.window(["x-ratelimit-remaining-tokens": "5000"], "tokens"))
        XCTAssertNil(AIRateLimit.window([:], "tokens"))
    }

    func testResetDecidesWhetherAWindowIsADay() {
        let perMinute = AIRateLimit.window([
            "x-ratelimit-limit-tokens": "6000",
            "x-ratelimit-remaining-tokens": "5400",
            "x-ratelimit-reset-tokens": "7.66s",
        ], "tokens")
        XCTAssertEqual(perMinute?.isDaily, false)
        XCTAssertEqual(perMinute?.used, 600)

        let perDay = AIRateLimit.window([
            "x-ratelimit-limit-requests": "1000",
            "x-ratelimit-remaining-requests": "958",
            "x-ratelimit-reset-requests": "17h12m4s",
        ], "requests")
        XCTAssertEqual(perDay?.isDaily, true)
        XCTAssertEqual(perDay?.used, 42)
        XCTAssertEqual(perDay?.fraction ?? 0, 0.042, accuracy: 0.0001)
    }

    func testAFractionCannotLeaveZeroToOne() {
        // A remainder above the limit, or below zero, is a server being odd — not a reason to draw a
        // bar past the end of its track.
        let odd = AIRateLimit.window([
            "x-ratelimit-limit-requests": "100",
            "x-ratelimit-remaining-requests": "-5",
            "x-ratelimit-reset-requests": "20h",
        ], "requests")
        XCTAssertEqual(odd?.remaining, 0)
        XCTAssertEqual(odd?.fraction, 1)
    }

    // MARK: - Reading it back

    func testAReadingRoundTripsAndPicksTheDailyWindows() {
        AIRateLimit.record(model: "openai/gpt-oss-20b", headers: [
            "X-RateLimit-Limit-Requests": "1000",
            "X-RateLimit-Remaining-Requests": "958",
            "X-RateLimit-Reset-Requests": "17h12m4s",
            "x-ratelimit-limit-tokens": "6000",
            "x-ratelimit-remaining-tokens": "5400",
            "x-ratelimit-reset-tokens": "7.66s",
        ], defaults)
        let r = AIRateLimit.reading(model: "openai/gpt-oss-20b", defaults)
        XCTAssertNotNil(r)
        // Headers are case-insensitive; the capitalised spellings above must land like the rest.
        XCTAssertEqual(r?.dailyRequests?.used, 42)
        // Tokens reset in eight seconds, so they are NOT the day and must not be drawn as it.
        XCTAssertNil(r?.dailyTokens)
    }

    func testAResponseWithNoLimitHeadersLeavesTheLastReadingAlone() {
        AIRateLimit.record(model: "m", headers: [
            "x-ratelimit-limit-requests": "1000",
            "x-ratelimit-remaining-requests": "900",
            "x-ratelimit-reset-requests": "20h",
        ], defaults)
        AIRateLimit.record(model: "m", headers: ["content-type": "application/json"], defaults)
        XCTAssertEqual(AIRateLimit.reading(model: "m", defaults)?.dailyRequests?.used, 100)
    }

    func testAStaleReadingIsNotShown() {
        let old = AIRateLimitReading(
            model: "m",
            requests: AIRateLimitWindow(limit: 1000, remaining: 900, resetSeconds: 72_000),
            tokens: nil,
            receivedAt: Date().addingTimeInterval(-AIRateLimitReading.maxAge - 60))
        XCTAssertFalse(old.isFresh)
    }
}
