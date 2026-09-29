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

    // MARK: - HEALTH_V2 H1

    /// H1a: a window with less than half of its minutes carrying motion data cannot claim "at rest".
    func testMotionCoverageIsTheShareOfMinutesWithAGravitySample() {
        let from = 1_800_000_000, to = from + 600
        XCTAssertEqual(LiveStressMonitor.motionCoverage(gravityTs: [], from: from, to: to), 0)
        // One sample in each of the first four minutes (several in one minute count once): 4 of 10.
        let four = [from + 1, from + 2, from + 61, from + 130, from + 200]
        XCTAssertEqual(LiveStressMonitor.motionCoverage(gravityTs: four, from: from, to: to), 0.4, accuracy: 1e-9)
        XCTAssertLessThan(LiveStressMonitor.motionCoverage(gravityTs: four, from: from, to: to),
                          LiveStressMonitor.minMotionCoverage)
        // Every minute covered, and samples outside the window ignored.
        let all = (0..<10).map { from + $0 * 60 + 5 } + [from - 30, to + 30]
        XCTAssertEqual(LiveStressMonitor.motionCoverage(gravityTs: all, from: from, to: to), 1, accuracy: 1e-9)
    }

    /// H1b: words, and what it is measured from — never "2.3 of 3".
    func testTheSubtitleIsABandInWordsAndSaysHeartRateBased() {
        XCTAssertEqual(LiveStressMonitor.alertSubtitle(level: 2.4), "High · heart-rate based")
        XCTAssertEqual(LiveStressMonitor.alertSubtitle(level: 1.5), "Moderate · heart-rate based")
        XCTAssertEqual(LiveStressMonitor.alertSubtitle(level: 0.4), "Low · heart-rate based")
        XCTAssertFalse(LiveStressMonitor.alertSubtitle(level: 2.4).contains("of 3"))
        XCTAssertTrue(LiveStressMonitor.alertSubtitle(level: nil).hasPrefix("—"))
    }

    private func suite() -> UserDefaults {
        let name = "livestress.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// Owner decision: the full-screen alert is OFF on a fresh install and on an install that had it on.
    func testTheAlertScreenIsOffOnAFreshInstallAndOnAMigratedOne() {
        let fresh = suite()
        XCTAssertFalse(LiveStressMonitor.alertScreenEnabled(fresh))
        XCTAssertFalse(LiveStressMonitor.shared.claimScreenSlot(now: Date(), fresh))

        let migrated = suite()
        migrated.set(true, forKey: LiveStressMonitor.alertScreenEnabledKey)   // an older build's "on"
        XCTAssertFalse(LiveStressMonitor.alertScreenEnabled(migrated))
        XCTAssertFalse(LiveStressMonitor.shared.claimScreenSlot(now: Date(), migrated))
    }

    /// Turning it back on restores the alert, and the choice survives (the migration runs once).
    func testTurningItOnRestoresTheAlertWithADailyCapOfTwo() {
        let d = suite()
        XCTAssertFalse(LiveStressMonitor.alertScreenEnabled(d))
        LiveStressMonitor.setAlertScreenEnabled(true, d)
        XCTAssertTrue(LiveStressMonitor.alertScreenEnabled(d))
        // 08:00 local, so every slot below falls on the same local day whatever the test machine's zone.
        let now = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0,
                                        of: Date(timeIntervalSince1970: 1_800_000_000))!
        XCTAssertTrue(LiveStressMonitor.shared.claimScreenSlot(now: now, d))
        XCTAssertTrue(LiveStressMonitor.shared.claimScreenSlot(now: now.addingTimeInterval(3_700), d))
        XCTAssertFalse(LiveStressMonitor.shared.claimScreenSlot(now: now.addingTimeInterval(7_400), d),
                       "a third screen the same day is refused")
        XCTAssertTrue(LiveStressMonitor.shared.claimScreenSlot(now: now.addingTimeInterval(86_400 + 3_600), d),
                      "a new day has its own two")
    }

    func testTheDailyCapRuleIsPure() {
        XCTAssertTrue(LiveStressMonitor.screenAllowed(storedDay: nil, count: 0, today: "2026-09-29"))
        XCTAssertTrue(LiveStressMonitor.screenAllowed(storedDay: "2026-09-29", count: 1, today: "2026-09-29"))
        XCTAssertFalse(LiveStressMonitor.screenAllowed(storedDay: "2026-09-29", count: 2, today: "2026-09-29"))
        XCTAssertTrue(LiveStressMonitor.screenAllowed(storedDay: "2026-09-28", count: 2, today: "2026-09-29"))
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
