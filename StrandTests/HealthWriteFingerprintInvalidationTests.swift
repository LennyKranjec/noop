import XCTest
@testable import Strand

/// Two ways a stored Apple Health write fingerprint lied, and the two rules that stop it.
///
/// A fingerprint only ever proved what the last pass WROTE. It was read as "Health already holds
/// exactly these samples", which is a different claim:
///
///  - `canSkip` (#4): `clearAll()` fired only on re-authorization and after the #1503 sweep, so a user
///    who deleted NOOP's data from inside the Health app never got it back — every later pass matched
///    the stale fingerprint and skipped. A cheap existence probe now has to agree before a skip.
///  - `storeIfReconciled` (#5): the vitals and sleep paths deleted with `try?`, saved, then stored the
///    fingerprint unconditionally. A delete that FAILED left the old samples in place, the save added a
///    second copy, and the fingerprint then told every later pass there was nothing to reconcile — so
///    the duplicates were permanent. `writeWorkouts` already gated on its `reconciled` flag.
final class HealthWriteFingerprintInvalidationTests: XCTestCase {

    private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "hkfp-invalidation-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            throw NSError(domain: "HealthWriteFingerprintInvalidationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no suite defaults"])
        }
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        try body(d)
    }

    private func fingerprint(_ salt: String) -> HealthWriteFingerprint {
        var fp = HealthWriteFingerprint(seed: ["noop-hk-write", "v1", "vitals", "my-whoop", "dev"])
        fp.add(salt)
        return fp
    }

    // MARK: - #4 existence probe

    func testMatchingFingerprintIsNotTrustedWhenHealthHoldsNoneOfOurSamples() throws {
        try withFreshDefaults { d in
            let fp = fingerprint("a")
            HealthWriteFingerprintStore.store(.vitals, fp, defaults: d)
            XCTAssertTrue(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d))

            XCTAssertFalse(
                HealthWriteFingerprintStore.canSkip(.vitals, fp, healthHasSamples: false, defaults: d),
                "Health has none of ours — the user deleted them there, so rewrite")
            XCTAssertFalse(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d),
                           "the lying fingerprint is dropped, so even a failed rewrite retries next pass")
        }
    }

    func testMatchingFingerprintIsTrustedWhenHealthStillHoldsOurSamples() throws {
        try withFreshDefaults { d in
            let fp = fingerprint("a")
            HealthWriteFingerprintStore.store(.vitals, fp, defaults: d)
            XCTAssertTrue(
                HealthWriteFingerprintStore.canSkip(.vitals, fp, healthHasSamples: true, defaults: d))
            XCTAssertTrue(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d),
                          "a skip must not disturb the stored fingerprint")
        }
    }

    /// The probe could not run (unauthorized type, query error): nothing was learned, so behave exactly
    /// as before rather than forcing a full rewrite on every single pass.
    func testUnknownProbeResultFallsBackToTheStoredFingerprint() throws {
        try withFreshDefaults { d in
            let fp = fingerprint("a")
            HealthWriteFingerprintStore.store(.vitals, fp, defaults: d)
            XCTAssertTrue(
                HealthWriteFingerprintStore.canSkip(.vitals, fp, healthHasSamples: nil, defaults: d))
            XCTAssertTrue(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d))
        }
    }

    /// Changed content is still a rewrite whatever the probe says — the probe only ever REMOVES trust.
    func testChangedContentNeverSkipsEvenWhenHealthHoldsSamples() throws {
        try withFreshDefaults { d in
            HealthWriteFingerprintStore.store(.vitals, fingerprint("a"), defaults: d)
            XCTAssertFalse(HealthWriteFingerprintStore.canSkip(.vitals, fingerprint("b"),
                                                               healthHasSamples: true, defaults: d))
        }
    }

    // MARK: - #5 a failed delete is not a completed write

    func testFingerprintIsNotStoredWhenTheDeleteFailed() throws {
        try withFreshDefaults { d in
            let fp = fingerprint("a")
            // The real order: clear before touching Health, save, then record — only if reconciled.
            HealthWriteFingerprintStore.clear(.vitals, defaults: d)
            HealthWriteFingerprintStore.storeIfReconciled(.vitals, fp, reconciled: false, defaults: d)

            XCTAssertFalse(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d),
                           "a delete that failed leaves duplicates in Health; the next pass must rewrite")
            XCTAssertNil(d.string(forKey: HealthWriteFingerprintStore.key(.vitals)))
        }
    }

    func testFingerprintIsStoredWhenTheDeleteSucceeded() throws {
        try withFreshDefaults { d in
            let fp = fingerprint("a")
            HealthWriteFingerprintStore.clear(.sleep, defaults: d)
            HealthWriteFingerprintStore.storeIfReconciled(.sleep, fp, reconciled: true, defaults: d)
            XCTAssertTrue(HealthWriteFingerprintStore.matches(.sleep, fp, defaults: d))
        }
    }

    /// A failed delete must not leave a PREVIOUS pass's fingerprint standing either — hence the
    /// clear-before-write discipline the two calls above model together.
    func testAFailedPassLeavesNoFingerprintFromAnEarlierOne() throws {
        try withFreshDefaults { d in
            HealthWriteFingerprintStore.store(.sleep, fingerprint("old"), defaults: d)
            HealthWriteFingerprintStore.clear(.sleep, defaults: d)
            HealthWriteFingerprintStore.storeIfReconciled(.sleep, fingerprint("new"),
                                                          reconciled: false, defaults: d)
            XCTAssertNil(d.string(forKey: HealthWriteFingerprintStore.key(.sleep)))
        }
    }
}
