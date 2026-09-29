import SwiftUI
import Combine
import StrandDesign

// SleepAlarmSheet.swift — the Sleep tab's wake buzz.
//
// Opened from the alarm button in the Sleep hero, mirrored to Customize at the other end of that row.
// Three things and nothing else: a quarter-hour wake time, an on/off switch, and a Test that fires the
// REAL ring so the wrist can be felt before trusting it at 07:00.
//
// The settings and the timing rules live in `WakeBuzzAlarm` (pure, unit-tested); the ring itself is
// `AppModel.wakeBuzz`. This file only binds them to controls — and it observes the RINGER, never the
// AppModel: the model publishes 1–3×/s while a strap streams, and a wheel picker re-rendering at that
// rate is exactly the jank `appModelRef` (ModelReferenceEnvironment) exists to prevent. The ringer
// publishes twice a morning.

struct SleepAlarmSheet: View {
    @Environment(\.appModelRef) private var modelRef

    var body: some View {
        // Same contract an `@EnvironmentObject var model: AppModel` carried: a host that injected
        // neither the ref nor a live AppModel could not have shown the Sleep tab this opens from.
        // Explicit `return` so this stays a plain function body rather than a result-builder one — the
        // `let` is a binding, not a view.
        let model = requireAppModel(modelRef)
        return SleepAlarmSheetContent(ringer: model.wakeBuzz, live: model.live)
    }
}

private struct SleepAlarmSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ringer: WakeBuzzRinger

    /// The live link, held WITHOUT observing it — `LiveState` publishes 1–3×/s while a strap streams, and
    /// this sheet carries a wheel picker (the whole reason it observes the ringer and not the model). Only
    /// the one flag this screen needs is pulled off it, into `@State`, via `.onReceive` — the documented
    /// idiom in `ModelReferenceEnvironment`.
    let live: LiveState

    /// Whether the strap is connected RIGHT NOW. This alarm is sent by the phone over BLE, so this is the
    /// difference between an alarm that can fire and one that cannot, and the user could previously not see
    /// it anywhere on this screen.
    @State private var strapConnected = false

    /// Whether the strap is REFUSING NOOP's writes ("Authentication is insufficient") — connected, but the
    /// encrypted pairing is gone from this phone, so nothing NOOP sends can land.
    ///
    /// THE FACT THIS SCREEN WAS MISSING. `strapConnected` is true in that state, so the reach row drew a
    /// green tick and said "Strap connected — NOOP can buzz it", which is true of the link and false of the
    /// alarm. A real 5/MG owner (fw 50.42.1.0, after an iPhone reset) read that for days while the diagnosis
    /// AND the fix sat in the strap log, hundreds of lines deep, where nobody looks.
    @State private var strapWritesRefused = false
    /// Whatever the BLE layer has OBSERVED about this bond (#78 / #747 / #1635 / the refused-write hint).
    /// Preferred over anything this screen could assert, because it is closer to the evidence.
    @State private var pairingHint: String?

    /// The persisted alarm, read straight from the same defaults keys `WakeBuzzAlarm` writes, so the
    /// Sleep header's filled/empty alarm glyph tracks this switch with no plumbing in between.
    @AppStorage(WakeBuzzAlarm.Key.enabled) private var alarmOn = false
    @AppStorage(WakeBuzzAlarm.Key.minutes) private var minutes = WakeBuzzAlarm.defaultMinutes

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    alarmCard
                    testCard
                    honestyCard
                }
                .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Wake buzz")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(StrandPalette.accent)
        #if os(macOS)
        .frame(minWidth: NoopMetrics.editorSheetMinWidth, minHeight: NoopMetrics.editorSheetMinHeight)
        #endif
        .onAppear {
            // A value written by an older build (or a corrupted defaults entry) could sit between two
            // slots, which would leave the wheel showing no selection. Snap it once on open.
            minutes = WakeBuzzAlarm.snapped(minutes)
            // Re-resolve the schedule as the sheet opens. `reschedule` is idempotent and cheap, and it is
            // what fills `nextFire` — without this, opening the sheet on a launch where the resolve was
            // skipped shows "Not scheduled yet" under an alarm that is switched on, and the caption is the
            // only place the user can check the alarm is really armed.
            ringer.reschedule()
        }
        .onReceive(live.$connected.removeDuplicates()) { strapConnected = $0 }
        // Both flip at most a handful of times per session, so they cost nothing next to the 1–3 Hz stream
        // this screen deliberately does not observe.
        .onReceive(live.$strapWritesRefused.removeDuplicates()) { strapWritesRefused = $0 }
        .onReceive(live.$pairingHint.removeDuplicates()) { pairingHint = $0 }
    }

    // MARK: - Time + on/off

    private var alarmCard: some View {
        StrandCard(padding: 20, tint: alarmOn ? StrandPalette.restColor : nil) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buzz my strap awake")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(nextFireCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Toggle("", isOn: $alarmOn)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .accessibilityLabel("Buzz my strap awake")
                }
                .frame(minHeight: 42)

                if alarmOn {
                    Divider().overlay(StrandPalette.hairline)
                    reachRow
                    Divider().overlay(StrandPalette.hairline)
                    Text("Wake time").strandOverline()
                    timeWheel
                }
            }
            // One re-schedule hook for both controls: the ringer resolves the next instant, re-arms the
            // timer and (dis)arms the backup notification, and self-gates on the switch being on.
            .onChangeCompat(of: alarmOn) { _ in ringer.reschedule() }
            .onChangeCompat(of: minutes) { _ in ringer.reschedule() }
        }
    }

    /// The armed time, from the ringer's OWN resolved instant rather than the picker's raw minutes — if
    /// the two ever disagree, the one that will actually buzz is the one worth showing. Never an invented
    /// time: the switch being ON with nothing resolved is its own line, not "Off", because reading "Off"
    /// next to a switch that is on tells the user the opposite of the truth.
    private var nextFireCaption: String {
        guard alarmOn else { return String(localized: "Off") }
        guard let next = ringer.nextFire else { return String(localized: "Not scheduled yet") }
        let c = Calendar.current.dateComponents([.hour, .minute], from: next)
        return String(localized: "Next buzz \(WakeBuzzAlarm.timeLabel((c.hour ?? 0) * 60 + (c.minute ?? 0)))")
    }

    /// CAN THIS ALARM ACTUALLY FIRE? The alarm is buzzed by the phone over Bluetooth, so a disconnected
    /// strap means silence — and that was invisible here, which is the whole shape of "the vibration
    /// doesn't work at all": nothing on this screen distinguished an armed working alarm from an armed
    /// one that had no way to reach the wrist. Stated as a live condition, not a promise, and never
    /// dressed up: "connected" says the buzz can be delivered now, nothing more.
    ///
    /// THREE states, not two. The boolean this row used to be could not express the case the user was
    /// actually in — connected AND unable to receive anything — so it told them the opposite of the truth in
    /// the most confident form the screen has. Which of the three applies is decided by the pure
    /// `WakeBuzzAlarm.reach`, so the choice is pinned by a test rather than by a ternary here.
    @ViewBuilder
    private var reachRow: some View {
        let reach = WakeBuzzAlarm.reach(strapConnected: strapConnected,
                                        bondRefused: strapWritesRefused,
                                        pairingHint: pairingHint)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: reach == .canBuzz ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(reach == .canBuzz ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                .accessibilityHidden(true)
            // Separate literal Texts rather than one ternary, so each string stays a plain
            // `LocalizedStringKey` the string catalog can pick up.
            switch reach {
            case .canBuzz:
                Text("Strap connected — NOOP can buzz it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .notConnected:
                Text("Strap not connected. Nothing will buzz unless it's connected at your wake time — the backup notification is all you'd get.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .refused(let guidance):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your strap is connected but NOT paired. It is refusing everything NOOP sends, so nothing will buzz until you pair it again.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    // The BLE layer's own guidance, verbatim — it is not a `LocalizedStringKey`, and
                    // deliberately so: re-typing it here as one would make a second copy of the text that
                    // #78 already owns, which is how this repo ends up with two of everything.
                    Text(verbatim: guidance)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A fixed wheel of quarter-hour slots rather than a free `DatePicker` — the alarm only has 96
    /// possible times, so there is no 07:07 to mis-tap onto.
    private var timeWheel: some View {
        Picker("", selection: $minutes) {
            ForEach(WakeBuzzAlarm.options, id: \.self) { slot in
                Text(WakeBuzzAlarm.timeLabel(slot)).tag(slot)
            }
        }
        .labelsHidden()
        #if os(iOS)
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        #else
        .pickerStyle(.menu)
        #endif
        .accessibilityLabel("Wake time")
    }

    // MARK: - Test / Stop

    /// Fires the REAL ring, not a one-off buzz: same cadence, same auto-stop, same stop gestures. A
    /// test that behaved differently from the alarm would prove nothing about the alarm.
    private var testCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    if ringer.isRinging {
                        ringer.stop(reason: "Stop button")
                    } else {
                        // `startTest`, not `start`: with no reachable strap the test must send nothing and
                        // SAY so, rather than flipping to "Stop" for thirty seconds over a silent wrist.
                        ringer.startTest()
                    }
                } label: {
                    // Two literal Texts rather than one ternary, so each string stays a plain
                    // `LocalizedStringKey` the string catalog can pick up.
                    if ringer.isRinging { Text("Stop") } else { Text("Test") }
                }
                .buttonStyle(NoopButtonStyle(ringer.isRinging ? .destructive : .secondary, fullWidth: true))

                deliveryRow
                phoneFallbackRow

                Text("Your strap buzzes every few seconds. Double-tap the strap to stop it, tap Stop here, or leave it — it stops by itself after about half a minute.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the last Test / alarm actually DID. The Test button is the one path the user can trigger while
    /// watching their wrist, so it has to report — pressing it and getting silence used to leave them with
    /// no way to tell a dropped write from a strap that took the command and didn't buzz, which are two
    /// completely different problems. Nothing is claimed beyond what the app can observe: `.sent` means the
    /// bytes left the phone, and says so, because whether the motor turned is a fact only a wrist has.
    @ViewBuilder
    private var deliveryRow: some View {
        switch ringer.lastDelivery {
        case .none:
            EmptyView()   // nothing tried yet — the absence of a claim, not a claim of success
        case .some(.sent):
            deliveryNote("checkmark.circle", StrandPalette.statusPositive,
                         Text("Buzz sent to your strap. If your wrist felt nothing, the strap took the command but didn't vibrate."))
        case .some(.noStrap):
            deliveryNote("exclamationmark.triangle", StrandPalette.statusWarning,
                         Text("Nothing was sent — your strap isn't connected. NOOP buzzes it over Bluetooth, so it has to be connected first."))
        case .some(.strapRefused):
            // A DIFFERENT instruction from `.noStrap`, which is the whole reason it is a separate case:
            // this strap is connected, it will stay connected, and waiting for it achieves nothing.
            deliveryNote("exclamationmark.triangle", StrandPalette.statusWarning,
                         Text("Nothing was sent — your strap is connected but refusing it. The pairing is gone from this phone: close the official WHOOP app, tap the band until the LEDs flash blue, forget the strap under iPhone Settings → Bluetooth if it's listed, then tap Connect in NOOP. Steps and sleep can't sync either until that's done."))
        case .some(.noSink):
            deliveryNote("exclamationmark.triangle", StrandPalette.statusWarning,
                         Text("NOOP couldn't send anything: the buzz isn't wired up in this build. Please report it — this one is our bug, not your strap."))
        }
    }

    /// Whether the last attempt had to buzz the PHONE instead of the wrist. Its own row rather than a
    /// fourth `deliveryRow` case, because it is a different fact: `lastDelivery` is what happened on the
    /// BLE link, this is what happened instead. Worded as the weaker thing it is — a phone haptic needs
    /// NOOP awake, is not a sound, and is not on the wrist.
    @ViewBuilder
    private var phoneFallbackRow: some View {
        if ringer.lastPhoneFallback {
            deliveryNote("iphone.radiowaves.left.and.right", StrandPalette.textSecondary,
                         Text("NOOP buzzed your phone instead. That only works while NOOP is awake, and it's a phone on a table rather than a strap on your wrist — treat it as a fallback, not the alarm."))
        }
    }

    /// CAN ANYTHING FIRE ONCE NOOP IS SUSPENDED? The repeating backup notification is the only part of
    /// this alarm that lives outside our process, so whether it is registered is the difference between
    /// "the alarm degrades" and "there is no alarm" — and until now nothing in the app said which.
    ///
    /// Only rendered once the ringer has an answer: nil is "we have not resolved it", which must not be
    /// drawn as either a tick or a warning. On macOS there is no backstop and no answer, so this is
    /// absent there, which is correct.
    @ViewBuilder
    private var backupRow: some View {
        switch ringer.backupState {
        case .none, .some(.off):
            EmptyView()
        case .some(.scheduled):
            deliveryNote("bell.badge", StrandPalette.textSecondary,
                         Text("A backup notification is set for your wake time. It's the only part that still fires if NOOP is closed — but a sideloaded app can't sound a guaranteed wake, so silent mode or a Sleep Focus that doesn't allow NOOP will mute it. Add NOOP to your Sleep Focus's allowed notifications if you rely on it."))
        case .some(.denied):
            deliveryNote("exclamationmark.triangle", StrandPalette.statusWarning,
                         Text("Notifications are off for NOOP, so there is no backup at all: if NOOP isn't awake at your wake time, nothing will happen. Turn notifications on for NOOP in Settings, and keep your phone's Clock alarm."))
        }
    }

    private func deliveryNote(_ symbol: String, _ tint: Color, _ text: Text) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            text
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - What it can't do

    /// Said up front rather than discovered at 07:00. This buzz is sent by the phone over Bluetooth, so
    /// unlike the strap's own firmware alarm (Settings → Alarms) it cannot fire from a force-quit app.
    private var honestyCard: some View {
        StrandCard(padding: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.slash")
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("NOOP sends this buzz, not the strap")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // THE THREE PATHS, WEAKEST LAST, and what is left when each one is gone. The old copy
                    // named the backup notification without ever saying whether it was actually set, and
                    // said nothing at all about the case the fallback now covers: NOOP awake, strap away.
                    Text("Best case, your strap is connected and NOOP is running, and your wrist buzzes. If the strap is away but NOOP is awake, your phone buzzes instead. If NOOP has been force-quit or suspended, only the backup notification is left — and a sideloaded app can't sound a guaranteed wake, so silent mode or a Sleep Focus that doesn't allow NOOP will mute that too. If notifications are off as well, nothing will wake you. Keep your phone's Clock alarm for anything you truly can't miss.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    backupRow
                    Text("Your strap can also hold an alarm in its own clock (More → Alarms), which buzzes once with NOOP closed. On a WHOOP 5/MG that one is still unconfirmed and needs the Experimental toggle, so it isn't armed for you here.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
