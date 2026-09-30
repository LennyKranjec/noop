import Foundation

// LiftProgram.swift — Telos Lift's training plan: programs → day templates → exercises → planned sets
// (DESIGN_V2 coordinator decision 16).
//
// WHAT THIS IS. The wearer's own plan, imported once from the Alphaprog plan export and edited in the app
// afterwards. It is NOT a catalogue: an exercise is whatever name the wearer (or their export) wrote, kept
// verbatim, because that name is the key every stored set, the progression screen and the muscle
// attribution already match on.
//
// PURE VALUE TYPES, Codable. The app persists a `LiftLibrary` as JSON in the store directory
// (`LiftProgramStore`); nothing here touches a file, a clock or the store. Every edit the program editor
// offers is a mutating method on these types so it can be tested without SwiftUI.
//
// IDS ARE STABLE ACROSS A RE-IMPORT. A logged session records the TEMPLATE id it ran (`liftSession.programId`)
// and the prefill / "last time" / comparable-session lookups key on it. So an import derives template ids
// from the program and day names (`LiftProgram.templateId(program:day:)`), and a merge keeps an existing
// template's id when its name matches. A fresh UUID per import would orphan every session logged against
// the old one.

// MARK: - Set type

/// What kind of set a planned (or logged) set is.
///
/// Only `warmup` changes arithmetic: warm-ups are recorded and EXCLUDED from volume, e1RM, PRs and the
/// working-set count, exactly like `LiftSetRow.isWarmup` and every importer. `drop` and `failure` are working
/// sets with a label — they count as work, and the label travels to the store as a note token so a later
/// reader can tell them apart without a schema change.
public enum LiftSetKind: String, Codable, CaseIterable, Sendable {
    case working
    case warmup
    case drop
    case failure

    public var isWarmup: Bool { self == .warmup }

    /// The stored `liftSet.note` token for the kinds that have one. Fixed ASCII DATA, never shown raw and
    /// never localised (a translated token would split one kind into two).
    public var noteToken: String? {
        switch self {
        case .working, .warmup: return nil
        case .drop: return "telos:drop"
        case .failure: return "telos:failure"
        }
    }

    public static func fromNoteToken(_ note: String?) -> LiftSetKind? {
        guard let note else { return nil }
        for kind in allCases where kind.noteToken != nil && note.contains(kind.noteToken!) { return kind }
        return nil
    }
}

// MARK: - Planned set / exercise / day / program

public struct LiftPlannedSet: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: LiftSetKind

    public init(id: String = UUID().uuidString, kind: LiftSetKind) {
        self.id = id
        self.kind = kind
    }
}

public struct LiftExercisePlan: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Verbatim, as the export or the wearer wrote it ("Beinpresse").
    public var name: String
    /// "Maschine", "Kabelzug", "Körpergewicht" … nil when the export named none.
    public var equipment: String?
    /// The planned sets in order: warm-ups first by convention (the editor keeps them there).
    public var sets: [LiftPlannedSet]
    /// Rep target ("10 Wdh"). A range keeps its top in `targetRepsHigh`; nil when the plan names none.
    public var targetReps: Int?
    public var targetRepsHigh: Int?
    /// Rest after a set of THIS exercise, seconds. nil = the wearer's global default (`LiftLibrary`).
    public var restSeconds: Int?
    public var note: String?

    public init(id: String = UUID().uuidString,
                name: String,
                equipment: String? = nil,
                sets: [LiftPlannedSet],
                targetReps: Int? = nil,
                targetRepsHigh: Int? = nil,
                restSeconds: Int? = nil,
                note: String? = nil) {
        self.id = id
        self.name = name
        self.equipment = equipment
        self.sets = sets
        self.targetReps = targetReps
        self.targetRepsHigh = targetRepsHigh
        self.restSeconds = restSeconds
        self.note = note
    }

    public var workingSetCount: Int { sets.filter { !$0.kind.isWarmup }.count }
    public var warmupSetCount: Int { sets.filter { $0.kind.isWarmup }.count }

    /// Whether a load typed for this exercise is weight ADDED to bodyweight rather than the whole load.
    ///
    /// Alphaprog files hyperextensions and dips under "Körpergewicht" and prints an added load as `+10`; the
    /// importer flags those sets `addedToBodyweight`, and `StrengthProgression` / `StrengthIndex` exclude
    /// them from every absolute estimate. A set logged here on a bodyweight exercise is the same thing and
    /// must be stored the same way, or an in-app hyperextension would become a "10 kg lift" next to machine
    /// loads. Matched on the equipment word the plan export writes, in both languages.
    public var isBodyweight: Bool {
        guard let equipment else { return false }
        let e = equipment.lowercased()
        return e.contains("körpergewicht") || e.contains("koerpergewicht") || e.contains("bodyweight")
            || e.contains("body weight")
    }

    // MARK: Edits

    /// Set the number of WORKING sets, keeping warm-ups untouched. Removing takes sets off the end (a
    /// drop/failure set planned last is removed first, which is what "one set fewer" means at the bar);
    /// adding appends plain working sets.
    public mutating func setWorkingSetCount(_ count: Int) {
        let target = max(0, count)
        var working = workingSetCount
        while working > target, let last = sets.lastIndex(where: { !$0.kind.isWarmup }) {
            sets.remove(at: last)
            working -= 1
        }
        while working < target {
            sets.append(LiftPlannedSet(kind: .working))
            working += 1
        }
    }

    /// Set the number of warm-up sets. Warm-ups are kept at the FRONT of the list.
    public mutating func setWarmupCount(_ count: Int) {
        let target = max(0, count)
        var warm = warmupSetCount
        while warm > target, let last = sets.lastIndex(where: { $0.kind.isWarmup }) {
            sets.remove(at: last)
            warm -= 1
        }
        while warm < target {
            let insertAt = sets.lastIndex(where: { $0.kind.isWarmup }).map { $0 + 1 } ?? 0
            sets.insert(LiftPlannedSet(kind: .warmup), at: insertAt)
            warm += 1
        }
    }

    /// Change one planned set's type. Turning a set into a warm-up moves it to the end of the warm-up block
    /// (and a warm-up turned into work moves after it), so warm-ups always stay first.
    public mutating func setKind(setId: String, to kind: LiftSetKind) {
        guard let i = sets.firstIndex(where: { $0.id == setId }) else { return }
        var s = sets.remove(at: i)
        s.kind = kind
        let boundary = sets.lastIndex(where: { $0.kind.isWarmup }).map { $0 + 1 } ?? 0
        if kind.isWarmup {
            sets.insert(s, at: boundary)
        } else {
            sets.insert(s, at: min(max(i, boundary), sets.count))
        }
    }
}

public struct LiftDayTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// "Lower A (Di)". The weekday tag in parentheses is how today's template is picked.
    public var name: String
    public var exercises: [LiftExercisePlan]

    public init(id: String = UUID().uuidString, name: String, exercises: [LiftExercisePlan]) {
        self.id = id
        self.name = name
        self.exercises = exercises
    }

    /// Calendar weekday (1 = Sunday … 7 = Saturday) from the name's tag, nil when untagged.
    public var weekday: Int? { LiftWeekday.weekday(inTemplateName: name) }

    public var plannedSetCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }

    // MARK: Edits

    public mutating func addExercise(_ exercise: LiftExercisePlan, at index: Int? = nil) {
        if let index, index >= 0, index <= exercises.count {
            exercises.insert(exercise, at: index)
        } else {
            exercises.append(exercise)
        }
    }

    public mutating func removeExercise(id: String) {
        exercises.removeAll { $0.id == id }
    }

    /// Move the exercise with `id` so it ends up at `index` in the resulting list (clamped).
    public mutating func moveExercise(id: String, to index: Int) {
        guard let from = exercises.firstIndex(where: { $0.id == id }) else { return }
        let item = exercises.remove(at: from)
        exercises.insert(item, at: min(max(0, index), exercises.count))
    }

    public mutating func updateExercise(id: String, _ change: (inout LiftExercisePlan) -> Void) {
        guard let i = exercises.firstIndex(where: { $0.id == id }) else { return }
        change(&exercises[i])
    }
}

public struct LiftProgram: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// "Lower"
    public var name: String
    /// The date the export printed next to the program name ("2026-01-05"), kept verbatim; nil when absent.
    public var createdOn: String?
    public var days: [LiftDayTemplate]

    public init(id: String = UUID().uuidString, name: String, createdOn: String? = nil,
                days: [LiftDayTemplate]) {
        self.id = id
        self.name = name
        self.createdOn = createdOn
        self.days = days
    }

    /// A template id derived from the program and day names, so importing the same plan twice yields the
    /// same ids and history keeps pointing at them. Case- and whitespace-folded; not a hash (a readable id
    /// is easier to check in a support log, and nothing here crosses a platform boundary).
    public static func templateId(program: String, day: String) -> String {
        "tpl:" + slug(program) + "/" + slug(day)
    }

    public static func programId(_ program: String) -> String { "prg:" + slug(program) }

    static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-")
                lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

// MARK: - Library (what is persisted)

public struct LiftLibrary: Codable, Equatable, Sendable {
    /// Bumped only for a breaking change of this JSON; the loader keeps an unreadable file aside rather
    /// than overwriting it.
    public static let currentVersion = 1

    public var version: Int
    public var programs: [LiftProgram]
    /// The wearer's global rest default, seconds. 2:30 unless they changed it (decision 16).
    public var defaultRestSeconds: Int

    public init(version: Int = LiftLibrary.currentVersion,
                programs: [LiftProgram] = [],
                defaultRestSeconds: Int = LiftRestTimer.defaultSeconds) {
        self.version = version
        self.programs = programs
        self.defaultRestSeconds = defaultRestSeconds
    }

    public var isEmpty: Bool { programs.allSatisfy { $0.days.isEmpty } }

    /// Every day template, in program order then day order.
    public var allTemplates: [LiftDayTemplate] { programs.flatMap(\.days) }

    public func template(id: String) -> LiftDayTemplate? {
        allTemplates.first { $0.id == id }
    }

    public func programName(forTemplate id: String) -> String? {
        programs.first { $0.days.contains { $0.id == id } }?.name
    }

    public mutating func updateTemplate(id: String, _ change: (inout LiftDayTemplate) -> Void) {
        for p in programs.indices {
            if let d = programs[p].days.firstIndex(where: { $0.id == id }) {
                change(&programs[p].days[d])
                return
            }
        }
    }

    public mutating func removeTemplate(id: String) {
        for p in programs.indices { programs[p].days.removeAll { $0.id == id } }
        programs.removeAll { $0.days.isEmpty }
    }

    /// Merge freshly imported programs.
    ///
    /// THE FILE IS THE AUTHORITY FOR THE PROGRAMS IT NAMES: an imported program replaces the stored program
    /// of the same name (case-folded), because a wearer re-importing their plan wants the plan in the file.
    /// Two things are preserved so history is not orphaned: a day whose name matches an existing day keeps
    /// that day's id, and an exercise whose name matches keeps its id and its per-exercise rest override
    /// (the plan export carries no rest times, so importing must not wipe the wearer's own). Programs the
    /// file does not name are left alone.
    public mutating func merge(imported: [LiftProgram]) {
        for incoming in imported {
            let key = incoming.name.lowercased().trimmingCharacters(in: .whitespaces)
            if let existingIndex = programs.firstIndex(where: {
                $0.name.lowercased().trimmingCharacters(in: .whitespaces) == key
            }) {
                let existing = programs[existingIndex]
                var merged = incoming
                merged.id = existing.id
                for d in merged.days.indices {
                    let dayKey = merged.days[d].name.lowercased()
                    guard let old = existing.days.first(where: { $0.name.lowercased() == dayKey }) else { continue }
                    merged.days[d].id = old.id
                    for e in merged.days[d].exercises.indices {
                        let exKey = merged.days[d].exercises[e].name.lowercased()
                        if let oldEx = old.exercises.first(where: { $0.name.lowercased() == exKey }) {
                            merged.days[d].exercises[e].id = oldEx.id
                            if merged.days[d].exercises[e].restSeconds == nil {
                                merged.days[d].exercises[e].restSeconds = oldEx.restSeconds
                            }
                        }
                    }
                }
                programs[existingIndex] = merged
            } else {
                programs.append(incoming)
            }
        }
    }
}

// MARK: - Weekday tags

/// "(Di)", "(Mo)", "(Fr)" … → a Calendar weekday (1 = Sunday … 7 = Saturday).
///
/// German two-letter tags are what the owner's export writes; English three-letter and full names are
/// accepted too. Two-letter English tags that collide with German ones ("Mo", "Fr", "Sa") mean the same day
/// in both languages, so there is no ambiguity to resolve.
public enum LiftWeekday {
    static let table: [String: Int] = [
        // German
        "so": 1, "mo": 2, "di": 3, "mi": 4, "do": 5, "fr": 6, "sa": 7,
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7,
        // English
        "su": 1, "tu": 3, "we": 4, "th": 5,
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// The weekday of the LAST parenthesised tag in a template name, nil when there is none or it is not a
    /// day ("Lower A (Di)" → 3; "Push (heavy)" → nil).
    public static func weekday(inTemplateName name: String) -> Int? {
        guard let close = name.lastIndex(of: ")"),
              let open = name[..<close].lastIndex(of: "(") else { return nil }
        let tag = name[name.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return table[tag]
    }

    /// Monday-first position (Mon = 0 … Sun = 6) for ordering a week.
    public static func mondayFirstIndex(_ weekday: Int) -> Int { (weekday + 5) % 7 }
}
