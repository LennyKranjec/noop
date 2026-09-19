#if !os(watchOS)
import XCTest
import SwiftUI
@testable import StrandDesign

/// Deep Timeline annotation parity (#979 spin-off): the pure span-scoping that decides WHICH sleep
/// band and workout glyphs annotate a visible day window. These mirror the classic Today's picks
/// (longest overlapping sleep = the main night; edge-inclusive workout overlap), so the two whole-day
/// charts can never disagree about what a day looked like.
final class OverviewHRChartAnnotationTests: XCTestCase {

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
    private func sleep(_ lo: TimeInterval, _ hi: TimeInterval, label: String? = nil) -> OverviewHRChart.SleepSpan {
        .init(start: date(lo), end: date(hi), label: label)
    }
    private func workout(_ lo: TimeInterval, _ hi: TimeInterval) -> OverviewHRChart.WorkoutSpan {
        .init(start: date(lo), end: date(hi), symbol: "figure.run")
    }

    /// A day window: 86 400 s starting at t=100 000 (arbitrary epoch, values only matter relatively).
    private let day: ClosedRange<Date> = Date(timeIntervalSince1970: 100_000)...Date(timeIntervalSince1970: 186_400)

    // MARK: mainSleep — the main night, never a nap

    /// The LONGEST overlapping block wins, exactly like the classic Today: a 7h night beats a 40m nap.
    func testMainSleepPicksLongestOverlappingBlock() {
        let night = sleep(95_000, 120_200, label: "7:00")     // 25 200 s = 7h, straddles the day start
        let nap = sleep(150_000, 152_400, label: "0:40")      // 2 400 s afternoon nap
        let picked = OverviewHRChart.mainSleep([nap, night], overlapping: day)
        XCTAssertEqual(picked?.start, night.start)
        XCTAssertEqual(picked?.end, night.end)
        XCTAssertEqual(picked?.label, "7:00")
    }

    /// A night that merely STRADDLES the window edge still counts (the pre-midnight onset case #144
    /// lives on) — overlap, not containment.
    func testMainSleepKeepsStraddlingNight() {
        let night = sleep(80_000, 110_000)                    // starts well before the day, ends inside
        XCTAssertNotNil(OverviewHRChart.mainSleep([night], overlapping: day))
    }

    /// Blocks entirely OUTSIDE the window never band it — including exact edge-touching ones, which
    /// contribute zero visible band (mirrors Today's strict `>` / `<` sleep filter).
    func testMainSleepDropsNonOverlappingAndEdgeTouching() {
        let before = sleep(10_000, 50_000)
        let endsAtStart = sleep(90_000, 100_000)              // ends exactly at window start → zero band
        let startsAtEnd = sleep(186_400, 190_000)             // starts exactly at window end → zero band
        let after = sleep(200_000, 220_000)
        XCTAssertNil(OverviewHRChart.mainSleep([before, endsAtStart, startsAtEnd, after], overlapping: day))
    }

    /// Empty candidates → nil, never a fabricated band.
    func testMainSleepEmptyIsNil() {
        XCTAssertNil(OverviewHRChart.mainSleep([], overlapping: day))
    }

    // MARK: workouts — edge-inclusive overlap, order preserved

    /// Overlapping workouts are kept in their supplied order; disjoint ones are dropped.
    func testWorkoutsKeepsOverlappingInOrder() {
        let morning = workout(110_000, 113_600)
        let evening = workout(170_000, 173_600)
        let lastWeek = workout(10_000, 13_600)
        let kept = OverviewHRChart.workouts([morning, lastWeek, evening], overlapping: day)
        XCTAssertEqual(kept.map(\.start), [morning.start, evening.start])
    }

    /// Edge-TOUCHING workouts are kept (inclusive `>=` / `<=`, mirroring Today's workout filter — a
    /// session ending exactly at midnight still belongs to the day it filled).
    func testWorkoutsKeepsEdgeTouching() {
        let endsAtStart = workout(96_400, 100_000)            // ends exactly at the window start
        let startsAtEnd = workout(186_400, 190_000)           // starts exactly at the window end
        let kept = OverviewHRChart.workouts([endsAtStart, startsAtEnd], overlapping: day)
        XCTAssertEqual(kept.count, 2)
    }

    /// A workout spanning the WHOLE window (an ultra, a long hike) is kept.
    func testWorkoutsKeepsWindowSpanning() {
        let ultra = workout(90_000, 200_000)
        XCTAssertEqual(OverviewHRChart.workouts([ultra], overlapping: day).count, 1)
    }

    func testWorkoutsEmptyIsEmpty() {
        XCTAssertTrue(OverviewHRChart.workouts([], overlapping: day).isEmpty)
    }

    // MARK: workoutBands — shaded spans, merged + clipped to the visible window

    /// A workout fully inside the window keeps its exact bounds and both real edges get a rule.
    func testBandInsideWindowKeepsBothEdges() {
        let bands = OverviewHRChart.workoutBands([workout(110_000, 113_600)], clippedTo: day)
        XCTAssertEqual(bands, [OverviewHRChart.WorkoutBand(start: date(110_000), end: date(113_600),
                                     startsInWindow: true, endsInWindow: true)])
    }

    /// A workout straddling the window start is clipped there, and the cut edge gets NO start rule
    /// (it's the plot boundary, not when the session began). Same for the end.
    func testBandClipsToWindowAndDropsCutEdgeRules() {
        let bands = OverviewHRChart.workoutBands(
            [workout(95_000, 103_000), workout(185_000, 190_000)], clippedTo: day)
        XCTAssertEqual(bands, [
            OverviewHRChart.WorkoutBand(start: date(100_000), end: date(103_000), startsInWindow: false, endsInWindow: true),
            OverviewHRChart.WorkoutBand(start: date(185_000), end: date(186_400), startsInWindow: true, endsInWindow: false),
        ])
    }

    /// A window-spanning session becomes one full-width band with no rules at all.
    func testBandSpanningWindowHasNoRules() {
        let bands = OverviewHRChart.workoutBands([workout(90_000, 200_000)], clippedTo: day)
        XCTAssertEqual(bands, [OverviewHRChart.WorkoutBand(start: date(100_000), end: date(186_400),
                                     startsInWindow: false, endsInWindow: false)])
    }

    /// Overlapping (e.g. double-logged) and touching sessions merge into their union so the fill never
    /// doubles up; a separate later session stays its own band. Input order doesn't matter.
    func testBandsMergeOverlappingAndTouching() {
        let a = workout(110_000, 113_600)
        let b = workout(112_000, 115_000)       // overlaps a
        let c = workout(115_000, 116_000)       // touches b's end
        let d = workout(170_000, 173_600)       // separate
        let bands = OverviewHRChart.workoutBands([d, c, a, b], clippedTo: day)
        XCTAssertEqual(bands.map(\.start), [date(110_000), date(170_000)])
        XCTAssertEqual(bands.map(\.end), [date(116_000), date(173_600)])
    }

    /// A session nested entirely inside another doesn't shrink the union.
    func testBandsMergeNestedKeepsOuterEnd() {
        let bands = OverviewHRChart.workoutBands([workout(110_000, 120_000), workout(112_000, 113_000)],
                                                 clippedTo: day)
        XCTAssertEqual(bands.count, 1)
        XCTAssertEqual(bands.first?.end, date(120_000))
    }

    /// Out-of-window, edge-touching (zero visible width) and degenerate (end <= start) spans yield no band.
    func testBandsDropInvisibleAndDegenerate() {
        let bands = OverviewHRChart.workoutBands([
            workout(10_000, 13_600),        // last week
            workout(96_400, 100_000),       // ends exactly at the window start
            workout(186_400, 190_000),      // starts exactly at the window end
            workout(150_000, 150_000),      // zero-length
            workout(160_000, 150_000),      // inverted
        ], clippedTo: day)
        XCTAssertTrue(bands.isEmpty)
    }

    // MARK: workout(at:) — scrub tooltip lookup

    func testWorkoutAtFindsContainingSessionEdgesInclusive() {
        let run = OverviewHRChart.WorkoutSpan(start: date(110_000), end: date(113_600),
                                              symbol: "figure.run", label: "Running")
        XCTAssertEqual(OverviewHRChart.workout(at: date(110_000), in: [run])?.label, "Running")
        XCTAssertEqual(OverviewHRChart.workout(at: date(113_600), in: [run])?.label, "Running")
        XCTAssertNil(OverviewHRChart.workout(at: date(113_601), in: [run]))
    }

    func testWorkoutAtPrefersMostRecentlyStartedWhenOverlapping() {
        let ride = OverviewHRChart.WorkoutSpan(start: date(110_000), end: date(120_000),
                                               symbol: "figure.outdoor.cycle", label: "Cycling")
        let run = OverviewHRChart.WorkoutSpan(start: date(115_000), end: date(118_000),
                                              symbol: "figure.run", label: "Running")
        XCTAssertEqual(OverviewHRChart.workout(at: date(116_000), in: [run, ride])?.label, "Running")
        XCTAssertEqual(OverviewHRChart.workout(at: date(112_000), in: [run, ride])?.label, "Cycling")
    }
}
#endif
