import Foundation

// LiftSession.swift — the session being logged, as a value.
//
// `LiftSessionRecorder` (app layer) owns one of these while a strength workout runs, journals it to disk on
// every change and mirrors the DONE sets into `liftSession` / `liftSet`. Everything that decides what a tap
// means — checking a set, un-checking it, finishing early — is here, pure, so it is tested without a store.
//
// A SET HAS THREE STATES, NOT TWO. `pending` (planned, not yet done), `done` (checked), `notDone` (the session
// finished without it). The third exists because decision 16 says an early finish "records unfinished sets as
// not done (never as zero)": a planned set the wearer skipped is not a set of 0 kg × 0 reps, and it is not
// silently dropped either — the finish screen counts it and the session note records it. Only `done` sets
// ever reach `liftSet` (see `LiftStoreBridge.setRows`), matching the importers' rule that an unperformed row
// is not a set.

public enum LiftSetStatus: String, Codable, Sendable {
    case pending
    case done
    case notDone
}

public struct LiftLoggedSet: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: LiftSetKind
    public var weightKg: Double?
    public var reps: Int?
    public var status: LiftSetStatus
    public var completedAt: Date?
    /// Rest actually taken AFTER this set, seconds (the gap to the next check), nil until known.
    public var restTakenSec: Int?
    /// The values came from a previous session (the row shows them as a suggestion until touched or checked).
    public var prefilled: Bool

    public init(id: String = UUID().uuidString, kind: LiftSetKind, weightKg: Double? = nil, reps: Int? = nil,
                status: LiftSetStatus = .pending, completedAt: Date? = nil, restTakenSec: Int? = nil,
                prefilled: Bool = false) {
        self.id = id
        self.kind = kind
        self.weightKg = weightKg
        self.reps = reps
        self.status = status
        self.completedAt = completedAt
        self.restTakenSec = restTakenSec
        self.prefilled = prefilled
    }
}

public struct LiftLoggedExercise: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var equipment: String?
    public var targetReps: Int?
    public var restSeconds: Int?
    public var isBodyweight: Bool
    public var sets: [LiftLoggedSet]
    public var increment: LiftIncrement.Resolved

    public init(id: String, name: String, equipment: String?, targetReps: Int?, restSeconds: Int?,
                isBodyweight: Bool, sets: [LiftLoggedSet], increment: LiftIncrement.Resolved) {
        self.id = id
        self.name = name
        self.equipment = equipment
        self.targetReps = targetReps
        self.restSeconds = restSeconds
        self.isBodyweight = isBodyweight
        self.sets = sets
        self.increment = increment
    }

    public var warmupSets: [LiftLoggedSet] { sets.filter { $0.kind.isWarmup } }
    public var workSets: [LiftLoggedSet] { sets.filter { !$0.kind.isWarmup } }
    public var doneCount: Int { sets.filter { $0.status == .done }.count }
    public var isComplete: Bool { !sets.isEmpty && sets.allSatisfy { $0.status != .pending } }
    /// The first set still to do, warm-ups first — the "active" row.
    public var activeSetId: String? { sets.first { $0.status == .pending }?.id }

    /// e1RM for one of this exercise's sets (nil = "—"): bodyweight exercises abstain, see `LiftE1RM`.
    public func e1rm(_ set: LiftLoggedSet) -> Double? {
        guard !set.kind.isWarmup else { return nil }
        return LiftE1RM.epley(weightKg: set.weightKg, reps: set.reps,
                              addedToBodyweight: isBodyweight && (set.weightKg ?? 0) > 0)
    }
}

public struct LiftLoggedSession: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var templateId: String?
    public var templateName: String?
    public var programName: String?
    public var start: Date
    public var end: Date?
    public var exercises: [LiftLoggedExercise]
    /// True when Finish was pressed with planned sets still pending.
    public var finishedEarly: Bool

    public init(id: String, templateId: String?, templateName: String?, programName: String?, start: Date,
                end: Date? = nil, exercises: [LiftLoggedExercise], finishedEarly: Bool = false) {
        self.id = id
        self.templateId = templateId
        self.templateName = templateName
        self.programName = programName
        self.start = start
        self.end = end
        self.exercises = exercises
        self.finishedEarly = finishedEarly
    }

    /// The deterministic session id for a workout that started at `start`: re-derivable after a crash, so a
    /// relaunch re-attaches the journal and the stored rows to the same session instead of minting a twin.
    public static func sessionId(workoutStart: Date) -> String {
        "telos-\(Int(workoutStart.timeIntervalSince1970))"
    }

    public var plannedCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
    public var doneCount: Int { exercises.reduce(0) { $0 + $1.doneCount } }
    public var pendingCount: Int { exercises.reduce(0) { $0 + $1.sets.filter { $0.status == .pending }.count } }
    public var notDoneCount: Int { exercises.reduce(0) { $0 + $1.sets.filter { $0.status == .notDone }.count } }
    /// Finish becomes the prominent primary action once this is true (decision 16).
    public var allPlannedDone: Bool { plannedCount > 0 && pendingCount == 0 }

    // MARK: Edits

    public mutating func updateSet(exerciseId: String, setId: String, _ change: (inout LiftLoggedSet) -> Void) {
        guard let e = exercises.firstIndex(where: { $0.id == exerciseId }),
              let s = exercises[e].sets.firstIndex(where: { $0.id == setId }) else { return }
        change(&exercises[e].sets[s])
    }

    /// Check a set: it becomes `done` at `now`, its prefill flag clears (the wearer confirmed the values), and
    /// the previous done set's rest-taken is closed at this instant. Returns the rest to start, in seconds, from
    /// this exercise's override or `defaultRestSeconds`. Nil when the ids do not resolve.
    @discardableResult
    public mutating func check(exerciseId: String, setId: String, at now: Date,
                               defaultRestSeconds: Int) -> Int? {
        guard let e = exercises.firstIndex(where: { $0.id == exerciseId }),
              let s = exercises[e].sets.firstIndex(where: { $0.id == setId }) else { return nil }
        closeRestOfLastDone(at: now)
        exercises[e].sets[s].status = .done
        exercises[e].sets[s].completedAt = now
        exercises[e].sets[s].prefilled = false
        exercises[e].sets[s].restTakenSec = nil
        return LiftRestTimer.duration(exerciseRestSeconds: exercises[e].restSeconds,
                                      globalDefaultSeconds: defaultRestSeconds)
    }

    /// Undo a check. The set returns to `pending` with its values kept (the wearer may just correct a figure).
    public mutating func uncheck(exerciseId: String, setId: String) {
        updateSet(exerciseId: exerciseId, setId: setId) {
            $0.status = .pending
            $0.completedAt = nil
            $0.restTakenSec = nil
        }
    }

    /// Append one more set of `kind` to an exercise, copying the last set's values as the prefill.
    public mutating func addSet(exerciseId: String, kind: LiftSetKind = .working) {
        guard let e = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        let template = exercises[e].sets.last { $0.kind.isWarmup == kind.isWarmup }
        let new = LiftLoggedSet(kind: kind, weightKg: template?.weightKg, reps: template?.reps,
                                prefilled: template != nil)
        if kind.isWarmup {
            let at = exercises[e].sets.lastIndex(where: { $0.kind.isWarmup }).map { $0 + 1 } ?? 0
            exercises[e].sets.insert(new, at: at)
        } else {
            exercises[e].sets.append(new)
        }
    }

    /// Remove a PENDING set (a done set is un-checked first; deleting logged work is a separate decision).
    public mutating func removePendingSet(exerciseId: String, setId: String) {
        guard let e = exercises.firstIndex(where: { $0.id == exerciseId }) else { return }
        exercises[e].sets.removeAll { $0.id == setId && $0.status == .pending }
    }

    /// Finish the session. Every still-pending set becomes `notDone` — NEVER a zero, never deleted — and
    /// `finishedEarly` records that there were some.
    public mutating func finish(at now: Date) {
        closeRestOfLastDone(at: now, onlyIfWithin: 15 * 60)
        var early = false
        for e in exercises.indices {
            for s in exercises[e].sets.indices where exercises[e].sets[s].status == .pending {
                exercises[e].sets[s].status = .notDone
                early = true
            }
        }
        finishedEarly = early
        end = now
    }

    /// Done sets in the order they were performed (completion time, then plan order), for `liftSet.ord`.
    public var doneSetsInOrder: [(exercise: LiftLoggedExercise, set: LiftLoggedSet)] {
        var out: [(exercise: LiftLoggedExercise, set: LiftLoggedSet, order: Int)] = []
        var order = 0
        for ex in exercises {
            for set in ex.sets {
                if set.status == .done { out.append((exercise: ex, set: set, order: order)) }
                order += 1
            }
        }
        return out.sorted { a, b in
            let ta = a.set.completedAt ?? .distantFuture, tb = b.set.completedAt ?? .distantFuture
            if ta != tb { return ta < tb }
            return a.order < b.order
        }.map { (exercise: $0.exercise, set: $0.set) }
    }

    /// The rest after the most recent done set ends now (the next set is being checked).
    ///
    /// `onlyIfWithin` guards the finish: a wearer who sits for twenty minutes and then taps Finish did not
    /// rest twenty minutes between sets, so an implausibly long gap is left unknown rather than recorded.
    private mutating func closeRestOfLastDone(at now: Date, onlyIfWithin limit: TimeInterval? = nil) {
        guard let last = doneSetsInOrder.last, last.set.restTakenSec == nil,
              let completed = last.set.completedAt else { return }
        let gap = now.timeIntervalSince(completed)
        guard gap >= 0 else { return }
        if let limit, gap > limit { return }
        updateSet(exerciseId: last.exercise.id, setId: last.set.id) { $0.restTakenSec = Int(gap.rounded()) }
    }
}
