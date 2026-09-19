import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// E1: a whole-DAY Effort integral only pays zone 1 (50–60 % HRmax) while the wearer is MOVING.
///
/// Since O6 put the Edwards zones on %HRmax, a seated day at 90–100 bpm sat half in zone 1 and scored
/// ~60–70/100 — a rest day reading like a training day. These fixtures pin the three day shapes the gate
/// must separate: a desk day (low), a walk day (moderate), a training day (high). Age 30 → HRmax 187
/// (Tanaka), so zone 1 is ≥ 93.5 bpm, zone 2 ≥ 112.2, zone 3 ≥ 130.9.
final class EffortDayMotionGateTests: XCTestCase {

    private let hrMax = 187.0
    private let rest = 55.0
    /// Minute-aligned epoch start so a segment boundary is a minute boundary.
    private let t0 = 1_700_006_400
    private let stepS = 5

    private struct Segment { let seconds: Int; let bpm: (Int) -> Int; let moving: Bool }

    /// Lay segments end to end at `stepS` cadence; gravity at the same cadence. A moving segment's wrist
    /// swings 0.5 g between records (well over the 0.20 walk floor); a still one wobbles 0.01 g.
    private func build(_ segments: [Segment]) -> (hr: [HRSample], grav: [GravitySample]) {
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var ts = t0
        var i = 0
        for seg in segments {
            let end = ts + seg.seconds
            while ts < end {
                hr.append(HRSample(ts: ts, bpm: seg.bpm(i)))
                let x = seg.moving ? (i % 2 == 0 ? 0.0 : 0.5) : (i % 2 == 0 ? 0.0 : 0.01)
                grav.append(GravitySample(ts: ts, x: x, y: 0.0, z: 1.0))
                ts += stepS
                i += 1
            }
        }
        return (hr, grav)
    }

    /// Seated hours at 90–100 bpm — half the samples above the zone-1 line — with a few short walks to
    /// the kitchen (8 moving minutes in all).
    private func deskSegments() -> [Segment] {
        let seated = Segment(seconds: 4 * 3600, bpm: { 90 + $0 % 11 }, moving: false)
        let stroll = Segment(seconds: 2 * 60, bpm: { _ in 100 }, moving: true)
        return [seated, stroll, seated, stroll, seated, stroll, seated, stroll]
    }

    private func dayScore(_ segs: [Segment], gated: Bool = true) -> Double {
        let d = build(segs)
        let gate: StrainScorer.Zone1Gate = gated ? .day(StrainScorer.movingMinutes(gravity: d.grav)) : .ungated
        return StrainScorer.strain(d.hr, maxHR: hrMax, restingHR: rest, zone1Gate: gate)!
    }

    func testDeskDayStaysLow() {
        let gated = dayScore(deskSegments())
        XCTAssertLessThanOrEqual(gated, 30.0, "a mostly seated day at 90–100 bpm must read as a rest day")
        // And the bug this closes: the same day ungated scores like a training day.
        XCTAssertGreaterThan(dayScore(deskSegments(), gated: false), 55.0)
    }

    func testWalkDayWithRealMotionLandsModerate() {
        let walk = Segment(seconds: 60 * 60, bpm: { _ in 105 }, moving: true)   // 56 % HRmax, zone 1
        let score = dayScore(deskSegments() + [walk])
        XCTAssertGreaterThanOrEqual(score, 40.0)
        XCTAssertLessThanOrEqual(score, 50.0)
    }

    func testTrainingDayScoresHigh() {
        let z2 = Segment(seconds: 30 * 60, bpm: { _ in 125 }, moving: true)     // 66.8 % HRmax
        let z3 = Segment(seconds: 30 * 60, bpm: { _ in 140 }, moving: true)     // 74.9 % HRmax
        XCTAssertGreaterThanOrEqual(dayScore(deskSegments() + [z2, z3]), 55.0)
    }

    /// Zones 2+ are never gated: a still wrist at 125 bpm (a spin bike, a rower) still pays in full.
    func testZoneTwoIsNeverGated() {
        let still = build([Segment(seconds: 30 * 60, bpm: { _ in 125 }, moving: false)])
        let gated = StrainScorer.strain(still.hr, maxHR: hrMax, restingHR: rest,
                                        zone1Gate: .day(StrainScorer.movingMinutes(gravity: still.grav)))
        let ungated = StrainScorer.strain(still.hr, maxHR: hrMax, restingHR: rest)
        XCTAssertEqual(gated!, ungated!, accuracy: 1e-9)
    }

    /// No motion information → zone 1 at half credit, not zero and not full.
    func testNilMotionHalvesZoneOne() {
        let d = build([Segment(seconds: 60 * 60, bpm: { _ in 100 }, moving: false)])
        let durations = StrainScorer.sampleDurationsMinutes(d.hr)
        let full = StrainScorer.edwardsTRIMP(d.hr, restingHR: rest, hrReserve: hrMax - rest,
                                             durations: durations)
        let half = StrainScorer.edwardsTRIMP(d.hr, restingHR: rest, hrReserve: hrMax - rest,
                                             durations: durations, zone1Gate: .day(nil))
        XCTAssertEqual(half, full * StrainScorer.unknownMotionZone1Weight, accuracy: 1e-9)
        XCTAssertNil(StrainScorer.movingMinutes(gravity: []))
    }

    /// A minute with no gravity at all is UNKNOWN (half), not still (zero).
    func testUncoveredMinuteIsHalfCredit() {
        let motion = StrainScorer.MotionMinutes(moving: [], covered: [])
        XCTAssertEqual(StrainScorer.zone1Credit(.day(motion), ts: t0), StrainScorer.unknownMotionZone1Weight)
        let still = StrainScorer.MotionMinutes(moving: [], covered: [t0 / 60])
        XCTAssertEqual(StrainScorer.zone1Credit(.day(still), ts: t0), 0.0)
        XCTAssertEqual(StrainScorer.zone1Credit(.ungated, ts: t0), 1.0)
    }

    /// Per-bout Effort is untouched: the default gate is `.ungated`, byte-identical to the old recipe.
    func testDefaultIsUngated() {
        let d = build(deskSegments())
        let implicit = StrainScorer.strain(d.hr, maxHR: hrMax, restingHR: rest)
        let explicit = StrainScorer.strain(d.hr, maxHR: hrMax, restingHR: rest, zone1Gate: .ungated)
        XCTAssertEqual(implicit!, explicit!, accuracy: 1e-12)
    }

    /// A detected bout's minutes count as moving even when the wrist barely registers it.
    func testBoutWindowsMarkMinutesMoving() {
        let d = build([Segment(seconds: 10 * 60, bpm: { _ in 100 }, moving: false)])
        let m = StrainScorer.movingMinutes(gravity: d.grav, bouts: [(start: t0, end: t0 + 299)])!
        XCTAssertTrue(m.moving.contains(t0 / 60))
        XCTAssertTrue(m.moving.contains(t0 / 60 + 4))
        XCTAssertFalse(m.moving.contains(t0 / 60 + 5))
    }
}
