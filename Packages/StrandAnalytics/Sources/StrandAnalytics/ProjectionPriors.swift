import Foundation

// ProjectionPriors.swift — the published numbers Look ahead and Goals may lean on, each with its source,
// and ONLY where the wearer's own data is not enough (DESIGN_V2 decisions 13 and 14).
//
// Two kinds of number live here:
//
// 1. TYPICAL RESPONSES (`ProjectionPrior`) for the "if you follow the plan" scenario: how a metric typically
//    moves when training dose rises. Always labelled "typical response, not yours yet", always with a
//    wide uncertainty (`relativeSD`), because individual responses to the same training vary enormously
//    (HERITAGE: Bouchard C et al. 1999, J Appl Physiol 87:1003–1008 — some people gain little or nothing).
//    Where the literature only reports a standardised effect (HRV: an SMD, not milliseconds) there is NO
//    prior: converting an SMD into this wearer's milliseconds would be an invented number.
//
// 2. PLAUSIBLE RATES (`PlausibleRate`) for the goal feasibility verdict: how fast a metric can realistically
//    change. Each one says what it is: a LITERATURE rate, the wearer's OWN fastest 4-week change, or a
//    PACING CONVENTION of this app (behaviour has no physiological speed limit, and we say so).
//    These are RATES, never ceilings on a value: nothing here bounds where a metric can end up.
//
// Per-week conversions of trial results are OURS (the trials report a total over a programme), and the
// comment beside each says which programme length was assumed.

// MARK: - Typical responses (plan scenario)

public struct ProjectionPrior: Equatable, Sendable {
    /// Change per week at the reference dose increase (units of the metric, or a fraction of the current
    /// value when `relative`).
    public let perWeekAtReference: Double
    /// The dose increase the rate refers to (aerobic: +150 WHO-equivalent min/week; strength: +2
    /// sessions/week). The effect scales linearly with the actual increase; a dose DECREASE applies no
    /// prior at all (the trials studied starting to train, not stopping).
    public let referenceDoseIncrease: Double
    public let relative: Bool
    /// SD of the effect as a fraction of it (individual response variability). Widens the band.
    public let relativeSD: Double
    /// Short source line shown in the detail view.
    public let citation: String
    /// What the app may say about it.
    public let statement: String

    public init(perWeekAtReference: Double, referenceDoseIncrease: Double, relative: Bool, relativeSD: Double,
                citation: String, statement: String) {
        self.perWeekAtReference = perWeekAtReference
        self.referenceDoseIncrease = referenceDoseIncrease
        self.relative = relative
        self.relativeSD = relativeSD
        self.citation = citation
        self.statement = statement
    }
}

/// Training age from the lift log (first logged session → now). The log may not hold older training, so
/// the app says "by your logged history".
public enum TrainingAge: String, Codable, Equatable, Sendable {
    case novice        // < 26 weeks logged
    case intermediate  // 26 – 104 weeks
    case advanced      // > 104 weeks

    public static func from(weeksLogged: Int) -> TrainingAge {
        if weeksLogged < 26 { return .novice }
        if weeksLogged <= 104 { return .intermediate }
        return .advanced
    }

    /// Typical e1RM gain per week while training ~2×/week (fraction of current e1RM). OUR per-week reading
    /// of ACSM 2009: strength gains of ~40 % in untrained vs ~16 % in trained people over programmes of
    /// 4 weeks to 2 years, i.e. early gains are fast and slow sharply with training age (Rhea MR et al.
    /// 2003, Med Sci Sports Exerc 35:456–464, same pattern in effect sizes by training status).
    public var typicalWeeklyGain: Double {
        switch self {
        case .novice: return 0.010
        case .intermediate: return 0.005
        case .advanced: return 0.0025
        }
    }
}

public enum ProjectionPriors {

    /// Reference aerobic dose increase: the WHO minimum (Bull 2020).
    public static let aerobicReference: Double = 150
    /// Reference strength dose increase: the WHO 2 sessions/week.
    public static let strengthReference: Double = 2

    /// VO₂max. Milanović Z, Sporiš G, Weston M 2015, Sports Med 45:1469–1481 (controlled trials, healthy
    /// adults 18–45): continuous endurance training +4.9 ml/kg/min vs control (95 % CL ±1.4); HIIT +5.5
    /// (±1.2). Spread over 12 weeks (our assumption of a typical programme) at +150 min/week: ≈ 0.4/week.
    /// relativeSD 0.6: HERITAGE's individual responses scatter about half the mean and more.
    public static let vo2max = ProjectionPrior(
        perWeekAtReference: 4.9 / 12, referenceDoseIncrease: aerobicReference, relative: false, relativeSD: 0.6,
        citation: "Milanović 2015, Sports Med (endurance training +4.9 ml/kg/min vs control)",
        statement: "Typical response, not yours yet: controlled trials of endurance training raised VO₂max by "
            + "about 5 ml/kg/min on average, with large differences between people.")

    /// Resting HR. Reimers AK, Knapp G, Reimers CD 2018, J Clin Med 7:503 (191 studies): endurance training
    /// lowered resting HR by ≈ 6 bpm, median intervention 12 weeks; larger drops from higher starting HR.
    /// ⇒ −0.5 bpm/week at +150 min/week. relativeSD 0.6.
    public static let restingHR = ProjectionPrior(
        perWeekAtReference: -6.0 / 12, referenceDoseIncrease: aerobicReference, relative: false, relativeSD: 0.6,
        citation: "Reimers 2018, J Clin Med (endurance training ≈ −6 bpm over a median 12 weeks)",
        statement: "Typical response, not yours yet: endurance training lowered resting heart rate by about "
            + "6 bpm over about 12 weeks on average; people starting higher tended to drop more.")

    /// e1RM by training age (see `TrainingAge.typicalWeeklyGain`). relativeSD 0.6.
    public static func e1rm(_ age: TrainingAge) -> ProjectionPrior {
        ProjectionPrior(
            perWeekAtReference: age.typicalWeeklyGain, referenceDoseIncrease: strengthReference, relative: true,
            relativeSD: 0.6,
            citation: "ACSM 2009 progression position stand; Rhea 2003 (gains slow with training age)",
            statement: "Typical response, not yours yet: strength rises fastest early in training "
                + "(about \(String(format: "%.1f", age.typicalWeeklyGain * 100)) % a week at your logged "
                + "training age) and more slowly after.")
    }

    /// The prior for a metric, nil when none exists (HRV: only standardised effects are published —
    /// Amekran 2024, Cureus, RMSSD SMD 0.84 over 4–32 weeks — with no honest conversion to this wearer's
    /// ms; the Level and its parts are this app's own composite and have no literature at all).
    public static func prior(for metric: ProjectionMetricID, trainingAge: TrainingAge?) -> ProjectionPrior? {
        switch metric.kind {
        case .vo2max: return vo2max
        case .restingHR: return restingHR
        case .e1rm: return e1rm(trainingAge ?? .novice)
        case .hrv, .level, .levelPart, .aerobicMinutes, .steps, .sleepRegularity, .meditationMinutes: return nil
        }
    }

    /// Why a metric has no prior (shown when the plan scenario abstains for it).
    public static func noPriorReason(for metric: ProjectionMetricID) -> String {
        switch metric.kind {
        case .hrv:
            return "Published HRV responses are standardised effects, not milliseconds — there is no honest "
                + "typical figure to borrow."
        case .level, .levelPart:
            return "The Level is this app's own composite: no study has measured its response to training."
        default:
            return "No published typical response applies."
        }
    }
}

// MARK: - Plausible rates (goal feasibility)

public struct PlausibleRate: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        /// A published rate, with its source.
        case literature(String)
        /// The wearer's own fastest sustained change so far.
        case ownHistory
        /// A pacing convention of this app (behaviour has no physiological speed limit), with its reason.
        case pacingConvention(String)
    }
    public enum Rate: Equatable, Sendable {
        /// Units per week.
        case perWeek(Double)
        /// A fraction of the current value per week (compounding).
        case relativePerWeek(Double)
        /// Per week: max(fraction × current, floor) — the aerobic ramp guard.
        case compounding(fraction: Double, floor: Double)
        /// No limit that could make a goal unrealistic (e.g. doing LESS of a behaviour).
        case unlimited
    }
    public let rate: Rate
    public let basis: Basis

    public init(rate: Rate, basis: Basis) {
        self.rate = rate
        self.basis = basis
    }

    /// The basis in one line.
    public var basisText: String {
        switch basis {
        case .literature(let s): return s
        case .ownHistory: return "your own fastest 4-week change so far"
        case .pacingConvention(let s): return "an app pacing convention, not a physiological limit: " + s
        }
    }

    /// Weeks needed to move |gap| from `current` in the goal's direction (sign of gap). nil for .unlimited.
    public func weeksNeeded(from current: Double, gap: Double) -> Double? {
        let need = abs(gap)
        guard need > 0 else { return 0 }
        switch rate {
        case .unlimited:
            return nil
        case .perWeek(let r):
            guard r > 0 else { return nil }
            return need / r
        case .relativePerWeek(let f):
            guard f > 0, current > 0 else { return nil }
            let target = gap > 0 ? current + need : current - need
            guard target > 0 else { return nil }
            return abs(log(target / current)) / log(1 + f)
        case .compounding(let f, let floor):
            guard f > 0 || floor > 0 else { return nil }
            var v = current
            var w = 0.0
            while w < 520 {
                let step = max(f * abs(v), floor)
                guard step > 0 else { return nil }
                let moved = abs(v - current)
                if moved + step >= need { return w + (need - moved) / step }
                v += gap > 0 ? step : -step
                w += 1
            }
            return nil
        }
    }

    /// Value reachable in `weeks` from `current`, moving in `direction` (+1 / −1). nil for .unlimited.
    public func reachable(from current: Double, weeks: Double, direction: Double) -> Double? {
        guard weeks > 0 else { return current }
        switch rate {
        case .unlimited:
            return nil
        case .perWeek(let r):
            return current + direction * r * weeks
        case .relativePerWeek(let f):
            let factor = pow(1 + f, weeks)
            return direction > 0 ? current * factor : current / factor
        case .compounding(let f, let floor):
            var v = current
            let whole = Int(weeks.rounded(.down))
            if whole > 0 {
                for _ in 0..<whole { v += direction * max(f * abs(v), floor) }
            }
            let frac = weeks - Double(whole)
            v += direction * frac * max(f * abs(v), floor)
            return v
        }
    }

    /// The fastest weekly change this rate allows from `current` (for "required vs plausible" display).
    public func perWeek(at current: Double) -> Double? {
        switch rate {
        case .unlimited: return nil
        case .perWeek(let r): return r
        case .relativePerWeek(let f): return f * abs(current)
        case .compounding(let f, let floor): return max(f * abs(current), floor)
        }
    }
}

public enum PlausibleRates {

    /// Weeks of history the own-history rate needs, and the span it measures change over.
    public static let ownHistoryMinWeeks = 8
    public static let ownHistorySpanWeeks = 4

    /// The wearer's fastest change over any `ownHistorySpanWeeks`-week span, per week, in `direction`
    /// (+1 rise / −1 fall). nil below `ownHistoryMinWeeks` weekly values or when they never moved that way.
    public static func ownFastest(_ weekly: [WeeklyValue], direction: Double) -> Double? {
        guard weekly.count >= ownHistoryMinWeeks else { return nil }
        var byDay: [Int: Double] = [:]
        for w in weekly {
            if let d = ProjectionStats.dayNumber(w.weekStart) { byDay[d] = w.value }
        }
        var best: Double? = nil
        let span = ownHistorySpanWeeks * 7
        for (d, v) in byDay {
            guard let later = byDay[d + span] else { continue }
            let rate = direction * (later - v) / Double(ownHistorySpanWeeks)
            if rate > 0, rate > (best ?? 0) { best = rate }
        }
        return best
    }

    /// The plausible rate for moving `metric` in `direction` (+1 increase / −1 decrease).
    /// `weekly` is the wearer's own weekly series (for the own-history rates); `trainingAge` for lifts.
    /// nil = no rate can be stated (the verdict then relies on the wearer's own projection alone).
    public static func rate(for metric: ProjectionMetricID, direction: Double, weekly: [WeeklyValue],
                            trainingAge: TrainingAge?) -> PlausibleRate? {
        let up = direction > 0
        switch metric.kind {
        case .vo2max:
            // Milanović 2015: HIIT +5.5 ml/kg/min vs control. Spread over ~11 weeks (our assumption) ≈ 0.5/wk,
            // the fast end of typical training responses. Falls: no documented goal-relevant rate.
            guard up else { return own(weekly, direction) }
            return PlausibleRate(rate: .perWeek(0.5),
                                 basis: .literature("Milanović 2015: about +5.5 ml/kg/min from interval training "
                                    + "in controlled trials; we read that as ≈ 0.5 per week at best"))
        case .restingHR:
            // Reimers 2018: ≈ −6 bpm over a median 12 weeks of endurance training ⇒ 0.5 bpm/week.
            guard !up else { return own(weekly, direction) }
            return PlausibleRate(rate: .perWeek(0.5),
                                 basis: .literature("Reimers 2018: endurance training lowered resting HR by "
                                    + "≈ 6 bpm over about 12 weeks (≈ 0.5 bpm a week)"))
        case .hrv, .level, .levelPart:
            return own(weekly, direction)
        case .aerobicMinutes:
            guard up else { return PlausibleRate(rate: .unlimited, basis: .pacingConvention("doing less has no limit")) }
            // Nielsen 2014: novice runners with > 30 % weekly increases had more injuries; +20 min lets a
            // beginner start (the week plan's ramp guard).
            return PlausibleRate(rate: .compounding(fraction: 0.30, floor: 20),
                                 basis: .literature("Nielsen 2014: weekly increases above ~30 % were linked to "
                                    + "more injuries in new runners (the week plan's ramp guard)"))
        case .steps:
            guard up else { return PlausibleRate(rate: .unlimited, basis: .pacingConvention("doing less has no limit")) }
            return PlausibleRate(rate: .perWeek(1000),
                                 basis: .pacingConvention("+1,000 steps/day each week, the week plan's step ramp "
                                    + "(Paluch 2022: the largest gains are at the low end)"))
        case .e1rm:
            guard up else { return PlausibleRate(rate: .unlimited, basis: .pacingConvention("losing strength has no speed limit worth a goal")) }
            let age = trainingAge ?? .novice
            // Upper plausible = 2 × the typical weekly gain for the logged training age.
            return PlausibleRate(rate: .relativePerWeek(2 * age.typicalWeeklyGain),
                                 basis: .literature("ACSM 2009; Rhea 2003: strength gains slow with training "
                                    + "age — about \(String(format: "%.1f", 2 * age.typicalWeeklyGain * 100)) % a "
                                    + "week at most at your logged training age"))
        case .sleepRegularity:
            guard !up else { return PlausibleRate(rate: .unlimited, basis: .pacingConvention("a less regular schedule has no limit")) }
            return PlausibleRate(rate: .perWeek(15),
                                 basis: .pacingConvention("wake-time spread down by 15 min a week, keeping wake "
                                    + "within 30 min of the sleep anchor"))
        case .meditationMinutes:
            guard up else { return PlausibleRate(rate: .unlimited, basis: .pacingConvention("doing less has no limit")) }
            return PlausibleRate(rate: .perWeek(35),
                                 basis: .pacingConvention("+5 minutes a day each week; new habits took a median "
                                    + "66 days to become automatic (Lally 2010)"))
        }
    }

    private static func own(_ weekly: [WeeklyValue], _ direction: Double) -> PlausibleRate? {
        guard let r = ownFastest(weekly, direction: direction) else { return nil }
        return PlausibleRate(rate: .perWeek(r), basis: .ownHistory)
    }
}
