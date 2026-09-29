import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-A.3 — associations: labelled, adjusted, HAC intervals, BH across habits, and "not logged"
/// never read as "no". Simulated rates were cross-checked on an independent NumPy re-implementation with
/// the same SplitMix64 streams; the reference values are quoted beside each assertion.
final class HabitAssociationTests: XCTestCase {

    static let asOf = "2026-06-30"
    static var windowStart: String { HabitDay.adding(-89, to: asOf)! }

    private func night(_ k: Int) -> String { HabitDay.adding(k, to: Self.windowStart)! }

    // MARK: Known effect

    func testSyntheticEffectTwiceMCIDIsAPossibleLink() {
        // Late caffeine shortens sleep by 30 min (= 2 × the 15-min MCID); 40 yes / 40 no observed nights,
        // 10 nights with no observation at all.
        var rng = DeterministicRNG(seed: 0xA1)
        var obs: [HabitObservation] = []
        var sleep: [String: Double] = [:], effort: [String: Double] = [:]
        var observed = 0
        for k in 0..<90 {
            let n = night(k)
            effort[HabitDay.adding(-1, to: n)!] = rng.nextDouble() * 21
            let noise = 20 * rng.nextGaussian()
            if k % 9 == 0 {
                sleep[n] = 420 + noise
                continue
            }
            let yes = observed % 2 == 0
            observed += 1
            obs.append(HabitObservation(nightKey: n, habit: HabitCatalog.lateCaffeineAuto, state: yes ? .yes : .no,
                                        source: .caffeineLog))
            sleep[n] = 420 - (yes ? 30 : 0) + noise
        }
        let report = HabitAssociation.analyse(
            inputs: HabitLedgerInputs(observations: obs, outcomes: [.totalSleepMin: sleep], effortByDay: effort),
            asOf: Self.asOf)
        let row = report.rows.first { $0.habit == HabitCatalog.lateCaffeineAuto }!
        XCTAssertEqual(row.yesCount, 40)
        XCTAssertEqual(row.noCount, 40)
        XCTAssertEqual(row.label, .possibleLink)
        XCTAssertEqual(row.estimate!, -30, accuracy: 12)
        XCTAssertEqual(row.mcid, 15)
        XCTAssertTrue(HabitAssociationCopy.sentence(row).contains("pattern, not proof"))
        XCTAssertFalse(HabitAssociationCopy.sentence(row).lowercased().contains("cause"))
    }

    // MARK: False discoveries under the null

    func testNullDataOverTwentyHabitsIsFDRControlled() {
        // 200 runs × 20 independent habits × 90 nights, no effect. Any possibleLink in ≤ 10 % of runs.
        // Reference twin: 11/200 runs (5.5 %); over 1,000 runs 8.8 %.
        var runsWithLink = 0
        let defs = (0..<20).map { HabitCatalog.custom(question: "Habit \($0)", primary: .totalSleepMin) }
        for r in 0..<200 {
            var rng = DeterministicRNG(seed: DeterministicRNG.mix(0xA2 &+ UInt64(r + 1) &* DeterministicRNG.gamma))
            var obs: [HabitObservation] = []
            var sleep: [String: Double] = [:], effort: [String: Double] = [:]
            for k in 0..<90 {
                let n = night(k)
                effort[HabitDay.adding(-1, to: n)!] = rng.nextDouble() * 21
                sleep[n] = 420 + 60 * rng.nextGaussian()
                for d in defs {
                    obs.append(HabitObservation(nightKey: n, habit: d.id, state: rng.nextDouble() < 0.5 ? .yes : .no,
                                                source: .journal))
                }
            }
            let report = HabitAssociation.analyse(
                inputs: HabitLedgerInputs(observations: obs, outcomes: [.totalSleepMin: sleep], effortByDay: effort,
                                          customDefinitions: defs),
                asOf: Self.asOf)
            XCTAssertEqual(report.rows.count, 20)
            if report.rows.contains(where: { $0.label == .possibleLink }) { runsWithLink += 1 }
        }
        print("HabitAssociation null (20 habits): runs with any possible link \(runsWithLink)/200")
        XCTAssertLessThanOrEqual(runsWithLink, 20)
    }

    func testAutocorrelatedNullIntervalCoverage() {
        // AR(1) ρ = 0.5 outcome AND a persistent habit (Markov, stay-probability 0.75): the case where naive
        // OLS intervals are too narrow. Coverage of the true 0 must be ≥ 90 %. Reference twin: 460/500.
        let def = HabitCatalog.custom(question: "Persistent habit", primary: .nightHrvLn)
        var covered = 0, total = 0
        for r in 0..<500 {
            var rng = DeterministicRNG(seed: DeterministicRNG.mix(0xA3 &+ UInt64(r + 1) &* DeterministicRNG.gamma))
            var obs: [HabitObservation] = []
            var hrv: [String: Double] = [:], effort: [String: Double] = [:]
            var ePrev = 0.0
            var prevYes = false
            for k in 0..<90 {
                let n = night(k)
                let z = rng.nextGaussian()
                let e = k == 0 ? z : 0.5 * ePrev + (1 - 0.25).squareRoot() * z
                ePrev = e
                let u = rng.nextDouble()
                let yes = k == 0 ? u < 0.5 : u < (prevYes ? 0.75 : 0.25)
                prevYes = yes
                effort[HabitDay.adding(-1, to: n)!] = rng.nextDouble() * 21
                hrv[n] = 4.0 + 0.3 * e
                obs.append(HabitObservation(nightKey: n, habit: def.id, state: yes ? .yes : .no, source: .journal))
            }
            let report = HabitAssociation.analyse(
                inputs: HabitLedgerInputs(observations: obs, outcomes: [.nightHrvLn: hrv], effortByDay: effort,
                                          customDefinitions: [def]),
                asOf: Self.asOf)
            guard let row = report.rows.first, let lo = row.lower, let hi = row.upper else { continue }
            total += 1
            if lo <= 0 && 0 <= hi { covered += 1 }
        }
        print("HabitAssociation AR(1) 0.5 null coverage: \(covered)/\(total)")
        XCTAssertGreaterThanOrEqual(total, 450)
        XCTAssertGreaterThanOrEqual(Double(covered) / Double(total), 0.90)
    }

    // MARK: Gates, absence, co-occurrence

    private func simpleInputs(yes: Int, no: Int, habit: HabitId = HabitCatalog.alcohol) -> HabitLedgerInputs {
        var obs: [HabitObservation] = []
        var hrv: [String: Double] = [:], effort: [String: Double] = [:]
        var rng = DeterministicRNG(seed: 9)
        for k in 0..<90 {
            let n = night(k)
            effort[HabitDay.adding(-1, to: n)!] = rng.nextDouble() * 21
            hrv[n] = 4 + 0.2 * rng.nextGaussian()
            if k < yes {
                obs.append(HabitObservation(nightKey: n, habit: habit, state: .yes, source: .journal))
            } else if k < yes + no {
                obs.append(HabitObservation(nightKey: n, habit: habit, state: .no, source: .journal))
            }
        }
        return HabitLedgerInputs(observations: obs, outcomes: [.nightHrvLn: hrv], effortByDay: effort)
    }

    func testGateAtSevenVersusEight() {
        let seven = HabitAssociation.analyse(inputs: simpleInputs(yes: 7, no: 30), asOf: Self.asOf).rows.first!
        XCTAssertEqual(seven.label, .notEnoughData)
        XCTAssertNil(seven.estimate)
        XCTAssertEqual(seven.absence, .tooFewNights(have: 7, need: 8))
        let eight = HabitAssociation.analyse(inputs: simpleInputs(yes: 8, no: 30), asOf: Self.asOf).rows.first!
        XCTAssertNotEqual(eight.label, .notEnoughData)
        XCTAssertNotNil(eight.estimate)
    }

    func testNotLoggedIsNeverNo() {
        // 20 logged "yes" nights and 70 nights with an outcome but no journal row: there is no "no" group.
        let row = HabitAssociation.analyse(inputs: simpleInputs(yes: 20, no: 0), asOf: Self.asOf).rows.first!
        XCTAssertEqual(row.yesCount, 20)
        XCTAssertEqual(row.noCount, 0, "unlogged nights must not become a control group")
        XCTAssertEqual(row.label, .notEnoughData)
    }

    func testContextAndSupplementHabitsAreCountedNeverTested() {
        var inputs = simpleInputs(yes: 20, no: 20, habit: HabitCatalog.stressed)
        inputs.observations += simpleInputs(yes: 15, no: 15, habit: HabitCatalog.magnesium).observations
        let report = HabitAssociation.analyse(inputs: inputs, asOf: Self.asOf)
        XCTAssertTrue(report.rows.isEmpty, "no association row, no label, no BH slot")
        XCTAssertEqual(Set(report.alsoLogged.map { $0.habit }), [HabitCatalog.stressed, HabitCatalog.magnesium])
        XCTAssertEqual(report.alsoLogged.first { $0.habit == HabitCatalog.stressed }?.yesCount, 20)
    }

    func testCooccurrenceFlag() {
        var inputs = simpleInputs(yes: 10, no: 30, habit: HabitCatalog.alcohol)
        // Late meal on nights 0–8 and 20: Jaccard with alcohol (0–9) = 9/11 ≈ 0.82.
        for k in Array(0..<9) + [20] {
            inputs.observations.append(HabitObservation(nightKey: night(k), habit: HabitCatalog.lateMeal, state: .yes,
                                                        source: .journal))
        }
        // Screens on nights 50–59: no overlap.
        for k in 50..<60 {
            inputs.observations.append(HabitObservation(nightKey: night(k), habit: HabitCatalog.screenInBed, state: .yes,
                                                        source: .journal))
        }
        let report = HabitAssociation.analyse(inputs: inputs, asOf: Self.asOf)
        let alcohol = report.rows.first { $0.habit == HabitCatalog.alcohol }!
        XCTAssertEqual(alcohol.cooccursWith, [HabitCatalog.lateMeal])
        XCTAssertNotNil(HabitAssociationCopy.cooccurrence(alcohol.cooccurLabels))
        let screen = report.rows.first { $0.habit == HabitCatalog.screenInBed }!
        XCTAssertTrue(screen.cooccursWith.isEmpty)
    }

    func testSecondariesAreExploratoryAndUnlabelled() {
        let inputs = simpleInputs(yes: 30, no: 30)
        let row = HabitAssociation.analyse(inputs: inputs, asOf: Self.asOf).rows.first!
        XCTAssertEqual(row.secondaries.map { $0.outcome }, [.nightRhr, .totalSleepMin])
        // No RHR / sleep data → no estimate; and no label field exists on a secondary.
        XCTAssertNil(row.secondaries[0].estimate)
    }

    func testRowOrderAndReportRoundTrip() throws {
        var inputs = simpleInputs(yes: 30, no: 30)
        inputs.observations += simpleInputs(yes: 5, no: 5, habit: HabitCatalog.sauna).observations
        let report = HabitAssociation.analyse(inputs: inputs, asOf: Self.asOf)
        XCTAssertEqual(report.rows.last?.label, .notEnoughData)
        XCTAssertEqual(report.windowStart, "2026-04-02")
        XCTAssertEqual(report.sourceCounts["journal"], 60)
        let data = try JSONEncoder().encode(report)
        XCTAssertEqual(try JSONDecoder().decode(HabitAssociationReport.self, from: data), report)
    }

    func testObservationsOutsideTheWindowAreIgnored() {
        var inputs = simpleInputs(yes: 10, no: 10)
        inputs.observations.append(HabitObservation(nightKey: "2025-01-01", habit: HabitCatalog.alcohol, state: .yes,
                                                    source: .journal))
        let row = HabitAssociation.analyse(inputs: inputs, asOf: Self.asOf).rows.first!
        XCTAssertEqual(row.yesCount, 10)
    }
}
