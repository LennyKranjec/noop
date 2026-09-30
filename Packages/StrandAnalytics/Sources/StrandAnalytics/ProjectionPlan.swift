import Foundation

// ProjectionPlan.swift — "if you follow the plan": the second Look-ahead scenario (DESIGN_V2 decision 13),
// built on the weekly movement plan (HEALTH_V2 S3, `WeekPlanEngine`) and consuming its public API as-is.
//
// WHAT "THE PLAN" CHANGES, per metric:
//   * Aerobic minutes and steps ARE plan targets: the scenario is the plan's own ramp, simulated forward
//     with `WeekPlanEngine.buildAerobicTarget(b:)` (the 4-week baseline rolling on the targets met) and
//     `WeekPlanEngine.stepsTarget(median:plateau:lastWeekTarget:)` — never a second ramp rule. The band is
//     the wearer's own week-to-week execution scatter, widened with the horizon like the trend's.
//     Steps only when the S3 step gate passed (the caller passes no path otherwise → abstain).
//   * Resting HR, HRV, VO₂max, the Level, and the heart/lungs parts move with AEROBIC DOSE; e1RM and the
//     muscle part with STRENGTH SESSIONS (2/week in the plan, WHO).
//       1. The wearer's OWN measured response first: the robust (Theil–Sen) relationship between their
//          past weekly readings and the dose they did in the 4 weeks up to each reading, when there are
//          ≥ 8 paired weeks and the dose actually varied (aerobic ≥ 60 min/week, strength ≥ 1 session/week
//          between their lightest and heaviest 4-week spell). It is OBSERVATIONAL (labelled so): weeks
//          they trained more may differ in other ways. Its uncertainty (slope error × dose change) widens
//          the band.
//       2. Only where their own data is insufficient: a published TYPICAL RESPONSE (`ProjectionPriors`),
//          labelled "typical response, not yours yet", with the individual-response SD added to the band.
//       3. Neither (HRV, Level, parts without own data) ⇒ the plan scenario ABSTAINS with the reason and the
//          count still needed. It never borrows another metric's response.
//   * The plan adds nothing over the current dose (already at the top of the range, an easy/hold week)
//     ⇒ the scenario equals the trend, said plainly.
//   * The sleep anchor and the day's gear have no measured or published per-week effect size we could
//     apply to these figures honestly; they are listed as "not modelled" rather than guessed.
//
// The scenario = the current-trend projection + the plan's EXTRA dose × response. No clamps; the Level
// stays unbounded (decision 9). The horizon is the trend's (the plan cannot be projected further than
// the evidence under it).

public enum PlanBasis: Equatable, Sendable {
    /// The metric is itself a plan target (aerobic minutes, steps).
    case planTargets
    /// The wearer's own dose-response: `perDoseUnit` metric units per unit of weekly dose, from `pairs` weeks.
    case ownResponse(pairs: Int, perDoseUnit: Double)
    /// A published typical response (not the wearer's own yet).
    case typicalResponse(ProjectionPrior)
    /// The plan does not add dose over what the wearer already does.
    case holdsDose
    /// The plan does not move this metric's inputs measurably.
    case notModelled

    /// The label under the scenario.
    public var label: String {
        switch self {
        case .planTargets:
            return "The plan's own weekly targets, with your usual week-to-week scatter"
        case .ownResponse(let pairs, _):
            return "Your own response: \(pairs) past weeks of training dose against this figure (observational)"
        case .typicalResponse(let p):
            return "Typical response, not yours yet — " + p.citation + ". Band widened for how differently people respond."
        case .holdsDose:
            return "The plan holds your current training dose, so this matches your current trend"
        case .notModelled:
            return "The plan's sleep anchor and gear have no measured effect size for this figure — shown as your current trend"
        }
    }

    public var isPrior: Bool {
        if case .typicalResponse = self { return true }
        return false
    }
}

public struct PlanProjection: Equatable, Sendable {
    public let metric: ProjectionMetricID
    public let basis: PlanBasis
    public let bands: [ProjectionBand]

    public func band(weeksAhead h: Int) -> ProjectionBand? { bands.first { $0.weeksAhead == h } }
}

public enum MetricPlan: Equatable, Sendable {
    case projected(PlanProjection)
    case abstained(String)

    public var projection: PlanProjection? {
        if case .projected(let p) = self { return p }
        return nil
    }
}

/// What the plan scenario reads, per metric.
public struct PlanScenarioInputs: Equatable, Sendable {
    /// The wearer's weekly readings of the metric (longer than the trend window is fine; ≤ 26 weeks useful).
    public let metricWeekly: [WeeklyValue]
    /// The wearer's past weekly dose (aerobic WHO-min per week, or strength sessions per week). Complete weeks.
    public let doseHistory: [WeeklyValue]
    /// The dose per week if the plan is followed: index 0 = the current week, 1…12 = weeks ahead.
    /// For aerobic minutes / steps this is ALSO the metric's own target path. Empty = no plan.
    public let planPath: [Double]
    public let trainingAge: TrainingAge?

    public init(metricWeekly: [WeeklyValue], doseHistory: [WeeklyValue], planPath: [Double],
                trainingAge: TrainingAge? = nil) {
        self.metricWeekly = metricWeekly
        self.doseHistory = doseHistory
        self.planPath = planPath
        self.trainingAge = trainingAge
    }
}

public enum PlanScenario {

    /// Paired weeks the own response needs.
    public static let minPairs = 8
    /// The dose must have varied this much between the lightest and heaviest 4-week spell.
    public static func minDoseRange(_ dose: ProjectionDose) -> Double { dose == .aerobic ? 60 : 1 }
    /// Weeks averaged for the dose that goes with a reading (training effects build over weeks).
    public static let doseLagWeeks = 4

    // MARK: Plan paths (WeekPlanEngine, simulated forward)

    /// Aerobic targets if the plan is followed: this week's frozen target (when known), then each week's
    /// build target from the rolling 4-week mean of the weeks before it. `recent` = the last complete
    /// weeks' done minutes, oldest first (at most 4 used). Index 0 = the current week.
    public static func aerobicPath(recent: [Double], thisWeekTarget: Double?, weeks: Int = 12) -> [Double] {
        var hist = Array(recent.suffix(4))
        func b() -> Double { hist.isEmpty ? 0 : hist.reduce(0, +) / Double(hist.count) }
        // The plan's own rule: build below the top of the WHO range, hold at/above it (WeekPlanEngine §3.3).
        func next() -> Double {
            let base = b()
            let type: WeekType = base >= WeekPlanEngine.whoHigh ? .hold : .build
            return WeekPlanEngine.aerobicTarget(type: type, b: base) ?? WeekPlanEngine.buildAerobicTarget(b: base)
        }
        var out: [Double] = []
        let first = thisWeekTarget ?? next()
        out.append(first)
        hist.append(first)
        if hist.count > 4 { hist.removeFirst() }
        if weeks >= 1 {
            for _ in 1...weeks {
                let t = next()
                out.append(t)
                hist.append(t)
                if hist.count > 4 { hist.removeFirst() }
            }
        }
        return out
    }

    /// Step targets if the plan is followed (only when the S3 gate passed): this week's target, then each
    /// week's target from the last one as the new median. Index 0 = the current week.
    public static func stepsPath(thisWeekTarget: Double, plateau: Double, weeks: Int = 12) -> [Double] {
        var out = [thisWeekTarget]
        var last = thisWeekTarget
        if weeks >= 1 {
            for _ in 1...weeks {
                let t = WeekPlanEngine.stepsTarget(median: last, plateau: plateau, lastWeekTarget: last)
                out.append(t)
                last = t
            }
        }
        return out
    }

    /// Strength sessions if the plan is followed: this week's minimum, then the WHO 2 per week.
    public static func strengthPath(thisWeekSessions: Int, weeks: Int = 12) -> [Double] {
        [Double(thisWeekSessions)] + Array(repeating: ProjectionPriors.strengthReference, count: max(0, weeks))
    }

    // MARK: Own response

    public struct OwnResponse: Equatable, Sendable {
        public let slope: Double
        public let slopeSE: Double
        public let pairs: Int
        public let doseRange: Double
    }

    /// The trailing `doseLagWeeks` mean dose ending at each week (needs ≥ 3 of the 4 weeks).
    static func laggedDose(_ dose: [WeeklyValue]) -> [String: Double] {
        var byDay: [Int: Double] = [:]
        for w in dose { if let d = ProjectionStats.dayNumber(w.weekStart) { byDay[d] = w.value } }
        var out: [String: Double] = [:]
        for w in dose {
            guard let d = ProjectionStats.dayNumber(w.weekStart) else { continue }
            let xs = (0..<doseLagWeeks).compactMap { byDay[d - 7 * $0] }
            if xs.count >= doseLagWeeks - 1 { out[w.weekStart] = xs.reduce(0, +) / Double(xs.count) }
        }
        return out
    }

    /// The wearer's own dose-response, nil when there are too few pairs or the dose never varied enough.
    public static func ownResponse(metricWeekly: [WeeklyValue], doseHistory: [WeeklyValue],
                                   dose: ProjectionDose) -> OwnResponse? {
        let lagged = laggedDose(doseHistory)
        var xs: [Double] = []
        var ys: [Double] = []
        for w in metricWeekly.sorted(by: { $0.weekStart < $1.weekStart }) {
            if let x = lagged[w.weekStart] {
                xs.append(x)
                ys.append(w.value)
            }
        }
        guard xs.count >= minPairs, let lo = xs.min(), let hi = xs.max(), hi - lo >= minDoseRange(dose),
              let ts = ProjectionStats.theilSen(xs: xs, ys: ys) else { return nil }
        let n = Double(xs.count)
        let mean = xs.reduce(0, +) / n
        let sxx = xs.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        guard sxx > 0 else { return nil }
        var ss = 0.0
        for i in 0..<xs.count {
            let r = ys[i] - (ts.intercept + ts.slope * xs[i])
            ss += r * r
        }
        let sigma = (ss / (n - 2)).squareRoot()
        let se = (ProjectionEngine.theilSenSlopeVariance * sigma * sigma / sxx).squareRoot()
        return OwnResponse(slope: ts.slope, slopeSE: se, pairs: xs.count, doseRange: hi - lo)
    }

    /// Paired weeks available (for the "needs n of 8" line).
    public static func pairCount(metricWeekly: [WeeklyValue], doseHistory: [WeeklyValue]) -> Int {
        let lagged = laggedDose(doseHistory)
        return metricWeekly.filter { lagged[$0.weekStart] != nil }.count
    }

    /// The wearer's usual weekly dose: mean of the last 4 complete weeks with a dose (0 when none).
    public static func currentDose(_ dose: [WeeklyValue]) -> Double {
        let last = dose.sorted { $0.weekStart < $1.weekStart }.suffix(doseLagWeeks)
        guard !last.isEmpty else { return 0 }
        return last.reduce(0) { $0 + $1.value } / Double(last.count)
    }

    // MARK: The scenario

    public static func project(metric: ProjectionMetricID, trend: MetricTrend,
                               inputs: PlanScenarioInputs) -> MetricPlan {
        guard let t = trend.projection else {
            return .abstained(trend.abstention?.text ?? "Not enough history to project")
        }
        let f = t.fit
        let hs = t.bands.map { $0.weeksAhead }
        let tq = ProjectionStats.t80(df: f.k - 2) ?? ProjectionStats.z80

        // Aerobic minutes and steps: the plan's own targets.
        if metric.kind == .aerobicMinutes || metric.kind == .steps {
            guard inputs.planPath.count > 1 else {
                return .abstained(metric.kind == .steps
                    ? "No step plan: steps are not calibrated yet"
                    : "No week plan yet")
            }
            let bands = hs.map { h -> ProjectionBand in
                let c = inputs.planPath[min(h, inputs.planPath.count - 1)]
                let hw = tq * f.sigma * ProjectionEngine.extrapolationFactor(f, weeksAhead: h)
                return ProjectionEngine.makeBand(metric: metric, currentWeek: t.currentWeek, weeksAhead: h,
                                                 center: c, halfWidth: hw)
            }
            return .projected(PlanProjection(metric: metric, basis: .planTargets, bands: bands))
        }

        guard let dose = metric.dose else {
            return .projected(PlanProjection(metric: metric, basis: .notModelled, bands: t.bands))
        }
        guard inputs.planPath.count > 1 else { return .abstained("No week plan yet") }
        let current = currentDose(inputs.doseHistory)
        let extra = inputs.planPath.map { $0 - current }
        guard extra.contains(where: { $0 > 0 }) else {
            return .projected(PlanProjection(metric: metric, basis: .holdsDose, bands: t.bands))
        }

        // 1. Own response.
        if let own = ownResponse(metricWeekly: inputs.metricWeekly, doseHistory: inputs.doseHistory, dose: dose) {
            let bands = hs.map { h -> ProjectionBand in
                let base = ProjectionEngine.centerAndHalfWidth(f, weeksAhead: h)
                // The plan's 4-week dose ending at h (weeks before the current one at the current dose).
                var window: [Double] = []
                for k in (h - doseLagWeeks + 1)...h {
                    window.append(k >= 0 ? inputs.planPath[min(k, inputs.planPath.count - 1)] : current)
                }
                let delta = window.reduce(0, +) / Double(window.count) - current
                let effect = own.slope * delta
                let sd = own.slopeSE * abs(delta)
                let hw = (base.halfWidth * base.halfWidth + (tq * sd) * (tq * sd)).squareRoot()
                return ProjectionEngine.makeBand(metric: metric, currentWeek: t.currentWeek, weeksAhead: h,
                                                 center: base.center + effect, halfWidth: hw)
            }
            return .projected(PlanProjection(metric: metric,
                                             basis: .ownResponse(pairs: own.pairs, perDoseUnit: own.slope),
                                             bands: bands))
        }

        // 2. A published typical response.
        guard let prior = ProjectionPriors.prior(for: metric, trainingAge: inputs.trainingAge) else {
            let have = pairCount(metricWeekly: inputs.metricWeekly, doseHistory: inputs.doseHistory)
            let need: String
            if have < minPairs {
                need = "\(minPairs) weeks of training dose and readings (have \(have) of \(minPairs))"
            } else {
                let unit = dose == .aerobic ? "aerobic minutes a week" : "strength sessions a week"
                need = "your dose to vary by at least \(Int(minDoseRange(dose))) \(unit) between your lightest "
                    + "and heaviest 4-week spell (\(have) weeks paired so far)"
            }
            return .abstained(ProjectionPriors.noPriorReason(for: metric)
                + " The plan scenario needs your own response: " + need + ".")
        }
        let baseValue = f.latest.value
        let bands = hs.map { h -> ProjectionBand in
            let base = ProjectionEngine.centerAndHalfWidth(f, weeksAhead: h)
            var effect = 0.0
            for k in 1...max(1, h) {
                let add = max(0, extra[min(k, extra.count - 1)])
                effect += prior.perWeekAtReference * add / prior.referenceDoseIncrease
            }
            if prior.relative { effect *= baseValue }
            let sd = prior.relativeSD * abs(effect)
            let z = ProjectionStats.z80
            let hw = (base.halfWidth * base.halfWidth + (z * sd) * (z * sd)).squareRoot()
            return ProjectionEngine.makeBand(metric: metric, currentWeek: t.currentWeek, weeksAhead: h,
                                             center: base.center + effect, halfWidth: hw)
        }
        return .projected(PlanProjection(metric: metric, basis: .typicalResponse(prior), bands: bands))
    }
}
