#if os(iOS)
import SwiftUI
import Combine
import StrandDesign
import StrandAnalytics

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
///
/// TELOS 2.0 (FRAME): the tabs are Home · Biometrics · Focus · System · More, switched by the floating
/// faux-glass `TelosTabBar` (the system bar is hidden; the custom bar does every job it did — see the notes in
/// `TelosTabBar.swift`), and every full-screen moment goes through the ONE `TelosMomentPresenter` hosted as
/// this shell's outermost overlay.
struct RootTabView: View {
    /// #1841: shared with Android by NAME and meaning, not by storage — the two platforms keep their own
    /// stores, exactly as the Clock format setting does.
    ///
    /// Default FALSE here while Android defaults true, and the divergence is deliberate. Apple's forums
    /// report `.tabBarMinimizeBehavior(.onScrollDown)` failing to trigger in tabs built on
    /// `NavigationStack(path:)` — which is every primary tab in this file, bound deliberately so a tab
    /// root can pop and re-scroll. So this may well be inert on our structure, and defaulting ON would
    /// advertise a behaviour that never happens. Off until someone confirms it on an iOS 26 device.
    @AppStorage("noop.bottomBarAutoHide") private var bottomBarAutoHide = false

    /// External entry points must wait until the mandatory first-run gates have completed. The root owns
    /// that state; keeping it explicit here prevents this shell's window-level sheet from covering a gate.
    let homeScreenQuickActionsEnabled: Bool

    // THE SAME GATES, FOR THE SHELL'S OWN FULL-SCREEN COVER. `homeScreenQuickActionsEnabled` above is the
    // precedent: an entry point that can put something over the tabs must know whether a mandatory
    // first-run gate is still up. The morning flow did not, and `LevelDayFreeze.morningDue` is true by
    // DEFAULT — it is "past 04:00 and `level.briefDay.v1` is not today", and an absent UserDefaults key
    // satisfies that — so a brand-new install opened at any time after 04:00 presented the morning flow
    // full-screen OVER the onboarding wizard and the un-accepted Terms gate, on a phone with no strap,
    // no night and nothing to brief. `backgroundCovered` only knew about this file's own sheets.
    //
    // Read here rather than threaded as a parameter so the fix needs no change in `StrandiOSApp`: these
    // are the SAME two `@AppStorage` keys `iOSRootView` gates on, and `@AppStorage` re-renders this shell
    // when either changes — which is what the `.onChange(of: launchGatesCleared)` retry further down
    // hangs on, since this view's `onAppear` has long since fired underneath the gates.
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTermsVersion = ""

    /// Whether the mandatory first-run gates are done and the tabs are the frontmost thing.
    ///
    /// Mirrors `iOSRootView`'s own DEBUG `--demo-seed` bypass, so a seeded screenshot build keeps
    /// rendering exactly what it rendered before — the gates it skips are skipped here too.
    private var launchGatesCleared: Bool {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-seed") { return true }
        #endif
        return onboarded && acceptedTermsVersion == Terms.currentVersion
    }

    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter
    /// The scene-local receiver for actions chosen from NOOP's Home Screen icon menu.
    @EnvironmentObject private var homeScreenQuickActions: HomeScreenQuickActionSceneDelegate
    /// The coach, for the tab glyph's working state. NOT observed: the coach publishes on every streamed
    /// chunk, and the shell needs one bool — kept in `coachWorking`, fed by a de-duplicated publisher.
    @Environment(\.coachEngine) private var coachRef
    @Environment(\.scenePhase) private var scenePhase
    /// The morning flow — dream, the night's questions, the daily brief — on the day's first open.
    @State private var showMorning = false
    /// When the morning flow was put up — the moment its day begins from (see `LevelDayFreeze.beginDay`).
    @State private var morningPresentedAt = Date()
    @ObservedObject private var stressMonitor = LiveStressMonitor.shared
    @ObservedObject private var dayAlerts = DayAlerts.shared
    /// The quest list, for the one card that closes a past day's chosen-difficulty plan. Observed rather
    /// than read through the quest host: the host owns the per-quest pop-ups, and this is the day-level
    /// summary that replaces four of them. Publishes only when a quest changes, so it costs nothing like
    /// the live stores do.
    @ObservedObject private var questStore = QuestStore.shared
    /// The game layer's books, for the prices on the day's card. Publishes only when a judgement, a
    /// payout or a make-up changes — rarely, like the quest list.
    @ObservedObject private var penaltyStore = QuestPenaltyStore.shared
    /// The id of the automatic full-screen stress alert while it is queued or on screen (it goes through the
    /// moment presenter). Separate from the pill in the level strip, which follows the live reading alone —
    /// ignoring the screen does not hide the pill.
    @State private var stressMomentId: String?
    /// When the stress screen was last shown, so an ignored alarm does not come back two minutes later.
    @AppStorage("stress.alertScreen.shownAt") private var stressScreenShownAt: Double = 0
    /// Once an hour at most: often enough to catch a new spell, rarely enough not to nag through one.
    private static let stressScreenEvery: TimeInterval = 60 * 60
    /// NOT observed: AppModel publishes 1–3×/s while streaming, and the shell only needs whether a
    /// workout is running — kept in `workoutActive`, fed by a de-duplicated publisher.
    @Environment(\.appModelRef) private var appModelRef
    @State private var workoutActive = false

    /// High stress AT REST: the monitor's reading when it is in the top third and no workout is running.
    /// The reading is motion-gated already; a workout in progress is exertion by definition, even when
    /// it is a still one like a plank.
    private var stressAlert: Double? {
        // `isHigh`, not one reading over the line: two consecutive high windows, so a phone call or a
        // coffee does not trip the red warning and the full-screen alarm.
        guard !workoutActive, stressMonitor.isHigh,
              let level = stressMonitor.current else { return nil }
        return level
    }
    /// The health store, for today's macros.
    @EnvironmentObject private var health: HealthKitBridge

    /// The level strip's data. The app's one `LevelBarModel`, shared with the Health tab, so there is a
    /// single writer to the level ledger rather than two instances racing to freeze the same morning.
    @ObservedObject private var levelBar = LevelBarModel.shared
    /// Presents the level timeline the radar opens.
    @State private var showLevelTimeline = false
    /// Remembered for the LIFE OF THE SHELL, so the count-up runs once on opening rather than every
    /// time a tab is switched — keyed on anything recomposition touches, the header would re-spin.
    @State private var levelCountUpKey = Int(Date().timeIntervalSince1970)

    /// Which quick-action screen the centre FAB is presenting (nil = sheet closed).
    @State private var quickAction: QuickAction?
    /// Presents the Devices manager (pair / switch bands) when a screen asks the shell to open it.
    @State private var showDevices = false
    /// A routed v5 pillar screen (Insights hub / Lab Book / fused record / Rhythm) presented as a sheet
    /// when a hub row deep-links to it via NavRouter. nil = closed.
    @State private var routedPillar: NavRouter.Destination?
    /// Selected tab — bound so tab switches can crossfade (README §Motion: ~240ms opacity swap
    /// between tab roots, calm easing). Defaults to Today.
    @State private var selectedTab: Int = 0
    /// One `NavigationPath` per tab, indexed by tab tag. Re-tapping the already-active tab pops
    /// that tab's stack to its root (#135) by clearing its path — an animated pop that leaves the
    /// root view alive, so an at-root re-tap keeps scroll position and never re-runs `.task`
    /// (#198; the #197 resetID/`.id()` rebuild reset both). Requires the tab roots' first-hop
    /// links to push `TabRoute`/`MoreDestination` VALUES — closure-destination links bypass the path.
    @State private var tabPaths: [NavigationPath] = Array(repeating: NavigationPath(), count: 5)
    /// One scroll-to-top token per tab. Bumped when the user re-taps the active tab while it's ALREADY
    /// at its root — the other half of the iOS convention #197/#198 left unserved (an at-root re-tap was
    /// a no-op). Threaded into each tab's root via `\.scrollToTopSignal`; ScreenScaffold / LiquidTodayView
    /// scroll to their top anchor when their tab's token changes.
    @State private var scrollTop: [Int] = Array(repeating: 0, count: 5)
    /// Which More-tab groups are expanded (S2). Insights + Body stay open at rest; Data + App collapse to
    /// just their header until tapped. Persisted (#860 item 2): the user's open/closed choice must SURVIVE
    /// leaving and re-entering the More tab (and relaunch), not reset to the seed every visit. Backed by an
    /// `@AppStorage` CSV string (keyed identically to the Android `MoreSectionPrefs`), bridged to a
    /// `Set<String>` through `MoreSectionPrefs` so the section logic below is unchanged.
    @AppStorage(MoreSectionPrefs.storageKey) private var expandedMoreSectionsCSV = MoreSectionPrefs.defaultCSV
    private var expandedMoreSections: Set<String> { MoreSectionPrefs.decode(expandedMoreSectionsCSV) }

    /// V8 liquid redesign is the default Today; the Settings toggle lets a user fall back to the classic
    /// Today if they prefer it (keyed identically to the SettingsView toggle). Default ON.
    @AppStorage("noop.liquidTodayEnabled") private var liquidTodayEnabled = true

    /// True while the system is generating anything at all — chat or headless.
    @State private var coachWorking = false

    /// `AICoachEngine.isWorking` (`sending || backgroundWork > 0`) as a de-duplicated stream.
    private var coachWorkingPublisher: AnyPublisher<Bool, Never> {
        guard let coach = resolvedCoach(coachRef) else { return Empty().eraseToAnyPublisher() }
        return coach.$sending.combineLatest(coach.$backgroundWork)
            .map { sending, background in sending || background > 0 }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Whether AppModel has an active workout, as a de-duplicated stream.
    private var workoutActivePublisher: AnyPublisher<Bool, Never> {
        guard let model = resolvedAppModel(appModelRef) else { return Empty().eraseToAnyPublisher() }
        return model.$activeWorkout.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher()
    }

    /// Bumped when a generation ENDS while the wearer is looking somewhere else. The edge, not the
    /// level: a flag would re-fire on every re-render.
    @State private var coachFinishedElsewhere = 0

    /// The one moment presenter. NOT observed here: the shell needs one bool (`momentShowing`, fed by a
    /// de-duplicated publisher) and the route requests; the overlay view observes the presenter itself.
    private let momentPresenter = TelosMomentPresenter.shared
    /// Whether a full-screen moment is on screen — the tabs underneath stand still while it is.
    @State private var momentShowing = false
    /// The keyboard is up: the floating bar steps aside (as the system bar did) and its inset drops.
    @State private var keyboardVisible = false
    /// Goals, opened by a moment's "Set the next goal".
    @State private var showGoals = false
    /// The Telos Lift plan editor, opened from More (the editor owns its own NavigationStack).
    @State private var showLiftPlan = false

    // MARK: - Today's meditation is still open (the Focus tab's reminder)
    //
    // WHAT "DONE" MEANS IS NOT DECIDED HERE. `MeditationLog.isDayDone` is the single rule — the level's
    // `meditationMinMinutes` — and it is the same expression the Focus card's day circles light on. A
    // badge that cleared on its own threshold would be contradicting the circles on the screen it points
    // at.
    //
    // NOT OBSERVED, for the reason `coachWorking` and `workoutActive` are not: the shell needs one bool,
    // and the previous pass deliberately took broad observation out of this file. A `@State` refreshed on
    // `.task(id:)` over a CHEAP signal is the shape that leaves.

    /// Whether today has no meditation yet. FALSE until the first read lands, so the wearer never sees a
    /// warning the data has not backed yet — an absent read is not a missed meditation.
    @State private var meditationDue = false

    /// The in-app / system motion gate (`NoopMotionState.poseStill`), so the pulse stops in Low Power
    /// Mode and under "Reduce motion in NOOP" as well as system Reduce Motion. A singleton that publishes
    /// only when one of those settings changes.
    @ObservedObject private var motionState = NoopMotionState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the reminder re-reads on. All three are counters the shell already holds:
    ///
    /// * `refreshSeq` — any data refresh, including the one a strap sync causes.
    /// * `workoutsSeq` — EVERY workout write, which is what ending a Meditation session is. A session
    ///   that ends often leaves the daily caches byte-identical and so never bumps `refreshSeq`; without
    ///   this counter the badge would survive the meditation that cleared it.
    /// * the day key, but ONLY while the app is active — which is both the "app came forward" signal and
    ///   the day roll, so the badge comes back the next morning. Off-screen the key collapses to a
    ///   constant, so a phase change costs one string comparison rather than a `DateFormatter` call.
    private var meditationDueKey: String {
        let day = scenePhase == .active ? Repository.localDayKey(Date()) : ""
        return "\(repo.refreshSeq)|\(repo.workoutsSeq)|\(day)"
    }

    /// What VoiceOver reads for the Focus item while the reminder is up — the badge is a punctuation mark,
    /// and "Focus, one item" is not a thing anybody can act on. `nil` = read the plain tab title.
    private var meditationA11yLabel: LocalizedStringKey? {
        meditationDue ? "Focus, today's meditation is still open" : nil
    }

    /// Whether the badge should be pulsing right now — as opposed to merely showing.
    ///
    /// It SHOWS whenever today's meditation is open; it MOVES only when the movement can be seen and is
    /// worth paying for: not behind the background, not under any of the three motion gates, and not while
    /// the wearer is already on Focus reading the card that says the same thing.
    private var meditationPulsing: Bool {
        meditationDue
            && scenePhase == .active
            && selectedTab != 2
            && !motionState.poseStill(reduceMotion)
    }

    /// Re-read whether today's meditation is outstanding.
    ///
    /// `days: 4` is the SAME window `QuestAutoComplete.gather` reads, so this joins that memoised workout
    /// read instead of opening a fourth cache window (`workoutRowsCacheLimit` is 3, and a new window
    /// evicts somebody else's rows).
    private func reloadMeditationDue() async {
        let minutes = await repo.meditationMinutesByDay(days: 4)[repo.meditationToday] ?? 0
        let due = !MeditationLog.isDayDone(minutes: minutes)
        if meditationDue != due { meditationDue = due }
    }

    /// The Today tab root, honouring the liquid/classic preference.
    @ViewBuilder private var todayTabRoot: some View {
        if liquidTodayEnabled { LiquidTodayView() } else { TodayView() }
    }

    /// Native tab selection binding. SwiftUI sends taps on the already-selected item through the
    /// setter, which lets the system tab bar retain the app's refresh / pop-to-root / scroll-to-top
    /// convention without placing a custom hit-testing layer over the platform bar.
    private var nativeTabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tag in
                if tag == selectedTab {
                    reselectTab(tag)
                } else {
                    selectedTab = tag
                }
            }
        )
    }

    /// Open the morning flow when this is the day's first open. Not over another sheet that is already
    /// up — it will be due again the next time the app comes to the front.
    private func presentMorningIfDue() {
        let now = Date()
        guard !showMorning, LevelDayFreeze.morningDue(now: now), !backgroundCovered else { return }
        morningPresentedAt = now
        showMorning = true
    }

    /// Show the stress screen for a high reading, unless one was shown within the hour or the morning flow
    /// or another sheet is up.
    ///
    /// OFF BY DEFAULT (HEALTH_V2 H1, owner decision): the FINAL guard is `claimScreenSlot()`, which refuses
    /// outright while `stress.alertScreen.enabled` is off and otherwise takes one of the day's two slots in
    /// one step. The diagnostic stays reachable from the stress tile (`diagnosticRequested`, below).
    private func presentStressScreenIfDue() {
        guard let level = stressAlert, stressMomentId == nil, !showMorning, !backgroundCovered,
              Date().timeIntervalSince1970 - stressScreenShownAt > Self.stressScreenEvery,
              LiveStressMonitor.shared.claimScreenSlot() else { return }
        stressScreenShownAt = Date().timeIntervalSince1970
        let id = "stress.alert.\(Int(stressScreenShownAt))"
        stressMomentId = id
        momentPresenter.enqueue(
            stressMoment(id: id, level: level, requested: false),
            onPrimary: { quickAction = .breathe },
            onClose: { stressMomentId = nil },
            secondary: TelosMomentSecondaryAction(String(localized: "IGNORE")))
    }

    /// The diagnostic the wearer opened from the stress tile: shown whatever the reading and whether or not
    /// the automatic alert is on, never counted against its cap, and closed through `closeDiagnostic()`.
    private func presentRequestedStressDiagnostic() {
        let level = stressMonitor.current
        momentPresenter.enqueue(
            stressMoment(id: "stress.diagnostic.\(Int(Date().timeIntervalSince1970 * 1000))",
                         level: level, requested: true),
            onPrimary: { quickAction = .breathe },
            onClose: { LiveStressMonitor.shared.closeDiagnostic() },
            secondary: TelosMomentSecondaryAction(String(localized: "IGNORE")),
            requestedByWearer: true)
    }

    /// The stress diagnostic as a full-screen moment (decision 7): the diagnostic register, the reading as a
    /// word and what it is measured from (`alertSubtitle`), never "x.x of 3"; BREATHE / IGNORE.
    private func stressMoment(id: String, level: Double?, requested: Bool) -> TelosMoment {
        let high = (level ?? 0) >= LiveStressMonitor.highThreshold
        let subtitle = LiveStressMonitor.alertSubtitle(level: level)
        let message = high
            ? String(localized: "Your last ten minutes read high while you were still. A few minutes of slow breathing is the fastest way down.")
            : String(localized: "Measured over the last ten minutes against your own calm reference. A few minutes of slow breathing brings it down.")
        return TelosMoment(
            id: id,
            kind: .stressDiagnostic,
            overline: String(localized: "STRESS ALERT"),
            headline: high || !requested ? String(localized: "High stress") : String(localized: "Stress right now"),
            detail: subtitle + "\n\n" + message,
            primaryActionTitle: String(localized: "BREATHE"))
    }

    /// The day's optimum as a full-screen moment (decision 4 keeps it; decision 7 makes it a moment — the
    /// shell's own overlay for it is gone). `DayAlerts` raises it once a day; closing it clears it there.
    private func presentOptimum(_ optimum: DayAlerts.Optimum) {
        let moment = TelosMoment(
            id: "optimum." + Repository.localDayKey(Date()),
            kind: .optimumReached,
            overline: String(localized: "SYSTEM DIAGNOSTICS"),
            headline: String(localized: "Optimum reached"),
            detail: optimum.message,
            figures: [
                TelosMoment.Figure(label: String(localized: "Effort"), value: optimum.effort),
                TelosMoment.Figure(label: String(localized: "Recommended"), value: optimum.target),
            ],
            primaryActionTitle: String(localized: "UNDERSTOOD"))
        momentPresenter.enqueue(moment, onPrimary: {}, onClose: { dayAlerts.dismissOptimum() })
    }

    /// What holds full-screen moments back right now (decision 7): a workout, the morning flow, or anything
    /// else already over the tabs — a sheet, a first-run gate, the day's penalty card, a quest pop-up.
    private var momentSuppression: TelosMomentPresenter.Suppression {
        let questPopupUp = questStore.offered != nil
            || !questStore.completions.isEmpty
            || !questStore.failures.isEmpty
        return TelosMomentPresenter.Suppression(
            workout: workoutActive,
            morningFlow: showMorning,
            covered: backgroundCovered || questStore.planReport != nil || questPopupUp)
    }

    /// The five items of the floating bar, with the live state the system items used to carry.
    private var tabBarItems: [TelosTabItem] {
        [
            TelosTabItem(tag: 0, title: "Home", systemImage: "house"),
            TelosTabItem(tag: 1, title: "Biometrics", systemImage: "waveform.path.ecg"),
            TelosTabItem(tag: 2, title: "Focus", systemImage: "figure.mind.and.body",
                         a11yLabel: meditationA11yLabel,
                         showsMark: meditationDue,
                         pulsing: meditationPulsing),
            TelosTabItem(tag: 3, title: "System", systemImage: coachWorking ? "circle.dotted" : "sparkles",
                         bounceTrigger: coachFinishedElsewhere),
            TelosTabItem(tag: 4, title: "More", systemImage: "ellipsis"),
        ]
    }

    /// Whether something is already over the tabs — one of this shell's own sheets, or a mandatory
    /// first-run gate that is drawn OUTSIDE this file (the onboarding wizard and the Terms gate, both
    /// stacked over this view in `iOSRootView`). Both of the shell's full-screen presenters read it.
    private var backgroundCovered: Bool {
        !launchGatesCleared
            || quickAction != nil || showDevices || routedPillar != nil || showLevelTimeline
            || showGoals || showLiftPlan
    }

    private func reselectTab(_ tag: Int) {
        Task { await repo.refresh() }
        if !tabPaths[tag].isEmpty {
            tabPaths[tag] = NavigationPath()
        } else {
            scrollTop[tag] += 1
        }
    }

    // NO TAB SWIPE. The anywhere-swipe that moved between tabs is gone on every tab: the tab bar is
    // the one way between them. A sideways flick is too easily a scroll that drifted, a chip strip
    // dragged, or a back-swipe that started a few points from the edge — and each of those throwing the
    // wearer onto a different tab cost more than the gesture ever saved.

    /// Select a tab from the floating bar. A tap on the ALREADY-selected item is the reselect the system bar
    /// used to send through its binding: refresh, then pop to root, or scroll to the top when at the root.
    private func selectTab(_ tag: Int) {
        if tag == selectedTab {
            reselectTab(tag)
        } else {
            selectedTab = tag
        }
    }

    var body: some View {
        // Split in four (core → presentations → routing → the moment overlay) to keep each chain well
        // inside the type-checker's budget.
        shellRouting
            // THE ONE MOMENT PRESENTER (decision 7), the OUTERMOST overlay: above the tabs, the level strip,
            // the floating bar and the shell's cards. Sheets and the morning flow present above it, which is
            // why the queue is held while any of them is up (`momentSuppression`).
            .overlay {
                TelosMomentOverlay(presenter: momentPresenter)
            }
            // Connect the stores that raise moments (goals today; see the FRAME hand-offs for the rest).
            // Idempotent.
            .onAppear { momentPresenter.wireSources() }
    }

    /// The tabs, the level strip, the floating bar and the shell's always-on work.
    private var shellCore: some View {
        // THE SYSTEM BAR IS HIDDEN (per tab, in `tab(...)` / `moreTab`) and the floating `TelosTabBar` below
        // replaces it. The TabView stays: it keeps each tab's root alive once visited (scroll positions,
        // chart ranges, `.task`s run once) exactly as before, and lazily builds a tab on first visit.
        TabView(selection: nativeTabSelection) {
            // HOME is the day you are in (the reference's house). Its hero belongs to Today itself
            // (LiquidTodayView); the shell only hosts it.
            tab(todayTabRoot, "Home", "house", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
            // BIOMETRICS: the Health/Trends screen, renamed to the reference's word. Sleep is reached from it
            // and from its own More row.
            tab(TrendsView(), "Biometrics", "waveform.path.ecg", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
            // FOCUS STAYS (coordinator decision 3 — not swapped for Habits). Its "today's meditation is still
            // open" mark and pulse are drawn by the floating bar (`tabBarItems`), with the same VoiceOver label.
            tab(MindfulnessView(), "Focus", "figure.mind.and.body",
                path: $tabPaths[2], scrollSignal: scrollTop[2],
                a11yLabel: meditationA11yLabel)
                .tag(2)
            // SYSTEM (the coach). Its working glyph and finished-elsewhere pop live on the floating bar.
            tab(CoachView(), "System", coachWorking ? "circle.dotted" : "sparkles",
                path: $tabPaths[3], scrollSignal: scrollTop[3])
                .tag(3)
            moreTab(path: $tabPaths[4], scrollSignal: scrollTop[4]).tag(4)
        }
        .tint(StrandPalette.accent)
        // THE TABS BEHIND A SHEET — OR A FULL-SCREEN MOMENT — STAND STILL. Applied here, on the TabView
        // itself, so it reaches every tab root and none of the sheets below — they are attached further out
        // and do not inherit it.
        .environment(\.noopBackgroundCovered, backgroundCovered || momentShowing)
        // THE LEVEL STRIP, over every tab. An overlay rather than a toolbar: the radar hangs a third of
        // its own height past the bar's bottom edge, and a toolbar clips its content.
        //
        // IT DOES NOT IGNORE THE SAFE AREA. It used to, which put the whole strip UNDER the status bar:
        // the clock sat on the trend chips, the battery sat on the levers, and the notch cut the top off
        // the pentagon. The strip's own FILL still bleeds up behind the status bar (see the background
        // inside the view) so there is no seam; only the content is inset.
        .overlay(alignment: .top) {
            LevelOverlayBarView(
                trend: levelBar.trend,
                countUpKey: levelCountUpKey,
                onOpenTimeline: { showLevelTimeline = true },
                stressAlert: stressAlert,
                onStressAlert: { quickAction = .breathe }
            )
            .allowsHitTesting(true)
        }
        // THE FLOATING TAB BAR. Over the content, which scrolls beneath it (every tab's safe area is inset
        // by the bar's height, so nothing ends up hidden under it). Steps aside for the keyboard, as the
        // system bar did; `ignoresSafeArea(.keyboard)` keeps it from riding up on the way out.
        .overlay(alignment: .bottom) {
            TelosTabBar(items: tabBarItems, selected: selectedTab, onSelect: selectTab)
                .opacity(keyboardVisible ? 0 : 1)
                .allowsHitTesting(!keyboardVisible)
                .accessibilityHidden(keyboardVisible)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if !keyboardVisible { keyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardVisible { keyboardVisible = false }
        }
        .task(id: repo.refreshSeq) {
            await levelBar.refresh(repo: repo, tick: repo.refreshSeq)
        }
        // The Focus tab's reminder. Only while the app is actually in front: a read fired as the shell
        // goes away would be work nobody can see the result of, and the key re-fires on the way back.
        .task(id: meditationDueKey) {
            guard scenePhase == .active else { return }
            await reloadMeditationDue()
        }
        // Both publishers replay their current value on subscription, which seeds the state on appear.
        .onReceive(coachWorkingPublisher) { working in
            if coachWorking != working { coachWorking = working }
        }
        .onReceive(workoutActivePublisher) { active in
            if workoutActive != active { workoutActive = active }
        }
        .onChangeCompat(of: coachWorking) { working in
            // Only on the falling edge, and only when they are not already reading the answer.
            if !working, selectedTab != 3 { coachFinishedElsewhere += 1 }
        }
        .sheet(isPresented: $showLevelTimeline) {
            LevelTimelineSheetView(model: levelBar, repo: repo)
        }
        // THE QUEST POP-UP, over every tab. It belongs to the shell rather than to Today for the same
        // reason the level strip does: a directive that only appears on the tab you happened to be on is
        // one the system never actually issued.
        .questHost()
        // #1841: the same "Hide bar when scrolling" preference Android drives its own bar with. Here the
        // system owns the behaviour — iOS 26's tab bar MINIMISES to a pill on scroll down rather than
        // sliding away entirely, so this is the platform's read of the same intent, not a copy of ours.
        // With the floating bar replacing the system one this is inert (the system bar is hidden); kept so the
        // preference keeps its one reader and the minimise behaviour returns if the system bar ever does.
        .noopTabBarAutoHide(bottomBarAutoHide)
        // NO TAB CROSSFADE (§6.1): tab switches are instant. The fade encoded nothing and animated the whole
        // subtree of both tabs.
    }

    /// The shell's covers, cards, sheets, routing and change handlers, over `shellCore`.
    private var shellPresentations: some View {
        shellCore
        .task {
            // The room sensor is read every ten minutes for as long as the app runs, which is what the
            // bedroom history is made of.
            BedroomClimate.shared.startPolling()
            // The lights' morning and evening automations, checked once a minute while the app runs.
            WizLightStore.shared.startAutomation()
            // Stress right now, for the warning beside the level.
            LiveStressMonitor.shared.start(repo: repo)
            await repo.refresh()
            // TODAY'S MACROS, from whichever app the wearer keeps their food diary in. A live read
            // rather than an import: a diary is filled in across the day, so a figure banked once is
            // wrong by lunchtime. iOS-only, which is why it is here and not in the shared Today.
            //
            // INSTALLED AS A HOOK, not just run once at launch: every refresh the wearer asks for should
            // re-read the diary, and the shared screens cannot call HealthKit themselves.
            repo.refreshPlatformNutrition = { [weak repo] in
                guard let repo else { return }
                if await health.refreshTodayMacros() != nil { repo.noteNutritionChanged() }
            }
            await repo.refreshPlatformNutrition?()
            // Backup & Sync: on-launch catch-up (see RootView). Detached + utility priority so a
            // 100MB+ whole-DB ZIP never blocks startup; gated on the auto toggle (default OFF). (Must-fix #4.)
            let backupRepo = repo
            Task.detached(priority: .utility) {
                await FolderBackup.catchUpIfDue(checkpoint: { await backupRepo.checkpointForBackup() })
            }
        }
        // Quick-action sheet presents with the calm easing (~0.42s) per the README sheet spec —
        // the easing is applied where `quickAction` is set (see `presentQuickAction`), keeping the
        // animation scoped to the sheet rather than the whole shell.
        // THE MORNING FLOW, on the first open of the day (after 04:00). Full screen, over every tab: it is
        // the first thing the day says, and it is where today's level is scored and frozen.
        .fullScreenCover(isPresented: $showMorning) {
            MorningFlowView(levelBar: levelBar, presentedAt: morningPresentedAt) {
                showMorning = false
                // The day has turned: the strip redraws on today's level (or marks it pending) now, not at
                // the next data refresh. The model owns the load, so the cover going away cannot stop it.
                Task { await levelBar.reload(repo: repo) }
            }
        }
        .onAppear { presentMorningIfDue() }
        // THE RETRY, once the gates come down. This shell is alive UNDER the wizard and the Terms gate,
        // so its `onAppear` has already fired by the time a first-run user finishes them — without this
        // the morning flow would simply be skipped until the next foreground, which is the opposite
        // mistake from the one being fixed.
        .onChange(of: launchGatesCleared) { _, cleared in
            if cleared { presentMorningIfDue() }
        }
        // THE STRESS ALARM and THE DAY'S OPTIMUM are full-screen MOMENTS now (decision 7): they go through the
        // one presenter (see `presentStressScreenIfDue`, `presentRequestedStressDiagnostic`, `presentOptimum`
        // and the change handlers below) instead of overlays of their own. Both features stay (decision 4);
        // the automatic stress alert is off by default (H1) and only its opt-in presents itself.
        .onChange(of: stressMonitor.diagnosticRequested, initial: true) { _, requested in
            if requested { presentRequestedStressDiagnostic() }
        }
        .onChange(of: dayAlerts.optimum, initial: true) { _, optimum in
            if let optimum { presentOptimum(optimum) }
        }
        // YESTERDAY'S PLAN, CLOSED IN ONE CARD — WITH ITS PRICE. The directives a difficulty choice issues
        // still do not each get a red card when they run out (four modal cards in a row is noise, not
        // teeth), so `QuestStore.sweepExpired` cancels them without cards and `QuestPlanReporter`
        // summarises the day once. What changed is the card: every line that fell short now carries its
        // penalty — how far short, the gear's multiplier, any escalation, the make-up it rolled into — and
        // the headline is the XP the day cost (`QuestPenaltyDayCard`). A line the data never carried says
        // "not measured — no penalty". The store holds the card back until the day's plan quests are all
        // judged, so it never shows a verdict without its numbers.
        //
        // NOT OVER THE MORNING FLOW OR A SHEET. The card is not urgent and the store holds it until it is
        // dismissed, so gating the RENDER is enough — nothing is lost by drawing it a moment later.
        .overlay {
            if let report = questStore.planReport, !showMorning, !backgroundCovered {
                let card = QuestPenaltyDayCard.make(
                    report: report,
                    judgements: penaltyStore.ledger.judgements.filter {
                        $0.dayKey == report.day && $0.questId.hasPrefix(QuestDayPlan.idPrefix)
                    })
                DiagnosticAlertView(
                    overline: card.overline,
                    symbol: card.totalCost > 0 ? "xmark.octagon" : "flag.checkered",
                    title: card.title,
                    subtitle: card.subtitle,
                    message: card.message,
                    primary: ("UNDERSTOOD", { questStore.dismissPlanReport() }),
                    ringed: card.totalCost > 0)
                .transition(.opacity)
                .task { SystemHaptics.play(.summon) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: questStore.planReport?.day)
        // CLOSED QUESTS ARE JUDGED ON THEIR DATA from the shell as well as from Today's strip, so a miss
        // is priced (and the day's card let through) whichever tab the wearer is on. Keyed on the pending
        // queue, re-read every few minutes while the app is in front so late data is picked up.
        .task(id: "\(penaltyStore.pendingSignature)|\(scenePhase == .active)") {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await QuestPenaltyAssessor.run(repo: repo)
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
        .onChange(of: stressAlert != nil) { _, high in
            if high {
                presentStressScreenIfDue()
            } else if let id = stressMomentId {
                // The reading came down: the automatic alert is taken back, queued or on screen.
                momentPresenter.withdraw(id: id)
                stressMomentId = nil
            }
        }
        // The strap-cue engine holds its ambient cues while the morning flow is up.
        .onChange(of: showMorning) { _, v in StrapCueEngine.shared.morningFlowActive = v }
        // The moment queue waits for whatever is over the tabs, and shows the next one the moment it clears.
        .onChange(of: momentSuppression, initial: true) { _, suppression in
            momentPresenter.setSuppression(suppression)
        }
        .onReceive(momentPresenter.$current.map { $0 != nil }.removeDuplicates()) { showing in
            if momentShowing != showing { momentShowing = showing }
        }
        // A moment's primary action asked for a screen ("Set the next goal" → Goals).
        .onReceive(momentPresenter.$requestedRoute.removeDuplicates()) { route in
            guard let route else { return }
            switch route {
            case .goals: showGoals = true
            }
            momentPresenter.consumeRoute()
        }
        .sheet(isPresented: $showGoals) {
            NavigationStack {
                GoalsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showGoals = false }
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
        }
        .sheet(isPresented: $showLiftPlan) {
            LiftProgramEditorView(programs: LiftProgramStore.shared)
        }
    }

    /// Scene phase, the quick-action / Devices / pillar sheets, router requests and Home Screen actions,
    /// over `shellPresentations`.
    private var shellRouting: some View {
        shellPresentations
        .onChange(of: scenePhase) { _, phase in
            LiveStressMonitor.shared.foreground = phase == .active
            if phase == .active { presentMorningIfDue() }
        }
        .sheet(item: $quickAction) { action in
            QuickActionHost(initial: action) { quickActionDestination($0) }
        }
        // Live's "Manage devices" affordance (and any future cross-screen link to Devices) routes here:
        // present the Devices manager in its own nav stack, the same way the quick-action screens do.
        .sheet(isPresented: $showDevices) {
            devicesScreen
        }
        // v5 pillar deep-links (Insights hub / Lab Book / fused record / Rhythm) present as a sheet in
        // their own nav stack — the same idiom the quick-action + Devices screens use on iPhone.
        .sheet(item: $routedPillar) { dest in
            pillarScreen(dest)
        }
        // Honour a router request: Devices keeps its dedicated sheet; the v5 pillars route through the
        // shared pillar sheet. Cleared so the same tap can fire again later.
        .onChange(of: router.requestedDestination) { _, dest in
            switch dest {
            case .devices:
                showDevices = true
                router.requestedDestination = nil
            case .insightsHub, .labBook, .fusedRecord, .rhythm:
                routedPillar = dest
                router.requestedDestination = nil
            case .coach:
                // K3: Coach is now a top-level tab (tag 3) — switch to it directly instead of
                // presenting it as a pillar sheet.
                selectedTab = 3
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                selectedTab = 1
                router.requestedDestination = nil
            case .activeWorkout:
                // The Today active-workout indicator opens Live through the quick-action Live sheet; once
                // it's up, LiveView consumes the one-shot `presentActiveWorkout` flag and presents the
                // in-exercise screen. Calm sheet easing, matching the other quick-action presents.
                quickAction = .live
                router.requestedDestination = nil
            case .liveSession:
                // Live Sessions is presented from Today's own Start entry (a cover, not a routed sheet),
                // so a deep-link lands on the Today tab where that entry lives.
                selectedTab = 0
                router.requestedDestination = nil
            case .coach:
                // #1862: the Today Coach launcher hands its question here. Coach is a pillar sheet on
                // iPhone, the same as the Insights hub, so route it that way rather than switching tabs.
                routedPillar = dest
                router.requestedDestination = nil
            case .journal:
                // The #627 Today journal widget opens the journal through the quick-action Journal sheet
                // (InsightsView), matching the FAB's "Log journal" action. Calm sheet easing.
                quickAction = .journal
                router.requestedDestination = nil
            case nil:
                break
            }
        }
        // A screen's top-bar "+" routes here: open the quick-action sheet, then clear the flag.
        .onChange(of: router.quickActionsRequested) { _, req in
            if req {
                quickAction = .menu
                router.quickActionsRequested = false
            }
        }
        // A cold-launch selection is already pending when this shell appears; a warm selection arrives
        // through the change callback. Both route through the same screens as the centre FAB.
        .onAppear {
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActions.pendingAction) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
        .onChange(of: homeScreenQuickActionsEnabled) { _, _ in
            presentPendingHomeScreenQuickActionIfPossible()
        }
    }

    /// Mandatory launch gates defer an external action. Once the shell is available, an explicit Home
    /// Screen choice supersedes any ordinary shell sheet; choosing the already-open destination simply
    /// consumes the request and leaves that screen in place.
    private func presentPendingHomeScreenQuickActionIfPossible() {
        guard homeScreenQuickActionsEnabled,
              let action = homeScreenQuickActions.pendingAction else { return }

        let destination: QuickAction = switch action {
        case .liveHeartRate: .live
        case .startWorkout: .workout
        case .logJournal: .journal
        case .breathe: .breathe
        }
        homeScreenQuickActions.consume(action)
        withAnimation(Self.sheetEase) {
            showDevices = false
            routedPillar = nil
            quickAction = destination
        }
    }

    /// A routed v5 pillar screen wrapped in its own nav stack + Done button (mirrors `quickScreen`).
    @ViewBuilder
    private func pillarScreen(_ dest: NavRouter.Destination) -> some View {
        NavigationStack {
            Group {
                switch dest {
                case .insightsHub: InsightsHubView()
                case .labBook: LabBookView()
                case .fusedRecord: FusedRecordHost()
                case .rhythm: RhythmHost(onClose: { routedPillar = nil })
                case .devices: DevicesView()
                // K5: the scheduled morning-brief notification's tap-through target.
                case .coach: CoachView()
                // .trends is never presented as a pillar sheet on iPhone (it's a primary tab — the
                // requestedDestination handler switches `selectedTab` instead), but the switch must stay
                // exhaustive. Fall back to Trends inside the sheet host if it ever arrives here.
                case .trends: TrendsView()
                // .activeWorkout routes through the quick-action Live sheet (handled above); this keeps the
                // switch exhaustive and falls back to Live if it ever reaches the pillar host.
                case .activeWorkout: LiveView()
                // .liveSession routes to the Today tab (handled above — its Start entry owns the cover);
                // this keeps the switch exhaustive and falls back to Today if it ever reaches the host.
                case .liveSession: LiquidTodayView()
                // .journal opens through the quick-action Journal sheet (handled above); this keeps the
                // switch exhaustive and falls back to the journal's Insights host if it ever reaches here.
                case .journal: InsightsView()
                // #1862: Coach IS presented here — the launcher sheet routes to it as a pillar, so unlike
                // the fallbacks above this arm is the real destination, not a safety net.
                case .coach: CoachView()
                }
            }
            // The Trends/Today fallbacks above emit TabRoute value pushes (#198), which need a
            // destination registered in THIS sheet's stack to resolve.
            .tabRouteDestinations()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            // #1027: same fix as quickScreen — the pillar screens draw the full-bleed liquid sky, so a
            // transparent nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { routedPillar = nil }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    /// Calm-easing curve (cubic-bezier(0.22,1,0.36,1)) at the README sheet-present duration.
    private static let sheetEase = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.42)

    // MARK: - Quick-action sheet

    /// Routes a chosen quick action to the existing screen, or shows the action menu itself.
    @ViewBuilder
    private func quickActionDestination(_ action: QuickAction) -> some View {
        switch action {
        case .menu:
            // The menu itself is drawn by `QuickActionHost`, which owns the swap to a destination.
            EmptyView()
        case .live:
            quickScreen(LiveView())
        case .workout:
            quickScreen(WorkoutsView())
        case .journal:
            quickScreen(InsightsView())
        case .breathe:
            quickScreen(BreathingView())
        }
    }

    /// Wraps a routed quick-action screen in its own nav stack so it has a title bar + the
    /// shared surface background, matching how the More-tab links present these same views.
    private func quickScreen<V: View>(_ view: V) -> some View {
        NavigationStack {
            view
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: these screens draw a full-bleed liquid sky (ScreenScaffold topBackground) that runs
                // edge-to-edge under a transparent bar — exactly how the tab roots present it. An OPAQUE
                // surfaceBase toolbar background sat on top of that sky and, as the content scrolled up, its
                // extended status-bar band CLIPPED the sky + the in-content header ("Live Body Console").
                // Hiding the bar background lets the sky stay continuous under the floating Done button.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { quickAction = nil }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// The Devices manager wrapped in its own nav stack + Done button (mirrors `quickScreen`, but
    /// dismisses the dedicated `showDevices` sheet rather than the quick-action item).
    private var devicesScreen: some View {
        NavigationStack {
            DevicesView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                // #1027: same fix as quickScreen — Devices draws the full-bleed liquid sky, so a transparent
                // nav bar keeps it edge-to-edge instead of an opaque band clipping the top on scroll.
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showDevices = false }
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }

    /// - Parameter a11yLabel: what VoiceOver reads instead of `title`, for an item whose state the visible
    ///   label cannot carry (the Focus tab's "meditation still open" badge). `nil` = read the title.
    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int,
                              a11yLabel: LocalizedStringKey? = nil) -> some View {
        // Each primary tab gets its OWN NavigationStack so the in-content NavigationLinks (e.g. the Today
        // dashboard card rows) both navigate AND render opaque. An ORPHANED NavigationLink (no
        // NavigationStack ancestor) renders its whole label in a disabled/translucent state — that was
        // washing the Today cards over the hero scene and dimming their text to grey (2026-06-23).
        // The root view hides the system nav bar (each screen draws its own in-content header); pushed
        // detail screens get their own nav bar + back button. The stack is bound to the tab's path so a
        // re-tap of the active tab can pop it to the root (#135/#198); the roots' first-hop links push
        // TabRoute values, registered here ONCE per stack (a double registration double-pushes, #38).
        NavigationStack(path: path) {
            view
                // THE STRIP'S OWN ROOM. Inset HERE, on the tab's content, not on the TabView: each tab
                // is its own NavigationStack and lays its content out inside that, so an inset applied
                // to the TabView never reached the screen's scroll view — which is why the level bar
                // sat on top of every tab's heading.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: levelBarHeight)
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                .tabRouteDestinations()
        }
        // THE SYSTEM BAR IS HIDDEN for the whole stack (root and every pushed screen); the floating
        // `TelosTabBar` replaces it.
        .toolbar(.hidden, for: .tabBar)
        // THE FLOATING BAR'S ROOM, on the stack so every pushed screen gets it too: scroll content ends above
        // the bar (and still scrolls beneath it), bottom-pinned rows (the coach's input) sit above it. Drops
        // to zero while the keyboard is up, when the bar steps aside.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardVisible ? 0 : TelosTabBarMetrics.contentInset)
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        // ONE SHAPE, whatever `a11yLabel` is. The modifier is applied UNCONDITIONALLY and only its
        // ARGUMENT varies — the rule this file already states for `noopTabBarAutoHide`: a runtime
        // condition that selects between `_ConditionalContent` branches changes the view's identity, and
        // #519 is what that costs. `?? title` means the four tabs that pass nothing read exactly as before.
        .tabItem {
            Label(title, systemImage: icon)
                .accessibilityLabel(Text(a11yLabel ?? title))
        }
    }

    // The "More" tab is the app's catch-all index, on the shared page chrome: ScreenScaffold for the title +
    // subtitle, a small-caps overline per group, and the group's rows in ONE glass card with hairline
    // dividers (§5.8 / the reference family). Every existing row stays; 2.0 adds Goals, Look ahead, Habits
    // (Insights), the Lift plan (Body) and Strap cues (App).
    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refreshEverything() },
                           topBackground: liquidScaffoldSky()) {
                moreSection("Insights") {
                    // Routines head Insights: everything else on this list reports on the body, and
                    // this is the one row that says what the day around it looks like.
                    MoreRow("Routines", "clock.badge.checkmark", .routines)
                    // 2.0 (decisions 13 + 14): where the wearer is heading, and what they are aiming at.
                    MoreRow("Goals", "flag.checkered", .goals)
                    MoreRow("Look ahead", "chart.line.uptrend.xyaxis", .lookAhead)
                    // The Habits hub (decision 3: reached from More, Today and the Coach — not a tab).
                    MoreRow("Habits", "flask", .habits)
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                    MoreRow("Intelligence", "brain.head.profile", .intelligence)
                    // K3: Coach promoted to a top-level tab — no longer listed under More.
                    MoreRow("Insights", "lightbulb.fill", .insights)
                    MoreRow("Explore", "square.grid.2x2.fill", .explore)
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare, last: true)
                }
                moreSection("Body") {
                    MoreRow("Sleep", "bed.double.fill", .sleep)
                    MoreRow("Bedroom", "thermometer.medium", .bedroom)
                    MoreRow("Dream Journal", "moon.stars.fill", .dreamJournal)
                    MoreRow("Smart Lights", "lightbulb.2.fill", .smartLights)
                    MoreRow("Live", "waveform.path.ecg", .live)
                    MoreRow("Workouts", "figure.run", .workouts)
                    // Telos Lift's plan editor (decision 16). A SHEET, not a push: the editor owns its own
                    // NavigationStack.
                    MoreSheetRow("Lift plan", "dumbbell.fill") { showLiftPlan = true }
                    MoreRow("Health", "heart.text.square.fill", .health)
                    MoreRow("Lab Book", "books.vertical.fill", .labBook)
                    MoreRow("Stress", "bolt.heart.fill", .stress)
                    MoreRow("Breathe", "wind", .breathe)
                    MoreRow("Intervals", "timer", .intervals)
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    MoreRow("Rhythm", "waveform.path", .rhythm, last: true)
                }
                moreSection("Data") {
                    MoreRow("Your Data, Fused", "square.stack.3d.up.fill", .fusedRecord)
                    MoreRow("Apple Health", "heart.fill", .appleHealth)
                    MoreRow("Mi Band", "figure.walk.motion", .miBand)
                    MoreRow("Data Sources", "externaldrive.fill", .dataSources)
                    MoreRow("Backup & Sync", "externaldrive.fill.badge.icloud", .backupSync)
                    // #155: HealthKit-free Apple Health path for sideloaded installs (Siri Shortcut
                    // reads the opt-in Documents/noop_sync.txt drop file).
                    MoreRow("Shortcuts Export", "square.and.arrow.up.fill", .shortcutsExport)
                    // The plain 4.0 vs 5.0/MG capability grid — what NOOP reads live off each strap.
                    MoreRow("NOOP Limitations", "list.bullet.rectangle", .noopLimitations, last: true)
                }
                moreSection("App") {
                    // #805/#811: the v7.3.1 #766 alarm consolidation moved Smart Alarm under a single
                    // "Alarms" sidebar entry (RootView .smartAlarm) but the regression dropped the row
                    // from the iPhone More list, leaving Alarms unreachable on iPhone. Restore it here
                    // (route to SmartAlarmView, the cross-platform iOS/macOS surface).
                    //
                    // Notifications (RootView .notifications) is deliberately NOT added: that screen is
                    // macOS-only (it picks which Mac apps tap your wrist via NSWorkspace, imports AppKit,
                    // and project.yml excludes Screens/NotificationSettingsView.swift from the iOS target),
                    // so it can't compile or apply on iPhone. iPhone's wrist-alert controls live on the
                    // Automations screen instead. Its absence from the iPhone More list is correct.
                    MoreRow("Alarms", "alarm.fill", .alarms)
                    MoreRow("Automations", "wand.and.stars", .automations)
                    // The strap's purposeful vibrations (sitting break, rewards, penalties, timers).
                    MoreRow("Strap cues", "hand.tap.fill", .strapCues)
                    // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
                    // just buried in Settings, so the feedback loop is one tap from the More tab.
                    MoreRow("Test Centre", "stethoscope", .testCentre)
                    MoreRow("Siri & Shortcuts", "mic.fill", .siriShortcuts)
                    // #477 lives here rather than inside Settings: the strap-battery levers are the
                    // ones people reach for when a strap is running down, so they get their own row.
                    MoreRow("Power saving", "battery.25", .powerSaving)
                    MoreRow("Settings", "gearshape.fill", .settings, last: true)
                }
            }
            // The strip's own room, as in `tab(_:_:_:path:scrollSignal:)` — the More tab builds its own
            // stack rather than going through that helper, so it needs the same inset.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: levelBarHeight)
            }
            // The rows push MoreDestination VALUES so a re-tap of the More tab can pop them off the
            // bound path (#135/#198). Each destination keeps the per-screen wrapper the rows used to
            // apply inline (surfaceBase background, inline title bar, hidden bar background):
            // #1027 — a pushed sky-scaffold screen (Live, Workouts, Health, …) draws a full-bleed liquid
            // sky; an opaque surfaceBase nav-bar band sat over it and clipped the top on scroll. A hidden
            // bar background keeps the sky edge-to-edge. On the flat (no-sky) screens this is visually
            // identical at rest — the destination's own surfaceBase background shows through the bar.
            .navigationDestination(for: MoreDestination.self) { route in
                route.destination
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbar(.hidden, for: .tabBar)
            }
            .toolbar(.hidden, for: .tabBar)
        }
        // The system bar hidden for the whole stack, and the floating bar's room — as in `tab(...)`.
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: keyboardVisible ? 0 : TelosTabBarMetrics.contentInset)
        }
        // Scroll the More index to the top on an at-root re-tap (#198 follow-up); read by its ScreenScaffold.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label("More", systemImage: "ellipsis") }
    }

    /// One titled, COLLAPSIBLE group in the More index (S2): the app's overline (UPPERCASE) becomes a
    /// tappable header with a disclosure chevron; tapping it expands/collapses the grouped rows card.
    /// Insights + Body default open, Data + App default collapsed (the `expandedMoreSections` seed) so the
    /// list is shorter at rest without dropping a single row. The grouped card is unchanged: a single
    /// `NoopCard` holding a `VStack(spacing: 0)` whose `MoreRow`s draw their own hairlines, clipped to the
    /// card's rounded shape so the last divider is trimmed inside the corners. Same idiom Settings/Health use.
    @ViewBuilder
    private func moreSection<Rows: View>(_ title: String,
                                         @ViewBuilder rows: @escaping () -> Rows) -> some View {
        let isOpen = expandedMoreSections.contains(title)
        VStack(alignment: .leading, spacing: 10) {
            // Tappable overline header: the same ALL-CAPS tracked label as before, now with a trailing
            // chevron that rotates open. A plain Button (not a SwiftUI DisclosureGroup) so the header keeps
            // the exact strandOverline styling and the card layout below stays identical to before.
            Button {
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                    // Persist the toggle via the CSV-backed @AppStorage so the choice survives leaving and
                    // re-entering the More tab and relaunch (#860 item 2). MoreSectionPrefs owns encode/decode.
                    var open = expandedMoreSections
                    if isOpen { open.remove(title) } else { open.insert(title) }
                    expandedMoreSectionsCSV = MoreSectionPrefs.encode(open)
                }
            } label: {
                HStack(spacing: TelosSpace.s) {
                    // The label voice (small caps, +1.6 tracking). Allowed to wrap rather than truncate at
                    // large text sizes (the wide tracking makes a one-line cap clip first).
                    Text(title).strandOverline()
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: TelosSpace.s)
                    Image(systemName: "chevron.down")
                        .font(TelosType.glyphChevron)
                        .foregroundStyle(TelosColor.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isOpen ? String(localized: "Expanded") : String(localized: "Collapsed")))
            .accessibilityHint(Text(isOpen ? String(localized: "Double tap to collapse") : String(localized: "Double tap to expand")))

            if isOpen {
                // Zero internal padding so each MoreRow owns its own comfortable insets + height; the rows
                // supply their own hairline separators (drawn at the bottom of every row but the last via the
                // divider overlay) so the group reads as one continuous grouped list, matching Settings/Health.
                NoopCard(padding: 0) {
                    VStack(spacing: 0) { rows() }
                        // Clip the rows column to the card's rounded shape so the last row's bottom hairline is
                        // trimmed inside the corners (the card draws its surface in the BACKGROUND and doesn't
                        // clip content itself, so without this the final divider would run past the rounded edge).
                        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
                }
            }
        }
    }
}

/// Every screen the More index links to, as a `Hashable` value the tab's `NavigationPath` can carry
/// (#198): a closure-destination push would bypass the path and be un-poppable on tab re-tap. The
/// per-screen chrome the old inline links applied lives at the single `navigationDestination(for:)`
/// registration in `moreTab`.
private enum MoreDestination: Hashable {
    case insightsHub, intelligence, coach, insights, explore, compare
    case goals, lookAhead, habits
    case live, workouts, health, labBook, sleep, stress, breathe, intervals, rhythm
    case routines, bedroom, dreamJournal, smartLights
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, strapCues, testCentre, siriShortcuts, powerSaving, settings

    /// Main actor: some destinations read main-actor singletons (the strap-cue engine).
    @MainActor @ViewBuilder var destination: some View {
        switch self {
        // 2.0: Goals / Look ahead / Habits read the app model from the environment the app root injects.
        case .goals:           GoalsView()
        case .lookAhead:       LookAheadView()
        case .habits:          HabitsHubView()
        case .strapCues:       StrapCuesSettingsView(engine: StrapCueEngine.shared)
        case .insightsHub:     InsightsHubView()
        case .intelligence:    IntelligenceView()
        case .coach:           CoachView()
        case .insights:        InsightsView()
        case .explore:         MetricExplorerView()
        case .compare:         CompareView()
        case .live:            LiveView()
        case .workouts:        WorkoutsView()
        case .health:          HealthView()
        case .labBook:         LabBookView()
        // Sleep handed its tab slot to Focus, so it needs a row here — a screen this central must not
        // be reachable only as a link off another one.
        case .routines:        RoutinesView()
        case .bedroom:         BedroomClimateSettingsView()
        case .dreamJournal:    DreamJournalView()
        case .smartLights:     SmartLightsView()
        case .sleep:           SleepView()
        case .stress:          StressView()
        case .breathe:         BreathingView()
        case .intervals:       IntervalTimerView()
        case .rhythm:          RhythmHost()
        case .fusedRecord:     FusedRecordHost()
        case .appleHealth:     AppleHealthView()
        case .miBand:          XiaomiBandView()
        case .dataSources:     DataSourcesView()
        case .noopLimitations: NoopLimitationsView()
        case .backupSync:      BackupSyncView()
        case .shortcutsExport: ShortcutExportSettingsView()
        case .alarms:          SmartAlarmView()
        case .automations:     AutomationsView()
        case .testCentre:      TestCentreView()
        case .siriShortcuts:   SiriShortcutsSettingsView()
        case .powerSaving:     PowerSavingView()
        case .settings:        SettingsView()
        }
    }
}


/// One tappable destination row in the More index (§5.8): the 28 pt icon plate (the symbol pinned to the
/// accent explicitly — an inherited tint was re-resolved to the system blue a beat after first render, #184),
/// the title in `body`, a chevron; min height 52; a `lineSoft` divider inset to the title under every row
/// but the group's last. Pressed: the row fill steps to `surfaceInset`.
private struct MoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let route: MoreDestination
    let last: Bool

    init(_ title: LocalizedStringKey, _ icon: String, _ route: MoreDestination, last: Bool = false) {
        self.title = title; self.icon = icon; self.route = route; self.last = last
    }

    var body: some View {
        NavigationLink(value: route) {
            MoreRowLabel(title: title, icon: icon, last: last)
        }
        .buttonStyle(TelosRowButtonStyle())
    }
}

/// A More row that presents a sheet instead of pushing (the Lift plan editor owns its NavigationStack).
private struct MoreSheetRow: View {
    let title: LocalizedStringKey
    let icon: String
    let last: Bool
    let action: () -> Void

    init(_ title: LocalizedStringKey, _ icon: String, last: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.last = last; self.action = action
    }

    var body: some View {
        Button(action: action) {
            MoreRowLabel(title: title, icon: icon, last: last)
        }
        .buttonStyle(TelosRowButtonStyle())
    }
}

private struct MoreRowLabel: View {
    let title: LocalizedStringKey
    let icon: String
    let last: Bool

    var body: some View {
        TelosListRow(title, systemImage: icon, iconTint: TelosColor.mint, showsChevron: true)
            .overlay(alignment: .bottom) {
                if !last { TelosListDivider() }
            }
    }
}

// MARK: - Quick actions (centre FAB)

/// The destinations the centre FAB can present. `.menu` is the action sheet itself; the rest
/// route to existing screens. `Identifiable` so it drives `.sheet(item:)`.
private enum QuickAction: Int, Identifiable {
    case menu, live, workout, journal, breathe
    var id: Int { rawValue }
}

/// ONE SHEET FOR THE MENU AND WHAT IT OPENS.
///
/// Picking an action used to DISMISS the menu sheet and present a second one 50 ms later. UIKit will not
/// present over a sheet that is still animating away, so the second one waited out the whole dismissal
/// — the menu slid down, the screen sat there, and only then did the destination slide up. That wait is
/// what read as lag. The destination now replaces the menu inside the same sheet, which grows from the
/// menu's height to full height in one movement.
private struct QuickActionHost<Destination: View>: View {
    @State private var current: QuickAction
    @State private var detent: PresentationDetent
    let destination: (QuickAction) -> Destination

    private static var menuDetent: PresentationDetent { .height(344) }

    init(initial: QuickAction, @ViewBuilder destination: @escaping (QuickAction) -> Destination) {
        _current = State(initialValue: initial)
        _detent = State(initialValue: initial == .menu ? Self.menuDetent : .large)
        self.destination = destination
    }

    var body: some View {
        Group {
            if current == .menu {
                QuickActionSheet { picked in
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)) {
                        detent = .large
                        current = picked
                    }
                }
                .presentationDragIndicator(.hidden)
            } else {
                destination(current)
            }
        }
        .presentationDetents(current == .menu ? [Self.menuDetent] : [.large], selection: $detent)
    }
}

/// The bottom sheet of quick actions presented by the centre FAB. Spec bottom sheet: surfaceOverlay
/// fill, gold hairline top edge, grab handle, three flat action rows that route to existing screens.
private struct QuickActionSheet: View {
    /// Called with the picked destination (the host swaps the menu for that screen).
    let onPick: (QuickAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Grab handle (36×4) in the slate hairline tone.
            Capsule()
                .fill(StrandPalette.hairlineStrong)
                .frame(width: 36, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            Text("QUICK ACTIONS")
                .telosScale()
                .foregroundStyle(TelosColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                row("Live HR", icon: "waveform.path.ecg", tint: StrandPalette.metricRose) { onPick(.live) }
                row("Start workout", icon: "figure.run", tint: StrandPalette.effortColor) { onPick(.workout) }
                row("Log journal", icon: "square.and.pencil", tint: StrandPalette.accent) { onPick(.journal) }
                row("Breathe", icon: "wind", tint: StrandPalette.restColor) { onPick(.breathe) }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // §6.1: the rows sit on the solid canvas — no material, no hairline "gold" top edge.
        .background(TelosColor.canvas.ignoresSafeArea())
    }

    /// One flat action row: hued line-icon tile + title, inset surface, hairline border.
    private func row(_ title: LocalizedStringKey, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(StrandPalette.surfaceInset))
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(NoopPanelSurface(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif

/// #1841: apply the iOS 26 tab-bar minimise behaviour, doing nothing on older systems.
///
/// The availability branch is deliberately the ONLY branch. `RootTabView` already documents what happens
/// when a condition that flips at runtime wraps this `TabView`: #519 put two states in separate
/// `_ConditionalContent` branches, and every navigation rebuilt the whole subtree, resetting `@State`
/// inside the tab roots — scroll offsets, chart ranges, expanded sections.
///
/// So the preference must NOT select between branches. It selects the modifier's ARGUMENT, while the
/// availability check — fixed for the life of the process — is what picks a branch. Toggling the setting
/// changes a value, never the view's identity.
extension View {
    @ViewBuilder
    func noopTabBarAutoHide(_ enabled: Bool) -> some View {
        if #available(iOS 26.0, *) {
            // `.onScrollDown` minimises to a pill on downward scroll; `.never` pins it fully visible.
            self.tabBarMinimizeBehavior(enabled ? .onScrollDown : .never)
        } else {
            self
        }
    }
}
