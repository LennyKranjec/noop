import XCTest
@testable import Strand
import StrandImport
import WhoopStore

/// The import → `liftSet` row mapping, and the read back out of it.
///
/// WHY THE ROUND TRIP IS THE POINT. `liftSet` has no column for "this weight is an ADDITION to bodyweight",
/// so the marker travels in `note`. If the write sets it and the read forgets it, ten added kilograms come
/// back as a ten-kilogram lift and the progression model — which is correct on its own inputs — reports a
/// confident estimate for a lift nobody performed at that load. The two halves have to be tested against
/// each other, not each against a literal.
///
/// The ids are asserted for the same reason `upsertLiftSessions` conflicts on the natural key: a fresh id
/// per import would write sets under an id no session row carries, and the screen would read an empty
/// history out of a full table.
///
/// NOTE ON COVERAGE: this is an app-target test, so it runs under `xcodebuild … test` (or `app-build.yml`
/// on demand) and NOT in the default `swift-packages` job. The model's own behaviour is covered in
/// `Packages/StrandImport/Tests/StrandImportTests/StrengthProgression*Tests.swift`, which does run there.
final class ImportedLiftSetsTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_758_800_000)

    private func session(sets: [LiftingSetRecord]) -> LiftingSession {
        LiftingSession(start: start, end: start.addingTimeInterval(3600),
                       volumeLoadKg: 0, setCount: sets.count, exerciseCount: 1, totalReps: 0,
                       topSetKg: nil, title: "Upper A", sets: sets)
    }

    // MARK: - Deterministic ids

    func testSessionAndSetIdsAreDerivedFromTheStartNotMinted() {
        let ts = Int(start.timeIntervalSince1970)
        XCTAssertEqual(ImportedLiftSets.sessionId(startTs: ts), "lifting-\(ts)")
        // Same input, same id — twice, because "deterministic" is the whole property.
        XCTAssertEqual(ImportedLiftSets.sessionId(startTs: ts), ImportedLiftSets.sessionId(startTs: ts))
        XCTAssertNotEqual(ImportedLiftSets.sessionId(startTs: ts), ImportedLiftSets.sessionId(startTs: ts + 1))
        XCTAssertEqual(ImportedLiftSets.setId(sessionId: "lifting-1", ord: 3), "lifting-1#3")
    }

    func testReimportingProducesTheIdenticalRows() {
        let s = session(sets: [
            LiftingSetRecord(exercise: "Brustpresse", weightKg: 75, reps: 8),
            LiftingSetRecord(exercise: "Brustpresse", weightKg: 75, reps: 7),
        ])
        let id = ImportedLiftSets.sessionId(startTs: Int(start.timeIntervalSince1970))
        XCTAssertEqual(ImportedLiftSets.setRows(for: s, sessionId: id),
                       ImportedLiftSets.setRows(for: s, sessionId: id))
    }

    // MARK: - Ordering

    func testOrdIsSessionWideAndSetIndexIsPerExercise() {
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Brustpresse", weightKg: 75, reps: 8),
            LiftingSetRecord(exercise: "Brustpresse", weightKg: 75, reps: 7),
            LiftingSetRecord(exercise: "Schulterpresse", weightKg: 27.5, reps: 9),
            // Back to the first exercise later in the session: its own numbering CONTINUES rather than
            // restarting, so "set 3 of 3" survives a superset.
            LiftingSetRecord(exercise: "brustpresse", weightKg: 70, reps: 8),
        ]), sessionId: "s")
        XCTAssertEqual(rows.map(\.ord), [0, 1, 2, 3])
        XCTAssertEqual(rows.map(\.setIndex), [1, 2, 1, 3])
        XCTAssertEqual(rows.map(\.id), ["s#0", "s#1", "s#2", "s#3"])
    }

    // MARK: - Absent stays absent

    func testAbsentWeightAndRepsAreStoredAbsentNotZero() {
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Plank", weightKg: nil, reps: nil),
        ]), sessionId: "s")
        XCTAssertNil(rows[0].weightKg, "a zero would say they lifted nothing, which is a different claim")
        XCTAssertNil(rows[0].reps)
        // Nothing this lane can honestly fill: no RPE in any of these exports, no per-set clock, no rest.
        XCTAssertNil(rows[0].rpe)
        XCTAssertNil(rows[0].startTs)
        XCTAssertNil(rows[0].endTs)
        XCTAssertNil(rows[0].restSec)
    }

    func testNoMuscleIsInventedForAnImportedSet() {
        // The import's attribution is `MuscleGroup`-shaped and already banked as `muscle_volume_*`. A
        // `LiftMuscle` guessed here would be a second per-muscle rollup derived differently from the first.
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Bench Press", weightKg: 100, reps: 5),
        ]), sessionId: "s")
        XCTAssertNil(rows[0].primaryMuscle)
        XCTAssertTrue(rows[0].secondaryMuscles.isEmpty)
    }

    // MARK: - The bodyweight-added marker survives storage

    func testTheBodyweightAddedFlagRoundTrips() {
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Hyperextensions", weightKg: 10, reps: 11, addedToBodyweight: true),
            LiftingSetRecord(exercise: "Brustpresse", weightKg: 75, reps: 8),
        ]), sessionId: "s")
        XCTAssertEqual(rows[0].note, ImportedLiftSets.bodyweightAddedNote)
        XCTAssertNil(rows[1].note, "a real load carries no marker")

        let back = rows.map(ImportedLiftSets.record(from:))
        XCTAssertTrue(back[0].addedToBodyweight, "losing this turns 10 added kg into a 10 kg lift")
        XCTAssertFalse(back[1].addedToBodyweight)
        // And the whole record survives, not just the flag.
        XCTAssertEqual(back[0].exercise, "Hyperextensions")
        XCTAssertEqual(back[0].weightKg, 10)
        XCTAssertEqual(back[0].reps, 11)
    }

    func testAFlaggedSetCannotReachTheModelAsAnAbsoluteLoad() {
        // End to end through the mapping the app actually uses: a bodyweight-added set, re-read, must make
        // the model abstain rather than estimate.
        let sets = (0..<4).map { _ in
            LiftingSetRecord(exercise: "Hyperextensions", weightKg: 10, reps: 11, addedToBodyweight: true)
        }
        let sessions = (0..<4).map { i -> StrengthProgression.Session in
            let day = start.addingTimeInterval(Double(i) * 7 * 86_400)
            let s = LiftingSession(start: day, end: day, volumeLoadKg: 0, setCount: 1, exerciseCount: 1,
                                   totalReps: 0, topSetKg: nil, title: nil, sets: [sets[i]])
            let rows = ImportedLiftSets.setRows(for: s, sessionId: "s\(i)")
            return StrengthProgression.Session(start: day, sets: rows.map(ImportedLiftSets.record(from:)))
        }
        let out = StrengthProgression.build(sessions: sessions)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].abstained, .noUsableSets)
        XCTAssertNil(out[0].currentE1rmKg)
        XCTAssertEqual(out[0].excludedBodyweightSets, 4)
    }

    // MARK: - Sessions with no set detail

    func testWarmupsAreCarriedAndFlagged() {
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Bench", weightKg: 40, reps: 10, isWarmup: true),
            LiftingSetRecord(exercise: "Bench", weightKg: 100, reps: 8),
        ]), sessionId: "s")
        XCTAssertTrue(rows[0].isWarmup)
        XCTAssertFalse(rows[1].isWarmup)
        // Recorded, not dropped: a set missing from the stored list cannot be told from one never logged.
        XCTAssertEqual(rows.count, 2)
    }

    func testTheImportedRowsAreScopedToTheLiftingSource() {
        // Same deviceId as the workout rows, so a "delete this device's data" clears the pair together.
        XCTAssertEqual(ImportedLiftSets.deviceId, LiftingImporter.sourceId)
        XCTAssertEqual(ImportedLiftSets.sport, LiftingImporter.sport)
        let rows = ImportedLiftSets.setRows(for: session(sets: [
            LiftingSetRecord(exercise: "Bench", weightKg: 100, reps: 5),
        ]), sessionId: "s")
        XCTAssertEqual(rows[0].deviceId, LiftingImporter.sourceId)
    }
}
