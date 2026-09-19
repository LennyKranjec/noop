import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StrainScorerTests: XCTestCase {

    /// Build n consecutive 1 Hz HR samples at a constant bpm.
    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testTanakaAndDefaultMax() {
        XCTAssertEqual(StrainScorer.tanakaHRmax(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 30), 190)
    }

    func testTrimpToStrainCeilingMapsTo100() {
        // Edwards 24 h ceiling TRIMP = 7200 → Effort exactly 100.0 with D = 7201
        // (rescaled from the old 21.0; the curve/saturation point is unchanged).
        XCTAssertEqual(StrainScorer.trimpToStrain(7200), 100.0, accuracy: 1e-9)
    }

    func testTrimpToStrainKnownValues() {
        XCTAssertEqual(StrainScorer.trimpToStrain(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(-5), 0.0, accuracy: 1e-9)
        // 10.91 × 100/21 on the rescaled axis.
        XCTAssertEqual(StrainScorer.trimpToStrain(100), 51.96, accuracy: 1e-2)
    }

    func testStrainGoldenEdwardsZone5() {
        // 600 z5 samples at 1 Hz, resting 60, max 190. TRIMP = 600*5*(1/60)=50.
        // Effort = 100*ln(51)/ln(7201) = 44.27 (was 9.3 on the 0–21 axis).
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)
        XCTAssertEqual(s!, 44.27, accuracy: 1e-2)
    }

    /// #137 (partial-day sanity, PR #236 review): an imported ride is a short HR ISLAND — a 1–2 h
    /// window, not a full day of HR. Prove the day Effort from that island is SENSIBLE: it equals the
    /// Effort the same ride would score if worn on a strap for a full day. Edwards TRIMP integrates only
    /// over the samples present, and resting HR (≤ restingHR → zone weight 0) adds zero TRIMP, so a
    /// strap-less imported ride is neither diluted by the empty hours nor inflated by them — the number
    /// the user sees is the ride's own honest cardiovascular load, identical to a worn strap.
    func testImportedRidePartialDayEffortMatchesWornStrap() {
        // A 90-minute ride @ 150 bpm (moderate), mid-morning, sampled at 1 Hz.
        let ride = hr(150, 90 * 60, start: 8 * 3_600)

        // Import case (strap-less day): the ride is the ONLY HR on the day.
        let importEffort = StrainScorer.strain(ride, maxHR: 190, restingHR: 60)

        // Worn-strap case: the SAME ride embedded in a full 24 h of resting HR (60 bpm) around it.
        let restBefore = hr(60, 8 * 3_600, start: 0)
        let restAfter  = hr(60, 24 * 3_600 - 8 * 3_600 - 90 * 60, start: 8 * 3_600 + 90 * 60)
        let wornEffort = StrainScorer.strain(restBefore + ride + restAfter, maxHR: 190, restingHR: 60)

        XCTAssertNotNil(importEffort, "a 90-min HR island clears the minReadings/minSpan gates")
        // Identical: resting time contributes zero TRIMP, so the island scores the same either way.
        XCTAssertEqual(importEffort!, wornEffort!, accuracy: 1e-9,
                       "imported-ride Effort must equal the same ride worn on a strap")
        // A sensible MODERATE Effort for a 90-min zone-3 ride — not 0 (dark), not saturated (~100).
        XCTAssertGreaterThan(importEffort!, 20)
        XCTAssertLessThan(importEffort!, 90)
    }

    func testStrainReturnsNilTooFewReadings() {
        XCTAssertNil(StrainScorer.strain(hr(150, 599), maxHR: 190, restingHR: 60))
    }

    func testStrainReturnsNilInvalidHRR() {
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 60, restingHR: 60))
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 50, restingHR: 60))
    }

    func testStrainMonotonicInZoneTime() {
        // More time at high intensity → higher strain. Compare 600 vs 1200 z5 samples.
        let short = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!
        let long = StrainScorer.strain(hr(185, 1200), maxHR: 190, restingHR: 60)!
        XCTAssertGreaterThan(long, short)
    }

    func testStrainMonotonicInIntensity() {
        // Same duration, higher zone → higher strain.
        let z4 = StrainScorer.strain(hr(155, 600), maxHR: 190, restingHR: 60)!  // ~82% HRmax → w4
        let z5 = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!  // ~97% HRmax → w5
        XCTAssertGreaterThan(z5, z4)
    }

    func testStrainBanisterAlsoBounded() {
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60, method: .banister)!
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 100.0)
    }

    // MARK: - #482/#480 sparse-strap acceptance + honest-zero (regression guards)

    /// Build n samples at a fixed cadence (default 30 s — the WHOOP 5/MG live-HR rate).
    private func hrEvery(_ bpm: Int, _ n: Int, stepS: Int = 30, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0 * stepS, bpm: bpm) }
    }

    func testSparseStreamScoresOnceItSpansEnoughTime() {
        // The 5/MG case: only ~30 live samples at 30 s cadence — far under minReadings (600), but
        // they SPAN ~15 min, so the score should compute rather than return nil (which made the live
        // gauge fall back to a stale prior-day value). HR 185 is z5, so it produces a real number.
        let sparse = hrEvery(185, 30)                                // 30 × 30 s = 870 s span
        XCTAssertGreaterThanOrEqual(sparse.last!.ts - sparse.first!.ts, StrainScorer.minSpanSeconds)
        XCTAssertNotNil(StrainScorer.strain(sparse, maxHR: 190, restingHR: 60))
    }

    func testSparseStreamStillNilUnderSampleFloor() {
        // A handful of readings (under minSparseReadings) is too little to trust even if spread out.
        let tooFew = hrEvery(185, 5, stepS: 200)                     // 5 samples, wide span, < floor
        XCTAssertNil(StrainScorer.strain(tooFew, maxHR: 190, restingHR: 60))
    }

    func testLightDayHonestlyScoresZeroNotFabricated() {
        // #482: HR that never crosses 50% HRmax earns ZERO Effort, by design. With max 184, zone 1
        // starts at 92 bpm (O6 — Edwards on %HRmax); a day spent at 88 stays below it. The fix must NOT
        // invent load to make the gauge "look alive" — both a dense (4.0) and a sparse (5/MG) light day = 0.
        let denseLight = hr(88, 1200, start: 0)                      // 4.0-style, 20 min at 1 Hz
        let sparseLight = hrEvery(88, 40)                            // 5/MG-style, 40 × 30 s
        XCTAssertEqual(StrainScorer.strain(denseLight, maxHR: 184, restingHR: 60), 0.0)
        XCTAssertEqual(StrainScorer.strain(sparseLight, maxHR: 184, restingHR: 60), 0.0)
    }

    func testSparseStreamScoresRealWorkout() {
        // The same sparse cadence, but a genuine workout (z5) — Effort must be clearly > 0, proving the
        // zero above is about intensity, not about the sparse path swallowing real load.
        let sparseHard = hrEvery(175, 40)                            // 175 bpm ≈ 95% HRmax → z5
        let s = StrainScorer.strain(sparseHard, maxHR: 184, restingHR: 60)
        XCTAssertNotNil(s)
        XCTAssertGreaterThan(s!, 0)
    }

    func testEstimateHRmaxObservedVsTanaka() {
        // Thin history but known age → tanaka.
        let (v1, src1) = StrainScorer.estimateHRmax([150, 160, 170], age: 30)
        XCTAssertEqual(v1, 187.0, accuracy: 1e-9)
        XCTAssertEqual(src1, "tanaka")

        // No age, no history → unknown.
        let (v2, src2) = StrainScorer.estimateHRmax([150], age: nil)
        XCTAssertEqual(v2, 0.0)
        XCTAssertEqual(src2, "unknown")

        // Dense history with a sustained high tail above tanaka → observed.
        // The 99.5th percentile must exceed 187, so the top ~0.5% must be high:
        // 700 samples, top 10 (>0.5%) at 195 → p99.5 lands in the high tail.
        var hist = Array(repeating: 120.0, count: 690)
        hist.append(contentsOf: Array(repeating: 195.0, count: 10))
        let (v3, src3) = StrainScorer.estimateHRmax(hist, age: 30)
        XCTAssertEqual(src3, "observed")
        XCTAssertGreaterThan(v3, 187.0)
    }

    func testPercentileLinearInterp() {
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 50), 25.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 0), 10.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 100), 40.0, accuracy: 1e-9)
    }

    func testFitStrainDenominator() throws {
        // Pairs generated from a known D should recover that D. Pairs use the rescaled
        // 0–100 axis (maxStrain = 100), matching fitStrainDenominator's maxStrain term.
        let knownD = 5000.0
        func strainFor(_ t: Double) -> Double { 100 * log(t + 1) / log(knownD) }
        let pairs = [(100.0, strainFor(100)), (1000.0, strainFor(1000)), (50.0, strainFor(50))]
        let fitted = try StrainScorer.fitStrainDenominator(pairs)
        XCTAssertEqual(fitted, knownD, accuracy: 1.0)
    }

    func testFitStrainDenominatorThrowsTooFew() {
        XCTAssertThrowsError(try StrainScorer.fitStrainDenominator([(100, 10)]))
    }

    /// #983 → O6 — the resting HR a workout is scored with still matters, but only where the recipe uses it.
    ///
    /// Before O6 Edwards zones were %HRR, so scoring someone whose real resting is 50 as if it were the
    /// hardcoded 60 moved 136 bpm from zone 1 to zone 2. Edwards is now on %HRmax as published, where the
    /// resting HR cancels out: the same HR is the same zone whatever the resting. Banister is DEFINED on
    /// ΔHRR, so there the measured resting still has to reach the score — which is what #983 protects.
    ///
    /// Twin: `StrainRestingHrTest.restingHrChangesTheZoneASampleLandsIn` (needs the same O6 update).
    func testRestingHrChangesTheZoneASampleLandsIn() {
        // 136 / 190 = 71.6% HRmax → zone 3 under either resting HR.
        XCTAssertEqual(StrainScorer.zoneWeight(136, restingHR: 60, hrReserve: 130), 3)
        XCTAssertEqual(StrainScorer.zoneWeight(136, restingHR: 50, hrReserve: 140), 3)
        let window = hr(136, 1200)   // well past the >=600-sample gate this file pins above
        let edDefault = StrainScorer.strain(window, maxHR: 190, restingHR: 60)
        let edMeasured = StrainScorer.strain(window, maxHR: 190, restingHR: 50)
        XCTAssertNotNil(edDefault); XCTAssertNotNil(edMeasured)
        XCTAssertEqual(edMeasured!, edDefault!, accuracy: 1e-9, "Edwards (%HRmax) does not read resting HR")
        // ...but Banister does, all the way through to the score.
        let baDefault = StrainScorer.strain(window, maxHR: 190, restingHR: 60, method: .banister)
        let baMeasured = StrainScorer.strain(window, maxHR: 190, restingHR: 50, method: .banister)
        XCTAssertNotNil(baDefault); XCTAssertNotNil(baMeasured)
        XCTAssertGreaterThan(baMeasured!, baDefault!,
                             "a lower measured resting widens ΔHRR for the same HR, so Banister Effort rises")
    }

    // MARK: - O6: Edwards zones on %HRmax

    /// The reported case: age 30 (Tanaka 187), RHR 50. Zone 1 must start at 50% HRmax = 93.5 bpm — not at
    /// 50% of the reserve (118.5 bpm), which left brisk walking and lifting at ≈0 Effort.
    func testEdwardsZonesAreOnPercentHRmax() {
        let hrMax = StrainScorer.tanakaHRmax(age: 30)          // 187
        let rest = 50.0, reserve = hrMax - rest
        XCTAssertEqual(StrainScorer.zoneWeight(93, restingHR: rest, hrReserve: reserve), 0)    // 49.7%
        XCTAssertEqual(StrainScorer.zoneWeight(94, restingHR: rest, hrReserve: reserve), 1)    // 50.3%
        XCTAssertEqual(StrainScorer.zoneWeight(113, restingHR: rest, hrReserve: reserve), 2)   // 60.4%
        XCTAssertEqual(StrainScorer.zoneWeight(131, restingHR: rest, hrReserve: reserve), 3)   // 70.1%
        XCTAssertEqual(StrainScorer.zoneWeight(150, restingHR: rest, hrReserve: reserve), 4)   // 80.2%
        XCTAssertEqual(StrainScorer.zoneWeight(169, restingHR: rest, hrReserve: reserve), 5)   // 90.4%
        // The pre-O6 table is kept for the detector's gate only, and still reads 110 bpm as band 0.
        XCTAssertEqual(StrainScorer.karvonenBand(110, restingHR: rest, hrReserve: reserve), 0)
        XCTAssertEqual(StrainScorer.karvonenBand(119, restingHR: rest, hrReserve: reserve), 1)
        // End to end: an hour's brisk walk at 105 bpm now earns real Effort (60 min × w1 = TRIMP 60).
        let walk = hr(105, 3600)
        let s = StrainScorer.strain(walk, maxHR: hrMax, restingHR: rest)
        XCTAssertNotNil(s)
        XCTAssertEqual(s ?? -1, StrainScorer.trimpToStrain(60), accuracy: 0.05)
        XCTAssertGreaterThan(s ?? -1, 40)
    }

    /// Pins the log-map anchor values documented in StrainScorer's header, so a change to D or the curve
    /// has to update the documentation along with them. D is deliberately unchanged by O6.
    func testDocumentedLogMapAnchors() {
        XCTAssertEqual(StrainScorer.strainDenominator, 7201.0)
        XCTAssertEqual(StrainScorer.trimpToStrain(60), 46.3, accuracy: 0.1)    // easy walk day
        XCTAssertEqual(StrainScorer.trimpToStrain(150), 56.5, accuracy: 0.1)   // 60-min moderate + day
        XCTAssertEqual(StrainScorer.trimpToStrain(345), 65.8, accuracy: 0.1)   // hard 90-min + day
    }
}
