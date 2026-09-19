import XCTest
import StrandAnalytics
@testable import Strand

/// O8 — the app side of the Effort → WHOOP-strain calibration: which days pair, the linear fallback, and
/// that the 0–21 display actually routes through a stored calibration. The fit itself is covered by
/// `EffortStrainCalibrationTests` in StrandAnalytics.
///
/// Touches the real `UserDefaults.standard` key the app uses, so every test restores what was there.
final class StrainCalibrationTests: XCTestCase {

    private var savedData: Data?

    override func setUp() {
        super.setUp()
        savedData = UserDefaults.standard.data(forKey: StrainCalibration.storageKey)
        StrainCalibration.store(nil)
    }

    override func tearDown() {
        if let savedData {
            StrainCalibration.store(try? JSONDecoder().decode(EffortStrainCalibration.self, from: savedData))
        } else {
            StrainCalibration.store(nil)
        }
        super.tearDown()
    }

    func testPairsJoinByDayAndSkipTodayAndGaps() {
        let own: [(day: String, effort: Double?)] = [
            ("2026-09-01", 40), ("2026-09-02", nil), ("2026-09-03", 55), ("2026-09-04", 20),
        ]
        let whoop: [(day: String, strain: Double?)] = [
            ("2026-09-01", 9.5), ("2026-09-02", 11), ("2026-09-03", nil), ("2026-09-04", 6.1),
        ]
        let p = StrainCalibration.pairs(own: own, whoop: whoop, excludingDay: "2026-09-04")
        XCTAssertEqual(p.count, 1, "only 09-01 has both sides and is not today")
        XCTAssertEqual(p.first?.effort100 ?? -1, 40, accuracy: 1e-12)
        XCTAssertEqual(p.first?.strain21 ?? -1, 9.5, accuracy: 1e-12)
    }

    /// No calibration → the linear ×21/100, byte-identical to the pre-O8 formatter (and its inverse).
    func testNoCalibrationIsTheOldLinearMapping() {
        XCTAssertNil(StrainCalibration.current)
        XCTAssertEqual(UnitFormatter.effortValue(100, scale: .whoop), 21.0, accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.effortValue(50, scale: .whoop), 10.5, accuracy: 1e-9)
        XCTAssertEqual(StrainCalibration.effort100(strain21: 10.5), 50.0, accuracy: 1e-9)
    }

    /// With < 10 paired days the fit refuses, so storing its result leaves the linear mapping in place.
    func testTooFewPairedDaysKeepsLinear() {
        let few = (0..<9).map { i in (effort100: 10.0 + Double(i) * 8, strain21: 4.0 + Double(i)) }
        StrainCalibration.store(EffortStrainCalibration.fit(few))
        XCTAssertNil(StrainCalibration.current)
        XCTAssertEqual(UnitFormatter.effortValue(50, scale: .whoop), 10.5, accuracy: 1e-9)
    }

    /// A stored calibration reaches the WHOOP-scale display, leaves the 0–100 display alone, and never
    /// touches a DIFFERENCE (which stays linear).
    func testStoredCalibrationDrivesTheWhoopScaleOnly() {
        let cal = EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30)
        StrainCalibration.store(cal)
        XCTAssertEqual(UnitFormatter.effortValue(50, scale: .whoop), cal.strain21(effort100: 50), accuracy: 1e-9)
        XCTAssertEqual(UnitFormatter.effortValue(50, scale: .hundred), 50, accuracy: 1e-12)
        XCTAssertEqual(UnitFormatter.effortDeltaValue(50, scale: .whoop), 10.5, accuracy: 1e-9)
        // The inverse puts a WHOOP band top back where the display will read it as that band top.
        let e = StrainCalibration.effort100(strain21: 14)
        XCTAssertEqual(UnitFormatter.effortValue(e, scale: .whoop), 14, accuracy: 1e-9)
        // Persisted: a fresh decode of the stored JSON is the same calibration.
        let data = UserDefaults.standard.data(forKey: StrainCalibration.storageKey)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(EffortStrainCalibration.self, from: $0) }, cal)
        // E4: and tagged with the recipe it was fitted against.
        XCTAssertEqual(UserDefaults.standard.integer(forKey: StrainCalibration.recipeKey),
                       StrainCalibration.strainRecipeVersion)
    }

    // MARK: - E4: one recipe per fit

    /// A calibration fitted on an older Effort recipe (or an untagged pre-E4 one) is ignored.
    func testOlderRecipeCalibrationIsIgnored() throws {
        let data = try JSONEncoder().encode(EffortStrainCalibration(a: 1.35, b: 0.58, pairs: 30))
        XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: 0), "untagged = pre-E4")
        XCTAssertNil(StrainCalibration.decodeIfCurrent(data, recipe: StrainCalibration.strainRecipeVersion - 1))
        XCTAssertNotNil(StrainCalibration.decodeIfCurrent(data, recipe: StrainCalibration.strainRecipeVersion))
    }

    /// Never before the rescore; at once when it completes (even if a fit already ran today); then daily.
    func testRefitWaitsForTheRescoreThenRefitsOnceThenDaily() {
        let marker = StrainCalibration.fitMarker(rescoreFlagKey: "rescore.v1.done")
        XCTAssertFalse(StrainCalibration.isDue(rescoreDone: false, fittedMarker: nil, currentMarker: marker,
                                               refreshedDay: nil, today: "2026-09-19"))
        XCTAssertTrue(StrainCalibration.isDue(rescoreDone: true, fittedMarker: nil, currentMarker: marker,
                                              refreshedDay: "2026-09-19", today: "2026-09-19"),
                      "the flag just flipped: refit now even though a (pre-rescore) fit ran today")
        XCTAssertFalse(StrainCalibration.isDue(rescoreDone: true, fittedMarker: marker, currentMarker: marker,
                                               refreshedDay: "2026-09-19", today: "2026-09-19"))
        XCTAssertTrue(StrainCalibration.isDue(rescoreDone: true, fittedMarker: marker, currentMarker: marker,
                                              refreshedDay: "2026-09-18", today: "2026-09-19"))
        // A bumped rescore key (a new full-history pass) invalidates the marker.
        XCTAssertNotEqual(marker, StrainCalibration.fitMarker(rescoreFlagKey: "rescore.v2.done"))
    }
}
