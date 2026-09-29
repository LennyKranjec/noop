import XCTest
import StrandAnalytics
@testable import Strand

/// Audit item 4: `strainRecipeVersion` did not encode Edwards vs Banister. The justification ("same axis")
/// is only about the theoretical maximum day — a 24 h day held at 5 % HRR scores 0 under Edwards and about 45
/// under Banister — so a curve fitted under one method was being applied to numbers produced by the other.
/// Toggling the pref, or reinstalling (which resets it to Edwards), kept recipe 2 and kept the fit.
final class AccuracyAuditStrainRecipeTests: XCTestCase {

    /// THE BUG. The two methods must not share a recipe identity.
    func testTheTwoEffortMethodsHaveDifferentRecipeIdentities() {
        let edwards = StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion,
                                                       method: .edwards)
        let banister = StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion,
                                                       method: .banister)
        XCTAssertNotEqual(edwards, banister,
                          "a calibration fitted on one method is the wrong curve for the other")
    }

    /// A calibration fitted under Banister is REFUSED once the device is scoring with Edwards, and vice
    /// versa — which is the linear fallback, the honest mapping.
    func testACalibrationFromTheOtherMethodIsIgnored() throws {
        let data = try JSONEncoder().encode(EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30))
        let edwards = StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion,
                                                       method: .edwards)
        let banister = StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion,
                                                        method: .banister)
        XCTAssertNotNil(StrainCalibration.decodeIfCurrent(data, recipe: edwards, currentIdentity: edwards))
        XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: banister, currentIdentity: edwards),
                     "a Banister fit must not be applied to Edwards numbers")
        XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: edwards, currentIdentity: banister),
                     "…nor the reverse, which is what a reinstall produced")
    }

    /// The pre-fix stored tag (a bare recipe number) matches no identity, so every existing calibration
    /// refits rather than being applied to numbers it was never fitted on.
    func testPreFixRecipeTagsMatchNothing() throws {
        let data = try JSONEncoder().encode(EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30))
        for method in [StrainScorer.Method.edwards, .banister] {
            let identity = StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion,
                                                           method: method)
            XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: StrainCalibration.strainRecipeVersion,
                                                           currentIdentity: identity))
            XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: 0, currentIdentity: identity))
        }
    }

    /// The refit MARKER carries the identity too, so flipping the method makes the next refresh refit at
    /// once instead of tomorrow. (`fitMarker` reads the live method, so this asserts the identity is in it.)
    func testTheRefitMarkerNamesTheRecipeIdentity() {
        let marker = StrainCalibration.fitMarker(rescoreFlagKey: "rescore.v1.done")
        XCTAssertTrue(marker.hasSuffix("|r\(StrainCalibration.strainRecipeIdentity)"), marker)
        // And a marker built under the other method is a different string, so `isDue` returns true.
        let other: StrainScorer.Method = PuffinExperiment.effortMethod == .banister ? .edwards : .banister
        let otherMarker = "rescore.v1.done|r\(StrainCalibration.recipeIdentity(version: StrainCalibration.strainRecipeVersion, method: other))"
        XCTAssertNotEqual(marker, otherMarker)
        XCTAssertTrue(StrainCalibration.isDue(rescoreDone: true, fittedMarker: otherMarker,
                                              currentMarker: marker,
                                              refreshedDay: "2026-09-29", today: "2026-09-29"),
                      "a method change must refit now, not tomorrow")
    }
}
