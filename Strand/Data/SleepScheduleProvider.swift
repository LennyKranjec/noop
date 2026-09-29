import Foundation
import StrandAnalytics
import WhoopStore

// SleepScheduleProvider.swift — the ONE sleep schedule the app's evening consumers read (HEALTH_V2 S2).
//
// `SleepAnchor` (pure, in the package) turns a wake anchor, the wearer's sleep need and their debt into a
// bedtime and every evening time derived from it. This is the app half: it reads the inputs from the
// store, keeps one plan per wake weekday (the weekend offset makes Saturday and Sunday differ), caches
// them so the notification and automation paths — which have no repository — read the same plan at
// launch, and tells the consumers when it changes:
//
//   · wind-down reminder — `WindDownNudge` schedules at the plan's wind-down start per weekday; its own
//     wake / need / lead settings are the fallback used only while there is no plan;
//   · room climate      — `RoomClimatePlan.schedule` prefers the plan's sleep window;
//   · WiZ               — evening scene at lights-dim, wind-down scene at wind-down start, daylight at the
//     anchor (`wiz.followSleepAnchor`, on by default); the fixed times are the fallback;
//   · caffeine cutoff   — `CaffeineBedtime` takes the plan's bedtime; `noop.caffeine.bedtimeMinutes` is the
//     fallback;
//   · bedtime quests    — `QuestBaseline.bedtimeTargetMin` = the plan's asleep-by, for every gear;
//   · morning ritual    — anchor + 15 min (`morningRitualMinute`), for `DayRitualScheduler` (H4).
//
// ABSENT IS ABSENT. With no plan (`abstention` says why: calibrating, or a schedule too irregular to
// anchor), every consumer falls back to what it did before, and the card shows "—" plus the reason.
//
// Prefs (new, not in the `.noopbak` whitelist in 2.0 — HEALTH_V2 §4.3):
//   `sleepAnchor.targetWakeMinutes`  Int, optional — the wearer's target wake;
//   `sleepAnchor.weekendOffsetMinutes` Int, 0–60 — how much later Saturday and Sunday wake.

@MainActor
final class SleepScheduleProvider: ObservableObject {

    static let shared = SleepScheduleProvider()

    enum Prefs {
        static let targetWakeMinutes = "sleepAnchor.targetWakeMinutes"
        static let weekendOffsetMinutes = "sleepAnchor.weekendOffsetMinutes"
        /// Derived cache, rebuilt on every refresh: one plan per wake weekday ("1"…"7").
        static let plans = "sleepAnchor.plans.v1"
    }

    /// Tonight's plan: the one whose wake day is the coming morning. Nil while abstaining.
    @Published private(set) var current: SleepSchedulePlan?
    /// Why there is no plan, or nil when there is one (or before the first refresh).
    @Published private(set) var abstention: SleepAnchorAbstention?
    /// One plan per wake weekday, 1 = Sunday … 7 = Saturday. Empty while abstaining.
    private(set) var plans: [Int: SleepSchedulePlan] = [:]

    private let defaults: UserDefaults
    /// The last inputs read from the store, so a pref change re-plans without a store read.
    private var lastInputs: SleepAnchor.Inputs?
    private var lastRefreshAt: Date?
    private var refreshing = false
    /// Re-reading the store more often than this on a days republish buys nothing: the inputs are nights.
    static let refreshInterval: TimeInterval = 15 * 60

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plans = Self.readCache(defaults)
        current = plan(wakingOn: Self.comingWakeDate(now: Date()))
    }

    // MARK: - Prefs

    /// The wearer's target wake, minutes past midnight; nil = anchor on the median of their own wakes.
    var targetWakeMinutes: Int? {
        get {
            guard let v = defaults.object(forKey: Prefs.targetWakeMinutes) as? Int else { return nil }
            return SleepClock.wrap(v)
        }
        set {
            if let newValue { defaults.set(SleepClock.wrap(newValue), forKey: Prefs.targetWakeMinutes) }
            else { defaults.removeObject(forKey: Prefs.targetWakeMinutes) }
            replanFromLastInputs()
        }
    }

    /// Saturday/Sunday wake offset, 0–60 minutes.
    var weekendOffsetMinutes: Int {
        get { Swift.min(Swift.max(defaults.integer(forKey: Prefs.weekendOffsetMinutes), 0), SleepAnchor.maxWeekendOffsetMin) }
        set {
            defaults.set(Swift.min(Swift.max(newValue, 0), SleepAnchor.maxWeekendOffsetMin),
                         forKey: Prefs.weekendOffsetMinutes)
            replanFromLastInputs()
        }
    }

    // MARK: - Reading the plan

    /// The wake day of the coming night: tomorrow from noon, today before it.
    static func comingWakeDate(now: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: now)
        return hour >= 12 ? (calendar.date(byAdding: .day, value: 1, to: now) ?? now) : now
    }

    /// The plan for the night that ends on `date`'s day.
    func plan(wakingOn date: Date, calendar: Calendar = .current) -> SleepSchedulePlan? {
        plans[calendar.component(.weekday, from: date)]
    }

    /// The coming night's plan, recomputed from the clock (the published `current` is refreshed on data
    /// and pref changes, and can lag the noon turn by a few minutes).
    var comingNight: SleepSchedulePlan? { plan(wakingOn: Self.comingWakeDate(now: Date())) }

    /// How long after the wake anchor the morning ritual push lands (HEALTH_V2 H4).
    static let morningRitualLeadMin = 15

    /// H4: the morning ritual push, anchor + 15 minutes, for the day `date` falls on. Nil without a plan
    /// (the ritual then keeps its own default time).
    func morningRitualMinute(on date: Date, calendar: Calendar = .current) -> Int? {
        plan(wakingOn: date, calendar: calendar).map { SleepClock.wrap($0.anchorMin + Self.morningRitualLeadMin) }
    }

    // MARK: - Refreshing

    /// A days republish: refresh at most every `refreshInterval`.
    func noteDaysChanged(repo: Repository, now: Date = Date()) {
        if let at = lastRefreshAt, now.timeIntervalSince(at) < Self.refreshInterval { return }
        Task { await self.refresh(repo: repo, now: now) }
    }

    /// Read the inputs from the store and re-plan.
    func refresh(repo: Repository, now: Date = Date()) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        lastRefreshAt = now
        let timings = await repo.sleepTimingsByDay(days: SleepAnchor.windowNights * 2 + 2)
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let nights = timings.map { day, t in
            SleepTimingNight(wakeDay: day, onsetMin: t.onsetMinute, wakeMin: t.wakeMinute,
                             asleepMin: byDay[day]?.totalSleepMin, efficiency: byDay[day]?.efficiency)
        }
        let debt = await repo.sleepDebtMinByDay()
        let newestDebt = debt.keys.max().flatMap { debt[$0] }.map { Swift.abs($0) }
        apply(nights: nights, needHours: AnalyticsEngine.Rest.engineNeedHours(), debtMin: newestDebt, now: now)
    }

    /// Plan from already-read inputs (the pref setters, and tests).
    func apply(nights: [SleepTimingNight], needHours: Double?, debtMin: Double?, now: Date = Date()) {
        let inputs = SleepAnchor.Inputs(nights: nights, needHours: needHours, debtMin: debtMin,
                                        targetWakeMin: targetWakeMinutes, weekendOffsetMin: weekendOffsetMinutes)
        lastInputs = inputs
        install(SleepAnchor.weekPlans(inputs),
                abstention: SleepAnchor.plan(inputs, wakeWeekday: 2).abstention, now: now)
    }

    private func replanFromLastInputs() {
        guard let last = lastInputs else {
            // No store read yet this launch: a target alone is enough for a plan (population need).
            apply(nights: [], needHours: AnalyticsEngine.Rest.engineNeedHours(), debtMin: nil)
            return
        }
        apply(nights: last.nights, needHours: last.needHours, debtMin: last.debtMin)
    }

    private func install(_ next: [Int: SleepSchedulePlan], abstention why: SleepAnchorAbstention?, now: Date) {
        let changed = next != plans
        plans = next
        abstention = next.isEmpty ? why : nil
        current = plan(wakingOn: Self.comingWakeDate(now: now))
        guard changed else { return }
        Self.writeCache(next, defaults)
        // The consumers that schedule ahead re-read the plan now; the rest read it when they next look.
        WindDownNudge.reschedule()
        WizLightStore.shared.sleepPlanDidChange()
    }

    // MARK: - Cache

    private static func readCache(_ d: UserDefaults) -> [Int: SleepSchedulePlan] {
        guard let data = d.data(forKey: Prefs.plans),
              let raw = try? JSONDecoder().decode([String: SleepSchedulePlan].self, from: data) else { return [:] }
        var out: [Int: SleepSchedulePlan] = [:]
        for (k, v) in raw { if let wd = Int(k), (1...7).contains(wd) { out[wd] = v } }
        return out
    }

    private static func writeCache(_ plans: [Int: SleepSchedulePlan], _ d: UserDefaults) {
        let raw = Dictionary(uniqueKeysWithValues: plans.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(raw) { d.set(data, forKey: Prefs.plans) }
    }
}
