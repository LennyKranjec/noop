import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// ProjectionSource.swift — the app side of "Look ahead" (DESIGN_V2 decision 13) and the numbers the Goals
// screen judges against (decision 14).
//
// ONE PLACE assembles every metric's weekly series and runs the pure engines (`ProjectionEngine`,
// `PlanScenario`, `PlausibleRates`, `GoalFeasibility`) over them, so Look ahead, the Goals calendar, the
// Level breakdown's "in 8 weeks" line and the coach's goals block can never disagree about a projection.
//
// WHAT IT READS (nothing is written; no store, no metricSeries):
//   * the Level and its parts — the FROZEN ledger (`LevelLedger`): a past level is a fact, never re-scored
//     here. The Level stays unbounded (decision 9); nothing below clamps it;
//   * resting HR, HRV — `repo.days` (nightly values);
//   * VO₂max — session estimates only (run/walk speed against HR reserve, `VO2MaxEstimator.fromSession`),
//     never the Uth fallback: the same rule `WeekPlanSource`'s review uses (±5 ml/kg/min outer band);
//   * weekly aerobic minutes and strength sessions — `SessionIntensityCache` (a day counts toward a week only
//     with ≥ 70 % wear, the week plan's validity rule, so "no session" is never confused with "not worn");
//   * steps — ONLY through the S3 step-reliability gate (`WeekPlanEngine.stepGate`), with each day resolved
//     exactly as Today resolves it (`TodayView.stepsTileSource`); uncalibrated ⇒ "not measured", never a line;
//   * e1RM per lift — `StrengthProgressionSource` (Epley, working sets only); the three most-trained lifts
//     are the "main lifts" Look ahead shows, every lift can carry a goal;
//   * wake-time spread — per-week circular SD of wake times (≥ 4 nights), from `repo.sleepTimingsByDay`;
//   * meditation minutes — `repo.meditationMinutesByDay`, from the first logged session on (before it: not
//     tracked, never "0");
//   * the week plan — `WeekPlanSource.shared` (refreshed here once if nothing has built it yet).
//
// COST: one refresh per screen open (re-entrancy guarded, `defer`-cleared), no timers, off the render path.

@MainActor
final class ProjectionSource: ObservableObject {

    static let shared = ProjectionSource()

    /// Weeks of history read (12-week trend window + the own dose-response, which benefits from more).
    static let historyWeeks = 26
    /// Days of session intensity requested (16 weeks: the trend window plus the 4-week dose lag).
    static let activityDays = 112
    /// Lifts shown in Look ahead.
    static let mainLiftCount = 3
    /// A day's aerobic minutes count toward a week only when the strap was worn this much (WeekPlanEngine).
    static let minWear = WeekPlanEngine.minWearCoverage
    /// Nights a week needs for a wake-time spread.
    static let minNightsPerWeek = 4

    @Published private(set) var trends: [String: MetricTrend] = [:]
    @Published private(set) var plans: [String: MetricPlan] = [:]
    @Published private(set) var weekly: [String: [WeeklyValue]] = [:]
    /// The main lifts (most sessions first) and every lift with an estimate.
    @Published private(set) var mainLifts: [String] = []
    @Published private(set) var allLifts: [String] = []
    @Published private(set) var trainingAge: TrainingAge?
    /// The local day the projections were computed on.
    @Published private(set) var asOf: String?
    @Published private(set) var isRefreshing = false

    private var refreshing = false

    // MARK: - Reads

    /// Look ahead's rows, in order.
    var lookAheadMetrics: [ProjectionMetricID] {
        ProjectionMetricID.lookAheadOrder + mainLifts.map { ProjectionMetricID.e1rm(lift: $0) }
    }

    func trend(_ m: ProjectionMetricID) -> MetricTrend {
        trends[m.id] ?? .abstained(.notEnoughHistory(have: 0, need: ProjectionEngine.minWeeks))
    }

    func plan(_ m: ProjectionMetricID) -> MetricPlan {
        plans[m.id] ?? .abstained("No week plan yet")
    }

    /// The metric's value NOW. For the Level and its parts that is the figure the rest of the app shows —
    /// the Level strip, Home and the widgets all read `LevelBarModel.shared.trend.now` — so Look ahead and
    /// Goals can never show a different "current" Level (owner report, 2026-09-30). Every other metric, and
    /// the Level before the model has loaded, uses its newest weekly value. The projection itself still
    /// runs on weekly values; only the "now" figure is shared.
    func current(_ m: ProjectionMetricID) -> WeeklyValue? { liveLevelValue(m) ?? weekly[m.id]?.last }

    /// Whether `current(m)` is the app-wide live Level figure (label it "now") rather than a week's value.
    func currentIsLive(_ m: ProjectionMetricID) -> Bool { liveLevelValue(m) != nil }

    private func liveLevelValue(_ m: ProjectionMetricID) -> WeeklyValue? {
        guard let now = LevelBarModel.shared.trend?.now else { return nil }
        let value: Double?
        switch m.kind {
        case .level:
            value = now.level
        case .levelPart:
            value = now.components.first { $0.part.rawValue == m.qualifier }?.score
        default:
            return nil
        }
        guard let v = value, v.isFinite else { return nil }
        let today = Repository.localDayKey(Date())
        return WeeklyValue(weekStart: ProjectionEngine.monday(of: today) ?? today, value: v, readings: 1)
    }

    /// The Level breakdown's compact line: "In 8 weeks: projection …" or the abstention reason.
    /// Hand-off: the design package shows it inside the Level breakdown.
    func levelEightWeekLine() -> String { ProjectionEngine.compactLine(trend(.level), weeks: 8) }

    /// The feasibility verdict for one goal, from the same series and projections Look ahead shows.
    func assess(_ goal: Goal, today: String) -> GoalAssessment {
        let series = weekly[goal.metric.id] ?? []
        let rate = PlausibleRates.rate(for: goal.metric, direction: goal.direction.sign, weekly: series,
                                       trainingAge: trainingAge)
        var final: Double? = nil
        if goal.targetDate < today, let wk = ProjectionEngine.monday(of: goal.targetDate) {
            final = series.first { $0.weekStart == wk }?.value
        }
        return GoalFeasibility.assess(goal: goal, current: current(goal.metric) ?? series.last,
                                      trend: trends[goal.metric.id], plausible: rate, today: today,
                                      finalValue: final)
    }

    // MARK: - Refresh

    func refresh(model: AppModel, now: Date = Date()) async {
        guard !refreshing else { return }
        refreshing = true
        isRefreshing = true
        defer {
            refreshing = false
            isRefreshing = false
        }

        let repo = model.repo
        let profile = model.profile
        let calendar = Calendar.current
        let today = Repository.localDayKey(now)
        let from = WeeklyDigestEngine.addDays(today, -(Self.historyWeeks * 7 + 7))
        var daily: [String: [DatedValue]] = [:]
        var weeklyOut: [String: [WeeklyValue]] = [:]

        // Level and its parts — the frozen ledger.
        for e in LevelLedger.shared.entries(from: from, through: today) {
            if e.level.isFinite { daily[ProjectionMetricID.level.id, default: []].append(DatedValue(day: e.day, value: e.level)) }
            for p in e.parts {
                if let s = p.score, s.isFinite {
                    daily[ProjectionMetricID.part(p.part).id, default: []].append(DatedValue(day: e.day, value: s))
                }
            }
        }

        // Resting HR, HRV.
        for d in repo.days where d.day >= from {
            if let r = d.restingHr, r > 0 {
                daily[ProjectionMetricID.restingHR.id, default: []].append(DatedValue(day: d.day, value: Double(r)))
            }
            if let h = d.avgHrv, h > 0, h.isFinite {
                daily[ProjectionMetricID.hrv.id, default: []].append(DatedValue(day: d.day, value: h))
            }
        }

        // VO₂max — session estimates only.
        let rhr = profile.zoneRestingHR
        if rhr.source != .fallback {
            let hrMax = profile.zoneHRmaxResolved.bpm
            for w in await repo.workoutRows(days: Self.historyWeeks * 7 + 7) {
                guard let dist = w.distanceM, dist > 0, let avg = w.avgHr else { continue }
                let dur = w.durationS ?? Double(w.endTs - w.startTs)
                let s = VO2MaxEstimator.Session(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                                durationS: dur, distanceM: dist, avgHr: Double(avg))
                if let v = VO2MaxEstimator.fromSession(s, restingHr: rhr.bpm, hrMax: hrMax), v.isFinite {
                    daily[ProjectionMetricID.vo2max.id, default: []]
                        .append(DatedValue(day: Repository.localDayKey(s.start), value: v))
                }
            }
        }

        // Aerobic minutes and strength sessions — worn days only.
        let cache = await SessionIntensityCache.refresh(repo: repo, profile: profile, days: Self.activityDays,
                                                        now: now, calendar: calendar)
        var strengthDaily: [DatedValue] = []
        for (day, c) in cache where day < today {
            guard (c.wear ?? 0) >= Self.minWear else { continue }
            if let m = c.mvpaEq { daily[ProjectionMetricID.aerobicMinutes.id, default: []].append(DatedValue(day: day, value: m)) }
            strengthDaily.append(DatedValue(day: day, value: c.strength ? 1 : 0))
        }
        let strengthWeekly = ProjectionEngine.weekly(strengthDaily, asOf: today, aggregation: .sum,
                                                     minReadings: WeekPlanEngine.minWornDaysPerWeek)

        // Steps — through the S3 gate only.
        let stepDays = await stepActivity(repo: repo, profile: profile, now: now, calendar: calendar)
        let gate = WeekPlanEngine.stepGate(days: stepDays, today: today)
        if gate.passed {
            for d in stepDays where d.stepsReliable {
                if let s = d.steps { daily[ProjectionMetricID.steps.id, default: []].append(DatedValue(day: d.day, value: s)) }
            }
        }

        // Wake-time spread: one circular SD per week with ≥ 4 nights.
        let timings = await repo.sleepTimingsByDay(days: Self.historyWeeks * 7 + 7)
        var wakesByWeek: [String: [Int]] = [:]
        for (day, t) in timings where day >= from {
            guard let mon = ProjectionEngine.monday(of: day) else { continue }
            wakesByWeek[mon, default: []].append(t.wakeMinute)
        }
        var regularity: [WeeklyValue] = []
        for (mon, wakes) in wakesByWeek where wakes.count >= Self.minNightsPerWeek {
            if let sd = SleepClock.circularSD(wakes) {
                regularity.append(WeeklyValue(weekStart: mon, value: sd, readings: wakes.count))
            }
        }
        let currentMonday = ProjectionEngine.monday(of: today) ?? today
        weeklyOut[ProjectionMetricID.sleepRegularity.id] = regularity.filter { $0.weekStart < currentMonday }
            .sorted { $0.weekStart < $1.weekStart }

        // Meditation — from the first logged day on; before it the practice was not tracked.
        let med = await repo.meditationMinutesByDay(days: Self.historyWeeks * 7 + 7)
        if let first = med.filter({ $0.value > 0 }).keys.min() {
            var day = max(first, from)
            while day < today {
                daily[ProjectionMetricID.meditationMinutes.id, default: []].append(DatedValue(day: day, value: med[day] ?? 0))
                day = WeeklyDigestEngine.addDays(day, 1)
            }
        }

        // Lifts.
        var liftDose: [String: [WeeklyValue]] = [:]
        var lifts: [(name: String, sessions: Int)] = []
        var firstLift: Date? = nil
        if let store = await repo.storeHandle() {
            let exercises = await StrengthProgressionSource.load(store: store, now: now, calendar: calendar)
            for ex in exercises {
                if let d = ex.sessions.first?.date { firstLift = min(firstLift ?? d, d) }
                let series = ex.e1rmSeries
                guard !series.isEmpty else { continue }
                let id = ProjectionMetricID.e1rm(lift: ex.name).id
                daily[id] = series.map { DatedValue(day: Repository.localDayKey($0.date), value: $0.value) }
                lifts.append((ex.name, ex.sessions.count))
                liftDose[ex.name] = Self.sessionsPerWeek(ex.sessions.map { Repository.localDayKey($0.date) }, today: today)
            }
        }
        let age: TrainingAge? = firstLift.map {
            TrainingAge.from(weeksLogged: Int(now.timeIntervalSince($0) / (7 * 86_400)))
        }

        // Weekly series.
        for (id, values) in daily {
            guard let metric = ProjectionMetricID(id: id) else { continue }
            weeklyOut[id] = ProjectionEngine.weekly(values, asOf: today, aggregation: metric.aggregation,
                                                    minReadings: metric.minReadingsPerWeek)
        }

        // Trends.
        var trendOut: [String: MetricTrend] = [:]
        var allMetrics: [ProjectionMetricID] = ProjectionMetricID.lookAheadOrder
            + [.sleepRegularity, .meditationMinutes]
        allMetrics += lifts.map { ProjectionMetricID.e1rm(lift: $0.name) }
        for m in allMetrics {
            if m.kind == .steps && !gate.passed {
                trendOut[m.id] = .abstained(.notMeasured(Self.stepsNotMeasured(gate)))
                continue
            }
            trendOut[m.id] = ProjectionEngine.trend(metric: m, weekly: weeklyOut[m.id] ?? [], asOf: today)
        }

        // The plan scenario.
        if WeekPlanSource.shared.currentPlan == nil {
            await WeekPlanSource.shared.refresh(model: model, now: now)
        }
        let weekPlan = WeekPlanSource.shared.currentPlan
        let aerobicWeekly = weeklyOut[ProjectionMetricID.aerobicMinutes.id] ?? []
        let aerobicPath: [Double] = weekPlan.map {
            PlanScenario.aerobicPath(recent: aerobicWeekly.suffix(4).map(\.value), thisWeekTarget: $0.aerobicTarget)
        } ?? []
        let stepsPath: [Double] = {
            guard let p = weekPlan, let t = p.stepsTarget, gate.passed else { return [] }
            return PlanScenario.stepsPath(thisWeekTarget: t, plateau: p.stepsPlateau)
        }()
        let strengthPath: [Double] = weekPlan.map { PlanScenario.strengthPath(thisWeekSessions: $0.strength.minSessions) } ?? []

        var planOut: [String: MetricPlan] = [:]
        for m in allMetrics where m.kind != .sleepRegularity && m.kind != .meditationMinutes {
            let path: [Double]
            let doseHistory: [WeeklyValue]
            switch m.kind {
            case .aerobicMinutes:
                path = aerobicPath
                doseHistory = aerobicWeekly
            case .steps:
                path = stepsPath
                doseHistory = []
            case .e1rm:
                path = strengthPath
                doseHistory = liftDose[m.qualifier ?? ""] ?? []
            default:
                switch m.dose {
                case .some(.aerobic):
                    path = aerobicPath
                    doseHistory = aerobicWeekly
                case .some(.strength):
                    path = strengthPath
                    doseHistory = strengthWeekly
                case .none:
                    path = []
                    doseHistory = []
                }
            }
            let inputs = PlanScenarioInputs(metricWeekly: weeklyOut[m.id] ?? [], doseHistory: doseHistory,
                                            planPath: path, trainingAge: age)
            planOut[m.id] = PlanScenario.project(metric: m, trend: trendOut[m.id] ?? .abstained(.notEnoughHistory(have: 0, need: ProjectionEngine.minWeeks)),
                                                 inputs: inputs)
        }

        trends = trendOut
        plans = planOut
        weekly = weeklyOut
        let ordered = lifts.sorted { ($0.sessions, $1.name) > ($1.sessions, $0.name) }.map { $0.name }
        mainLifts = Array(ordered.prefix(Self.mainLiftCount))
        allLifts = ordered
        trainingAge = age
        asOf = today
    }

    // MARK: - Helpers

    /// Weekly session counts for one lift, from its first logged week to the last complete week (weeks
    /// without a session are a real 0 once the wearer has started logging that lift).
    static func sessionsPerWeek(_ days: [String], today: String) -> [WeeklyValue] {
        guard let current = ProjectionEngine.monday(of: today),
              let firstDay = days.min(), var week = ProjectionEngine.monday(of: firstDay) else { return [] }
        var counts: [String: Int] = [:]
        for d in days { if let m = ProjectionEngine.monday(of: d) { counts[m, default: 0] += 1 } }
        var out: [WeeklyValue] = []
        while week < current {
            out.append(WeeklyValue(weekStart: week, value: Double(counts[week] ?? 0), readings: 7))
            week = WeeklyDigestEngine.addDays(week, 7)
        }
        return out
    }


    static func stepsNotMeasured(_ gate: StepGate) -> String {
        "Steps are not calibrated yet (\(gate.reliableDays) of \(WeekPlanEngine.stepMinReliableDays) reliable days "
            + "needed in the last \(gate.windowDays)) — no projection until they are measured"
    }

    /// Days with steps resolved exactly as Today and the week plan resolve them (the S3 gate's input) —
    /// through the week plan's own resolver, so the two can never drift apart.
    private func stepActivity(repo: Repository, profile: ProfileStore, now: Date,
                              calendar: Calendar) async -> [DayActivity] {
        let span = Self.historyWeeks * 7 + 7
        let resolve = await WeekPlanSource.stepResolver(repo: repo, profile: profile, readDays: span)
        let todayStart = calendar.startOfDay(for: now)
        var out: [DayActivity] = []
        for offset in stride(from: span, through: 1, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let key = Repository.localDayKey(date)
            let steps = resolve(key)
            out.append(DayActivity(day: key, steps: steps.steps, stepsReliable: steps.reliable))
        }
        return out
    }
}
