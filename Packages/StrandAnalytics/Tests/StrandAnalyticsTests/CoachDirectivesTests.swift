import Foundation
import XCTest
@testable import StrandAnalytics

/// Parity pin for the bracket syntax the coach uses to create and delete reminders. Must behave
/// identically to the Android twin `com.noop.ai.CoachDirectivesTest`.
///
/// What these pin is the boundary between "the model asked for something sensible" and "the model
/// produced bracket-shaped noise". Everything on the wrong side of it must come back as `.unparsed`
/// and be reported, never silently applied and never silently dropped — a coach that says it set a
/// reminder when it did not is the failure this whole design is arranged to avoid.
final class CoachDirectivesTests: XCTestCase {

    func testAReplyWithoutDirectivesIsUntouched() {
        let parsed = CoachDirectives.parse("Sleep more. That is the whole tip.")
        XCTAssertEqual(parsed.text, "Sleep more. That is the whole tip.")
        XCTAssertTrue(parsed.requests.isEmpty)
    }

    func testAnAddCarriesTimeRepeatAndReason() {
        let parsed = CoachDirectives.parse(
            "Done.\n[[reminder add 22:00 daily Bedtime, they want eight hours]]"
        )
        guard case let .add(minute, repeats, context) = parsed.requests.first else {
            return XCTFail("expected an add, got \(parsed.requests)")
        }
        XCTAssertEqual(minute, 22 * 60)
        XCTAssertEqual(repeats, .daily)
        XCTAssertEqual(context, "Bedtime, they want eight hours")
    }

    func testTheDirectiveNeverReachesTheWearer() {
        let parsed = CoachDirectives.parse(
            "Right.\n\n[[reminder add 07:30 weekdays Morning walk]]\n\nSee you at half seven."
        )
        XCTAssertFalse(parsed.text.contains("[["))
        XCTAssertFalse(parsed.text.contains("reminder add"))
        // And it leaves no hole where it was.
        XCTAssertEqual(parsed.text, "Right.\n\nSee you at half seven.")
    }

    func testAMissingRepeatKeywordMeansDailyAndTheRestIsReason() {
        guard case let .add(minute, repeats, context) =
            CoachDirectives.request("reminder add 06:00 Get up") else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(minute, 6 * 60)
        XCTAssertEqual(repeats, .daily)
        XCTAssertEqual(context, "Get up")
    }

    func testATimeOffTheClockIsRefusedRatherThanClamped() {
        // 25:00 is a model error, not a preference. Clamping it to 23:59 would schedule a reminder the
        // wearer never asked for at a time the coach never meant.
        assertUnparsed(CoachDirectives.request("reminder add 25:00 daily Nope"))
        assertUnparsed(CoachDirectives.request("reminder add 22:70 daily Nope"))
        // "10pm" would otherwise parse as 10:00 — the wrong half of the day.
        assertUnparsed(CoachDirectives.request("reminder add 10pm daily Nope"))
        assertUnparsed(CoachDirectives.request("reminder add 22:0 daily Nope"))
    }

    func testAnAddWithNoReasonIsRefused() {
        // The reason is what the notification gets written from; without it there is nothing to say.
        assertUnparsed(CoachDirectives.request("reminder add 22:00 daily"))
        assertUnparsed(CoachDirectives.request("reminder add 22:00 daily   —  "))
    }

    func testADeleteCarriesWhateverReferenceWasGiven() {
        guard case let .delete(reference) = CoachDirectives.request("reminder del the bedtime one") else {
            return XCTFail("expected a delete")
        }
        XCTAssertEqual(reference, "the bedtime one")
    }

    func testBracketsAroundSomethingElseAreNotAReminderRequest() {
        let parsed = CoachDirectives.parse("Your HRV [[whatever that means]] is fine.")
        assertUnparsed(parsed.requests.first)
        XCTAssertEqual(parsed.text, "Your HRV  is fine.")
    }

    func testARunawayReasonIsBounded() {
        let long = "reminder add 09:00 daily " + String(repeating: "word ", count: 200)
        guard case let .add(_, _, context) = CoachDirectives.request(long) else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(context.count, CoachDirectives.maxContextChars)
    }

    func testAnUnclosedBracketIsNotADirective() {
        // A model that starts a directive and stops must not take the rest of the reply with it.
        let parsed = CoachDirectives.parse("Fine. [[reminder add 22:00 daily bed")
        XCTAssertTrue(parsed.requests.isEmpty)
        XCTAssertTrue(parsed.text.contains("reminder add"))
    }

    func testTwoDirectivesInOneReplyAreBothRead() {
        let parsed = CoachDirectives.parse(
            "[[reminder del bedtime]] and [[reminder add 23:00 daily Later bedtime]]"
        )
        XCTAssertEqual(parsed.requests.count, 2)
        if case .delete = parsed.requests[0] {} else { XCTFail("first should be a delete") }
        if case .add = parsed.requests[1] {} else { XCTFail("second should be an add") }
    }

    func testTheRepeatKeywordIsCaseInsensitive() {
        guard case let .add(_, repeats, _) =
            CoachDirectives.request("reminder add 07:00 WEEKDAYS Walk") else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(repeats, .weekdays)
    }

    func testAnUnknownRepeatWordBecomesPartOfTheReason() {
        // "fortnightly" is not a rule this app has. It must not silently become daily WITH the word
        // eaten — the wearer would see a reminder whose reason lost its first word.
        guard case let .add(_, repeats, context) =
            CoachDirectives.request("reminder add 07:00 fortnightly Walk") else {
            return XCTFail("expected an add")
        }
        XCTAssertEqual(repeats, .daily)
        XCTAssertEqual(context, "fortnightly Walk")
    }

    private func assertUnparsed(_ request: CoachDirectives.Request?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unparsed = request else {
            return XCTFail("expected .unparsed, got \(String(describing: request))", file: file, line: line)
        }
    }
}
