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
    @ViewBuilder
    private var reachRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: strapConnected ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(strapConnected ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                .accessibilityHidden(true)
            // Two literal Texts rather than one ternary, so each string stays a plain
            // `LocalizedStringKey` the string catalog can pick up.
            if strapConnected {
                Text("Strap connected — NOOP can buzz it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Strap not connected. Nothing will buzz unless it's connected at your wake time — the backup notification is all you'd get.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        ringer.start(reason: "test")
                    }
                } label: {
                    // Two literal Texts rather than one ternary, so each string stays a plain
                    // `LocalizedStringKey` the string catalog can pick up.
                    if ringer.isRinging { Text("Stop") } else { Text("Test") }
                }
                .buttonStyle(NoopButtonStyle(ringer.isRinging ? .destructive : .secondary, fullWidth: true))

                deliveryRow

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
        case .some(.noSink):
            deliveryNote("exclamationmark.triangle", StrandPalette.statusWarning,
                         Text("NOOP couldn't send anything: the buzz isn't wired up in this build. Please report it — this one is our bug, not your strap."))
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
                    Text("Your strap has to be connected and NOOP still running — it usually is, because the strap keeps it awake in the background. If you force-quit NOOP you only get the backup notification, and a sideloaded app can't sound a guaranteed wake, so Focus or silent mode can mute that too. Keep your phone's Clock alarm for anything you truly can't miss.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Your strap can also hold an alarm in its own clock (More → Alarms), which buzzes once with NOOP closed. On a WHOOP 5/MG that one is still unconfirmed and needs the Experimental toggle, so it isn't armed for you here.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
