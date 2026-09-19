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
}
