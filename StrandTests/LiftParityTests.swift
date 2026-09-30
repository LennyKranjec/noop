import XCTest
@testable import Strand
import StrandAnalytics
import StrandImport
import WhoopStore

/// Telos Lift's app-layer seams (DESIGN_V2 decision 16).
///
/// PARITY PINS. `StrandAnalytics` cannot import `StrandImport` or the app module, so two facts are restated
/// there: the Epley e1RM (`LiftE1RM` vs `StrengthIndex.e1rm`) and the stored bodyweight-added marker
/// (`LiftStoreBridge.bodyweightAddedNote` vs `ImportedLiftSets.bodyweightAddedNote`). Only this target sees both
/// sides, so this is where a drift fails.
///
/// NOTE ON COVERAGE: app-target test — runs under `xcodebuild … test` / `app-build.yml`, not the default
/// `swift-packages` job. The logic itself is covered in `StrandAnalyticsTests/Lift/LiftTests.swift` and
/// `StrandImportTests/AlphaprogPlanImporterTests.swift`, which do run there.
final class LiftParityTests: XCTestCase {

    func testE1rmTwinsAgreeOverTheWholeGrid() {
        for reps in 0...15 {
            for step in 0...120 {
                let w = Double(step) * 2.5
                XCTAssertEqual(LiftE1RM.epley(weightKg: w, reps: reps), StrengthIndex.e1rm(weightKg: w, reps: reps),
                               "\(w) kg × \(reps)")
            }
        }
    }

    func testBodyweightMarkerTwinsAgree() {
        XCTAssertEqual(LiftStoreBridge.bodyweightAddedNote, ImportedLiftSets.bodyweightAddedNote)
        XCTAssertEqual(LiftSessionRecorder.deviceId, ImportedLiftSets.deviceId, "logged and imported sets share one source")
        XCTAssertEqual(LiftSessionRecorder.sport, ImportedLiftSets.sport)
    }

    /// A set logged on a bodyweight exercise reads back through the IMPORT's reader as bodyweight-added, so the
    /// progression model excludes it exactly as it excludes Alphaprog's `+10`.
    func testLoggedBodyweightSetReadsBackThroughTheImportReader() {
        var plan = LiftExercisePlan(name: "Hyperextensions", equipment: "Körpergewicht", sets: [], targetReps: 12)
        plan.setWorkingSetCount(1)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var session = LiftLoggedSession(
            id: LiftLoggedSession.sessionId(workoutStart: start), templateId: nil, templateName: nil,
            programName: nil, start: start,
            exercises: [LiftLoggedExercise(id: plan.id, name: plan.name, equipment: plan.equipment,
                                           targetReps: 12, restSeconds: nil, isBodyweight: plan.isBodyweight,
                                           sets: plan.sets.map { LiftLoggedSet(id: $0.id, kind: $0.kind, weightKg: 10, reps: 12) },
                                           increment: LiftIncrement.resolve(weightsKg: []))])
        let ex = session.exercises[0]
        session.check(exerciseId: ex.id, setId: ex.sets[0].id, at: start.addingTimeInterval(60), defaultRestSeconds: 150)
        let row = LiftStoreBridge.setRows(session, deviceId: LiftSessionRecorder.deviceId)[0]
        XCTAssertTrue(ImportedLiftSets.record(from: row).addedToBodyweight)
    }

    /// The plan export → programs mapping: ids derived from names (a re-import keeps history linked), every
    /// planned set a working set (the export has no set types), rep target carried.
    func testPlanBecomesProgramsWithStableIds() {
        let text = "Lower;2026-01-05\r\n\"Tag 1 · Lower A (Di)\"\r\n\"1. Beinpresse · Maschine\";\"4 Sätze\";\"10 Wdh\"\r\n"
        let programs = LiftProgramStore.programs(from: AlphaprogPlanImporter.parse(text))
        XCTAssertEqual(programs.count, 1)
        let day = programs[0].days[0]
        XCTAssertEqual(day.id, LiftProgram.templateId(program: "Lower", day: "Lower A (Di)"))
        XCTAssertEqual(day.weekday, 3)
        XCTAssertEqual(day.exercises[0].sets.map(\.kind), [.working, .working, .working, .working])
        XCTAssertEqual(day.exercises[0].targetReps, 10)
        XCTAssertNil(day.exercises[0].targetRepsHigh)
        XCTAssertEqual(LiftProgramStore.programs(from: AlphaprogPlanImporter.parse(text)), programs, "deterministic ids")
    }

    @MainActor
    func testProgramStorePersistsEditsAcrossInstances() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lift-programs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LiftProgramStore(fileURL: url)
        let text = "Upper;2025-12-12\n\"Tag 1 · Upper A (Mo)\"\n\"1. Brustpresse · Maschine\";\"4 Sätze\";\"10 Wdh\"\n"
        _ = store.importAlphaprogPlan(data: Data(text.utf8))
        let templateId = LiftProgram.templateId(program: "Upper", day: "Upper A (Mo)")
        let exerciseId = try XCTUnwrap(store.library.template(id: templateId)?.exercises.first?.id)
        store.mutate { lib in
            lib.defaultRestSeconds = 120
            lib.updateTemplate(id: templateId) { day in
                day.updateExercise(id: exerciseId) { $0.restSeconds = 90; $0.setWarmupCount(2) }
            }
        }
        let reopened = LiftProgramStore(fileURL: url)
        XCTAssertEqual(reopened.library, store.library)
        XCTAssertEqual(reopened.library.defaultRestSeconds, 120)
        XCTAssertEqual(reopened.library.template(id: templateId)?.exercises.first?.warmupSetCount, 2)
        XCTAssertEqual(reopened.library.template(id: templateId)?.exercises.first?.restSeconds, 90)
    }

    /// The owner's plan ships in the app bundle (`TelosLiftSeedPlan.csv`) and seeds ONCE into a store with no
    /// plan — never again after the wearer deletes it, and never over an existing plan file.
    @MainActor
    func testBundledPlanSeedsOnceAndNeverOverAPlan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lift-seed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(LiftProgramStore.fileName)
        let suite = "lift-seed-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = LiftProgramStore(fileURL: url)
        XCTAssertTrue(store.seedBundledPlanIfNeeded(defaults: defaults), "the CSV must be in the app bundle")
        XCTAssertEqual(Set(store.library.allTemplates.map(\.name)),
                       ["Lower A (Di)", "Lower B (Fr)", "Upper A (Mo)", "Upper B (Do)"])
        // Tuesday, nothing completed yet → Lower A (Di), by the logger's own rule.
        XCTAssertEqual(LiftTemplatePicker.pick(templates: store.library.allTemplates, weekday: 3,
                                               lastCompletedTemplateId: nil)?.template.name, "Lower A (Di)")

        // Deleting the plan is respected: no second seed.
        store.mutate { $0.programs = [] }
        XCTAssertFalse(store.seedBundledPlanIfNeeded(defaults: defaults))
        XCTAssertTrue(store.library.programs.isEmpty)

        // A device that never seeded but already has a plan file (here: an emptied one) keeps it as it is.
        let otherSuite = suite + ".other"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let reopened = LiftProgramStore(fileURL: url)
        XCTAssertFalse(reopened.seedBundledPlanIfNeeded(defaults: otherDefaults))
        XCTAssertTrue(reopened.library.programs.isEmpty)
    }

    /// The stored-set → StrengthIndex shape used by the derived-series rebuild leaves warm-ups out and keeps the
    /// bodyweight flag.
    func testDerivedWorkoutShape() {
        let h = LiftHistorySession(id: "telos-1", start: Date(timeIntervalSince1970: 1_790_000_000), title: "Lower A (Di)",
                                   sets: [LiftHistorySet(exercise: "Beinpresse", weightKg: 40, reps: 10, isWarmup: true),
                                          LiftHistorySet(exercise: "Beinpresse", weightKg: 100, reps: 10),
                                          LiftHistorySet(exercise: "Hyperextensions", weightKg: 10, reps: 12,
                                                         addedToBodyweight: true)])
        let w = LiftDerivedSeries.workout(from: h)
        XCTAssertEqual(w.exercises.map(\.name), ["Beinpresse", "Hyperextensions"])
        XCTAssertEqual(w.exercises[0].sets.map(\.weightKg), [100])
        XCTAssertTrue(w.exercises[1].sets[0].addedToBodyweight)
        XCTAssertTrue(LiftSessionRecorder.isStrengthSport("Strength"))
        XCTAssertFalse(LiftSessionRecorder.isStrengthSport("Running"))
    }
}
