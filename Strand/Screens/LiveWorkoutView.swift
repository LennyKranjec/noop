import SwiftUI
import Combine
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
///
/// TELOS 2.0 (DESIGN_V2 §6.7, the "Training Coach" reference). Top to bottom:
///   - the Telos Lift logger (strength sports only — decision 16), unchanged in behaviour;
///   - the hero glass panel: a luminous ZONE DIAL (the five zone arcs in the HR-zone ramp, the current
///     zone lit, a caret at the live bpm) with the heart rate as the big numeral in the zone's colour,
///     and the session's Effort as a thin `TelosRing` beside it; the LIVE status pill above;
///   - compact glass tiles: AVG · PEAK · DAY / TARGET, "—" until the session has a reading (the old
///     `?? 0` into this card is gone), with the day-vs-ceiling bar under them;
///   - HR ZONE: the zone scale (5-band bar, caret at the live bpm) and the five 44 pt lock chips;
///   - the HR-since-start trace (collapsed by default), GPS distance / pace, sensor read-outs (leaves);
///   - an OPAQUE `surface` band pinned to the bottom safe area holding the controls (delete · pause ·
///     elapsed · end) — glass role 3 on iOS 26, the solid fallback everywhere else. No `Material`.
///
/// ZONE LOCK: the HR ZONE block carries a zone slider and five lock chips. A locked zone is stored on
/// `ActiveWorkout.lockedZone`; the strap cueing itself lives in `AppModel.evaluateZoneGuidance`, so it
/// keeps running with this screen closed.
///
/// PERFORMANCE (§2.1 rule 5 — the owner reports lag on an iPhone 12 Pro). `AppModel` publishes at 1 Hz
/// while a strap streams AND rewrites `activeWorkout` every second of a workout. This parent does NOT
/// observe it: it holds the model through the non-observing `\.appModelRef` and takes its ONE
/// invalidation from `LiveWorkoutCoarse` — the few coarse workout fields the layout gates on
/// (active, start, sport, paused), de-duplicated into `@State`. The per-second values are read ONLY in
/// small leaves (`LiveWorkoutHero`, `LiveZoneSection`, `SessionSummaryCard`, `LiveHRTraceLeaf`), so a
/// heartbeat re-renders those leaves and never the Lift logger, the bottom band or the scroll column.
/// The trace chart is additionally throttled to one redraw per 5 samples while expanded.
///
/// MOTION: the zone caret and the Effort arc settle on a new reading (`TelosMotion.settle`, ≈0.45 s,
/// then rest); the LIVE dot is the one loop, gated by `TelosMotion.liveLoop` (Reduce Motion / Low Power /
/// "Reduce motion in NOOP" → a still dot). Nothing else loops; the backdrop is the plain canvas.
struct LiveWorkoutView: View {
    /// NOT observed (see PERFORMANCE above). Actions and one-shot reads go through `model`.
    @Environment(\.appModelRef) private var modelRef
    private var model: AppModel { requireAppModel(modelRef) }
    /// The parent's sole invalidation driver from the model — fed by the de-duplicated `.onReceive` below.
    @State private var coarseState: LiveWorkoutCoarse?
    /// The published snapshot once it landed, otherwise read straight off the model (first body pass).
    private var coarse: LiveWorkoutCoarse { coarseState ?? LiveWorkoutCoarse(model.activeWorkout) }

    let onClose: () -> Void

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the destructive End action behind a confirm (#517) — a stray tap on the compact exit
    /// control must not end the workout instantly with no way back.
    @State private var showEndConfirm = false
    @State private var showDeleteConfirm = false

    // TELOS LIFT (DESIGN_V2 decision 16). A strength sport opens the in-app logger INSIDE this screen, above the
    // live HR / zone / Effort blocks, which keep running underneath. The finish screen then replaces the whole
    // screen in place (decision 7: no cover of its own). Everything lift-specific lives in `Screens/Lift/*` and
    // `Data/LiftSessionRecorder.swift`; these few hooks only host it.
    @ObservedObject private var lift = LiftSessionRecorder.shared
    @ObservedObject private var liftPrograms = LiftProgramStore.shared
    @Environment(\.scenePhase) private var scenePhase

    private var isLift: Bool {
        #if os(iOS)
        return LiftSessionRecorder.isStrengthSport(coarse.sport)
        #else
        return false
        #endif
    }

    var body: some View {
        #if os(iOS)
        if lift.phase == .finished, let summary = lift.summary, let session = lift.session {
            LiftFinishView(summary: summary, session: session) {
                lift.reset()
                onClose()
            }
        } else {
            workoutBody
        }
        #else
        workoutBody
        #endif
    }

    /// Finish the lift (unchecked sets → not done), then end the workout. In THAT order: ending the workout
    /// first would clear `activeWorkout` while the logger is still up, and the close-on-end hook would tear the
    /// screen down before the finish screen could show.
    private func finishLift() {
        Task {
            await lift.finish()
            model.endWorkout()
        }
    }

    private var workoutBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TelosSpace.cardGap) {
                #if os(iOS)
                if isLift {
                    LiftLoggerView(recorder: lift, programs: liftPrograms, onFinish: finishLift)
                }
                #endif
                // Listed directly (not an [AnyView] walked by a ForEach): SwiftUI keeps each card's static
                // type, so it can diff them instead of rebuilding type-erased boxes on every live tick.
                LiveWorkoutHero(isPaused: coarse.isPaused).staggeredAppear(index: 0)
                // AVG / PEAK plus today's Effort against the day's recommended ceiling — the SAME two
                // shared resolutions Today's hero ring and the lock-screen strip read (`todayEffortNow` /
                // `todayEffortTarget`), so a session can be paced against the whole day without this
                // screen ever printing a day figure the other surfaces disagree with.
                SessionSummaryCard().staggeredAppear(index: 1)
                LiveZoneSection().staggeredAppear(index: 2)
                // The whole session's HR since start against the zone lines (dashed), with a locked
                // zone's band raised — the history the zone slider above shows only the latest point of.
                // Collapsed by default; the disclosure state is remembered across sessions.
                LiveHRTraceLeaf().staggeredAppear(index: 3)
                // Live GPS distance + pace (#1195) — a self-gating leaf owning its own recorder
                // observation, so a GPS fix re-renders only this line. Renders nothing until the first
                // accepted fix, so non-GPS / denied sessions leave the stack unchanged.
                DistancePaceRowIfPresent(recorder: model.gpsRecorder).staggeredAppear(index: 4)
                // Live-observing leaf: renders the sensor line (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / zone rail above (scroll-stutter isolation).
                SensorRowIfPresent()
            }
            .padding(.horizontal, TelosSpace.pageGutter)
            .padding(.top, TelosSpace.m)
            // The bottom band is a `.safeAreaInset`, so the scroll view ALREADY reserves the band's full
            // height (plus the home-indicator inset) below the content — this is only optical breathing
            // room above it, not the clearance itself.
            .padding(.bottom, TelosSpace.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
        // tracker, up for the whole workout, so worth the same defensive fix.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // The controls sit in the bottom safe area so the scroll content never owns the chrome and the
        // controls can never scroll out of reach (one-handed: everything tappable mid-set is at the
        // bottom). `safeAreaInset(edge: .bottom)` lays the band out INSIDE the bottom safe area and
        // shrinks the ScrollView's safe area by its height, so content never hides behind it.
        //
        // §4.9 role 3: the glass controls sit on an OPAQUE `surface` band, never over the scrolling cards,
        // so iOS 26's glass never re-samples moving content every frame.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: TelosSpace.s) {
                #if os(iOS)
                if isLift { LiftRestTimerPill(recorder: lift) }
                #endif
                bottomControlRow
            }
            .padding(.top, TelosSpace.s)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                TelosColor.surface
                    .overlay(alignment: .top) {
                        Rectangle().fill(TelosColor.line).frame(height: TelosStroke.line)
                    }
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        // Plain canvas behind the whole in-exercise screen (§6.7: `ScenicHeroBackground` goes). Static.
        .background {
            TelosColor.canvas.ignoresSafeArea()
        }
        // THE PARENT'S ONE SUBSCRIPTION to the model. The `!=` guard is load-bearing: the publisher is
        // rebuilt on every body pass, SwiftUI re-subscribes and a fresh `removeDuplicates()` replays the
        // current value — writing `@State` on each replay would be a render loop (the LiveView pattern).
        .onReceive(LiveWorkoutCoarse.publisher(model)) { next in
            if coarseState != next { coarseState = next }
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: coarse.active) { active in if !active && lift.phase != .finished { onClose() } }
        // Attach the lift logger to this workout (idempotent), with today's Charge and the week plan's easy-week
        // flag for the progression proposal.
        .task(id: coarse.start) {
            guard isLift, let start = model.activeWorkout?.start else { return }
            let repo = model.repo
            let todayKey = Repository.localDayKey(Date())
            await lift.attach(workoutStart: start,
                              storeProvider: { await repo.storeHandle() },
                              charge: repo.days.first { $0.day == todayKey }?.recovery,
                              holdLoads: WeekPlanSource.shared.currentPlan?.strength.holdLoads ?? false)
        }
        // The rest timer's local-notification backup is armed only while the app is in the background.
        .onChangeCompat(of: scenePhase == .background) { background in
            if isLift { lift.sceneDidChange(background: background) }
        }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            let seeded = LiveWorkoutCoarse(model.activeWorkout)
            if coarseState != seeded { coarseState = seeded }
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
            ScreenIdle.keepAwake(false)
        }
        // Confirm before ending (#517): ending still requires an explicit confirm so a stray tap on the
        // compact exit control cannot discard the in-progress recording with no way back.
        .alert("End this workout?",
               isPresented: $showEndConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("End", role: .destructive) {
                if isLift, lift.session != nil {
                    // Ending a strength workout IS finishing the lift: unchecked sets are recorded as not
                    // done and the finish screen shows.
                    finishLift()
                } else {
                    model.endWorkout()
                    onClose()
                }
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
        .confirmationDialog("Delete", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if isLift { lift.discard() }
                model.discardWorkout()
                onClose()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Bottom controls (on the opaque band)

    /// Diameter of the ICON FRAME inside each control circle.
    ///
    /// On iOS 26 `nativeLiquidGlassWorkoutControl` resolves to `.buttonStyle(.glass)`, which adds its OWN
    /// metrics-driven padding AROUND the label — at `.large` a 56 pt label occupied roughly 90 pt and the
    /// row overflowed. 46 at `.regular` lands each control near 64 pt, which fits with the clock intact.
    /// 46 (not 44) because the tap shape is a CIRCLE inscribed in this square — a 44 pt frame would put
    /// the circle's usable width under the 44 pt minimum at the top and bottom of the glyph.
    private static let bottomControlDiameter: CGFloat = 46

    /// discard · pause · elapsed · end, laid out in ONE HStack so the timer and the controls cannot
    /// overlap (#1068 / #1533: a ZStack-centred clock once slid under the pause button and read as a
    /// second timer). The clock sits centred in the space the buttons leave; its layout priority is -1 so
    /// the buttons are sized first unconditionally and the clock scales into whatever is left.
    private var bottomControlRow: some View {
        HStack(spacing: TelosSpace.s) {
            deleteWorkoutGlassButton
            pauseWorkoutGlassButton
            bottomElapsedTimer
                .allowsHitTesting(false)
                // Scaling down is the honest failure when the room runs out: truncating a clock to
                // "1:30:0" would be worse than a smaller one.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // NEVER raise the timer's priority — a clipped control is the failure this layout exists
                // to remove (see the type comment).
                .layoutPriority(-1)
            endWorkoutGlassButton
        }
        .padding(.horizontal, TelosSpace.pageGutter)
        // Clearance ABOVE the home indicator on top of the safe-area inset; on a device with NO home
        // indicator it is the ONLY gap between the controls and the screen edge.
        .padding(.bottom, TelosSpace.m)
    }

    /// The screen's ONLY elapsed clock, from the pause-aware `activeWorkout.elapsed()` read at each 1 s
    /// tick (a periodic clock, not a frame loop). Read through the non-observing model reference, so the
    /// tick re-renders this `Text` alone.
    private var bottomElapsedTimer: some View {
        Group {
            if coarse.active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds: TimeInterval = model.activeWorkout?.elapsed() ?? 0
                    Text(Self.elapsed(seconds: seconds))
                        .telosNumeral(.numeralM)
                        .foregroundStyle(coarse.isPaused ? TelosColor.textSecondary : TelosColor.textPrimary)
                        .contentTransition(.numericText())
                        .accessibilityLabel(Text("Elapsed time"))
                        .accessibilityValue(Text(Self.elapsed(seconds: seconds)))
                }
            }
        }
        // minWidth 0 so the clock is allowed to give up ALL of its width to the controls rather than
        // insisting on an ideal size the row cannot pay for.
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var endWorkoutGlassButton: some View {
        Button { showEndConfirm = true } label: {
            Image(systemName: "xmark")
                .font(TelosType.glyphControl)
                .foregroundStyle(TelosColor.textPrimary)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("End workout"))
        .accessibilityHint(Text("Stops recording and saves what's captured so far"))
    }

    private var pauseWorkoutGlassButton: some View {
        let paused = coarse.isPaused
        return Button {
            TelosHaptics.play(.select)
            model.toggleWorkoutPause()
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(TelosType.glyphControl)
                .foregroundStyle(paused ? TelosColor.mint : TelosColor.textPrimary)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text(paused ? "Resume" : "Pause"))
    }

    private var deleteWorkoutGlassButton: some View {
        Button { showDeleteConfirm = true } label: {
            Image(systemName: "trash")
                .font(TelosType.glyphControl)
                .foregroundStyle(TelosColor.critical)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("Delete"))
    }

    private var activeSportName: String {
        coarse.sport ?? WorkoutCatalog.defaultSportName
    }

    private var workoutTypeGlassButton: some View {
        Button {
            // Placeholder — sport-type picker lands later; chrome and sizing stay put.
        } label: {
            WorkoutTypeIcon(workoutType: activeSportName, size: 20, weight: .semibold)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("\(WorkoutSource.displaySport(activeSportName)) workout"))
    }

    // MARK: - Helpers

    /// Delegates to the shared clock (hour roll-over "1:30:00", matching Android and the Today card).
    fileprivate static func elapsed(seconds: TimeInterval) -> String {
        ActiveWorkoutClock.clock(Int(seconds))
    }

    fileprivate static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }

    /// The zone's ramp colour, or the Effort hue below zone 1 / without a reading.
    fileprivate static func zoneTint(_ zone: Int) -> Color {
        zone >= 1 ? StrandPalette.hrZoneColor(zone) : TelosColor.effort
    }
}

// MARK: - Coarse snapshot (the parent's only model-driven invalidation)

/// The workout fields the parent's LAYOUT gates on. `activeWorkout` is rewritten every second of a
/// workout (new sample, new live Effort); none of that reaches the parent because these four fields do
/// not change per sample, and `removeDuplicates()` drops the 1 Hz rewrites before they reach `@State`.
struct LiveWorkoutCoarse: Equatable {
    var active: Bool
    var start: Date?
    var sport: String?
    var isPaused: Bool

    init(_ w: AppModel.ActiveWorkout?) {
        active = w != nil
        start = w?.start
        sport = w?.sport
        isPaused = w?.isPaused ?? false
    }

    @MainActor
    static func publisher(_ model: AppModel) -> AnyPublisher<LiveWorkoutCoarse, Never> {
        model.$activeWorkout
            .map { LiveWorkoutCoarse($0) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}

// MARK: - Controls chrome (glass role 3)

private extension View {
    /// Platform-owned circular chrome for the live-workout controls. iOS 26 uses the interactive Liquid
    /// Glass button (through the `nativeLiquidGlass*` family); everywhere else the ONE solid fallback
    /// (`nativeLiquidGlassFallbackSurface`: `surfaceRaised` + 1 pt `line`) — no material, no blur.
    ///
    /// `.regular`, not `.large`: the glass style's padding is driven by the control size and is added
    /// AROUND the 46 pt label, so `.large` inflated each control to ~90 pt and overflowed the bar.
    @ViewBuilder
    func nativeLiquidGlassWorkoutControl() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .regular) {
            self
                .buttonStyle(TelosPressButtonStyle())
                .nativeLiquidGlassFallbackSurface(Circle())
        }
    }
}

// MARK: - LIVE dot

/// The heart-coloured LIVE dot. Its breathing is the ONE loop on this screen, and only while the session
/// is actually recording with a reading: `TelosMotion.liveLoop(poseStill:)` returns nil (a still dot)
/// under Reduce Motion / Low Power / "Reduce motion in NOOP", and when paused or waiting for the strap.
/// Cost: one 7 pt circle's opacity, 2 s half-cycle.
private struct LiveWorkoutDot: View {
    let live: Bool
    @State private var dimmed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared
    private var looping: Bool { live && !motion.poseStill(reduceMotion) }

    var body: some View {
        Circle()
            .fill(live ? TelosColor.heart : TelosColor.textTertiary)
            .frame(width: 7, height: 7)
            .opacity(dimmed ? 0.35 : 1)
            .animation(TelosMotion.liveLoop(poseStill: !looping), value: dimmed)
            .onAppear { dimmed = looping }
            .onChangeCompat(of: looping) { active in dimmed = active }
            .accessibilityHidden(true)
    }
}

// MARK: - Hero (leaf: observes the model)

/// The status pill + the luminous zone dial holding the live heart rate + the session's Effort ring.
/// A LEAF: it owns the 1 Hz `AppModel` observation, so a heartbeat re-renders this panel and nothing
/// above or below it.
private struct LiveWorkoutHero: View {
    @EnvironmentObject private var model: AppModel
    let isPaused: Bool

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let dialDiameter: CGFloat = 184
    private static let effortDiameter: CGFloat = 96

    var body: some View {
        let zoneSet = model.profile.hrZoneSet
        let bpm = model.bpm
        let zone = bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0
        let tint = LiveWorkoutView.zoneTint(zone)
        return VStack(alignment: .leading, spacing: TelosSpace.m) {
            statusPill(hasReading: bpm != nil)
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    // AX sizes: stack, so neither the heart rate nor Effort has to shrink.
                    VStack(spacing: TelosSpace.l) {
                        dial(zoneSet: zoneSet, bpm: bpm, zone: zone, tint: tint)
                        effortColumn
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .center, spacing: TelosSpace.m) {
                        dial(zoneSet: zoneSet, bpm: bpm, zone: zone, tint: tint)
                        Spacer(minLength: 0)
                        effortColumn
                    }
                }
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .topLeading) {
                FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card)
                // The zone's bioluminescence behind the dial: ONE static radial gradient (no blur, no
                // shadow); it only changes colour when the zone changes.
                TelosRadialGlow(color: tint, intensity: 0.20, radius: Self.dialDiameter * 0.7)
                    .frame(width: Self.dialDiameter * 1.4, height: Self.dialDiameter * 1.4)
                    .offset(x: -Self.dialDiameter * 0.1, y: TelosSpace.l)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: TelosRadius.card, style: .continuous))
    }

    private func statusPill(hasReading: Bool) -> some View {
        let ink = isPaused ? TelosColor.textSecondary : TelosColor.heartInk
        let title: Text = isPaused ? Text("Paused") : Text("Recording workout")
        return HStack(spacing: TelosSpace.xs) {
            LiveWorkoutDot(live: !isPaused && hasReading)
            title
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(ink)
                .lineLimit(1)
        }
        .padding(.horizontal, TelosSpace.s)
        .padding(.vertical, TelosSpace.xxs)
        .frame(minHeight: 22)
        .background(Capsule(style: .continuous).fill(ink.opacity(TelosOpacity.wash)))
        .overlay(Capsule(style: .continuous).strokeBorder(ink.opacity(TelosOpacity.border), lineWidth: TelosStroke.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }

    private func dial(zoneSet: HRZoneSet, bpm: Int?, zone: Int, tint: Color) -> some View {
        ZStack {
            LiveZoneDial(zoneSet: zoneSet, bpm: bpm, currentZone: zone)
            VStack(spacing: TelosSpace.xxs) {
                Text("HEART RATE")
                    .telosScale()
                    .foregroundStyle(TelosColor.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let bpm {
                    HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xxs) {
                        Text(verbatim: "\(bpm)")
                            .telosNumeral(.geometryBound(size: 54, cap: 1.2))
                            .foregroundStyle(tint)
                            .contentTransition(.numericText())
                        Text("bpm")
                            .font(TelosType.scale)
                            .foregroundStyle(TelosColor.textSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    Text(zone >= 1 ? "Zone \(zone) · \(LiveWorkoutView.zoneName(zone))" : "Below Zone 1")
                        .telosScale()
                        .textCase(.uppercase)
                        .foregroundStyle(zone >= 1 ? tint : TelosColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else {
                    // Absent input abstains — the dash and the existing reason, never a stand-in number.
                    Text(verbatim: TelosType.absent)
                        .telosNumeral(.geometryBound(size: 54, cap: 1.2))
                        .foregroundStyle(TelosColor.textTertiary)
                    Text("Waiting for the strap")
                        .font(TelosType.footnote)
                        .foregroundStyle(TelosColor.textTertiary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: Self.dialDiameter * 0.66)
        }
        .frame(width: Self.dialDiameter, height: Self.dialDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate"))
        .accessibilityValue(Text(heartRateAccessibilityValue(bpm: bpm, zone: zone)))
    }

    /// Spoken HR. Absent input abstains — "No heart rate", never a stand-in number.
    private func heartRateAccessibilityValue(bpm: Int?, zone: Int) -> String {
        guard let bpm else { return String(localized: "No heart rate") }
        return zone >= 1 ? String(localized: "Zone \(zone), \(bpm) bpm")
                         : String(localized: "Below Zone 1, \(bpm) bpm")
    }

    /// Live Effort — the same `liveStrain` / Effort-scale conversion and `StrainGauge` intensity word as
    /// every other surface, as a thin luminous ring (one lap = the scale's top, so a value past it wraps
    /// instead of clipping). "—" until the session has its first sample: a zero arc would claim a
    /// measured zero.
    ///
    /// No target caret on this ring on purpose: the day's recommended ceiling is on the DAY axis and this
    /// ring is the SESSION's own Effort; the ceiling is drawn where both share an axis (the DAY / TARGET
    /// tile and its bar below).
    private var effortColumn: some View {
        let w = model.activeWorkout
        let hasSamples: Bool = !(w?.samples.isEmpty ?? true)
        let strain: Double? = hasSamples ? w?.liveStrain : nil
        let displayEffort: Double? = strain.map { UnitFormatter.effortValue($0, scale: effortScale) }
        let maxValue: Double = effortScale == .whoop ? 21.0 : 100.0
        // The intensity word exists only for a real reading (no word is ever derived from a stand-in 0).
        let state: String? = displayEffort.map { StrainGauge.stateLabel(forFraction: min(max($0 / maxValue, 0), 1)) }
        let format: (Double) -> String = effortScale == .whoop ? TelosFormat.decimal(1) : TelosFormat.integer
        let scaleCaption = String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
        let axLabel = "\(String(localized: "Effort")) \(scaleCaption)"
        return VStack(spacing: TelosSpace.xs) {
            TelosRing(value: displayEffort,
                      scale: maxValue,
                      color: TelosColor.effort,
                      diameter: Self.effortDiameter,
                      format: format,
                      caption: state.map { Text($0) },
                      captionColor: TelosColor.effortInk,
                      accessibilityLabel: Text(verbatim: axLabel))
            Text("EFFORT BUILDING")
                .telosScale()
                .foregroundStyle(TelosColor.effortInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(minWidth: Self.effortDiameter)
    }
}

// MARK: - Zone dial

/// The luminous zone dial (the Training Coach reference's ring): an open 270° gauge from zone 1's floor
/// to HRmax, each zone an arc of its TRUE bpm span in the HR-zone ramp (data ramp, unchanged) — the
/// current zone lit at full strength with one faint halo stroke, the rest at 0.35 — and a caret dot at
/// the live bpm. No reading: the arcs stay dim and no caret is drawn.
///
/// Cost (§2.1 rule 8): shapes only — no Canvas, no clock, no blur. The caret SETTLES to a new reading
/// (`TelosMotion.settle`, ≈0.45 s, then rest); under Reduce Motion / quiet motion it jumps.
private struct LiveZoneDial: View {
    let zoneSet: HRZoneSet
    let bpm: Int?
    let currentZone: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private static let lineWidth: CGFloat = 7
    private static let gapFraction: Double = 0.006

    var body: some View {
        if let span = ZoneSliderGeometry.span(zoneSet) {
            let width: Double = span.upperBound - span.lowerBound
            let fraction: Double? = bpm.map { ZoneSliderGeometry.fraction(bpm: Double($0), in: span) }
            ZStack {
                // The dim track under the arcs, so gaps between zones read as a scale, not holes.
                DialArc(from: 0, to: 1, inset: Self.lineWidth)
                    .stroke(TelosColor.lineSoft, style: StrokeStyle(lineWidth: Self.lineWidth * 0.4, lineCap: .round))
                ForEach(zoneSet.zones, id: \.number) { z in
                    zoneArc(z, span: span, width: width)
                }
                if let fraction {
                    DialCaret(fraction: fraction, inset: Self.lineWidth, diameter: Self.lineWidth + 5)
                        .fill(TelosColor.textPrimary)
                        .overlay(
                            DialCaret(fraction: fraction, inset: Self.lineWidth, diameter: Self.lineWidth + 5)
                                .stroke(TelosColor.canvas, lineWidth: TelosStroke.strong)
                        )
                        .animation(motion.poseStill(reduceMotion) ? nil : TelosMotion.settle, value: fraction)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            // No usable zone set: the bare dashed track (nothing to place a caret on).
            DialArc(from: 0, to: 1, inset: Self.lineWidth)
                .stroke(TelosColor.lineStrong, style: StrokeStyle(lineWidth: TelosStroke.line, dash: [2, 3]))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func zoneArc(_ z: HRZone, span: ClosedRange<Double>, width: Double) -> some View {
        let lo: Double = (z.lower - span.lowerBound) / width
        let hi: Double = (z.upper - span.lowerBound) / width
        let color = StrandPalette.hrZoneColor(z.number)
        let arc = DialArc(from: lo + Self.gapFraction, to: hi - Self.gapFraction, inset: Self.lineWidth)
        if bpm != nil && z.number == currentZone {
            arc.telosLuminousStroke(color, lineWidth: Self.lineWidth, haloOpacity: 0.25)
        } else {
            arc.stroke(color.opacity(bpm == nil ? 0.18 : 0.35),
                       style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
        }
    }
}

/// The dial's geometry: an open gauge from 135° (bottom-left) clockwise through the top to 405°.
private enum DialGeometry {
    static let startDegrees: Double = 135
    static let spanDegrees: Double = 270

    static func radius(in rect: CGRect, inset: CGFloat) -> CGFloat {
        max(0, min(rect.width, rect.height) / 2 - inset)
    }

    static func point(fraction: Double, in rect: CGRect, inset: CGFloat) -> CGPoint {
        let clamped: Double = min(max(fraction, 0), 1)
        let a: Double = (startDegrees + spanDegrees * clamped) * Double.pi / 180
        let r: CGFloat = radius(in: rect, inset: inset)
        return CGPoint(x: rect.midX + r * CGFloat(cos(a)), y: rect.midY + r * CGFloat(sin(a)))
    }
}

private struct DialArc: Shape {
    var from: Double
    var to: Double
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lo: Double = min(max(from, 0), 1)
        let hi: Double = min(max(to, 0), 1)
        guard hi > lo else { return p }
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                 radius: DialGeometry.radius(in: rect, inset: inset),
                 startAngle: .degrees(DialGeometry.startDegrees + DialGeometry.spanDegrees * lo),
                 endAngle: .degrees(DialGeometry.startDegrees + DialGeometry.spanDegrees * hi),
                 clockwise: false)
        return p
    }
}

/// The caret dot, animatable along the arc (its fraction interpolates, so it travels the ring rather
/// than cutting across it).
private struct DialCaret: Shape {
    var fraction: Double
    var inset: CGFloat
    var diameter: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let c = DialGeometry.point(fraction: fraction, in: rect, inset: inset)
        let r = diameter / 2
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: diameter, height: diameter))
    }
}

// MARK: - HR zone section (leaf: observes the model)

/// HR ZONE — the zone scale (one continuous bar from zone 1's floor to HRmax with a caret at the live
/// bpm), the where-in-the-zone caption, and the ZONE LOCK chips. Same zone derivation as before
/// (`HRZoneSet.zoneNumber(forBPM:)` on the smoothed bpm). A leaf, so the lock row re-renders with the
/// reading rather than dragging the whole screen with it.
private struct LiveZoneSection: View {
    @EnvironmentObject private var model: AppModel

    private static let chipVisualHeight: CGFloat = 36

    var body: some View {
        let zoneSet = model.profile.hrZoneSet
        let bpm = model.bpm
        let zone = bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0
        let locked = model.activeWorkout?.lockedZone
        return VStack(alignment: .leading, spacing: TelosSpace.s) {
            HStack {
                Text("HR ZONE")
                    .telosScale()
                    .foregroundStyle(TelosColor.textTertiary)
                Spacer()
                if let locked {
                    HStack(spacing: TelosSpace.xxs) {
                        Image(systemName: "lock.fill").font(TelosType.glyphDelta)
                        Text("Z\(locked)")
                    }
                    .font(TelosType.numeralXS)
                    .foregroundStyle(StrandPalette.hrZoneColor(locked))
                    .accessibilityHidden(true)
                }
            }
            ZoneSlider(zoneSet: zoneSet, bpm: bpm, lockedZone: locked)
            zoneLockRow(locked: locked)
            // Both captions in one stack at label spacing — they read as one explanatory footer.
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(zonePlacementCaption(zoneSet: zoneSet, bpm: bpm, zone: zone))
                    .font(TelosType.footnote).foregroundStyle(TelosColor.textSecondary)
                Text(zoneLockCaption(zoneSet: zoneSet, locked: locked))
                    .font(TelosType.footnote).foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TelosSpace.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card))
    }

    /// "Z3 · 142 bpm · high end" — the zone, the bpm and WHERE in the zone the marker sits, so the
    /// slider reads in words too (and for VoiceOver). Warming-up copy below zone 1, as before.
    private func zonePlacementCaption(zoneSet: HRZoneSet, bpm: Int?, zone: Int) -> String {
        guard let bpm else { return String(localized: "Waiting for heart rate.") }
        guard zone >= 1, let within = ZoneSliderGeometry.withinZone(bpm: Double(bpm), set: zoneSet) else {
            return String(localized: "Warming up. Keep moving to climb into Zone 1.")
        }
        let place: String
        switch within {
        case ..<(1.0 / 3.0): place = String(localized: "low end")
        case ..<(2.0 / 3.0): place = String(localized: "middle")
        default:             place = String(localized: "high end")
        }
        return "Z\(zone) · \(bpm) bpm · \(place)"
    }

    /// ZONE LOCK row: five chips, at most one on. Tapping the locked zone unlocks it; tapping another
    /// moves the lock. The phone gives a light selection tick on every toggle; the STRAP carries the
    /// in-session cues (`AppModel.evaluateZoneGuidance`), so the wearer never has to look.
    ///
    /// Each chip is a full-width fifth by a 44 pt hit target (the visual chip is 36 pt, centred), so
    /// one-handed taps mid-set land.
    private func zoneLockRow(locked: Int?) -> some View {
        HStack(spacing: TelosSpace.xs) {
            ForEach(1...5, id: \.self) { z in
                zoneLockChip(z, isLocked: locked == z)
            }
        }
    }

    private func zoneLockChip(_ z: Int, isLocked: Bool) -> some View {
        let color = StrandPalette.hrZoneColor(z)
        let shape = RoundedRectangle(cornerRadius: TelosRadius.control, style: .continuous)
        return Button {
            TelosHaptics.play(.select)
            model.toggleWorkoutZoneLock(z)
        } label: {
            HStack(spacing: 3) {
                if isLocked {
                    Image(systemName: "lock.fill").font(TelosType.glyphDelta)
                }
                Text("Z\(z)")
            }
            .font(TelosType.numeralXS)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isLocked ? TelosColor.canvas : color)
            .frame(maxWidth: .infinity, minHeight: Self.chipVisualHeight)
            .background(shape.fill(isLocked ? color : color.opacity(TelosOpacity.wash)))
            .overlay(shape.strokeBorder(isLocked ? color : color.opacity(TelosOpacity.border),
                                        lineWidth: TelosStroke.line))
            .frame(minHeight: TelosSpace.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(TelosPressButtonStyle())
        .accessibilityLabel(Text(isLocked ? String(localized: "Unlock Zone \(z)")
                                            : String(localized: "Lock Zone \(z)")))
        .accessibilityAddTraits(isLocked ? .isSelected : [])
    }

    private func zoneLockCaption(zoneSet: HRZoneSet, locked: Int?) -> String {
        guard let locked, let band = zoneSet.zones.first(where: { $0.number == locked }) else {
            return String(localized: "Tap a zone to lock it as your target. The strap buzzes twice when you're below it and once when you're above it.")
        }
        return String(localized: "Zone \(locked) locked · \(Int(band.lower))-\(Int(band.upper)) bpm. Two buzzes: speed up. One buzz: ease off.")
    }
}

// MARK: - Compact inline read-out

/// One "LABEL value" pair for the thin single-line read-outs (GPS, sensor) at the bottom of the stack.
private struct InlineReadout: View {
    let label: String
    let value: String
    var tint: Color = TelosColor.effortInk

    var body: some View {
        HStack(spacing: TelosSpace.xs) {
            Text(label)
                .telosScale()
                .foregroundStyle(TelosColor.textTertiary)
            Text(value)
                .font(TelosType.numeralS)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

/// The shared thin glass pill the inline read-out lines sit in.
private extension View {
    func inlineReadoutRow() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TelosSpace.m)
            .padding(.vertical, TelosSpace.s)
            .frame(minHeight: TelosSpace.hitTarget)
            .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.pill))
            .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE line (pill + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Speed follows the exercise-distance preference; cadence stays per-minute and power in watts.
///
/// A standalone leaf that owns its OWN `@EnvironmentObject live` (the parent does not observe
/// `LiveState`), so an incoming sensor / R-R packet re-renders only this row.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        if live.hasSensorMetrics {
            let speed = UnitFormatter.speedFromKilometersPerHour(
                live.sensorSpeedKmh, system: distanceUnitSystem)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            HStack(spacing: TelosSpace.m) {
                if let speed { InlineReadout(label: String(localized: "SPEED"), value: speed) }
                if let cadence { InlineReadout(label: String(localized: "CADENCE"), value: "\(cadence)/min") }
                if let power { InlineReadout(label: String(localized: "POWER"), value: "\(power) W") }
                Spacer(minLength: 0)
            }
            .inlineReadoutRow()
            .staggeredAppear(index: 5)
        }
    }
}

/// Live GPS distance + average pace on the active-workout screen, for distance sports (#1195).
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent does not observe
/// it), so a GPS fix re-renders only this line. Self-gates to nothing until the first accepted fix, so a
/// denied-permission or GPS-less (Mac) session shows no empty row. Mirrors Android's gated
/// distance/pace row in `LiveWorkoutScreen`.
private struct DistancePaceRowIfPresent: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }

    var body: some View {
        // `isRecording` is essential, not just `pointCount > 0`: the recorder is a single long-lived
        // object and `stop()` leaves `pointCount`/`distanceM` intact (only `start()` resets them, and it
        // runs solely for distance sports). Without the `isRecording` guard a non-GPS workout started
        // after a GPS one would show the previous session's stale distance.
        if recorder.isRecording, recorder.pointCount > 0 {
            HStack(spacing: TelosSpace.l) {
                // "Distance"/"Pace" are already localized (reused from the detail view); uppercased for
                // the caps label, exactly as the detail route stats do.
                InlineReadout(label: String(localized: "Distance").uppercased(),
                              value: UnitFormatter.distanceFromMeters(recorder.distanceM,
                                                                      system: distanceUnitSystem))
                InlineReadout(label: String(localized: "Pace").uppercased(),
                              value: UnitFormatter.paceFromSecPerKm(recorder.paceSecPerKm,
                                                                    system: distanceUnitSystem))
                Spacer(minLength: 0)
            }
            .inlineReadoutRow()
        }
    }
}

// MARK: - HR trace

/// The leaf that reads the session's samples (1 Hz) and hands them to the trace card, which is
/// `Equatable` on a 5-sample bucket: while expanded the Swift Chart redraws at most once per 5 samples
/// (≈5 s) instead of every heartbeat; collapsed, it costs one small header.
private struct LiveHRTraceLeaf: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let w = model.activeWorkout {
            WorkoutHRTraceCard(samples: w.samples,
                               startSec: Int(w.start.timeIntervalSince1970),
                               zoneSet: model.profile.hrZoneSet,
                               lockedZone: w.lockedZone)
                .equatable()
        }
    }
}

/// The whole session's heart rate since the workout started (x = time since start, y = bpm), read
/// against the wearer's dynamic Karvonen zones: each zone boundary is a dashed line in its zone colour,
/// labelled Z1…Z5 on the leading axis, every zone band carries a faint wash of its colour, and a LOCKED
/// zone's band is raised so the target reads at a glance.
///
/// COLLAPSIBLE: a tap on the whole title row expands it, and the state is remembered in `@AppStorage`.
///
/// All the shaping is `WorkoutHRTrace` (StrandAnalytics, unit-tested): the samples are bucketed to at
/// most ~600 points, the line breaks across capture gaps (a pause records no samples), and the y-range
/// frames the data between its neighbouring zone lines plus the locked band, never 0…220. Interpolation
/// `.monotone` (never overshoots the data).
///
/// The x-axis is WALL time since start, so a pause shows as a gap; the elapsed clock in the bottom band is
/// pause-aware active time, so the two differ by the paused duration.
private struct WorkoutHRTraceCard: View, Equatable {
    let samples: [HRSample]
    let startSec: Int
    let zoneSet: HRZoneSet
    let lockedZone: Int?

    /// Redraw bucket: every sample for the first 10 (so the first readings appear at once), then one
    /// step per 5 samples.
    private var sampleBucket: Int { samples.count < 10 ? samples.count : 10 + samples.count / 5 }

    static func == (lhs: WorkoutHRTraceCard, rhs: WorkoutHRTraceCard) -> Bool {
        lhs.sampleBucket == rhs.sampleBucket && lhs.startSec == rhs.startSec
            && lhs.zoneSet == rhs.zoneSet && lhs.lockedZone == rhs.lockedZone
    }

    /// Remembered across sessions, per the compact layout. Default collapsed.
    @AppStorage("liveWorkoutTraceExpanded") private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Band: Identifiable {
        let zone: Int
        let lower: Double
        let upper: Double
        var id: Int { zone }
    }

    private struct ZoneLine: Identifiable {
        let bpm: Double
        /// The zone this line is the floor of (1…5), or 6 for the HRmax line on top of zone 5.
        let zone: Int
        var id: Int { zone }
        var color: Color { StrandPalette.hrZoneColor(min(zone, 5)) }
        var label: String { zone <= 5 ? "Z\(zone)" : String(localized: "Max") }
    }

    private static let chartHeight: CGFloat = 150

    /// Memo of the shaped trace — its points only change when a sample lands. A reference held in
    /// @State, so filling it never invalidates the view.
    @State private var cache = TraceCache()

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.s) {
            disclosureHeader
            if expanded { expandedBody }
        }
        .padding(.horizontal, TelosSpace.cardPadding)
        .padding(.vertical, TelosSpace.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.card))
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(TelosMotion.animation(.screen, reduced: reduceMotion)) { expanded.toggle() }
        } label: {
            HStack(spacing: TelosSpace.s) {
                Text("HEART RATE SINCE START")
                    .telosScale()
                    .foregroundStyle(TelosColor.textTertiary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(TelosType.glyphChevron)
                    .foregroundStyle(TelosColor.textTertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            // The whole row is the target: the card's full width by a 44 pt-tall strip.
            .frame(maxWidth: .infinity, minHeight: TelosSpace.hitTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Heart rate since start"))
        // Reuses the existing translated "Show %@" / "Hide %@" keys — no new string for the disclosure.
        .accessibilityHint(Text(disclosureHint))
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }

    private var disclosureHint: String {
        let name = String(localized: "Heart rate since start")
        return expanded ? String(localized: "Hide \(name)") : String(localized: "Show \(name)")
    }

    /// Only evaluated while expanded — collapsed, `cache.shaped` is never called.
    private var expandedBody: some View {
        let shaped = cache.shaped(samples: samples, startSec: startSec, zoneSet: zoneSet, lockedZone: lockedZone)
        let points = shaped.points
        let yDomain = shaped.yDomain
        let lastOffset: Double = points.last?.offset ?? 0
        let xMax: Double = max(60, lastOffset)
        return Group {
            if points.isEmpty {
                AbsentValue(reason: "Waiting for heart rate.")
                    .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
            } else {
                chart(points: points, yDomain: yDomain, xMax: xMax)
            }
        }
        .padding(.bottom, TelosSpace.s)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart rate since start"))
        .accessibilityValue(Text(accessibilityValue(points)))
    }

    private func chart(points: [WorkoutHRTrace.Point], yDomain: ClosedRange<Double>, xMax: Double) -> some View {
        let edges = Self.edges(zoneSet).filter { yDomain.contains($0.bpm) }
        let bands = Self.bands(zoneSet, clampedTo: yDomain)
        return Chart {
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Start", 0.0), xEnd: .value("End", xMax),
                              yStart: .value("Zone floor", band.lower), yEnd: .value("Zone ceiling", band.upper))
                    .foregroundStyle(StrandPalette.hrZoneColor(band.zone)
                        .opacity(lockedZone == band.zone ? 0.20 : 0.05))
            }
            ForEach(edges) { edge in
                RuleMark(y: .value("Zone boundary", edge.bpm))
                    .lineStyle(StrokeStyle(lineWidth: TelosStroke.line, dash: [4, 4]))
                    .foregroundStyle(edge.color.opacity(isLockedEdge(edge) ? 0.9 : 0.5))
            }
            ForEach(points, id: \.offset) { p in
                LineMark(x: .value("Time", p.offset),
                         y: .value("BPM", p.bpm),
                         series: .value("Segment", p.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: TelosStroke.data, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(TelosColor.heart)
            }
        }
        .chartXScale(domain: 0...xMax)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: WorkoutHRTrace.xTicks(maxOffset: xMax)) { value in
                AxisGridLine().foregroundStyle(TelosColor.lineSoft)
                AxisValueLabel {
                    if let s = value.as(Double.self) {
                        Text(ActiveWorkoutClock.clock(Int(s)))
                            .font(TelosType.scaleNumber).foregroundStyle(TelosColor.textTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            // Zone labels at their boundary lines (leading) and a sparse bpm scale (trailing).
            AxisMarks(position: .leading, values: edges.map(\.bpm)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), let edge = edges.first(where: { abs($0.bpm - v) < 0.01 }) {
                        Text(edge.label)
                            .font(TelosType.scaleNumber)
                            .foregroundStyle(edge.color)
                    }
                }
            }
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel().foregroundStyle(TelosColor.textTertiary)
                    .font(TelosType.scaleNumber)
            }
        }
        .frame(height: Self.chartHeight)
    }

    private func isLockedEdge(_ edge: ZoneLine) -> Bool {
        guard let lockedZone else { return false }
        return edge.zone == lockedZone || edge.zone == lockedZone + 1
    }

    /// Zone floors labelled Z1…Z5, plus the HRmax line on top of zone 5.
    private static func edges(_ set: HRZoneSet) -> [ZoneLine] {
        var out = set.zones.filter { $0.lower.isFinite }.map { ZoneLine(bpm: $0.lower, zone: $0.number) }
        if let top = set.zones.last, top.upper.isFinite, top.upper > top.lower {
            out.append(ZoneLine(bpm: top.upper, zone: 6))
        }
        return out
    }

    /// Each zone's band, clamped to the visible range (a band wholly outside it is dropped) so no mark
    /// asks the chart to draw beyond the plot.
    private static func bands(_ set: HRZoneSet, clampedTo domain: ClosedRange<Double>) -> [Band] {
        set.zones.compactMap { z in
            let lo = max(z.lower, domain.lowerBound)
            let hi = min(z.upper, domain.upperBound)
            guard lo.isFinite, hi.isFinite, hi > lo else { return nil }
            return Band(zone: z.number, lower: lo, upper: hi)
        }
    }

    private func accessibilityValue(_ points: [WorkoutHRTrace.Point]) -> String {
        guard let lo = points.map(\.bpm).min(), let hi = points.map(\.bpm).max() else {
            return String(localized: "Waiting for heart rate.")
        }
        return String(localized: "\(Int(lo.rounded()))–\(Int(hi.rounded())) bpm")
    }

    /// `WorkoutHRTrace.downsample` + `yDomain`, recomputed only when an input moved. The samples are only
    /// ever appended to or have their LAST reading overwritten (one sample per second), so their count
    /// plus the last sample identifies them within a session; the start pins the session.
    private final class TraceCache {
        private struct Key: Equatable {
            let count: Int
            let last: HRSample?
            let startSec: Int
            let zoneSet: HRZoneSet
            let lockedZone: Int?
        }
        private var key: Key?
        private var value: (points: [WorkoutHRTrace.Point], yDomain: ClosedRange<Double>)?

        func shaped(samples: [HRSample], startSec: Int, zoneSet: HRZoneSet,
                    lockedZone: Int?) -> (points: [WorkoutHRTrace.Point], yDomain: ClosedRange<Double>) {
            let k = Key(count: samples.count, last: samples.last, startSec: startSec, zoneSet: zoneSet,
                        lockedZone: lockedZone)
            if let value, key == k { return value }
            let points = WorkoutHRTrace.downsample(samples, startSec: startSec)
            let yDomain = WorkoutHRTrace.yDomain(bpms: points.map(\.bpm), zones: zoneSet, lockedZone: lockedZone)
            key = k
            value = (points, yDomain)
            return (points, yDomain)
        }
    }
}

// MARK: - Zone slider

/// One continuous horizontal bar from zone 1's lower bound to HRmax, divided into the five zone segments
/// in their zone colours (each segment's width is its real bpm span, so personalised zones of unequal
/// width draw true to scale; ramp at 0.35, the current — or locked — band at full strength). A caret
/// rides the bar at the current smoothed bpm, showing WHERE in the zone the wearer is, not just which
/// one. A locked zone's segment is raised and outlined.
///
/// The caret settles between readings (`TelosMotion.settle`); under Reduce Motion / quiet motion / Low
/// Power (`NoopMotionState`) it jumps instead. The animation always settles, so it costs nothing between
/// HR updates.
private struct ZoneSlider: View {
    let zoneSet: HRZoneSet
    let bpm: Int?
    let lockedZone: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private static let barHeight: CGFloat = 12
    private static let lockedHeight: CGFloat = 20
    private static let segmentGap: CGFloat = 2

    var body: some View {
        if let span = ZoneSliderGeometry.span(zoneSet) {
            let width = span.upperBound - span.lowerBound
            let current = bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0
            let fraction = bpm.map { ZoneSliderGeometry.fraction(bpm: Double($0), in: span) }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    ForEach(zoneSet.zones, id: \.number) { z in
                        segment(z, span: span, width: width, barWidth: w, current: current)
                    }
                    if let fraction {
                        marker
                            .offset(x: CGFloat(fraction) * w - 3)
                            .animation(motion.poseStill(reduceMotion) ? nil : TelosMotion.settle,
                                       value: fraction)
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .leading)
            }
            .frame(height: 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Heart rate zone slider"))
            .accessibilityValue(Text(accessibilityValue(current: current)))
        }
    }

    /// One zone's segment, placed at its true bpm offset along the bar. With a lock the locked segment is
    /// the focus; without one, the zone the wearer is in.
    private func segment(_ z: HRZone, span: ClosedRange<Double>, width: Double, barWidth w: CGFloat,
                         current: Int) -> some View {
        let x = CGFloat((z.lower - span.lowerBound) / width) * w
        let segW = max(0, CGFloat((z.upper - z.lower) / width) * w - Self.segmentGap)
        let isLocked = lockedZone == z.number
        let emphasised = lockedZone.map { $0 == z.number } ?? (z.number == current)
        let color = StrandPalette.hrZoneColor(z.number)
        let shape = Capsule(style: .continuous)
        return shape
            .fill(color.opacity(emphasised ? 1 : 0.35))
            .overlay(shape.strokeBorder(isLocked ? TelosColor.textPrimary : Color.clear, lineWidth: TelosStroke.strong))
            .frame(width: segW, height: isLocked ? Self.lockedHeight : Self.barHeight)
            .offset(x: x)
    }

    private func accessibilityValue(current: Int) -> String {
        guard let bpm else { return String(localized: "No heart rate") }
        return current >= 1 ? String(localized: "Zone \(current), \(bpm) bpm")
                            : String(localized: "Below Zone 1, \(bpm) bpm")
    }

    /// The live-bpm caret: a slim pill that stands clear of the tallest (locked) segment. No shadow.
    private var marker: some View {
        Capsule()
            .fill(TelosColor.textPrimary)
            .frame(width: 6, height: 26)
            .overlay(Capsule().strokeBorder(TelosColor.canvas, lineWidth: TelosStroke.strong))
    }
}

// MARK: - Session stats + Today's Effort vs target

/// The session's AVG / PEAK heart rate AND today's Effort against the day's recommended ceiling, as three
/// compact glass tiles (decision 11) with the day bar under them.
///
/// HONEST ABSENCE (§2.3 rule 2 — the `?? 0` this card used to be fed is gone): AVG and PEAK are nil until
/// the session holds a sample, and render "—" + "Waiting for the strap"; the day figure and the target
/// each show a dash on their own until they resolve, and the bar does not draw until the day figure
/// does. Nothing is substituted for a missing value.
///
/// THE SAME NUMBER TODAY AND THE WIDGET SHOW, AT THE SAME MOMENT — `Repository.todayEffortNow()` printed
/// through its own `display(scale:)`, and `Repository.todayEffortTarget()` for the ceiling.
///
/// THE SESSION IS NOT ADDED INTO THE DAY FIGURE. The day's Effort is measured from the day's heart rate,
/// and this session's beats reach it through the strap's history; adding the session's own running Effort
/// on top would count the overlap twice the moment a drain lands. The session's own live Effort is the
/// ring in the hero, and the line under the bar states it as its own figure — see `TodayEffortNow`.
///
/// CHEAP ON PURPOSE: the two shared resolutions are day-scoped reads on a 30 s task of their own, never on
/// the live-HR path. A leaf: its 1 Hz observation re-renders three small tiles, nothing else.
private struct SessionSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// How often the shared day figure + target are re-read while the session runs. Slow on purpose: both
    /// move on a sync or a Today reload, not per heartbeat.
    private static let dayRefreshNanos: UInt64 = 30_000_000_000

    @State private var effortNow: TodayEffortNow?
    @State private var target: TodayEffortTarget?

    var body: some View {
        let w = model.activeWorkout
        let hasSamples: Bool = !(w?.samples.isEmpty ?? true)
        // No sample yet ⇒ no average and no peak (never the stored 0 the struct starts with).
        let avg: Int? = hasSamples ? w.flatMap { $0.avgHr > 0 ? $0.avgHr : nil } : nil
        let peak: Int? = hasSamples ? w.flatMap { $0.peakHr > 0 ? $0.peakHr : nil } : nil
        let sessionEffort: Double? = hasSamples ? w?.liveStrain : nil
        let dayInk: Color = effortNow == nil ? TelosColor.textTertiary
            : (pastTarget ? TelosColor.heartInk : TelosColor.effortInk)
        // The stat row renders immediately (it needs no load), and the day bar appears under it when the
        // first read lands. The card is never zero-height, so `.task` is always attached to a view that
        // actually renders.
        return VStack(alignment: .leading, spacing: TelosSpace.s) {
            TelosTileGrid(minTileWidth: 96, maxColumns: 3) {
                LiveStatTile(label: String(localized: "AVG"), value: avg.map { "\($0)" }, unit: "bpm",
                             ink: TelosColor.heartInk)
                LiveStatTile(label: String(localized: "PEAK"), value: peak.map { "\($0)" }, unit: "bpm",
                             ink: TelosColor.heartInk)
                // Day Effort / today's recommended ceiling, on the wearer's scale, both from the shared
                // resolutions. The label reuses the already-translated "Day" and "target" keys.
                LiveStatTile(label: Self.dayTargetLabel,
                             value: TodayEffortNow.dayTargetText(effort: effortNow, target: target, scale: effortScale),
                             unit: nil,
                             ink: dayInk)
            }
            if let day100 = effortNow?.effort100 {
                dayStrip(day100: day100, sessionEffort: sessionEffort)
                    .padding(.horizontal, TelosSpace.xs)
            }
        }
        .task { await trackDayEffort() }
    }

    /// The bar: the day so far on the 0–100 axis with a notch at the target — the same axis and the same
    /// inverse-calibrated mark Today's hero ring uses.
    private func dayStrip(day100: Double, sessionEffort: Double?) -> some View {
        let target100 = target?.upper100
        // Axis only (never a displayed figure): room for the target and the day, at least 10.
        let targetRoom: Double = target100.map { $0 * 1.2 } ?? 10
        let domain: Double = min(StrainScorer.maxStrain, max(targetRoom, day100 * 1.1, 10))
        let dayFrac: Double = min(max(day100 / domain, 0), 1)
        let targetFrac: Double? = target100.map { min(max($0 / domain, 0), 1) }
        return VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(TelosColor.effort.opacity(TelosOpacity.fill))
                    Capsule().fill(TelosColor.effort)
                        .frame(width: max(0, CGFloat(dayFrac) * w))
                    if let targetFrac {
                        Capsule()
                            .fill(TelosColor.textPrimary)
                            .frame(width: 2, height: 14)
                            .offset(x: CGFloat(targetFrac) * w - 1)
                    }
                }
                .frame(width: w, height: 6, alignment: .leading)
                .frame(height: geo.size.height)
            }
            .frame(height: 14)
            Group {
                if pastTarget {
                    Text("Past today's recommended ceiling.")
                } else if let sessionEffort {
                    // The session's OWN Effort, stated as its own figure (see the type comment).
                    Text("This workout \(UnitFormatter.effortDisplay(sessionEffort, scale: effortScale)) so far")
                } else {
                    Text("Waiting for heart rate.")
                }
            }
            .font(TelosType.footnote).foregroundStyle(TelosColor.textTertiary)
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
    }

    /// "DAY / TARGET" built from the two existing localized words, so the card adds no new translation key.
    private static var dayTargetLabel: String {
        "\(String(localized: "Day").localizedUppercase) / \(String(localized: "target").localizedUppercase)"
    }

    /// Past the ceiling, compared on the one axis both figures are already on (0–100, the target through
    /// the inverse calibration).
    private var pastTarget: Bool {
        guard let day100 = effortNow?.effort100, let target100 = target?.upper100 else { return false }
        return day100 >= target100
    }

    /// Keep the day figure + target current while the session runs — a slow poll of the two shared
    /// resolutions, its own task, cancelled with the screen, never on the live-HR path.
    private func trackDayEffort() async {
        let repo = model.repo
        while !Task.isCancelled {
            let now = await repo.todayEffortNow()
            let resolvedTarget = await repo.todayEffortTarget()
            effortNow = now
            target = resolvedTarget
            try? await Task.sleep(nanoseconds: Self.dayRefreshNanos)
        }
    }
}

/// One compact glass stat tile: label (small caps) → value + unit, or "—" + the existing reason. No
/// count-up on purpose — these move every second while streaming, and a per-second count would be a
/// near-continuous animation.
private struct LiveStatTile: View {
    let label: String
    let value: String?
    let unit: String?
    let ink: Color

    var body: some View {
        VStack(alignment: .leading, spacing: TelosSpace.xxs) {
            Text(label)
                .telosScale()
                .textCase(.uppercase)
                .foregroundStyle(TelosColor.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: TelosSpace.xxs) {
                Text(verbatim: value ?? TelosType.absent)
                    .telosNumeral(.numeralM)
                    .foregroundStyle(value == nil ? TelosColor.textTertiary : ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if value != nil, let unit {
                    Text(verbatim: unit)
                        .font(TelosType.scale)
                        .foregroundStyle(TelosColor.textSecondary)
                        .lineLimit(1)
                }
            }
            if value == nil {
                Text("Waiting for the strap")
                    .font(TelosType.caption)
                    .foregroundStyle(TelosColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TelosSpace.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(FrostedCardSurface(tint: nil, cornerRadius: TelosRadius.tile))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: Text {
        guard let value else { return Text("No data") }
        return Text(verbatim: value + (unit.map { " " + $0 } ?? ""))
    }
}
