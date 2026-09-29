import Foundation
import XCTest
@testable import StrandAnalytics

/// The energy model against the wearer's own word.
///
/// Expected values below were produced by a line-for-line Python mirror of `EnergyCalibration` over the
/// same deterministic generator (`TestLCG`), so the tolerances are real margins, not guesses:
///   * fit on 400 noise-free samples from TRUTH → bias −10.60, share 0.411, strain 31.04, stress 35.23,
///     rest 11.77, awake 1.990;
///   * fit on the first 3 of them → bias −4.49, share 0.692, strain 60.08, stress 25.61, rest 14.50,
///     awake 0.187 (every weight within 0.35 prior SD of its default);
///   * seed 5 (reports follow the model) → before ρ 0.953, LOO after ρ 0.944, tracks, defaults kept;
///   * seed 6 (reports ignore the model) → before ρ −0.398, after ρ −0.781, weak;
///   * seed 8 (a wearer strain does not tire and time awake does) → before ρ 0.588 → after ρ 0.924,
///     fitted strain cost 8.1, awake 3.34/h.
final class EnergyCalibrationTests: XCTestCase {

    // MARK: - Deterministic synthetic data (mirrored in the Python oracle)

    private struct TestLCG {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    private func randomInputs(_ g: inout TestLCG) -> EnergyInputs {
        let recovery = 20 + 75 * g.next()
        let sleep = 30 + 65 * g.next()
        let strain = 18 * g.next()
        let stress = 300 * g.next()
        let calm = 400 * g.next()
        let awake = 14 * g.next()
        return EnergyInputs(recovery: recovery, sleepScore: sleep, strain21: strain,
                            stressMinutes: stress, calmMinutes: calm, hoursAwake: awake)
    }

    /// A 0–100 value as the 1–5 tap nearest to it.
    private func quantise(_ v: Double) -> Int {
        Int(Swift.min(Swift.max((v / 25).rounded(), 0), 4)) + 1
    }

    private func checkIns(seed: UInt64, count: Int, days: Int,
                          felt: (EnergyInputs, inout TestLCG) -> Int) -> [EnergyCheckIn] {
        var g = TestLCG(seed)
        var out: [EnergyCheckIn] = []
        for k in 0..<count {
            let inputs = randomInputs(&g)
            let f = felt(inputs, &g)
            out.append(EnergyCheckIn(id: "c\(k)", at: Date(timeIntervalSince1970: Double(k) * 3600),
                                     day: String(format: "d%02d", k % days), slot: .morning, felt: f,
                                     inputs: inputs))
        }
        return out
    }

    private let truth = EnergyBank.Parameters(bias: -10, recoveryShare: 0.4, strainCost: 30, stressCost: 40,
                                              restReturnMax: 10, awakeCostPerHour: 2)

    private func samples(_ n: Int, _ params: EnergyBank.Parameters, seed: UInt64) -> [EnergyCalibration.Sample] {
        var g = TestLCG(seed)
        return (0..<n).map { _ -> EnergyCalibration.Sample in
            let inputs = randomInputs(&g)
            let target = EnergyCalibration.linearPrediction(EnergyBank.features(inputs)!, params)
            return EnergyCalibration.Sample(inputs: inputs, target: target)
        }
    }

    // MARK: - Agreement statistic

    func testTiesShareTheirAverageRank() {
        XCTAssertEqual(EnergyCalibration.ranks([1, 2, 2, 3]), [1, 2.5, 2.5, 4])
        XCTAssertEqual(EnergyCalibration.ranks([5, 5, 5]), [2, 2, 2])
    }

    func testPerfectAgreement() {
        let x = (0..<20).map(Double.init)
        let a = EnergyCalibration.spearman(x, x.map { 2 * $0 + 1 })
        XCTAssertEqual(a?.rho ?? 0, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(a?.lower ?? 0, 0.99)
        XCTAssertTrue(a?.excludesZero ?? false)
    }

    func testReversedAgreement() {
        let x = (0..<20).map(Double.init)
        let a = EnergyCalibration.spearman(x, x.map { -$0 })
        XCTAssertEqual(a?.rho ?? 0, -1, accuracy: 1e-12)
        XCTAssertLessThan(a?.upper ?? 0, -0.99)
        XCTAssertFalse(a?.excludesZero ?? true)
    }

    func testNoRelationshipGivesAnIntervalAcrossZero() {
        var g = TestLCG(7)
        let y = (0..<30).map { _ in g.next() }
        let a = EnergyCalibration.spearman((0..<30).map(Double.init), y)
        // Oracle: ρ −0.0242, interval (−0.391, 0.349).
        XCTAssertEqual(a?.rho ?? 9, -0.0242, accuracy: 1e-3)
        XCTAssertLessThan(a?.lower ?? 0, 0)
        XCTAssertGreaterThan(a?.upper ?? 0, 0)
        XCTAssertEqual(a?.n, 30)
    }

    func testAgreementNeedsPairsAndSpread() {
        XCTAssertNil(EnergyCalibration.spearman([1, 2, 3], [1, 2, 3]), "three pairs is not a correlation")
        XCTAssertNil(EnergyCalibration.spearman([1, 2, 3, 4, 5], [3, 3, 3, 3, 3]),
                     "every report the same says nothing about agreement")
        XCTAssertNil(EnergyCalibration.spearman([1, 2, 3, 4], [1, 2, 3]))
        XCTAssertNil(EnergyCalibration.spearman([1, 2, .nan, 4], [1, 2, 3, 4]))
    }

    // MARK: - The fit

    func testTheFitRecoversKnownWeightsFromPlentyOfData() {
        let fitted = EnergyCalibration.fit(samples(400, truth, seed: 42))
        let d = EnergyBank.Parameters.defaults
        XCTAssertEqual(fitted.bias, -10, accuracy: 1.5)
        XCTAssertEqual(fitted.recoveryShare, 0.4, accuracy: 0.03)
        XCTAssertEqual(fitted.strainCost, 30, accuracy: 2.5)
        XCTAssertEqual(fitted.stressCost, 40, accuracy: 6)
        XCTAssertEqual(fitted.restReturnMax, 10, accuracy: 2.5)
        XCTAssertEqual(fitted.awakeCostPerHour, 2, accuracy: 0.1)
        // …and every weight ended nearer the truth than the default it was pulled toward.
        XCTAssertLessThan(abs(fitted.stressCost - 40), abs(fitted.stressCost - d.stressCost))
        XCTAssertLessThan(abs(fitted.restReturnMax - 10), abs(fitted.restReturnMax - d.restReturnMax))
        XCTAssertLessThan(abs(fitted.strainCost - 30), abs(fitted.strainCost - d.strainCost))
    }

    func testWithLittleDataTheFitStaysNearTheDefaults() {
        let fitted = EnergyCalibration.fit(samples(3, truth, seed: 42))
        let d = EnergyBank.Parameters.defaults
        let sd = EnergyCalibration.priorSD
        XCTAssertLessThan(abs(fitted.bias - d.bias), 0.5 * sd.bias)
        XCTAssertLessThan(abs(fitted.recoveryShare - d.recoveryShare), 0.5 * sd.recoveryShare)
        XCTAssertLessThan(abs(fitted.strainCost - d.strainCost), 0.5 * sd.strainCost)
        XCTAssertLessThan(abs(fitted.stressCost - d.stressCost), 0.5 * sd.stressCost)
        XCTAssertLessThan(abs(fitted.restReturnMax - d.restReturnMax), 0.5 * sd.restReturnMax)
        XCTAssertLessThan(abs(fitted.awakeCostPerHour - d.awakeCostPerHour), 0.5 * sd.awakeCostPerHour)
    }

    func testWithNoDataTheFitIsThePrior() {
        XCTAssertEqual(EnergyCalibration.fit([]), .defaults)
        let unusable = [EnergyCalibration.Sample(inputs: EnergyInputs(strain21: 5), target: 50)]
        XCTAssertEqual(EnergyCalibration.fit(unusable), .defaults, "no opening, nothing to learn from")
    }

    func testASpendIsNeverTurnedIntoACredit() {
        // A wearer whose reports rise with strain: the unconstrained weight is negative; the model's is 0.
        var p = EnergyBank.Parameters.defaults
        p.strainCost = -40
        let fitted = EnergyCalibration.fit(samples(200, p, seed: 9))
        XCTAssertEqual(fitted.strainCost, 0)
        XCTAssertGreaterThanOrEqual(fitted.awakeCostPerHour, 0)
    }

    // MARK: - The verdict

    func testCalibratingBelowTheMinimumCount() {
        let v = EnergyCalibration.evaluate(checkIns(seed: 5, count: 13, days: 13) { inputs, _ in
            self.quantise(EnergyBank.balance(inputs)!.balance)
        })
        XCTAssertEqual(v.status, .calibrating)
        XCTAssertEqual(v.usable, 13)
        XCTAssertNil(v.after)
        XCTAssertFalse(v.fitted)
        XCTAssertEqual(v.params, .defaults, "nothing is fitted before the minimum")
    }

    func testCalibratingWhenTheCheckInsCrowdIntoTooFewDays() {
        let v = EnergyCalibration.evaluate(checkIns(seed: 5, count: 20, days: 5) { inputs, _ in
            self.quantise(EnergyBank.balance(inputs)!.balance)
        })
        XCTAssertEqual(v.status, .calibrating)
        XCTAssertEqual(v.days, 5)
    }

    func testCheckInsWithoutInputsOrOutOfRangeDoNotCount() {
        var list = checkIns(seed: 5, count: 20, days: 20) { inputs, _ in
            self.quantise(EnergyBank.balance(inputs)!.balance)
        }
        for i in 0..<10 { list[i].inputs = nil }                 // pending, never matched
        list.append(EnergyCheckIn(at: Date(), day: "x", slot: .afternoon, felt: 9,
                                  inputs: EnergyInputs(recovery: 50)))
        let v = EnergyCalibration.evaluate(list)
        XCTAssertEqual(v.usable, 10)
        XCTAssertEqual(v.status, .calibrating)
    }

    func testTracksWhenTheReportsFollowTheModel() {
        let v = EnergyCalibration.evaluate(checkIns(seed: 5, count: 20, days: 20) { inputs, _ in
            self.quantise(EnergyBank.balance(inputs)!.balance)
        })
        XCTAssertEqual(v.status, .tracks)
        XCTAssertEqual(v.before?.rho ?? 0, 0.953, accuracy: 0.01)
        XCTAssertEqual(v.after?.rho ?? 0, 0.944, accuracy: 0.01)
        XCTAssertFalse(v.fitted, "the fit did no better out of sample, so the defaults stand")
        XCTAssertEqual(EnergyCalibration.tileMode(balance: EnergyBank.balance(EnergyInputs(recovery: 70)),
                                                  verdict: v), .energy)
    }

    func testWeakAgreementRelabelsTheTileAsALoadEstimate() {
        let v = EnergyCalibration.evaluate(checkIns(seed: 6, count: 20, days: 20) { _, g in
            1 + Int(g.next() * 5)
        })
        XCTAssertEqual(v.status, .weak)
        XCTAssertLessThan(v.decidingAgreement?.rho ?? 0, EnergyCalibration.weakRho)
        let mode = EnergyCalibration.tileMode(balance: EnergyBank.balance(EnergyInputs(recovery: 70)), verdict: v)
        XCTAssertEqual(mode, .loadEstimate)
        XCTAssertEqual(EnergyCalibration.displayValue(71.4, mode: mode), "≈70",
                       "a figure that does not track the wearer is never printed to the point")
    }

    func testTheFitImprovesAgreementForAWearerTheDefaultsMisread() {
        // Strain does not tire this wearer; hours awake do.
        let wearer = EnergyBank.Parameters(bias: 0, recoveryShare: 0.7, strainCost: 0, stressCost: 25,
                                           restReturnMax: 15, awakeCostPerHour: 4)
        let v = EnergyCalibration.evaluate(checkIns(seed: 8, count: 40, days: 40) { inputs, _ in
            self.quantise(EnergyCalibration.linearPrediction(EnergyBank.features(inputs)!, wearer))
        })
        XCTAssertEqual(v.status, .tracks)
        XCTAssertTrue(v.fitted)
        XCTAssertEqual(v.before?.rho ?? 0, 0.588, accuracy: 0.01)
        XCTAssertEqual(v.after?.rho ?? 0, 0.924, accuracy: 0.01)
        XCTAssertLessThan(v.params.strainCost, 15)
        XCTAssertGreaterThan(v.params.awakeCostPerHour, 2.5)
    }

    // MARK: - What the tile shows

    func testTheCalibratingStateIsAnApproximateEstimateWithProgress() {
        let v = EnergyCalibration.evaluate([])
        let mode = EnergyCalibration.tileMode(balance: EnergyBank.balance(EnergyInputs(recovery: 73)), verdict: v)
        XCTAssertEqual(mode, .calibrating(checkIns: 0, needed: 14, days: 0, neededDays: 10))
        XCTAssertEqual(EnergyCalibration.displayValue(73, mode: mode), "≈75")
        XCTAssertEqual(EnergyCalibration.displayValue(72.4, mode: mode), "≈70")
        XCTAssertFalse(EnergyCalibration.displayValue(72.4, mode: mode).contains("."), "never a decimal")
    }

    func testTheValueIsExactOnlyOnceItTracks() {
        XCTAssertEqual(EnergyCalibration.displayValue(72.4, mode: .energy), "72")
        XCTAssertEqual(EnergyCalibration.displayValue(nil, mode: .energy), "–")
        XCTAssertEqual(EnergyCalibration.displayValue(.nan, mode: .energy), "–")
        XCTAssertEqual(EnergyCalibration.tileMode(balance: nil, verdict: EnergyCalibration.evaluate([])), .unknown)
    }
}
