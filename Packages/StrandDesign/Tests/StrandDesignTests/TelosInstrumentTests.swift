import XCTest
import SwiftUI
@testable import StrandDesign

/// P2 · INS — pure tests for the instruments: the life orb's data mapping (incl. absent inputs and the
/// unbounded Level), its organ-blob geometry and eased pose, ring overflow maths, the bezel and linear scales, the
/// frame-clock gate, and the pinned chart callout.
final class TelosOrbMappingTests: XCTestCase {

    // MARK: Absent inputs → neutral, never invented

    func testNoInputsIsTheNeutralDimStillOrb() {
        let a = TelosOrbAppearance.from(TelosOrbInputs())
        XCTAssertTrue(a.isNeutral)
        XCTAssertNil(a.growth)
        XCTAssertEqual(a.size, TelosOrbAppearance.neutralSize)
        XCTAssertEqual(a.outerShells, 0)
        XCTAssertEqual(a.turbulence, TelosOrbAppearance.turbulenceRange.lowerBound, "calm, not agitated")
        XCTAssertEqual(a.pulsePeriod, TelosOrbAppearance.neutralPulsePeriod)
        XCTAssertEqual(a.orbitSpeed, TelosOrbAppearance.neutralOrbitSpeed)
        XCTAssertEqual(a.brightness, TelosOrbAppearance.emptyBrightness, accuracy: 1e-9, "dim, not a good-day glow")
        XCTAssertTrue(a.partWeights.isEmpty)
    }

    func testNonFiniteInputsCountAsAbsent() {
        let a = TelosOrbAppearance.from(TelosOrbInputs(level: .nan, stress: .infinity, heartRateBpm: .nan,
                                                       charge: -.infinity, effortRatio: .nan))
        XCTAssertTrue(a.isNeutral)
        XCTAssertEqual(a, TelosOrbAppearance.from(TelosOrbInputs()))
    }

    func testAZeroOrNegativeHeartRateIsNotAPulse() {
        XCTAssertFalse(TelosOrbAppearance.from(TelosOrbInputs(heartRateBpm: 0)).hasHeartRate)
        XCTAssertFalse(TelosOrbAppearance.from(TelosOrbInputs(heartRateBpm: -60)).hasHeartRate)
    }

    func testOneMissingChannelRestsAtItsNeutralWhileOthersAreDrawn() {
        let a = TelosOrbAppearance.from(TelosOrbInputs(level: 80, charge: 90))
        XCTAssertFalse(a.isNeutral)
        XCTAssertFalse(a.hasStress)
        XCTAssertEqual(a.turbulence, TelosOrbAppearance.turbulenceRange.lowerBound)
        XCTAssertFalse(a.hasHeartRate)
        XCTAssertEqual(a.pulsePeriod, TelosOrbAppearance.neutralPulsePeriod)
    }

    // MARK: Level — monotone and unbounded

    func testSizeAndGrowthAreStrictlyMonotoneInLevel() {
        let levels: [Double] = [0, 10, 50, 81, 100, 101, 150, 300, 1_000, 10_000, 1_000_000]
        let looks = levels.map { TelosOrbAppearance.from(TelosOrbInputs(level: $0)) }
        for i in 1..<looks.count {
            XCTAssertGreaterThan(looks[i].growth!, looks[i - 1].growth!, "growth at \(levels[i])")
            XCTAssertGreaterThan(looks[i].size, looks[i - 1].size, "size at \(levels[i])")
        }
    }

    func testLevelIsNeverClampedAtAHighValue() {
        let high = TelosOrbAppearance.from(TelosOrbInputs(level: 100_000))
        let higher = TelosOrbAppearance.from(TelosOrbInputs(level: 200_000))
        XCTAssertGreaterThan(higher.growth!, high.growth!)
        XCTAssertGreaterThan(higher.outerShells, high.outerShells)
        XCTAssertGreaterThan(higher.size, high.size)
    }

    func testReferenceRangeAndShells() {
        XCTAssertEqual(TelosOrbAppearance.growth(level: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.growth(level: 100), 1, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.growth(level: 300), 2, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(level: 100)).size,
                       TelosOrbAppearance.sizeAtReference, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(level: 100)).outerShells, 0, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(level: 300)).outerShells, 1, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(level: 700)).outerShells, 2, accuracy: 1e-12)
    }

    func testDensityRisesWithLevelAndFallsWhileProvisional() {
        let low = TelosOrbAppearance.from(TelosOrbInputs(level: 10))
        let ref = TelosOrbAppearance.from(TelosOrbInputs(level: 100))
        XCTAssertLessThan(low.density, ref.density)
        XCTAssertEqual(ref.density, 1, accuracy: 1e-12)
        let building = TelosOrbAppearance.from(TelosOrbInputs(level: 100, charge: 80, confidence: .building))
        let calibrating = TelosOrbAppearance.from(TelosOrbInputs(level: 100, charge: 80,
                                                                 confidence: .calibrating(done: 1, total: 7)))
        let solid = TelosOrbAppearance.from(TelosOrbInputs(level: 100, charge: 80))
        XCTAssertLessThan(calibrating.density, building.density)
        XCTAssertLessThan(building.density, solid.density)
        XCTAssertLessThan(calibrating.brightness, solid.brightness, "provisional = dimmer")
        XCTAssertLessThan(calibrating.assembly, 1)
    }

    // MARK: Parts, stress, heart, charge, effort

    func testPartSharesNormaliseAndDropInvalidParts() {
        let a = TelosOrbAppearance.from(TelosOrbInputs(partShares: [.sleep: 30, .heart: 10, .lungs: 0,
                                                                    .muscle: .nan, .focus: -4]))
        XCTAssertEqual(Set(a.partWeights.keys), [.sleep, .heart])
        XCTAssertEqual(a.partWeights[.sleep]!, 0.75, accuracy: 1e-12)
        XCTAssertEqual(a.partWeights[.heart]!, 0.25, accuracy: 1e-12)
        XCTAssertFalse(a.isNeutral)
    }

    func testStressDrivesTurbulenceMonotonicallyWithinTheBoundedScale() {
        let t = [0.0, 1.0, 2.0, 3.0].map { TelosOrbAppearance.from(TelosOrbInputs(stress: $0)).turbulence }
        XCTAssertEqual(t.first!, TelosOrbAppearance.turbulenceRange.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(t.last!, TelosOrbAppearance.turbulenceRange.upperBound, accuracy: 1e-12)
        for i in 1..<t.count { XCTAssertGreaterThan(t[i], t[i - 1]) }
    }

    func testHeartRateSetsTheSlowedPulse() {
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(heartRateBpm: 60)).pulsePeriod, 6, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(heartRateBpm: 120)).pulsePeriod, 3, accuracy: 1e-12)
    }

    func testChargeDrivesBrightness() {
        let low = TelosOrbAppearance.from(TelosOrbInputs(charge: 10)).brightness
        let high = TelosOrbAppearance.from(TelosOrbInputs(charge: 95)).brightness
        XCTAssertLessThan(low, high)
        XCTAssertEqual(TelosOrbAppearance.from(TelosOrbInputs(charge: 100)).brightness,
                       TelosOrbAppearance.brightnessRange.upperBound, accuracy: 1e-12)
    }

    func testEffortRatioSpinsTheOrbitsWithoutACap() {
        let s = [0.0, 1.0, 2.0, 5.0].map { TelosOrbAppearance.from(TelosOrbInputs(effortRatio: $0)).orbitSpeed }
        XCTAssertEqual(s[0], 0.4, accuracy: 1e-12)
        XCTAssertEqual(s[1], 1.2, accuracy: 1e-12)
        for i in 1..<s.count { XCTAssertGreaterThan(s[i], s[i - 1]) }
    }

    // MARK: The organ blob — geometry built once, lobes from the part shares

    private func look(_ inputs: TelosOrbInputs) -> TelosOrbAppearance { TelosOrbAppearance.from(inputs) }

    private func form(_ inputs: TelosOrbInputs, style: TelosOrb.Style = .hero) -> TelosOrbForm {
        let a = look(inputs)
        return TelosOrbGeometry.form(appearance: a, turbulence: a.turbulence, density: a.density, style: style)
    }

    func testFormIsDeterministic() {
        let inputs = TelosOrbInputs(level: 64, partShares: [.sleep: 30, .heart: 20, .muscle: 18], stress: 1.2)
        XCTAssertEqual(form(inputs), form(inputs))
        XCTAssertEqual(form(inputs, style: .compact), form(inputs, style: .compact))
    }

    func testEachPartWithAShareGetsExactlyOneLobeInItsColour() {
        let f = form(TelosOrbInputs(partShares: [.sleep: 30, .heart: 10, .lungs: 0, .muscle: .nan, .focus: 5]))
        XCTAssertNil(f.lobes[0].part, "index 0 is the core")
        let parts = f.lobes.compactMap(\.part)
        XCTAssertEqual(Set(parts), [.sleep, .heart, .focus], "absent / zero / invalid parts have no lobe")
        XCTAssertEqual(parts.count, 3)
        for lobe in f.lobes where lobe.part != nil {
            XCTAssertEqual(lobe.colorIndex, TelosOrbGeometry.colorIndex(of: lobe.part!))
        }
    }

    func testLobeSizeGrowsWithTheShare() {
        let f = form(TelosOrbInputs(partShares: [.sleep: 40, .heart: 20, .focus: 5]))
        func r(_ p: TelosOrbPart) -> Double { f.lobes.first(where: { $0.part == p })!.r }
        XCTAssertGreaterThan(r(.sleep), r(.heart))
        XCTAssertGreaterThan(r(.heart), r(.focus))
        XCTAssertEqual(TelosOrbGeometry.lobeRadius(share: 0), 0)
        XCTAssertEqual(TelosOrbGeometry.lobeRadius(share: .nan), 0)
        let shares = [0.01, 0.05, 0.1, 0.2, 0.4, 0.8, 1.0]
        for i in 1..<shares.count {
            XCTAssertGreaterThan(TelosOrbGeometry.lobeRadius(share: shares[i]),
                                 TelosOrbGeometry.lobeRadius(share: shares[i - 1]))
        }
    }

    func testNoSharesDrawsTheTintsUnlabelledLobesNotParts() {
        let f = form(TelosOrbInputs(level: 50))
        XCTAssertTrue(f.lobes.allSatisfy { $0.part == nil && $0.colorIndex == 0 }, "no part is implied")
        XCTAssertGreaterThan(f.lobes.count, 1, "still an organic blob, not a disc")
    }

    func testMembraneEnclosesTheCoreAndIsNotACircle() {
        let f = form(TelosOrbInputs(level: 80, partShares: [.sleep: 30, .heart: 22, .muscle: 20, .lungs: 12, .focus: 9]))
        XCTAssertEqual(f.outline.count, TelosOrbGeometry.outlineSamples)
        XCTAssertTrue(f.outline.allSatisfy { $0 >= TelosOrbGeometry.coreRadius * 0.9 })
        XCTAssertGreaterThan(f.outline.max()! - f.outline.min()!, 0.1, "lobed, not a sphere")
        XCTAssertFalse(f.membrane.isEmpty)
    }

    func testStressRipplesTheMembrane() {
        let lobes = TelosOrbGeometry.lobes(for: look(TelosOrbInputs(partShares: [.sleep: 1, .heart: 1])))
        func roughness(_ turbulence: Double) -> Double {
            let r = TelosOrbGeometry.outline(lobes: lobes, turbulence: turbulence).radii
            return r.indices.reduce(0) { $0 + abs(r[$1] - r[($1 + 1) % r.count]) }
        }
        XCTAssertGreaterThan(roughness(1.0), roughness(0.12))
    }

    func testDotBudgetAndDensity() {
        for style in [TelosOrb.Style.hero, .compact] {
            let full = TelosOrbGeometry.form(appearance: look(TelosOrbInputs(level: 500)), turbulence: 0.12,
                                             density: 1, style: style)
            XCTAssertLessThanOrEqual(full.dotCount, TelosOrbGeometry.maxDots)
            XCTAssertLessThanOrEqual(full.dots.count, TelosOrbPart.allCases.count * TelosOrbGeometry.tiers + TelosOrbGeometry.tiers,
                                     "dots are batched: at most colour × tier fills")
            let half = TelosOrbGeometry.form(appearance: look(TelosOrbInputs(level: 500)), turbulence: 0.12,
                                             density: 0.5, style: style)
            XCTAssertLessThan(half.dotCount, full.dotCount)
        }
        XCTAssertLessThan(form(TelosOrbInputs(level: 5)).dotCount, form(TelosOrbInputs(level: 100)).dotCount,
                          "a higher Level fills the blob with more dots")
    }

    func testProvisionalLevelHasAFainterMembrane() {
        XCTAssertEqual(form(TelosOrbInputs(level: 80)).assembly, 1)
        XCTAssertLessThan(form(TelosOrbInputs(level: 80, confidence: .calibrating(done: 1, total: 7))).assembly, 1)
    }

    // MARK: Lobe glyphs

    func testLobeGlyphsAreLegibleOrAbsent() {
        XCTAssertNil(TelosOrbRenderer.glyphSide(lobeRadiusPoints: 10), "a small lobe keeps its plain nucleus")
        XCTAssertNil(TelosOrbRenderer.glyphSide(lobeRadiusPoints: .nan))
        XCTAssertNil(TelosOrbRenderer.glyphSide(lobeRadiusPoints: 0))
        let side = TelosOrbRenderer.glyphSide(lobeRadiusPoints: 25)
        XCTAssertNotNil(side)
        XCTAssertGreaterThanOrEqual(side ?? 0, TelosOrbRenderer.minGlyphSide)
        XCTAssertEqual(TelosOrbRenderer.glyphSide(lobeRadiusPoints: 500), TelosOrbRenderer.maxGlyphSide)
    }

    func testThumbnailOrbsCarryNoGlyphsButTheHeroDoes() {
        // An 84 pt history thumbnail: even a dominant lobe is too small for a legible glyph.
        let thumbUnit = TelosOrbRenderer.unitScale(dim: 84, size: TelosOrbAppearance.sizeAtReference)
        XCTAssertNil(TelosOrbRenderer.glyphSide(lobeRadiusPoints: TelosOrbGeometry.lobeRadius(share: 0.3) * thumbUnit))
        // The 214 pt Home orb at a typical Level: a typical 20 % lobe carries one.
        let heroUnit = TelosOrbRenderer.unitScale(dim: 214, size: TelosOrbAppearance.from(TelosOrbInputs(level: 64)).size)
        XCTAssertNotNil(TelosOrbRenderer.glyphSide(lobeRadiusPoints: TelosOrbGeometry.lobeRadius(share: 0.2) * heroUnit))
    }

    func testEveryPartHasItsOwnSymbol() {
        XCTAssertEqual(Set(TelosOrbPart.allCases.map(\.symbolName)).count, TelosOrbPart.allCases.count)
    }

    // MARK: Motion — transforms only, eased bursts, ≤ 20 fps

    func testTheOrbClockIsCappedAtTwentyFramesPerSecond() {
        XCTAssertGreaterThanOrEqual(TelosOrb.frameInterval, 1.0 / 20.0 - 1e-12)
    }

    func testBurstEnvelopeStartsAndEndsAtRest() {
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: 0, burst: 8), 0)
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: 4, burst: 8), 1, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: 8, burst: 8), 0, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: 12, burst: 8), 0)
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: .nan, burst: 8), 0)
        XCTAssertEqual(TelosOrbPose.envelope(elapsed: 60, burst: nil), 1, accuracy: 1e-12)
        XCTAssertEqual(TelosOrbPose.at(elapsed: 8, burst: 8, pulsePeriod: 6, turbulence: 1), .rest,
                       "the still frame after a burst is the pose it ended in")
        XCTAssertEqual(TelosOrbPose.at(elapsed: 0, burst: nil, pulsePeriod: 6, turbulence: 0.5), .rest)
    }

    func testPoseStaysGentle() {
        for t in stride(from: 0.0, through: 30, by: 0.37) {
            let p = TelosOrbPose.at(elapsed: t, burst: nil, pulsePeriod: 3, turbulence: 1)
            XCTAssertEqual(p.scaleX, 1, accuracy: 0.05)
            XCTAssertEqual(p.scaleY, 1, accuracy: 0.05)
            XCTAssertLessThanOrEqual(abs(p.rotation), 0.09)
        }
    }
}

final class TelosRingMathTests: XCTestCase {

    func testLapsAreNotClampedAboveOneLap() {
        XCTAssertEqual(TelosRingMath.laps(value: 134, scale: 100)!, 1.34, accuracy: 1e-12)
        XCTAssertEqual(TelosRingMath.laps(value: 67.7, scale: 100)!, 0.677, accuracy: 1e-12)
    }

    func testAbsentAndDegenerateInputs() {
        XCTAssertNil(TelosRingMath.laps(value: nil, scale: 100))
        XCTAssertNil(TelosRingMath.laps(value: .nan, scale: 100))
        XCTAssertNil(TelosRingMath.laps(value: 50, scale: 0))
        XCTAssertNil(TelosRingMath.laps(value: 50, scale: .infinity))
        XCTAssertEqual(TelosRingMath.laps(value: -5, scale: 100), 0, "below zero draws no arc")
    }

    func testLapFractionsDrawOverflowAsFurtherLaps() {
        XCTAssertEqual(TelosRingMath.lapFractions(0), [0])
        XCTAssertEqual(TelosRingMath.lapFractions(0.5), [0.5])
        XCTAssertEqual(TelosRingMath.lapFractions(1), [1])
        let over = TelosRingMath.lapFractions(1.34)
        XCTAssertEqual(over.count, 2)
        XCTAssertEqual(over[0], 1)
        XCTAssertEqual(over[1], 0.34, accuracy: 1e-12)
        XCTAssertEqual(TelosRingMath.lapFractions(2), [1, 1])
        XCTAssertEqual(TelosRingMath.lapFractions(3.7), [1, 1, 1])
    }

    func testOverflowFlags() {
        XCTAssertFalse(TelosRingMath.overflows(1), "exactly one lap is full, not overflow")
        XCTAssertTrue(TelosRingMath.overflows(1.01))
        XCTAssertFalse(TelosRingMath.exceedsDrawnLaps(3))
        XCTAssertTrue(TelosRingMath.exceedsDrawnLaps(3.7), "the lap label must state the rest")
    }

    func testLapGeometry() {
        let d: CGFloat = 100, lw: CGFloat = 5
        let r0 = TelosRingMath.radius(forLap: 0, diameter: d, lineWidth: lw)
        let r1 = TelosRingMath.radius(forLap: 1, diameter: d, lineWidth: lw)
        XCTAssertLessThan(r0 + lw * 1.3, d / 2 + 0.001, "the halo fits the frame")
        XCTAssertEqual(r0 - r1, TelosRingMath.lapStep(lineWidth: lw), accuracy: 1e-9)
        // A quarter lap ends at 3 o'clock.
        let tip = TelosRingMath.tipPoint(laps: 0.25, diameter: d, lineWidth: lw)
        XCTAssertEqual(tip.x, d / 2 + r0, accuracy: 1e-6)
        XCTAssertEqual(tip.y, d / 2, accuracy: 1e-6)
    }

    func testDefaultLineWidthIsThin() {
        XCTAssertEqual(TelosRingMath.defaultLineWidth(diameter: 10), 2)
        XCTAssertEqual(TelosRingMath.defaultLineWidth(diameter: 1_000), 9)
        XCTAssertEqual(TelosRingMath.defaultLineWidth(diameter: 100), 5.5, accuracy: 1e-9)
    }
}

final class TelosScaleMathTests: XCTestCase {

    func testSegmentsLightToTheValue() {
        let s = TelosScaleMath.segments(value: 92, scale: 100, count: 10)
        XCTAssertEqual(s.lit, 9)
        XCTAssertEqual(s.partial, 0.2, accuracy: 1e-9)
        XCTAssertFalse(s.overflow)
        XCTAssertFalse(s.absent)
        XCTAssertEqual(TelosScaleMath.segments(value: 100, scale: 100, count: 10).lit, 10)
    }

    func testSegmentsOverflowAndAbsence() {
        let over = TelosScaleMath.segments(value: 118, scale: 100, count: 10)
        XCTAssertTrue(over.overflow)
        XCTAssertEqual(over.lit, 10)
        let none = TelosScaleMath.segments(value: nil, scale: 100, count: 10)
        XCTAssertTrue(none.absent)
        XCTAssertEqual(none.lit, 0)
        XCTAssertTrue(TelosScaleMath.segments(value: .nan, scale: 100, count: 10).absent)
    }

    func testBarDrawsTheOverflowAsASecondLap() {
        let within = TelosScaleMath.bar(value: 62, scale: 100)!
        XCTAssertEqual(within.fill, 0.62, accuracy: 1e-12)
        XCTAssertEqual(within.overflow, 0)
        let over = TelosScaleMath.bar(value: 134, scale: 100)!
        XCTAssertEqual(over.fill, 1)
        XCTAssertEqual(over.overflow, 0.34, accuracy: 1e-12)
        XCTAssertFalse(over.beyondSecondLap)
        XCTAssertTrue(TelosScaleMath.bar(value: 250, scale: 100)!.beyondSecondLap)
        XCTAssertNil(TelosScaleMath.bar(value: nil, scale: 100))
    }

    func testFiniteRunsBreakAtGaps() {
        XCTAssertEqual(TelosScaleMath.finiteRuns([1, 2, .nan, 4, 5, 6, .nan]), [0...1, 3...5])
        XCTAssertEqual(TelosScaleMath.finiteRuns([.nan, 3, .nan]), [1...1])
        XCTAssertEqual(TelosScaleMath.finiteRuns([]), [])
    }

    func testSmoothPathNeverOvershootsTheData() {
        let pts = [CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 90), CGPoint(x: 20, y: 5),
                   CGPoint(x: 30, y: 95), CGPoint(x: 40, y: 50)]
        let box = TelosScaleMath.smoothPath(pts).boundingRect
        XCTAssertGreaterThanOrEqual(box.minY, 5 - 1e-6)
        XCTAssertLessThanOrEqual(box.maxY, 95 + 1e-6)
    }

    func testBezelTicksAndOutOfRange() {
        XCTAssertEqual(TelosBezelMath.ticks(majorCount: 4, minorPerMajor: 5).count, 20, "closed dial: no duplicate")
        let open = TelosBezelMath.ticks(majorCount: 4, minorPerMajor: 5, startDegrees: 150, spanDegrees: 240)
        XCTAssertEqual(open.count, 21)
        XCTAssertEqual(open.filter(\.isMajor).count, 5)
        let inside = TelosBezelMath.position(of: 1.5, in: 0...3)!
        XCTAssertEqual(inside.fraction, 0.5, accuracy: 1e-12)
        XCTAssertFalse(inside.outOfRange)
        let beyond = TelosBezelMath.position(of: 3.6, in: 0...3)!
        XCTAssertEqual(beyond.fraction, 1)
        XCTAssertTrue(beyond.outOfRange, "beyond the scale is marked, not silently pinned")
        XCTAssertNil(TelosBezelMath.position(of: nil, in: 0...3))
    }
}

final class TelosFrameGateTests: XCTestCase {

    func testLiveOnlyWhenEveryConditionHolds() {
        XCTAssertEqual(TelosFrameGate.mode(requested: true, visible: true, offscreen: false, covered: false,
                                           poseStill: false), .live)
    }

    func testEachConditionAloneStillsTheClock() {
        func mode(requested: Bool = true, visible: Bool = true, offscreen: Bool = false, covered: Bool = false,
                  poseStill: Bool = false, window: Bool = true) -> TelosFrameGate.Mode {
            TelosFrameGate.mode(requested: requested, visible: visible, offscreen: offscreen, covered: covered,
                                poseStill: poseStill, withinActiveWindow: window)
        }
        XCTAssertEqual(mode(requested: false), .still)
        XCTAssertEqual(mode(visible: false), .still)
        XCTAssertEqual(mode(offscreen: true), .still)
        XCTAssertEqual(mode(covered: true), .still)
        XCTAssertEqual(mode(poseStill: true), .still, "Reduce Motion / Low Power / quiet motion")
        XCTAssertEqual(mode(window: false), .still, "a settle-then-rest clock rests after its window")
    }

    func testRateIsCappedAtThirtyFramesPerSecond() {
        XCTAssertEqual(TelosFrameGate.minimumInterval, 1.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(TelosFrameGate.clampedInterval(1.0 / 60.0), 1.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(TelosFrameGate.clampedInterval(0.5), 0.5)
        XCTAssertEqual(TelosFrameGate.clampedInterval(.nan), TelosFrameGate.minimumInterval)
        XCTAssertLessThanOrEqual(TelosMotion.settleBudget, 1.2)
    }
}

#if !os(watchOS)
final class ChartCalloutPlacementTests: XCTestCase {

    func testCalloutIsPinnedToThePlotTopBesideThePoint() {
        let size = CGSize(width: 80, height: 30)
        let container = CGSize(width: 300, height: 200)
        let p = ChartTooltipPlacement.pinnedTop(anchorX: 100, tooltipSize: size, in: container, plotTop: 8)
        XCTAssertEqual(p.y, 8 + 15 + 2, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(abs(p.x - 100), size.width / 2, "never covers the scrubbed point")
        XCTAssertGreaterThan(p.x, 100, "sits to the right by default")
    }

    func testCalloutFlipsAtTheRightEdgeAndStaysInBounds() {
        let size = CGSize(width: 80, height: 30)
        let container = CGSize(width: 300, height: 200)
        let p = ChartTooltipPlacement.pinnedTop(anchorX: 280, tooltipSize: size, in: container)
        XCTAssertLessThan(p.x, 280)
        XCTAssertGreaterThanOrEqual(abs(p.x - 280), size.width / 2)
        XCTAssertLessThanOrEqual(p.x + size.width / 2, container.width + 1e-9)
        XCTAssertGreaterThanOrEqual(p.x - size.width / 2, -1e-9)
    }
}
#endif
