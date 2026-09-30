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
        XCTAssertEqual(penalty.haptic, .penalty)
        XCTAssertEqual(penalty.entrance, .penalty)
        XCTAssertEqual(penalty.strapCue, .penalty)
        XCTAssertNil(penalty.fill)                                           // no value → no liquid
        let stress = TelosMoment(id: "s.1", kind: .stressDiagnostic, overline: "Stress", headline: "High")
        XCTAssertEqual(stress.register, .diagnostic)
        XCTAssertEqual(stress.haptic, .heartbeat)                            // the heart-moment pattern
        XCTAssertEqual(stress.entrance, .standard)
        XCTAssertTrue(TelosMoment.showsBefore(stress, penalty))
        XCTAssertNil(TelosMoment.Kind.gearChoice.defaultHaptic)
        // Big rewards celebrate, play the reward pattern and ask the strap for the reward cue.
        let rewards: [TelosMoment.Kind] = [.personalRecord, .questCompleted, .goalCompleted, .levelUp, .debtCleared]
        for kind in rewards {
            XCTAssertEqual(kind.defaultEntrance, .celebration, "\(kind)")
            XCTAssertEqual(kind.defaultHaptic, .reward, "\(kind)")
            XCTAssertEqual(kind.defaultStrapCue, .reward, "\(kind)")
        }
        XCTAssertEqual(TelosMoment.Kind.streakBroken.defaultStrapCue, .penalty)
        // A Lift finish celebrates but only buzzes the strap when the presenter says it holds a PR.
        XCTAssertEqual(TelosMoment.Kind.liftFinished.defaultEntrance, .celebration)
        XCTAssertNil(TelosMoment.Kind.liftFinished.defaultStrapCue)
        // A verdict is a reading, never a celebration.
        XCTAssertEqual(TelosMoment.Kind.trialVerdict.defaultEntrance, .standard)
    }

    // MARK: Decision 19 — clinical restraint (no glimmer, no bursts, no gold glow)

    func testRetiredBurstDrawsNothingAndPenaltyFlashIsGone() {
        XCTAssertFalse(TelosMomentBurst.drawsAnything)
        XCTAssertEqual(TelosMomentStyle.celebrationParticles, 0)
        XCTAssertEqual(TelosMomentStyle.penaltyParticles, 0)
        XCTAssertEqual(TelosMomentStyle.penaltyFlashOpacity, 0)
    }

    func testMomentLiquidIsNeutralForNeutralAndGoldTones() {
        // No decorative green (neutral) and no gold fill (a PR): both liquids are the neutral ink.
        XCTAssertEqual(TelosMomentStyle.liquidColor(.neutral), TelosColor.textTertiary)
        XCTAssertEqual(TelosMomentStyle.liquidColor(.gold), TelosColor.textTertiary)
        // Data tones keep their hue (colour is for data).
        XCTAssertEqual(TelosMomentStyle.liquidColor(.heart), TelosColor.heart)
        XCTAssertEqual(TelosMomentStyle.liquidColor(.critical), TelosColor.critical)
    }

    func testParticleTextureIsNeutralAndBarelyThere() {
        XCTAssertEqual(TelosParticleField.dotColor, TelosColor.textTertiary)
        XCTAssertLessThanOrEqual(TelosParticleField.maxDotOpacity, 0.04)
        let dots = TelosParticleField.makeParticles(count: 400, seed: 7, sizes: 1...2)
        XCTAssertTrue(dots.allSatisfy { TelosParticleField.dotOpacity($0.alpha) <= TelosParticleField.maxDotOpacity + 1e-12 })
        XCTAssertTrue(dots.allSatisfy { TelosParticleField.dotOpacity($0.alpha) >= 0 })
        XCTAssertEqual(TelosParticleField.dotOpacity(.nan), 0)
        XCTAssertLessThanOrEqual(TelosParticleField.dotOpacity(5), TelosParticleField.maxDotOpacity)
    }

    func testGlassHasNoTopGlowOrTintedGlow() {
        XCTAssertEqual(NoopPanelSurface.tintGlowOpacity, 0)
        XCTAssertEqual(TelosColor.Spec.glassGlow.dark.suffix(2), "00", "the retired top glow is transparent")
        XCTAssertEqual(TelosColor.Spec.glassGlow.light.suffix(2), "00")
    }

    func testMomentBurstIsShortAndEnds() {
        XCTAssertLessThanOrEqual(TelosMomentStyle.burstDuration, 1.5)
        XCTAssertEqual(TelosMomentStyle.burstProgress(elapsed: 0), 0)
        XCTAssertEqual(TelosMomentStyle.burstProgress(elapsed: -1), 0)
        XCTAssertEqual(TelosMomentStyle.burstProgress(elapsed: TelosMomentStyle.burstDuration), 1, accuracy: 1e-9)
        XCTAssertEqual(TelosMomentStyle.burstProgress(elapsed: 60), 1, accuracy: 1e-9)   // never loops
        let half = TelosMomentStyle.burstProgress(elapsed: TelosMomentStyle.burstDuration / 2)
        XCTAssertGreaterThan(half, 0.5)                                                  // eased out
    }

    func testCountingFigureFormats() {
        XCTAssertTrue(TelosMoment.Figure(label: "Level", value: "81", countFrom: 57, countTo: 81).counts)
        XCTAssertFalse(TelosMoment.Figure(label: "Level", value: "81").counts)
        XCTAssertFalse(TelosMoment.Figure(label: "Level", value: "81", countFrom: 81, countTo: 81).counts)
        XCTAssertFalse(TelosMoment.Figure(label: "Level", value: "81", countFrom: .nan, countTo: 81).counts)
        XCTAssertEqual(TelosMoment.CountFormat.signed(0).string(24), "+24")
        XCTAssertEqual(TelosMoment.CountFormat.signed(0).string(-3), "\u{2212}3")
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

    // MARK: Reward / penalty patterns

    func testRewardAndPenaltyPatterns() {
        let reward = TelosHaptic.reward.events.filter { $0.duration == 0 }
        XCTAssertEqual(reward.count, 3)
        XCTAssertTrue(reward[0].intensity < reward[1].intensity && reward[1].intensity < reward[2].intensity,
                      "the reward rises")
        func energy(_ h: TelosHaptic) -> Float { h.events.reduce(Float(0)) { $0 + $1.intensity } }
        XCTAssertGreaterThan(energy(.penalty), energy(.failure), "the penalty is heavier than a failure")
        let penaltySharpness: Float = TelosHaptic.penalty.events.map { $0.sharpness }.max() ?? 1
        let rewardSharpness: Float = TelosHaptic.reward.events.map { $0.sharpness }.max() ?? 0
        XCTAssertLessThan(penaltySharpness, rewardSharpness, "dull thuds vs a bright sparkle")
    }

    // MARK: Stepper

    func testStepperSnapsToTheCustomStepAndClamps() {
        XCTAssertEqual(TelosStepper.snapped(61.4, step: 2.5, range: 0...500), 62.5, accuracy: 1e-9)
        XCTAssertEqual(TelosStepper.snapped(40 + 8, step: 8, range: 0...200), 48, accuracy: 1e-9)
        XCTAssertEqual(TelosStepper.snapped(-5, step: 2.5, range: 0...500), 0)
        XCTAssertEqual(TelosStepper.snapped(510, step: 2.5, range: 0...500), 500)
        XCTAssertEqual(TelosStepper.snapped(150 + 15, step: 15, range: nil), 165, accuracy: 1e-9)   // rest ±15 s
        XCTAssertEqual(TelosStepper.snapped(.nan, step: 1, range: 1...20), 1)
    }

    // MARK: Particle field

    func testParticlesAreDeterministicAndBounded() {
        let a = TelosParticleField.makeParticles(count: 50, seed: 42, sizes: 1...2)
        let b = TelosParticleField.makeParticles(count: 50, seed: 42, sizes: 1...2)
        XCTAssertEqual(a.count, 50)
        XCTAssertEqual(a.map { $0.x }, b.map { $0.x })
        XCTAssertEqual(a.map { $0.y }, b.map { $0.y })
        XCTAssertTrue(a.allSatisfy { $0.x >= 0 && $0.x < 1 && $0.y >= 0 && $0.y < 1 && $0.size >= 1 && $0.size <= 2 })
        XCTAssertEqual(TelosParticleField.makeParticles(count: 5_000, seed: 1, sizes: 1...2).count, 400)
        XCTAssertNotEqual(TelosParticleField.makeParticles(count: 5, seed: 1, sizes: 1...2).map { $0.x },
                          TelosParticleField.makeParticles(count: 5, seed: 2, sizes: 1...2).map { $0.x })
    }
}
