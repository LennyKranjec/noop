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
///
/// It also needs a LIVE BLE LINK at the wake minute, and that was the honesty hole this type shipped
/// with. `buzz` ends in `BLEManager.send`, which drops the write and returns when the link is down; this
/// object could not tell that from a delivered write, so it set `isRinging`, logged "ringing", and the
/// sheet showed "Stop" for thirty seconds while nothing left the phone. `strapReady` is now asked before
/// every volley, `lastDelivery` carries the answer to the UI, and the strap log records the arm, each
/// delivery transition and the per-ring tally — so a "it didn't buzz" report is decidable from the log
/// instead of a guess.
@MainActor
final class WakeBuzzRinger: ObservableObject {

    /// True while the strap is being buzzed. Drives the sheet's Test/Stop button.
    ///
    /// "Ringing" means this object is RUNNING A RING — it is writing volleys on the cadence. It does NOT
    /// mean anything reached the strap; that is `lastDelivery`, and the two must be read together. They
    /// were conflated before, which is how a sheet showed "Stop" for thirty seconds over an unreachable
    /// strap with no other signal anywhere in the UI.
    @Published private(set) var isRinging = false
    /// The next instant the alarm will ring, or nil when it is off / unresolvable. Display-only.
    @Published private(set) var nextFire: Date?
    /// What the most recent volley of the CURRENT (or last) ring actually did. nil before the first ring
    /// of the session — nil is "nothing has been tried yet", never "it worked".
    ///
    /// It is the newest fact, not a summary: a ring that begins with the strap away and ends with it back
    /// reports `.noStrap` and then `.sent`, so the UI can stop claiming failure the moment a volley lands.
    /// The whole-ring tally goes to the strap log at stop (`WakeBuzzAlarm.deliveryLogLine`).
    @Published private(set) var lastDelivery: WakeBuzzAlarm.Delivery?

    /// One buzz volley on the strap. Wired by `AppModel` to `BLEManager.buzzStrapOnce()` — the one
    /// on-device-confirmed "vibrate now" sequence (#921), rather than a second hand-composed write.
    var buzz: (() -> Void)?
    /// Whether a buzz written RIGHT NOW could reach the strap. Wired by `AppModel` to the live link
    /// state, because `buzz` cannot report back: `BLEManager.send` returns silently when the link is
    /// down, so the only way this type can tell a delivered volley from a dropped one is to ask first.
    ///
    /// UNWIRED (a unit test, a host that never set it) counts as REACHABLE. That direction is deliberate:
    /// this type must not invent a failure it cannot observe any more than it may invent a success. In
    /// the app it is always wired, so the honest answer is the one the user sees.
    var strapReady: (() -> Bool)?
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
    /// Volleys of the current ring that went out / were dropped, for the tally logged at stop.
    private var volleysSent = 0
    private var volleysDropped = 0
    /// The instant the last "armed" line was logged for, so `reschedule` — which runs on every foreground,
    /// every settings edit and every day rollover — logs an ARM only when the armed instant actually
    /// changes. Without this the strap log would carry one identical line per app resume.
    private var loggedArmFor: Date?

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
            if loggedArmFor != nil {
                log?("Wake buzz: disarmed — the alarm is switched off")
                loggedArmFor = nil
            }
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
            fireIfNotAlreadyRung(for: target, now: now)
            // Whichever way that went, the NEXT instant is the one after the missed one.
            guard let after = WakeBuzzAlarm.nextFireDate(minutes: minutes, from: now) else {
                nextFire = nil
                return
            }
            target = after
        }

        nextFire = target
        // ARM, logged once per changed instant (#alarm forensics): the firmware alarm's log already carries
        // armed / strap-reports / fired as one decidable sequence, and a "my alarm didn't buzz" report about
        // THIS alarm could not be settled at all — there was no armed line, so nothing distinguished "never
        // armed" from "armed and dropped on the wire". The strap-reachability note is the second half of
        // that: an alarm armed while the strap is away is the single most likely way this ends in silence.
        if loggedArmFor != target {
            loggedArmFor = target
            let reach = (strapReady?() ?? true)
                ? "strap connected"
                : "strap NOT connected — it must be back by then or nothing will buzz"
            log?("Wake buzz: armed for \(Self.logTime(target)) (\(reach))")
        }
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
    ///
    /// The grace check lives HERE rather than at each caller, because there are two delivery paths — the
    /// fire timer and `reschedule`'s catch-up scan — and only the scan used to apply it. A `Timer` armed
    /// for an absolute instant cannot fire while iOS has the app suspended, so it fires the moment the run
    /// loop spins up again: a 07:00 alarm on a phone first woken at 10:00 buzzed at 10:00. The stamp is
    /// written either way, so a dropped instant is CONSUMED and cannot be retried by a later pass.
    private func fireIfNotAlreadyRung(for scheduled: Date, now: Date = Date()) {
        let epoch = Int(scheduled.timeIntervalSince1970)
        guard defaults.integer(forKey: WakeBuzzAlarm.Key.lastFired) != epoch else { return }
        defaults.set(epoch, forKey: WakeBuzzAlarm.Key.lastFired)
        guard WakeBuzzAlarm.shouldRing(scheduled: scheduled, now: now) else {
            log?("Wake buzz: skipped — the wake time passed \(Int(now.timeIntervalSince(scheduled)))s ago while NOOP was suspended, too late to buzz")
            return
        }
        start(reason: "wake time", now: now)
    }

    // MARK: - Ringing

    /// Start the repeating buzz. `reason` is log-only. Used by both the scheduled fire and the sheet's
    /// Test button, so a test feels exactly like the real thing and stops exactly the same ways.
    ///
    /// Returns what the FIRST volley did, which is the whole point of the Test button: it is the one path
    /// the user can trigger while watching their wrist, so it has to come back with "sent" / "no strap" /
    /// "nothing wired" instead of leaving them to infer it from silence.
    ///
    /// A ring whose first volley could not be delivered still RUNS. The cadence re-asks on every volley, so
    /// a link that comes up two seconds into the window does buzz the wrist — dropping the whole ring
    /// because of the first sample would throw that away. What must not happen is claiming it worked, and
    /// `lastDelivery` is what stops that.
    @discardableResult
    func start(reason: String, now: Date = Date()) -> WakeBuzzAlarm.Delivery {
        stopTimers()
        isRinging = true
        ringStartedAt = now
        volleysSent = 0
        volleysDropped = 0
        // A fresh attempt reports itself from scratch. Carrying the previous ring's outcome over would both
        // show a stale verdict in the sheet and suppress this ring's first log line (the per-transition
        // guards below compare against it), so the second failed morning would leave no trace at all.
        lastDelivery = nil
        log?("Wake buzz: ringing (\(reason)) — double-tap the strap, hit Stop, or it stops itself after \(Int(WakeBuzzAlarm.autoStopSeconds))s")
        let first = deliverVolley()   // first volley immediately, so the wrist feels it at the chosen minute
        let cadence = Timer(timeInterval: WakeBuzzAlarm.buzzIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.deliverVolley() }
        }
        RunLoop.main.add(cadence, forMode: .common)
        buzzTimer = cadence
        let autoStop = Timer(timeInterval: WakeBuzzAlarm.autoStopSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stop(reason: "auto-stop") }
        }
        RunLoop.main.add(autoStop, forMode: .common)
        autoStopTimer = autoStop
        return first
    }

    /// Write ONE buzz volley, and report what it did.
    ///
    /// The readiness question has to be asked here rather than trusted to the buzz closure, because the
    /// closure cannot answer: it runs `BLEManager.buzzStrapOnce` → `send`, and `send` logs one line and
    /// RETURNS when the link is down. From this side a dropped write and a delivered one are identical —
    /// which is exactly why a wake buzz over an unreachable strap looked, in the UI, like a working alarm.
    ///
    /// Internal rather than private only so the delivery tests can drive one volley without spinning a run
    /// loop for the 3 s cadence. Nothing in the app calls it outside `start` and the cadence timer.
    @discardableResult
    func deliverVolley() -> WakeBuzzAlarm.Delivery {
        guard let buzz else {
            // A wiring bug, not a strap condition. Loud once per ring rather than silent.
            if lastDelivery != .some(.noSink) {
                log?("Wake buzz: no buzz sink is wired — NOOP cannot buzz the strap at all (app bug, not your strap)")
            }
            lastDelivery = .noSink
            volleysDropped += 1
            return .noSink
        }
        guard strapReady?() ?? true else {
            volleysDropped += 1
            // First drop only: a 30 s ring is ~10 volleys and ten identical lines bury the useful ones.
            if lastDelivery != .some(.noStrap) {
                log?("Wake buzz: volley NOT sent — the strap isn't connected, so the write would be dropped; still trying for the rest of the window")
            }
            lastDelivery = .noStrap
            return .noStrap
        }
        buzz()
        volleysSent += 1
        if lastDelivery != .some(.sent) { log?("Wake buzz: volley sent to the strap") }
        lastDelivery = .sent
        return .sent
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
            log?(WakeBuzzAlarm.deliveryLogLine(sent: volleysSent, dropped: volleysDropped, reason: reason))
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

    /// Local wall-clock "EEE HH:mm zzz" for a log line. `Date` prints in UTC by default, so a 07:00 alarm
    /// logged bare reads like a timezone bug — the same reason `BLEManager.armStrapAlarm` formats its own.
    private static func logTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm zzz"
        return fmt.string(from: date)
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
