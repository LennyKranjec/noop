import Foundation
import StrandAnalytics
import StrandImport

// LiftProgramStore.swift — Telos Lift's programs, persisted as JSON next to the store (DESIGN_V2 decision 16).
//
// WHY A JSON FILE AND NOT THE v45 `liftProgram` / `liftProgramItem` TABLES. Those tables model a flat
// program → item list with a rep RANGE and no day templates, no equipment and no per-set type; the plan export
// is programs → days → exercises → typed sets. Squeezing that into the table would need a migration (not this
// package's call), and the plan is small, edited as a whole and never queried by SQL. So it lives beside
// `week-plans.json` in the store directory, the same idiom `WeekPlanSource` uses: written atomically, an
// unreadable file set aside instead of overwritten. What IS queried — the sets actually lifted — goes to
// `liftSession` / `liftSet` like every import (`LiftSessionRecorder`).
//
// ALL EDITS GO THROUGH `mutate`, which saves; the value types in `StrandAnalytics/Lift` carry the edit logic
// (tested there), so this file is only load / save / import.

@MainActor
final class LiftProgramStore: ObservableObject {

    static let shared = LiftProgramStore()

    nonisolated static let fileName = "lift-programs.json"

    @Published private(set) var library: LiftLibrary

    private let fileURL: URL?

    init(fileURL: URL? = LiftProgramStore.defaultFileURL()) {
        self.fileURL = fileURL
        self.library = Self.load(fileURL)
    }

    // MARK: - Storage

    nonisolated static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    nonisolated static func load(_ url: URL?) -> LiftLibrary {
        guard let url, let data = try? Data(contentsOf: url) else { return LiftLibrary() }
        if let lib = try? JSONDecoder().decode(LiftLibrary.self, from: data) { return lib }
        // Unreadable (a future version, or damage): keep the bytes aside rather than overwrite the wearer's plan
        // with an empty one on the next save.
        let aside = url.deletingLastPathComponent().appendingPathComponent("lift-programs.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return LiftLibrary()
    }

    private func save() {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(library) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The one write path: change the library, publish, save.
    func mutate(_ change: (inout LiftLibrary) -> Void) {
        var next = library
        change(&next)
        guard next != library else { return }
        library = next
        save()
    }

    // MARK: - Import

    struct ImportOutcome: Equatable {
        let programs: Int
        let days: Int
        let exercises: Int
        let diagnostics: AlphaprogPlanImporter.Diagnostics
    }

    /// Parse an Alphaprog plan export and merge it (see `LiftLibrary.merge`: a program of the same name is
    /// replaced, ids and rest overrides are kept). Nil when the bytes are not text.
    @discardableResult
    func importAlphaprogPlan(data: Data) -> ImportOutcome? {
        guard let parsed = AlphaprogPlanImporter.parse(data: data) else { return nil }
        let programs = Self.programs(from: parsed)
        if !programs.isEmpty { mutate { $0.merge(imported: programs) } }
        return ImportOutcome(programs: programs.count,
                             days: programs.reduce(0) { $0 + $1.days.count },
                             exercises: programs.reduce(0) { $0 + $1.days.reduce(0) { $0 + $1.exercises.count } },
                             diagnostics: parsed.diagnostics)
    }

    /// The parsed export → Lift programs. Every planned set is a WORKING set: the export has no warm-up or
    /// set-type column, and guessing which sets were warm-ups would invent a distinction the file does not make
    /// (the wearer marks them in the editor). Ids are derived from the names so a re-import keeps history linked.
    nonisolated static func programs(from parsed: AlphaprogPlanImporter.Parsed) -> [LiftProgram] {
        parsed.programs.map { program in
            LiftProgram(
                id: LiftProgram.programId(program.name),
                name: program.name,
                createdOn: program.date,
                days: program.days.map { day in
                    let templateId = LiftProgram.templateId(program: program.name, day: day.name)
                    return LiftDayTemplate(
                        id: templateId,
                        name: day.name,
                        exercises: day.exercises.enumerated().map { index, ex in
                            let count = max(0, ex.targetSets ?? 0)
                            return LiftExercisePlan(
                                id: "\(templateId)#\(index + 1)",
                                name: ex.name,
                                equipment: ex.equipment,
                                sets: (0..<count).map { n in
                                    LiftPlannedSet(id: "\(templateId)#\(index + 1).\(n + 1)", kind: .working)
                                },
                                targetReps: ex.targetRepsLow,
                                targetRepsHigh: ex.targetRepsHigh == ex.targetRepsLow ? nil : ex.targetRepsHigh,
                                restSeconds: nil)
                        })
                })
        }
    }
}
