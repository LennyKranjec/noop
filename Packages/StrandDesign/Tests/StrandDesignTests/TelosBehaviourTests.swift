import XCTest
import SwiftUI
@testable import StrandDesign

/// Pure behaviour of the Telos 2.0 foundation: the honesty formatters, the haptic vocabulary and its
/// one-action-one-pattern gate, the compact-tile grid's column choice, the moment backdrop's unbounded
/// fill levels, and the micro-sparkline's gap handling. No UI, no clock, no device.
final class TelosBehaviourTests: XCTestCase {

    // MARK: Honesty formatting

    func testIntegerFormatNeverInventsANumber() {
        XCTAssertEqual(TelosFormat.integer(.nan), TelosType.absent)
        XCTAssertEqual(TelosFormat.integer(.infinity), TelosType.absent)
        XCTAssertEqual(TelosFormat.decimal(1)(.nan), TelosType.absent)
    }

    func testSignedDeltaUsesTrueMinusAndDistinguishesFlatFromMissing() {
        XCTAssertEqual(TelosFormat.signedDelta(-3), "\u{2212}3")
        XCTAssertEqual(TelosFormat.signedDelta(4), "+4")
        XCTAssertEqual(TelosFormat.signedDelta(0.2), "\u{00B1}0")          // rounds to 0 → flat
        XCTAssertEqual(TelosFormat.signedDelta(-0.04, digits: 1), "\u{00B1}0")
        XCTAssertEqual(TelosFormat.signedDelta(.nan), TelosType.absent)      // missing stays "—"
        XCTAssertEqual(TelosDelta.notComputed.displayText, TelosType.absent)
        XCTAssertEqual(TelosDelta.value(0.3, tone: .better).tone, .flat)     // "±0" is never "better"
        XCTAssertEqual(TelosDelta.value(5, tone: .worse).tone, .worse)
        XCTAssertEqual(TelosDelta.value(.nan, tone: .better), .notComputed)
    }

    func testConfidenceSolidIsTheOnlySolid() {
        XCTAssertTrue(TelosConfidence.solid.isSolid)
        XCTAssertFalse(TelosConfidence.building.isSolid)
        XCTAssertFalse(TelosConfidence.calibrating(done: 2, total: 4).isSolid)
    }

    // MARK: Haptic vocabulary

    func testEveryPatternIsWellFormed() {
        for haptic in TelosHaptic.allCases {
            let events = haptic.events
            XCTAssertFalse(events.isEmpty, "\(haptic) has no events")
            for event in events {
                XCTAssertTrue((0...1).contains(event.intensity), "\(haptic) intensity out of range")
                XCTAssertTrue((0...1).contains(event.sharpness), "\(haptic) sharpness out of range")
                XCTAssertGreaterThanOrEqual(event.offset, 0)
                XCTAssertLessThanOrEqual(event.offset + event.duration, 0.6, "\(haptic) runs too long")
            }
            // The reduced form keeps the information and drops the flourish: ONE immediate transient.
            let reduced = haptic.reducedEvents
            XCTAssertEqual(reduced.count, 1, "\(haptic) reduced form must be one transient")
            XCTAssertEqual(reduced.first?.offset, 0)
            XCTAssertEqual(reduced.first?.duration, 0)
        }
        // The named shapes.
        XCTAssertEqual(TelosHaptic.failure.events.count, 2)                 // a heavier two-beat
        XCTAssertGreaterThan(TelosHaptic.failure.events[0].intensity, TelosHaptic.success.events[0].intensity)
        let rise = TelosHaptic.levelSettle.events.filter { $0.duration == 0 }
        XCTAssertEqual(rise.count, 3)                                       // a slow three-step rise
        XCTAssertTrue(rise[0].intensity < rise[1].intensity && rise[1].intensity < rise[2].intensity)
        XCTAssertEqual(TelosHaptic.heartbeat.events.count, 2)               // lub-dub
    }

    func testLegacyNamesMapOntoTheVocabulary() {
        XCTAssertEqual(StrandHaptic.selection.telos, .select)
        XCTAssertEqual(StrandHaptic.light.telos, .tap)
        XCTAssertEqual(StrandHaptic.commit.telos, .commit)
        XCTAssertEqual(StrandHaptic.success.telos, .success)
        XCTAssertEqual(StrandHaptic.warning.telos, .warning)
    }

    func testGateOneActionOnePattern() {
        var gate = TelosHapticGate()
        XCTAssertTrue(gate.admit(.commit, at: 10.0))
        // A second pattern 40 ms later is the same action → dropped.
        XCTAssertFalse(gate.admit(.success, at: 10.04))
        // After the gap a different pattern plays.
        XCTAssertTrue(gate.admit(.success, at: 10.20))
    }

    func testGateDropsDoubleFires() {
        var gate = TelosHapticGate()
        XCTAssertTrue(gate.admit(.select, at: 1.0))
        XCTAssertFalse(gate.admit(.select, at: 1.15))    // a re-render firing it again
        XCTAssertTrue(gate.admit(.select, at: 1.40))     // a real second tap
    }

    func testGateHonoursActionKeysForASecond() {
        var gate = TelosHapticGate()
        XCTAssertTrue(gate.admit(.success, action: "moment.q1", at: 5.0))
        XCTAssertFalse(gate.admit(.success, action: "moment.q1", at: 5.5))
        XCTAssertFalse(gate.admit(.failure, action: "moment.q1", at: 5.9))
        XCTAssertTrue(gate.admit(.failure, action: "moment.q2", at: 5.9))
        XCTAssertTrue(gate.admit(.success, action: "moment.q1", at: 6.5))
    }

    func testGateRateLimitsTicksIndependently() {
        var gate = TelosHapticGate()
        XCTAssertTrue(gate.admit(.tick, at: 0.0))
        XCTAssertFalse(gate.admit(.tick, at: 0.038))     // 26 Hz typing: every other letter
        XCTAssertTrue(gate.admit(.tick, at: 0.080))
        XCTAssertTrue(gate.admit(.commit, at: 0.085))    // ticks don't block a real pattern
    }

    // MARK: Compact tile grid

    func testGridPicksColumnsFromWidth() {
        let minWidth = TelosTileGridLayout.defaultMinTileWidth   // 104
        let gap: CGFloat = 8
        // A 343 pt iPhone content width fits 3 × 104 + 2 × 8 = 328.
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: 343, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 6), 3)
        // Wider: capped at 4.
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: 900, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 6), 4)
        // Never more columns than tiles.
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: 900, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 2), 2)
        // Narrow: 2, then 1 — never 0.
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: 230, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 6), 2)
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: 50, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 6), 1)
        // Unknown width uses the cap.
        XCTAssertEqual(TelosTileGridLayout.columns(forWidth: .infinity, minTileWidth: minWidth, spacing: gap, maxColumns: 4, count: 6), 4)
    }

    func testGridReflowsToFewerColumnsAsTextGrows() {
        let base = TelosTileGridLayout.defaultMinTileWidth
        let width: CGFloat = 343
        let large = TelosTileGridLayout.columns(
            forWidth: width, minTileWidth: base * TelosTileGridLayout.widthScale(for: .large),
            spacing: 8, maxColumns: 4, count: 6)
        let xxxLarge = TelosTileGridLayout.columns(
            forWidth: width, minTileWidth: base * TelosTileGridLayout.widthScale(for: .xxxLarge),
            spacing: 8, maxColumns: 4, count: 6)
        XCTAssertGreaterThan(large, xxxLarge)
        XCTAssertEqual(TelosTileGridLayout.widthScale(for: .accessibility1), 1.6)
    }

    // MARK: Moment backdrop

    func testMomentFillIsUnboundedAndHonest() {
        // Absent / zero / non-finite → no liquid.
        XCTAssertEqual(TelosMomentStyle.levels(fraction: 0).level, 0)
        XCTAssertEqual(TelosMomentStyle.levels(fraction: .nan).level, 0)
        XCTAssertNil(TelosMomentStyle.levels(fraction: 0.5).hundred)
        // At or under 100 %: linear in the value, no 100 % marker.
        XCTAssertEqual(TelosMomentStyle.levels(fraction: 0.5).level, 0.45, accuracy: 1e-9)
        XCTAssertEqual(TelosMomentStyle.levels(fraction: 1).level, TelosMomentStyle.fullLevel, accuracy: 1e-9)
        XCTAssertNil(TelosMomentStyle.levels(fraction: 1).hundred)
        // Over 100 %: nothing clamps — the scale grows and a marker shows where 100 % sits.
        let over = TelosMomentStyle.levels(fraction: 1.5)
        XCTAssertEqual(over.level, TelosMomentStyle.fullLevel, accuracy: 1e-9)
        XCTAssertEqual(over.hundred ?? -1, TelosMomentStyle.fullLevel / 1.5, accuracy: 1e-9)
    }

    func testMomentDefaultsFollowItsKind() {
        let penalty = TelosMoment(id: "p.1", kind: .penalty, overline: "Missed", headline: "Walk 10,000 steps")
        XCTAssertEqual(penalty.tone, .critical)
        XCTAssertEqual(penalty.haptic, .failure)
        XCTAssertNil(penalty.fill)                                           // no value → no liquid
        let stress = TelosMoment(id: "s.1", kind: .stressDiagnostic, overline: "Stress", headline: "High")
        XCTAssertEqual(stress.register, .diagnostic)
        XCTAssertEqual(stress.haptic, .heartbeat)                            // the heart-moment pattern
        XCTAssertTrue(TelosMoment.showsBefore(stress, penalty))
        XCTAssertNil(TelosMoment.Kind.gearChoice.defaultHaptic)
    }

    // MARK: Micro-sparkline

    func testSparklineBreaksAtGapsAndNeverBridges() {
        let rect = CGRect(x: 0, y: 0, width: 30, height: 20)
        let points = TelosSparklineGeometry.points([1, 2, .nan, 4], in: rect)
        XCTAssertEqual(points.count, 4)
        XCTAssertNotNil(points[0])
        XCTAssertNil(points[2])
        // A single point is not a line.
        XCTAssertTrue(TelosSparklineGeometry.points([3], in: rect).allSatisfy { $0 == nil })
        // A flat series draws mid-height, not at the floor.
        let flat = TelosSparklineGeometry.points([5, 5, 5], in: rect)
        XCTAssertEqual(flat[0]?.y ?? -1, 10, accuracy: 1e-9)
    }
}
