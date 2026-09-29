import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-B.9 — the analysis of an N-of-1 habit trial.
///
/// Simulation tests use 500 permutations per analysed trial (the registered production count is 10,000)
/// to keep `swift test` in debug mode well under half a minute. The Monte-Carlo p-value
/// `(1 + #extreme)/(1 + B)` is a valid test for ANY B, so a smaller B costs only resolution, never
/// validity. `testEmpiricalFalsePositiveRateFullPermutations` re-runs the 2,000-trial simulation with the
/// full 10,000 when `STRAND_SLOW_TESTS=1`.
///
/// Every simulated rate below was cross-checked on an independent Python/NumPy re-implementation of the
/// same algorithm with the same SplitMix64 streams (same seeds, same draw order); the expected values are
/// quoted next to each assertion.
final class HabitTrialAnalysisTests: XCTestCase {

    // MARK: 2. Known effect

    func testKnownEffectDetectedIID() {
        // i.i.d. σ = 1, true effect 1.5σ, L = 28, MCID 0.5 → Helped ≥ 80 % of 200; interval covers the
        // truth in ≥ 92 %. Reference twin: Helped 189/200, covered 191/200.
        var helped = 0, covered = 0
        for r in 0..<200 {
            let reg = TrialSim.registration(seed: TrialSim.repSeed(0x2000, r) & TrialSim.mask53, mcid: 0.5)
            let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x2001, r), effect: 1.5)
            let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
            if res.verdict == .helped { helped += 1 }
            if let lo = res.lower, let hi = res.upper, lo <= 1.5, 1.5 <= hi { covered += 1 }
        }
        print("HabitTrial known effect (iid): Helped \(helped)/200, interval covered truth \(covered)/200")
        XCTAssertGreaterThanOrEqual(helped, 160)
        XCTAssertGreaterThanOrEqual(covered, 184)
    }

    func testKnownEffectDetectedUnderAutocorrelation() {
        // AR(1) ρ = 0.5 (marginal σ = 1), effect 2σ, L = 56 → Helped ≥ 80 %. Reference twin: 200/200.
        var helped = 0
        for r in 0..<200 {
            let reg = TrialSim.registration(length: 56, seed: TrialSim.repSeed(0x3000, r) & TrialSim.mask53,
                                            mcid: 0.5)
            let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x3001, r), effect: 2.0, rho: 0.5)
            let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
            if res.verdict == .helped { helped += 1 }
        }
        print("HabitTrial known effect (AR 0.5, L 56): Helped \(helped)/200")
        XCTAssertGreaterThanOrEqual(helped, 160)
    }

    // MARK: 4. The null is not an effect

    func testNullIsNotAnEffect() {
        // Effect 0; half i.i.d., half AR(1) ρ = 0.5; linear drift and weekday seasonality.
        // Helped ≤ 2.5 % + binomial tolerance: ≤ 4.5 % of 1,000. Reference twin: 19/1000 (1.9 %).
        var helped = 0
        for r in 0..<1000 {
            let reg = TrialSim.registration(seed: TrialSim.repSeed(0x4000, r) & TrialSim.mask53, mcid: 0.5)
            let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x4001, r), effect: 0,
                                        rho: r % 2 == 0 ? 0 : 0.5, drift: 1.0, weekday: true)
            let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
            if res.verdict == .helped { helped += 1 }
        }
        print("HabitTrial null (drift + weekday, iid/AR): Helped \(helped)/1000")
        XCTAssertLessThanOrEqual(helped, 45)
    }

    // MARK: 5. Empirical false-positive simulation

    func testEmpiricalFalsePositiveRate() {
        runFalsePositiveSimulation(permutations: 500)
    }

    func testEmpiricalFalsePositiveRateFullPermutations() throws {
        guard ProcessInfo.processInfo.environment["STRAND_SLOW_TESTS"] == "1" else {
            throw XCTSkip("Slow (2,000 trials × 10,000 permutations); set STRAND_SLOW_TESTS=1 to run.")
        }
        runFalsePositiveSimulation(permutations: 10_000)
    }

    /// 2,000 null trials mixing ρ ∈ {0, 0.3, 0.6}, 15 % MCAR missing nights, 20 % non-adherence on ON days,
    /// drift and weekday seasonality. Asserts Helped ≤ 3.5 % and "interval excludes zero on the beneficial
    /// side" ≤ 3.5 %, both over all runs and over the runs that passed every gate.
    ///
    /// Precision: with 2,000 runs, a true rate of 2.5 % has a binomial SE of 0.35 percentage points, so the
    /// 3.5 % bound sits ~2.9 SE above the nominal rate. Reference twin (500 permutations): Helped 35/2000
    /// (1.75 %); excludes zero 38/2000 (1.9 %), 38/1591 of the analysed runs (2.4 %).
    private func runFalsePositiveSimulation(permutations: Int) {
        var helped = 0, excludesZero = 0, analysed = 0
        var gates: [HabitTrialInconclusiveReason: Int] = [:]
        let rhos = [0.0, 0.3, 0.6]
        let runs = 2000
        for r in 0..<runs {
            let reg = TrialSim.registration(seed: TrialSim.repSeed(0x5000, r) & TrialSim.mask53, mcid: 0.5,
                                            permutations: permutations)
            let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x5001, r), effect: 0, rho: rhos[r % 3],
                                        drift: 0.5, weekday: true, missing: 0.15, nonAdherence: 0.2)
            let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
            if res.verdict == .helped { helped += 1 }
            if let g = res.gate { gates[g, default: 0] += 1 }
            if let lo = res.lower {
                analysed += 1
                if lo > 0 { excludesZero += 1 }
            }
        }
        let helpedRate = Double(helped) / Double(runs)
        let exclRate = Double(excludesZero) / Double(runs)
        let exclRateAnalysed = analysed > 0 ? Double(excludesZero) / Double(analysed) : 0
        let rates = String(format: "Helped %.2f%%; interval excludes 0 (beneficial side) %.2f%% of all runs, "
                           + "%.2f%% of analysed runs", helpedRate * 100, exclRate * 100, exclRateAnalysed * 100)
        let gateText = gates.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ", ")
        print("HabitTrial empirical FPR (\(permutations) permutations, \(runs) null trials): Helped \(helped), "
              + "excludes-zero \(excludesZero), analysed \(analysed). \(rates). Gates: \(gateText)")
        XCTAssertLessThanOrEqual(helpedRate, 0.035)
        XCTAssertLessThanOrEqual(exclRate, 0.035)
        XCTAssertLessThanOrEqual(exclRateAnalysed, 0.035)
        XCTAssertGreaterThan(analysed, 1000, "most null trials should pass the gates")
    }

    // MARK: 6. Confounded adherence

    func testConfoundedAdherenceDoesNotManufactureAnEffect() {
        // Null effect, but the wearer skips the three LOWEST-outcome ON days (adherence 11/14 = 79 %, above
        // the gate). ITT must not say Helped more than chance; per-protocol (exploratory) is allowed to look
        // better and must not reach the verdict. Reference twin: Helped 2/200; mean ITT 0.06, mean PP 0.42.
        var helped = 0
        var ittSum = 0.0, ppSum = 0.0, count = 0
        for r in 0..<200 {
            let reg = TrialSim.registration(seed: TrialSim.repSeed(0x6000, r) & TrialSim.mask53, mcid: 0.5)
            var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x6001, r), effect: 0)
            var onDays: [(value: Double, day: String)] = []
            for i in 0..<reg.lengthDays where reg.schedule[i] {
                let day = HabitDay.adding(i, to: reg.startDay)!
                let key = HabitDay.adding(1, to: day)!
                onDays.append((value: obs.outcomes[key] ?? 1e9, day: day))
            }
            onDays.sort { $0.value < $1.value }
            for d in onDays.prefix(3) { obs.behaviour[d.day] = .didNot }
            let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
            if res.verdict == .helped { helped += 1 }
            if let itt = res.estimate, let pp = res.perProtocol?.estimate {
                ittSum += itt
                ppSum += pp
                count += 1
            }
            // The verdict is a function of the ITT interval alone.
            XCTAssertEqual(res.verdict, HabitTrialVerdict.decide(result: res, registration: reg))
        }
        print("HabitTrial confounded adherence: ITT Helped \(helped)/200; mean ITT \(ittSum / Double(max(count, 1))), "
              + "mean per-protocol \(ppSum / Double(max(count, 1)))")
        XCTAssertLessThanOrEqual(helped, 9)
        XCTAssertGreaterThan(count, 150)
        XCTAssertGreaterThan(ppSum / Double(count), ittSum / Double(count) + 0.2,
                             "per-protocol should look better here — that is exactly why it never decides")
    }

    // MARK: 7–9. Missing nights, lopsided missingness, adherence

    func testMissingNightsAreMissingNotZero() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x7A, 0) & TrialSim.mask53, mcid: 0.5)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x7B, 0), effect: 1.0)
        let onKeys = TrialSim.outcomeKeys(reg, on: true)
        var dropped = obs
        for key in onKeys.prefix(3) { dropped.outcomes[key] = nil }
        var zeroed = obs
        for key in onKeys.prefix(3) { zeroed.outcomes[key] = 0 }

        let full = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: dropped)
        let zero = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: zeroed)
        XCTAssertEqual(full.nOn, 14)
        XCTAssertEqual(res.nOn, 11)
        XCTAssertEqual(res.missingOn, 3)
        XCTAssertEqual(res.nOff, 14)

        // The estimate is the OLS fit on the remaining rows — the dropped nights take no part at all.
        var y: [Double] = [], idx: [Int] = [], z: [[Double]] = []
        for i in 0..<reg.lengthDays {
            let day = HabitDay.adding(i, to: reg.startDay)!
            guard let v = dropped.outcomes[HabitDay.adding(1, to: day)!], let e = dropped.effort[day] else { continue }
            y.append(v)
            idx.append(i)
            z.append([1, e, Double(i)])
        }
        let fit = HabitTrialAnalysis.fitOLS(y: y, rowsIdx: idx, zRows: z, assignment: reg.schedule, useShort: false)
        XCTAssertNotNil(fit)
        XCTAssertEqual(res.estimate!, fit!.coefficients[3], accuracy: 1e-9)
        // …and it is nothing like what zeros would have produced (twin: 1.56 vs 0.31).
        XCTAssertGreaterThan(abs(res.estimate! - zero.estimate!), 0.5)
    }

    func testNineValidOnDaysIsTooFew() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x7A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x7B, 0), effect: 1.0)
        for key in TrialSim.outcomeKeys(reg, on: true).prefix(5) { obs.outcomes[key] = nil }
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.nOn, 9)
        XCTAssertEqual(res.verdict, .inconclusive(.tooFewDays))
        XCTAssertNil(res.estimate, "a gated trial exposes no estimate")
        XCTAssertEqual(res.moreValidDaysNeeded, 1)
    }

    func testLopsidedMissingness() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x7A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x7B, 0), effect: 1.0)
        for key in TrialSim.outcomeKeys(reg, on: true).prefix(4) { obs.outcomes[key] = nil }
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.nOn, 10)        // enough on its own…
        XCTAssertEqual(res.verdict, .inconclusive(.missingImbalance))   // …but 4 vs 0 missing is lopsided
    }

    func testAdherenceGate() {
        // 9 of 14 ON days followed (64 %) with a large true effect ⇒ still Inconclusive(adherence).
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x9A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x9B, 0), effect: 2.0)
        var onDays: [String] = []
        for i in 0..<reg.lengthDays where reg.schedule[i] { onDays.append(HabitDay.adding(i, to: reg.startDay)!) }
        for day in onDays.prefix(5) { obs.behaviour[day] = .didNot }
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.adherenceOn, 9.0 / 14.0, accuracy: 1e-12)
        XCTAssertEqual(res.verdict, .inconclusive(.adherence))
        XCTAssertNil(res.estimate)
    }

    func testContaminationGate() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x9A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x9B, 0), effect: 2.0)
        var offDays: [String] = []
        for i in 0..<reg.lengthDays where !reg.schedule[i] { offDays.append(HabitDay.adding(i, to: reg.startDay)!) }
        for day in offDays.prefix(5) { obs.behaviour[day] = .did }     // 5/14 = 36 % > 30 %
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.verdict, .inconclusive(.adherence))
    }

    func testUnknownAnswersCountAsNotFollowed() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x9A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x9B, 0), effect: 2.0)
        obs.behaviour = [:]          // nobody answered anything
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.adherenceOn, 0)
        XCTAssertEqual(res.verdict, .inconclusive(.adherence))
    }

    func testIllnessGate() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x9A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x9B, 0), effect: 2.0)
        obs.illnessRaisedDays = Set((3..<6).map { HabitDay.adding($0, to: reg.startDay)! })
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.illnessDays, 3)
        XCTAssertEqual(res.verdict, .inconclusive(.illness))
        // Two flagged days are not enough, and flagged days are NOT excluded individually.
        obs.illnessRaisedDays = Set((3..<5).map { HabitDay.adding($0, to: reg.startDay)! })
        let res2 = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertNotEqual(res2.gate, .illness)
        XCTAssertEqual(res2.nOn + res2.nOff, 28)
    }

    // MARK: 10–12. Below the MCID, harmful direction, wide interval

    func testEffectBelowMCIDIsNoMeaningfulEffect() {
        // L = 56, σ = 0.25 × MCID, true effect 0.3 × MCID. Twin: τ̂ 0.32, interval [0.16, 0.50], MCID 1.
        let reg = TrialSim.registration(length: 56, seed: TrialSim.repSeed(0x10A, 0) & TrialSim.mask53, mcid: 1.0)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x10B, 0), effect: 0.3, sigma: 0.25)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.verdict, .noMeaningfulEffect(pointedOtherWay: false))
        XCTAssertGreaterThan(res.lower!, 0, "a statistically clear effect…")
        XCTAssertLessThan(res.upper!, 1.0, "…smaller than the MCID is not a win")
    }

    func testHarmfulDirection() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x11A, 0) & TrialSim.mask53, mcid: 0.5)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x11B, 0), effect: -1.5)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.verdict, .noMeaningfulEffect(pointedOtherWay: true))
    }

    func testWideIntervalIsInconclusive() {
        // Both arms at the 10-day minimum, small effect.
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x12A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x12B, 0), effect: 0.3)
        for key in TrialSim.outcomeKeys(reg, on: true).prefix(4) + TrialSim.outcomeKeys(reg, on: false).prefix(4) {
            obs.outcomes[key] = nil
        }
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.nOn, 10)
        XCTAssertEqual(res.nOff, 10)
        XCTAssertEqual(res.verdict, .inconclusive(.imprecise))
        XCTAssertNotNil(res.estimate, "an imprecise result still shows its (wide) interval")
        XCTAssertLessThanOrEqual(res.lower!, 0)
        XCTAssertGreaterThanOrEqual(res.upper!, 0.5)
        XCTAssertNotNil(res.moreValidDaysNeeded)
    }

    // MARK: 13. Stopped early

    func testStoppedEarlyRunsNoAnalysis() {
        let reg = TrialSim.registration(seed: 7, mcid: 0.5)
        let res = HabitTrialAnalysis.stoppedEarly(registration: reg, storedHash: reg.hash)
        XCTAssertEqual(res.verdict, .inconclusive(.stoppedEarly))
        XCTAssertNil(res.estimate)
        XCTAssertNil(res.lower)
        XCTAssertNil(res.pOneSided)
        XCTAssertNil(res.meanOn)
        XCTAssertEqual(res.permutations, 0)
    }

    // MARK: 14. Covariates absorb chance confounding

    func testCovariateAbsorbsConfounding() {
        // Effort happens to be higher on ON days and depresses the outcome. Twin: adjusted 0.467, raw 0.106.
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x14A, 0) & TrialSim.mask53, mcid: 0.5)
        var rng = DeterministicRNG(seed: TrialSim.repSeed(0x14B, 0))
        var outcomes: [String: Double] = [:], effort: [String: Double] = [:]
        var behaviour: [String: HabitTrialBehaviour] = [:]
        var onVals: [Double] = [], offVals: [Double] = []
        for i in 0..<reg.lengthDays {
            let on = reg.schedule[i]
            let u = rng.nextDouble()
            let z = rng.nextGaussian()
            let e = (on ? 11.0 : 7.0) + 6.0 * u
            let y = 4.0 + (on ? 0.5 : 0.0) - 0.1 * e + 0.05 * z
            let day = HabitDay.adding(i, to: reg.startDay)!
            outcomes[HabitDay.adding(1, to: day)!] = y
            effort[day] = e
            behaviour[day] = on ? .did : .didNot
            if on { onVals.append(y) } else { offVals.append(y) }
        }
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash,
                                             observations: HabitTrialObservations(outcomes: outcomes, effort: effort,
                                                                                  behaviour: behaviour))
        let raw = HabitStats.mean(onVals)! - HabitStats.mean(offVals)!
        XCTAssertEqual(res.estimate!, 0.5, accuracy: 0.1)
        XCTAssertGreaterThan(abs(raw - 0.5), 0.3)
    }

    // MARK: 15. Determinism

    func testDeterminism() throws {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x15A, 0) & TrialSim.mask53, mcid: 0.5,
                                        permutations: 10_000)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x15B, 0), effect: 0.8, rho: 0.3, missing: 0.1)
        let a = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        let b = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(a, b)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try enc.encode(a), try enc.encode(b))
        XCTAssertEqual(a.permutations, 10_000)
    }

    // MARK: 16. Registration immutability

    func testAlteredRecordGivesNoVerdict() {
        let reg = TrialSim.registration(seed: 11, mcid: 0.5)
        let stored = reg.hash
        // The same record with a looser MCID written over it.
        let tampered = TrialSim.registration(seed: 11, mcid: 0.1)
        let obs = TrialSim.simulate(tampered, seed: 12, effect: 2.0)
        let res = HabitTrialAnalysis.analyse(registration: tampered, storedHash: stored, observations: obs)
        XCTAssertFalse(res.recordIntact)
        XCTAssertNil(res.verdict)
        XCTAssertNil(res.estimate)
        XCTAssertEqual(HabitTrialCopy.altered, "Trial record altered — no verdict.")
    }

    func testScheduleNotFromSeedIsTreatedAsAltered() {
        let reg = TrialSim.registration(seed: 11, mcid: 0.5)
        var flipped = reg.schedule
        flipped[0].toggle()
        flipped[7].toggle()
        let forged = TrialSim.registration(seed: 11, mcid: 0.5, schedule: flipped)
        let res = HabitTrialAnalysis.analyse(registration: forged, storedHash: forged.hash,
                                             observations: TrialSim.simulate(forged, seed: 3, effect: 2))
        XCTAssertNil(res.verdict, "a schedule that the registered seed does not reproduce is not the randomised one")
    }

    // MARK: Designs and directions

    func testDecreaseDirection() {
        // A habit that LOWERS the outcome where lower is better (e.g. RHR).
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x16A, 0) & TrialSim.mask53, mcid: 0.5,
                                        direction: .decrease, outcome: .nightRhr)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x16B, 0), effect: -2.5)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.verdict, .helped)
        XCTAssertLessThan(res.upper!, 0)
        XCTAssertLessThan(res.pOneSided!, 0.025)
    }

    func testBlockedDesignExcludesWashoutDays() {
        let reg = TrialSim.registration(design: .phaseBlocks, length: 48,
                                        seed: TrialSim.repSeed(0x17A, 0) & TrialSim.mask53, mcid: 0.5)
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x17B, 0), effect: 2.0)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.washoutDays, 12)
        XCTAssertEqual(res.plannedPerArm, 18)
        XCTAssertEqual(res.nOn, 18)
        XCTAssertEqual(res.nOff, 18)
        XCTAssertEqual(res.verdict, .helped)
    }

    func testShortCarryOverRuns() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x18A, 0) & TrialSim.mask53, mcid: 0.5,
                                        carryOver: .short)
        XCTAssertTrue(reg.covariates.contains(.prevAssignedOn))
        let obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x18B, 0), effect: 2.0)
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.verdict, .helped)
    }

    func testMissingEffortDropsTheDayFromTheAnalysis() {
        let reg = TrialSim.registration(seed: TrialSim.repSeed(0x7A, 0) & TrialSim.mask53, mcid: 0.5)
        var obs = TrialSim.simulate(reg, seed: TrialSim.repSeed(0x7B, 0), effect: 1.0)
        obs.effort[reg.startDay] = nil
        let res = HabitTrialAnalysis.analyse(registration: reg, storedHash: reg.hash, observations: obs)
        XCTAssertEqual(res.droppedForCovariate, 1)
        XCTAssertEqual(res.nOn + res.nOff, 27)
    }

    func testMinimumDetectableEffect() {
        // 2.8 · 1 · √(2/14) · √(1) = 1.0583
        XCTAssertEqual(HabitTrialAnalysis.minimumDetectableEffect(sd: 1, rho: 0, nOn: 14, nOff: 14)!,
                       2.8 * (2.0 / 14).squareRoot(), accuracy: 1e-12)
        // ρ clamped to 0.6 → √4 = 2
        XCTAssertEqual(HabitTrialAnalysis.minimumDetectableEffect(sd: 1, rho: 0.9, nOn: 14, nOff: 14)!,
                       2.8 * (2.0 / 14).squareRoot() * 2, accuracy: 1e-12)
        XCTAssertEqual(HabitTrialAnalysis.minimumDetectableEffect(sd: 1, rho: -0.4, nOn: 14, nOff: 14)!,
                       2.8 * (2.0 / 14).squareRoot(), accuracy: 1e-12)
        XCTAssertNil(HabitTrialAnalysis.minimumDetectableEffect(sd: 1, rho: 0, nOn: 0, nOff: 14))
    }
}

// MARK: - Simulation support

/// The synthetic-trial generator. Its draw order is part of the reference-twin contract: per day, one
/// Gaussian (noise), then Effort, then the missingness uniform, then the adherence uniform.
enum TrialSim {
    static let start = "2026-01-05"   // a Monday
    static let mask53: UInt64 = (1 << 53) - 1
    static let weekdayPattern = [0.0, 0.0, 0.0, 0.0, 0.3, 0.5, 0.2]

    static func repSeed(_ base: UInt64, _ r: Int) -> UInt64 {
        DeterministicRNG.mix(base &+ UInt64(r + 1) &* DeterministicRNG.gamma)
    }

    static func registration(design: HabitTrialDesign = .weekdayBalanced, length: Int = 28, seed: UInt64,
                             mcid: Double, direction: EffectDirection = .increase,
                             carryOver: HabitTrialCarryOver = .none, affectsEffort: Bool = false,
                             permutations: Int = 500, outcome: HabitOutcome = .nightHrvLn,
                             schedule: [Bool]? = nil) -> HabitTrialRegistration {
        let sched = schedule ?? HabitTrialSchedule.assignments(design: design, lengthDays: length, seed: seed)
        return HabitTrialRegistration(
            trialId: "sim.\(seed)", interventionId: "sim", registeredOn: HabitDay.adding(-1, to: start)!,
            startDay: start, lengthDays: length, design: design, carryOver: carryOver, primaryOutcome: outcome,
            direction: direction, lag: .nightAfter, mcid: mcid, secondaryOutcomes: [],
            covariates: HabitTrialRegistration.covariates(design: design, carryOver: carryOver,
                                                          affectsEffort: affectsEffort),
            affectsEffort: affectsEffort, seed: seed, schedule: sched, permutations: permutations,
            baselineNights: 28, baselineSD: 1, baselineRho: 0, baselineMedian: 4, mde: nil)
    }

    static func simulate(_ reg: HabitTrialRegistration, seed: UInt64, effect: Double, sigma: Double = 1,
                         rho: Double = 0, drift: Double = 0, weekday: Bool = false, missing: Double = 0,
                         nonAdherence: Double = 0, effortEffect: Double = 0) -> HabitTrialObservations {
        var rng = DeterministicRNG(seed: seed)
        var outcomes: [String: Double] = [:], effort: [String: Double] = [:]
        var behaviour: [String: HabitTrialBehaviour] = [:]
        var ePrev = 0.0
        let L = reg.lengthDays
        for i in 0..<L {
            let z = rng.nextGaussian()
            let e = i == 0 ? z : rho * ePrev + (1 - rho * rho).squareRoot() * z
            ePrev = e
            let eff = rng.nextDouble() * 21.0
            let um = rng.nextDouble()
            let ua = rng.nextDouble()
            let day = HabitDay.adding(i, to: reg.startDay)!
            let on = reg.schedule[i]
            let season = weekday ? sigma * weekdayPattern[HabitDay.isoWeekday(day)! - 1] : 0
            let y = 4.0 + (on ? effect : 0.0) + sigma * e + drift * Double(i) / Double(L) + season - effortEffect * eff
            if um >= missing { outcomes[HabitDay.adding(1, to: day)!] = y }
            effort[day] = eff
            behaviour[day] = on ? (ua < nonAdherence ? .didNot : .did) : .didNot
        }
        return HabitTrialObservations(outcomes: outcomes, effort: effort, behaviour: behaviour)
    }

    /// Outcome keys of the ON (or OFF) days, in day order.
    static func outcomeKeys(_ reg: HabitTrialRegistration, on: Bool) -> [String] {
        (0..<reg.lengthDays).compactMap { i in
            guard reg.schedule[i] == on, let day = HabitDay.adding(i, to: reg.startDay) else { return nil }
            return HabitDay.adding(1, to: day)
        }
    }
}
