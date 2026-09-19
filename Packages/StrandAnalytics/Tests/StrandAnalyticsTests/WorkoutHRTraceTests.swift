import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Pins the live-workout HR chart shaping: bounded downsampling that keeps short sessions verbatim and
/// breaks the line at capture gaps, and a y-range framed by zone lines rather than 0…220.
final class WorkoutHRTraceTests: XCTestCase {

    private let start = 1_700_000_000

    private func samples(count: Int, from offset: Int = 0, bpm: (Int) -> Int = { _ in 120 }) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + offset + $0, bpm: bpm($0)) }
    }

    /// RHR 50 / HRmax 190 Karvonen set: edges 120, 134, 148, 162, 176, 190.
    private let zones = HRZones.zones(maxHR: 190, restingHR: 50)

    func testEmptyIsEmpty() {
        XCTAssertTrue(WorkoutHRTrace.downsample([], startSec: start).isEmpty)
    }

    func testShortSessionKeepsEverySample() {
        let s = samples(count: 120, bpm: { 100 + $0 % 7 })
        let pts = WorkoutHRTrace.downsample(s, startSec: start)
        XCTAssertEqual(pts.count, 120)
        XCTAssertEqual(pts.first?.offset, 0)
        XCTAssertEqual(pts.last?.offset, 119)
        XCTAssertEqual(pts.map(\.bpm), s.map { Double($0.bpm) })
        XCTAssertTrue(pts.allSatisfy { $0.segment == 0 })
    }

    func testLongSessionIsBoundedAndAveraged() {
        // Two hours at 1 Hz.
        let s = samples(count: 7200, bpm: { $0 % 2 == 0 ? 100 : 110 })
        let pts = WorkoutHRTrace.downsample(s, startSec: start, maxPoints: 600)
        XCTAssertLessThanOrEqual(pts.count, 600)
        XCTAssertGreaterThan(pts.count, 500)
        // 12 s buckets of alternating 100/110 average to 105.
        XCTAssertEqual(pts[3].bpm, 105, accuracy: 0.001)
        // Offsets ascend and stay within the session.
        XCTAssertEqual(pts.map(\.offset), pts.map(\.offset).sorted())
        XCTAssertLessThanOrEqual(pts.last!.offset, 7199)
    }

    func testGapStartsNewSegment() {
        let s = samples(count: 60) + samples(count: 60, from: 300)
        let pts = WorkoutHRTrace.downsample(s, startSec: start)
        XCTAssertEqual(Set(pts.map(\.segment)), [0, 1])
        XCTAssertEqual(pts.first(where: { $0.segment == 1 })?.offset, 300)
    }

    func testXTicksUseWholeMinuteSteps() {
        XCTAssertEqual(WorkoutHRTrace.xTicks(maxOffset: 60), [0, 60])
        XCTAssertEqual(WorkoutHRTrace.xTicks(maxOffset: 1800), [0, 600, 1200, 1800])
        XCTAssertEqual(WorkoutHRTrace.xTicks(maxOffset: 5000), [0, 1800, 3600])
        XCTAssertLessThanOrEqual(WorkoutHRTrace.xTicks(maxOffset: 40_000).count, 4)
    }

    func testBoundariesAreSixAscendingEdges() {
        XCTAssertEqual(WorkoutHRTrace.boundaries(zones), [120, 134, 148, 162, 176, 190])
    }

    func testYDomainFramesDataBetweenNeighbouringZoneLines() {
        // Data 138…155 sits between the 134 and 162 lines → 129…167 padded → snapped 125…170.
        let d = WorkoutHRTrace.yDomain(bpms: [138, 150, 155], zones: zones)
        XCTAssertEqual(d, 125...170)
        XCTAssertLessThanOrEqual(d.lowerBound, 134)
        XCTAssertGreaterThanOrEqual(d.upperBound, 162)
    }

    func testYDomainBelowZoneOneKeepsTheZoneOneLine() {
        let d = WorkoutHRTrace.yDomain(bpms: [80, 95], zones: zones)
        XCTAssertEqual(d.lowerBound, 75)
        XCTAssertGreaterThanOrEqual(d.upperBound, 120)
        XCTAssertLessThan(d.upperBound, 140)
    }

    func testYDomainIncludesLockedBand() {
        let d = WorkoutHRTrace.yDomain(bpms: [100, 110], zones: zones, lockedZone: 4)
        XCTAssertLessThanOrEqual(d.lowerBound, 100)
        XCTAssertGreaterThanOrEqual(d.upperBound, 176)
    }

    func testYDomainWithoutDataFramesTheZones() {
        let d = WorkoutHRTrace.yDomain(bpms: [], zones: zones)
        XCTAssertEqual(d, 115...195)
    }
}
