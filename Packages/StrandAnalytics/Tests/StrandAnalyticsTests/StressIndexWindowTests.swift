import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// F8 — the day's Baevsky Stress Index is the MEDIAN of its 5-minute windows, not one histogram over
/// midnight → now (which pooled sleep, exercise and rest and measured the day's HR spread instead).
final class StressIndexWindowTests: XCTestCase {

    /// A clean, gently varying R-R block of `count` beats around `centerMs`, starting at `startTs`, one
    /// beat per second so a block of ≤ 300 beats fits one 5-minute window.
    private func block(startTs: Int, count: Int, centerMs: Int, swingMs: Int) -> [RRInterval] {
        (0..<count).map { i in
            let offset = [0, swingMs, -swingMs, swingMs / 2, -swingMs / 2][i % 5]
            return RRInterval(ts: startTs + i, rrMs: centerMs + offset)
        }
    }

    func testEachWindowIsScoredOnItsOwnBeats() {
        // Three windows on the unix 300 s grid.
        let rr = block(startTs: 3_000, count: 120, centerMs: 1_000, swingMs: 40)
            + block(startTs: 3_300, count: 120, centerMs: 800, swingMs: 20)
            + block(startTs: 3_600, count: 120, centerMs: 600, swingMs: 10)
        let windows = StressIndex.windowComponents(rr: rr)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0], StressIndex.components(rr: Array(rr[0..<120])))
        XCTAssertEqual(windows[1], StressIndex.components(rr: Array(rr[120..<240])))
        XCTAssertEqual(windows[2], StressIndex.components(rr: Array(rr[240..<360])))
    }

    func testMedianIsTheMiddleWindowNotTheWholeDayHistogram() {
        let rr = block(startTs: 3_000, count: 120, centerMs: 1_000, swingMs: 40)   // relaxed
            + block(startTs: 3_300, count: 120, centerMs: 800, swingMs: 20)        // middle
            + block(startTs: 3_600, count: 120, centerMs: 600, swingMs: 10)        // tense
        let perWindow = StressIndex.windowComponents(rr: rr).map(\.si).sorted()
        let median = StressIndex.medianWindowStressIndex(rr: rr)
        XCTAssertEqual(median, perWindow[1])
        // The pooled whole-series SI sees a 600→1040 ms range across the windows — a different number.
        XCTAssertNotEqual(median, StressIndex.stressIndex(rr: rr))
    }

    func testEvenCountReportsTheLowerMiddleWindow() {
        let rr = block(startTs: 3_000, count: 120, centerMs: 1_000, swingMs: 40)
            + block(startTs: 3_300, count: 120, centerMs: 800, swingMs: 20)
            + block(startTs: 3_600, count: 120, centerMs: 700, swingMs: 15)
            + block(startTs: 3_900, count: 120, centerMs: 600, swingMs: 10)
        let sorted = StressIndex.windowComponents(rr: rr).sorted { $0.si < $1.si }
        XCTAssertEqual(sorted.count, 4)
        XCTAssertEqual(StressIndex.medianWindowComponents(rr: rr), sorted[1])
    }

    func testSparseWindowsAreSkipped() {
        // One full window plus one 30-beat fragment: only the full window counts.
        let full = block(startTs: 3_000, count: 120, centerMs: 900, swingMs: 30)
        let fragment = block(startTs: 3_300, count: 30, centerMs: 600, swingMs: 10)
        let windows = StressIndex.windowComponents(rr: full + fragment)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(StressIndex.medianWindowStressIndex(rr: full + fragment),
                       StressIndex.stressIndex(rr: full))
    }

    func testNoQualifyingWindowIsNil() {
        XCTAssertNil(StressIndex.medianWindowStressIndex(rr: []))
        XCTAssertNil(StressIndex.medianWindowStressIndex(rr: block(startTs: 3_000, count: 40, centerMs: 900,
                                                                   swingMs: 30)))
    }
}
