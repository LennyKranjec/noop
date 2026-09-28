import Foundation
import StrandImport
import WhoopStore

// ImportedLiftSets.swift — the imported sets, into the store's own lift log.
//
// WHAT THIS CLOSES. `liftSession` / `liftSet` (store v46) were added as the place an individual set could
// live, and the migration's own note says why: "NOOP can already IMPORT a lifting history … but that path
// collapses each workout to a session summary … because there has never been anywhere to put an
// individual set." The tables landed; nothing ever wrote to them. So the import still stored volume load,
// a set count and a top set, and "is my bench press moving" was unanswerable from stored data even though
// the parsers had every set in hand and threw them away.
//
// NO SCHEMA CHANGE. The tables, the indexes, the natural key and the device-scoped delete list are all
// already there. This is the writer they were waiting for.
//
// ONE SESSION PER WORKOUT ROW. The import already writes a `workout` row per session under deviceId
// "lifting"; `liftSession` uses the workout table's own natural key (deviceId, startTs, sport), so the two
// find each other without a foreign key. Both are written under the same deviceId, so a
// "delete this device's data" clears the pair together.
//
// IDEMPOTENT, because re-importing is the normal case: a wearer exports the same log again next month and
// re-imports the whole file. The session id is derived from its start rather than minted fresh, and a
// session's sets are REPLACED rather than merged, so importing the same export twice leaves the store
// exactly as one import does, and importing a longer export adds only what is new.
//
// NO MUSCLE CLASSIFICATION ON AN IMPORTED SET, deliberately. `liftSet.primaryMuscle` is a `LiftMuscle` (20
// fine groups, the in-app vocabulary); the import's attribution is `MuscleGroup` (13 coarse groups) and is
// ALREADY banked per day as `muscle_volume_*`, which is what the muscle model card reads. Inventing a
// mapping between the two here would put a second per-muscle rollup in the app, derived differently from
// the first, and the two would disagree about the same session — so imported sets carry no muscle and
// `liftSetCounts` correctly counts none of them. Progression is keyed on the exercise NAME and needs none.

enum ImportedLiftSets {

    /// The deviceId every imported lifting row is written under — the same one the workout rows use.
    static var deviceId: String { LiftingImporter.sourceId }

    /// The sport every imported lifting session is filed under, matching its workout row.
    static var sport: String { LiftingImporter.sport }

    /// A session's id, derived from its start so it is the same on every import of the same session.
    ///
    /// NOT a UUID. `upsertLiftSessions` resolves conflicts on the natural key and leaves the stored `id`
    /// alone, so a fresh id per import would write sets under an id no session row carries — the sets
    /// would be orphans and the screen would read an empty history from a full table.
    static func sessionId(startTs: Int) -> String { "lifting-\(startTs)" }

    /// A set's id, derived from its session and its position, for the same reason.
    static func setId(sessionId: String, ord: Int) -> String { "\(sessionId)#\(ord)" }

    /// The set rows for one session, in the order the export listed them.
    ///
    /// `ord` is 0-based over the whole session; `setIndex` is 1-based within its exercise, which is what
    /// makes "set 3 of 4" reconstructible. Counted per exercise NAME as it appears, so an exercise the
    /// wearer came back to later in the session continues its own numbering rather than restarting.
    ///
    /// Pure and static so it can be tested without a database.
    static func setRows(for session: LiftingSession, sessionId: String) -> [LiftSetRow] {
        var perExercise: [String: Int] = [:]
        return session.sets.enumerated().map { ord, record in
            let key = record.exercise.lowercased().trimmingCharacters(in: .whitespaces)
            let index = (perExercise[key] ?? 0) + 1
            perExercise[key] = index
            return LiftSetRow(
                id: setId(sessionId: sessionId, ord: ord),
                deviceId: deviceId,
                sessionId: sessionId,
                ord: ord,
                exercise: record.exercise,
                // See the file header: no LiftMuscle is invented for an imported set.
                primaryMuscle: nil,
                secondaryMuscles: [],
                setIndex: index,
                weightKg: record.weightKg,
                reps: record.reps,
                // The exports NOOP reads carry no RPE (Hevy's API has one; its CSV and Alphaprog do not),
                // and this lane has nowhere to get one. Absent, never a middling default.
                rpe: nil,
                isWarmup: record.isWarmup,
                // A set's own start/end and the rest after it are not in any of these exports. The
                // session's bounds are on the session row; guessing a set's clock from them would be
                // inventing timestamps.
                startTs: nil,
                endTs: nil,
                restSec: nil,
                // THE BODYWEIGHT-ADDED MARKER, carried into storage rather than left in the parse.
                //
                // `weightKg` for one of these is the ADDED weight alone, and nothing in the schema
                // distinguishes that from an absolute load — so without this note a re-derivation from
                // stored rows would read ten added kilograms as a ten-kilogram lift, which is exactly the
                // reading the parser refuses. The note is a fixed token, matched not translated: it is
                // stored data, not UI copy.
                note: record.addedToBodyweight ? bodyweightAddedNote : nil)
        }
    }

    /// The stored marker for a load the export wrote as an addition to bodyweight (Alphaprog's `+10`).
    ///
    /// A fixed ASCII token in a data column. Never localized, never shown raw: the screen reads it and
    /// writes its own sentence.
    static let bodyweightAddedNote = "bodyweight+added"

    /// Rebuild `LiftingSetRecord`s from stored rows, so a read is the inverse of `setRows`.
    ///
    /// The ONE place the stored note is turned back into the flag, so a reader cannot forget to and quietly
    /// treat an added load as an absolute one.
    static func record(from row: LiftSetRow) -> LiftingSetRecord {
        LiftingSetRecord(
            exercise: row.exercise,
            weightKg: row.weightKg,
            reps: row.reps,
            isWarmup: row.isWarmup,
            addedToBodyweight: row.note == bodyweightAddedNote)
    }

    /// Write every session that carries sets. Returns how many sessions were written.
    ///
    /// A session with no sets is skipped rather than written empty: a `liftSession` row with no `liftSet`
    /// rows reads as "this session had no sets", where the truth is "this import did not record them".
    /// That distinction is what lets the progression screen say which sessions it can read.
    @discardableResult
    static func write(_ sessions: [LiftingSession], store: WhoopStore) async throws -> Int {
        let withSets = sessions.filter { !$0.sets.isEmpty }
        guard !withSets.isEmpty else { return 0 }

        let sessionRows = withSets.map { session -> LiftSessionRow in
            let startTs = Int(session.start.timeIntervalSince1970)
            return LiftSessionRow(
                id: sessionId(startTs: startTs),
                deviceId: deviceId,
                startTs: startTs,
                endTs: session.end > session.start ? Int(session.end.timeIntervalSince1970) : nil,
                sport: sport,
                programId: nil,
                // The export's own workout title, which is the closest thing it has to a program name and
                // is snapshotted here exactly as a logged session snapshots one.
                programName: session.title,
                note: nil)
        }
        _ = try await store.upsertLiftSessions(sessionRows)

        // READ THE IDS BACK rather than assuming the ones just written won. `upsertLiftSessions` conflicts
        // on (deviceId, startTs, sport) and does NOT update the id, so a session row that already existed
        // under a different id keeps it — and sets written under the id this function minted would be
        // orphans. One extra read makes the write correct in that case instead of silently wrong.
        let starts = sessionRows.map(\.startTs)
        let stored = try await store.liftSessions(
            deviceId: deviceId, fromTs: starts.min() ?? 0, toTs: starts.max() ?? 0)
        var idByStart: [Int: String] = [:]
        for row in stored where row.sport == sport { idByStart[row.startTs] = row.id }

        var written = 0
        for session in withSets {
            let startTs = Int(session.start.timeIntervalSince1970)
            guard let id = idByStart[startTs] else { continue }
            _ = try await store.replaceLiftSets(
                sessionId: id, sets: setRows(for: session, sessionId: id))
            written += 1
        }
        return written
    }
}
