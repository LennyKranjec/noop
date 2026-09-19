import XCTest
@testable import StrandAnalytics

/// Pins the live-workout ZONE LOCK decision logic: hysteresis in (≥ margin for ≥ settle), instant stop
/// on re-entry, the cue cadence, and which cue each side plays. Pure — no BLE, no clock.
final class ZoneGuidanceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Zone 3 of a 190-HRmax set: 133…152.
    private func guidance() -> ZoneGuidance { ZoneGuidance(lower: 133, upper: 152) }

    /// Feed one sample per second from `from` to `to` (inclusive) at `bpm`; return the cues by second.
    private func run(_ g: inout ZoneGuidance, bpm: Double, from: Int, to: Int) -> [Int: ZoneGuidance.Cue] {
        var cues: [Int: ZoneGuidance.Cue] = [:]
        for s in from...to {
            if let c = g.update(bpm: bpm, now: at(TimeInterval(s))) { cues[s] = c }
        }
        return cues
    }

    func testInsideIsSilent() {
        var g = guidance()
        XCTAssertTrue(run(&g, bpm: 140, from: 0, to: 60).isEmpty)
        XCTAssertEqual(g.cueing, .inside)
    }

    func testEdgesCountAsInside() {
        var g = guidance()
        XCTAssertTrue(run(&g, bpm: 133, from: 0, to: 30).isEmpty)
        XCTAssertTrue(run(&g, bpm: 152, from: 31, to: 60).isEmpty)
    }

    func testBelowStartsAfterSettleThenRepeatsEveryInterval() {
        var g = guidance()
        let cues = run(&g, bpm: 120, from: 0, to: 30)
        // First reading beyond the margin at t=0 opens the settle window; first cue at t=10, then +8 s.
        XCTAssertEqual(cues.keys.sorted(), [10, 18, 26])
        XCTAssertTrue(cues.values.allSatisfy { $0 == .below })
        XCTAssertEqual(ZoneGuidance.Cue.below.buzzCount, 2)
    }

    func testAboveIsOneBuzz() {
        var g = guidance()
        let cues = run(&g, bpm: 165, from: 0, to: 12)
        XCTAssertEqual(cues, [10: .above])
        XCTAssertEqual(ZoneGuidance.Cue.above.buzzCount, 1)
    }

    func testWithinMarginNeverStartsARun() {
        var g = guidance()
        // 132 is below the zone but by only 1 bpm (< the 2 bpm margin).
        XCTAssertTrue(run(&g, bpm: 132, from: 0, to: 60).isEmpty)
        XCTAssertNil(g.pendingSide)
    }

    func testDippingIntoTheMarginRestartsTheSettleWindow() {
        var g = guidance()
        XCTAssertTrue(run(&g, bpm: 128, from: 0, to: 8).isEmpty)
        XCTAssertNil(g.update(bpm: 132, now: at(9)))    // dead band → settle resets
        let cues = run(&g, bpm: 128, from: 10, to: 25)
        XCTAssertEqual(cues.keys.sorted(), [20])         // 10 s from the NEW start at t=10
    }

    func testReenteringStopsImmediately() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 12)
        XCTAssertEqual(g.cueing, .below)
        XCTAssertNil(g.update(bpm: 134, now: at(13)))
        XCTAssertEqual(g.cueing, .inside)
        // Dropping out again must settle afresh, not resume the old cadence.
        let cues = run(&g, bpm: 120, from: 14, to: 30)
        XCTAssertEqual(cues.keys.sorted(), [24])
    }

    func testDeadBandKeepsARunningRunGoing() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 10)           // cue at 10
        let cues = run(&g, bpm: 132, from: 11, to: 20)  // still below, inside the margin
        XCTAssertEqual(cues, [18: .below])
    }

    func testCrossingSidesNeedsItsOwnSettle() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 10)           // below run started
        let cues = run(&g, bpm: 170, from: 11, to: 25)
        XCTAssertEqual(cues, [21: .above])
    }

    func testLostSignalResets() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 10)
        XCTAssertNil(g.update(bpm: nil, now: at(11)))
        XCTAssertEqual(g.cueing, .inside)
        XCTAssertNil(g.pendingSide)
    }

    func testResetClearsState() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 5)
        g.reset()
        XCTAssertNil(g.pendingSide)
        XCTAssertNil(g.pendingSince)
        XCTAssertNil(g.lastCueAt)
    }

    // MARK: - Slider geometry

    private func zoneSet() -> HRZoneSet {
        let edges = HRZones.zoneEdges
        let maxHR = 200.0
        let zones = (0..<5).map { i in
            HRZone(number: i + 1, lower: edges[i] * maxHR, upper: edges[i + 1] * maxHR,
                   lowerPct: edges[i], upperPct: edges[i + 1])
        }
        return HRZoneSet(zones: zones, maxHR: maxHR, source: "manual")
    }

    func testSliderSpanAndFraction() {
        let span = ZoneSliderGeometry.span(zoneSet())
        XCTAssertEqual(span, 100...200)
        XCTAssertEqual(ZoneSliderGeometry.fraction(bpm: 150, in: 100...200), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ZoneSliderGeometry.fraction(bpm: 80, in: 100...200), 0)
        XCTAssertEqual(ZoneSliderGeometry.fraction(bpm: 230, in: 100...200), 1)
    }

    func testWithinZone() {
        let set = zoneSet()
        // Zone 3 is 140–160 bpm on a 200 HRmax: 150 is its midpoint, 142 near its floor.
        XCTAssertEqual(ZoneSliderGeometry.withinZone(bpm: 150, set: set)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(ZoneSliderGeometry.withinZone(bpm: 142, set: set)!, 0.1, accuracy: 1e-9)
        XCTAssertNil(ZoneSliderGeometry.withinZone(bpm: 90, set: set))
    }

    // MARK: - Effort combine

    func testStrainTRIMPRoundTrip() {
        for e in [1.0, 10.0, 37.5, 80.0] {
            let t = StrainScorer.strainToTRIMP(e)
            XCTAssertEqual(StrainScorer.trimpToStrain(t), e, accuracy: 0.01)
        }
        XCTAssertEqual(StrainScorer.strainToTRIMP(0), 0)
    }

    func testCombinedStrainIsLogAdditive() {
        XCTAssertEqual(StrainScorer.combinedStrain(40, 0), 40, accuracy: 0.01)
        let both = StrainScorer.combinedStrain(40, 40)
        XCTAssertGreaterThan(both, 40)
        XCTAssertLessThan(both, 80)   // NOT the linear sum
        XCTAssertLessThanOrEqual(StrainScorer.combinedStrain(100, 100), StrainScorer.maxStrain)
    }
}
