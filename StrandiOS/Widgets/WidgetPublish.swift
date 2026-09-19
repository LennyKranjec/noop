#if os(iOS)
import Foundation
import UIKit
import WidgetKit
import StrandAnalytics
import StrandImport

extension WidgetSnapshot {
    /// The ACTIVE device's charge for the widget (#2075).
    ///
    /// `LiveState.batteryPct` is the WHOOP's, and `LiveState` is one object every live source writes
    /// into, so publishing it unconditionally put the strap's charge on the widget while a ring was the
    /// active device. Same rule as the Live Console, through the same seam.
    ///
    /// `@MainActor` like both publishers that call it: `AppModel.deviceRegistry` and `LiveState` are
    /// main-actor isolated, so a nonisolated helper cannot read them.
    @MainActor
    static func activeBatteryPct(from model: AppModel) -> Int? {
        LiveConsoleReadout.batteryPercent(
            activeIsWhoop: LiveConsoleReadout.activeIsWhoop(
                devices: model.deviceRegistry?.devices ?? [],
                activeId: model.deviceRegistry?.activeDeviceId,
            ),
            whoopPct: model.live.batteryPct,
            ringPct: model.live.ouraBatteryPct,
        )
    }

    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// anchor day, so the richer fields and the headline never disagree about which day they describe.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    /// The Rest figure for the anchor day — `restByDay[anchor] ?? (anchorIsToday ? series.last : nil)` over
    /// the full `exploreSeries("sleep_performance")` — without reading the full history for one number.
    ///
    /// PERF: a `recentDays` window is read first. `exploreSeries` builds every day INSIDE its window from
    /// exactly the layers the full read uses (each layer is a per-day value filtered only by the window),
    /// so on any day on or after the window's first day the two agree; outside it the window holds at most
    /// the unwindowed daily-column layer. Hence the window's answer is the full read's answer when:
    ///   - the anchor day is on or after the window start (its value, or its absence, is the same); and
    ///   - when the tail is needed, the window's last point is on or after the window start — then it is
    ///     the newest point of the full series too (every full-series day at or after the window start is
    ///     in the window with the same value, and the full series has no day beyond `to` the window lacks).
    /// Anything else falls back to the full read, so the result is identical either way. The bound used is
    /// one day inside the window's own start, so a midnight between the two `Date()` reads cannot open a
    /// gap.
    @MainActor
    private static func restForAnchor(repo: Repository, anchorDay: String, anchorIsToday: Bool) async -> Double? {
        let recentDays = 3
        let safeStart = Repository.dayString(Date().addingTimeInterval(-Double(recentDays - 1) * 86_400))
        if anchorDay >= safeStart {
            let recent = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop", days: recentDays)
            let recentByDay = Dictionary(recent.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            if let v = recentByDay[anchorDay] { return v }
            if !anchorIsToday { return nil }
            if let last = recent.last, last.day >= safeStart { return last.value }
        }
        let restSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        return restByDay[anchorDay] ?? (anchorIsToday ? restSeries.last?.value : nil)
    }

    @MainActor
    static func publish(from model: AppModel, reload: Bool = true) async {
        if reload { await refreshWidgetPresence() }
        let days = model.repo.days
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = Repository.widgetAnchor(days: days, now: now)
        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. The tail fallback (restSeries.last) is ONLY valid when the
        // anchor day IS the local today: early in a fresh day today's Rest row may not exist yet, so we
        // borrow the latest value. For an anchor that is NOT today, borrowing the tail would surface a
        // DIFFERENT day's Rest as this day's (the cross-day bug), so we leave it nil. Mirrors TodayView's
        // `restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)` and the
        // matching guard in WatchSessionBridge.
        var restScore: Double?
        if let day {
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = await restForAnchor(repo: model.repo, anchorDay: day.day, anchorIsToday: anchorIsToday)
        }
        // #313: honour the user's Effort scale at publish time. The widget extension cannot read the
        // app's plain `@AppStorage(UnitPrefs.effortScaleKey)` (it is not in the App Group), so we
        // pre-format the display string here and keep the 0–100 int for the ring fill (the fill
        // fraction is scale-independent: 38/100 == 8.0/21).
        let effortScale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? ""
        )
        let strain = day?.strain
        let effortDisplay: String? = strain.map { stored in
            if effortScale == .whoop {
                return String(format: "%.1f", UnitFormatter.effortValue(stored, scale: .whoop))
            }
            return "\(Int(stored.rounded()))"
        }
        // #2040: today's stress curve. Self-gating on a cheap heart-rate fingerprint, so a publish that
        // changed nothing costs one indexed COUNT and no rows. Only the FULL path scores it; the live
        // fast path below reuses the previous snapshot and so carries the curve forward untouched.
        let stress = await StressDayCurve.today(repo: model.repo)
        // The widget's own point type is built HERE, at the one place that needs it: `StressPoint`
        // lives in the iOS/widget shared sources, and the producer is now also read by the Today card,
        // which is compiled for macOS too.
        let stressPoints: [StressPoint]? = stress.map { scored in
            scored.result.timeline.map {
                // `startTs` is the wall-clock bucket start with the local shift already undone, so it
                // is a true instant and formats correctly against the device's zone.
                StressPoint(ts: Int64($0.startTs), level: $0.level, moving: $0.maskedForActivity)
            }
        }
        // Loaded ONCE for the carry-forward below. Reaching for `load()` in each of the two arguments
        // would decode the App Group blob twice on any publish that could not score, and this file
        // already went to the trouble of removing one such decode from the live path.
        let storedStress: WidgetSnapshot? = stress == nil ? load() : nil
        // WHOOP'S NIGHT FIRST, as Today does: where WHOOP scored the anchor day's recovery or sleep, its
        // figure wins over the app's own, which is computed from scraps on a night WHOOP held the strap.
        var whoopRecovery: Double?
        if let day {
            whoopRecovery = await model.repo.whoopCloudDay(day.day)?.recovery
            if let whoopSleep = await model.repo.whoopCloudSleepScore(day: day.day) { restScore = whoopSleep }
        }
        let recovery = whoopRecovery ?? day?.recovery
        let snap = WidgetSnapshot(
            recovery: recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: activeBatteryPct(from: model),
            bonded: model.live.bonded,
            updated: Date(),
            // Stored 0–100 axis for ring fill; display string carries the #313 scale.
            effort: strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr,
            effortDisplay: effortDisplay,
            effortWhoop: effortScale == .whoop,
            // nil when the curve could not be scored at all, which must not blank a widget that already
            // has one: carry the stored values forward instead of publishing an absence.
            stressSeries: stressPoints ?? storedStress?.stressSeries,
            stressDay: stress?.day ?? storedStress?.stressDay
        )
        var full = snap
        await fillStrip(&full, model: model, recovery: recovery, effortScale: effortScale,
                        dayHours: stress?.result.hours, now: now)
        fillWater(&full, model: model, now: now)
        full.waterMl = Int((await model.repo.hydrationTotal(day: Repository.localDayKey(now))).rounded())
        // Read AFTER every await above, so figures the Today screen published meanwhile are not lost.
        let stored = load()
        mergeStripFallback(stored: stored, into: &full, now: now)
        saveAndReloadIfChanged(full, previous: stored, reload: reload)
    }

    /// THE LOCK-SCREEN STRIP'S FIGURES: today's steps, today's effort and its target, stress now.
    ///
    /// THE FALLBACK. The Today screen publishes exactly what it displays (`publishTodayFigures`), and
    /// while it has done so recently those figures win (`mergeStripFallback`). This read is for when it
    /// has not — the app in the background, Today never opened — and it resolves every figure from the
    /// SAME sources, under the SAME day key, that Today does.
    ///
    /// TODAY'S, not the anchor day's. The anchor carries yesterday's scored row over the rollover so the
    /// rings are never blank; a step count or an effort carried from yesterday would be a wrong number
    /// under today's clock, so these read today's own row and are stamped with the day they were read for.
    @MainActor
    private static func fillStrip(_ snap: inout WidgetSnapshot, model: AppModel, recovery: Double?,
                                  effortScale: EffortScale, dayHours: [DaytimeStress.HourPoint]?,
                                  now: Date) async {
        // Today's key exactly as Today's `selectedDayKey` resolves it at offset 0: `repo.today`'s day
        // (which carries the pre-04:00 logical-day rule), else the logical day. The calendar day this
        // used before disagreed with Today — and with the live effort Today publishes under ITS key —
        // for the four hours after every midnight.
        let todayKey = model.repo.today?.day ?? Repository.logicalDayKey(now)
        let row = model.repo.today ?? model.repo.days.last { $0.day == todayKey }
        // STEPS, in Today's precedence: the strap's measured count, else Apple Health's imported count,
        // else the on-device estimate. The estimate is written under the COMPUTED ("-noop") source,
        // which only `exploreSeries` reads — the plain `series(key:source:"my-whoop")` this used before
        // reads the imported ids alone, so on a strap-only install it returned nothing, every time, and
        // the strip's step count stayed blank. Apple Health's count was not consulted at all.
        var steps = row?.steps
        if steps == nil {
            steps = await model.repo.appleDailyRows(days: 2)
                .filter { $0.day == todayKey }.compactMap { $0.steps }.max()
        }
        if steps == nil {
            steps = await model.repo.exploreSeries(key: "steps_est", source: "my-whoop", days: 2)
                .last { $0.day == todayKey }.map { Int($0.value.rounded()) }
        }
        snap.stepsToday = steps
        snap.stepsDay = todayKey
        // E5 — MIRRORS TODAY'S `heroOwnEffort`. The app's OWN Effort (0–100) is the one number the O8
        // calibration may touch; WHOOP's cloud strain is already on WHOOP's axis, so on the 0–21 scale it is
        // shown exactly as WHOOP gave it (10.0 reads 10.0) instead of being round-tripped through ×100/21 and
        // a curve fitted to map OUR Effort onto WHOOP's.
        // A ZERO THE STRAP DID NOT EARN yields to WHOOP's own strain for the day, as on Today.
        //
        // THE OWN EFFORT IS TODAY'S, resolved as Today resolves it: the computed lane first (`noopScores`,
        // the app's own row, as Today's `noopEffort`), the merged row only without one, and the live
        // in-progress value Today last scored (`TodayView.publishedLiveStrain`) through the same
        // never-drop max (`StrainScorer.effectiveEffort`).
        // ONE RESOLUTION (`Repository.todayEffortNow`), the same the Effort detail screen reads and the
        // same pure resolver Today's hero uses, so the widget cannot drift from either. WHOOP's own strain
        // goes on the 0–100 axis through the INVERSE calibration — the mapping the target mark below uses.
        let effortNow = await model.repo.todayEffortNow(now: now)
        snap.effortToday = effortNow.effort100.map { Int($0.rounded()) }
        // The display string as Today's hero (`heroEffortText`) builds it, so the two read identically.
        snap.effortTodayDisplay = effortNow.display(scale: effortScale)
        snap.effortDay = todayKey
        // The top of today's recommended band, the same ceiling Today's hero ring marks — placed on the
        // 0–100 axis through the INVERSE calibration, exactly as Today does, so the widget ring crosses the
        // mark at the same moment the hero ring does (linear ×100/21 without a calibration, as before).
        snap.effortTarget = CoupledView.optimalStrainRange(recovery: recovery)
            .map { Int(StrainCalibration.effort100(strain21: Double($0.upperBound)).rounded()) }
        // A publish that cannot read the last ten minutes leaves these nil; `mergeStripFallback` then keeps
        // the stored reading while it is recent rather than blanking a figure that was true a moment ago.
        if let dayHours, let level = await WindowStress.now(repo: model.repo, dayHours: dayHours) {
            snap.stressNow = level
            snap.stressNowAt = now
        }
    }

    /// THE TODAY SCREEN'S FIGURES, as displayed, for the lock-screen strip.
    ///
    /// Today resolves steps, effort and its target through a dozen sources and precedences; the strip
    /// used to re-derive them on its own publish path and drifted from them (and, for steps, found
    /// nothing at all). Now Today hands over the numbers it is SHOWING, debounced on its side, whenever
    /// they change. Written straight into the stored snapshot — every other field untouched — and only
    /// the strip is reloaded, and only while the app is in front (a background reload spends the day's
    /// WidgetKit budget; the strip's own fifteen-minute timeline picks the figures up instead).
    @MainActor
    static func publishTodayFigures(day: String, steps: Int?, effort: Int?, effortDisplay: String?,
                                    target: Int?) async {
        writeStripFigures { snap in
            snap.stepsToday = steps
            snap.stepsDay = day
            snap.effortToday = effort
            snap.effortTodayDisplay = effort == nil ? nil : effortDisplay
            snap.effortTarget = target
            snap.effortDay = day
            snap.stripTodayAt = Date()
        }
    }

    /// The Today stress tile's live ten-minute read, as it shows it.
    @MainActor
    static func publishTodayStress(_ level: Double, at: Date) async {
        writeStripFigures { snap in
            snap.stressNow = level
            snap.stressNowAt = at
        }
    }

    @MainActor
    private static func writeStripFigures(_ edit: (inout WidgetSnapshot) -> Void) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let previous = load()
        var snap = previous ?? .unavailable
        edit(&snap)
        guard snap != previous else { return }
        // Encoded as-is rather than through `save()`: that folds the bpm into the trace at `updated`,
        // and this write carries no new heart rate — the loaded trace goes back exactly as it came.
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults.set(data, forKey: storageKey)
        if renderedContentChanged(from: previous, to: snap),
           UIApplication.shared.applicationState == .active {
            WidgetCenter.shared.reloadTimelines(ofKind: stripWidgetKind)
        }
    }

    /// THE WATER WIDGET'S FIGURES: whether tracking is on, today's total and the day's goal.
    @MainActor
    private static func fillWater(_ snap: inout WidgetSnapshot, model: AppModel, now: Date) {
        snap.waterEnabled = UserDefaults.standard.bool(forKey: HydrationStore.enabledKey)
        snap.waterDay = Repository.localDayKey(now)
        snap.waterGoalMl = model.repo.hydrationGoalML(profileSex: model.profile.sex)
    }

    /// Republish only the water, after a drink was logged or the widget's own taps were drained.
    @MainActor
    static func publishWater(from model: AppModel) async {
        guard var snap = load() else {
            await publish(from: model)
            return
        }
        let previous = snap
        let now = Date()
        fillWater(&snap, model: model, now: now)
        snap.waterMl = Int((await model.repo.hydrationTotal(day: Repository.localDayKey(now))).rounded())
        // A water write does not bump the day, so `updated` stays — the strip still knows whose figures
        // it is holding.
        saveAndReloadIfChanged(snap, previous: previous)
    }

    /// Publish fields that come directly from the live BLE state without re-reading the Rest metric
    /// series. HR is admitted once a minute and battery arrives about every eight minutes; routing those
    /// hooks through the full `publish` path used to query up to 4,000 days of Rest history every time even
    /// though none of the score fields could have changed. Reusing the last full snapshot keeps every score
    /// byte-identical and changes only the three live fields. A cold start with no snapshot falls back to a
    /// full build so this fast path can never publish an incomplete first glance. The first live update
    /// after a local-day rollover also takes the full path so the score anchor advances with Today.
    @MainActor
    static func publishLive(from model: AppModel) async {
        let now = Date()
        guard var snap = load(), !liveUpdateRequiresFullBuild(previous: snap, now: now) else {
            await publish(from: model)
            return
        }
        // The loaded value IS the current on-disk state (this runs on the main actor, so nothing else
        // rewrote it between here and the save); hand it to the dedup so the live path reads the App Group
        // ONCE per tick instead of loading it again inside saveAndReloadIfChanged.
        let previous = snap
        snap.bpm = model.bpm ?? model.live.heartRate
        snap.batteryPct = Self.activeBatteryPct(from: model)
        snap.bonded = model.live.bonded
        snap.updated = now
        saveAndReloadIfChanged(snap, previous: previous)
    }

    /// Persist and ask WidgetKit for a new timeline only when a rendered field changed. The snapshot's
    /// timestamp is metadata only (no widget family displays it), so an otherwise-identical publish is a
    /// true no-op rather than an App-Group write plus an extension reload.
    /// `previous` lets the live fast path pass the snapshot it already loaded (it runs on the main actor,
    /// so that value is still current); the full publish path omits it and this loads once for the dedup.
    @MainActor
    private static func saveAndReloadIfChanged(_ snap: WidgetSnapshot, previous: WidgetSnapshot? = nil,
                                               reload: Bool = true) {
        let previous = previous ?? load()
        if !reload {
            // THE QUIET PATH, for the background. The figures are written where the widgets read them,
            // and no reload is asked for: a background reload spends the day's WidgetKit budget, and
            // every widget here already redraws itself on its own timeline — which now finds fresh
            // figures waiting instead of the last foreground's.
            if renderedContentChanged(from: previous, to: snap) {
                snap.save(previousSeries: previous?.hrSeries ?? [])
            }
            return
        }
        if renderedContentChanged(from: previous, to: snap) {
            snap.save(previousSeries: previous?.hrSeries ?? [])
            WidgetCenter.shared.reloadAllTimelines()
            // Android skips the update entirely when no widget is placed; WidgetKit offers no
            // synchronous way to know, so the reload still goes out and is instead recorded honestly.
            // Counting it as a reload would make a widget-removed export read exactly like a
            // widget-installed one, which is half the comparison the counters exist for.
            if WidgetTelemetry.widgetsInstalled {
                WidgetTelemetry.noteReloaded()
            } else {
                WidgetTelemetry.noteNoWidget()
            }
        } else if WidgetSnapshot.traceNeedsPoint(previous: previous, bpm: snap.bpm, now: snap.updated) {
            // A steady heart changes nothing the header renders, so the branch above declines — but the
            // TRACE still wants this minute's point, or it stops advancing at rest and prunes to empty
            // (#1957). Persist without a reload: the point is for the next timeline WidgetKit builds,
            // and spending a reload a minute is exactly what the dedup above exists to avoid.
            snap.save(previousSeries: previous?.hrSeries ?? [])
            WidgetTelemetry.noteDeclined()
        } else if liveUpdateRequiresFullBuild(previous: previous, now: snap.updated) {
            // The rollover's visible values can legitimately match yesterday's. Persist the fresh day
            // stamp once without spending a redundant WidgetKit reload, so later live ticks stay fast.
            snap.save(previousSeries: previous?.hrSeries ?? [])
            WidgetTelemetry.noteDeclined()
        } else {
            // Nothing at all to do. Counted rather than left as a silent fall-through: an outcome that
            // records nothing is exactly how the Android counters came to report publishes that never
            // went anywhere as if they had.
            WidgetTelemetry.noteDeclined()
        }
    }

    /// Ask WidgetKit whether any widget is actually installed, and remember the answer.
    ///
    /// Only on the full publish path: it is already `async`, and the once-a-minute live path has no
    /// `await` to spend on an XPC round trip it does not need. The answer changes when a user adds or
    /// removes a widget, which is exactly when the app is being foregrounded anyway, so a value from
    /// the last full publish is fresh enough for a diagnostic.
    ///
    /// A failure leaves the previous answer in place rather than guessing, and "never asked" counts as
    /// installed — over-reporting reloads is the safe direction for a figure meant to show a cost.
    @MainActor
    private static func refreshWidgetPresence() async {
        let installed: Bool? = await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let widgets): continuation.resume(returning: !widgets.isEmpty)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
        if let installed { WidgetTelemetry.noteWidgetsInstalled(installed) }
    }

    /// #114/#169: HR is the ONE high-frequency widget-publish trigger — `model.bpm` moves every few
    /// seconds during activity, unlike battery (~8 min) or connection flips (rare). Left ungated, the
    /// `model.$bpm` hook rewrote the shared snapshot + called `reloadAllTimelines()` on every tick (and,
    /// before the live-only fast path, also re-read the full Rest series). This caps HR-DRIVEN publishes
    /// to one per `interval`, mirroring Android's `PushGate` 60 s `HR_REFRESH_MS` cadence. Only the bpm
    /// hook consults it; the low-frequency score/battery/connection/scenePhase publish sites stay ungated,
    /// exactly as before. `@MainActor` (the hook already runs there), so the timestamp needs no locking.
    @MainActor
    enum HRPublishThrottle {
        static let interval: TimeInterval = 60
        private static var lastPublishedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed since the last HR-driven publish;
        /// false to skip this HR change. The first call always admits (`.distantPast`).
        static func admit(now: Date = Date()) -> Bool {
            guard now.timeIntervalSince(lastPublishedAt) >= interval else {
                WidgetTelemetry.noteGated(now: now)
                return false
            }
            lastPublishedAt = now
            WidgetTelemetry.noteAdmitted(now: now)
            return true
        }
    }
}
#endif
