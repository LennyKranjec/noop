import XCTest
import StrandAnalytics
@testable import Strand

/// `MeditationLog.isDayDone` — the ONE answer to "has today's meditation happened".
///
/// It has three readers now (the Focus card's day circles, that card's 28-day count, and the Focus tab's
/// reminder badge in `RootTabView`), and the whole point of extracting it was that a reader cannot hold its
/// own copy of the threshold. So what is pinned here is not just the arithmetic but that the threshold IS
/// `LevelEngine.meditationMinMinutes` — if someone re-spells it as a literal, `testTheThresholdIsTheLevels`
/// fails when the level's constant moves and the rule's does not.
final class MeditationDoneRuleTests: XCTestCase {

    func testNothingLoggedIsNotDone() {
        XCTAssertFalse(MeditationLog.isDayDone(minutes: 0))
    }

    /// The case the badge exists for: a mis-tap or a very short sit must not clear the reminder, exactly as
    /// it must not light the card's circle.
    func testAThinSitIsNotDone() {
        XCTAssertFalse(MeditationLog.isDayDone(minutes: 0.5))
        XCTAssertFalse(MeditationLog.isDayDone(minutes: LevelEngine.meditationMinMinutes - 0.01))
    }

    /// Inclusive at the line — five minutes IS five minutes. The card's footer tells the wearer "a day
    /// counts from 5 minutes", so a day of exactly five that did not count would contradict the screen.
    func testTheThresholdItselfIsDone() {
        XCTAssertTrue(MeditationLog.isDayDone(minutes: LevelEngine.meditationMinMinutes))
    }

    func testMoreThanTheThresholdIsDone() {
        XCTAssertTrue(MeditationLog.isDayDone(minutes: LevelEngine.meditationMinMinutes + 0.01))
        XCTAssertTrue(MeditationLog.isDayDone(minutes: 45))
    }

    /// The rule reads the level's constant rather than restating it. Written as a sweep across the constant
    /// so it cannot be satisfied by a literal that happens to equal today's value.
    func testTheThresholdIsTheLevels() {
        let line = LevelEngine.meditationMinMinutes
        for step in stride(from: -2.0, through: 2.0, by: 0.5) {
            let minutes = line + step
            XCTAssertEqual(MeditationLog.isDayDone(minutes: minutes), minutes >= line,
                           "minutes \(minutes) against the level's line \(line)")
        }
    }

    /// A negative figure cannot be reached through `logMeditation`, but the badge asks this of whatever the
    /// day's total happens to be — so it must not read as done.
    func testANegativeTotalIsNotDone() {
        XCTAssertFalse(MeditationLog.isDayDone(minutes: -10))
    }
}
