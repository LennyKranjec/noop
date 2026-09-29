import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-B.2 — the pre-registration, frozen before day 1 — and the sealed running view.
final class HabitTrialRegistrationTests: XCTestCase {

    private func baseline(endingOn day: String, count: Int = 28, value: (Int) -> Double) -> [String: Double] {
        var out: [String: Double] = [:]
        for back in 0..<count { out[HabitDay.adding(-back, to: day)!] = value(back) }
        return out
    }

    private func register(_ id: String = "screensOff60", length: Int = 28,
                          base: [String: Double]? = nil) -> Result<HabitTrialRegistration, HabitTrialRegistrationError> {
        let entry = HabitTrialCatalog.entry(id)!
        let b = base ?? baseline(endingOn: "2026-09-29") { 1380 + Double(($0 * 37) % 41) }
        return HabitTrialRegistration.register(entry: entry, registeredOn: "2026-09-29", lengthDays: length,
                                               seed: 0xABCD_EF01_2345_6789, baseline: b)
    }

    func testStartIsTomorrowAndEverythingIsFrozen() throws {
        let reg = try register().get()
        XCTAssertEqual(reg.registeredOn, "2026-09-29")
        XCTAssertEqual(reg.startDay, "2026-09-30", "never today: today's behaviour must not leak in")
        XCTAssertEqual(reg.endDay, "2026-10-27")
        XCTAssertEqual(reg.lastOutcomeKey, "2026-10-28")
        XCTAssertEqual(reg.primaryOutcome, .onsetClockMin)
        XCTAssertEqual(reg.direction, .decrease, "earlier onset is better")
        XCTAssertEqual(reg.lag, .nightAfter)
        XCTAssertEqual(reg.mcid, 15)
        XCTAssertEqual(reg.permutations, 10_000)
        XCTAssertEqual(reg.alpha, 0.05)
        XCTAssertEqual(reg.covariates, [.effort, .trend])
        XCTAssertEqual(reg.schedule.count, 28)
        XCTAssertEqual(reg.schedule,
                       HabitTrialSchedule.assignments(design: .weekdayBalanced, lengthDays: 28, seed: reg.seed))
        XCTAssertLessThan(reg.seed, UInt64(1) << 53)
        XCTAssertEqual(reg.baselineNights, 28)
        XCTAssertNotNil(reg.mde)
        XCTAssertEqual(reg.secondaryOutcomes, [.totalSleepMin])
    }

    func testCovariatesFollowTheDesign() throws {
        XCTAssertEqual(try register("alcoholFree", base: baseline(endingOn: "2026-09-29") { 3.9 + 0.01 * Double($0 % 7) }).get().covariates,
                       [.effort, .trend, .prevAssignedOn])
        XCTAssertEqual(try register("walkAfterDinner10", base: baseline(endingOn: "2026-09-29") { 52 + Double($0 % 5) }).get().covariates,
                       [.effortPreviousDay, .trend], "the walk moves Effort, so D−1's Effort is used")
        let daylight = try register("morningDaylight", length: 48).get()
        XCTAssertEqual(daylight.covariates, [.effort, .trend, .weekend])
        XCTAssertEqual(daylight.design, .phaseBlocks)
    }

    func testMCIDTable() throws {
        // HRV: max(0.5 × SD, 0.04); RHR: max(0.5 × SD, 1.0).
        let hrv = try register("breathing10", base: baseline(endingOn: "2026-09-29") { 3.9 + 0.2 * Double($0 % 2) }).get()
        XCTAssertEqual(hrv.mcid, max(0.5 * hrv.baselineSD!, 0.04), accuracy: 1e-12)
        let stable = try register("breathing10", base: baseline(endingOn: "2026-09-29") { 3.9 + 0.001 * Double($0 % 2) }).get()
        XCTAssertEqual(stable.mcid, 0.04, "the floor stops a very stable wearer's MCID shrinking into noise")
        let rhr = try register("dinner3h", base: baseline(endingOn: "2026-09-29") { 52 + 0.2 * Double($0 % 3) }).get()
        XCTAssertEqual(rhr.mcid, 1.0)
        XCTAssertEqual(HabitOutcome.totalSleepMin.mcid(baselineSD: 40), 15)
        XCTAssertEqual(HabitOutcome.sleepEfficiency.mcid(baselineSD: nil), 2)
        XCTAssertNil(HabitOutcome.dayStressMean.mcid(baselineSD: 1), "stress is exploratory only")
    }

    func testRefusals() {
        XCTAssertEqual(register(length: 30).failureValue, .invalidLength(allowed: [28, 42, 56]))
        let thin = baseline(endingOn: "2026-09-29", count: 13) { Double($0) }
        XCTAssertEqual(register(base: thin).failureValue, .tooFewBaselineNights(have: 13, need: 14))
    }

    func testHashIsStableAndDetectsEveryEdit() throws {
        let reg = try register().get()
        XCTAssertEqual(reg.hash, reg.hash)
        XCTAssertEqual(reg.hash.count, 16)
        XCTAssertTrue(reg.verify(storedHash: reg.hash))

        // Round trip through the store's codec keeps the hash.
        let data = try JSONEncoder().encode(reg)
        let back = try JSONDecoder().decode(HabitTrialRegistration.self, from: data)
        XCTAssertEqual(back, reg)
        XCTAssertEqual(back.hash, reg.hash)

        // Any edit is detectable.
        let edited = HabitTrialRegistration(
            trialId: reg.trialId, interventionId: reg.interventionId, registeredOn: reg.registeredOn,
            startDay: reg.startDay, lengthDays: reg.lengthDays, design: reg.design, carryOver: reg.carryOver,
            primaryOutcome: reg.primaryOutcome, direction: reg.direction, lag: reg.lag, mcid: reg.mcid * 2,
            secondaryOutcomes: reg.secondaryOutcomes, covariates: reg.covariates, affectsEffort: reg.affectsEffort,
            seed: reg.seed, schedule: reg.schedule, alpha: reg.alpha, permutations: reg.permutations,
            baselineNights: reg.baselineNights, baselineSD: reg.baselineSD, baselineRho: reg.baselineRho,
            baselineMedian: reg.baselineMedian, mde: reg.mde)
        XCTAssertFalse(edited.verify(storedHash: reg.hash))
    }

    func testCanonicalJSONHasSortedKeysAndFixedNumbers() throws {
        let json = try register().get().canonicalJSON()
        XCTAssertTrue(json.hasPrefix("{\"affectsEffort\":false,\"alpha\":0.050000000,"))
        XCTAssertTrue(json.contains("\"mcid\":15.000000000"))
        XCTAssertTrue(json.hasSuffix("\"trialId\":\"screensOff60.2026-09-30\"}"))
        // Every key present, in sorted order.
        let keys = ["affectsEffort", "alpha", "baselineMedian", "baselineNights", "baselineRho", "baselineSD",
                    "carryOver", "covariates", "design", "direction", "interventionId", "lag", "lengthDays", "mcid",
                    "mde", "permutations", "primaryOutcome", "registeredOn", "schedule", "secondaryOutcomes", "seed",
                    "startDay", "trialId"]
        XCTAssertEqual(keys, keys.sorted())
        var last = json.startIndex
        for key in keys {
            guard let r = json.range(of: "\"\(key)\":") else { return XCTFail("missing key \(key)") }
            XCTAssertGreaterThanOrEqual(r.lowerBound, last, "\(key) out of order")
            last = r.lowerBound
        }
    }

    func testFNV1aReference() {
        // FNV-1a 64 of the empty string is the offset basis; of "a" is the published 0xaf63dc4c8601ec8c.
        XCTAssertEqual(HabitTrialRegistration.fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(HabitTrialRegistration.fnv1a64Hex("a"), "af63dc4c8601ec8c")
    }

    func testUnderpoweredWarningAndRecommendedLength() throws {
        // A noisy onset (SD ≈ 60 min) cannot detect 15 min in 28 days.
        let noisy = baseline(endingOn: "2026-09-29") { 1380 + 60 * sin(Double($0) * 1.7) }
        let reg = try register(base: noisy).get()
        XCTAssertTrue(reg.isUnderpowered)
        // Even 56 days is not enough here: no recommendation rather than a false promise.
        XCTAssertNil(reg.recommendedLength())
        let calm = baseline(endingOn: "2026-09-29") { 1380 + 12 * sin(Double($0) * 1.7) }
        let ok = try register(base: calm).get()
        XCTAssertNotNil(ok.recommendedLength())
    }

    // MARK: The sealed view

    func testProgressExposesCountsOnly() throws {
        let reg = try register().get()
        var behaviour: [String: HabitTrialBehaviour] = [:]
        for i in 0..<10 where reg.schedule[i] { behaviour[HabitDay.adding(i, to: reg.startDay)!] = .did }
        let scored = Set((0..<10).map { HabitDay.adding($0 + 1, to: reg.startDay)! })
        let p = HabitTrialProgress.make(registration: reg, today: HabitDay.adding(10, to: reg.startDay)!,
                                        behaviour: behaviour, scoredOutcomeKeys: scored)
        XCTAssertEqual(p.dayNumber, 11)
        XCTAssertEqual(p.todayOn, reg.schedule[10])
        XCTAssertEqual(p.adherence, 1.0)
        XCTAssertEqual(p.validOn + p.validOff, 10)
        XCTAssertEqual(p.sealedUntil, reg.lastOutcomeKey)
        // BY CONSTRUCTION: no field of the running view can hold an estimate.
        let names = Mirror(reflecting: p).children.compactMap { $0.label?.lowercased() }
        for forbidden in ["estimate", "interval", "lower", "upper", "mean", "p", "pvalue", "effect", "verdict"] {
            XCTAssertFalse(names.contains(forbidden), "HabitTrialProgress must not carry \(forbidden)")
        }
    }

    func testProgressRevealsOnlyToday() throws {
        let reg = try register().get()
        let before = HabitTrialProgress.make(registration: reg, today: reg.registeredOn, behaviour: [:],
                                             scoredOutcomeKeys: [])
        XCTAssertNil(before.todayOn, "nothing is revealed before day 1")
        XCTAssertEqual(before.dayNumber, 0)
        let after = HabitTrialProgress.make(registration: reg, today: "2027-01-01", behaviour: [:],
                                            scoredOutcomeKeys: [])
        XCTAssertNil(after.todayOn)
        XCTAssertEqual(after.dayNumber, 28)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
