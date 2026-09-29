import XCTest
import CoreGraphics
@testable import StrandDesign

/// The two pure decisions behind a chart touch scrub:
///
/// 1. WHICH POINT the crosshair names for a finger position — a real sample, never a value interpolated
///    between two of them.
/// 2. WHOSE GESTURE a drag is — the chart's (sideways) or the enclosing ScrollView's (up/down). This used
///    to be a 0.25 s stationary long press, which a swipe fails by definition, so the charts appeared not
///    to scrub at all. The decision now rides the first 8 pt of travel, and these tests pin it.
final class TrendChartScrubGestureTests: XCTestCase {

    // MARK: Nearest real point

    private func day(_ d: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    private var threeDays: [Date] { [day(10), day(11), day(12)] }

    func testEmptySeriesHasNoNearestPoint() {
        XCTAssertNil(ChartHoverMath.nearestIndex(toDate: day(11), dates: []))
        XCTAssertNil(TrendChart.nearestPoint(toDate: day(11), in: []))
    }

    func testExactHitPicksThatPoint() {
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: day(11), dates: threeDays), 1)
    }

    func testBeforeTheFirstPointClampsToTheFirst() {
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: day(1), dates: threeDays), 0)
    }

    func testAfterTheLastPointClampsToTheLast() {
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: day(30), dates: threeDays), 2)
    }

    func testSnapsToTheCloserNeighbourNotBetweenThem() {
        // 4 h past the 11th: still the 11th's reading, not a blend of the 11th and the 12th.
        let justAfter11 = day(11).addingTimeInterval(4 * 3600)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: justAfter11, dates: threeDays), 1)
        // 4 h before the 12th: the 12th.
        let justBefore12 = day(12).addingTimeInterval(-4 * 3600)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: justBefore12, dates: threeDays), 2)
    }

    /// A finger exactly between two days must land on ONE of them, deterministically. Earlier wins, the
    /// same tie-break `CompareView`'s scrub uses, so two charts never disagree about the same position.
    func testExactMidpointTieSnapsToTheEarlierDay() {
        let midnightBetween = day(11).addingTimeInterval(12 * 3600)
        XCTAssertEqual(ChartHoverMath.nearestIndex(toDate: midnightBetween, dates: threeDays), 1)
    }

    /// The scrub readout must be a value the data actually contained. Given a series with a big step
    /// between two samples, every cursor position across the whole span reports one of the two — never
    /// anything in the gap.
    func testScrubbedValueIsAlwaysARecordedReadingNeverAnInterpolation() {
        let pts = [
            TrendPoint(date: day(10), value: 40),
            TrendPoint(date: day(11), value: 90),
        ]
        for step in 0...48 {
            let cursor = day(10).addingTimeInterval(Double(step) * 1800)
            guard let p = TrendChart.nearestPoint(toDate: cursor, in: pts) else {
                return XCTFail("no point for step \(step)")
            }
            XCTAssertTrue(p.value == 40 || p.value == 90, "interpolated \(p.value) at step \(step)")
        }
    }

    func testNearestPointSurvivesASingleSampleSeries() {
        let one = [TrendPoint(date: day(11), value: 61)]
        XCTAssertEqual(TrendChart.nearestPoint(toDate: day(1), in: one)?.value, 61)
        XCTAssertEqual(TrendChart.nearestPoint(toDate: day(30), in: one)?.value, 61)
    }

    // MARK: Axis decision

    func testMovementUnderTheThresholdIsUndecidedSoATapStillOpensTheMetric() {
        // A thumb tap jitters a few points. Nothing may be claimed at that distance, or every Trends card
        // would scrub instead of navigating.
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: .zero), .undecided)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 5, height: 0)), .undecided)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 0, height: 5)), .undecided)
        // 5,5 is 7.07 pt of travel — still short of 8.
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 5, height: 5)), .undecided)
    }

    func testASidewaysSwipeScrubs() {
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 20, height: 3)), .horizontal)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 9, height: 0)), .horizontal)
    }

    /// Right-to-left reads the series backwards and is just as much a scrub. The decision is on magnitude,
    /// so a negative translation must not fall through to the scroll view.
    func testARightToLeftSwipeAlsoScrubs() {
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: -20, height: 3)), .horizontal)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: -20, height: -3)), .horizontal)
    }

    func testAnUpOrDownSwipeIsLeftToThePageScroll() {
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 3, height: 20)), .vertical)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 3, height: -20)), .vertical)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 0, height: 9)), .vertical)
    }

    /// A perfect diagonal goes to the scroll view: a page that refuses to scroll is far more noticeable
    /// than a crosshair that doesn't appear, so the ambiguous case defers.
    func testAPerfectDiagonalDefersToTheScroll() {
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: 20, height: 20)), .vertical)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: -20, height: 20)), .vertical)
    }

    /// The gesture's own `minimumDistance` and this decision must fire on the same movement, or there is a
    /// band of travel where the drag is live but unclassified.
    func testThresholdMatchesTheGesturesMinimumDistance() {
        let d = ChartHoverMath.scrubMinimumDistance
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: d, height: 0)), .horizontal)
        XCTAssertEqual(ChartHoverMath.scrubAxis(translation: CGSize(width: d - 0.01, height: 0)), .undecided)
    }
}
