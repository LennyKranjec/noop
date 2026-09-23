import Foundation
import Combine
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Runs the Sleep tab's wake buzz: schedules the next fire, buzzes the strap on a steady cadence once
/// it arrives, and stops on the first of a strap double-tap, the auto-stop window, or an explicit Stop.
///
/// Owned by `AppModel` (`model.wakeBuzz`) and wired there to the BLE buzz + the strap's DOUBLE_TAP
/// event, so this type itself touches no CoreBluetooth — the settings and the timing rules it obeys all
/// live in the pure `WakeBuzzAlarm`, which is where the unit tests are.
///
/// HONEST about what it can and cannot do. NOOP is usually alive in the background because the strap
/// keeps the bluetooth-central session awake, and that is what lets these timers run at all — but iOS
/// can suspend the app, and a force-quit kills it outright. So the buzz is backed by a repeating local
/// notification (with its own Stop action), and `reschedule()` re-runs on foreground and after the day
/// rolls over, ringing an instant that was missed by less than one ring window. An alarm the app was
/// killed for arrives as the notification only, and the UI says so rather than promising a buzz.
@MainActor
final class WakeBuzzRinger: ObservableObject {

    /// True while the strap is being buzzed. Drives the sheet's Test/Stop button.
    @Published private(set) var isRinging = false
    /// The next instant the alarm will ring, or nil when it is off / unresolvable. Display-only.
    @Published private(set) var nextFire: Date?

    /// One buzz volley on the strap. Wired by `AppModel` to `BLEManager.buzzStrapOnce()` — the one
    /// on-device-confirmed "vibrate now" sequence (#921), rather than a second hand-composed write.
    var buzz: (() -> Void)?
    /// Best-effort "cut the motor now" (STOP_HAPTICS). A no-op on a 5/MG, whose send allowlist does not
    /// carry cmd 122 — stopping there simply means we send no further volleys and the last one ends.
    var cancelBuzz: (() -> Void)?
    /// Strap-log sink, so a "it didn't buzz" report can be settled from the shared log like the
    /// firmware alarm's armed / reports / fired lines already can.
    var log: ((String) -> Void)?

    private let defaults: UserDefaults
    /// Fires once at `nextFire`. One-shot: the fire handler re-schedules the following day's instant.
    private var fireTimer: Timer?
    /// The repeating buzz cadence while ringing.
    private var buzzTimer: Timer?
    /// The auto-stop backstop, armed with every ring.
    private var autoStopTimer: Timer?
    private var ringStartedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if os(iOS)
        Self.registerNotificationCategory()
        // Tapping Stop on the backup notification wakes the app in the background and lands here.
        NotificationPresenter.shared.onWakeBuzzStop = { [weak self] in
            Task { @MainActor in self?.stop(reason: "Stop from the notification") }
        }
        #endif
    }

    // MARK: - Scheduling

    /// (Re)compute the schedule from the persisted settings. Idempotent and cheap: safe to call on every
    /// foreground, after every settings edit, and after the day rolls over.
    func reschedule(now: Date = Date()) {
        fireTimer?.invalidate()
        fireTimer = nil

        // A ring that was still "on" when the app was suspended must not come back ringing — the
        // auto-stop timer cannot fire while suspended, so re-check the window every time we are woken.
        if let started = ringStartedAt, WakeBuzzAlarm.shouldAutoStop(startedAt: started, now: now) {
            stop(reason: "auto-stop (caught up)")
        }

        guard WakeBuzzAlarm.isEnabled(defaults) else {
            // Turning the alarm off must also silence a ring already in progress, and drop the backstop.
            stop(reason: "alarm turned off")
            cancelBackupNotification()
            nextFire = nil
            return
        }

        let minutes = WakeBuzzAlarm.minutes(defaults)
        // Resolve from one grace window ago, so an instant that has JUST passed (the app was busy, or
        // iOS only woke us now) is still seen. `nextFireDate` returns the first strictly-future instant
        // after the date it is given, so a result at or before `now` is exactly that missed instant.
        guard var target = WakeBuzzAlarm.nextFireDate(
            minutes: minutes,
            from: now.addingTimeInterval(-WakeBuzzAlarm.missedGraceSeconds)
        ) else {
            nextFire = nil
            return
        }
        if target <= now {
            fireIfNotAlreadyRung(for: target)
            // Whichever way that went, the NEXT instant is the one after the missed one.
            guard let after = WakeBuzzAlarm.nextFireDate(minutes: minutes, from: now) else {
                nextFire = nil
                return
            }
            target = after
        }

        nextFire = target
        let timer = Timer(fire: target, interval: 0, repeats: false) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor for this @MainActor type (the
            // idiom AppModel.scheduleDailySmartAlarmRearm already uses).
            Task { @MainActor in self?.fireScheduled() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fireTimer = timer
        scheduleBackupNotification(minutes: minutes)
    }

    /// The scheduled instant arrived while the app was alive.
    private func fireScheduled() {
        if let target = nextFire { fireIfNotAlreadyRung(for: target) }
        reschedule()   // arm tomorrow's instant (and the `lastFired` stamp keeps this from re-ringing)
    }

    /// Ring for a scheduled instant, at most once. The stamp is what makes the catch-up path safe to
    /// re-run from a foreground, a day rollover and a settings edit that all land in the same minute.
    private func fireIfNotAlreadyRung(for scheduled: Date) {
        let epoch = Int(scheduled.timeIntervalSince1970)
        guard defaults.integer(forKey: WakeBuzzAlarm.Key.lastFired) != epoch else { return }
        defaults.set(epoch, forKey: WakeBuzzAlarm.Key.lastFired)
        start(reason: "wake time")
    }

    // MARK: - Ringing

    /// Start the repeating buzz. `reason` is log-only. Used by both the scheduled fire and the sheet's
    /// Test button, so a test feels exactly like the real thing and stops exactly the same ways.
    func start(reason: String, now: Date = Date()) {
        stopTimers()
        isRinging = true
        ringStartedAt = now
        log?("Wake buzz: ringing (\(reason)) — double-tap the strap, hit Stop, or it stops itself after \(Int(WakeBuzzAlarm.autoStopSeconds))s")
        buzz?()   // first volley immediately, so the wrist feels it at the chosen minute
        let cadence = Timer(timeInterval: WakeBuzzAlarm.buzzIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.buzz?() }
        }
        RunLoop.main.add(cadence, forMode: .common)
        buzzTimer = cadence
        let autoStop = Timer(timeInterval: WakeBuzzAlarm.autoStopSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "auto-stop") }
        }
        RunLoop.main.add(autoStop, forMode: .common)
        autoStopTimer = autoStop
    }

    /// Stop a ring in progress. Returns whether anything was actually ringing, so a caller can tell
    /// whether it CONSUMED the gesture. Idempotent: calling it with nothing ringing is a silent no-op,
    /// which is what lets every failure path call it unconditionally.
    @discardableResult
    func stop(reason: String) -> Bool {
        let wasRinging = isRinging
        stopTimers()
        isRinging = false
        ringStartedAt = nil
        if wasRinging {
            cancelBuzz?()
            log?("Wake buzz: stopped (\(reason))")
        }
        return wasRinging
    }

    /// The strap's own DOUBLE_TAP gesture arrived (`LiveState.onDoubleTap` → `AppModel.handleDoubleTap`).
    /// Returns true when it silenced a ring, in which case the caller must NOT also run the user's
    /// configured double-tap action — the gesture belonged to the alarm.
    func handleDoubleTap(at when: Date = Date()) -> Bool {
        guard isRinging, let started = ringStartedAt,
              WakeBuzzAlarm.tapStopsRing(tapAt: when, ringStartedAt: started) else { return false }
        return stop(reason: "strap double-tap")
    }

    private func stopTimers() {
        buzzTimer?.invalidate()
        buzzTimer = nil
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }

    // MARK: - Backup notification (iOS)

    #if os(iOS)
    /// Register the one category that carries the Stop action. Merged into whatever else is registered
    /// rather than replacing it — `setNotificationCategories` overwrites the whole set.
    private static func registerNotificationCategory() {
        let stop = UNNotificationAction(identifier: WakeBuzzAlarm.stopActionId,
                                        title: String(localized: "Stop"),
                                        options: [])
        let category = UNNotificationCategory(identifier: WakeBuzzAlarm.notificationCategoryId,
                                              actions: [stop],
                                              intentIdentifiers: [],
                                              options: [])
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var merged = existing.filter { $0.identifier != WakeBuzzAlarm.notificationCategoryId }
            merged.insert(category)
            center.setNotificationCategories(merged)
        }
    }

    /// A repeating daily notification at the wake time. It "lives in the notification centre, not our
    /// process" (the WindDownNudge / smart-alarm-backup idiom), so it survives relaunch and still
    /// arrives when the app was killed and no timer could run. NOT a guaranteed wake: a sideloaded
    /// build has no critical-alert entitlement, so Focus / silent mode can still mute it.
    private func scheduleBackupNotification(minutes: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [WakeBuzzAlarm.notificationId])
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wake buzz")
        content.body = String(localized: "Your wake time is here. Double-tap your strap to stop the buzzing.")
        content.sound = .default
        content.categoryIdentifier = WakeBuzzAlarm.notificationCategoryId
        let request = UNNotificationRequest(
            identifier: WakeBuzzAlarm.notificationId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                center.add(request)
            case .notDetermined:
                // The user just turned the alarm on and may never have been asked — ask now, so the
                // FIRST morning is covered rather than some later re-arm.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                break   // Denied: the in-app buzz still works; the UI copy says the backstop needs it.
            }
        }
    }

    private func cancelBackupNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [WakeBuzzAlarm.notificationId])
    }
    #else
    // macOS keeps just the in-app buzz — same shape as the firmware alarm's backup helpers, which are
    // iOS-only for the same reason.
    private func scheduleBackupNotification(minutes: Int) {}
    private func cancelBackupNotification() {}
    #endif
}
