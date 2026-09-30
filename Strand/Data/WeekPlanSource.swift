import Foundation
import StrandAnalytics
import StrandImport
import WhoopStore

// WeekPlanSource.swift — the app side of the weekly movement plan (HEALTH_V2 S3 §3.7).
//
// ONE PLACE assembles `WeekPlanInputs` and publishes what every surface reads: the week card, the review,
// the quest layer (through `WeekPlanQuestBridge`) and the coach's week line. A second assembler would let
// the card and the coach disagree about the same week.
//
// WHAT IT READS
//   * `SessionIntensityCache` — aerobic minutes, hard/strength sessions, wear coverage per local day;
//   * `repo.days` — Effort (→ linear TRIMP through `StrainScorer.strainToTRIMP` with the denominator of
//     the method that scored the day), Charge, nightly HRV, resting HR, sleep;
//   * steps through the SAME resolution Today uses (`TodayView.stepsTileSource`): a day's total is
//     reliable only when it is a measurement (calibrated counter or phone) or a fitted 4.0 estimate
//     (≥ 3 phone-calibrated days, or a manual k). An uncalibrated counter total ("est.") never is;
//   * the illness heads-up (`AppModel.illnessSignal`), sleep debt (`SleepModel.debtLedger`), age;
//   * the lift log (`StrengthProgressionSource`) for the strength line.
//
// WHAT IT KEEPS — `week-plans.json` in the store directory (NOT on the `.noopbak` whitelist in 2.0; the
// Android codec parity contract, HEALTH_V2 §4.3):
//   * the frozen plan of each of the last 26 weeks (decided at the first refresh on/after Monday 04:00
//     local, then never recomputed);
//   * the guidance each day actually got (so the review can excuse the days the plan made easy);
//   * the days the illness heads-up was up (the "raised in the last 3 days" easy trigger).
//
// NO PUSH NOTIFICATIONS. The Monday review appears on the card when the app is next opened.
//
// Refresh is re-entrancy guarded with a `defer`-cleared flag, so an early return can never wedge it.

/// What `week-plans.json` holds.
struct WeekPlanArchive: Codable, Equatable {
    var plans: [WeekPlan] = []
    var guidance: [String: DayGuidance.Kind] = [:]
    var illnessDays: [String] = []
    /// Per day: may a missed training quest (`workoutMinutes` / `strain`) be CHARGED? Decided once, from
    /// that morning's guidance and Charge (`WeekPlanQuestBridge.isChargeable`), for the penalty layer.
    var trainingChargeable: [String: Bool] = [:]

    init() {}

    /// Tolerant decoding: a key added later is absent from an older file, never a reason to drop it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = try c.decodeIfPresent([WeekPlan].self, forKey: .plans) ?? []
        guidance = try c.decodeIfPresent([String: DayGuidance.Kind].self, forKey: .guidance) ?? [:]
        illnessDays = try c.decodeIfPresent([String].self, forKey: .illnessDays) ?? []
        trainingChargeable = try c.decodeIfPresent([String: Bool].self, forKey: .trainingChargeable) ?? [:]
    }
}

/// The inputs the day guidance was last evaluated with, so an easy-week answer can re-evaluate it.
private struct GuidanceArgs {
    let day: String
    let hrvTier: ReadinessTier?
    let hrvValidNights: Int
    let charge: Double?
    let illness: Bool
    let sleepDebtMin: Double?
}

@MainActor
final class WeekPlanSource: ObservableObject {

    static let shared = WeekPlanSource()

    static let fileName = "week-plans.json"
    static let keepWeeks = 26
    static let keepGuidanceDays = 70
    static let keepIllnessDays = 30
    /// The logical day rolls at 04:00 local, so a Monday plan is decided after the Sunday night.
    static let rolloverHours = 4
    /// Days of activity assembled: 6 complete weeks for the baseline and streak rules, plus this week.
    static let windowDays = 49

    @Published private(set) var currentPlan: WeekPlan?
    @Published private(set) var progress: WeekProgress?
    @Published private(set) var todayGuidance: DayGuidance?
    @Published private(set) var lastReview: WeekReview?
    /// "bench press: Try 82.5 kg × 7" / "hold loads this week", nil with no lift log.
    @Published private(set) var strengthLine: String?
    /// The newest imported lift session (the card says "last import …").
    @Published private(set) var lastLiftSession: Date?

    /// S2 hand-off: the sleep schedule's wake SD, usual wake time and bedtime target (minutes past
    /// midnight). Set by `SleepScheduleProvider`; nil until then (the review says so).
    var sleepInputsProvider: (() -> (wakeSdMin: Double?, typicalWakeMinute: Int?, bedtimeTargetMinute: Int?))?
    /// S1 hand-off: one line of trial status for the review, set by the habit-trial store.
    var trialStatusProvider: (() -> String?)?

    private var archive: WeekPlanArchive
    private var refreshing = false
    private var lastDays: [DayActivity] = []
    private var lastGuidanceArgs: GuidanceArgs?
    /// The log-map denominator of the method that scores Effort, kept for `optimumNoticeDue`.
    private var effortDenominator: Double = StrainScorer.strainDenominator
    private let fileURL: URL?

    init(fileURL: URL? = WeekPlanSource.defaultFileURL()) {
        self.fileURL = fileURL
        self.archive = Self.load(fileURL)
        let today = Repository.localDayKey(Date())
        if let start = WeekPlanEngine.weekStart(of: today) {
            currentPlan = archive.plans.first { $0.weekStart == start }
        }
    }

    // MARK: - Storage

    static func defaultFileURL() -> URL? {
        guard let path = try? StorePaths.defaultDatabasePath() else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func load(_ url: URL?) -> WeekPlanArchive {
        guard let url, let data = try? Data(contentsOf: url) else { return WeekPlanArchive() }
        if let a = try? JSONDecoder().decode(WeekPlanArchive.self, from: data) { return a }
        // Unreadable: keep the bytes aside rather than overwrite frozen history on the next save.
        let aside = url.deletingLastPathComponent().appendingPathComponent("week-plans.unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
        return WeekPlanArchive()
    }

    private func save() {
        guard let fileURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Keep the archive bounded. Pure over the archive, so it is testable.
    static func pruned(_ a: WeekPlanArchive, today: String) -> WeekPlanArchive {
        var out = a
        out.plans = Array(a.plans.sorted { $0.weekStart < $1.weekStart }.suffix(keepWeeks))
        let gFloor = WeeklyDigestEngine.addDays(today, -keepGuidanceDays)
        out.guidance = a.guidance.filter { $0.key >= gFloor }
        out.trainingChargeable = a.trainingChargeable.filter { $0.key >= gFloor }
        let iFloor = WeeklyDigestEngine.addDays(today, -keepIllnessDays)
        out.illnessDays = Array(Set(a.illnessDays.filter { $0 >= iFloor })).sorted()
        return out
    }

    // MARK: - Refresh

    /// Recompute the week. Called by `HealthV2Refresh` (S1) when days change.
    func refresh(model: AppModel, now: Date = Date()) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        let repo = model.repo
        let profile = model.profile
        let calendar = Calendar.current
        let calendarToday = Repository.localDayKey(now)
        let logicalToday = Repository.localDayKey(now.addingTimeInterval(-Double(Self.rolloverHours) * 3600))

        let cache = await SessionIntensityCache.refresh(repo: repo, profile: profile, days: Self.windowDays,
                                                        now: now, calendar: calendar)
        var metrics: [String: DailyMetric] = [:]
        for d in repo.days { metrics[d.day] = d }

        // Steps, resolved exactly as Today resolves them.
        let resolveSteps = await Self.stepResolver(repo: repo, profile: profile, readDays: Self.windowDays + 7)

        let denom = StrainScorer.logMapDenominator(method: PuffinExperiment.effortMethod, sex: profile.sex)
        effortDenominator = denom
        let todayStart = calendar.startOfDay(for: now)
        var keys: [String] = []
        for offset in stride(from: Self.windowDays - 1, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: todayStart) {
                keys.append(Repository.localDayKey(d))
            }
        }
        var days: [DayActivity] = []
        for key in keys {
            let c = cache[key]
            let m = metrics[key]
            let steps = resolveSteps(key)
            let trimp: Double? = m?.strain.map { StrainScorer.strainToTRIMP($0, denominator: denom) }
            days.append(DayActivity(
                day: key,
                mvpaEq: c?.mvpaEq,
                moderateMin: c.flatMap { $0.abstained ? nil : $0.moderate },
                vigorousMin: c.flatMap { $0.abstained ? nil : $0.vigorous },
                hardSession: c.map { $0.hardSession },
                strengthSession: c.map { $0.strength },
                steps: steps.steps,
                stepsReliable: steps.reliable,
                trimp: trimp,
                wearCoverage: c?.wear,
                unmeasuredSessions: c?.unmeasured ?? 0,
                approximate: c?.approximate ?? false))
        }
        lastDays = days

        // HRV: nightly RMSSD aligned by day, the tier today and on each of the last 7 days.
        var hrvKeys: [String] = []
        for offset in stride(from: 96, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: todayStart) {
                hrvKeys.append(Repository.localDayKey(d))
            }
        }
        let hrvSeries: [Double?] = hrvKeys.map { metrics[$0]?.avgHrv }
        let cfg = Baselines.hrvCfg
        let validNights = hrvSeries.suffix(HRVReadiness.longWindow)
            .compactMap { $0 }.filter { cfg.minVal <= $0 && $0 <= cfg.maxVal }.count
        let tierToday = HRVReadiness.evaluate(avgHrv: hrvSeries)?.tier
        var last7: [ReadinessTier?] = []
        for j in stride(from: hrvSeries.count - 7, to: hrvSeries.count, by: 1) where j >= 0 {
            last7.append(HRVReadiness.evaluate(avgHrv: Array(hrvSeries[0...j]))?.tier)
        }

        // Illness, debt, age.
        let level = model.illnessSignal?.level
        let illnessNow = level == .raised || level == .alreadyUnwell
        if illnessNow { archive.illnessDays.append(calendarToday) }
        let ledger = SleepModel.debtLedger(days: repo.days, napSleepMinByDay: [:])
        let debt: Double? = ledger.nights.isEmpty ? nil : max(0, -ledger.balanceMin)
        let age: Int? = profile.age > 0 ? profile.age : nil
        let charge = metrics[calendarToday]?.recovery

        let inputs = WeekPlanInputs(today: logicalToday, days: days, hrvTier: tierToday, hrvTierLast7: last7,
                                    hrvValidNights: validNights, charge: charge,
                                    illnessRaisedDays: archive.illnessDays, illnessRaisedNow: illnessNow,
                                    sleepDebtMin: debt, age: age)
        let plan = WeekPlanEngine.plan(inputs, frozen: archive.plans, guidanceHistory: archive.guidance)
        if !archive.plans.contains(where: { $0.weekStart == plan.weekStart }) { archive.plans.append(plan) }

        let args = GuidanceArgs(day: calendarToday, hrvTier: tierToday, hrvValidNights: validNights, charge: charge,
                                illness: illnessNow, sleepDebtMin: debt)
        lastGuidanceArgs = args
        let guidance = Self.guidance(plan: plan, args)
        archive.guidance[calendarToday] = guidance.kind
        archive.trainingChargeable[calendarToday] =
            WeekPlanQuestBridge.isChargeable(metric: .workoutMinutes, guidance: guidance, charge: charge)

        // Strength line first: it also refreshes `lastLiftSession`, which the review's lift freshness reads.
        await loadStrengthLine(repo: repo, plan: plan)

        // Last week's review.
        var review: WeekReview? = nil
        let lastStart = WeeklyDigestEngine.addDays(plan.weekStart, -7)
        if let lastPlan = archive.plans.first(where: { $0.weekStart == lastStart }) {
            review = await buildReview(lastPlan: lastPlan, days: days, metrics: metrics, hrvKeys: hrvKeys,
                                       hrvSeries: hrvSeries, debt: debt, repo: repo, profile: profile, now: now)
        }

        archive = Self.pruned(archive, today: calendarToday)
        save()
        currentPlan = plan
        todayGuidance = guidance
        progress = WeekPlanEngine.progress(plan: plan, days: days, today: calendarToday)
        lastReview = review
    }

    /// A day's steps resolved exactly as Today resolves them (`TodayView.stepsTileSource`), and whether the
    /// total is RELIABLE: a measurement (calibrated counter or phone) always is; a fitted 4.0 estimate is
    /// only with ≥ `StepsEstimateEngine.minCalibrationDays` phone-calibrated days or a manual k; an
    /// uncalibrated counter total ("est.") never is. Reads the phone rows and the estimate series for the
    /// last `readDays` once, then resolves any local day key. The ONE resolution the week plan and Look ahead
    /// (`ProjectionSource`) share, so the S3 step gate cannot see two different step histories.
    static func stepResolver(repo: Repository, profile: ProfileStore,
                             readDays: Int) async -> (String) -> (steps: Double?, reliable: Bool) {
        var phoneByDay: [String: Int] = [:]
        for r in await repo.appleDailyRows(days: readDays) {
            if let s = r.steps { phoneByDay[r.day] = max(phoneByDay[r.day] ?? 0, s) }
        }
        var estByDay: [String: Double] = [:]
        for p in await repo.exploreSeries(key: "steps_est", source: "my-whoop", days: readDays) {
            estByDay[p.day] = p.value
        }
        var counterByDay: [String: Int] = [:]
        for d in repo.days { counterByDay[d.day] = d.steps }   // last row wins, as `metrics` does
        let estimateFitted = profile.stepsCalibrationManual
            || profile.stepsCalibrationSampleDays >= StepsEstimateEngine.minCalibrationDays
        let counterCalibrated = profile.stepCounterCalibrated
        return { key in
            let src = TodayView.stepsTileSource(strapCounter: counterByDay[key],
                                                counterCalibrated: counterCalibrated,
                                                phoneSameDay: phoneByDay[key],
                                                motionEstimate: estByDay[key].map { Int($0.rounded()) })
            let reliable: Bool
            switch src {
            case .some(.measured): reliable = true
            case .some(.motionEstimate): reliable = estimateFitted
            default: reliable = false
            }
            return (src.map { Double($0.steps) }, reliable)
        }
    }

    private static func guidance(plan: WeekPlan, _ a: GuidanceArgs) -> DayGuidance {
        WeekPlanEngine.guidance(day: a.day, weekType: plan.type, hrvTier: a.hrvTier, hrvValidNights: a.hrvValidNights,
                                charge: a.charge, illnessRaised: a.illness, sleepDebtMin: a.sleepDebtMin)
    }

    // MARK: - Penalty layer

    /// Whether a missed training quest (`workoutMinutes` / `strain`) on `day` may be charged: only on a day
    /// whose guidance was `asPlanned` with Charge known and above the low line. nil when the plan never saw
    /// that day — the caller treats nil as NOT chargeable (unknown counts as low; HEALTH_V2 S0 rule 2).
    func isTrainingChargeable(day: String) -> Bool? { archive.trainingChargeable[day] }

    /// The whole per-day map, for the pure penalty context (`QuestDebtContext`).
    var trainingChargeableByDay: [String: Bool] { archive.trainingChargeable }

    /// The guidance a day actually got, for the quest layer and the coach.
    func guidanceKind(day: String) -> DayGuidance.Kind? { archive.guidance[day] }

    /// Today's guidance, only if it was evaluated for `day` (a stale morning never leaks into a new day).
    func guidance(for day: String) -> DayGuidance? {
        guard let g = todayGuidance, g.day == day else { return nil }
        return g
    }

    /// H2(b): whether the "Optimum reached" notice is due, from the week plan instead of the population
    /// band. `todayEffort` is the Effort (0–100) Today already shows.
    func optimumNoticeDue(todayEffort: Double?) -> Bool {
        let load = todayEffort.map { StrainScorer.strainToTRIMP($0, denominator: effortDenominator) }
        return WeekPlanEngine.optimumNoticeDue(plan: currentPlan,
                                               guidance: guidance(for: Repository.localDayKey(Date())),
                                               todayLoad: load)
    }

    // MARK: - Easy-week offer

    /// The wearer's answer to an offered easy week. Declining is never penalised: nothing here reaches the
    /// quest ledger.
    func respondToEasyOffer(accept: Bool) {
        guard let plan = currentPlan, plan.easyOffer == .offered else { return }
        let next = WeekPlanEngine.respond(to: plan, accept: accept, days: lastDays)
        if let i = archive.plans.firstIndex(where: { $0.weekStart == next.weekStart }) { archive.plans[i] = next }
        save()
        currentPlan = next
        if let args = lastGuidanceArgs {
            let g = Self.guidance(plan: next, args)
            archive.guidance[args.day] = g.kind
            archive.trainingChargeable[args.day] =
                WeekPlanQuestBridge.isChargeable(metric: .workoutMinutes, guidance: g, charge: args.charge)
            save()
            todayGuidance = g
        }
        progress = WeekPlanEngine.progress(plan: next, days: lastDays, today: Repository.localDayKey(Date()))
    }

    // MARK: - Review

    private func buildReview(lastPlan: WeekPlan, days: [DayActivity], metrics: [String: DailyMetric],
                             hrvKeys: [String], hrvSeries: [Double?], debt: Double?, repo: Repository,
                             profile: ProfileStore, now: Date) async -> WeekReview {
        let weekKeys = (0..<7).map { WeeklyDigestEngine.addDays(lastPlan.weekStart, $0) }
        let end = lastPlan.weekEnd
        let fourWeekKeys = (0..<28).map { WeeklyDigestEngine.addDays(end, -$0) }

        func mean(_ xs: [Double], min n: Int) -> Double? {
            xs.count >= n ? xs.reduce(0, +) / Double(xs.count) : nil
        }
        let hrvThrough = zip(hrvKeys, hrvSeries).filter { $0.0 <= end }.map { $0.1 }
        let rhrWeek = mean(weekKeys.compactMap { metrics[$0]?.restingHr.map { Double($0) } }, min: 3)
        let rhr4 = mean(fourWeekKeys.compactMap { metrics[$0]?.restingHr.map { Double($0) } }, min: 10)
        let sleepWeek = mean(weekKeys.compactMap { metrics[$0]?.totalSleepMin }.filter { $0 > 0 }, min: 3)
        let need = SleepModel.debtNeedMin(days: repo.days)
        let sleep = sleepInputsProvider?()
        let trends = WeekTrendInputs(hrv: HRVReadiness.evaluate(avgHrv: hrvThrough), rhrWeekMean: rhrWeek,
                                     rhr4WeekMean: rhr4, sleepWeekMeanMin: sleepWeek, sleepNeedMin: need,
                                     wakeSdMin: sleep?.wakeSdMin, typicalWakeMinute: sleep?.typicalWakeMinute,
                                     sleepDebtMin: debt, bedtimeTargetMinute: sleep?.bedtimeTargetMinute)

        // VO₂max: the session method only (run/walk speed against HR reserve), never the Uth fallback.
        var vo2: [VO2SessionEstimate] = []
        let rhr = profile.zoneRestingHR
        if rhr.source != .fallback {
            let hrMax = profile.zoneHRmaxResolved.bpm
            for w in await repo.workoutRows(days: 100) {
                guard let dist = w.distanceM, dist > 0, let avg = w.avgHr else { continue }
                let dur = w.durationS ?? Double(w.endTs - w.startTs)
                let s = VO2MaxEstimator.Session(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                                                durationS: dur, distanceM: dist, avgHr: Double(avg))
                if let v = VO2MaxEstimator.fromSession(s, restingHr: rhr.bpm, hrMax: hrMax) {
                    vo2.append(VO2SessionEstimate(day: Repository.localDayKey(s.start), vo2max: v, sessionBased: true))
                }
            }
        }

        // Lift log freshness: a wearer who lifts but has imported nothing since the week began cannot be
        // told "missed" — the sets may simply not be imported yet.
        let liftFresh: Bool
        if let last = lastLiftSession {
            let ninetyDaysAgo = now.addingTimeInterval(-90 * 86_400)
            liftFresh = last < ninetyDaysAgo || Repository.localDayKey(last) >= lastPlan.weekStart
        } else {
            liftFresh = true
        }

        return WeekReview.build(plan: lastPlan, days: days, guidanceByDay: archive.guidance, liftDataFresh: liftFresh,
                                trends: trends, vo2Estimates: vo2, trialStatus: trialStatusProvider?())
    }

    // MARK: - Strength line

    private func loadStrengthLine(repo: Repository, plan: WeekPlan) async {
        guard let store = await repo.storeHandle() else { strengthLine = nil; return }
        let exercises = await StrengthProgressionSource.load(store: store)
        lastLiftSession = exercises.compactMap { $0.sessions.last?.date }.max()
        guard !exercises.isEmpty else { strengthLine = nil; return }
        if plan.strength.holdLoads {
            strengthLine = String(localized: "hold loads this week")
            return
        }
        if let ex = exercises.first(where: { $0.suggestion != nil }), let s = ex.suggestion {
            strengthLine = "\(ex.name): \(StrengthProgressionCopy.suggestion(s))"
        } else {
            strengthLine = nil
        }
    }

    // MARK: - Coach

    /// The coach's week block: the plan, today's line, and last week's review, priority-truncated to
    /// `maxChars` (whole lines only). Hand-off: registered with the context budget by the Strand/AI owner.
    func coachBlock(maxChars: Int = 700) -> String {
        guard let plan = currentPlan else { return "" }
        var lines: [String] = []
        var head = "WEEK PLAN \(plan.weekStart) (\(plan.type.rawValue) week)"
        if let r = plan.reasons.first, plan.type != .build { head += ": " + r.text }
        lines.append(head)
        if let g = todayGuidance { lines.append("Today (\(g.day)): " + g.line) }
        if let p = progress {
            let aero = plan.aerobicTarget.map { "\(Int(p.aerobicDone.rounded()))/\(Int($0)) min" }
                ?? "\(Int(p.aerobicDone.rounded())) min, no personal target yet (WHO range 150-300)"
            lines.append("Aerobic \(aero) · strength \(p.strengthDone)/\(plan.strength.minSessions)"
                + (plan.stepsTarget.map { " · steps target \(Int($0))/day" } ?? " · no step target (steps not calibrated)"))
        }
        var out = ""
        for line in lines {
            let candidate = out.isEmpty ? line : out + "\n" + line
            if candidate.count > maxChars { return out }
            out = candidate
        }
        if let review = lastReview {
            let room = maxChars - out.count - 1
            if room > 0 {
                let block = review.coachBlock(maxChars: room)
                if !block.isEmpty { out += "\n" + block }
            }
        }
        return out
    }
}
