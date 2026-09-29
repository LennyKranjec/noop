import CoreBluetooth
import XCTest
import WhoopProtocol
@testable import Strand

/// Which WHOOP family a session decides it is talking to, and how a wrong initial guess corrects itself.
///
/// The bug these pin: on a fresh install `WhoopModel.persisted` is `.whoop4` whatever strap the user owns,
/// and every connect path that does NOT scan (CoreBluetooth state restoration, the targeted pin connect, a
/// standing reconnect, an adopted already-open link) took that guess as fact. `discoverPrimaryServices`
/// then asked only for the guessed family's proprietary service, so a WHOOP 5/MG never had `fd4b0001`
/// discovered: no puffin characteristic, no CLIENT_HELLO, no offload — and therefore no steps — while live
/// HR carried on over plain 0x2A37. Worse, the one site that writes the `selectedWhoopModel` preference is
/// keyed on seeing that service, so the guess was never corrected and every later launch repeated it.
///
/// Pure rules only: BLE behaviour is not CI-testable, so the resolution rules are where the guarantee has
/// to live.
final class FamilyResolutionTests: XCTestCase {

    // MARK: - resolvedModel(fromDiscoveredServices:)

    private let whoop4Service = WhoopModel.whoop4.scanService
    private let whoop5Service = WhoopModel.whoop5mg.scanService
    private let heartRateService = CBUUID(string: "180D")
    private let batteryService = CBUUID(string: "180F")
    private let disService = CBUUID(string: "180A")

    /// The `WhoopModel` UUIDs and `BLEManager`'s must stay value-equal, because the resolver compares the
    /// former while `didDiscoverServices` switches on the latter. `WhoopModel.scanService` documents this
    /// invariant (it duplicates the strings deliberately, to stay nonisolated); nothing enforced it.
    ///
    /// `@MainActor` because `BLEManager` is, and these constants are not declared `nonisolated`.
    @MainActor
    func testTheModelServiceUuidsMatchTheManagerConstants() {
        XCTAssertEqual(whoop4Service, BLEManager.customService)
        XCTAssertEqual(whoop5Service, BLEManager.whoop5Service)
    }

    func testAFiveMgIsResolvedFromItsPuffinService() {
        let resolved = resolvedModel(fromDiscoveredServices: [heartRateService, whoop5Service, disService])
        XCTAssertEqual(resolved, .whoop5mg)
    }

    func testAFourOhIsResolvedFromItsCustomService() {
        let resolved = resolvedModel(fromDiscoveredServices: [whoop4Service, heartRateService, batteryService])
        XCTAssertEqual(resolved, .whoop4)
    }

    /// The whole point of the fix: the resolver is handed the tree from a discovery that asked for BOTH
    /// families, so a 5/MG resolves even when the session opened believing it was a 4.0. Before, the 5/MG
    /// service was not in the discovery request at all, so this input could not occur.
    func testAFiveMgResolvesEvenWhenTheSessionGuessedFourOh() {
        XCTAssertEqual(WhoopModel.whoop4.deviceFamily, .whoop4)   // the fresh-install guess
        let resolved = resolvedModel(fromDiscoveredServices: [heartRateService, batteryService, whoop5Service])
        XCTAssertEqual(resolved?.deviceFamily, .whoop5)
    }

    /// A strap exposing NEITHER proprietary service resolves to nothing. Returning a family here would be
    /// exactly the guess this resolver exists to remove — and it is reachable, because the standard
    /// HR/battery/DIS profiles are discovered on any generic strap.
    func testNeitherProprietaryServiceResolvesToNothing() {
        XCTAssertNil(resolvedModel(fromDiscoveredServices: [heartRateService, batteryService, disService]))
        XCTAssertNil(resolvedModel(fromDiscoveredServices: []))
    }

    /// Deterministic when both are present, and deterministic REGARDLESS of order — otherwise which
    /// family's characteristics get discovered would depend on how CoreBluetooth happened to list them.
    func testBothServicesResolveToFiveMgInEitherOrder() {
        XCTAssertEqual(resolvedModel(fromDiscoveredServices: [whoop4Service, whoop5Service]), .whoop5mg)
        XCTAssertEqual(resolvedModel(fromDiscoveredServices: [whoop5Service, whoop4Service]), .whoop5mg)
    }

    // MARK: - ProprietaryNotifySource

    /// Only the two families' proprietary notify characteristics attest to anything. Every WHOOP exposes
    /// 0x2A37/0x2A19/DIS, so a live-HR-only link — which is precisely the mis-framed 5/MG's symptom — must
    /// never be read as evidence for either family.
    func testStandardProfilesAttestToNothing() {
        XCTAssertNil(ProprietaryNotifySource.standardProfile.attestedFamily)
        XCTAssertEqual(ProprietaryNotifySource.whoop4.attestedFamily, .whoop4)
        XCTAssertEqual(ProprietaryNotifySource.whoop5.attestedFamily, .whoop5)
    }

    // MARK: - FamilyMismatchDetector

    /// Two contradicting frames re-arm; one does not (re-arming discards the reassembler's in-progress
    /// buffer, so the streak buys certainty cheaply).
    func testContradictingFramesReArmAtTheThreshold() {
        var d = FamilyMismatchDetector()
        XCTAssertEqual(FamilyMismatchDetector.threshold, 2)
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))
        XCTAssertEqual(d.note(source: .whoop5, current: .whoop4), .whoop5)
    }

    /// Symmetric: a 4.0 mis-believed to be a 5/MG corrects the same way. Nothing here is 5/MG-specific.
    func testTheDetectorIsSymmetricAcrossFamilies() {
        var d = FamilyMismatchDetector()
        XCTAssertNil(d.note(source: .whoop4, current: .whoop5))
        XCTAssertEqual(d.note(source: .whoop4, current: .whoop5), .whoop4)
    }

    /// Fires ONCE per streak. Without the reset-on-fire, every subsequent frame would re-arm the pipeline
    /// and throw away the reassembler buffer on each one — the family is already corrected by then, but
    /// this pins the counter rather than relying on the caller.
    func testTheDetectorFiresOnlyOncePerStreak() {
        var d = FamilyMismatchDetector()
        _ = d.note(source: .whoop5, current: .whoop4)
        XCTAssertEqual(d.note(source: .whoop5, current: .whoop4), .whoop5)
        XCTAssertEqual(d.consecutiveContradictions, 0)
        // The caller has switched to .whoop5 by now, so these agree and stay quiet.
        XCTAssertNil(d.note(source: .whoop5, current: .whoop5))
        XCTAssertNil(d.note(source: .whoop5, current: .whoop5))
    }

    /// Agreement resets the streak, so a single stray frame can never accumulate across a whole session
    /// into a spurious family switch.
    func testAgreementResetsTheStreak() {
        var d = FamilyMismatchDetector()
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))
        XCTAssertNil(d.note(source: .whoop4, current: .whoop4))   // agreement
        XCTAssertEqual(d.consecutiveContradictions, 0)
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))   // back to 1, not 2
    }

    /// Standard-profile traffic is inert: it neither accumulates nor resets. A mis-framed 5/MG streams
    /// 0x2A37 continuously, so counting that either way would make the detector a coin toss.
    func testStandardProfileTrafficNeitherAccumulatesNorResets() {
        var d = FamilyMismatchDetector()
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))
        for _ in 0..<50 {
            XCTAssertNil(d.note(source: .standardProfile, current: .whoop4))
        }
        XCTAssertEqual(d.consecutiveContradictions, 1)
        XCTAssertEqual(d.note(source: .whoop5, current: .whoop4), .whoop5)
    }

    /// A standard-profile-only link never re-arms anything, however long it runs. This is the honest
    /// no-evidence case: live HR alone cannot tell the families apart.
    func testAStandardProfileOnlyLinkNeverReArms() {
        var d = FamilyMismatchDetector()
        for _ in 0..<500 {
            XCTAssertNil(d.note(source: .standardProfile, current: .whoop4))
        }
    }

    func testResetClearsTheStreak() {
        var d = FamilyMismatchDetector()
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))
        d.reset()
        XCTAssertNil(d.note(source: .whoop5, current: .whoop4))   // 1 again, not 2
    }

    // MARK: - WhoopModel

    /// The rotation the scan fallback relies on, and the pairing the both-families retrieve in
    /// `connectCore` uses to look for an already-bonded strap of either generation.
    func testEachFamilysFallbackIsTheOther() {
        XCTAssertEqual(WhoopModel.whoop4.fallbackScanModel, .whoop5mg)
        XCTAssertEqual(WhoopModel.whoop5mg.fallbackScanModel, .whoop4)
        XCTAssertNotEqual(WhoopModel.whoop4.scanService, WhoopModel.whoop5mg.scanService)
    }

    /// The fresh-install default, stated as a test because every failure in this file's header follows
    /// from it: absent a persisted pick, the app guesses WHOOP 4.0.
    func testAnUnwrittenPreferenceGuessesFourOh() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: "selectedWhoopModel")
        defaults.removeObject(forKey: "selectedWhoopModel")
        XCTAssertEqual(WhoopModel.persisted, .whoop4)
        if let saved { defaults.set(saved, forKey: "selectedWhoopModel") }
    }
}
