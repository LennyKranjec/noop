import Foundation
import XCTest
@testable import StrandAnalytics

/// Parity pin for the streaming `<think>` filter. Must behave identically to the Android twin
/// `com.noop.ai.ThinkingFilterTest`.
///
/// The cases that matter are the SPLIT ones: a reasoning model's tags arrive in pieces, and a naive
/// per-chunk replace passes the halves straight through to the user. Each test feeds the stream the
/// way the engine does — one delta at a time — and asserts on what the UI would show.
final class ThinkingFilterTests: XCTestCase {

    private func run(_ deltas: String...) -> String {
        let f = ThinkingFilter()
        var out = ""
        for d in deltas { out += f.push(d) }
        out += f.flush()
        return out
    }

    func testTextWithoutAnyThinkingPassesThroughUnchanged() {
        XCTAssertEqual(run("Sleep ", "more ", "tonight."), "Sleep more tonight.")
    }

    func testAWholeThinkingBlockIsDropped() {
        XCTAssertEqual(run("<think>weighing it up</think>Sleep more."), "Sleep more.")
    }

    func testATagSplitAcrossDeltasIsStillCaught() {
        // The whole reason this is a streaming filter and not a replace.
        XCTAssertEqual(run("<th", "ink>working</thi", "nk>Bed by ten."), "Bed by ten.")
    }

    func testATagSplitCharacterByCharacterIsStillCaught() {
        var deltas = Array("<think>x</think>").map(String.init)
        deltas.append("Done.")
        let f = ThinkingFilter()
        var out = ""
        for d in deltas { out += f.push(d) }
        out += f.flush()
        XCTAssertEqual(out, "Done.")
    }

    func testALoneAngleBracketIsNotSwallowed() {
        XCTAssertEqual(run("HRV < 40 ", "is low."), "HRV < 40 is low.")
    }

    func testTwoBlocksInOneStreamAreBothDropped() {
        XCTAssertEqual(run("<think>x</think>", "A ", "<think>y</think>", "B"), "A B")
    }

    func testAnUnterminatedThinkingBlockYieldsNothingVisible() {
        XCTAssertEqual(run("<think>", "half a thought and then the stream died"), "")
    }

    func testTheWorkingOfAnAnswerThatNeverArrivedIsKeptForTheCaller() {
        // The small-model failure mode: the whole budget spent deliberating, so there is no answer to
        // show. The caller needs the working to explain that, rather than a blank bubble.
        let f = ThinkingFilter()
        _ = f.push("<think>the numbers say ")
        _ = f.push("she is fried, so")
        XCTAssertEqual(f.flush(), "")
        XCTAssertEqual(f.strandedReasoning(), "the numbers say she is fried, so")
    }

    func testNothingIsStrandedWhenTheModelDidReachItsAnswer() {
        // "Not empty" must mean "there is no answer", or the caller shows working alongside one.
        let f = ThinkingFilter()
        _ = f.push("<think>working</think>Sleep more.")
        XCTAssertEqual(f.strandedReasoning(), "")
    }

    func testClosedSpansAreHandedBack() {
        // The directive lane runs this same filter with bracket tags and needs what was dropped.
        let f = ThinkingFilter(openTag: "[[", closeTag: "]]")
        _ = f.push("Done. [[reminder add 22:00 daily Bed]] See you.")
        XCTAssertEqual(f.captured(), ["reminder add 22:00 daily Bed"])
    }

    func testTextAfterAClosedSpanSurvives() {
        XCTAssertEqual(run("<think>x</think>", "tail"), "tail")
    }

    func testAPartialOpenTagAtTheEndIsHeldNotEmitted() {
        // "<thi" must not reach the screen just because the stream paused there.
        let f = ThinkingFilter()
        XCTAssertEqual(f.push("Answer<thi"), "Answer")
    }
}
