import XCTest
@testable import Strand
import StrandAnalytics
import WhoopStore

/// #1391: VO₂max is offered even WITHOUT a waist. `fitnessAgeRows` persists `vo2max_est` = the Nes 2011
/// waist-based estimate when a waist is set, else falls back to the Uth 2004 HR-ratio estimate
/// (15.3·HRmax/RHR, HRmax = Tanaka(age)) — so a user past the age+RHR fitness-age gate gets a VO₂max
/// instead of a blank. Twin of the Android Vo2maxFallbackTest.
///
/// `@MainActor`: `IntelligenceEngine.fitnessAgeRows` is main-actor-isolated, so the whole fixture
/// runs on the main actor to call it from a synchronous test context.
@MainActor
final class Vo2maxFallbackTests: XCTestCase {

    /// ≥ minCoverageDays (4) RHR nights + strain so the fitness-age gate can compute.
    private func gate(_ rhr: Int) -> [DailyMetric] {
        (0..<7).map { i in
            DailyMetric(day: String(format: "2026-08-%02d", 9 + i), totalSleepMin: nil, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: rhr,
                        avgHrv: nil, recovery: nil, strain: 50, exerciseCount: nil)
        }
    }

    private func vo2maxEst(waistCm: Double) -> Double? {
        IntelligenceEngine.fitnessAgeRows(
            gateDays: gate(60), age: 40, sex: "male", waistCm: waistCm, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-15"
        ).first { $0.key == "vo2max_est" }?.value
    }

    func testNoWaistFallsBackToUthHrRatioEstimate() {
        let vo2 = vo2maxEst(waistCm: 0)   // no waist → Nes value is nil
        XCTAssertNotNil(vo2, "without a waist, VO₂max must still be offered via the Uth fallback")
        // Uth: 15.3 × Tanaka(40)=180 / the WAKING rest (O7): sleep RHR 60 + the 6 bpm offset = 66.
        XCTAssertEqual(vo2!, 15.3 * StrainScorer.tanakaHRmax(age: 40) / 66.0, accuracy: 1e-6)
    }

    /// O7: a MEASURED daytime waking rest wins over the sleep + offset fallback, day by day, and the
    /// value fed to Uth / Nes is the median of the resolved days.
    func testMeasuredWakingRestFeedsTheEstimate() {
        let days = gate(60)
        var waking: [String: Double] = [:]
        for d in days.prefix(4) { waking[d.day] = 70 }   // 4 measured @70, 3 fallback @66 → median 70
        let rows = IntelligenceEngine.fitnessAgeRows(
            gateDays: days, age: 40, sex: "male", waistCm: 0, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-15", wakingRhrByDay: waking)
        let vo2 = rows.first { $0.key == "vo2max_est" }?.value
        XCTAssertEqual(vo2 ?? 0, 15.3 * StrainScorer.tanakaHRmax(age: 40) / 70.0, accuracy: 1e-6)
        let fa = rows.first { $0.key == "fitness_age" }?.value
        let paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 50)
        XCTAssertEqual(fa ?? 0, FitnessAgeEngine.fitnessAge(age: 40, sex: "male", restingHR: 70, paIndex: paIndex),
                       accuracy: 1e-6)
    }

    func testWaistSetUsesTheNesWaistBasedEstimate() {
        let uth = vo2maxEst(waistCm: 0)!
        let nes = vo2maxEst(waistCm: 90)!
        let paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: 7, meanActiveStrain: 50)
        // With a waist the persisted value is the Nes waist-based estimate…
        XCTAssertEqual(nes, FitnessAgeEngine.estimateVO2max(age: 40, sex: "male", waistCm: 90,
                                                            restingHR: 66, paIndex: paIndex), accuracy: 1e-6)
        // …and it differs from the Uth HR-ratio fallback.
        XCTAssertGreaterThan(abs(nes - uth), 0.01)
    }

    func testNewlyComputedPointRecordsTheEstimatorUsedAtComputeTime() {
        let uthRows = IntelligenceEngine.fitnessAgeRows(
            gateDays: gate(60), age: 40, sex: "male", waistCm: 0, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-15")
        let nesRows = IntelligenceEngine.fitnessAgeRows(
            gateDays: gate(60), age: 40, sex: "male", waistCm: 90, heightCm: 175, weightKg: 80,
            computedId: "my-whoop-noop", satKey: "2026-08-22")

        let uth = IntelligenceEngine.vo2MaxProvenance(points: uthRows, waistCm: 0).first
        let nes = IntelligenceEngine.vo2MaxProvenance(points: nesRows, waistCm: 90).first
        XCTAssertEqual(uth?.sourceId, Vo2MaxEstimator.uth.rawValue)
        XCTAssertEqual(uth?.day, "2026-08-15")
        XCTAssertEqual(uth?.key, "vo2max_est")
        XCTAssertEqual(nes?.sourceId, Vo2MaxEstimator.nes.rawValue)
        XCTAssertNil(Vo2MaxEstimator(rawValue: "my-whoop"))
    }
}
