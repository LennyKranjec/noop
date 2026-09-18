#if os(iOS)
import SwiftUI
import StrandDesign

/// iOS navigation shell. macOS uses a `NavigationSplitView` sidebar (`RootView`); on iPhone the
/// natural analogue is a `TabView` with the most-used screens as tabs and everything else under a
/// "More" list. Every screen is the same `StrandDesign`-built view the macOS app uses.
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

    @EnvironmentObject private var repo: Repository
    /// Cross-screen navigation requests (e.g. Live → "Manage devices"). Devices isn't a tab — it lives
    /// behind the More list — so a request presents it as a sheet, matching the quick-action screens.
    @EnvironmentObject private var router: NavRouter
    /// The scene-local receiver for actions chosen from NOOP's Home Screen icon menu.
    @EnvironmentObject private var homeScreenQuickActions: HomeScreenQuickActionSceneDelegate
    /// The coach, for the tab glyph's working state.
    @EnvironmentObject private var coach: AICoachEngine
    @Environment(\.scenePhase) private var scenePhase
    /// The morning flow — dream, the night's questions, the daily brief — on the day's first open.
    @State private var showMorning = false
    @ObservedObject private var stressMonitor = LiveStressMonitor.shared
    @ObservedObject private var dayAlerts = DayAlerts.shared
    /// The full-screen stress alarm. Separate from the pill in the level strip, which follows the live
    /// reading alone — ignoring the screen does not hide the pill.
    @State private var showStressScreen = false
    /// When the stress screen was last shown, so an ignored alarm does not come back two minutes later.
    @AppStorage("stress.alertScreen.shownAt") private var stressScreenShownAt: Double = 0
    /// Once an hour at most: often enough to catch a new spell, rarely enough not to nag through one.
    private static let stressScreenEvery: TimeInterval = 60 * 60
    @EnvironmentObject private var appModel: AppModel

    /// High stress AT REST: the monitor's reading when it is in the top third and no workout is running.
    /// The reading is motion-gated already; a workout in progress is exertion by definition, even when
    /// it is a still one like a plank.
    private var stressAlert: Double? {
        guard appModel.activeWorkout == nil, let level = stressMonitor.current,
              level >= LiveStressMonitor.highThreshold else { return nil }
        return level
    }
    /// The health store, for today's macros.
    @EnvironmentObject private var health: HealthKitBridge

    /// The level strip's own data. Owned by the shell because the strip rides above every tab.
    @StateObject private var levelBar = LevelBarModel()
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
    private var coachWorking: Bool { coach.isWorking }

    /// Bumped when a generation ENDS while the wearer is looking somewhere else. The edge, not the
    /// level: a flag would re-fire on every re-render.
    @State private var coachFinishedElsewhere = 0

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
        guard !showMorning, LevelDayFreeze.morningDue(), !backgroundCovered else { return }
        showMorning = true
    }

    /// Show the stress screen for a high reading, unless one was shown within the hour or the morning flow
    /// or another sheet is up.
    private func presentStressScreenIfDue() {
        guard stressAlert != nil, !showStressScreen, !showMorning, !backgroundCovered,
              Date().timeIntervalSince1970 - stressScreenShownAt > Self.stressScreenEvery else { return }
        stressScreenShownAt = Date().timeIntervalSince1970
        showStressScreen = true
    }

    /// Whether one of the shell's own sheets is up over the tabs.
    private var backgroundCovered: Bool {
        quickAction != nil || showDevices || routedPillar != nil || showLevelTimeline
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

    var body: some View {
        // The platform tab bar is intentionally left fully native. iOS 26 supplies Liquid Glass and
        // its dynamic interaction with scrolling content automatically; older supported releases use
        // the corresponding system material and safe-area behaviour from the same TabView.
        TabView(selection: nativeTabSelection) {
            // A SUN, not a grid. Today is the day you are in, and a grid glyph says "a page of tiles" —
            // which is what the screen is made of, not what it is for. The sun also pairs with the moon
            // the Sleep and level surfaces already use, so the two halves of a day read as a pair in the
            // bar. Matches the Android lane's `Icons.Filled.WbSunny`.
            tab(todayTabRoot, "Today", "sun.max", path: $tabPaths[0], scrollSignal: scrollTop[0]).tag(0)
            // Labelled Health, as on Android; the screen behind it is still Trends.
            tab(TrendsView(), "Health", "chart.line.uptrend.xyaxis", path: $tabPaths[1], scrollSignal: scrollTop[1]).tag(1)
            // FOCUS TOOK SLEEP'S SLOT, matching the Android bar. Sleep is not gone — it is reached from
            // the Health tab and from its own More row below — and Focus is the tab with something to do
            // on it, which is what earns a slot in a five-slot bar.
            tab(MindfulnessView(), "Focus", "figure.mind.and.body", path: $tabPaths[2], scrollSignal: scrollTop[2]).tag(2)
            // K3: Coach promoted to a top-level tab (was behind the More list). The sparkles icon
            // matches the More-tab row and the macOS sidebar entry.
            // THE GLYPH SAYS WHETHER THE SYSTEM IS WORKING. While a generation is in flight — the
            // visible chat OR any of the headless ones — the sparkles become a progress glyph, so a
            // wearer on another tab can see that something is being written. The platform tab bar owns
            // its own item, so this is a glyph swap rather than the Android lane's spinner-in-the-slot;
            // it lands in the same place and says the same thing.
            tab(CoachView(), "System", coachWorking ? "circle.dotted" : "sparkles",
                path: $tabPaths[3], scrollSignal: scrollTop[3])
                .tag(3)
                // THE POP IS A NOTIFICATION, and it only fires for somebody who cannot see the answer
                // arrive: on the System tab itself the reply is right there filling the screen, and a
                // bouncing icon underneath it would be telling you something you are already reading.
                .symbolEffectPopCompat(trigger: coachFinishedElsewhere)
            moreTab(path: $tabPaths[4], scrollSignal: scrollTop[4]).tag(4)
        }
        .tint(StrandPalette.accent)
        // THE TABS BEHIND A SHEET STAND STILL. Applied here, on the TabView itself, so it reaches every
        // tab root and none of the sheets below — they are attached further out and do not inherit it.
        .environment(\.noopBackgroundCovered, backgroundCovered)
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
        .task(id: repo.refreshSeq) {
            await levelBar.refresh(repo: repo, tick: repo.refreshSeq)
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
        .noopTabBarAutoHide(bottomBarAutoHide)
            // Tab crossfade — README §Motion: ~240ms opacity swap between tab roots, global calm
            // easing cubic-bezier(0.22,1,0.36,1).
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)
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
            MorningFlowView(levelBar: levelBar) { showMorning = false }
        }
        .onAppear { presentMorningIfDue() }
        // THE STRESS ALARM, full screen, when the live reading turns high — on opening, on a refresh, or
        // mid-session. The same diagnostic look as a failed quest, with a way out that helps and one that
        // does not.
        .overlay {
            if showStressScreen, let level = stressAlert {
                DiagnosticAlertView(
                    overline: "STRESS ALERT",
                    symbol: "bolt.heart",
                    title: "High stress",
                    subtitle: String(format: "%.1f of 3, at rest", level),
                    message: "Your last ten minutes read high while you were still. A few minutes of slow breathing is the fastest way down.",
                    primary: ("BREATHE", {
                        showStressScreen = false
                        quickAction = .breathe
                    }),
                    secondary: ("IGNORE", { showStressScreen = false }))
                .transition(.opacity)
                .task { SystemHaptics.play(.summon) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: showStressScreen)
        // THE DAY'S OPTIMUM, reached: the effort the night's recovery can carry has been spent.
        .overlay {
            if let optimum = dayAlerts.optimum {
                DiagnosticAlertView(
                    overline: "SYSTEM DIAGNOSTICS",
                    symbol: "battery.25percent",
                    title: "Optimum reached",
                    subtitle: "Effort \(optimum.effort) of \(optimum.target) recommended",
                    message: "Today's load has reached what last night's recovery can carry. Anything more now is paid for tomorrow: keep the rest of the day easy and get to bed on time.",
                    primary: ("UNDERSTOOD", { dayAlerts.dismissOptimum() }),
                    ringed: true)
                .transition(.opacity)
                .task { SystemHaptics.play(.summon) }
            }
        }
        .animation(.easeOut(duration: 0.25), value: dayAlerts.optimum)
        .onChange(of: stressAlert != nil) { _, high in
            if high { presentStressScreenIfDue() } else { showStressScreen = false }
        }
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
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 3 }
                router.requestedDestination = nil
            case .trends:
                // Trends is a primary tab on iPhone (not a pillar sheet) — switch to it.
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 1 }
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
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) { selectedTab = 0 }
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

    private func tab<V: View>(_ view: V, _ title: LocalizedStringKey, _ icon: String,
                              path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
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
                .tabRouteDestinations()
        }
        // Drive this tab's root scroll-to-top on an at-root re-tap (#198 follow-up); read by ScreenScaffold
        // / LiquidTodayView inside. Only THIS tab's token changes on its reselect, so the others don't scroll.
        .environment(\.scrollToTopSignal, scrollSignal)
        .tabItem { Label(title, systemImage: icon) }
    }

    // The "More" tab is the app's catch-all index. It was a plain SwiftUI `List` with system large-title
    // + system title-case section headers, so it didn't match any other page (which all use ScreenScaffold
    // + SectionHeader's UPPERCASE overline + the 28pt section rhythm). Rebuilt on the shared page chrome:
    // ScreenScaffold for the title1 "More" + subtitle, a `SectionHeader` overline per group, and the group's
    // rows in a single grouped NoopCard with hairline dividers — the same row idiom Settings/Health use.
    private func moreTab(path: Binding<NavigationPath>, scrollSignal: Int) -> some View {
        NavigationStack(path: path) {
            ScreenScaffold(title: "More", subtitle: "Everything else, one tap away",
                           onRefresh: { await repo.refreshEverything() },
                           topBackground: liquidScaffoldSky()) {
                moreSection("Insights") {
                    // Routines head Insights: everything else on this list reports on the body, and
                    // this is the one row that says what the day around it looks like.
                    MoreRow("Routines", "clock.badge.checkmark", .routines)
                    MoreRow("What Moves You", "wand.and.sparkles", .insightsHub)
                    MoreRow("Intelligence", "brain.head.profile", .intelligence)
                    // K3: Coach promoted to a top-level tab — no longer listed under More.
                    MoreRow("Insights", "lightbulb.fill", .insights)
                    MoreRow("Explore", "square.grid.2x2.fill", .explore)
                    MoreRow("Compare", "rectangle.split.2x1.fill", .compare)
                }
                moreSection("Body") {
                    MoreRow("Sleep", "bed.double.fill", .sleep)
                    MoreRow("Bedroom", "thermometer.medium", .bedroom)
                    MoreRow("Dream Journal", "moon.stars.fill", .dreamJournal)
                    MoreRow("Smart Lights", "lightbulb.2.fill", .smartLights)
                    MoreRow("Live", "waveform.path.ecg", .live)
                    MoreRow("Workouts", "figure.run", .workouts)
                    MoreRow("Health", "heart.text.square.fill", .health)
                    MoreRow("Lab Book", "books.vertical.fill", .labBook)
                    MoreRow("Stress", "bolt.heart.fill", .stress)
                    MoreRow("Breathe", "wind", .breathe)
                    MoreRow("Intervals", "timer", .intervals)
                    // Experimental beat-to-beat regularity visualization — self-gates on its own consent.
                    MoreRow("Rhythm", "waveform.path", .rhythm)
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
                    MoreRow("NOOP Limitations", "list.bullet.rectangle", .noopLimitations)
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
                    // The Test Centre (the diagnostics + bug-report hub) gets a first-class home here, not
                    // just buried in Settings, so the feedback loop is one tap from the More tab.
                    MoreRow("Test Centre", "stethoscope", .testCentre)
                    MoreRow("Siri & Shortcuts", "mic.fill", .siriShortcuts)
                    // #477 lives here rather than inside Settings: the strap-battery levers are the
                    // ones people reach for when a strap is running down, so they get their own row.
                    MoreRow("Power saving", "battery.25", .powerSaving)
                    MoreRow("Settings", "gearshape.fill", .settings)
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
            }
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
                HStack(spacing: 6) {
                    Text(title).strandOverline()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    case live, workouts, health, labBook, sleep, stress, breathe, intervals, rhythm
    case routines, bedroom, dreamJournal, smartLights
    case fusedRecord, appleHealth, miBand, dataSources, backupSync, shortcutsExport, noopLimitations
    case alarms, automations, testCentre, siriShortcuts, powerSaving, settings

    @ViewBuilder var destination: some View {
        switch self {
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


/// One tappable destination row in the More index. A `NavigationLink` whose label is the standard app row:
/// the SF Symbol icon tinted `StrandPalette.accent`, the title in the body text colour, a `Spacer`, and a
/// trailing `chevron.right` in `textTertiary`. ~44pt min height + the card's row insets keep the whole row a
/// comfortable tap target.
private struct MoreRow: View {
    let title: LocalizedStringKey
    let icon: String
    let route: MoreDestination

    init(_ title: LocalizedStringKey, _ icon: String, _ route: MoreDestination) {
        self.title = title; self.icon = icon; self.route = route
    }

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 14) {
                // Pin the icon to the accent explicitly. A plain inherited tint gets re-resolved by iOS to
                // its default blue a beat after first render — so the icons flashed green→blue (#184). The
                // explicit foregroundStyle on the image overrides that; the title keeps the primary colour.
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 26, alignment: .center)
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Hairline under every row; the grouped container clips the last one's overflow so the bottom
            // edge stays clean (the divider sits inside the card's rounded corners).
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
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
                .font(StrandFont.overline)
                .tracking(1.6)
                .foregroundStyle(StrandPalette.textTertiary)
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
        .background(
            NoopChromeSurface()
                .overlay(alignment: .top) {
                    // Gold hairline top edge per the bottom-sheet spec.
                    Rectangle()
                        .fill(StrandPalette.gold.opacity(0.35))
                        .frame(height: 1)
                }
                .ignoresSafeArea()
        )
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

// MARK: - The finished-generation pop

private extension View {
    /// Bounce a symbol once when `trigger` changes, where the OS can do it.
    ///
    /// `symbolEffect(.bounce, value:)` is iOS 17; below that the glyph simply does not bounce, which is
    /// the correct degradation — the swap to and from the progress glyph already carries the state, and
    /// the bounce is the flourish on top of it.
    @ViewBuilder
    func symbolEffectPopCompat(trigger: Int) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.bounce, value: trigger)
        } else {
            self
        }
    }
}
