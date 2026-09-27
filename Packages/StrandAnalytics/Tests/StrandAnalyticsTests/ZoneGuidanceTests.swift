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

    /// The shipped feel: a cue the wearer can act on, not one that arrives after the moment has passed.
    /// These two numbers used to be 10 s and 8 s and STACKED into a 15–20 s wait for the first correction;
    /// pinned here so a regression to anything that slow fails loudly rather than shipping as "late".
    func testDefaultTimingsAreTheFastOnes() {
        XCTAssertEqual(ZoneGuidance.defaultSettleSeconds, 3)
        XCTAssertEqual(ZoneGuidance.defaultCueInterval, 4)
        XCTAssertEqual(ZoneGuidance.defaultMarginBPM, 2)
        // First cue ≤ settle + one 1 Hz tick, repeats ≤ interval + one tick: the whole budget the wearer
        // feels, asserted as a budget rather than as an incidental consequence of the constants.
        XCTAssertLessThanOrEqual(ZoneGuidance.defaultSettleSeconds + 1, 4)
        XCTAssertLessThanOrEqual(ZoneGuidance.defaultCueInterval + 1, 5)
    }

    func testBelowStartsAfterSettleThenRepeatsEveryInterval() {
        var g = guidance()
        let cues = run(&g, bpm: 120, from: 0, to: 30)
        // First reading beyond the margin at t=0 opens the settle window; first cue at t=3, then every 4 s.
        XCTAssertEqual(cues.keys.sorted(), [3, 7, 11, 15, 19, 23, 27])
        XCTAssertTrue(cues.values.allSatisfy { $0 == .below })
        XCTAssertEqual(ZoneGuidance.Cue.below.buzzCount, 2)
    }

    func testAboveIsOneBuzz() {
        var g = guidance()
        let cues = run(&g, bpm: 165, from: 0, to: 5)
        XCTAssertEqual(cues, [3: .above])
        XCTAssertEqual(ZoneGuidance.Cue.above.buzzCount, 1)
    }

    /// THE reported bug, pinned from the decision side: a wearer holding a STEADY bpm outside the zone must
    /// keep being cued at the cadence. Nothing about the bpm changes here — every tick feeds the identical
    /// reading — because the real failure was that the owner only evaluated when the published bpm CHANGED
    /// (both HR publishers are change-guarded), so a steady effort got one cue and then silence. This type
    /// is driven by a 1 Hz clock now, and its contract is: ticks in, cues out on schedule.
    func testSteadyBpmOutsideKeepsCueingAtTheCadence() {
        var g = guidance()
        let cues = run(&g, bpm: 120, from: 0, to: 60)
        let times = cues.keys.sorted()
        // First cue inside the settle budget, then one every `cueInterval` for the whole minute — no
        // widening gaps, no single cue followed by silence.
        XCTAssertEqual(times.first, Int(ZoneGuidance.defaultSettleSeconds))
        XCTAssertEqual(times.count, 15)
        let gaps = Set(zip(times, times.dropFirst()).map { $1 - $0 })
        XCTAssertEqual(gaps, [Int(ZoneGuidance.defaultCueInterval)])
        XCTAssertTrue(cues.values.allSatisfy { $0 == .below })
        XCTAssertEqual(g.cueing, .below)
    }

    /// Same, on the ABOVE side and with a bpm that never moves: one buzz, repeating.
    func testSteadyBpmAboveKeepsCueingAtTheCadence() {
        var g = guidance()
        let cues = run(&g, bpm: 170, from: 0, to: 24)
        XCTAssertEqual(cues.keys.sorted(), [3, 7, 11, 15, 19, 23])
        XCTAssertTrue(cues.values.allSatisfy { $0 == .above })
    }

    /// A cue the owner could not play (another haptic pattern still on the motor) comes back on the NEXT
    /// tick, not a whole cadence later. The owner used to check its quiet-gap AFTER `update` had banked the
    /// cue, so a cue colliding with the workout-start buzz was lost outright.
    func testDeferredCueIsReofferedOnTheNextTick() {
        var g = guidance()
        XCTAssertNil(g.update(bpm: 120, now: at(0)))
        XCTAssertNil(g.update(bpm: 120, now: at(1)))
        XCTAssertNil(g.update(bpm: 120, now: at(2)))
        XCTAssertEqual(g.update(bpm: 120, now: at(3)), .below)   // first cue — pretend the motor was busy
        g.deferLastCue()
        XCTAssertEqual(g.update(bpm: 120, now: at(4)), .below)   // re-offered one tick later, not at t=7
        // And the cadence resumes from the cue that actually played.
        XCTAssertNil(g.update(bpm: 120, now: at(5)))
        XCTAssertNil(g.update(bpm: 120, now: at(7)))
        XCTAssertEqual(g.update(bpm: 120, now: at(8)), .below)
    }

    /// Deferring a repeat mid-run keeps the run; deferring with nothing running is inert.
    func testDeferIsInertWithNoRun() {
        var g = guidance()
        g.deferLastCue()
        XCTAssertEqual(g.cueing, .inside)
        XCTAssertTrue(run(&g, bpm: 140, from: 0, to: 20).isEmpty)
    }

    func testWithinMarginNeverStartsARun() {
        var g = guidance()
        // 132 is below the zone but by only 1 bpm (< the 2 bpm margin).
        XCTAssertTrue(run(&g, bpm: 132, from: 0, to: 60).isEmpty)
        XCTAssertNil(g.pendingSide)
    }

    func testDippingIntoTheMarginRestartsTheSettleWindow() {
        var g = guidance()
        XCTAssertTrue(run(&g, bpm: 128, from: 0, to: 2).isEmpty)
        XCTAssertNil(g.update(bpm: 132, now: at(3)))    // dead band → settle resets
        let cues = run(&g, bpm: 128, from: 4, to: 8)
        XCTAssertEqual(cues.keys.sorted(), [7])          // 3 s from the NEW start at t=4
    }

    func testReenteringStopsImmediately() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 5)
        XCTAssertEqual(g.cueing, .below)
        XCTAssertNil(g.update(bpm: 134, now: at(6)))
        XCTAssertEqual(g.cueing, .inside)
        // Dropping out again must settle afresh, not resume the old cadence.
        let cues = run(&g, bpm: 120, from: 7, to: 12)
        XCTAssertEqual(cues.keys.sorted(), [10])
    }

    /// Returning into the zone stops the buzzing within one tick — the owner's pump is 1 Hz, so the wearer
    /// feels silence about a second after they corrected, never a cue for a mistake they already fixed.
    func testReentryStopsWithinOneTick() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 6)            // cueing below, last cue at t=3
        XCTAssertNil(g.update(bpm: 140, now: at(7)))     // the very next tick after re-entry: silent
        XCTAssertEqual(g.cueing, .inside)
        XCTAssertNil(g.lastCueAt)
        XCTAssertTrue(run(&g, bpm: 140, from: 8, to: 40).isEmpty)
    }

    func testDeadBandKeepsARunningRunGoing() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 3)            // cue at 3
        let cues = run(&g, bpm: 132, from: 4, to: 10)   // still below, inside the margin
        XCTAssertEqual(cues, [7: .below])
    }

    func testCrossingSidesNeedsItsOwnSettle() {
        var g = guidance()
        _ = run(&g, bpm: 120, from: 0, to: 3)            // below run started
        let cues = run(&g, bpm: 170, from: 4, to: 8)
        XCTAssertEqual(cues, [7: .above])
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
