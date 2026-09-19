import XCTest
@testable import StrandAnalytics

/// WHOOP-style display zones: Karvonen (%HRR) edges, a learned zone HRmax (rises at once, decays slowly,
/// needs ≥ 3 workouts, ignores implausible peaks, loses to a manual override) and a 7-night median RHR.
final class HRZonesKarvonenTests: XCTestCase {

    private let day = 86_400
    private let now = 1_800_000_000

    // MARK: - Karvonen bounds

    func testKarvonenBoundsForKnownRestingAndMax() {
        // RHR 50, HRmax 190 → reserve 140: 50 + {70, 84, 98, 112, 126, 140}.
        let zs = HRZones.zones(maxHR: 190, restingHR: 50, source: "learned")
        XCTAssertEqual(zs.source, "learned")
        XCTAssertEqual(zs.restingHR, 50)
        let expected: [Double] = [120, 134, 148, 162, 176]
        for i in 0..<5 {
            XCTAssertEqual(zs.zones[i].lower, expected[i], accuracy: 1e-9)
            XCTAssertEqual(zs.zones[i].upper, i < 4 ? expected[i + 1] : 190, accuracy: 1e-9)
            // lowerPct stays a fraction of HRmax, so a "% max HR" label stays true.
            XCTAssertEqual(zs.zones[i].lowerPct, expected[i] / 190, accuracy: 1e-9)
        }
        XCTAssertEqual(zs.bpmRanges.map { [$0.lower, $0.upper] },
                       [[120, 133], [134, 147], [148, 161], [162, 175], [176, 190]])
        XCTAssertEqual(zs.zoneNumber(forBPM: 119), 0)
        XCTAssertEqual(zs.zoneNumber(forBPM: 120), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 133), 1)
        XCTAssertEqual(zs.zoneNumber(forBPM: 134), 2)
        XCTAssertEqual(zs.zoneNumber(forBPM: 176), 5)
        XCTAssertEqual(zs.zoneNumber(forBPM: 190), 5)
    }

    func testKarvonenDefaultLowerBoundsRoundUp() {
        // RHR 52, HRmax 191 → reserve 139: 121.5, 135.4, 149.3, 163.2, 177.1 → rounded up.
        XCTAssertEqual(HRZones.defaultLowerBounds(maxHR: 191, restingHR: 52), [122, 136, 150, 164, 178])
        // nil RHR → the old %HRmax seeds.
        XCTAssertEqual(HRZones.defaultLowerBounds(maxHR: 187, restingHR: nil), [94, 113, 131, 150, 169])
    }

    func testNilOrUnusableRestingHRFallsBackToPercentOfMax() {
        let pct = HRZones.zones(maxHR: 200)
        XCTAssertEqual(HRZones.zones(maxHR: 200, restingHR: nil), pct)
        XCTAssertEqual(HRZones.zones(maxHR: 200, restingHR: 0), pct)
        XCTAssertEqual(HRZones.zones(maxHR: 200, restingHR: 210), pct)   // RHR ≥ HRmax: no reserve
        XCTAssertNil(pct.restingHR)
    }

    func testCustomBoundsStillWinOverKarvonen() {
        let zs = HRZones.zones(maxHR: 200, restingHR: 55, customLowerBounds: [95, 118, 142, 168, 184])
        XCTAssertEqual(zs.source, "custom")
        XCTAssertNil(zs.restingHR)
        XCTAssertEqual(zs.zones.map(\.lower), [95, 118, 142, 168, 184])
    }

    func testKarvonenZonesPartitionContiguously() {
        let zs = HRZones.zones(maxHR: 187, restingHR: 58)
        for i in 0..<4 { XCTAssertEqual(zs.zones[i].upper, zs.zones[i + 1].lower, accuracy: 1e-9) }
        XCTAssertEqual(zs.zones[4].upper, 187, accuracy: 1e-9)
    }

    // MARK: - Observed HRmax (workout peaks)

    func testObservedNeedsThreePlausibleWorkouts() {
        XCTAssertNil(HRZones.observedZoneHRmax(workoutPeaks: [(now - day, 185), (now - 2 * day, 190)], now: now))
        XCTAssertEqual(HRZones.observedZoneHRmax(
            workoutPeaks: [(now - day, 185), (now - 2 * day, 190), (now - 3 * day, 180)], now: now), 185)
    }

    func testObservedIgnoresImplausibleSpikesAndTakesRunnerUp() {
        // 240 and 90 are outside 100–220 → only two usable peaks → nil.
        XCTAssertNil(HRZones.observedZoneHRmax(
            workoutPeaks: [(now - day, 240), (now - day, 90), (now - day, 181), (now - day, 176)], now: now))
        // A single in-band spike (205) is dropped as the top peak; the runner-up is the estimate.
        XCTAssertEqual(HRZones.observedZoneHRmax(
            workoutPeaks: [(now - day, 240), (now - day, 205), (now - day, 186), (now - day, 176)], now: now), 186)
    }

    func testObservedOnlyCountsTheLast180Days() {
        let old = now - 200 * day
        XCTAssertNil(HRZones.observedZoneHRmax(
            workoutPeaks: [(old, 199), (old, 198), (now - day, 180), (now - day, 178)], now: now))
    }

    func testRobustObservedMinWorkoutsParameterKeepsVO2Default() {
        XCTAssertNil(StrainScorer.robustObservedHRmax(workoutPeaks: [181, 176, 183]))       // default 5
        XCTAssertEqual(StrainScorer.robustObservedHRmax(workoutPeaks: [181, 176, 183], minWorkouts: 3), 181)
        XCTAssertNil(StrainScorer.robustObservedHRmax(workoutPeaks: [181], minWorkouts: 1))  // needs a runner-up
    }

    // MARK: - Learned HRmax

    func testLearnedIsAgeFormulaWithoutWorkouts() {
        let l = HRZones.learnedZoneHRmax(age: 30, observed: nil, previous: nil, previousAt: nil, now: now)
        XCTAssertEqual(l, HRZones.ZoneHRmax(bpm: 187, source: .ageFormula))
        // A lower observed ceiling never pulls it under the formula.
        let low = HRZones.learnedZoneHRmax(age: 30, observed: 175, previous: nil, previousAt: nil, now: now)
        XCTAssertEqual(low, HRZones.ZoneHRmax(bpm: 187, source: .ageFormula))
    }

    func testLearnedRisesImmediatelyWithANewPeak() {
        let a = HRZones.learnedZoneHRmax(age: 30, observed: 192, previous: 187, previousAt: now - day, now: now)
        XCTAssertEqual(a, HRZones.ZoneHRmax(bpm: 192, source: .learned))
        let b = HRZones.learnedZoneHRmax(age: 30, observed: 195, previous: a.bpm, previousAt: now, now: now + 60)
        XCTAssertEqual(b.bpm, 195, accuracy: 1e-9)
    }

    func testLearnedIgnoresImplausibleObserved() {
        let l = HRZones.learnedZoneHRmax(age: 30, observed: 245, previous: nil, previousAt: nil, now: now)
        XCTAssertEqual(l, HRZones.ZoneHRmax(bpm: 187, source: .ageFormula))
    }

    func testLearnedDecaysSlowlyOnceItsPeaksAgeOut() {
        // 10 days at 0.25 bpm/day: 195 → 192.5, still learned.
        let ten = HRZones.learnedZoneHRmax(age: 30, observed: nil, previous: 195, previousAt: now - 10 * day, now: now)
        XCTAssertEqual(ten.bpm, 192.5, accuracy: 1e-9)
        XCTAssertEqual(ten.source, .learned)
        // Never below the current target (the age formula here).
        let long = HRZones.learnedZoneHRmax(age: 30, observed: nil, previous: 195, previousAt: now - 100 * day, now: now)
        XCTAssertEqual(long, HRZones.ZoneHRmax(bpm: 187, source: .ageFormula))
        // Or below a still-supported observed value.
        let held = HRZones.learnedZoneHRmax(age: 30, observed: 190, previous: 195, previousAt: now - 100 * day, now: now)
        XCTAssertEqual(held.bpm, 190, accuracy: 1e-9)
    }

    func testManualOverrideWins() {
        let learned = HRZones.ZoneHRmax(bpm: 193, source: .learned)
        XCTAssertEqual(HRZones.resolveZoneHRmax(overrideBpm: 200, learned: learned),
                       HRZones.ZoneHRmax(bpm: 200, source: .manual))
        XCTAssertEqual(HRZones.resolveZoneHRmax(overrideBpm: 0, learned: learned), learned)
        XCTAssertEqual(HRZones.resolveZoneHRmax(overrideBpm: nil, learned: learned), learned)
    }

    // MARK: - Resting HR

    func testRestingHRIsSevenNightMedian() {
        // Oldest → newest; the oldest (60) falls outside the last 7; 0 and 150 are implausible.
        let r = HRZones.zoneRestingHR(sleepRestingHRs: [60, 50, 52, 0, 55, 51, 150, 53, 54, 49])
        XCTAssertEqual(r, HRZones.ZoneRestingHR(bpm: 52, source: .sleepMedian))
        let even = HRZones.zoneRestingHR(sleepRestingHRs: [50, 53])
        XCTAssertEqual(even.bpm, 51.5, accuracy: 1e-9)
    }

    func testRestingHRFallsBackToWakingThenDefault() {
        XCTAssertEqual(HRZones.zoneRestingHR(sleepRestingHRs: [], wakingRestingHRs: [58, 62]),
                       HRZones.ZoneRestingHR(bpm: 60, source: .waking))
        XCTAssertEqual(HRZones.zoneRestingHR(sleepRestingHRs: [], wakingRestingHRs: []),
                       HRZones.ZoneRestingHR(bpm: 60, source: .fallback))
        // Sleep beats waking whenever any night has one.
        XCTAssertEqual(HRZones.zoneRestingHR(sleepRestingHRs: [48], wakingRestingHRs: [58]).source, .sleepMedian)
    }
}
