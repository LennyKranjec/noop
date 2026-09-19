import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
///
/// ZONE LOCK: the HR ZONE card carries a zone slider (the whole zone 1 … HRmax range as one bar with a
/// live marker) and five lock toggles. A locked zone is stored on `ActiveWorkout.lockedZone`; the strap
/// cueing itself lives in `AppModel.evaluateZoneGuidance`, so it keeps running with this screen closed.
/// The TODAY'S EFFORT card sets the session against the day's Effort and its recommended ceiling.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick — the HR hero, effort
    // gauge, zone rail and stats grid all re-evaluate even though they read from `model` (smoothed bpm +
    // scorers), not `live`. The only region that genuinely needs `live` is the additive sensor readout
    // (speed / cadence / power), so it's extracted into the small `SensorRowIfPresent` leaf below that
    // owns its OWN `@EnvironmentObject live`. A sensor/R-R packet now re-renders just that row, not the
    // hero. (`model.live` is its own ObservableObject, so the leaf's `live` is the one that sees the
    // @Published changes — exactly as the parent's direct observation did before.)
    let onClose: () -> Void

    /// Effort display scale (#268) — routes the live Effort read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    /// Guards the destructive End action behind a confirm (#517) — a stray tap on the compact exit
    /// control must not end the workout instantly with no way back.
    @State private var showEndConfirm = false
    @State private var showDeleteConfirm = false

    private var zoneSet: HRZoneSet { model.profile.hrZoneSet }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                let cards: [AnyView] = [
                    AnyView(header),
                    AnyView(timeBlock),
                    AnyView(heartRateBlock),
                    AnyView(effortGauge),
                    // Today's Effort so far (live) against the day's recommended ceiling — the same
                    // target Today's hero ring marks — so a session can be paced against the whole day.
                    AnyView(DayEffortTargetCard(sessionEffort: model.activeWorkout?.liveStrain ?? 0,
                                                effortScale: effortScale)),
                    AnyView(zoneSection),
                    AnyView(statsGrid),
                    // Live GPS distance + pace (#1195) — a self-gating leaf owning its own recorder
                    // observation, so a GPS fix re-renders only this card. Renders nothing until the first
                    // accepted fix, so non-GPS / denied sessions leave the stack unchanged.
                    AnyView(DistancePaceRowIfPresent(recorder: model.gpsRecorder)),
                ]
                ForEach(Array(cards.enumerated()), id: \.offset) { index, card in
                    card.staggeredAppear(index: index)
                }
                // Live-observing leaf: renders the sensor row (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / effort gauge above (scroll-stutter isolation).
                SensorRowIfPresent()
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space6)
            .padding(.bottom, NoopMetrics.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
        // tracker, up for the whole workout, so worth the same defensive fix.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // Floating end / elapsed / sport-type controls sit in the bottom safe area so the scroll
        // content never owns the chrome and the timer can stay screen-centered.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomControlRow
        }
        // A scenic Effort-tinted backdrop behind the whole in-exercise screen, fading to the base — the
        // live workout reads as an Effort-world hero, not a flat panel.
        .background {
            ScenicHeroBackground(domain: .effort)
                .ignoresSafeArea()
        }
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
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
                model.endWorkout()
                onClose()
            }
        } message: {
            Text("This stops recording and saves what's captured so far. It can't be resumed.")
        }
        .confirmationDialog("Delete", isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.discardWorkout()
                onClose()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: NoopMetrics.space1) {
                Circle()
                    .fill(StrandPalette.metricRose)
                    .frame(width: 7, height: 7)
                Group {
                    if model.activeWorkout?.isPaused == true { Text("Paused") }
                    else { Text("Recording workout") }
                }
                .textCase(.uppercase)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.metricRose)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(NoopPanelSurface(tint: StrandPalette.metricRose, cornerRadius: 14))
            .clipShape(Capsule())
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording workout"))
    }

    /// Centered elapsed-time stack — same TimelineView source as before; card chrome removed so
    /// TIME sits as a free hero metric above heart rate.
    private var timeBlock: some View {
        Group {
            if let workout = model.activeWorkout {
                VStack(spacing: NoopMetrics.space1) {
                    Text("TIME")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Self.elapsed(seconds: workout.elapsed()))
                            .font(StrandFont.number(56)).monospacedDigit()
                            .foregroundStyle(StrandPalette.textPrimary)
                            .contentTransition(.numericText())
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Centered live HR stack — bpm unit sits under the value; the zone capsule moved to `zoneSection`.
    private var heartRateBlock: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return VStack(spacing: NoopMetrics.space1) {
            Text("HEART RATE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            if let bpm = model.bpm {
                CountUpText(value: Double(bpm),
                            format: { "\(Int($0.rounded()))" },
                            font: StrandFont.rounded(72, weight: .semibold),
                            color: tint)
            } else {
                Text("—")
                    .font(StrandFont.rounded(72, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text("bpm")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Centered Effort stack — same `liveStrain` / Effort-scale conversion and `StrainGauge` intensity
    /// label as before. Card chrome and side-by-side layout removed so the value sits as a free hero
    /// metric between heart rate and the zone rail. Display-only; captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        let displayEffort = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let fraction = min(max(displayEffort / maxValue, 0), 1)
        // VoiceOver needs the selected scale maximum (0–21 / 0–100) even though the visible denominator
        // was removed from the glanceable layout. Reuse the same localized "of %@" caption as Today /
        // Week-in-review, and format the spoken value like the on-screen CountUpText.
        let valueText = effortScale == .whoop
            ? String(format: "%.1f", displayEffort)
            : "\(Int(displayEffort.rounded()))"
        let scaleCaption = String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))")
        let effortAccessibilityLabel = "\(String(localized: "Effort")) \(valueText) \(scaleCaption)"
        return VStack(spacing: NoopMetrics.space1) {
            CountUpText(value: displayEffort,
                        format: { value in
                            effortScale == .whoop
                                ? String(format: "%.1f", value)
                                : "\(Int(value.rounded()))"
                        },
                        font: StrandFont.rounded(56, weight: .semibold),
                        color: StrandPalette.textPrimary)
            .accessibilityLabel(effortAccessibilityLabel)
            .accessibilityValue(Text(StrainGauge.stateLabel(forFraction: fraction)))

            Text("EFFORT BUILDING")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.effortColor)
            Text(StrainGauge.stateLabel(forFraction: fraction))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// HR ZONE — the header capsule, the ZONE SLIDER (one continuous bar from zone 1's floor to HRmax with
    /// a live marker), where-in-the-zone caption, and the ZONE LOCK row. Same zone derivation as before
    /// (`HRZoneSet.zoneNumber(forBPM:)` on the smoothed bpm); the slider replaces the five-chip rail.
    private var zoneSection: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        let locked = model.activeWorkout?.lockedZone
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("HR ZONE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, NoopMetrics.space2)
                    .padding(.vertical, NoopMetrics.space1)
                    .background(tint.opacity(0.12), in: Capsule())
            }
            ZoneSlider(zoneSet: zoneSet, bpm: model.bpm, lockedZone: locked)
            Text(zonePlacementCaption)
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            zoneLockRow(locked: locked)
            Text(zoneLockCaption(locked: locked))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Z3 · 142 bpm · high end" — the zone, the bpm and WHERE in the zone the marker sits, so the
    /// slider reads in words too (and for VoiceOver). Warming-up copy below zone 1, as before.
    private var zonePlacementCaption: String {
        guard let bpm = model.bpm else { return String(localized: "Waiting for heart rate.") }
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

    /// ZONE LOCK row: five toggles, at most one on. Tapping the locked zone unlocks it; tapping another
    /// moves the lock. The phone gives a light tap on every toggle; the STRAP carries the in-session cues
    /// (`AppModel.evaluateZoneGuidance`), so the wearer never has to look.
    private func zoneLockRow(locked: Int?) -> some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { z in
                let isLocked = locked == z
                let color = StrandPalette.hrZoneColor(z)
                Button {
                    StrandHaptic.light.play()
                    model.toggleWorkoutZoneLock(z)
                } label: {
                    HStack(spacing: 3) {
                        if isLocked {
                            Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold))
                        }
                        Text("Z\(z)")
                    }
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(isLocked ? StrandPalette.surfaceBase : color)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isLocked ? color : color.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isLocked ? color : StrandPalette.hairline, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isLocked ? String(localized: "Unlock Zone \(z)")
                                                    : String(localized: "Lock Zone \(z)")))
                .accessibilityAddTraits(isLocked ? .isSelected : [])
            }
        }
    }

    private func zoneLockCaption(locked: Int?) -> String {
        guard let locked, let band = zoneSet.zones.first(where: { $0.number == locked }) else {
            return String(localized: "Tap a zone to lock it as your target. The strap buzzes twice when you're below it and once when you're above it.")
        }
        return String(localized: "Zone \(locked) locked · \(Int(band.lower))-\(Int(band.upper)) bpm. Two buzzes: speed up. One buzz: ease off.")
    }

    private var statsGrid: some View {
        let w = model.activeWorkout
        return NoopCard(padding: NoopMetrics.cardInnerPadding) {
            HStack(spacing: 0) {
                stat(String(localized: "AVG"), (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "—",
                     tint: (w?.avgHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
                statDivider
                stat(String(localized: "PEAK"), (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "—",
                     tint: (w?.peakHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
                statDivider
                stat(String(localized: "EFFORT"), UnitFormatter.effortDisplay(w?.liveStrain ?? 0, scale: effortScale),
                     tint: StrandPalette.strainColor(w?.liveStrain ?? 0))
            }
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(28))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 48)
    }

    // MARK: - Bottom floating controls

    /// Diameter shared by every Liquid Glass circle in the bottom capsule, so the row reads as one
    /// set of controls rather than a mix of sizes.
    ///
    /// It used to justify itself as keeping "the centered timer optically balanced against equal side
    /// chrome". The side chrome has not been equal since #1533 put two circles on the left and one on
    /// the right, and the timer is no longer centred against them — see `bottomControlRow`.
    private static let bottomControlDiameter: CGFloat = 56
    /// Tight inset so the glass circles nest into the capsule ends (stopwatch-bar proportions).
    private static let bottomBarInset: CGFloat = 4

    /// One shared dark floating capsule: discard · pause · elapsed · end.
    ///
    /// Laid out in ONE HStack, so the timer and the controls cannot overlap. #1068 built this as a
    /// ZStack with the timer centred independently — deliberately, "so uneven label widths cannot pull
    /// the time off-center" — and that held while the bar carried one circle per side. #1533 added the
    /// discard and pause controls to the left group, and a centred 40pt timer then began where two
    /// 56pt circles plus their spacing end: `0:02` merely touched the pause button, and anything wider
    /// went under it. A field report of "two timers" was this one half-occluded, read as a duplicate of
    /// the big TIME readout above. `.allowsHitTesting(false)` on the timer was already a tell that it
    /// sat beneath something tappable.
    ///
    /// The trade is deliberate: the timer now sits centred in the space the buttons leave rather than
    /// in the bar, so it reads slightly right of true centre because the left chrome is heavier. That
    /// is the cost of the layout being unable to collide at all. The buttons keep the positions they
    /// have shipped with — moving pause to the right would centre the timer better and would also move
    /// a control under the thumb of everyone already using this screen, which is a worse trade than an
    /// off-centre clock.
    ///
    /// It can still run out of ROOM, and the arithmetic is tighter than it looks: three 56pt circles
    /// and their gaps leave the timer roughly 161pt on a 393pt screen, against about 144pt for a
    /// `1:30:00` at 40pt monospaced. On a 375pt device, or at a larger Dynamic Type, that does not fit,
    /// so the timer scales rather than overflowing the capsule. The alternative considered — padding
    /// the timer clear of the widest group to keep true centring — left it barely 105pt and would have
    /// truncated the same clock outright.
    private var bottomControlRow: some View {
        HStack(spacing: NoopMetrics.space2) {
            deleteWorkoutGlassButton
            pauseWorkoutGlassButton
            Spacer(minLength: NoopMetrics.space2)
            bottomElapsedTimer
                .allowsHitTesting(false)
                // Scaling down is the honest failure when the room runs out: truncating a clock to
                // "1:30:0" would be worse than a smaller one. Same idiom the rest of this file uses.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // NO layoutPriority here, deliberately. Raising the timer's priority sizes it BEFORE
                // the three circles, and those are fixed 56pt frames — inflexible, so when the space
                // runs out they do not shrink, they clip. That inverts which element gives way: a
                // half-drawn pause button is worse than a smaller clock, and a clipped control is the
                // failure this whole change exists to remove. At equal priority the inflexible frames
                // are satisfied first and the Text scales into what is left, which is the order wanted.
            Spacer(minLength: NoopMetrics.space2)
            endWorkoutGlassButton
        }
        .padding(Self.bottomBarInset)
        .background {
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: true)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        .padding(.bottom, NoopMetrics.space3)
    }

    /// Same `activeWorkout.start` + `TimelineView` source as the hero TIME block — plain primary text,
    /// no card / glass / capsule behind it (the shared bar owns the surface).
    private var bottomElapsedTimer: some View {
        Group {
            if let workout = model.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsed(seconds: workout.elapsed()))
                        .font(StrandFont.number(40)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(Self.elapsed(seconds: workout.elapsed())))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var endWorkoutGlassButton: some View {
        Button { showEndConfirm = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("End workout"))
        .accessibilityHint(Text("Stops recording and saves what's captured so far"))
    }

    private var pauseWorkoutGlassButton: some View {
        let paused = model.activeWorkout?.isPaused == true
        return Button { model.toggleWorkoutPause() } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text(paused ? "Resume" : "Pause"))
    }

    private var deleteWorkoutGlassButton: some View {
        Button { showDeleteConfirm = true } label: {
            Image(systemName: "trash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StrandPalette.statusCritical)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("Delete"))
    }

    private var activeSportName: String {
        model.activeWorkout?.sport ?? WorkoutCatalog.defaultSportName
    }

    private var workoutTypeGlassButton: some View {
        Button {
            // Placeholder — sport-type picker lands later; chrome and sizing stay put.
        } label: {
            WorkoutTypeIcon(workoutType: activeSportName, size: 22, weight: .semibold)
                .frame(width: Self.bottomControlDiameter, height: Self.bottomControlDiameter)
                .contentShape(Circle())
        }
        .nativeLiquidGlassWorkoutControl()
        .accessibilityLabel(Text("\(WorkoutSource.displaySport(activeSportName)) workout"))
    }

    // MARK: - Helpers

    /// Delegates to the shared clock. This carried its own `%d:%02d` with NO hour roll-over, so a
    /// 90-minute session read "90:00" here while Android's live workout screen read "1:30:00" — and,
    /// after the card fix, while the iOS card that opens THIS screen read "1:30:00" too. The math was
    /// already pause-aware (`workout.elapsed()`); only the formatting was the odd one out.
    private static func elapsed(seconds: TimeInterval) -> String {
        ActiveWorkoutClock.clock(Int(seconds))
    }

    private static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

// MARK: - Native Liquid Glass workout controls

private extension View {
    /// Platform-owned circular chrome for the live-workout bottom controls. iOS 26 uses the interactive
    /// Liquid Glass button material; macOS and older iOS keep the same circular geometry with the
    /// same native-system material fallback the Home header buttons already use.
    @ViewBuilder
    func nativeLiquidGlassWorkoutControl() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .large) {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE block (panel + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Speed follows the exercise-distance preference; cadence stays per-minute and power in watts.
/// Tinted with the Effort world so it reads as part of the hero, not a competing accent. Nothing
/// here touches HR / zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row, not the
/// HR hero / effort gauge / zone rail above. The gate, layout and `staggeredAppear(index: 5)` are
/// preserved verbatim (index bumped to 7 — 6 after the glanceable layout split TIME / HR / Effort / zone
/// into separate stagger slots, then 7 after the live distance/pace card #1195 took the slot before it,
/// then 8 after the day-Effort/target card took a slot above), so the rendered output matches the
/// previous inline code.
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
            NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Text("SENSOR")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    HStack(spacing: NoopMetrics.gap) {
                        if let speed { stat(String(localized: "SPEED"), speed, tint: StrandPalette.effortColor) }
                        if let cadence { stat(String(localized: "CADENCE"), "\(cadence)/min", tint: StrandPalette.effortColor) }
                        if let power { stat(String(localized: "POWER"), "\(power) W", tint: StrandPalette.effortColor) }
                    }
                }
            }
            .staggeredAppear(index: 8)
        }
    }

    /// Compact sensor value used inside this leaf's shared panel, keeping its high-frequency updates
    /// isolated from the rest of the workout screen.
    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(26))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Live GPS distance + average pace on the active-workout screen, for distance sports (#1195). The main
/// gap this closes: the recorder already computes and publishes `distanceM` / `paceSecPerKm` on every
/// accepted fix, but they were only ever shown in the post-workout detail view — never live.
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent `LiveWorkoutView`
/// does not observe it), so a GPS fix re-renders only this card — not the HR hero / effort gauge above,
/// the same scroll-stutter isolation as `SensorRowIfPresent`. Self-gates to nothing until the first
/// accepted fix, so a denied-permission or GPS-less (Mac) session shows no empty card. Mirrors Android's
/// gated distance/pace row in `LiveWorkoutScreen`.
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
        // after a GPS one would show the previous session's stale distance. Together they mean "a GPS
        // recording is live AND has at least one accepted fix" — the Android `gpsEnabled && track` twin.
        if recorder.isRecording, recorder.pointCount > 0 {
            NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
                HStack(spacing: 0) {
                    // "Distance"/"Pace" are already localized (reused from the detail view); uppercased for
                    // the caps stat grid, exactly as the detail route stats do.
                    stat(String(localized: "Distance").uppercased(),
                         UnitFormatter.distanceFromMeters(recorder.distanceM, system: distanceUnitSystem))
                    statDivider
                    stat(String(localized: "Pace").uppercased(),
                         UnitFormatter.paceFromSecPerKm(recorder.paceSecPerKm, system: distanceUnitSystem))
                }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.number(28))
                .foregroundStyle(StrandPalette.effortColor)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 48)
    }
}

// MARK: - Zone slider

/// One continuous horizontal bar from zone 1's lower bound to HRmax, divided into the five zone segments
/// in their zone colours (each segment's width is its real bpm span, so personalised zones of unequal
/// width draw true to scale). A marker rides the bar at the current smoothed bpm, showing WHERE in the
/// zone the wearer is, not just which one. A locked zone's segment is raised and outlined; the rest dim.
///
/// The marker glides between readings; under Reduce Motion / quiet motion / Low Power (`NoopMotionState`)
/// it jumps instead. The animation always settles, so it costs nothing between HR updates.
private struct ZoneSlider: View {
    let zoneSet: HRZoneSet
    let bpm: Int?
    let lockedZone: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private static let barHeight: CGFloat = 16
    private static let lockedHeight: CGFloat = 24
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
                            .animation(motion.poseStill(reduceMotion) ? nil
                                       : .spring(response: 0.55, dampingFraction: 0.85),
                                       value: fraction)
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .leading)
            }
            .frame(height: 36)
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
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.opacity(emphasised ? 1 : 0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isLocked ? StrandPalette.textPrimary : Color.clear, lineWidth: 1.5)
            )
            .frame(width: segW, height: isLocked ? Self.lockedHeight : Self.barHeight)
            .offset(x: x)
    }

    private func accessibilityValue(current: Int) -> String {
        guard let bpm else { return String(localized: "No heart rate") }
        return current >= 1 ? String(localized: "Zone \(current), \(bpm) bpm")
                            : String(localized: "Below Zone 1, \(bpm) bpm")
    }

    /// The live-bpm marker: a slim pill that stands clear of the tallest (locked) segment.
    private var marker: some View {
        Capsule()
            .fill(StrandPalette.textPrimary)
            .frame(width: 6, height: 34)
            .overlay(Capsule().strokeBorder(StrandPalette.surfaceBase, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Today's Effort vs target

/// Today's Effort so far — live — against the day's recommended ceiling, on the wearer's Effort scale:
/// "Day 9.8 / target 14". A bar shows the day before this session (dim), what this session has added
/// (bright), and a notch at the target.
///
/// THE SAME NUMBERS AS TODAY, resolved as Today resolves them (and as the widget publisher mirrors it):
///   - DAY BEFORE THE SESSION: the app's own Effort (computed lane, else the merged row, through the
///     never-drop max with the live value Today last published), yielding to WHOOP's own strain when the
///     app's own is a zero the strap did not earn — read ONCE when the screen opens.
///   - TARGET: the top of `CoupledView.optimalStrainRange(recovery:)`, recovery being WHOOP's own for
///     today when it has one, else the app's own Charge; placed on the 0–100 axis through the INVERSE
///     `StrainCalibration`, exactly like the hero ring's mark.
///
/// CHEAP ON PURPOSE. Nothing here rescans the day's heart rate: the day figure is loaded once, and the
/// session's running `liveStrain` (already recomputed per sample by `AppModel`) is folded in on the log
/// axis via `StrainScorer.combinedStrain` — Effort is not additive, TRIMP is.
///
/// KNOWN LIMIT: if Today (or the daily pass) had already scored part of THIS session's heart rate before
/// the screen opened — e.g. reopened after a relaunch mid-workout — that part is counted twice. It is a
/// live pacing read-out, not a stored score; the day's number of record is still the daily pass.
private struct DayEffortTargetCard: View {
    @EnvironmentObject private var model: AppModel
    let sessionEffort: Double
    let effortScale: EffortScale

    @State private var loaded = false
    @State private var baseline: Double = 0
    @State private var target100: Double?
    @State private var targetUpper21: Int?

    var body: some View {
        // A zero-height stand-in until the one-off load lands, NOT an empty Group: `.task` on a view
        // that renders nothing is not guaranteed to run, and then the card would never appear.
        Group {
            if loaded { card } else { Color.clear.frame(height: 1) }
        }
        .task { await load() }
    }

    private var dayEffort: Double {
        let denominator = StrainScorer.logMapDenominator(method: PuffinExperiment.effortMethod,
                                                         sex: model.profile.sex)
        return StrainScorer.combinedStrain(baseline, sessionEffort, denominator: denominator)
    }

    private var targetText: String {
        guard let target100 else { return "–" }
        // On the WHOOP scale the band top is a whole WHOOP strain (14), shown as WHOOP states it.
        if effortScale == .whoop, let targetUpper21 { return "\(targetUpper21)" }
        return "\(Int(target100.rounded()))"
    }

    private var card: some View {
        let day = dayEffort
        let domain = min(StrainScorer.maxStrain, max((target100 ?? 0) * 1.2, day * 1.1, 10))
        let beforeFrac = min(max(baseline / domain, 0), 1)
        let dayFrac = min(max(day / domain, 0), 1)
        let targetFrac = target100.map { min(max($0 / domain, 0), 1) }
        let dayText = UnitFormatter.effortDisplay(day, scale: effortScale)
        let past = target100.map { day >= $0 } ?? false
        let sessionText = UnitFormatter.effortDeltaDisplay(max(0, day - baseline), scale: effortScale)
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("TODAY'S EFFORT")
                        .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text("Day \(dayText) / target \(targetText)")
                        .font(StrandFont.captionNumber).monospacedDigit()
                        .foregroundStyle(past ? StrandPalette.metricRose : StrandPalette.textPrimary)
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(StrandPalette.hairline)
                        // The whole day so far in full colour, then the day-before span dimmed over its
                        // start, so the bright remainder is exactly what this session added.
                        Capsule().fill(StrandPalette.effortColor)
                            .frame(width: max(0, CGFloat(dayFrac) * w))
                        Capsule().fill(StrandPalette.effortColor.opacity(0.4))
                            .frame(width: max(0, CGFloat(beforeFrac) * w))
                        if let targetFrac {
                            Rectangle()
                                .fill(StrandPalette.textPrimary)
                                .frame(width: 2, height: 20)
                                .offset(x: CGFloat(targetFrac) * w - 1)
                        }
                    }
                    .frame(width: w, height: 10, alignment: .leading)
                    .frame(height: geo.size.height)
                }
                .frame(height: 20)
                Text(past ? String(localized: "Past today's recommended ceiling.")
                          : String(localized: "This workout +\(sessionText)"))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Read the day-before-session Effort and today's target once. Mirrors `LiquidTodayView.heroOwnEffort`
    /// / `optimalStrainCeiling` and `WidgetPublish.fillStrip`.
    private func load() async {
        guard !loaded else { return }
        let repo = model.repo
        let todayKey = Repository.localDayKey(Date())
        let cloud = await repo.whoopCloudDay(todayKey)
        let computed = await repo.noopScores(day: todayKey)
        let row = repo.days.first { $0.day == todayKey }
        var own = StrainScorer.effectiveEffort(live: TodayView.publishedLiveStrain(day: todayKey),
                                               stored: computed.effort ?? row?.strain)
        // A ZERO THE STRAP DID NOT EARN yields to WHOOP's own strain for the day, as on Today.
        if let o = own, o < 0.5, let c = cloud?.strain, c > 0 { own = nil }
        baseline = own ?? cloud?.strain.map { StrainCalibration.effort100(strain21: $0) } ?? 0
        let recovery = cloud?.recovery ?? computed.charge ?? row?.recovery
        if let band = CoupledView.optimalStrainRange(recovery: recovery) {
            targetUpper21 = band.upperBound
            target100 = StrainCalibration.effort100(strain21: Double(band.upperBound))
        }
        loaded = true
    }
}
