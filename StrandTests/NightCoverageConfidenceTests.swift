import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// The night's OWN coverage as a confidence input.
///
/// A night that synced only two hours used to be scored and rendered exactly like a whole night. None of
/// the existing guards could see it: `stageCoverage` measures the hypnogram against the DETECTED span, and
/// the detected span is derived from the very rows whose completeness is in question, so two synced hours
/// produce a two-hour session whose stages cover it perfectly. The measurement has to come from the clock.
///
/// These pin the window arithmetic and the covered-seconds reduction that feed
/// `ScoreConfidence.rest(nightCoverage:)` / `charge(nightCoverage:)`. Pure - no store, no clock of their own.
final class NightCoverageConfidenceTests: XCTestCase {

    /// 2026-08-14 00:00 +03 (the same anchor `SleepReadWindowTests` uses).
    private let dayStart = 1_786_690_800
    private var wellAfter: Int { dayStart + 86_400 }

    // MARK: - The window

    func testWindowRunsFromTwentyTwoHundredToOhNineHundred() throws {
        let w = try XCTUnwrap(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart, now: wellAfter))
        XCTAssertEqual(w.start, dayStart - 2 * 3_600)
        XCTAssertEqual(w.end, dayStart + 9 * 3_600)
        XCTAssertEqual(w.end - w.start, 11 * 3_600, "the stated window is 11 h")
    }

    /// A window still in progress ends NOW. Counting hours that have not happened yet as missing data is
    /// the one direction a coverage figure must never err in - it would mark every morning's live night
    /// as incomplete.
    func testWindowStillInProgressIsClampedToNow() throws {
        let now = dayStart + 4 * 3_600
        let w = try XCTUnwrap(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart, now: now))
        XCTAssertEqual(w.end, now)
        XCTAssertEqual(w.end - w.start, 6 * 3_600)
    }

    /// Before the window opens there is nothing to measure, and nil fails OPEN downstream rather than
    /// reading as "badly covered".
    func testWindowNotYetOpenIsNil() {
        XCTAssertNil(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart,
                                                            now: dayStart - 3 * 3_600))
    }

    // MARK: - Covered seconds

    func testCoveredSecondsCountsDistinctSecondsInsideTheWindow() throws {
        let w = try XCTUnwrap(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart, now: wellAfter))
        // Two hours of 1 Hz heart rate starting at the window's open, and nothing else.
        let hr = (0..<(2 * 3_600)).map { HRSample(ts: w.start + $0, bpm: 55) }
        XCTAssertEqual(IntelligenceEngine.nightHrCoveredSeconds(hr: hr, window: w), 2 * 3_600)
        let fraction = try XCTUnwrap(ScoreConfidence.nightCoverageFraction(
            coveredSeconds: IntelligenceEngine.nightHrCoveredSeconds(hr: hr, window: w),
            windowSeconds: w.end - w.start))
        XCTAssertEqual(fraction, 2.0 / 11.0, accuracy: 1e-9)
        XCTAssertLessThan(fraction, ScoreConfidence.minNightCoverage)
        // …and that is the whole point: every other guard is satisfied and the night still reads BUILDING.
        XCTAssertEqual(
            ScoreConfidence.rest(hasSession: true, hasStagedSleep: true,
                                 asleepSeconds: 2 * 3_600, restorativeSeconds: 0.45 * 2 * 3_600,
                                 efficiency: 0.93, stageCoverage: 1.0, nightCoverage: fraction),
            .building, "a two-hour sync must not be presented as a solid night")
    }

    /// Several samples on ONE timestamp are one covered second, not several - a banked stream cannot
    /// report more coverage than it has.
    func testCoveredSecondsDeduplicatesTimestamps() throws {
        let w = try XCTUnwrap(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart, now: wellAfter))
        let hr = (0..<600).map { _ in HRSample(ts: w.start + 100, bpm: 60) }
        XCTAssertEqual(IntelligenceEngine.nightHrCoveredSeconds(hr: hr, window: w), 1)
    }

    /// Samples outside the window do not count, and the window is half-open so a fully covered window
    /// reports exactly its own length.
    func testCoveredSecondsIsHalfOpenAndWindowScoped() throws {
        let w = try XCTUnwrap(IntelligenceEngine.nightCoverageWindow(dayStart: dayStart, now: wellAfter))
        let full = (w.start..<w.end).map { HRSample(ts: $0, bpm: 58) }
        XCTAssertEqual(IntelligenceEngine.nightHrCoveredSeconds(hr: full, window: w), w.end - w.start)
        XCTAssertEqual(try XCTUnwrap(ScoreConfidence.nightCoverageFraction(
            coveredSeconds: w.end - w.start, windowSeconds: w.end - w.start)), 1.0, accuracy: 1e-9)

        let outside = [HRSample(ts: w.start - 1, bpm: 58), HRSample(ts: w.end, bpm: 58)]
        XCTAssertEqual(IntelligenceEngine.nightHrCoveredSeconds(hr: outside, window: w), 0)
    }

    func testCoveredSecondsIsNilWithoutAWindow() {
        XCTAssertNil(IntelligenceEngine.nightHrCoveredSeconds(hr: [HRSample(ts: 0, bpm: 60)], window: nil))
    }
}
