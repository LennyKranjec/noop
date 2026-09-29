import Foundation

// WeekReview.swift — the Monday review that closes the loop (HEALTH_V2 S3 §3.6).
//
// Self-monitoring combined with goal review is one of the more consistent active ingredients in
// physical-activity behaviour change (Michie 2009). The review is one pure struct, rendered two ways:
//   * the SCREEN shows its deterministic content, always;
//   * the COACH narrates the same struct (`coachBlock(maxChars:)`), so it never invents a figure and the
//     review works with no API key.
//
// RULES (each has a test):
//   * Plan vs done per component: `met` (≥ 90 %), `partly` (50–90 %), `missed` (< 50 %), `notMeasured`,
//     or `notAsked`. Days whose guidance was easy or rest are taken OUT of the denominator — a shortfall
//     the plan itself asked for is never a miss.
//   * A shortfall that the data cannot see (sessions without heart rate, a lift log not re-imported, too
//     few worn days) is `notMeasured`, not `missed`.
//   * VO₂max appears only as a MONTHLY MEDIAN with its ±5 ml/kg/min band, only when two consecutive months
//     each have ≥ 2 session-based (run/walk) estimates — never the Uth HR-ratio fallback, and NEVER as a
//     target (its error is larger than a year of realistic change).
//   * EXACTLY ONE suggestion, first matching rule wins (missed target → wake regularity → sleep debt →
//     keep the plan).
//   * No push notification: the review appears on the card when the app is next opened on Monday.
//
// Pure, deterministic, DB-free. Swift-only engine.

// MARK: - Plan vs done

public enum WeekComponent: String, Codable, Equatable, Sendable {
    case aerobic, strength, steps
}

public enum ComponentStatus: String, Codable, Equatable, Sendable {
    case met, partly, missed, notMeasured, notAsked
}

public struct ComponentResult: Codable, Equatable, Sendable {
    public let component: WeekComponent
    /// The plan's target for the whole week (aerobic min, strength sessions, steps/day).
    public let planned: Double?
    /// The target after easy/rest days were taken out of the denominator.
    public let effectiveTarget: Double?
    public let done: Double?
    public let status: ComponentStatus
    /// Why it is `notMeasured` / `notAsked`, when it is.
    public let note: String?
}

// MARK: - Trends and VO₂max

/// Plain numbers for the trend lines. Every field optional; a nil line renders "—" plus its reason.
public struct WeekTrendInputs: Equatable, Sendable {
    public let hrv: HRVReadinessResult?
    public let rhrWeekMean: Double?
    public let rhr4WeekMean: Double?
    public let sleepWeekMeanMin: Double?
    public let sleepNeedMin: Double?
    /// SD of wake time over the week (S2 `SleepRegularity.wakeSdMin`).
    public let wakeSdMin: Double?
    /// The wearer's usual wake time, minutes past midnight (S2 anchor or median wake).
    public let typicalWakeMinute: Int?
    public let sleepDebtMin: Double?
    /// S2's bedtime target, minutes past midnight.
    public let bedtimeTargetMinute: Int?

    public init(hrv: HRVReadinessResult? = nil, rhrWeekMean: Double? = nil, rhr4WeekMean: Double? = nil,
                sleepWeekMeanMin: Double? = nil, sleepNeedMin: Double? = nil, wakeSdMin: Double? = nil,
                typicalWakeMinute: Int? = nil, sleepDebtMin: Double? = nil, bedtimeTargetMinute: Int? = nil) {
        self.hrv = hrv
        self.rhrWeekMean = rhrWeekMean
        self.rhr4WeekMean = rhr4WeekMean
        self.sleepWeekMeanMin = sleepWeekMeanMin
        self.sleepNeedMin = sleepNeedMin
        self.wakeSdMin = wakeSdMin
        self.typicalWakeMinute = typicalWakeMinute
        self.sleepDebtMin = sleepDebtMin
        self.bedtimeTargetMinute = bedtimeTargetMinute
    }
}

/// One VO₂max estimate with its provenance.
public struct VO2SessionEstimate: Equatable, Sendable {
    public let day: String
    public let vo2max: Double
    /// True for the session method (`VO2MaxEstimator.fromSession`, run/walk speed vs HRR); false for the
    /// Uth HR-ratio fallback and the activity model, which the month rule excludes.
    public let sessionBased: Bool

    public init(day: String, vo2max: Double, sessionBased: Bool) {
        self.day = day
        self.vo2max = vo2max
        self.sessionBased = sessionBased
    }
}

public struct VO2MonthlyTrend: Equatable, Sendable {
    /// `yyyy-MM`.
    public let previousMonth: String
    public let previousMedian: Double
    public let previousSessions: Int
    public let month: String
    public let median: Double
    public let sessions: Int
    /// ± band (the estimator's standard error, ml/kg/min).
    public let band: Double
}

public enum VO2Abstention: String, Equatable, Sendable {
    /// Fewer than two consecutive months with ≥ 2 session-based estimates.
    case tooFewSessions
}

// MARK: - Suggestion

public struct WeekSuggestion: Equatable, Sendable {
    public enum Rule: String, Equatable, Sendable {
        case missedStrength, missedAerobic, wakeRegularity, sleepDebt, keepPlan
    }
    public let rule: Rule
    public let text: String
}

// MARK: - The review

public struct WeekReview: Equatable, Sendable {
    public let weekStart: String
    public let weekEnd: String
    public let weekType: WeekType
    public let components: [ComponentResult]
    public let trendLines: [String]
    public let vo2: VO2MonthlyTrend?
    public let vo2Abstention: VO2Abstention?
    public let suggestion: WeekSuggestion
    public let trialStatus: String?

    // MARK: Constants

    public static let metRatio: Double = 0.90
    public static let partlyRatio: Double = 0.50
    /// Fewer than 4 worn days in a week cannot tell "did not train" from "did not wear".
    public static let minObservedDays: Int = 4
    /// A day counts as observed at ≥ 50 % wear.
    public static let observedWear: Double = 0.5
    /// VO₂max band: the estimator's SEE ≈ 5 ml/kg/min.
    public static let vo2Band: Double = 5
    public static let vo2MinSessionsPerMonth: Int = 2
    /// Wake-time SD above 45 min is irregular enough to be the week's one suggestion (the regularity
    /// evidence, Windred 2024, is about day-to-day consistency; 45 min is well past normal jitter).
    public static let wakeSdSuggestMin: Double = 45
    /// Sleep debt at/above 2 h makes an earlier bedtime the suggestion.
    public static let sleepDebtSuggestMin: Double = 120
    /// A weekday "worked for you before" when it carried at least this many past sessions.
    public static let preferredWeekdayMinCount: Int = 2

    // MARK: Plan vs done

    static func status(ratio: Double) -> ComponentStatus {
        if ratio >= metRatio { return .met }
        if ratio >= partlyRatio { return .partly }
        return .missed
    }

    /// Plan vs done for one frozen week.
    ///
    /// - Parameters:
    ///   - guidanceByDay: the guidance each day actually got. A day missing from the map counts as planned.
    ///   - liftDataFresh: the lift log has been imported since the week ended (or there is none to import).
    ///     When false, a strength shortfall is `notMeasured`, not `missed`.
    public static func planVsDone(plan: WeekPlan, days: [DayActivity], guidanceByDay: [String: DayGuidance.Kind],
                                  liftDataFresh: Bool) -> [ComponentResult] {
        let byDay = WeekPlanEngine.index(days)
        let week = WeekPlanEngine.weekDays(plan.weekStart)
        let planned = week.filter { d in
            guard let k = guidanceByDay[d] else { return true }
            return k != .easy && k != .rest
        }
        let fraction = Double(planned.count) / 7.0
        let acts = week.compactMap { byDay[$0] }
        let observed = acts.filter { ($0.wearCoverage ?? 0) >= observedWear || ($0.mvpaEq ?? 0) > 0 }.count
        let unmeasured = acts.reduce(0) { $0 + $1.unmeasuredSessions }

        var out: [ComponentResult] = []

        // Aerobic.
        if let target = plan.aerobicTarget {
            let eff = target * fraction
            let done = acts.reduce(0) { $0 + ($1.mvpaEq ?? 0) }
            if eff <= 0 {
                out.append(ComponentResult(component: .aerobic, planned: target, effectiveTarget: eff, done: done,
                                           status: .notAsked, note: "Every day this week was easy or rest."))
            } else if observed < minObservedDays {
                out.append(ComponentResult(component: .aerobic, planned: target, effectiveTarget: eff, done: done,
                                           status: .notMeasured,
                                           note: "The strap was worn on \(observed) of 7 days."))
            } else {
                var st = status(ratio: done / eff)
                var note: String? = nil
                if st != .met && unmeasured > 0 {
                    st = .notMeasured
                    note = "\(unmeasured) session\(unmeasured == 1 ? "" : "s") without heart rate."
                }
                out.append(ComponentResult(component: .aerobic, planned: target, effectiveTarget: eff, done: done,
                                           status: st, note: note))
            }
        } else {
            out.append(ComponentResult(component: .aerobic, planned: nil, effectiveTarget: nil, done: nil,
                                       status: .notAsked, note: "No personal target while the baseline builds."))
        }

        // Strength.
        let sTarget = Double(plan.strength.minSessions)
        let sEff = sTarget * fraction
        let sDone = Double(acts.filter { $0.strengthSession == true }.count)
        if sEff <= 0 {
            out.append(ComponentResult(component: .strength, planned: sTarget, effectiveTarget: sEff, done: sDone,
                                       status: .notAsked, note: nil))
        } else {
            var st = status(ratio: sDone / sEff)
            var note: String? = nil
            if st != .met && !liftDataFresh {
                st = .notMeasured
                note = "The lift log has not been imported since the week ended."
            }
            out.append(ComponentResult(component: .strength, planned: sTarget, effectiveTarget: sEff, done: sDone,
                                       status: st, note: note))
        }

        // Steps (per day; only planned days with a reliable total).
        if let target = plan.stepsTarget {
            let xs = planned.compactMap { d -> Double? in
                guard let a = byDay[d], a.stepsReliable else { return nil }
                return a.steps
            }
            if planned.isEmpty {
                out.append(ComponentResult(component: .steps, planned: target, effectiveTarget: target, done: nil,
                                           status: .notAsked, note: "Every day this week was easy or rest."))
            } else if xs.count < minObservedDays {
                out.append(ComponentResult(component: .steps, planned: target, effectiveTarget: target, done: nil,
                                           status: .notMeasured,
                                           note: "Reliable step totals on \(xs.count) days only."))
            } else {
                let mean = xs.reduce(0, +) / Double(xs.count)
                out.append(ComponentResult(component: .steps, planned: target, effectiveTarget: target, done: mean,
                                           status: status(ratio: mean / target), note: nil))
            }
        } else {
            out.append(ComponentResult(component: .steps, planned: nil, effectiveTarget: nil, done: nil,
                                       status: .notAsked, note: "Steps are not calibrated, so there is no step target."))
        }
        return out
    }

    // MARK: VO₂max

    /// `yyyy-MM` of a day.
    static func month(_ day: String) -> String { String(day.prefix(7)) }

    static func previousMonth(_ ym: String) -> String {
        let p = ym.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return ym }
        let (y, m) = p[1] == 1 ? (p[0] - 1, 12) : (p[0], p[1] - 1)
        return String(format: "%04d-%02d", y, m)
    }

    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// The most recent pair of consecutive months (this month and last, else the two before) in which
    /// each month has ≥ 2 session-based estimates.
    public static func vo2Trend(_ estimates: [VO2SessionEstimate], asOf: String) -> (VO2MonthlyTrend?, VO2Abstention?) {
        var byMonth: [String: [Double]] = [:]
        for e in estimates where e.sessionBased && e.day <= asOf && e.vo2max.isFinite {
            byMonth[month(e.day), default: []].append(e.vo2max)
        }
        let m0 = month(asOf)
        let m1 = previousMonth(m0)
        let m2 = previousMonth(m1)
        for (cur, prev) in [(m0, m1), (m1, m2)] {
            let a = byMonth[prev] ?? [], b = byMonth[cur] ?? []
            guard a.count >= vo2MinSessionsPerMonth, b.count >= vo2MinSessionsPerMonth,
                  let ma = median(a), let mb = median(b) else { continue }
            return (VO2MonthlyTrend(previousMonth: prev, previousMedian: ma, previousSessions: a.count,
                                    month: cur, median: mb, sessions: b.count, band: vo2Band), nil)
        }
        return (nil, .tooFewSessions)
    }

    public static func vo2Line(_ trend: VO2MonthlyTrend?, _ abstention: VO2Abstention?) -> String {
        guard let t = trend else {
            return "VO₂max — needs 2 runs or brisk walks with heart rate in each of two consecutive months"
        }
        let a = Int(t.previousMedian.rounded()), b = Int(t.median.rounded())
        let qualifier = abs(t.median - t.previousMedian) < t.band
            ? "a change smaller than the estimate's error"
            : "a change larger than the estimate's error"
        return "VO₂max (estimate, run/walk method) \(t.previousMonth): \(a) ± \(Int(t.band)) · \(t.month): \(b) ± "
            + "\(Int(t.band)) ml/kg/min — \(qualifier). Not a target."
    }

    // MARK: Trends

    public static func makeTrendLines(_ t: WeekTrendInputs) -> [String] {
        var out: [String] = []
        if let h = t.hrv {
            let where_: String
            switch h.tier {
            case .primed: where_ = "above"
            case .normal: where_ = "inside"
            case .suppressed: where_ = "below"
            }
            out.append("HRV 7-day \(Int(h.baseline7Ms.rounded())) ms — \(where_) your normal range "
                + "(\(Int(h.normalLowMs.rounded()))–\(Int(h.normalHighMs.rounded())) ms)")
        } else {
            out.append("HRV 7-day — not enough nights yet (\(HRVReadiness.minNights) needed)")
        }
        if let w = t.rhrWeekMean, let m = t.rhr4WeekMean {
            let d = Int((w - m).rounded())
            out.append("Resting HR \(Int(w.rounded())) bpm — \(d >= 0 ? "+" : "−")\(abs(d)) vs your 4-week mean")
        } else {
            out.append("Resting HR — not enough nights this week")
        }
        if let s = t.sleepWeekMeanMin, let n = t.sleepNeedMin, n > 0 {
            out.append("Sleep \(hm(s)) a night vs a need of \(hm(n))")
        } else {
            out.append("Sleep — no night recorded")
        }
        if let sd = t.wakeSdMin {
            out.append("Wake time varied by ±\(Int(sd.rounded())) min")
        } else {
            out.append("Wake time — regularity not available yet")
        }
        return out
    }

    static func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60) h \(m % 60) m"
    }

    static func clock(_ minute: Int) -> String {
        let w = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", w / 60, w % 60)
    }

    // MARK: Suggestion

    static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The weekdays (0 = Sunday) on which `days` matching `predicate` happened at least twice, most
    /// frequent first (ties: Monday-first order), at most `limit`.
    public static func preferredWeekdays(_ days: [DayActivity], limit: Int = 2,
                                         where predicate: (DayActivity) -> Bool) -> [Int] {
        var counts = [Int](repeating: 0, count: 7)
        for d in days where predicate(d) {
            guard let (y, m, dd) = WeeklyDigestEngine.parseYMD(d.day),
                  let w = WeeklyDigestEngine.weekday(y, m, dd) else { continue }
            counts[w] += 1
        }
        // Position in a Monday-first week (0 = Monday … 6 = Sunday).
        func pos(_ w: Int) -> Int { (w + 6) % 7 }
        let candidates = (0..<7).filter { counts[$0] >= preferredWeekdayMinCount }
        let ranked = candidates.sorted { a, b in
            if counts[a] != counts[b] { return counts[a] > counts[b] }
            return pos(a) < pos(b)
        }
        let top = Array(ranked.prefix(limit))
        // Present in calendar order.
        return top.sorted { a, b in pos(a) < pos(b) }
    }

    static func dayList(_ ws: [Int]) -> String {
        let names = ws.map { weekdayNames[$0] }
        if names.count <= 1 { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    /// Exactly one suggestion. First matching rule wins.
    public static func makeSuggestion(components: [ComponentResult], plan: WeekPlan, history: [DayActivity],
                                      trends: WeekTrendInputs) -> WeekSuggestion {
        if let s = components.first(where: { $0.component == .strength }), s.status == .missed {
            let n = max(1, plan.strength.minSessions)
            let noun = n == 1 ? "strength session" : "strength sessions"
            let ws = preferredWeekdays(history) { $0.strengthSession == true }
            let text = ws.count >= min(n, 2)
                ? "Put \(n) \(noun) in the calendar — \(dayList(ws)) worked for you before"
                : "Put \(n) \(noun) in the calendar this week"
            return WeekSuggestion(rule: .missedStrength, text: text)
        }
        if let a = components.first(where: { $0.component == .aerobic }), a.status == .missed {
            let ws = preferredWeekdays(history) { ($0.mvpaEq ?? 0) >= 20 }
            let text = ws.isEmpty
                ? "Put your aerobic sessions in the calendar this week"
                : "Put your aerobic sessions in the calendar — \(dayList(ws)) worked for you before"
            return WeekSuggestion(rule: .missedAerobic, text: text)
        }
        if let sd = trends.wakeSdMin, sd > wakeSdSuggestMin {
            let text = trends.typicalWakeMinute.map { "Keep wake time within 30 min of \(clock($0))" }
                ?? "Keep wake time within 30 min of your usual time"
            return WeekSuggestion(rule: .wakeRegularity, text: text)
        }
        if let debt = trends.sleepDebtMin, debt >= sleepDebtSuggestMin {
            let text = trends.bedtimeTargetMinute.map { "Bedtime \(clock($0)) this week" }
                ?? "An earlier, regular bedtime this week — about \(Int((debt / 60).rounded())) h of sleep debt"
            return WeekSuggestion(rule: .sleepDebt, text: text)
        }
        return WeekSuggestion(rule: .keepPlan, text: "Keep the same plan")
    }

    // MARK: Build

    /// The review of `plan`'s week.
    ///
    /// - Parameters:
    ///   - days: activity covering the reviewed week and the history used for preferred weekdays.
    ///   - vo2Estimates: VO₂max estimates with provenance (the session method is the only one counted).
    ///   - trialStatus: S1's one-line trial status, nil when no trial is running or finished recently.
    public static func build(plan: WeekPlan, days: [DayActivity], guidanceByDay: [String: DayGuidance.Kind],
                             liftDataFresh: Bool, trends: WeekTrendInputs, vo2Estimates: [VO2SessionEstimate],
                             trialStatus: String?) -> WeekReview {
        let comps = planVsDone(plan: plan, days: days, guidanceByDay: guidanceByDay, liftDataFresh: liftDataFresh)
        let (vo2, why) = vo2Trend(vo2Estimates, asOf: plan.weekEnd)
        let history = days.filter { $0.day <= plan.weekEnd }
        return WeekReview(weekStart: plan.weekStart, weekEnd: plan.weekEnd, weekType: plan.type, components: comps,
                          trendLines: makeTrendLines(trends), vo2: vo2, vo2Abstention: why,
                          suggestion: makeSuggestion(components: comps, plan: plan, history: history, trends: trends),
                          trialStatus: trialStatus)
    }

    // MARK: Rendering

    public static func componentLine(_ c: ComponentResult) -> String {
        let name: String
        switch c.component {
        case .aerobic: name = "Aerobic"
        case .strength: name = "Strength"
        case .steps: name = "Steps"
        }
        let statusWord: String
        switch c.status {
        case .met: statusWord = "met"
        case .partly: statusWord = "partly"
        case .missed: statusWord = "missed"
        case .notMeasured: statusWord = "not measured"
        case .notAsked: statusWord = "no target"
        }
        let figures: String
        switch c.component {
        case .aerobic:
            let done = c.done.map { String(Int($0.rounded())) } ?? "—"
            let eff = c.effectiveTarget.map { String(Int($0.rounded())) } ?? "—"
            figures = "\(done) / \(eff) min"
        case .strength:
            let done = c.done.map { String(Int($0)) } ?? "—"
            let eff = c.effectiveTarget.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "—"
            figures = "\(done) / \(eff) sessions"
        case .steps:
            let done = c.done.map { String(Int($0.rounded())) } ?? "—"
            let eff = c.effectiveTarget.map { String(Int($0.rounded())) } ?? "—"
            figures = "\(done) / \(eff) a day"
        }
        var line = "\(name) \(figures) (\(statusWord))"
        if let note = c.note { line += " — " + note }
        return line
    }

    /// The coach's week block: dated, fixed layout, priority-truncated — whole lines are dropped from the
    /// bottom and a line is never cut. Always ≤ `maxChars` (empty when not even the header fits).
    public func coachBlock(maxChars: Int = 500) -> String {
        var lines: [String] = []
        lines.append("WEEK REVIEW \(weekStart)..\(weekEnd) (\(weekType.rawValue) week)")
        lines.append("Suggestion: \(suggestion.text)")
        lines.append(contentsOf: components.map(Self.componentLine))
        if let trialStatus { lines.append("Trial: \(trialStatus)") }
        lines.append(contentsOf: trendLines)
        lines.append(Self.vo2Line(vo2, vo2Abstention))
        var out = ""
        for line in lines {
            let candidate = out.isEmpty ? line : out + "\n" + line
            if candidate.count > maxChars { break }
            out = candidate
        }
        return out
    }
}
