import Foundation

// GoalModel.swift — goals and their honest feasibility verdict (DESIGN_V2 coordinator decision 14).
//
// A goal is a target VALUE for one metric (the Level or a part, resting HR, HRV, VO₂max, weekly aerobic
// minutes, steps, an e1RM per lift, wake-time spread, meditation minutes) on a target DATE, optionally
// from a start date. Goals are aspirations: they never alter a measured value, never touch the Level
// (which stays unbounded — a Level goal of 140 is allowed and judged on the same rules), and a missed
// date produces an honest REVIEW, never a penalty (the penalty system stays on daily quests).
//
// THE VERDICT compares the REQUIRED weekly rate with (a) the wearer's own current-trend projection band
// at the date and (b) a documented plausible rate (`PlausibleRates`, each with its basis):
//
//   reached                  the latest reading already meets the target (→ a full-screen moment);
//   date passed              the date is behind us → review (how far it moved, what is left), no penalty;
//   on track                 the projection's CENTRE at the date meets the target;
//   ambitious but plausible  the centre does not, but the band's favourable edge does, or the required
//                            rate is within the plausible rate (with the wearer's own projection present);
//   unrealistic at this date the required rate exceeds the plausible rate and the band's favourable edge
//                            misses too — with a REALISTIC DATE (at the plausible rate) and a REALISTIC
//                            VALUE by the chosen date;
//   can't judge yet          no current reading, or neither a projection nor a plausible rate exists, or
//                            the required rate is within the plausible rate but there is no own trend yet
//                            (the count of weeks still needed is given).
//
// EVERY VERDICT CARRIES ITS NUMBERS: current (with its week), target, weeks left, required weekly change,
// the projected range at the date (or why there is none) and the plausible rate with its basis.
//
// Pure, Codable, `yyyy-MM-dd` strings. Swift-only engine.

public enum GoalDirection: String, Codable, Equatable, Sendable {
    case increase, decrease
    public var sign: Double { self == .increase ? 1 : -1 }
}

public struct Goal: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var metric: ProjectionMetricID
    public var target: Double
    /// `yyyy-MM-dd`.
    public var targetDate: String
    /// Optional start (`yyyy-MM-dd`); defaults to the creation day.
    public var startDate: String?
    public let createdOn: String
    /// The reading when the goal was set (the review measures progress from it). nil if none existed.
    public var startValue: Double?
    public var direction: GoalDirection
    /// Set once, when the goal was first seen reached (fire-once guard for the moment).
    public var reachedOn: String?
    /// Set once the passed-date review has been shown.
    public var reviewedOn: String?
    public var archived: Bool

    public init(id: String, metric: ProjectionMetricID, target: Double, targetDate: String, startDate: String? = nil,
                createdOn: String, startValue: Double?, direction: GoalDirection, reachedOn: String? = nil,
                reviewedOn: String? = nil, archived: Bool = false) {
        self.id = id
        self.metric = metric
        self.target = target
        self.targetDate = targetDate
        self.startDate = startDate
        self.createdOn = createdOn
        self.startValue = startValue
        self.direction = direction
        self.reachedOn = reachedOn
        self.reviewedOn = reviewedOn
        self.archived = archived
    }

    /// Direction from the current reading when known, else from the metric's healthy direction.
    public static func direction(metric: ProjectionMetricID, current: Double?, target: Double) -> GoalDirection {
        if let c = current, c != target { return target > c ? .increase : .decrease }
        return metric.lowerIsBetter ? .decrease : .increase
    }

    public var effectiveStart: String { startDate ?? createdOn }

    /// Tolerant decoding: fields added later are absent from older files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metric = try c.decode(ProjectionMetricID.self, forKey: .metric)
        target = try c.decode(Double.self, forKey: .target)
        targetDate = try c.decode(String.self, forKey: .targetDate)
        startDate = try c.decodeIfPresent(String.self, forKey: .startDate)
        createdOn = try c.decode(String.self, forKey: .createdOn)
        startValue = try c.decodeIfPresent(Double.self, forKey: .startValue)
        direction = try c.decodeIfPresent(GoalDirection.self, forKey: .direction)
            ?? (metric.lowerIsBetter ? .decrease : .increase)
        reachedOn = try c.decodeIfPresent(String.self, forKey: .reachedOn)
        reviewedOn = try c.decodeIfPresent(String.self, forKey: .reviewedOn)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

public enum GoalVerdict: String, Codable, Equatable, Sendable {
    case reached
    case datePassed
    case onTrack
    case ambitiousButPlausible
    case unrealistic
    case cantJudgeYet

    public var title: String {
        switch self {
        case .reached: return "Reached"
        case .datePassed: return "Date passed — review"
        case .onTrack: return "On track"
        case .ambitiousButPlausible: return "Ambitious but plausible"
        case .unrealistic: return "Unrealistic at this date"
        case .cantJudgeYet: return "Can't judge yet"
        }
    }
}

/// The review of a goal whose date passed. Never a penalty.
public struct GoalReview: Equatable, Sendable {
    public let startValue: Double?
    public let finalValue: Double?
    public let target: Double
    /// Share of the way from start to target covered (can exceed 1 or be negative). nil without both ends.
    public let fractionCovered: Double?
    public let text: String
}

public struct GoalAssessment: Equatable, Sendable {
    public let goal: Goal
    public let verdict: GoalVerdict
    public let current: Double?
    /// Monday of the week the current reading belongs to.
    public let currentWeek: String?
    public let weeksLeft: Double
    /// Signed change per week still needed (nil without a current reading or with no time left).
    public let requiredPerWeek: Double?
    /// The current-trend band at the target date (nil: abstained or beyond the informative horizon).
    public let projectedAtDate: ProjectionBand?
    /// Why there is no band at the date, when there is none.
    public let noBandReason: String?
    public let plausible: PlausibleRate?
    /// Plausible weekly change at the current value, in the goal's direction (nil: unlimited / unknown).
    public let plausiblePerWeek: Double?
    public let realisticDate: String?
    public let realisticValue: Double?
    public let review: GoalReview?
    /// Extra honest notes (e.g. VO₂max change smaller than the estimate's error).
    public let caveats: [String]

    /// The reasoning numbers in one line — shown under every verdict and sent to the coach.
    public var numbersLine: String {
        let m = goal.metric
        var parts: [String] = []
        parts.append("now " + (current.map { m.formatWithUnit($0) } ?? "\u{2014}"))
        parts.append("target " + m.formatWithUnit(goal.target) + " by " + goal.targetDate)
        if let r = requiredPerWeek { parts.append("needs " + m.formatRate(r)) }
        if let b = projectedAtDate {
            parts.append("projected " + m.format(b.low) + "–" + m.format(b.high) + " at the date")
        } else if let why = noBandReason {
            parts.append("no projection at the date (" + why + ")")
        }
        if let p = plausiblePerWeek { parts.append("plausible up to " + m.formatRate(goal.direction.sign * p)) }
        return parts.joined(separator: " · ")
    }

    /// The verdict sentence.
    public var verdictLine: String {
        let m = goal.metric
        switch verdict {
        case .reached:
            return "Reached — " + (current.map { m.formatWithUnit($0) } ?? "") + " against a target of "
                + m.formatWithUnit(goal.target) + "."
        case .datePassed:
            return review?.text ?? "The date has passed."
        case .onTrack:
            return "On track: the projection on your current trend reaches the target by the date."
        case .ambitiousButPlausible:
            return "Ambitious but plausible: your current trend falls short, but the change needed is within "
                + "what is documented as achievable."
        case .unrealistic:
            var s = "Unrealistic at this date."
            if let d = realisticDate { s += " A realistic date: \(d)." }
            if let v = realisticValue { s += " A realistic value by \(goal.targetDate): \(m.formatWithUnit(v))." }
            return s
        case .cantJudgeYet:
            return "Can't judge yet — " + (noBandReason ?? "too little history") + "."
        }
    }
}

public enum GoalFeasibility {

    /// Assess one goal.
    /// - current: the latest weekly reading of the metric (nil = none).
    /// - trend: the current-trend projection (or its abstention).
    /// - plausible: the documented plausible rate in the goal's direction (nil = none can be stated).
    /// - today: the local day.
    /// - finalValue: for a passed date, the reading of the target week (nil → the latest reading is used).
    public static func assess(goal: Goal, current: WeeklyValue?, trend: MetricTrend?, plausible: PlausibleRate?,
                              today: String, finalValue: Double? = nil) -> GoalAssessment {
        let m = goal.metric
        let dir = goal.direction.sign
        let weeksLeft = ProjectionEngine.weeksBetween(today, goal.targetDate) ?? 0
        var caveats: [String] = []
        if let e = m.measurementError, let c = current?.value, abs(goal.target - c) < e {
            caveats.append("The change asked for is smaller than the estimate's own error (±\(Int(e)) "
                + m.unit + "): reaching it could not be confirmed by this estimate.")
        }

        func make(_ v: GoalVerdict, required: Double? = nil, band: ProjectionBand? = nil, noBand: String? = nil,
                  pPerWeek: Double? = nil, rDate: String? = nil, rValue: Double? = nil,
                  review: GoalReview? = nil) -> GoalAssessment {
            GoalAssessment(goal: goal, verdict: v, current: current?.value, currentWeek: current?.weekStart,
                           weeksLeft: weeksLeft, requiredPerWeek: required, projectedAtDate: band,
                           noBandReason: noBand, plausible: plausible, plausiblePerWeek: pPerWeek,
                           realisticDate: rDate, realisticValue: rValue, review: review, caveats: caveats)
        }

        // Reached (checked before the date: reaching it on the last day is still reaching it).
        if let c = current?.value, dir * (c - goal.target) >= 0 {
            return make(.reached)
        }
        // Date passed: an honest review, never a penalty.
        if goal.targetDate < today {
            return make(.datePassed, review: review(goal: goal, finalValue: finalValue ?? current?.value))
        }
        guard let c = current?.value else {
            return make(.cantJudgeYet, noBand: "no current reading of this figure")
        }
        let gap = goal.target - c
        let required: Double? = weeksLeft > 0 ? gap / weeksLeft : nil
        let pPerWeek = plausible?.perWeek(at: c)

        // The projection band at the date.
        var band: ProjectionBand? = nil
        var noBand: String? = nil
        switch trend {
        case .some(.projected(let p)):
            band = p.band(onDay: goal.targetDate)
            if band == nil {
                noBand = "the date is beyond the \(p.horizonCap)-week horizon where the band stays informative"
            }
        case .some(.abstained(let a)):
            noBand = a.text.prefix(1).lowercased() + String(a.text.dropFirst())
        case .none:
            noBand = "no projection for this figure"
        }

        if let b = band {
            if dir * (b.center - goal.target) >= 0 {
                return make(.onTrack, required: required, band: b, pPerWeek: pPerWeek)
            }
            let edge = dir > 0 ? b.high : b.low
            let edgeReaches = dir * (edge - goal.target) >= 0
            let withinPlausible: Bool = {
                guard let p = plausible else { return false }
                if case .unlimited = p.rate { return true }
                guard let need = p.weeksNeeded(from: c, gap: gap) else { return false }
                return need <= weeksLeft
            }()
            if edgeReaches || withinPlausible {
                return make(.ambitiousButPlausible, required: required, band: b, pPerWeek: pPerWeek)
            }
            let r = realistic(goal: goal, current: c, gap: gap, weeksLeft: weeksLeft, plausible: plausible,
                              today: today, band: b, trend: trend)
            return make(.unrealistic, required: required, band: b, pPerWeek: pPerWeek, rDate: r.date, rValue: r.value)
        }

        // No band at the date: documented rates alone can still say "unrealistic"; they cannot say "on track".
        guard let p = plausible else {
            return make(.cantJudgeYet, required: required, noBand: noBand)
        }
        if case .unlimited = p.rate {
            return make(.cantJudgeYet, required: required, noBand: noBand)
        }
        if let need = p.weeksNeeded(from: c, gap: gap), need > weeksLeft {
            let r = realistic(goal: goal, current: c, gap: gap, weeksLeft: weeksLeft, plausible: p, today: today,
                              band: nil, trend: trend)
            return make(.unrealistic, required: required, noBand: noBand, pPerWeek: pPerWeek,
                        rDate: r.date, rValue: r.value)
        }
        return make(.cantJudgeYet, required: required,
                    noBand: (noBand ?? "no projection") + "; the change is within documented rates",
                    pPerWeek: pPerWeek)
    }

    /// A realistic date (at the plausible rate) and a realistic value by the chosen date. With no plausible
    /// rate, the value is the band's favourable edge and the date comes from a significant trend in the
    /// goal's direction (else nil — no date can honestly be given).
    static func realistic(goal: Goal, current c: Double, gap: Double, weeksLeft: Double, plausible: PlausibleRate?,
                          today: String, band: ProjectionBand?, trend: MetricTrend?)
        -> (date: String?, value: Double?) {
        let dir = goal.direction.sign
        if let p = plausible, let weeks = p.weeksNeeded(from: c, gap: gap) {
            let days = Int((weeks * 7).rounded(.up))
            let date = WeeklyDigestEngine.addDays(today, days)
            let value = p.reachable(from: c, weeks: max(0, weeksLeft), direction: dir)
            return (date, value)
        }
        let value = band.map { dir > 0 ? $0.high : $0.low }
        var date: String? = nil
        if let t = trend?.projection, t.fit.significant, dir * t.fit.slopePerWeek > 0 {
            let weeks = abs(gap) / abs(t.fit.slopePerWeek)
            date = WeeklyDigestEngine.addDays(today, Int((weeks * 7).rounded(.up)))
        }
        return (date, value)
    }

    /// The passed-date review: where it ended, how much of the way it moved, no penalty.
    public static func review(goal: Goal, finalValue: Double?) -> GoalReview {
        let m = goal.metric
        var fraction: Double? = nil
        if let s = goal.startValue, let f = finalValue, goal.target != s {
            fraction = (f - s) / (goal.target - s)
        }
        var text = "The date \(goal.targetDate) has passed. Target \(m.formatWithUnit(goal.target))"
        if let f = finalValue {
            text += "; the reading then was \(m.formatWithUnit(f))"
            let short = goal.direction.sign * (goal.target - f)
            if short > 0 { text += " — \(m.formatWithUnit(short)) short" }
        } else {
            text += "; there was no reading to compare"
        }
        text += "."
        if let fr = fraction, let s = goal.startValue {
            text += " From \(m.formatWithUnit(s)) you covered \(Int((fr * 100).rounded())) % of the way."
        }
        text += " No penalty — goals are aspirations. Set a new date, or change the target."
        return GoalReview(startValue: goal.startValue, finalValue: finalValue, target: goal.target,
                          fractionCovered: fraction, text: text)
    }
}
