import Foundation

// LiftPlanning.swift — what happens BEFORE the first set: which day template today is, what each row is
// prefilled with, and what the progression proposal says.

// MARK: - History, as the store holds it

/// One stored set, stripped to what planning and the summary read. Built from `liftSet` rows by
/// `LiftStoreBridge.history(sessions:sets:)`.
public struct LiftHistorySet: Equatable, Sendable {
    public var exercise: String
    public var weightKg: Double?
    public var reps: Int?
    public var isWarmup: Bool
    /// Weight ADDED to bodyweight (Alphaprog's `+10`, or a load logged on a bodyweight exercise).
    public var addedToBodyweight: Bool

    public init(exercise: String, weightKg: Double?, reps: Int?, isWarmup: Bool = false,
                addedToBodyweight: Bool = false) {
        self.exercise = exercise
        self.weightKg = weightKg
        self.reps = reps
        self.isWarmup = isWarmup
        self.addedToBodyweight = addedToBodyweight
    }

    public var e1rmKg: Double? {
        guard !isWarmup else { return nil }
        return LiftE1RM.epley(weightKg: weightKg, reps: reps, addedToBodyweight: addedToBodyweight)
    }

    /// Weight × reps for a working set with both, else 0 (the importers' volume-load rule).
    public var volumeKg: Double {
        guard !isWarmup, let w = weightKg, let r = reps, w > 0, r > 0 else { return 0 }
        return w * Double(r)
    }
}

/// One stored strength session.
public struct LiftHistorySession: Equatable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date?
    /// The Telos template id the session ran, nil for an imported one.
    public var templateId: String?
    /// The template name (Telos) or the export's session title ("Lower A (Di) · Tag 1 · Woche 5 · Lower").
    public var title: String?
    public var sets: [LiftHistorySet]

    public init(id: String, start: Date, end: Date? = nil, templateId: String? = nil, title: String? = nil,
                sets: [LiftHistorySet]) {
        self.id = id
        self.start = start
        self.end = end
        self.templateId = templateId
        self.title = title
        self.sets = sets
    }

    /// Whether this session ran the given day template: the same template id, or — for a session imported
    /// from Alphaprog, which has no id — the same template NAME as the first "·" segment of its title.
    public func ran(templateId: String?, templateName: String?) -> Bool {
        if let templateId, let mine = self.templateId, mine == templateId { return true }
        guard let a = LiftDedupe.templateKey(title), let b = LiftDedupe.templateKey(templateName) else { return false }
        return a == b
    }

    public func sets(of exercise: String) -> [LiftHistorySet] {
        let key = LiftDedupe.exerciseKey(exercise)
        return sets.filter { LiftDedupe.exerciseKey($0.exercise) == key }
    }

    public var exerciseKeys: Set<String> { Set(sets.map { LiftDedupe.exerciseKey($0.exercise) }) }
}

// MARK: - Today's template

public enum LiftTemplatePicker {

    public enum Reason: Equatable, Sendable {
        /// The template's weekday tag is today ("(Di)" on a Tuesday).
        case weekday
        /// No tag matches today: the next template in the rotation after the last one completed.
        case rotation
        /// Nothing to go on (no tag today, nothing completed yet): the first template in the rotation.
        case first
    }

    /// The rotation: tagged templates in week order (Monday first), untagged ones after them in library order.
    /// For the owner's plan that is Upper A (Mo) → Lower A (Di) → Upper B (Do) → Lower B (Fr).
    public static func rotation(_ templates: [LiftDayTemplate]) -> [LiftDayTemplate] {
        let indexed = Array(templates.enumerated())
        return indexed.sorted { a, b in
            let wa = a.element.weekday.map(LiftWeekday.mondayFirstIndex) ?? Int.max
            let wb = b.element.weekday.map(LiftWeekday.mondayFirstIndex) ?? Int.max
            if wa != wb { return wa < wb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Pick today's template. `weekday` is a Calendar weekday (1 = Sunday).
    public static func pick(templates: [LiftDayTemplate], weekday: Int,
                            lastCompletedTemplateId: String?) -> (template: LiftDayTemplate, reason: Reason)? {
        let order = rotation(templates)
        guard !order.isEmpty else { return nil }
        let lastIndex = lastCompletedTemplateId.flatMap { id in order.firstIndex { $0.id == id } }

        let today = order.filter { $0.weekday == weekday }
        if today.count == 1 { return (today[0], .weekday) }
        if today.count > 1 {
            // Two programs tagged the same day: the first of them AFTER the last completed template, so the
            // pair alternates instead of the first one winning forever.
            if let lastIndex {
                for step in 1...order.count {
                    let candidate = order[(lastIndex + step) % order.count]
                    if candidate.weekday == weekday { return (candidate, .weekday) }
                }
            }
            return (today[0], .weekday)
        }
        if let lastIndex { return (order[(lastIndex + 1) % order.count], .rotation) }
        return (order[0], .first)
    }
}

// MARK: - Prefill

public enum LiftPrefill {

    public enum Source: Equatable, Sendable {
        /// The last session of the SAME day template (decision 16's first choice).
        case sameTemplate(Date)
        /// No session of this template has the exercise: the last session of the exercise anywhere.
        case sameExercise(Date)
        /// Never logged: weights are empty ("—"), reps show the plan's target.
        case none
    }

    public struct Result: Equatable, Sendable {
        public var sets: [LiftLoggedSet]
        public var source: Source
        /// This exercise's sets in the session the prefill came from — the "Last time" card.
        public var lastTime: [LiftHistorySet]
        public var lastTimeTitle: String?

        public init(sets: [LiftLoggedSet], source: Source, lastTime: [LiftHistorySet], lastTimeTitle: String?) {
            self.sets = sets
            self.source = source
            self.lastTime = lastTime
            self.lastTimeTitle = lastTimeTitle
        }
    }

    /// The rows for one planned exercise.
    ///
    /// MAPPING: the i-th planned warm-up takes the i-th warm-up of last time; the j-th planned work set takes
    /// the j-th work set of last time. When the plan has more sets than last time, the extra rows copy last
    /// time's final set of the same kind (the weight that was on the machine). A kind that has no past set at
    /// all gets NO weight (shown "—") and the plan's rep target — a target is not a measurement, and the row
    /// is only a proposal until the wearer checks it. Nothing is imputed from another exercise.
    public static func build(plan: LiftExercisePlan, templateId: String?, templateName: String?,
                             history: [LiftHistorySession]) -> Result {
        let newestFirst = history.sorted { $0.start > $1.start }
        var chosen: (session: LiftHistorySession, sets: [LiftHistorySet], source: Source)?
        for session in newestFirst where session.ran(templateId: templateId, templateName: templateName) {
            let s = session.sets(of: plan.name)
            if !s.isEmpty { chosen = (session: session, sets: s, source: Source.sameTemplate(session.start)); break }
        }
        if chosen == nil {
            for session in newestFirst {
                let s = session.sets(of: plan.name)
                if !s.isEmpty { chosen = (session: session, sets: s, source: Source.sameExercise(session.start)); break }
            }
        }

        let pastWarm = chosen?.sets.filter { $0.isWarmup } ?? []
        let pastWork = chosen?.sets.filter { !$0.isWarmup } ?? []
        var warmIndex = 0, workIndex = 0
        let rows = plan.sets.map { planned -> LiftLoggedSet in
            let pool = planned.kind.isWarmup ? pastWarm : pastWork
            let i = planned.kind.isWarmup ? warmIndex : workIndex
            if planned.kind.isWarmup { warmIndex += 1 } else { workIndex += 1 }
            let past: LiftHistorySet? = i < pool.count ? pool[i] : pool.last
            if let past {
                return LiftLoggedSet(id: planned.id, kind: planned.kind, weightKg: past.weightKg,
                                     reps: past.reps ?? plan.targetReps, prefilled: true)
            }
            return LiftLoggedSet(id: planned.id, kind: planned.kind, weightKg: nil,
                                 reps: planned.kind.isWarmup ? nil : plan.targetReps, prefilled: false)
        }
        return Result(sets: rows, source: chosen?.source ?? .none, lastTime: chosen?.sets ?? [],
                      lastTimeTitle: chosen?.session.title)
    }

    /// Every weight this wearer has used on an exercise, for `LiftIncrement`. Warm-ups included: they are
    /// real settings of the same machine and reveal its step as well as any work set.
    public static func weightsUsed(exercise: String, history: [LiftHistorySession]) -> [Double] {
        history.flatMap { $0.sets(of: exercise) }.compactMap(\.weightKg)
    }
}

// MARK: - Progression proposal

/// The per-exercise proposal shown before the first working set. A SUGGESTION, never applied to the rows.
///
/// THE PROGRESSION ITSELF IS `StrengthProgression`'s (StrandImport): double progression — a rep within the
/// range, then one observed increment. The app converts its `Exercise` into `Input`; this type only adds the
/// two things decision 16 layers on top, in this order:
///   1. STALLED → a deload: about 90 % of the stuck weight — the point of the wearer's own step grid (anchored
///      at the stuck weight, so a machine stack stays reachable) nearest to 90 %, at least one step down — same
///      reps. Without an observed step there is no honest number, so the deload is proposed without one.
///   2. EASY WEEK (week plan `holdLoads`) or a LOW-CHARGE day → hold: last time's top set, unchanged.
///   3. Otherwise → StrengthProgression's suggestion, or nothing with the reason it has none.
public enum LiftProposal {

    public static let deloadFraction = 0.9

    public struct Input: Equatable, Sendable {
        public enum Step: Equatable, Sendable { case addReps, addWeight }
        /// Nil when StrengthProgression made no suggestion (range exhausted and no increment).
        public var step: Step?
        public var weightKg: Double?
        public var reps: Int?
        public var incrementKg: Double?
        /// Last session's top set.
        public var fromWeightKg: Double?
        public var fromReps: Int?
        /// Sessions with a usable estimate vs the minimum, when StrengthProgression abstained
        /// (`.tooFewSessions(have:need:)`). Both set, or both nil.
        public var tooFewHave: Int?
        public var tooFewNeed: Int?
        public var stalledSessions: Int?
        public var stalledDays: Int?
        public var stuckAtKg: Double?

        public init(step: Step?, weightKg: Double?, reps: Int?, incrementKg: Double?,
                    fromWeightKg: Double?, fromReps: Int?, tooFewHave: Int? = nil, tooFewNeed: Int? = nil,
                    stalledSessions: Int? = nil, stalledDays: Int? = nil, stuckAtKg: Double? = nil) {
            self.step = step
            self.weightKg = weightKg
            self.reps = reps
            self.incrementKg = incrementKg
            self.fromWeightKg = fromWeightKg
            self.fromReps = fromReps
            self.tooFewHave = tooFewHave
            self.tooFewNeed = tooFewNeed
            self.stalledSessions = stalledSessions
            self.stalledDays = stalledDays
            self.stuckAtKg = stuckAtKg
        }
    }

    public enum Kind: Equatable, Sendable { case progress, hold, deload, none }

    public enum Reason: Equatable, Sendable {
        case addReps
        case addWeight(incrementKg: Double)
        case easyWeek
        case lowCharge(Double)
        case stalled(sessions: Int, days: Int)
        case tooFewSessions(have: Int, need: Int)
        /// Top of the range reached, and no observed step to add.
        case noIncrement
        case noHistory
    }

    public struct Result: Equatable, Sendable {
        public var kind: Kind
        public var weightKg: Double?
        public var reps: Int?
        public var reasons: [Reason]

        public init(kind: Kind, weightKg: Double?, reps: Int?, reasons: [Reason]) {
            self.kind = kind
            self.weightKg = weightKg
            self.reps = reps
            self.reasons = reasons
        }
    }

    public static func make(input: Input?, holdLoads: Bool, charge: Double?,
                            lowChargeThreshold: Double, stepKg: Double?) -> Result {
        guard let input else { return Result(kind: .none, weightKg: nil, reps: nil, reasons: [.noHistory]) }
        if let have = input.tooFewHave, let need = input.tooFewNeed {
            return Result(kind: .none, weightKg: nil, reps: nil,
                          reasons: [.tooFewSessions(have: have, need: need)])
        }
        if let sessions = input.stalledSessions, let days = input.stalledDays {
            let stuck = input.stuckAtKg ?? input.fromWeightKg
            var weight: Double?
            if let stuck, let step = stepKg ?? input.incrementKg, step > 0 {
                let target = stuck * deloadFraction
                let steps = max(1, Int(((stuck - target) / step).rounded()))
                let w = LiftIncrement.round2(stuck - Double(steps) * step)
                weight = w > 0 ? w : nil
            }
            return Result(kind: .deload, weightKg: weight, reps: input.fromReps,
                          reasons: [.stalled(sessions: sessions, days: days)])
        }
        var holdReasons: [Reason] = []
        if holdLoads { holdReasons.append(.easyWeek) }
        if let charge, charge < lowChargeThreshold { holdReasons.append(.lowCharge(charge)) }
        if !holdReasons.isEmpty {
            return Result(kind: .hold, weightKg: input.fromWeightKg, reps: input.fromReps, reasons: holdReasons)
        }
        switch input.step {
        case .addReps?:
            return Result(kind: .progress, weightKg: input.weightKg, reps: input.reps, reasons: [.addReps])
        case .addWeight?:
            return Result(kind: .progress, weightKg: input.weightKg, reps: input.reps,
                          reasons: [.addWeight(incrementKg: input.incrementKg ?? 0)])
        case nil:
            return Result(kind: .none, weightKg: nil, reps: nil,
                          reasons: [input.fromWeightKg == nil ? .noHistory : .noIncrement])
        }
    }
}
