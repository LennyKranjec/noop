import Foundation

/// The Sleep tab's WAKE BUZZ — the persisted settings plus the pure timing rules behind the repeating
/// strap buzz that the alarm button in the Sleep header arms.
///
/// This is deliberately NOT the strap's firmware alarm (`BehaviorStore.smartAlarm*`, armed from
/// `SmartAlarmView`). That one is a single silent buzz the strap fires from its own RTC, and it keeps
/// working with NOOP closed. This one is APP-DRIVEN: NOOP buzzes the strap over BLE on a steady cadence
/// until the wearer double-taps the band, until the auto-stop window runs out, or until they hit Stop.
/// The two are separate settings on purpose — arming one must never silently re-time the other.
///
/// Everything here is side-effect-free apart from the `UserDefaults` accessors, so the quarter-hour
/// grid, the ring policy and the next-fire math are unit-testable with no strap, no clock and no view.
enum WakeBuzzAlarm {

    // MARK: - Persisted settings (UserDefaults, single-user, on-device — the BehaviorStore idiom)

    enum Key {
        static let enabled = "wakeBuzz.enabled"
        static let minutes = "wakeBuzz.minutes"
        /// Epoch seconds of the scheduled instant we last rang for. The catch-up path in
        /// `WakeBuzzRinger.reschedule` reads it so a missed instant can ring at most ONCE, however many
        /// times a foreground / day-rollover / settings edit re-runs the scheduler.
        static let lastFired = "wakeBuzz.lastFiredFireEpoch"
    }

    /// 07:00, matching the firmware alarm's default so the two don't look arbitrarily different.
    static let defaultMinutes = 7 * 60

    /// Default OFF: nothing may buzz a wrist at 07:00 because the app was installed.
    static func isEnabled(_ d: UserDefaults = .standard) -> Bool { d.bool(forKey: Key.enabled) }
    static func setEnabled(_ on: Bool, _ d: UserDefaults = .standard) { d.set(on, forKey: Key.enabled) }

    /// Target wake time, minutes since LOCAL midnight, always snapped onto the quarter-hour grid — a
    /// value written by an older build (or a corrupted defaults entry) can never put the picker on a
    /// slot it cannot show.
    static func minutes(_ d: UserDefaults = .standard) -> Int {
        snapped(d.object(forKey: Key.minutes) as? Int ?? defaultMinutes)
    }

    static func setMinutes(_ m: Int, _ d: UserDefaults = .standard) { d.set(snapped(m), forKey: Key.minutes) }

    // MARK: - The quarter-hour grid

    /// The user picks a time in 15-minute steps, so the picker is a fixed list of slots rather than a
    /// free `DatePicker` — there is no 07:07 to mis-tap onto.
    static let stepMinutes = 15

    /// Every selectable slot, 00:00 … 23:45 (96 of them), in order.
    static var options: [Int] { stride(from: 0, to: 24 * 60, by: stepMinutes).map { $0 } }

    /// Snap an arbitrary minute-of-day onto the grid: clamped into the day, then rounded to the NEAREST
    /// slot. A value that rounds up past the last slot stays on 23:45 rather than wrapping to 00:00 —
    /// wrapping would move an alarm by nearly a full day, which is the opposite of what a round means.
    static func snapped(_ minuteOfDay: Int) -> Int {
        let clamped = min(max(minuteOfDay, 0), 24 * 60 - 1)
        let rounded = ((clamped + stepMinutes / 2) / stepMinutes) * stepMinutes
        return min(rounded, 24 * 60 - stepMinutes)
    }

    /// "HH:mm" for a minute-of-day. Fixed 24-hour form, matching `SmartAlarmView.timeLabel` so the two
    /// alarm surfaces read the same.
    static func timeLabel(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    // MARK: - Ring policy

    /// How long the buzz keeps going on its own before it gives up. The wearer asked for "about half a
    /// minute"; the strap's own wake pattern (`AlarmPayload.setAlarmRev4`) uses the same 30 s duration.
    static let autoStopSeconds: TimeInterval = 30

    /// Start-to-start spacing between buzz volleys. Each volley is one fixed-length motor pattern
    /// (`BLEManager.buzzStrapOnce`, patternId 2 × 3 loops ≈ 2 s of motor), so this leaves a short gap
    /// and gives ~10 volleys inside the auto-stop window.
    static let buzzIntervalSeconds: TimeInterval = 3

    /// How far into the past a scheduled instant may be and still ring when the scheduler next runs.
    /// iOS suspends this app between BLE wakes, so the fire timer can land late; a foreground or a
    /// strap wake that arrives within one ring window still delivers the alarm instead of dropping it
    /// silently. Anything older is NOT resurrected — a buzz twenty minutes after the wake time is worse
    /// than none.
    static let missedGraceSeconds: TimeInterval = autoStopSeconds

    /// Whether a scheduled instant is still worth ringing at `now` — the single gate BOTH delivery paths
    /// go through, so the grace window above is one rule rather than one rule and one omission.
    ///
    /// It has to be applied where the FIRE TIMER lands as well as where the catch-up scan runs. The timer
    /// is armed for an absolute instant on the main run loop, and that run loop does not turn while iOS
    /// has the app suspended: a 07:00 timer on a phone that is not woken until 10:00 fires the moment the
    /// loop spins up, three hours late. Without this gate that fired the alarm at 10:00 — which is the
    /// case the comment on `missedGraceSeconds` says must be dropped, not resurrected.
    ///
    /// A `now` BEFORE the instant is early (a run loop firing a hair ahead of the fire date, or a clock
    /// that moved backwards) and still rings: the instant has arrived as far as anyone can tell, and
    /// refusing it would drop the alarm entirely.
    static func shouldRing(scheduled: Date, now: Date) -> Bool {
        now.timeIntervalSince(scheduled) <= missedGraceSeconds
    }

    /// Whether a ring that started at `startedAt` has outlived the auto-stop window. The ringer arms a
    /// timer for this, but also re-checks it whenever it is woken, so a ring that was still "on" while
    /// the app was suspended can never come back ringing.
    static func shouldAutoStop(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= autoStopSeconds
    }

    /// Whether a strap double-tap at `tapAt` belongs to the ring that started at `ringStartedAt`.
    /// A tap BEFORE the ring started is somebody else's gesture (it must still run whatever the user
    /// mapped double-tap to), and a tap after the window has elapsed arrives when nothing is ringing.
    static func tapStopsRing(tapAt: Date, ringStartedAt: Date) -> Bool {
        tapAt >= ringStartedAt && !shouldAutoStop(startedAt: ringStartedAt, now: tapAt)
    }

    // MARK: - What a volley actually did

    /// The OUTCOME of one buzz volley — what reached the strap, not what we asked for.
    ///
    /// This exists because the ring used to be unfalsifiable. `WakeBuzzRinger.start` set `isRinging`,
    /// logged "ringing", called its buzz closure and returned; the closure runs
    /// `BLEManager.buzzStrapOnce` → `send`, and `send` DROPS the write and returns when the link is not
    /// up (`state.connected` false, the peripheral not `.connected`, or no command characteristic). So a
    /// wake buzz with the strap out of range produced a sheet showing "Stop" for thirty seconds, a
    /// "ringing" log line, and zero bytes on the wire — a confident success for something that did not
    /// happen. The ringer now carries the outcome back, the sheet states it, and the strap log records it.
    enum Delivery: Equatable {
        /// A volley was written to a connected strap. NOT a promise the motor turned — the write is
        /// acknowledged by the link, and whether the firmware honours the pattern is a hardware fact
        /// only a wrist can confirm. It IS a promise that the bytes left the phone.
        case sent
        /// Nothing was written: no strap link, so `send` would have dropped it. The one the user needs.
        case noStrap
        /// No buzz sink is wired at all (`WakeBuzzRinger.buzz` nil). An app-wiring bug rather than a
        /// strap condition — it must be visible instead of looking like a quiet strap.
        case noSink
    }

    /// Whether the BACKSTOP — the repeating local notification at the wake time — is registered with the
    /// OS. It is the only part of this alarm that can fire while NOOP is suspended or force-quit, so
    /// whether it exists is the difference between "the alarm degrades" and "there is no alarm".
    ///
    /// Note what even `.scheduled` does NOT promise. A sideloaded build has no critical-alert
    /// entitlement, and the Time Sensitive interruption level the content asks for needs the
    /// `com.apple.developer.usernotifications.time-sensitive` capability in the signed entitlements —
    /// which this project does not carry, so iOS downgrades it back to `.active` and a Sleep Focus that
    /// has not been told to allow NOOP will suppress it. `.scheduled` means REGISTERED, not GUARANTEED,
    /// and the copy that shows it says which of the two it is.
    enum BackupState: Equatable {
        /// Registered with the notification centre. Survives relaunch and a force-quit.
        case scheduled
        /// Notifications are off for NOOP, so the backstop cannot be registered at all.
        case denied
        /// The alarm is switched off, so there is nothing to back up.
        case off
    }

    /// The strap-log line for a ring that had to buzz the PHONE because the strap could not be reached.
    /// Pure, so what the log claims is pinned by a test rather than assembled at the call site.
    static func phoneFallbackLogLine(reason: Delivery) -> String {
        switch reason {
        case .sent:
            // Not reachable from the ringer (the fallback only fires on a failed volley); stated rather
            // than defaulted to something that would read as a failure.
            return "Wake buzz: phone buzzed alongside the strap"
        case .noStrap:
            return "Wake buzz: buzzed the PHONE instead — the strap isn't connected. A phone haptic needs NOOP awake and isn't a wrist, so it is a fallback, not the alarm"
        case .noSink:
            return "Wake buzz: buzzed the PHONE instead — NOOP has no strap buzz wired in this build (app bug, not your strap)"
        }
    }

    /// The strap-log line for one ring's delivery tally. Kept here, pure, so what the log claims is
    /// pinned by a test rather than assembled inline at a call site.
    ///
    /// `sent` / `dropped` count VOLLEYS, not bytes: a 30 s ring at a 3 s cadence is ~10 of them, and a
    /// ring that started with the strap away and finished with it back reports both halves instead of
    /// collapsing to whichever end we happened to sample.
    static func deliveryLogLine(sent: Int, dropped: Int, reason: String) -> String {
        if sent == 0 && dropped == 0 {
            return "Wake buzz: stopped (\(reason)) — no volleys were attempted"
        }
        if sent == 0 {
            return "Wake buzz: stopped (\(reason)) — NOTHING reached the strap, all \(dropped) volleys dropped (strap not connected)"
        }
        if dropped == 0 {
            return "Wake buzz: stopped (\(reason)) — \(sent) volleys sent to the strap"
        }
        return "Wake buzz: stopped (\(reason)) — \(sent) volleys sent, \(dropped) dropped (strap not connected)"
    }

    // MARK: - Backup notification identifiers

    /// Stable id + category for the backstop notification `WakeBuzzRinger` schedules. Kept distinct
    /// from the firmware alarm's "smart-alarm-wake-backup" so the two alarms can never cancel or
    /// replace one another. They live here, on a plain nonisolated enum, so the notification delegate
    /// can match on them without reaching into a `@MainActor` type.
    static let notificationId = "sleep-wake-buzz"
    static let notificationCategoryId = "sleep-wake-buzz"
    static let stopActionId = "sleep-wake-buzz.stop"

    // MARK: - Scheduling

    /// The next instant this alarm should ring, or nil if none resolves.
    ///
    /// Deliberately a thin wrapper over `AppModel.nextSmartAlarmDate` rather than a second copy of the
    /// same calendar walk: that function is the app's ONE next-wake resolver, it is already pinned by
    /// tests, and it is already correct about the two things that break hand-rolled versions — a time
    /// that has passed today rolls to tomorrow, and the roll is a CALENDAR day, not `+86400`, so it
    /// still lands on the chosen wall-clock time across a DST change. An empty weekday set means
    /// "every day", which is this alarm's only mode.
    static func nextFireDate(minutes: Int,
                             from now: Date = Date(),
                             calendar cal: Calendar = .current) -> Date? {
        AppModel.nextSmartAlarmDate(minutes: snapped(minutes), weekdays: [], from: now, calendar: cal)
    }
}
