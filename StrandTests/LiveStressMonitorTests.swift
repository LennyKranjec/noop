import XCTest
@testable import Strand

/// E9: the live stress warning needs TWO consecutive readings at or above `highThreshold`. One high
/// ten-minute window (a phone call, a coffee) no longer turns the strip red; `current` still reports the
/// latest value for display.
@MainActor
final class LiveStressMonitorTests: XCTestCase {

    func testOneHighReadingDoesNotWarnTwoDo() {
        let high = LiveStressMonitor.highThreshold + 0.3
        var streak = 0
        streak = LiveStressMonitor.nextConsecutiveHigh(streak, reading: high)
        XCTAssertFalse(LiveStressMonitor.isSustainedHigh(latest: high, consecutiveHigh: streak))
        streak = LiveStressMonitor.nextConsecutiveHigh(streak, reading: high)
        XCTAssertTrue(LiveStressMonitor.isSustainedHigh(latest: high, consecutiveHigh: streak))
    }

    func testALowOrMissingReadingResetsTheStreak() {
        let high = LiveStressMonitor.highThreshold
        var streak = LiveStressMonitor.nextConsecutiveHigh(0, reading: high)
        streak = LiveStressMonitor.nextConsecutiveHigh(streak, reading: 1.2)
        XCTAssertEqual(streak, 0)
        streak = LiveStressMonitor.nextConsecutiveHigh(LiveStressMonitor.nextConsecutiveHigh(0, reading: high),
                                                       reading: nil)
        XCTAssertEqual(streak, 0, "no reading (moving, too little HR) is not a second high one")
        streak = LiveStressMonitor.nextConsecutiveHigh(streak, reading: high)
        XCTAssertFalse(LiveStressMonitor.isSustainedHigh(latest: high, consecutiveHigh: streak))
    }

    func testAStreakEndsTheMomentTheLatestReadingDrops() {
        XCTAssertFalse(LiveStressMonitor.isSustainedHigh(latest: 1.5, consecutiveHigh: 5))
    }

    /// Two high readings HOURS apart (the app was in the background between them) are not a streak: the
    /// second one starts it afresh.
    func testAHighReadingLongAfterThePreviousOneStartsANewStreak() {
        let high = LiveStressMonitor.highThreshold + 0.4
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LiveStressMonitor.nextConsecutiveHigh(0, reading: high, previousAt: nil, now: t0)
        XCTAssertEqual(first, 1)
        let later = t0.addingTimeInterval(3 * 3600)
        let second = LiveStressMonitor.nextConsecutiveHigh(first, reading: high, previousAt: t0, now: later)
        XCTAssertEqual(second, 1)
        XCTAssertFalse(LiveStressMonitor.isSustainedHigh(latest: high, consecutiveHigh: second))
    }

    /// A reading on the five-minute cadence — even a late one, within one and a half cadences — continues it.
    func testAReadingOnCadenceContinuesTheStreak() {
        let high = LiveStressMonitor.highThreshold
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let onTime = t0.addingTimeInterval(LiveStressMonitor.everySeconds)
        XCTAssertEqual(LiveStressMonitor.nextConsecutiveHigh(1, reading: high, previousAt: t0, now: onTime), 2)
        let late = t0.addingTimeInterval(LiveStressMonitor.streakGap)
        XCTAssertEqual(LiveStressMonitor.nextConsecutiveHigh(1, reading: high, previousAt: t0, now: late), 2)
        let skipped = t0.addingTimeInterval(LiveStressMonitor.streakGap + 1)
        XCTAssertEqual(LiveStressMonitor.nextConsecutiveHigh(1, reading: high, previousAt: t0, now: skipped), 1)
    }

    /// The shared stress curve is served from cache only on the same day and while younger than the max age.
    func testSharedStressCurveFreshness() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let maxAge = StressDayCurve.sharedMaxAge
        XCTAssertTrue(StressDayCurve.isFresh(memoDay: 5, at: t0, day: 5,
                                             now: t0.addingTimeInterval(maxAge - 1), maxAge: maxAge))
        XCTAssertFalse(StressDayCurve.isFresh(memoDay: 5, at: t0, day: 5,
                                              now: t0.addingTimeInterval(maxAge), maxAge: maxAge))
        XCTAssertFalse(StressDayCurve.isFresh(memoDay: 4, at: t0, day: 5, now: t0, maxAge: maxAge))
    }
}
