import SwiftUI
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
        SleepAlarmSheetContent(ringer: requireAppModel(modelRef).wakeBuzz)
    }
}

private struct SleepAlarmSheetContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var ringer: WakeBuzzRinger

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
        }
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
    /// the two ever disagree, the one that will actually buzz is the one worth showing. "—" when the
    /// alarm is off or nothing resolved; never an invented time.
    private var nextFireCaption: String {
        guard alarmOn, let next = ringer.nextFire else { return String(localized: "Off") }
        let c = Calendar.current.dateComponents([.hour, .minute], from: next)
        return String(localized: "Next buzz \(WakeBuzzAlarm.timeLabel((c.hour ?? 0) * 60 + (c.minute ?? 0)))")
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

                Text("Your strap buzzes every few seconds. Double-tap the strap to stop it, tap Stop here, or leave it — it stops by itself after about half a minute.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                }
            }
        }
    }
}
