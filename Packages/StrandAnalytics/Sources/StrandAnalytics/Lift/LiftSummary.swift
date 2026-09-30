import Foundation

// LiftSummary.swift — the finish screen's numbers (decision 16): session number, workout count, duration,
// streak, per-exercise sets / PRs / e1RM change, muscle groups with their volume change against the previous
// comparable session, and achievements with REAL rules.
//
// EVERY FIGURE HERE HAS A COMPARISON OR IT IS ABSENT. A PR needs a previous best (the first time an exercise
// is logged is not a record, it is a first). An e1RM change needs a previous session with an estimate. A
// muscle group's % change needs a previous comparable session — the last session of the SAME day template —
// and a non-zero previous volume; otherwise it is nil and the screen writes "—". Nothing is compared against
// an average, a population or a guess.
//
// ACHIEVEMENTS ARE RULES, NOT FLAVOUR. Alphaprog shows titles like "Nachteule" / "Workaholic" without saying
// what earned them. Each case below carries the fact that earned it and its rule is written on the case, so
// the screen can say "started at 22:14 (after 21:00)" instead of a badge nobody can check.

public enum LiftAchievement: Equatable, Sendable {
    /// Started between 21:00 and 03:59 local.
    case nightOwl(startHour: Int)
    /// Started between 04:00 and 06:59 local.
    case earlyBird(startHour: Int)
    /// At least 90 minutes from start to finish.
    case longHaul(minutes: Int)
    /// Every planned set done — nothing left pending at Finish (at least one set planned).
    case everySetDone(sets: Int)
    /// At least one personal record this session.
    case newRecords(count: Int)
    /// The weekly streak reached a milestone (4, 8, 12, 26, 52 weeks in a row).
    case weekStreak(weeks: Int)
    /// The total strength-session count reached a milestone (10, 25, 50, then every 100).
    case sessionMilestone(count: Int)
    /// More volume than any earlier session of this day template (at least one earlier one with volume).
    case templateVolumeBest(volumeKg: Double, previousBestKg: Double)

    public static let nightOwlFromHour = 21
    public static let nightOwlUntilHour = 4
    public static let earlyBirdUntilHour = 7
    public static let longHaulMinutes = 90
    public static let streakMilestones = [4, 8, 12, 26, 52]
    public static func isSessionMilestone(_ n: Int) -> Bool {
        n == 10 || n == 25 || n == 50 || (n > 0 && n % 100 == 0)
    }
}

public struct LiftSessionSummary: Equatable, Sendable {

    public enum Record: Equatable, Sendable {
        /// Best estimated 1RM ever for the exercise.
        case e1rm(newKg: Double, previousBestKg: Double)
        /// Heaviest working weight ever for the exercise (absolute loads only).
        case heaviest(newKg: Double, previousBestKg: Double)
    }

    public struct ExerciseLine: Equatable, Sendable {
        public var name: String
        public var setsDone: Int
        public var setsNotDone: Int
        public var bestE1rmKg: Double?
        /// Best e1RM in the most recent EARLIER session that had one for this exercise.
        public var previousE1rmKg: Double?
        public var e1rmDeltaKg: Double? {
            guard let a = bestE1rmKg, let b = previousE1rmKg else { return nil }
            return a - b
        }
        public var records: [Record]
    }

    public struct MuscleLine: Equatable, Sendable {
        /// The attribution key the caller's `musclesFor` returned (e.g. `MuscleGroup.rawValue`).
        public var group: String
        /// Working sets that moved this group today (a two-mover exercise counts for both).
        public var sets: Int
        /// `sets` over today's working sets — Alphaprog's "100 % · 1 Satz".
        public var shareOfSets: Double
        public var volumeKg: Double
        /// Volume for this group in the previous comparable session; nil when there is none.
        public var previousVolumeKg: Double?
        /// (today − previous) / previous. Nil — "—" — without a comparable session or with a zero previous.
        public var changePct: Double?
    }

    public var templateSessionNumber: Int
    public var totalSessions: Int
    public var durationSec: TimeInterval?
    public var streakWeeks: Int
    public var setsDone: Int
    public var setsNotDone: Int
    public var workingSetsDone: Int
    public var volumeKg: Double
    public var exercises: [ExerciseLine]
    public var muscles: [MuscleLine]
    /// When the previous session of the same template started; nil = no comparable session.
    public var comparableSessionStart: Date?
    public var achievements: [LiftAchievement]

    public var recordCount: Int { exercises.reduce(0) { $0 + $1.records.count } }
    /// Exercises whose best e1RM beat the previous session's by more than the noise floor.
    public var improvedCount: Int {
        exercises.filter { ($0.e1rmDeltaKg ?? 0) >= LiftSessionSummary.improvementEpsilonKg }.count
    }

    /// Same floor as `StrengthProgression.improvementEpsilonKg`: below half a kilo an e1RM change is rounding.
    public static let improvementEpsilonKg = 0.5
}

// MARK: - Personal records (shared by the live check and the finish screen)

/// What an exercise had reached BEFORE this session — the bar a PR has to clear.
///
/// A metric the history never produced stays nil, and a nil bar can never be cleared: the first session of an
/// exercise sets its baseline, it is not a record (decision 16's honesty rule — no comparison, no claim).
public struct LiftPriorBest: Equatable, Sendable {
    /// Best Epley estimate over usable working sets (1–12 reps, absolute load).
    public var e1rmKg: Double?
    /// Heaviest absolute working load with at least one rep.
    public var heaviestKg: Double?
    /// The set that produced `e1rmKg` — "best: 100 kg × 10" on screen.
    public var bestSetWeightKg: Double?
    public var bestSetReps: Int?

    public init(e1rmKg: Double? = nil, heaviestKg: Double? = nil, bestSetWeightKg: Double? = nil,
                bestSetReps: Int? = nil) {
        self.e1rmKg = e1rmKg
        self.heaviestKg = heaviestKg
        self.bestSetWeightKg = bestSetWeightKg
        self.bestSetReps = bestSetReps
    }

    /// From this exercise's sets in earlier sessions.
    public init(sets: [LiftHistorySet]) {
        self.init()
        for set in sets { absorb(set) }
    }

    public var hasHistory: Bool { e1rmKg != nil || heaviestKg != nil }

    /// Raise the bar with a set — but only for metrics that ALREADY have a bar. A metric with no history stays
    /// nil through a whole first session, so no set of that session can be called a record against another.
    public mutating func raise(with set: LiftHistorySet) {
        if let bar = e1rmKg, let e = set.e1rmKg, e > bar {
            e1rmKg = e
            bestSetWeightKg = set.weightKg
            bestSetReps = set.reps
        }
        if let bar = heaviestKg, let w = LiftRecordCheck.absoluteLoad(set), w > bar { heaviestKg = w }
    }

    /// History absorption: every metric may start here.
    mutating func absorb(_ set: LiftHistorySet) {
        if let e = set.e1rmKg, e > (e1rmKg ?? -1) {
            e1rmKg = e
            bestSetWeightKg = set.weightKg
            bestSetReps = set.reps
        }
        if let w = LiftRecordCheck.absoluteLoad(set), w > (heaviestKg ?? -1) { heaviestKg = w }
    }
}

public enum LiftRecordCheck {

    /// The absolute working load of a set, or nil for a warm-up, a set with no reps, or a load added to bodyweight.
    public static func absoluteLoad(_ set: LiftHistorySet) -> Double? {
        guard !set.isWarmup, !set.addedToBodyweight, (set.reps ?? 0) > 0, let w = set.weightKg, w > 0 else { return nil }
        return w
    }

    /// Records for a candidate e1RM / heaviest load against a bar. e1RM must beat the bar by more than the
    /// half-kilo noise floor (`LiftSessionSummary.improvementEpsilonKg`); a load must simply be heavier.
    public static func records(e1rmKg: Double?, heaviestKg: Double?,
                               against bar: LiftPriorBest) -> [LiftSessionSummary.Record] {
        var out: [LiftSessionSummary.Record] = []
        if let e = e1rmKg, let prev = bar.e1rmKg, e > prev + LiftSessionSummary.improvementEpsilonKg {
            out.append(.e1rm(newKg: e, previousBestKg: prev))
        }
        if let w = heaviestKg, let prev = bar.heaviestKg, w > prev + 0.01 {
            out.append(.heaviest(newKg: w, previousBestKg: prev))
        }
        return out
    }

    /// The live check when a set is ticked: is THIS set a new best right now?
    ///
    /// The bar is the pre-session best raised by the exercise's OTHER done sets this session, so a second heavier
    /// set still flashes but an equal or lighter one after a PR does not. Returns [] on an exercise with no
    /// history (first session = baseline, not a record).
    public static func liveRecords(setId: String, in exercise: LiftLoggedExercise,
                                   prior: LiftPriorBest) -> [LiftSessionSummary.Record] {
        guard prior.hasHistory, let set = exercise.sets.first(where: { $0.id == setId }),
              !set.kind.isWarmup else { return [] }
        var bar = prior
        for other in exercise.sets where other.id != setId && other.status == .done {
            bar.raise(with: historySet(other, in: exercise))
        }
        let candidate = historySet(set, in: exercise)
        return records(e1rmKg: candidate.e1rmKg, heaviestKg: absoluteLoad(candidate), against: bar)
    }

    static func historySet(_ set: LiftLoggedSet, in exercise: LiftLoggedExercise) -> LiftHistorySet {
        LiftHistorySet(exercise: exercise.name, weightKg: set.weightKg, reps: set.reps,
                       isWarmup: set.kind.isWarmup,
                       addedToBodyweight: exercise.isBodyweight && (set.weightKg ?? 0) > 0)
    }
}

public enum LiftSummaryBuilder {

    /// Build the summary for a FINISHED session.
    ///
    /// - history: every stored strength session EXCEPT this one (imported and logged alike).
    /// - musclesFor: the muscle attribution for an exercise name (the app passes `MuscleAttribution`).
    public static func build(session: LiftLoggedSession,
                             history: [LiftHistorySession],
                             musclesFor: (String) -> [String],
                             calendar: Calendar) -> LiftSessionSummary {
        let prior = history.filter { $0.start < session.start && $0.id != session.id }
            .sorted { $0.start < $1.start }
        let end = session.end ?? session.start
        let current = LiftStoreBridge.historySets(of: session)

        // Per exercise.
        var lines: [LiftSessionSummary.ExerciseLine] = []
        for ex in session.exercises {
            let key = LiftDedupe.exerciseKey(ex.name)
            let mine = current.filter { LiftDedupe.exerciseKey($0.exercise) == key }
            let best = mine.compactMap(\.e1rmKg).max()
            let priorSets = prior.flatMap { $0.sets(of: ex.name) }
            let previousSession = prior.reversed().first { s in s.sets(of: ex.name).contains { $0.e1rmKg != nil } }
            let prevSessionBest = previousSession?.sets(of: ex.name).compactMap(\.e1rmKg).max()
            // The SAME rule the logger applies live at check time (`LiftRecordCheck`), so the finish screen and
            // the in-set reward can never disagree about what was a record.
            let records = LiftRecordCheck.records(
                e1rmKg: best,
                heaviestKg: mine.compactMap(LiftRecordCheck.absoluteLoad).max(),
                against: LiftPriorBest(sets: priorSets))
            lines.append(LiftSessionSummary.ExerciseLine(
                name: ex.name,
                setsDone: ex.sets.filter { $0.status == .done }.count,
                setsNotDone: ex.sets.filter { $0.status == .notDone }.count,
                bestE1rmKg: best,
                previousE1rmKg: prevSessionBest,
                records: records))
        }

        // The comparable session: the last earlier session of the SAME day template.
        let comparable = prior.reversed().first {
            $0.ran(templateId: session.templateId, templateName: session.templateName)
        }
        let muscles = muscleLines(current: current, previous: comparable?.sets, musclesFor: musclesFor)

        let volume = current.reduce(0) { $0 + $1.volumeKg }
        let workingDone = current.filter { !$0.isWarmup }.count
        let templateSessions = prior.filter {
            $0.ran(templateId: session.templateId, templateName: session.templateName)
        }
        let streak = streakWeeks(sessionStarts: prior.map(\.start) + [session.start], now: session.start,
                                 calendar: calendar)
        let total = prior.count + 1
        let duration: TimeInterval? = end > session.start ? end.timeIntervalSince(session.start) : nil

        var summary = LiftSessionSummary(
            templateSessionNumber: (session.templateId == nil && session.templateName == nil)
                ? total : templateSessions.count + 1,
            totalSessions: total,
            durationSec: duration,
            streakWeeks: streak,
            setsDone: session.doneCount,
            setsNotDone: session.notDoneCount,
            workingSetsDone: workingDone,
            volumeKg: volume,
            exercises: lines,
            muscles: muscles,
            comparableSessionStart: comparable?.start,
            achievements: [])
        let templateBest = templateSessions.map { $0.sets.reduce(0) { $0 + $1.volumeKg } }.max()
        summary.achievements = achievements(session: session, summary: summary,
                                            templateBestVolumeKg: templateBest, calendar: calendar)
        return summary
    }

    // MARK: Muscles

    static func muscleLines(current: [LiftHistorySet], previous: [LiftHistorySet]?,
                            musclesFor: (String) -> [String]) -> [LiftSessionSummary.MuscleLine] {
        func tally(_ sets: [LiftHistorySet]) -> (sets: [String: Int], volume: [String: Double]) {
            var count: [String: Int] = [:]
            var volume: [String: Double] = [:]
            for set in sets where !set.isWarmup {
                for group in musclesFor(set.exercise) {
                    count[group, default: 0] += 1
                    volume[group, default: 0] += set.volumeKg
                }
            }
            return (sets: count, volume: volume)
        }
        let now = tally(current)
        var before: (sets: [String: Int], volume: [String: Double])?
        if let previous { before = tally(previous) }
        let workingSets = current.filter { !$0.isWarmup }.count
        var groups = Set(now.sets.keys)
        if let before { groups.formUnion(before.sets.keys) }

        let lines = groups.map { group -> LiftSessionSummary.MuscleLine in
            let sets = now.sets[group] ?? 0
            let vol = now.volume[group] ?? 0
            let prev = before.map { $0.volume[group] ?? 0 }
            var change: Double?
            if let prev, prev > 0 { change = (vol - prev) / prev }
            return LiftSessionSummary.MuscleLine(
                group: group, sets: sets,
                shareOfSets: workingSets > 0 ? Double(sets) / Double(workingSets) : 0,
                volumeKg: vol, previousVolumeKg: prev, changePct: change)
        }
        return lines.sorted { a, b in
            if a.sets != b.sets { return a.sets > b.sets }
            if a.volumeKg != b.volumeKg { return a.volumeKg > b.volumeKg }
            return a.group < b.group
        }
    }

    // MARK: Streak

    /// Weeks in a row, ending with the week of `now`, that contain at least one session.
    public static func streakWeeks(sessionStarts: [Date], now: Date, calendar: Calendar) -> Int {
        func weekStart(_ d: Date) -> Date? { calendar.dateInterval(of: .weekOfYear, for: d)?.start }
        let weeks = Set(sessionStarts.compactMap(weekStart))
        guard var cursor = weekStart(now), weeks.contains(cursor) else { return 0 }
        var n = 0
        while weeks.contains(cursor) {
            n += 1
            // Step back by a week and re-anchor at that week's start (DST-safe: never 7 × 86 400 s).
            guard let back = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor),
                  let start = weekStart(back) else { break }
            cursor = start
        }
        return n
    }

    // MARK: Achievements

    static func achievements(session: LiftLoggedSession, summary: LiftSessionSummary,
                             templateBestVolumeKg: Double?, calendar: Calendar) -> [LiftAchievement] {
        var out: [LiftAchievement] = []
        let hour = calendar.component(.hour, from: session.start)
        if hour >= LiftAchievement.nightOwlFromHour || hour < LiftAchievement.nightOwlUntilHour {
            out.append(.nightOwl(startHour: hour))
        } else if hour < LiftAchievement.earlyBirdUntilHour {
            out.append(.earlyBird(startHour: hour))
        }
        if let d = summary.durationSec, Int(d / 60) >= LiftAchievement.longHaulMinutes {
            out.append(.longHaul(minutes: Int(d / 60)))
        }
        if session.plannedCount > 0, session.notDoneCount == 0, session.doneCount > 0 {
            out.append(.everySetDone(sets: session.doneCount))
        }
        if summary.recordCount > 0 { out.append(.newRecords(count: summary.recordCount)) }
        if LiftAchievement.streakMilestones.contains(summary.streakWeeks) {
            out.append(.weekStreak(weeks: summary.streakWeeks))
        }
        if LiftAchievement.isSessionMilestone(summary.totalSessions) {
            out.append(.sessionMilestone(count: summary.totalSessions))
        }
        if let best = templateBestVolumeKg, best > 0, summary.volumeKg > best {
            out.append(.templateVolumeBest(volumeKg: summary.volumeKg, previousBestKg: best))
        }
        return out
    }
}
