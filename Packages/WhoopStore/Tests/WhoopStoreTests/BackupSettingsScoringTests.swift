import XCTest
@testable import WhoopStore

/// Audit item 3: the `.noopbak` settings whitelist carried body metrics and display prefs but not one
/// scoring parameter, so a restore silently changed the RECIPE while claiming to restore the data —
/// `profile.stepTicksPerStep` reverted to raw tick pass-through (every step figure on every screen moved),
/// the fitted Effort→WHOOP curve reverted to the linear ×0.21 (an Effort of 60 that read 16.1 read 12.6),
/// the Rest need/consistency reverted to the 8 h / neutral defaults, the Effort METHOD reverted to Edwards,
/// and both manual baseline-recalibration epochs were lost.
final class BackupSettingsScoringTests: XCTestCase {

    private let scoringKeys = [
        "profile.stepTicksPerStep",
        "effort.whoopCalibration.v1",
        "effort.whoopCalibration.recipe",
        "noopBanisterEffort",
        "noop.rest.engineNeedHours",
        "noop.rest.engineConsistency",
        "noop.hrvBaselineEpoch",
        "noop.recoveryBaselineEpoch",
    ]

    /// THE BUG, stated as the contract: every scoring parameter is whitelisted, typed, and has a storage key.
    func testEveryScoringParameterIsWhitelistedAndMapped() {
        for key in scoringKeys {
            XCTAssertNotNil(BackupSettings.whitelist[key], "\(key) missing from the whitelist")
            XCTAssertNotNil(BackupSettings.appleDefaultsKey[key], "\(key) has no storage key")
        }
    }

    /// Int/Double/String only, per the byte-identical cross-platform contract — no new JSON kinds slipped in.
    func testTheWireStaysIntDoubleOrString() {
        for key in scoringKeys {
            switch BackupSettings.whitelist[key] {
            case .int, .double, .string: break
            case nil: XCTFail("\(key) not whitelisted")
            }
        }
    }

    /// A full device-A → device-B round trip through the codec AND the UserDefaults boundary: every scoring
    /// parameter arrives with the TYPE its live reader expects (`Data` for the calibration blob, `Bool` for
    /// the Effort-method toggle, `Double`/`Int` for the rest).
    func testScoringParametersSurviveAnExportImportRoundTrip() throws {
        let deviceA = try freshDefaults()
        let calibrationJSON = Data(#"{"a":1.35,"b":0.58,"pairs":30}"#.utf8)
        deviceA.set(24.0, forKey: "profile.stepTicksPerStep")
        deviceA.set(calibrationJSON, forKey: "effort.whoopCalibration.v1")
        deviceA.set(21, forKey: "effort.whoopCalibration.recipe")
        deviceA.set(true, forKey: "noopBanisterEffort")
        deviceA.set(7.75, forKey: "noop.rest.engineNeedHours")
        deviceA.set(0.42, forKey: "noop.rest.engineConsistency")
        deviceA.set(1_750_000_000.0, forKey: "noop.hrvBaselineEpoch")
        deviceA.set(1_750_000_001.0, forKey: "noop.recoveryBaselineEpoch")

        let payload = try XCTUnwrap(BackupSettings.encode(BackupSettings.snapshot(from: deviceA)))
        let deviceB = try freshDefaults()
        BackupSettings.apply(BackupSettings.decode(payload), to: deviceB)

        XCTAssertEqual(deviceB.object(forKey: "profile.stepTicksPerStep") as? Double, 24.0,
                       "a reverted step divisor moves every step figure on every screen")
        XCTAssertEqual(deviceB.data(forKey: "effort.whoopCalibration.v1"), calibrationJSON,
                       "the fitted Effort curve must come back as JSON bytes, not text")
        XCTAssertEqual(deviceB.object(forKey: "effort.whoopCalibration.recipe") as? Int, 21)
        XCTAssertEqual(deviceB.object(forKey: "noopBanisterEffort") as? Bool, true,
                       "the toggle travels as 0/1 and must land as a Bool for UserDefaults.bool")
        XCTAssertEqual(deviceB.object(forKey: "noop.rest.engineNeedHours") as? Double, 7.75)
        XCTAssertEqual(deviceB.object(forKey: "noop.rest.engineConsistency") as? Double, 0.42)
        XCTAssertEqual(deviceB.object(forKey: "noop.hrvBaselineEpoch") as? Double, 1_750_000_000.0)
        XCTAssertEqual(deviceB.object(forKey: "noop.recoveryBaselineEpoch") as? Double, 1_750_000_001.0)
    }

    /// The bridged kinds cross the JSON boundary as plain text / 0-or-1, so Android's codec sees the same
    /// wire shape it always did.
    func testBridgedKeysAreJsonTextAndZeroOrOne() throws {
        let deviceA = try freshDefaults()
        deviceA.set(Data(#"{"a":1.0}"#.utf8), forKey: "effort.whoopCalibration.v1")
        deviceA.set(false, forKey: "noopBanisterEffort")
        let snap = BackupSettings.snapshot(from: deviceA)
        XCTAssertEqual(snap["effort.whoopCalibration.v1"] as? String, #"{"a":1.0}"#)
        XCTAssertEqual(snap["noopBanisterEffort"] as? Int, 0, "off must be carried, not omitted")
    }

    /// Unset scoring parameters stay omitted, so restoring a backup made before any of them was set cannot
    /// overwrite the target's own values with defaults.
    func testUnsetScoringParametersAreOmitted() throws {
        let deviceA = try freshDefaults()
        deviceA.set(30, forKey: "profile.age")
        let snap = BackupSettings.snapshot(from: deviceA)
        for key in scoringKeys { XCTAssertNil(snap[key], "\(key) was never set and must not be defaulted") }
    }

    /// Non-UTF-8 bytes under the calibration key degrade to "one fewer key", never a corrupt restore.
    func testNonUtf8CalibrationBlobIsDropped() throws {
        let deviceA = try freshDefaults()
        deviceA.set(Data([0xFF, 0xFE, 0x00]), forKey: "effort.whoopCalibration.v1")
        XCTAssertNil(BackupSettings.snapshot(from: deviceA)["effort.whoopCalibration.v1"])
    }

    // MARK: - Suite-scoped defaults (never the test runner's real domain)

    private var suites: [String] = []

    private func freshDefaults() throws -> UserDefaults {
        let name = "BackupSettingsScoringTests-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            throw XCTSkip("Couldn't create a suite-scoped UserDefaults")
        }
        suites.append(name)
        return d
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }
}
