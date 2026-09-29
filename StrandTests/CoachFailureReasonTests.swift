import XCTest
@testable import Strand

/// WHY THIS FILE EXISTS. The wearer's report was: "when manually refreshing the State tile it says the coach
/// is not reachable." The proven cause was that `generateOneShot` wrapped the provider call in `try?`, so a
/// rejected key, a 429, a provider 500 with its own message, an unreadable reply, a mis-typed local-server
/// URL, a key stored for a DIFFERENT provider, a timeout and a mere cancellation all arrived at the tile as
/// the same nil — and the tile reported all of them as "Couldn't reach the coach. Kept the previous state."
/// Six different things to go and do, one sentence for all of them, and no way to retry.
///
/// These pin the classification: that each cause keeps its own token in the log, its own sentence on screen,
/// and the right answer to "is it worth simply trying again".
final class CoachFailureReasonTests: XCTestCase {

    // MARK: - Mapping a thrown error to a cause

    /// A cancelled request is NOT an unreachable provider. `URLSession` reports it as `URLError.cancelled`
    /// and Swift concurrency as `CancellationError`; both used to be wrapped as `.network(...)`, which is how
    /// "the screen went away mid-request" was shown to the wearer as a coach failure.
    func testACancelledRequestIsNotANetworkFailure() {
        XCTAssertEqual(AICoachError.from(URLError(.cancelled)).logReason, "cancelled")
        XCTAssertEqual(AICoachError.from(CancellationError()).logReason, "cancelled")
    }

    func testATimeoutIsItsOwnCause() {
        XCTAssertEqual(AICoachError.from(URLError(.timedOut)).logReason, "timed-out")
    }

    func testARealLossOfConnectionStaysANetworkCause() {
        XCTAssertEqual(AICoachError.from(URLError(.notConnectedToInternet)).logReason, "network")
    }

    /// An `AICoachError` that has already been classified travels through unchanged rather than being
    /// re-wrapped as a network problem.
    func testAnAlreadyClassifiedErrorIsNotReclassified() {
        XCTAssertEqual(AICoachError.from(AICoachError.rateLimited).logReason, "rate-limited")
        XCTAssertEqual(AICoachError.from(AICoachError.server(503, "busy")).logReason, "provider-error-503")
    }

    /// The log token is non-localised and names the OWNER of a mis-filed key, because that is the whole
    /// diagnosis: the coach is configured, a key exists, and it is the wrong one for this provider.
    func testAKeySavedForAnotherProviderIsItsOwnCause() {
        XCTAssertEqual(AICoachError.keyForOtherProvider("OpenAI").logReason, "key-for-OpenAI")
    }

    // MARK: - Worth retrying, or something to go and change

    func testTransientCausesAreRetryableAndTheRestAreNot() {
        for e in [AICoachError.rateLimited, .network("offline"), .decode, .timedOut, .cancelled,
                  .server(500, ""), .server(503, "busy")] {
            XCTAssertTrue(e.isTransient, "\(e.logReason) should be retryable")
            XCTAssertTrue(StateCoachFailure.canRetry(e), e.logReason)
        }
        for e in [AICoachError.noKey, .badKey, .keyForOtherProvider("Groq"),
                  .badCustomURL("bad url"), .emptyReply("no content"), .keySaveFailed] {
            XCTAssertFalse(e.isTransient, "\(e.logReason) is something to go and change, not to retry")
            XCTAssertFalse(StateCoachFailure.canRetry(e), e.logReason)
        }
    }

    /// A 4xx that is not a key rejection is the provider refusing THIS request, not a transient state.
    func testAClientSideProviderErrorIsNotRetryable() {
        XCTAssertFalse(AICoachError.server(400, "bad model").isTransient)
    }

    // MARK: - What the wearer is told

    /// THE ONE THAT MATTERS. Every cause produces a DIFFERENT sentence, and none of the ones that are not a
    /// connection problem claims to be one. This is the assertion that fails if a future edit collapses them
    /// back into one message.
    func testEveryCauseGetsItsOwnSentence() {
        let causes: [AICoachError] = [.noKey, .keyForOtherProvider("OpenAI"), .badKey, .rateLimited,
                                      .timedOut, .network("offline"), .server(500, "upstream"), .decode,
                                      .emptyReply("no content from the provider"),
                                      .badCustomURL("that server URL isn't valid")]
        var seen: Set<String> = []
        for c in causes {
            let line = StateCoachFailure.notice(c)
            XCTAssertFalse(line.isEmpty, c.logReason)
            XCTAssertTrue(seen.insert(line).inserted, "\(c.logReason) reuses another cause's sentence: \(line)")
        }
    }

    func testTheNoteNamesWhatToDoRatherThanBlamingTheConnection() {
        XCTAssertTrue(StateCoachFailure.notice(.badKey).contains("rejected"))
        XCTAssertFalse(StateCoachFailure.notice(.badKey).lowercased().contains("connection"))
        XCTAssertTrue(StateCoachFailure.notice(.rateLimited).contains("rate-limiting"))
        XCTAssertFalse(StateCoachFailure.notice(.rateLimited).lowercased().contains("not set up"))
        XCTAssertTrue(StateCoachFailure.notice(.keyForOtherProvider("Groq")).contains("Groq"))
    }

    /// The provider's OWN message travels to the wearer. A 500 with "model overloaded" in it is far more use
    /// than "couldn't reach the coach", and it is the only thing that explains a mis-typed model id.
    func testTheProvidersOwnMessageIsShown() {
        XCTAssertTrue(StateCoachFailure.notice(.server(503, "model overloaded")).contains("model overloaded"))
        XCTAssertTrue(StateCoachFailure.notice(.emptyReply("check the model name")).contains("check the model name"))
        XCTAssertTrue(StateCoachFailure.notice(.badCustomURL("use http://host:port")).contains("use http://host:port"))
    }

    /// A cancellation says NOTHING: an empty note, so the tile shows no warning at all. Reporting it is the
    /// exact bug — two parallel requests superseded by a newer refresh are not a failure.
    func testACancellationIsReportedAsNothing() {
        XCTAssertTrue(StateCoachFailure.notice(.cancelled).isEmpty)
    }

    // MARK: - Two parallel requests

    /// The State refresh makes two requests at once. When ONE fails for a real reason, that reason is what
    /// the wearer is told — not the cancellation of the other.
    func testARealFailureBeatsACancellation() {
        let picked = StateCoachFailure.firstReportable([.failure(.cancelled), .failure(.badKey)])
        XCTAssertEqual(picked?.logReason, "key-rejected")
    }

    /// When one request ANSWERED and the other was merely cancelled, there is nothing to report.
    func testAPartialSuccessWithACancellationReportsNothing() {
        XCTAssertNil(StateCoachFailure.firstReportable([.success("{}"), .failure(.cancelled)]))
    }

    /// Both succeeded: nothing to report.
    func testTwoSuccessesReportNothing() {
        XCTAssertNil(StateCoachFailure.firstReportable([.success("a"), .success("b")]))
    }

    /// Both cancelled: the cause is returned so the caller can log it, and its note is empty so nothing is
    /// shown. This is the path that used to read "Couldn't reach the coach."
    func testEverythingCancelledIsLoggedButNotShown() {
        let picked = StateCoachFailure.firstReportable([.failure(.cancelled), .failure(.cancelled)])
        XCTAssertEqual(picked?.logReason, "cancelled")
        XCTAssertEqual(picked.map(StateCoachFailure.notice), "")
    }
}
