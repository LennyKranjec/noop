import Foundation
import WhoopStore

// LiftStoreBridge.swift — Telos Lift ⇄ the store's existing lift log (`liftSession` / `liftSet`, store v46),
// and the dedupe rule against a later Alphaprog import.
//
// ONE SOURCE. A session logged in Telos is written to the SAME tables, under the SAME deviceId ("lifting",
// `LiftingImporter.sourceId`) and the SAME sport ("Strength Training") as an imported one, so
// `StrengthProgressionSource`, the muscle model, the Level's strength term and the coach all read it without
// knowing it came from the logger. The only marks it carries are the ones a reader may need:
//   * `liftSession.id` = "telos-<startTs>" (derivable from the workout start, so a crash re-attaches);
//   * `liftSession.programId` / `programName` = the day template's id and its name at the time;
//   * `liftSession.note` = "telos-lift" plus "notDone=N" when the session finished with planned sets undone;
//   * `liftSet.note` = the set-kind token for drop / failure sets, and the importer's own bodyweight marker
//     ("bodyweight+added", `ImportedLiftSets.bodyweightAddedNote`) for a load on a bodyweight exercise.
//
// NOT-DONE SETS ARE NOT ROWS. An unperformed set is not a set (the importers' rule for Alphaprog's `3;-;-`),
// so it never becomes a `liftSet` row that `liftSetCounts` or `StrengthProgression` would count. It is
// recorded as a count in the session note and in the local journal, and the finish screen shows it.
//
// NO LiftMuscle ON A LOGGED SET, deliberately and for the same reason `ImportedLiftSets` gives: the muscle
// model reads the per-day `muscle_volume_*` series (13 coarse groups from `MuscleAttribution`), which the app
// rebuilds for the day after a finish. Classifying these sets into the 20-group `LiftMuscle` vocabulary here
// would start a second, differently-derived per-muscle rollup for the same sessions.

public enum LiftStoreBridge {

    /// Same token as `ImportedLiftSets.bodyweightAddedNote` (app layer). Restated because this package cannot
    /// see the app module; `StrandTests/LiftParityTests` pins the two equal.
    public static let bodyweightAddedNote = "bodyweight+added"
    public static let sessionNoteTag = "telos-lift"
    public static let sessionIdPrefix = "telos-"

    public static func isTelosSession(id: String) -> Bool { id.hasPrefix(sessionIdPrefix) }

    // MARK: Rows

    /// The session row. `endTs` stays nil while the session runs, exactly as the table documents.
    public static func sessionRow(_ session: LiftLoggedSession, deviceId: String, sport: String) -> LiftSessionRow {
        var note = sessionNoteTag
        if session.end != nil, session.notDoneCount > 0 { note += " notDone=\(session.notDoneCount)" }
        return LiftSessionRow(
            id: session.id,
            deviceId: deviceId,
            startTs: Int(session.start.timeIntervalSince1970),
            endTs: session.end.map { Int($0.timeIntervalSince1970) },
            sport: sport,
            programId: session.templateId,
            programName: session.templateName,
            note: note)
    }

    /// A stored set's id: stable per logged set, so re-saving after an edit updates the row in place.
    public static func setId(sessionId: String, loggedSetId: String) -> String { "\(sessionId)#\(loggedSetId)" }

    /// One row per DONE set, `ord` in performed order, `setIndex` 1-based per exercise in performed order.
    public static func setRows(_ session: LiftLoggedSession, deviceId: String) -> [LiftSetRow] {
        var perExercise: [String: Int] = [:]
        return session.doneSetsInOrder.enumerated().map { ord, pair in
            let (ex, set) = (pair.exercise, pair.set)
            let key = LiftDedupe.exerciseKey(ex.name)
            let index = (perExercise[key] ?? 0) + 1
            perExercise[key] = index
            var notes: [String] = []
            if ex.isBodyweight, (set.weightKg ?? 0) > 0 { notes.append(bodyweightAddedNote) }
            if let token = set.kind.noteToken { notes.append(token) }
            return LiftSetRow(
                id: setId(sessionId: session.id, loggedSetId: set.id),
                deviceId: deviceId,
                sessionId: session.id,
                ord: ord,
                exercise: ex.name,
                primaryMuscle: nil,
                secondaryMuscles: [],
                setIndex: index,
                weightKg: set.weightKg,
                reps: set.reps,
                rpe: nil,
                isWarmup: set.kind.isWarmup,
                startTs: nil,
                endTs: set.completedAt.map { Int($0.timeIntervalSince1970) },
                restSec: set.restTakenSec,
                note: notes.isEmpty ? nil : notes.joined(separator: " "))
        }
    }

    /// The DONE sets of a logged session in the history shape (for the summary's "today").
    public static func historySets(of session: LiftLoggedSession) -> [LiftHistorySet] {
        session.doneSetsInOrder.map { pair in
            LiftHistorySet(exercise: pair.exercise.name,
                           weightKg: pair.set.weightKg,
                           reps: pair.set.reps,
                           isWarmup: pair.set.kind.isWarmup,
                           addedToBodyweight: pair.exercise.isBodyweight && (pair.set.weightKg ?? 0) > 0)
        }
    }

    /// Stored rows → history sessions, oldest first. Sessions with no stored sets are dropped: they carry
    /// nothing a prefill, a PR or a muscle comparison can read.
    public static func history(sessions: [LiftSessionRow], sets: [LiftSetWithSession]) -> [LiftHistorySession] {
        var bySession: [String: [LiftHistorySet]] = [:]
        for row in sets {
            let s = row.set
            bySession[s.sessionId, default: []].append(LiftHistorySet(
                exercise: s.exercise,
                weightKg: s.weightKg,
                reps: s.reps,
                isWarmup: s.isWarmup,
                addedToBodyweight: (s.note ?? "").contains(bodyweightAddedNote)))
        }
        return sessions.compactMap { row -> LiftHistorySession? in
            guard let sets = bySession[row.id], !sets.isEmpty else { return nil }
            return LiftHistorySession(
                id: row.id,
                start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
                end: row.endTs.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                templateId: isTelosSession(id: row.id) ? row.programId : nil,
                title: row.programName,
                sets: sets)
        }.sorted { $0.start < $1.start }
    }
}

// MARK: - Dedupe against a later import

/// Whether an imported session is one the wearer already logged in Telos.
///
/// THE RULE (decision 16: "dedupe by start time ± tolerance and day template"): the two starts are within
/// 30 minutes, AND either the template names agree (the imported title's first "·" segment — "Lower A (Di)"
/// in "Lower A (Di) · Tag 1 · Woche 5 · Lower" — against the logged template's name, case-folded) OR at least
/// half of the exercise names overlap (Jaccard on case-folded names), which catches a renamed template.
///
/// Thirty minutes because Alphaprog stamps the session when the wearer opened it in that app, and Telos when
/// the strength workout started — the same gym visit, minutes apart. Two genuinely different sessions of the
/// same template are a day or more apart.
///
/// The LOGGED session wins: it has warm-up flags, set times and rest taken, which the export does not. The
/// import skips the duplicate's workout row and sets, so nothing counts twice.
public enum LiftDedupe {
    public static let tolerance: TimeInterval = 30 * 60
    public static let minExerciseOverlap = 0.5

    public struct Candidate: Equatable, Sendable {
        public var start: Date
        public var title: String?
        public var exercises: [String]

        public init(start: Date, title: String?, exercises: [String]) {
            self.start = start
            self.title = title
            self.exercises = exercises
        }
    }

    /// The template part of a title: the first "·" segment, trimmed and case-folded; nil when empty.
    public static func templateKey(_ title: String?) -> String? {
        guard let title else { return nil }
        let first = title.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: false).first
            .map(String.init) ?? title
        let key = first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key.isEmpty ? nil : key
    }

    public static func exerciseKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isSameSession(_ a: Candidate, _ b: Candidate) -> Bool {
        guard abs(a.start.timeIntervalSince(b.start)) <= tolerance else { return false }
        if let ka = templateKey(a.title), let kb = templateKey(b.title), ka == kb { return true }
        let ea = Set(a.exercises.map(exerciseKey).filter { !$0.isEmpty })
        let eb = Set(b.exercises.map(exerciseKey).filter { !$0.isEmpty })
        let union = ea.union(eb)
        guard !union.isEmpty else { return false }
        return Double(ea.intersection(eb).count) / Double(union.count) >= minExerciseOverlap
    }

    /// Indices of `imported` that duplicate one of `logged`.
    public static func duplicateIndices(imported: [Candidate], logged: [Candidate]) -> Set<Int> {
        var out = Set<Int>()
        for (i, candidate) in imported.enumerated() where logged.contains(where: { isSameSession(candidate, $0) }) {
            out.insert(i)
        }
        return out
    }
}
