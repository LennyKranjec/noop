import XCTest
@testable import Strand

/// The pure half of the night-coverage diagnostic: the window, the gap arithmetic, the verdict and the
/// wording. Nothing here touches a store, a clock or a strap, so the thing a user reads back after a sync
/// is pinned by fixtures rather than by having to reproduce a bad night.
final class NightCoverageTests: XCTestCase {

    // MARK: - Helpers

    private func berlin() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        return cal.date(from: c)!
    }

    // MARK: - The window

    /// After the window has closed, it is the previous evening through this morning, whatever time of day
    /// the sync happens to run.
    func testWindowIsLastEveningThroughThisMorning() {
        let cal = berlin()
        let now = date(cal, 2026, 9, 29, 15, 20)
        let w = NightCoverage.lastNightWindow(now: now, calendar: cal)
        XCTAssertEqual(w?.start, Int(date(cal, 2026, 9, 28, 22).timeIntervalSince1970))
        XCTAssertEqual(w?.end, Int(date(cal, 2026, 9, 29, 9).timeIntervalSince1970))
        XCTAssertEqual((w?.end ?? 0) - (w?.start ?? 0), 11 * 3600)
    }

    /// A sync at 07:30 must NOT be told the night is missing its last ninety minutes: those have not
    /// happened yet. Counting the future as absent data is the one direction this figure must never err in.
    func testWindowStillInProgressEndsNowNotAtTheNominalHour() {
        let cal = berlin()
        let now = date(cal, 2026, 9, 29, 7, 30)
        let w = NightCoverage.lastNightWindow(now: now, calendar: cal)
        XCTAssertEqual(w?.start, Int(date(cal, 2026, 9, 28, 22).timeIntervalSince1970))
        XCTAssertEqual(w?.end, Int(now.timeIntervalSince1970))
    }

    /// A sync late in the evening still reports LAST night, not the one just beginning.
    func testWindowLateEveningStillReportsLastNight() {
        let cal = berlin()
        let now = date(cal, 2026, 9, 29, 23, 40)
        let w = NightCoverage.lastNightWindow(now: now, calendar: cal)
        XCTAssertEqual(w?.start, Int(date(cal, 2026, 9, 28, 22).timeIntervalSince1970))
        XCTAssertEqual(w?.end, Int(date(cal, 2026, 9, 29, 9).timeIntervalSince1970))
    }

    /// DST: the clocks go BACK on 2026-10-25, so that night is twelve real hours between the same two wall
    /// times. An 86,400-based window would report eleven and invent a missing hour; the calendar path does
    /// not. This is the same mistake the repo has made before in day arithmetic, so it is pinned here.
    func testWindowIsTwelveHoursOnTheAutumnDstNight() {
        let cal = berlin()
        let now = date(cal, 2026, 10, 25, 12)
        let w = NightCoverage.lastNightWindow(now: now, calendar: cal)
        XCTAssertEqual((w?.end ?? 0) - (w?.start ?? 0), 12 * 3600)
    }

    /// And ten hours on the spring night, when an hour does not exist at all.
    func testWindowIsTenHoursOnTheSpringDstNight() {
        let cal = berlin()
        let now = date(cal, 2026, 3, 29, 12)
        let w = NightCoverage.lastNightWindow(now: now, calendar: cal)
        XCTAssertEqual((w?.end ?? 0) - (w?.start ?? 0), 10 * 3600)
    }

    // MARK: - Gap arithmetic

    /// A window with nothing in it is entirely one gap, and the gap starts at the window's own start. This
    /// is the case a row-count log could never express: zero rows and "no gaps" would both be printable.
    func testEmptyWindowIsOneFullGap() {
        let s = NightCoverage.stats(seconds: [], samples: 0, windowStart: 1_000, windowEnd: 2_000)
        XCTAssertEqual(s.coveredSeconds, 0)
        XCTAssertEqual(s.largestGapSeconds, 1_000)
        XCTAssertEqual(s.largestGapStartTs, 1_000)
        XCTAssertNil(s.firstTs)
        XCTAssertNil(s.lastTs)
    }

    func testContiguousCoverageHasNoGap() {
        let seconds = Array(1_000..<2_000)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 1_000, windowEnd: 2_000)
        XCTAssertEqual(s.coveredSeconds, 1_000)
        XCTAssertEqual(s.largestGapSeconds, 0)
        XCTAssertNil(s.largestGapStartTs)
        XCTAssertEqual(s.firstTs, 1_000)
        XCTAssertEqual(s.lastTs, 1_999)
    }

    /// The gap the user actually felt: data for the first hour, nothing for two, data again. The run
    /// BETWEEN samples is measured, and it starts at the first missing second, not at the last held one.
    func testGapBetweenSamplesIsMeasuredFromTheFirstMissingSecond() {
        let seconds = Array(0..<10) + Array(110..<120)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: 120)
        XCTAssertEqual(s.coveredSeconds, 20)
        XCTAssertEqual(s.largestGapSeconds, 100)   // 10...109 inclusive
        XCTAssertEqual(s.largestGapStartTs, 10)
    }

    /// A night whose heart rate only starts three hours in is missing three hours. A gap measure that only
    /// looked BETWEEN samples would call that night gapless, which is precisely the reassurance this
    /// diagnostic exists to refuse.
    func testLeadingGapAtTheWindowEdgeCounts() {
        let seconds = Array(500..<1_000)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: 1_000)
        XCTAssertEqual(s.largestGapSeconds, 500)
        XCTAssertEqual(s.largestGapStartTs, 0)
    }

    /// And the same at the other edge: an offload that stopped before morning.
    func testTrailingGapAtTheWindowEdgeCounts() {
        let seconds = Array(0..<400)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: 1_000)
        XCTAssertEqual(s.largestGapSeconds, 600)   // 400...999 inclusive
        XCTAssertEqual(s.largestGapStartTs, 400)
    }

    /// Seconds outside the window never inflate coverage, so a read that overshot its bounds cannot make a
    /// night look better than it is.
    func testSecondsOutsideTheWindowAreIgnored() {
        let s = NightCoverage.stats(seconds: [-5, 0, 1, 999, 1_000, 5_000], samples: 6,
                                    windowStart: 0, windowEnd: 1_000)
        XCTAssertEqual(s.coveredSeconds, 3)        // 0, 1, 999 — 1_000 is outside the half-open window
        XCTAssertEqual(s.firstTs, 0)
        XCTAssertEqual(s.lastTs, 999)
    }

    /// Row count and covered seconds are DIFFERENT facts and the reduction keeps them apart: R-R banks
    /// several beats on one second, and reporting the beat count as coverage would claim time the night
    /// does not hold.
    func testSamplesAreCarriedSeparatelyFromCoveredSeconds() {
        let s = NightCoverage.stats(seconds: [10, 11, 12], samples: 42,
                                    windowStart: 0, windowEnd: 100)
        XCTAssertEqual(s.coveredSeconds, 3)
        XCTAssertEqual(s.samples, 42)
    }

    // MARK: - Verdict

    func testVerdictNoneWhenNothingLanded() {
        let s = NightCoverage.stats(seconds: [], samples: 0, windowStart: 0, windowEnd: 1_000)
        XCTAssertEqual(NightCoverage.verdict(s, windowSeconds: 1_000), .empty)
    }

    func testVerdictSparseBelowHalfTheWindow() {
        let seconds = Array(0..<499)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: 1_000)
        XCTAssertEqual(NightCoverage.verdict(s, windowSeconds: 1_000), .sparse)
    }

    /// Exactly half is not sparse: the threshold is "less than half", and a boundary that moved with the
    /// wording would make the line mean something different from what it says.
    func testVerdictAtExactlyHalfIsNotSparse() {
        let seconds = Array(0..<500)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: 1_000)
        XCTAssertNotEqual(NightCoverage.verdict(s, windowSeconds: 1_000), .sparse)
    }

    /// Good total coverage, one half-hour blind stretch. Total coverage alone would have called this night
    /// fine, and the stages inside that stretch were never observed.
    func testVerdictHoledOnAHalfHourBlindStretchDespiteGoodTotalCoverage() {
        let window = 8 * 3_600
        let hole = NightCoverage.holeSeconds
        let seconds = Array(0..<(window / 2)) + Array((window / 2 + hole)..<window)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: window)
        XCTAssertGreaterThan(Double(s.coveredSeconds) / Double(window), NightCoverage.sparseFraction)
        XCTAssertEqual(NightCoverage.verdict(s, windowSeconds: window), .holed)
    }

    func testVerdictCoveredWhenWholeNightArrived() {
        let window = 8 * 3_600
        let seconds = Array(0..<window)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: window)
        XCTAssertEqual(NightCoverage.verdict(s, windowSeconds: window), .covered)
    }

    /// A truncated read cannot say whether the night was complete, and it must NOT be reported as either
    /// good or bad. "We could not measure" and "the night is fine" are different claims.
    func testVerdictUnknownWhenTheReadWasTruncated() {
        let window = 8 * 3_600
        let seconds = Array(0..<window)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: 0, windowEnd: window, truncated: true)
        XCTAssertEqual(NightCoverage.verdict(s, windowSeconds: window), .unknown)
    }

    // MARK: - Formatting

    func testDurationFormat() {
        XCTAssertEqual(NightCoverage.duration(0), "0m")
        XCTAssertEqual(NightCoverage.duration(45), "45s")
        XCTAssertEqual(NightCoverage.duration(60), "1m")
        XCTAssertEqual(NightCoverage.duration(3_600), "1h0m")
        XCTAssertEqual(NightCoverage.duration(5 * 3_600 + 31 * 60), "5h31m")
    }

    /// A night one second short of whole is not a whole night, and the line is read as a claim.
    func testPercentNeverRoundsAPartialNightUpToWhole() {
        XCTAssertEqual(NightCoverage.percent(0, of: 1_000), "0%")
        XCTAssertEqual(NightCoverage.percent(500, of: 1_000), "50%")
        XCTAssertEqual(NightCoverage.percent(999, of: 1_000), "99%")
        XCTAssertEqual(NightCoverage.percent(1_000, of: 1_000), "100%")
        XCTAssertEqual(NightCoverage.percent(5, of: 0), "0%")
    }

    // MARK: - The line

    /// The whole point of the line: an incomplete night SAYS it is incomplete, in words, beside the numbers
    /// that prove it. A count-only log could print "8000 rows" for exactly this night.
    func testLineNamesAnIncompleteNightAsIncomplete() {
        let cal = berlin()
        let start = Int(date(cal, 2026, 9, 28, 22).timeIntervalSince1970)
        let end = start + 11 * 3_600
        // Two hours of HR at the start of the night, then nothing.
        let seconds = Array(start..<(start + 2 * 3_600))
        let hr = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                     windowStart: start, windowEnd: end)
        let rr = NightCoverage.stats(seconds: seconds, samples: seconds.count * 2,
                                     windowStart: start, windowEnd: end)
        let line = NightCoverage.line(windowStart: start, windowEnd: end, hr: hr, rr: rr,
                                      timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertTrue(line.contains("Night coverage 2026-09-28 22:00 to 09:00 local"), line)
        XCTAssertTrue(line.contains("window 11h0m"), line)
        XCTAssertTrue(line.contains("covering 2h0m (18%)"), line)
        XCTAssertTrue(line.contains("largest gap 9h0m from 00:00"), line)
        XCTAssertTrue(line.contains("INCOMPLETE"), line)
    }

    func testLineSaysCoveredForAWholeNight() {
        let cal = berlin()
        let start = Int(date(cal, 2026, 9, 28, 22).timeIntervalSince1970)
        let end = start + 11 * 3_600
        let seconds = Array(start..<end)
        let s = NightCoverage.stats(seconds: seconds, samples: seconds.count,
                                    windowStart: start, windowEnd: end)
        let line = NightCoverage.line(windowStart: start, windowEnd: end, hr: s, rr: s,
                                      timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertTrue(line.contains("(100%)"), line)
        XCTAssertTrue(line.contains("no gaps"), line)
        XCTAssertTrue(line.contains("Covered: this night arrived whole."), line)
    }

    /// A night with no heart rate at all must not be reported as merely sparse: there is nothing to score,
    /// and the sentence has to say that rather than imply a thin but usable night.
    func testLineSaysNoDataForAnEmptyNight() {
        let start = 1_700_000_000
        let end = start + 11 * 3_600
        let empty = NightCoverage.stats(seconds: [], samples: 0, windowStart: start, windowEnd: end)
        let line = NightCoverage.line(windowStart: start, windowEnd: end, hr: empty, rr: empty,
                                      timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(line.contains("NO DATA"), line)
        XCTAssertFalse(line.contains("INCOMPLETE"), line)
    }

    /// Project rule: no em-dash in log copy, on either platform.
    func testLineAndEverySentenceHaveNoEmDash() {
        let start = 1_700_000_000
        let end = start + 3_600
        let s = NightCoverage.stats(seconds: Array(start..<(start + 600)), samples: 600,
                                    windowStart: start, windowEnd: end)
        let line = NightCoverage.line(windowStart: start, windowEnd: end, hr: s, rr: s,
                                      timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertFalse(line.contains("\u{2014}"), line)
        for v in [NightCoverage.Verdict.empty, .sparse, .holed, .covered, .unknown] {
            XCTAssertFalse(NightCoverage.sentence(v, hr: s).contains("\u{2014}"))
        }
    }
}
