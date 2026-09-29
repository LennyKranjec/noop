import XCTest
@testable import Strand

/// Two `DataSourcesView` failures.
///
/// `AuxImportGate` (#6): `dataInFlight` — the guard that stops the level ledger's immutable 800-day
/// backfill, and the launch cascade's import wait, from reading a store that is being written — folds
/// `AppModel.hasActiveImport`. Four importers (nutrition CSV, lifting log, GPX/TCX/FIT workout file,
/// Oura/Fitbit/Garmin export) tracked their "importing" state in `DataSourcesView`'s own `@State`, so
/// `hasActiveImport` could not see them at all and a ledger day was free to be scored mid-import. They
/// now hold this gate. A counter, not a flag: if two ever overlap, the first to finish must not release
/// it under the second.
///
/// `pickerWasNotPresented` (#8): `DocumentPicker.importFile` returns nil for BOTH a cancel and a
/// presentation UIKit declined outright (target already presenting / mid-transition). The second is not
/// a choice the user made, and it read as a dead button — no sheet, no message, no log line.
final class DataSourcesGateTests: XCTestCase {

    // MARK: - #6 the aux-import gate

    func testGateIsActiveWhileAnImportHoldsIt() {
        var gate = AuxImportGate()
        XCTAssertFalse(gate.isActive, "idle by default — nothing is writing to the store")
        gate.begin()
        XCTAssertTrue(gate.isActive)
        gate.finish()
        XCTAssertFalse(gate.isActive)
    }

    /// THE REGRESSION SHAPE: the first of two overlapping importers finishing must not open the gate
    /// while the second is still writing. A Bool flag would.
    func testOverlappingImportsKeepTheGateClosedUntilTheLastOneFinishes() {
        var gate = AuxImportGate()
        gate.begin()
        gate.begin()
        gate.finish()
        XCTAssertTrue(gate.isActive, "one importer is still writing to the store")
        gate.finish()
        XCTAssertFalse(gate.isActive)
    }

    /// An unbalanced release must not take the count negative: a negative count would need two extra
    /// `begin`s before the gate closed again, silently disabling the very guard this provides.
    func testAnExtraReleaseCannotDriveTheCountNegative() {
        var gate = AuxImportGate()
        gate.finish()
        gate.finish()
        XCTAssertEqual(gate.count, 0)
        gate.begin()
        XCTAssertTrue(gate.isActive, "one begin must close the gate, whatever came before")
    }

    // MARK: - #8 a picker that never appeared

    private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "datasources-gate-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else {
            throw NSError(domain: "DataSourcesGateTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no suite defaults"])
        }
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        try body(d)
    }

    func testAPickerThatWasNeverPresentedIsReported() throws {
        try withFreshDefaults { d in
            let asked = Date()
            d.set("not-presented", forKey: "backupPicker.lastEvent")
            d.set(asked.addingTimeInterval(0.2).timeIntervalSince1970, forKey: "backupPicker.lastEventAt")
            XCTAssertTrue(DataSourcesView.pickerWasNotPresented(since: asked, defaults: d))
        }
    }

    func testAUserCancelStaysSilent() throws {
        try withFreshDefaults { d in
            let asked = Date()
            d.set("cancelled", forKey: "backupPicker.lastEvent")
            d.set(asked.addingTimeInterval(0.2).timeIntervalSince1970, forKey: "backupPicker.lastEventAt")
            XCTAssertFalse(DataSourcesView.pickerWasNotPresented(since: asked, defaults: d),
                           "a cancel is the user's choice, not a failure to report")
        }
    }

    /// `DocumentPicker.recordEvent` is shared by every picker in the app, so a `not-presented` left over
    /// from an earlier Backup & Sync attempt must not be blamed on this tap.
    func testAStaleNotPresentedEventFromAnEarlierPickerIsIgnored() throws {
        try withFreshDefaults { d in
            let asked = Date()
            d.set("not-presented", forKey: "backupPicker.lastEvent")
            d.set(asked.addingTimeInterval(-600).timeIntervalSince1970, forKey: "backupPicker.lastEventAt")
            XCTAssertFalse(DataSourcesView.pickerWasNotPresented(since: asked, defaults: d))
        }
    }

    func testNoRecordedEventAtAllStaysSilent() throws {
        try withFreshDefaults { d in
            XCTAssertFalse(DataSourcesView.pickerWasNotPresented(since: Date(), defaults: d))
        }
    }
}
