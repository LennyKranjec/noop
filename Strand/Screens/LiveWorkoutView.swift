import SwiftUI
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
/// ZONE LOCK: the HR ZONE block carries a zone slider (the whole zone 1 … HRmax range as one bar with a
/// live marker) and five lock chips. A locked zone is stored on `ActiveWorkout.lockedZone`; the strap
/// cueing itself lives in `AppModel.evaluateZoneGuidance`, so it keeps running with this screen closed.
/// The session card sets the session against the day's Effort and its recommended ceiling.
///
/// COMPACT LAYOUT (the in-exercise screen must be glanceable mid-set, not a scroll). The screen used to
/// be nine separately-spaced blocks — a status pill, a hero TIME, a hero HR, a hero EFFORT, a day-effort
/// card, an HR-trace card, a zone block, an AVG/PEAK/EFFORT card and two sensor cards — roughly 1200pt
/// on a 390×844 phone against about 680pt of visible room. Everything is still here; it is packed
/// differently:
///   - TIME lives ONLY in the always-visible bottom bar now. It was shown twice (56pt hero + 40pt bar),
///     which is the "two timers" report #1068 already chased once.
///   - HR and EFFORT share one hero row.
///   - AVG / PEAK / day-vs-target are one card (EFFORT was duplicated between the hero and the stat row).
///   - The HR-since-start chart is collapsed behind a disclosure header, remembered in `@AppStorage`.
///   - The GPS and sensor read-outs are single thin lines instead of stat cards.
/// Nothing was removed from the screen except the two values that appeared twice.
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
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                // Listed directly (not an [AnyView] walked by a ForEach): SwiftUI keeps each card's static
                // type, so it can diff them instead of rebuilding type-erased boxes on every live tick.
                heroRow.staggeredAppear(index: 0)
                // AVG / PEAK plus Today's Effort so far (live) against the day's recommended ceiling —
                // the same target Today's hero ring marks — so a session can be paced against the whole day.
                SessionSummaryCard(avgHr: model.activeWorkout?.avgHr ?? 0,
                                   peakHr: model.activeWorkout?.peakHr ?? 0,
                                   sessionEffort: model.activeWorkout?.liveStrain ?? 0,
                                   effortScale: effortScale)
                    .staggeredAppear(index: 1)
                zoneSection.staggeredAppear(index: 2)
                // The whole session's HR since start against the zone lines (dashed), with a locked
                // zone's band raised — the history the zone slider above shows only the latest point of.
                // Collapsed by default; the disclosure state is remembered across sessions.
                hrTraceCard.staggeredAppear(index: 3)
                // Live GPS distance + pace (#1195) — a self-gating leaf owning its own recorder
                // observation, so a GPS fix re-renders only this line. Renders nothing until the first
                // accepted fix, so non-GPS / denied sessions leave the stack unchanged.
                DistancePaceRowIfPresent(recorder: model.gpsRecorder).staggeredAppear(index: 4)
                // Live-observing leaf: renders the sensor line (and its entrance stagger) only when a
                // standard fitness sensor is feeding metrics, refreshing on its own packets without
                // re-rendering the HR hero / zone rail above (scroll-stutter isolation).
                SensorRowIfPresent()
            }
            .screenPadding()
            .padding(.top, NoopMetrics.space3)
            // The bottom bar is a `.safeAreaInset`, so the scroll view ALREADY reserves the bar's full
            // height (plus the home-indicator inset) below the content — this is only optical breathing
            // room above it, not the clearance itself. Adding the bar height again here is what used to
            // push the last card needlessly far down.
            .padding(.bottom, NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        // #697/#horizontal-swipe parity, see ScreenScaffold. This is the full-screen in-exercise
        // tracker, up for the whole workout, so worth the same defensive fix.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // Floating discard / pause / elapsed / end controls sit in the bottom safe area so the scroll
        // content never owns the chrome and the controls can never scroll out of reach.
        //
        // `safeAreaInset(edge: .bottom)` is what makes this safe on a home-indicator phone: SwiftUI lays
        // the bar out INSIDE the container's bottom safe area (above the indicator) and then shrinks the
        // ScrollView's own safe area by the bar's height, so scroll content can never hide behind it and
        // the bar can never sit under the indicator. That is why the controls must NOT be in the scrolling
        // column, and why the column's own bottom padding stays small (see above).
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

    // MARK: - Hero

    /// Status pill + the two live hero numbers (heart rate, effort) on ONE row.
    ///
    /// TIME is deliberately not here: the bottom bar shows it at 32pt and never scrolls, so a second
    /// 56pt copy above cost ~110pt of the fold to say the same thing twice.
    private var heroRow: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            statusPill
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                // HR wins the room at accessibility text sizes — it is the number a wearer glances at
                // mid-set, and "EFFORT BUILDING" is the widest label on the row.
                heartRateBlock.layoutPriority(1)
                Spacer(minLength: NoopMetrics.space2)
                effortBlock
            }
        }
    }

    private var statusPill: some View {
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
        .padding(.vertical, NoopMetrics.spaceHalf)
        .background(NoopPanelSurface(tint: StrandPalette.metricRose, cornerRadius: 14))
        .clipShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Recording workout"))
    }

    /// Live HR — the screen's biggest number, still the smoothed `AppModel.bpm` and still zone-tinted.
    /// The "bpm" unit moved onto the value's baseline so the stack is two lines instead of three.
    private var heartRateBlock: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return VStack(alignment: .leading, spacing: 0) {
            Text("HEART RATE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                if let bpm = model.bpm {
                    CountUpText(value: Double(bpm),
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.rounded(48, weight: .semibold),
                                color: tint)
                } else {
                    Text("—")
                        .font(StrandFont.rounded(48, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text("bpm")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            // Keep the hero legible at accessibility text sizes rather than letting it clip.
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Heart rate"))
        .accessibilityValue(Text(heartRateAccessibilityValue))
    }

    /// Spoken HR. Absent input abstains — "No heart rate", never a stand-in number.
    private var heartRateAccessibilityValue: String {
        guard let bpm = model.bpm else { return String(localized: "No heart rate") }
        return String(localized: "\(bpm) bpm")
    }

    /// Live Effort — same `liveStrain` / Effort-scale conversion and `StrainGauge` intensity label as
    /// before, just sized as the hero's second number rather than a block of its own. Display-only;
    /// the captured value stays 0–100.
    private var effortBlock: some View {
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
        return VStack(alignment: .trailing, spacing: 0) {
            Text("EFFORT BUILDING")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.effortColor)
                .lineLimit(1).minimumScaleFactor(0.6)
            CountUpText(value: displayEffort,
                        format: { value in
                            effortScale == .whoop
                                ? String(format: "%.1f", value)
                                : "\(Int(value.rounded()))"
                        },
                        font: StrandFont.rounded(36, weight: .semibold),
                        color: StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            Text(StrainGauge.stateLabel(forFraction: fraction))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(effortAccessibilityLabel))
        .accessibilityValue(Text(StrainGauge.stateLabel(forFraction: fraction)))
    }

    /// The full HR trace since the workout started. Reads the same `activeWorkout.samples` that
    /// `captureWorkoutSample` appends (and `ActiveWorkoutPersistence` restores after a relaunch), and the
    /// same `zoneSet` / `lockedZone` the slider and lock row above use, so it updates on every sample.
    @ViewBuilder private var hrTraceCard: some View {
        if let w = model.activeWorkout {
            WorkoutHRTraceCard(samples: w.samples,
                               startSec: Int(w.start.timeIntervalSince1970),
                               zoneSet: zoneSet,
                               lockedZone: w.lockedZone)
        }
    }

    // MARK: - HR zone

    /// HR ZONE — the header capsule, the ZONE SLIDER (one continuous bar from zone 1's floor to HRmax with
    /// a live marker), where-in-the-zone caption, and the ZONE LOCK chips. Same zone derivation as before
    /// (`HRZoneSet.zoneNumber(forBPM:)` on the smoothed bpm); the slider still replaces the five-chip rail.
    /// Deliberately NOT wrapped in a card: the card's own 16pt inset would cost more than the grouping buys.
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
                    .padding(.vertical, NoopMetrics.spaceHalf)
                    .background(tint.opacity(0.12), in: Capsule())
            }
            ZoneSlider(zoneSet: zoneSet, bpm: model.bpm, lockedZone: locked)
            zoneLockRow(locked: locked)
            // Both captions in one stack at label spacing — they read as one explanatory footer, and the
            // 8pt section gap between them was pure height.
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(zonePlacementCaption)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                Text(zoneLockCaption(locked: locked))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// ZONE LOCK row: five chips, at most one on. Tapping the locked zone unlocks it; tapping another
    /// moves the lock. The phone gives a light tap on every toggle; the STRAP carries the in-session cues
    /// (`AppModel.evaluateZoneGuidance`), so the wearer never has to look.
    ///
    /// The chips are the old toggles trimmed to `zoneChipHeight` and given a 4pt gutter instead of 6.
    /// They stay a full-width fifth each, so the touch target is about 70×36pt — deliberately NOT cut
    /// below the mid-30s, because the height here is worth only a few points and these are the screen's
    /// only in-column controls.
    private func zoneLockRow(locked: Int?) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            ForEach(1...5, id: \.self) { z in
                let isLocked = locked == z
                let color = StrandPalette.hrZoneColor(z)
                Button {
                    StrandHaptic.light.play()
                    model.toggleWorkoutZoneLock(z)
                } label: {
                    HStack(spacing: 3) {
                        if isLocked {
                            Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold))
                        }
                        Text("Z\(z)")
                    }
                    .font(StrandFont.captionNumber)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(isLocked ? StrandPalette.surfaceBase : color)
                    .frame(maxWidth: .infinity, minHeight: Self.zoneChipHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isLocked ? color : color.opacity(0.14))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isLocked ? color : StrandPalette.hairline, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isLocked ? String(localized: "Unlock Zone \(z)")
                                                    : String(localized: "Lock Zone \(z)")))
                .accessibilityAddTraits(isLocked ? .isSelected : [])
            }
        }
    }

    private static let zoneChipHeight: CGFloat = 36

    private func zoneLockCaption(locked: Int?) -> String {
        guard let locked, let band = zoneSet.zones.first(where: { $0.number == locked }) else {
            return String(localized: "Tap a zone to lock it as your target. The strap buzzes twice when you're below it and once when you're above it.")
        }
        return String(localized: "Zone \(locked) locked · \(Int(band.lower))-\(Int(band.upper)) bpm. Two buzzes: speed up. One buzz: ease off.")
    }

    // MARK: - Bottom floating controls

    /// Diameter of the ICON FRAME inside each Liquid Glass circle in the bottom capsule.
    ///
    /// This was 56 with `.controlSize(.large)`, and that combination is what pushed the row past the
    /// screen: on iOS 26 `nativeLiquidGlassWorkoutControl` resolves to `.buttonStyle(.glass)`, which adds
    /// its OWN metrics-driven padding AROUND the label — so a 56pt label at `.large` occupies roughly
    /// 90pt. Three of those plus their gaps and the capsule insets left the elapsed clock with almost no
    /// room on a 390pt screen; the HStack then overflowed the capsule and the outer controls were clipped
    /// off the edge. 46 at `.regular` lands each control near 64pt, which fits with the clock intact.
    ///
    /// 46 (not 44) because the tap shape is a CIRCLE inscribed in this square — a 44pt frame would put
    /// the circle's usable width under the 44pt minimum at the top and bottom of the glyph.
    private static let bottomControlDiameter: CGFloat = 46
    /// Tight inset so the glass circles nest into the capsule ends (stopwatch-bar proportions).
    private static let bottomBarInset: CGFloat = 6

    /// One shared dark floating capsule: discard · pause · elapsed · end. Every destructive control on
    /// this screen lives here, outside the scroll, so none of them can be scrolled away from.
    ///
    /// Laid out in ONE HStack, so the timer and the controls cannot overlap. #1068 built this as a
    /// ZStack with the timer centred independently — deliberately, "so uneven label widths cannot pull
    /// the time off-center" — and that held while the bar carried one circle per side. #1533 added the
    /// discard and pause controls to the left group, and a centred 40pt timer then began where two
    /// 56pt circles plus their spacing end: `0:02` merely touched the pause button, and anything wider
    /// went under it. A field report of "two timers" was this one half-occluded, read as a duplicate of
    /// the big TIME readout above. `.allowsHitTesting(false)` on the timer was already a tell that it
    /// sat beneath something tappable. (The big TIME readout is gone now, so this is the only clock.)
    ///
    /// The trade is deliberate: the timer sits centred in the space the buttons leave rather than in the
    /// bar, so it reads slightly right of true centre because the left chrome is heavier. That is the
    /// cost of the layout being unable to collide at all. The buttons keep the positions they have
    /// shipped with — moving pause to the right would centre the timer better and would also move a
    /// control under the thumb of everyone already using this screen.
    ///
    /// ROOM (redone for the 46pt/`.regular` control, see `bottomControlDiameter`): three controls at
    /// ~64pt rendered = 192, three 8pt gaps = 24, the capsule's own 6pt inset each side = 12, and the
    /// 16pt page gutter each side = 32. On a 390pt screen that leaves the clock about 122pt against
    /// roughly 115pt for `1:30:00` at 32pt monospaced — it fits, and `minimumScaleFactor` covers a 375pt
    /// device and larger Dynamic Type by scaling the clock rather than overflowing the capsule.
    private var bottomControlRow: some View {
        HStack(spacing: NoopMetrics.space2) {
            deleteWorkoutGlassButton
            pauseWorkoutGlassButton
            bottomElapsedTimer
                .allowsHitTesting(false)
                // Scaling down is the honest failure when the room runs out: truncating a clock to
                // "1:30:0" would be worse than a smaller one. Same idiom the rest of this file uses.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // NEVER raise the timer's priority. Sizing it BEFORE the three circles inverts which
                // element gives way: a half-drawn pause button is worse than a smaller clock, and a
                // clipped control is the failure this whole layout exists to remove.
                //
                // LOWERING it is the belt to that brace, and it is why the bar cannot repeat the #1533
                // overflow. The circles' footprint is NOT a number this file controls — on iOS 26 the
                // glass button style adds its own metrics-driven padding around the 46pt label — so
                // "equal priority is enough because fixed frames are inflexible" is an assumption about
                // a system control. At -1 the buttons are sized first unconditionally and the clock
                // scales into whatever is left, down to nothing, instead of pushing a control off the
                // capsule's edge.
                .layoutPriority(-1)
            endWorkoutGlassButton
        }
        .padding(Self.bottomBarInset)
        .background {
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: true)
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space2)
        // Clearance ABOVE the home indicator, on top of the safe-area inset `safeAreaInset(edge: .bottom)`
        // already applies — the bar is laid out inside the safe area, so this is breathing room, not the
        // indicator clearance itself. Kept at 12 (not trimmed with the rest of the layout) because on a
        // device with NO home indicator it is the ONLY gap between the capsule and the screen edge.
        .padding(.bottom, NoopMetrics.space3)
    }

    /// The screen's ONLY elapsed clock now (the hero TIME block it used to duplicate is gone), from the
    /// same pause-aware `activeWorkout.elapsed()` + `TimelineView` source — plain primary text, no card /
    /// glass / capsule behind it (the shared bar owns the surface).
    private var bottomElapsedTimer: some View {
        Group {
            if let workout = model.activeWorkout {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(Self.elapsed(seconds: workout.elapsed()))
                        .font(StrandFont.number(32)).monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(Self.elapsed(seconds: workout.elapsed())))
            }
        }
        // minWidth 0 so the clock is allowed to give up ALL of its width to the controls rather than
        // insisting on an ideal size the capsule cannot pay for.
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var endWorkoutGlassButton: some View {
        Button { showEndConfirm = true } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17, weight: .semibold))
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
                .font(.system(size: 17, weight: .semibold))
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
            WorkoutTypeIcon(workoutType: activeSportName, size: 20, weight: .semibold)
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
    ///
    /// `.regular`, not `.large`: the glass style's padding is driven by the control size and is added
    /// AROUND the 46pt label, so `.large` inflated each control to ~90pt and overflowed the bar.
    @ViewBuilder
    func nativeLiquidGlassWorkoutControl() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .regular) {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
    }
}

// MARK: - Compact inline read-out

/// One "LABEL value" pair for the thin single-line read-outs (GPS, sensor) at the bottom of the stack.
/// These used to be full stat cards (~90pt each); as a line they cost about 36pt and say the same thing.
private struct InlineReadout: View {
    let label: String
    let value: String
    var tint: Color = StrandPalette.effortColor

    var body: some View {
        HStack(spacing: NoopMetrics.space1) {
            Text(label)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

/// The shared thin pill the inline read-out lines sit in.
private extension View {
    func inlineReadoutRow() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NoopMetrics.space3)
            .padding(.vertical, NoopMetrics.space2)
            .background(NoopPanelSurface(tint: StrandPalette.effortColor,
                                         cornerRadius: NoopVisualStyle.pillRadius))
            .clipShape(Capsule())
    }
}

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each metric is dropped when its value is absent, and the WHOLE line (pill + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Speed follows the exercise-distance preference; cadence stays per-minute and power in watts.
/// Tinted with the Effort world so it reads as part of the hero, not a competing accent. Nothing
/// here touches HR / zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row, not the
/// HR hero / zone rail above. The gate and its absent-value semantics are preserved verbatim; only the
/// chrome changed (stat card → one thin line) and the stagger slot moved with the shortened stack.
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
            HStack(spacing: NoopMetrics.space3) {
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

/// Live GPS distance + average pace on the active-workout screen, for distance sports (#1195). The main
/// gap this closes: the recorder already computes and publishes `distanceM` / `paceSecPerKm` on every
/// accepted fix, but they were only ever shown in the post-workout detail view — never live.
///
/// A standalone leaf that owns its OWN `@ObservedObject` on the recorder (the parent `LiveWorkoutView`
/// does not observe it), so a GPS fix re-renders only this line — not the HR hero above, the same
/// scroll-stutter isolation as `SensorRowIfPresent`. Self-gates to nothing until the first accepted fix,
/// so a denied-permission or GPS-less (Mac) session shows no empty row. Mirrors Android's gated
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
        // after a GPS one would show the previous session's stale distance. Together they mean "a GPS
        // recording is live AND has at least one accepted fix" — the Android `gpsEnabled && track` twin.
        if recorder.isRecording, recorder.pointCount > 0 {
            HStack(spacing: NoopMetrics.space4) {
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

/// The whole session's heart rate since the workout started (x = time since start, y = bpm), read
/// against the wearer's dynamic Karvonen zones: each zone boundary is a dashed line in its zone colour,
/// labelled Z1…Z5 on the leading axis, every zone band carries a faint wash of its colour, and a LOCKED
/// zone's band is raised so the target reads at a glance.
///
/// COLLAPSIBLE (compact layout). The chart is the tallest thing on the screen (~200pt with its card) and
/// the least glanceable mid-set, so it now sits behind a disclosure header: a tap on the whole title row
/// expands it, and the state is remembered in `@AppStorage` so a wearer who wants it open keeps it open
/// across sessions. Collapsed it costs about 42pt.
///
/// All the shaping is `WorkoutHRTrace` (StrandAnalytics, unit-tested): the samples are bucketed to at
/// most ~600 points so a two-hour session costs the same per render as a ten-minute one, the line breaks
/// across capture gaps (a pause records no samples), and the y-range frames the data between its
/// neighbouring zone lines plus the locked band, never 0…220.
///
/// The downsample memo (`TraceCache`) is untouched and still keyed the same way. Collapsing simply does
/// not ask it for a shape at all — the cache is `@State`, so re-expanding hits the memo rather than
/// re-bucketing, exactly as a live tick does.
///
/// The x-axis is WALL time since start, so a pause shows as a gap; the elapsed clock in the bottom bar is
/// pause-aware active time, so the two differ by the paused duration.
private struct WorkoutHRTraceCard: View {
    let samples: [HRSample]
    let startSec: Int
    let zoneSet: HRZoneSet
    let lockedZone: Int?

    /// Remembered across sessions, per the compact layout. Default collapsed.
    @AppStorage("liveWorkoutTraceExpanded") private var expanded = false

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

    /// Memo of the shaped trace. The card re-renders on every live tick of the screen (bpm, the clock),
    /// but its points only change when a sample lands; re-bucketing the whole session each render was
    /// the cost. A reference held in @State, so filling it never invalidates the view.
    @State private var cache = TraceCache()

    var body: some View {
        NoopCard(padding: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                disclosureHeader
                if expanded { expandedBody }
            }
        }
    }

    private var disclosureHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: NoopMetrics.space2) {
                Text("HEART RATE SINCE START")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            // The whole row is the target: the card's full width by a 44pt-tall strip, so the
            // disclosure meets the touch-target rule even though its label is an 11pt overline.
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
        let xMax = max(60, points.last?.offset ?? 0)
        return Group {
            if points.isEmpty {
                Text(String(localized: "Waiting for heart rate."))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: Self.chartHeight)
            } else {
                chart(points: points, yDomain: yDomain, xMax: xMax)
            }
        }
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
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(edge.color.opacity(isLockedEdge(edge) ? 0.9 : 0.5))
            }
            ForEach(points, id: \.offset) { p in
                LineMark(x: .value("Time", p.offset),
                         y: .value("BPM", p.bpm),
                         series: .value("Segment", p.segment))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(StrandPalette.metricRose)
            }
        }
        .chartXScale(domain: 0...xMax)
        .chartYScale(domain: yDomain)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: WorkoutHRTrace.xTicks(maxOffset: xMax)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel {
                    if let s = value.as(Double.self) {
                        Text(ActiveWorkoutClock.clock(Int(s)))
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
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
                            .font(StrandFont.footnote)
                            .foregroundStyle(edge.color)
                    }
                }
            }
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
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
/// width draw true to scale). A marker rides the bar at the current smoothed bpm, showing WHERE in the
/// zone the wearer is, not just which one. A locked zone's segment is raised and outlined; the rest dim.
///
/// The marker glides between readings; under Reduce Motion / quiet motion / Low Power (`NoopMotionState`)
/// it jumps instead. The animation always settles, so it costs nothing between HR updates.
///
/// Heights are trimmed for the compact layout (36 → 30pt overall); the geometry is otherwise unchanged.
private struct ZoneSlider: View {
    let zoneSet: HRZoneSet
    let bpm: Int?
    let lockedZone: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    private static let barHeight: CGFloat = 14
    private static let lockedHeight: CGFloat = 22
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
            .frame(height: 30)
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
            .frame(width: 6, height: 28)
            .overlay(Capsule().strokeBorder(StrandPalette.surfaceBase, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Session stats + Today's Effort vs target

/// The session's AVG / PEAK heart rate AND today's Effort against the day's recommended ceiling, in one
/// card. They were two cards with a 26pt gap between them, and the stat row's third column repeated the
/// Effort already shown in the hero above — so the merge costs no information.
///
/// Today's Effort so far — live — against the day's recommended ceiling, on the wearer's Effort scale:
/// "9.8 / 14". A bar shows the day before this session (dim), what this session has added (bright), and
/// a notch at the target.
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
/// ABSENT INPUT ABSTAINS: AVG/PEAK show "—" until the session has a reading, and the DAY column shows
/// "—" until the one-off load lands. Nothing is substituted for a missing value.
///
/// KNOWN LIMIT: if Today (or the daily pass) had already scored part of THIS session's heart rate before
/// the screen opened — e.g. reopened after a relaunch mid-workout — that part is counted twice. It is a
/// live pacing read-out, not a stored score; the day's number of record is still the daily pass.
private struct SessionSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    let avgHr: Int
    let peakHr: Int
    let sessionEffort: Double
    let effortScale: EffortScale

    @State private var loaded = false
    @State private var baseline: Double = 0
    @State private var target100: Double?
    @State private var targetUpper21: Int?

    var body: some View {
        // The stat row renders immediately (it needs no load), and the day-vs-target strip appears under
        // it when the one-off read lands. The card is never zero-height, so `.task` is always attached to
        // a view that actually renders — the reason the old card carried a 1pt stand-in.
        NoopCard(padding: NoopMetrics.space3, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                statRow
                if loaded { dayStrip }
            }
        }
        .accessibilityElement(children: .combine)
        .task { await load() }
    }

    private var statRow: some View {
        HStack(spacing: 0) {
            stat(String(localized: "AVG"), avgHr > 0 ? "\(avgHr)" : "—",
                 tint: avgHr > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            statDivider
            stat(String(localized: "PEAK"), peakHr > 0 ? "\(peakHr)" : "—",
                 tint: peakHr > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            statDivider
            // Day Effort so far / today's recommended ceiling, on the wearer's scale. The label reuses
            // the already-translated "Day" and "target" keys rather than introducing a new string.
            stat(Self.dayTargetLabel,
                 loaded ? "\(UnitFormatter.effortDisplay(dayEffort, scale: effortScale))/\(targetText)" : "—",
                 tint: pastTarget ? StrandPalette.metricRose : StrandPalette.textPrimary)
        }
    }

    /// The bar: the whole day so far, the part this session added, and a notch at the target.
    private var dayStrip: some View {
        let day = dayEffort
        let domain = min(StrainScorer.maxStrain, max((target100 ?? 0) * 1.2, day * 1.1, 10))
        let beforeFrac = min(max(baseline / domain, 0), 1)
        let dayFrac = min(max(day / domain, 0), 1)
        let targetFrac = target100.map { min(max($0 / domain, 0), 1) }
        let sessionText = UnitFormatter.effortDeltaDisplay(max(0, day - baseline), scale: effortScale)
        return VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
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
                            .frame(width: 2, height: 16)
                            .offset(x: CGFloat(targetFrac) * w - 1)
                    }
                }
                .frame(width: w, height: NoopMetrics.indicatorTrackHeight, alignment: .leading)
                .frame(height: geo.size.height)
            }
            .frame(height: 16)
            Text(pastTarget ? String(localized: "Past today's recommended ceiling.")
                            : String(localized: "This workout +\(sessionText)"))
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(spacing: NoopMetrics.spaceHalf) {
            Text(title)
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value)
                .font(StrandFont.number(24))
                .foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 32)
    }

    /// "DAY / TARGET" built from the two existing localized words, so the merged card adds no new
    /// translation key. `localizedUppercase` keeps the caps-label convention in every language that
    /// has a case distinction and is a no-op in the ones that don't.
    private static var dayTargetLabel: String {
        "\(String(localized: "Day").localizedUppercase) / \(String(localized: "target").localizedUppercase)"
    }

    private var dayEffort: Double {
        let denominator = StrainScorer.logMapDenominator(method: PuffinExperiment.effortMethod,
                                                         sex: model.profile.sex)
        return StrainScorer.combinedStrain(baseline, sessionEffort, denominator: denominator)
    }

    private var pastTarget: Bool {
        guard loaded, let target100 else { return false }
        return dayEffort >= target100
    }

    private var targetText: String {
        guard let target100 else { return "–" }
        // On the WHOOP scale the band top is a whole WHOOP strain (14), shown as WHOOP states it.
        if effortScale == .whoop, let targetUpper21 { return "\(targetUpper21)" }
        return "\(Int(target100.rounded()))"
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
