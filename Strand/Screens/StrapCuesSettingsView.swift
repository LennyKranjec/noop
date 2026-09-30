import SwiftUI
import StrandDesign
import StrandAnalytics
#if os(iOS)
import UIKit
#endif

/// Settings → Strap cues: every cue with its switch, the sitting-break interval, quiet hours, the daily
/// budget, the Motion & Fitness status (with the button that asks for it), the pattern each cue plays, and
/// what the recent cues actually did. Plain about the limits: cues need the strap connected to this phone,
/// and the sitting-break nudge detects LOW MOVEMENT, not sitting itself.
///
/// Observes only the engine (and two UserDefaults keys), so it re-renders on a cue or a minute tick, not on
/// the ~1 Hz strap stream. Reached from Settings / More (entry point owned by the design packages).
struct StrapCuesSettingsView: View {
    @ObservedObject var engine: StrapCueEngine

    /// The Wrist-alerts master (same raw key as Automations' "Wrist alerts"). It holds only the evening cues
    /// here (wind-down, screens off — `StrapCueKind.heldByWristAlertsMaster`) plus the HR / strain wrist
    /// alerts in Automations; the sitting break, rewards and penalties follow their own switches.
    @AppStorage("notif.masterEnabled") private var wristAlertsMaster = false
    /// The older strap-offload inactivity reminder (Automations). Same raw key as `InactivityPrefs.enabled`.
    @AppStorage("inactivity.enabled") private var legacyInactivity = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScreenScaffold(title: "Strap cues",
                       subtitle: "Purposeful vibrations on your strap: move, breathe, wind down, and timers you start.") {
            limitsCard
            sittingCard
            breathingCard
            eveningCard
            focusCard
            meditationCard
            momentsCard
            rulesCard
            vocabularyCard
            historyCard
        }
        .onAppear { engine.tick() }
    }

    // MARK: - Limits

    private var limitsCard: some View {
        CueCard(icon: "applewatch.radiowaves.left.and.right", title: "How cues reach you") {
            Text("Cues need the strap connected to this phone. If it isn't reachable, or it is refusing writes, the cue is logged as not delivered — never as sent.")
                .cueHelp()
            Text("Timers and the breathing pacer run while NOOP is open or woken by the strap in the background; iOS can pause it otherwise.")
                .cueHelp()
            if !wristAlertsMaster {
                Divider().overlay(StrandPalette.hairline)
                Text("Wrist alerts are off, so the evening cues (wind-down, screens off) stay quiet. The sitting break, rewards and penalties follow their own switches; timers you start still buzz.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CueToggle(label: "Wrist alerts", help: "Also governs the evening cues here. The sitting break, rewards and penalties have their own switches.",
                      isOn: $wristAlertsMaster)
        }
    }

    // MARK: - Sitting break

    private var sittingCard: some View {
        CueCard(icon: "figure.walk", title: "Sitting-break nudge", active: engine.settings.sittingBreakEnabled) {
            Text("Two short taps when \(engine.settings.sittingIntervalMinutes) minutes pass without a movement break — a cue for about 5 minutes of easy walking.")
                .cueHelp()
            CueToggle(label: "Sitting-break nudge", help: "On by default.", isOn: binding(\.sittingBreakEnabled))
            if engine.settings.sittingBreakEnabled {
                Picker("Interval", selection: binding(\.sittingIntervalMinutes)) {
                    ForEach(StrapCueSettings.sittingIntervalOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Minutes without a break before the nudge")

                Text(sittingStatus)
                    .font(StrandFont.subhead)
                    .foregroundStyle(sittingStatusIsProblem ? StrandPalette.statusWarning : StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                motionRow

                Text("It detects low movement, not sitting itself. A wrist and a phone can't tell sitting from standing still, so it counts minutes of movement: about 2 minutes of walking (from the phone's motion and steps), or of chores that lift your heart rate while the phone moves with you, is a break. Ten steps to the kitchen is not.")
                    .cueHelp()
                Text("Why 30 minutes: in a lab study, 5 minutes of easy walking every 30 minutes lowered the rise in blood sugar and blood pressure after meals more than the other break schedules tested (Duran et al., 2023; see also Dunstan et al., 2012). Short-term lab results, not a promise about long-term health.")
                    .cueHelp()
                Text("The strap's own steps arrive minutes late, so live movement comes from this phone; the strap's steps only correct the record afterwards. Keep the phone with you: if it lies still while your strap shows you moving, the nudge pauses rather than guess.")
                    .cueHelp()
                if legacyInactivity {
                    Divider().overlay(TelosColor.lineSoft)
                    if engine.supersedesLegacyInactivityBuzz {
                        // The legacy buzz stands down while this nudge can fire (BLEManager.maybeBuzzInactivity),
                        // so there is no double buzz to warn about — only a switch that is currently idle.
                        Text("The older inactivity reminder in Automations is paused while this nudge runs.")
                            .cueHelp()
                    } else {
                        Text("The older inactivity reminder in Automations is also on, so one sitting stretch can buzz twice.")
                            .font(TelosType.footnote)
                            .foregroundStyle(TelosColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        NoopButton("Turn the older reminder off", systemImage: "bell.slash", kind: .secondary) {
                            legacyInactivity = false
                        }
                    }
                }
            }
        }
    }

    private var motionRow: some View {
        HStack(alignment: .center, spacing: TelosSpace.m) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text("Motion & Fitness").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(motionStatusText).font(StrandFont.footnote)
                    .foregroundStyle(engine.motionAccess == .authorized ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if engine.motionAccess == .notDetermined {
                NoopButton("Allow", kind: .secondary) {
                    Task { await engine.requestMotionAccess() }
                }
            } else if engine.motionAccess == .denied || engine.motionAccess == .restricted {
                openSettingsButton
            }
        }
        .padding(.vertical, TelosSpace.xs)
    }

    /// Once Motion & Fitness is decided iOS never prompts again, so the only way back is the Settings app.
    private var openSettingsButton: some View {
        #if os(iOS)
        return NoopButton("Open Settings", kind: .secondary) {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        #else
        return EmptyView()
        #endif
    }

    private var motionStatusText: String {
        switch engine.motionAccess {
        case .authorized: return String(localized: "Allowed")
        case .notDetermined: return String(localized: "Not asked yet — the nudge stays silent until you allow it.")
        case .denied: return String(localized: "Denied — the nudge stays silent. Allow it in Settings → Privacy → Motion & Fitness.")
        case .restricted: return String(localized: "Restricted on this device — the nudge stays silent.")
        case .unavailable: return String(localized: "Not available on this device — the nudge stays silent.")
        }
    }

    private var sittingStatus: String {
        let interval = engine.settings.sittingIntervalMinutes
        switch engine.sittingVerdict {
        case .off:
            return String(localized: "Off.")
        case .abstain(let a):
            return a.text
        case .suppressed(let s):
            return s.text
        case .accumulating(let secs):
            return String(localized: "Low movement for \(secs / 60) of \(interval) min.")
        case .awaitingBreak(let since):
            let t = StrapCueEngine.clock(Date(timeIntervalSince1970: TimeInterval(since)))
            return String(localized: "Nudged at \(t) — waiting for your break.")
        case .retryLater:
            return String(localized: "The last nudge couldn't reach the strap; trying again in a few minutes.")
        case .nudge:
            if let h = engine.lastHold { return h.text }
            return String(localized: "A nudge is due.")
        }
    }

    private var sittingStatusIsProblem: Bool {
        if case .abstain = engine.sittingVerdict { return true }
        if case .retryLater = engine.sittingVerdict { return true }
        return false
    }

    // MARK: - Breathing pacer

    private var breathingCard: some View {
        CueCard(icon: "wind", title: "Breathing pacer", active: engine.settings.breathingPacerEnabled) {
            Text("About 6 breaths a minute: one short pulse to breathe in, one long to breathe out. A quiet 90-second reading before and after (no pulses, breathe normally) gives an honest before/after.")
                .cueHelp()
            CueToggle(label: "Breathing pacer", help: "Off by default.", isOn: binding(\.breathingPacerEnabled))
            if engine.settings.breathingPacerEnabled {
                Picker("Length", selection: binding(\.breathingMinutes)) {
                    ForEach(StrapCueSettings.breathingOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                if let end = engine.breathingEndsAt {
                    Text(breathPhaseText).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    HStack {
                        Text("Ends in").cueHelp()
                        Text(end, style: .timer).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                    NoopButton("Stop", systemImage: "stop.fill", kind: .secondary) { engine.stopBreathing() }
                } else {
                    NoopButton("Start pacer", systemImage: "play.fill", kind: .primary) { engine.startBreathing() }
                }
            }
        }
    }

    private var breathPhaseText: String {
        switch engine.breathingPhase {
        case .preQuietStart?: return String(localized: "Quiet reading — breathe normally, sit still.")
        case .pacedStart?: return String(localized: "Breathe with the strap.")
        case .pacedEnd?: return String(localized: "Quiet reading — breathe normally again.")
        case .postQuietEnd?, nil: return String(localized: "Starting…")
        }
    }

    // MARK: - Evening

    private var eveningCard: some View {
        CueCard(icon: "moon.stars", title: "Evening cues",
                active: engine.settings.windDownEnabled || engine.settings.screensOffEnabled) {
            Text("Timed from your sleep plan's bedtime.").cueHelp()
            if !engine.sleepPlanAvailable {
                Text("No sleep plan yet (it needs a target wake time or a week of nights), so these stay quiet.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CueToggle(label: "Wind-down", help: "Two slow, long pulses when your wind-down hour starts.",
                      isOn: binding(\.windDownEnabled))
            CueToggle(label: "Screens off", help: "Three short taps 30 minutes before lights out — a common habit, not a proven optimum.",
                      isOn: binding(\.screensOffEnabled))
        }
    }

    // MARK: - Focus block

    private var focusCard: some View {
        CueCard(icon: "timer", title: "Focus blocks", active: engine.settings.focusBlocksEnabled) {
            Text("Start a block; one extra-long pulse when it ends. The sitting-break nudge waits for the end.").cueHelp()
            CueToggle(label: "Focus blocks", help: "Off by default.", isOn: binding(\.focusBlocksEnabled))
            if engine.settings.focusBlocksEnabled {
                Picker("Length", selection: binding(\.focusMinutes)) {
                    ForEach(StrapCueSettings.focusOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                if let end = engine.focusEndsAt, end > Date() {
                    HStack {
                        Text("Ends in").cueHelp()
                        Text(end, style: .timer).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                    NoopButton("Cancel block", systemImage: "xmark", kind: .secondary) { engine.cancelFocusBlock() }
                } else {
                    NoopButton("Start focus block", systemImage: "play.fill", kind: .primary) { engine.startFocusBlock() }
                }
            }
        }
    }

    // MARK: - Meditation timer

    private var meditationCard: some View {
        CueCard(icon: "leaf", title: "Silent meditation timer", active: engine.settings.meditationTimerEnabled) {
            Text("No sound, no screen: one extra-long pulse when the time is up. A completed timer is logged as meditation.").cueHelp()
            CueToggle(label: "Meditation timer", help: "Off by default. 10 minutes is the minimum.",
                      isOn: binding(\.meditationTimerEnabled))
            if engine.settings.meditationTimerEnabled {
                Picker("Length", selection: binding(\.meditationMinutes)) {
                    ForEach(StrapCueSettings.meditationOptions, id: \.self) { Text("\($0) min").tag($0) }
                }
                .pickerStyle(.segmented)
                if let end = engine.meditationEndsAt, end > Date() {
                    HStack {
                        Text("Ends in").cueHelp()
                        Text(end, style: .timer).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                    }
                    NoopButton("Cancel", systemImage: "xmark", kind: .secondary) { engine.cancelMeditation() }
                } else {
                    NoopButton("Start meditation", systemImage: "play.fill", kind: .primary) { engine.startMeditation() }
                }
            }
        }
    }

    // MARK: - Lift rest timer + reward / penalty moments

    private var momentsCard: some View {
        CueCard(icon: "sparkles", title: "Workouts and big moments",
                active: engine.settings.restOverEnabled || engine.settings.rewardCuesEnabled
                    || engine.settings.penaltyCuesEnabled) {
            CueToggle(label: "Rest over", help: "Long, then short when a Telos Lift rest timer ends. You started the timer, so it isn't counted in the daily budget or held by quiet hours.",
                      isOn: binding(\.restOverEnabled))
            CueToggle(label: "Rewards", help: "Short, short, long with a PR, a finished quest or goal, or a level up. Counted in the daily budget, never while you sleep, once per event.",
                      isOn: binding(\.rewardCuesEnabled))
            CueToggle(label: "Penalties", help: "Two extra-long pulses with the daily penalty card or a broken streak. Same limits as rewards.",
                      isOn: binding(\.penaltyCuesEnabled))
        }
    }

    // MARK: - Rules

    private var rulesCard: some View {
        CueCard(icon: "slider.horizontal.3", title: "Limits") {
            Stepper(value: binding(\.dailyBudget), in: StrapCueSettings.budgetRange) {
                VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                    Text("Daily budget: \(engine.settings.dailyBudget)").font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Unrequested cues per day. \(engine.remainingBudget) left today. Never two cues within a minute.")
                        .cueHelp()
                }
            }
            HStack(spacing: TelosSpace.m) {
                Text("Quiet hours").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                DatePicker("", selection: minutesBinding(\.quietStartMin), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.compact)
                    .accessibilityLabel("Quiet hours start")
                Text("to").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                DatePicker("", selection: minutesBinding(\.quietEndMin), displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.compact)
                    .accessibilityLabel("Quiet hours end")
            }
            Text("No unrequested cue in quiet hours. Set both to the same time for none.").cueHelp()
            CueToggle(label: "Buzz the phone as a fallback",
                      help: "Only while NOOP is on screen, when the strap can't be reached. It is logged as a phone buzz, not a strap cue.",
                      isOn: binding(\.phoneFallbackEnabled))
        }
    }

    // MARK: - Vocabulary

    private var vocabularyCard: some View {
        CueCard(icon: "waveform.path", title: "What each cue feels like") {
            ForEach(StrapCuePattern.allCases, id: \.self) { p in
                HStack {
                    Text(Self.patternName(p)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                    Text(p.feltAs).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private static func patternName(_ p: StrapCuePattern) -> String {
        switch p {
        case .move: return String(localized: "Move")
        case .inhale: return String(localized: "Breathe in")
        case .exhale: return String(localized: "Breathe out")
        case .windDown: return String(localized: "Wind down")
        case .screensOff: return String(localized: "Screens off")
        case .timesUp: return String(localized: "Time's up")
        case .restOver: return String(localized: "Rest over")
        case .reward: return String(localized: "Reward")
        case .penalty: return String(localized: "Penalty")
        }
    }

    // MARK: - History

    private var historyCard: some View {
        CueCard(icon: "list.bullet.rectangle", title: "Recent cues") {
            if engine.history.isEmpty {
                Text("Nothing yet.").cueHelp()
            } else {
                ForEach(Array(engine.history.suffix(10).reversed())) { e in
                    HStack(alignment: .firstTextBaseline, spacing: TelosSpace.s) {
                        Text(e.at, style: .time).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                        Text(e.text).font(StrandFont.footnote)
                            .foregroundStyle(e.delivered == false ? StrandPalette.statusWarning : StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Bindings

    private func binding<T>(_ kp: WritableKeyPath<StrapCueSettings, T>) -> Binding<T> {
        Binding(get: { engine.settings[keyPath: kp] },
                set: { v in engine.update { $0[keyPath: kp] = v } })
    }

    /// A minute-of-day setting as a Date for the compact time picker (today's date, local clock).
    private func minutesBinding(_ kp: WritableKeyPath<StrapCueSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = engine.settings[keyPath: kp]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                engine.update { $0[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
            })
    }
}

// MARK: - Local card + row

private struct CueCard<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    var active: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        StrandCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: TelosSpace.m) {
                HStack(spacing: TelosSpace.s) {
                    Image(systemName: icon)
                        .foregroundStyle(active ? StrandPalette.accent : StrandPalette.textSecondary)
                        .accessibilityHidden(true)
                    Text(title).font(TelosType.headline).foregroundStyle(TelosColor.textPrimary)
                    Spacer(minLength: 0)
                    if active {
                        Text("ON").telosScale()
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
                content()
            }
        }
    }
}

private struct CueToggle: View {
    let label: LocalizedStringKey
    let help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: TelosSpace.xxs) {
                Text(label).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                Text(help).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
    }
}

private extension Text {
    /// Secondary explanatory copy inside a cue card.
    func cueHelp() -> some View {
        self.font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
