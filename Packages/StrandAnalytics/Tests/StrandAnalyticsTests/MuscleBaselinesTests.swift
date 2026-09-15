import XCTest
@testable import StrandAnalytics

/// The muscle colour scale.
///
/// What these pin is the CONSTANCY, because that is the whole claim the card makes: a colour means the
/// same thing on any muscle in any month. A test that only checked "more volume is redder" would pass
/// just as happily on the ranking this replaced.
final class MuscleBaselinesTests: XCTestCase {

    func testAGroupWithTooLittleHistoryHasNoScaleAtAll() {
        // Freezing on a thin sample would be permanent, so it does not.
        XCTAssertNil(MuscleBaselines.derive(windows: Array(repeating: 1000, count: MuscleBaselines.minWindows - 1)))
        XCTAssertNotNil(MuscleBaselines.derive(windows: Array(repeating: 1000, count: MuscleBaselines.minWindows)))
    }

    func testAMuscleNeverTrainedIsNotFrozenAtZero() {
        // Otherwise its mean is 0 with no spread, and the first set the wearer ever does for it paints
        // it at the top of the scale for good.
        XCTAssertNil(MuscleBaselines.derive(windows: Array(repeating: 0, count: 200)))
    }

    func testANormalWeekSitsInTheMiddleOfTheScale() {
        let base = MuscleBaseline(mean: 4000, sd: 1000)
        XCTAssertEqual(MuscleBaselines.fraction(base, 4000), 0.5, accuracy: 1e-9)
    }

    func testTheEndsOfTheScaleAreTwoStandardDeviationsEitherSide() {
        let base = MuscleBaseline(mean: 4000, sd: 1000)
        XCTAssertEqual(MuscleBaselines.fraction(base, 2000), 0, accuracy: 1e-9)
        XCTAssertEqual(MuscleBaselines.fraction(base, 6000), 1, accuracy: 1e-9)
        // Past the end there is no further shade — the scale clips rather than running off.
        XCTAssertEqual(MuscleBaselines.fraction(base, 60_000), 1, accuracy: 1e-9)
        XCTAssertEqual(MuscleBaselines.fraction(base, 0), 0, accuracy: 1e-9)
    }

    func testTheSameZScoreIsTheSameColourOnDifferentMuscles() {
        // THE POINT OF THE WHOLE FILE. A calf that does 400 kg in a normal week and a chest that does
        // 8,000 must land on the same shade when each has had a normal week.
        let calves = MuscleBaseline(mean: 400, sd: 120)
        let chest = MuscleBaseline(mean: 8000, sd: 2400)
        XCTAssertEqual(
            MuscleBaselines.fraction(calves, 400 + 120),
            MuscleBaselines.fraction(chest, 8000 + 2400),
            accuracy: 1e-9
        )
    }

    func testAHeavyWeekDoesNotBecomeNormalBecauseTheNextWeekIsHeavier() {
        // The ranking this replaced could not tell these apart: in both, the group IS the peak.
        let base = MuscleBaseline(mean: 4000, sd: 1000)
        XCTAssertLessThan(MuscleBaselines.fraction(base, 5000), MuscleBaselines.fraction(base, 6000))
        XCTAssertLessThan(MuscleBaselines.fraction(base, 2500), 0.5)
    }

    func testAFlatHistoryGetsASpreadOnTheRightScale() throws {
        // sd = 0 exactly. Falling back to 1.0 would make a 4,000 kg week read as 4,000 SD from normal.
        let base = try XCTUnwrap(MuscleBaselines.derive(windows: Array(repeating: 4000, count: 60)))
        XCTAssertEqual(base.sd, 0, accuracy: 1e-9)
        XCTAssertEqual(base.safeSd, 2000, accuracy: 1e-9)
        XCTAssertEqual(MuscleBaselines.fraction(base, 4000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MuscleBaselines.fraction(base, 8000), 1, accuracy: 1e-9)
    }

    func testRestDaysAreInTheWindowsBecauseTheyAreInTheFigure() {
        // The card shows a trailing week on whatever day it is opened, so the distribution the colour is
        // judged against has to include the days that sum to little.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let windows = MuscleBaselines.rollingWindows(
            daily: ["2026-09-01": 1000, "2026-09-20": 500],
            calendar: calendar
        )
        XCTAssertEqual(windows.count, 20)
        XCTAssertEqual(windows.first, 1000)
        XCTAssertEqual(windows[6], 1000)
        XCTAssertEqual(windows[7], 0)
        XCTAssertEqual(windows.last, 500)
    }

    func testAGapInTheLogIsTimePassingNotTimeSkipped() {
        // Running over the ENTRIES rather than the calendar would turn a fortnight off into no time at
        // all, and the frozen spread would come out far tighter than the wearer's training really is.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let windows = MuscleBaselines.rollingWindows(
            daily: ["2026-01-01": 1000, "2026-06-01": 1000],
            calendar: calendar
        )
        XCTAssertEqual(windows.count, 152)
    }
}
