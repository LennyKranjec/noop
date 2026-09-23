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
