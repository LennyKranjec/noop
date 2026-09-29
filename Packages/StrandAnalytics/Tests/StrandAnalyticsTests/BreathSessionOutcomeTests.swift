import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// The honest breathing before/after (HEALTH_V2 S4 §4.2, §4.4). Pinned here:
///   * 39 clean beats ⇒ `tooFewBeats`; 25 % rejected ⇒ `tooManyArtifacts`;
///   * a synthetic series with known successive differences gives the expected RMSSD (±0.5 ms);
///   * the first 30 s of each quiet window are dropped, and paced beats never enter pre/post;
///   * the change exists only when both windows passed, and is symmetric in the log domain;
///   * the personal comparison appears only from 5 stored sessions.
final class BreathSessionOutcomeTests: XCTestCase {

    private let t0 = 1_790_000_000

    /// `values` spread evenly across the 60 s after the settling drop of a window starting at `start`.
    private func beats(_ values: [Int], start: Int) -> [ResonanceEngine.RrBeat] {
        values.enumerated().map { i, v in
            ResonanceEngine.RrBeat(ts: start + BreathSessionOutcome.settleSeconds + (i * 59) / max(1, values.count),
                                   rrMs: v)
        }
    }

    /// Alternating 1000 / 1040 ms: every successive difference is 40 ms ⇒ RMSSD 40.
    private func alternating(_ n: Int) -> [Int] { (0..<n).map { $0 % 2 == 0 ? 1000 : 1040 } }

    private func window(_ rr: [ResonanceEngine.RrBeat], start: Int, length: Int = 90) -> BreathSessionOutcome.QuietWindow {
        BreathSessionOutcome.QuietWindow(startTs: start, endTs: start + length, rr: rr)
    }

    // MARK: Gates

    func testThirtyNineCleanBeatsIsTooFew() {
        let r = BreathSessionOutcome.reading(window(beats(alternating(39), start: t0), start: t0))
        XCTAssertEqual(r.abstention, .tooFewBeats)
        XCTAssertNil(r.rmssd)
        XCTAssertEqual(r.cleanBeats, 39)

        let ok = BreathSessionOutcome.reading(window(beats(alternating(40), start: t0), start: t0))
        XCTAssertNil(ok.abstention)
        XCTAssertNotNil(ok.rmssd)
    }

    func testTwentyFivePercentRejectedIsTooNoisy() {
        // 60 good beats, 20 out-of-range (3000 ms) ⇒ 25 % rejected, 60 clean.
        var values = alternating(60)
        for i in stride(from: 0, to: 80, by: 4) { values.insert(3000, at: min(i, values.count)) }
        XCTAssertEqual(values.count, 80)
        let r = BreathSessionOutcome.reading(window(beats(values, start: t0), start: t0))
        XCTAssertEqual(r.abstention, .tooManyArtifacts)
        XCTAssertEqual(r.rejectedPct ?? 0, 25, accuracy: 1e-9)

        // 15 % rejected passes.
        var fewer = alternating(68)
        for i in stride(from: 0, to: 72, by: 6) { fewer.insert(3000, at: min(i, fewer.count)) }
        XCTAssertEqual(fewer.count, 80)
        XCTAssertNil(BreathSessionOutcome.reading(window(beats(fewer, start: t0), start: t0)).abstention)
    }

    func testShortWindowAndNoBeats() {
        XCTAssertEqual(BreathSessionOutcome.reading(window(beats(alternating(60), start: t0), start: t0, length: 80))
            .abstention, .windowTooShort)
        XCTAssertEqual(BreathSessionOutcome.reading(window([], start: t0)).abstention, .noLiveRR)
    }

    // MARK: RMSSD

    func testKnownSuccessiveDifferencesGiveTheExpectedRmssd() {
        let r = BreathSessionOutcome.reading(window(beats(alternating(60), start: t0), start: t0))
        XCTAssertEqual(r.rmssd ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(r.meanHr ?? 0, 60_000 / 1020, accuracy: 0.01, "mean HR from the clean beats")
    }

    func testFirstThirtySecondsAreDropped() {
        // Wild alternation (600/1400) in the settling period, clean beats after it.
        let settling = (0..<25).map { ResonanceEngine.RrBeat(ts: t0 + $0, rrMs: $0 % 2 == 0 ? 600 : 1400) }
        let r = BreathSessionOutcome.reading(window(settling + beats(alternating(60), start: t0), start: t0))
        XCTAssertNil(r.abstention)
        XCTAssertEqual(r.inputBeats, 60, "no settling beat was read")
        XCTAssertEqual(r.rmssd ?? 0, 40, accuracy: 0.5)
    }

    func testPacedBeatsNeverEnterAQuietWindow() {
        let clean = beats(alternating(60), start: t0)
        // Beats stamped after the window's end (the paced phase) with a huge swing.
        let paced = (0..<200).map { ResonanceEngine.RrBeat(ts: t0 + 95 + $0, rrMs: $0 % 2 == 0 ? 700 : 1300) }
        let a = BreathSessionOutcome.reading(window(clean, start: t0))
        let b = BreathSessionOutcome.reading(window(clean + paced, start: t0))
        XCTAssertEqual(a, b)

        // And a whole-session evaluation never mixes the paced swing into the change.
        let postStart = t0 + 1000
        let res = BreathSessionOutcome.evaluate(
            pre: window(clean + paced, start: t0), pacedRR: paced, pacedStartTs: t0 + 90, pacedEndTs: t0 + 900,
            post: window(beats(alternating(60), start: postStart) + paced, start: postStart), paceBpm: 6)
        XCTAssertEqual(res.change?.deltaPct ?? 99, 0, accuracy: 1e-9, "identical quiet windows ⇒ no change")
    }

    // MARK: Change

    func testChangeNeedsBothWindows() {
        let pre = window(beats(alternating(60), start: t0), start: t0)
        let badPost = window(beats(alternating(10), start: t0 + 1000), start: t0 + 1000)
        let res = BreathSessionOutcome.evaluate(pre: pre, pacedRR: [], pacedStartTs: t0 + 90, pacedEndTs: t0 + 900,
                                                post: badPost, paceBpm: 6)
        XCTAssertNil(res.change)
        XCTAssertEqual(res.post.abstention, .tooFewBeats)
        XCTAssertTrue(BreathSessionOutcome.line(res.post).hasPrefix("—"))
    }

    func testDeltaIsSymmetricInLog() {
        let up = BreathSessionOutcome.deltaPct(pre: 38, post: 44)!
        let down = BreathSessionOutcome.deltaPct(pre: 44, post: 38)!
        XCTAssertEqual(log(1 + up / 100), -log(1 + down / 100), accuracy: 1e-12)
        XCTAssertEqual(up, 100 * (44.0 / 38.0 - 1), accuracy: 1e-9)
        XCTAssertNil(BreathSessionOutcome.deltaPct(pre: 0, post: 40))
    }

    // MARK: Personal comparison

    func testComparisonOnlyFromFiveSessions() {
        XCTAssertNil(BreathSessionOutcome.compare(deltaPct: 10, past: [1, 2, 3, 4]))
        let past = [0.0, 5, 10, 15, 20]   // Q1 5, median 10, Q3 15
        let c = BreathSessionOutcome.compare(deltaPct: 10, past: past)
        XCTAssertEqual(c?.label, .similar)
        XCTAssertEqual(c?.usualDeltaPct ?? 0, 10, accuracy: 1e-9)
        XCTAssertEqual(BreathSessionOutcome.compare(deltaPct: 16, past: past)?.label, .larger)
        XCTAssertEqual(BreathSessionOutcome.compare(deltaPct: 4, past: past)?.label, .smaller)
        XCTAssertEqual(BreathSessionOutcome.comparisonLine(c), "a similar change than your usual (+10 %)")
    }

    func testChangeLine() {
        XCTAssertEqual(BreathSessionOutcome.changeLine(.init(deltaPct: 15.4, deltaHr: -4.2)), "(+15 %, −4 bpm)")
        XCTAssertNil(BreathSessionOutcome.changeLine(nil))
    }
}
