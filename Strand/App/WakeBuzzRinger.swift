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
///
/// `strapReady` ALONE WAS NOT ENOUGH, and #2213 is the field report that proved it. A WHOOP 5/MG on firmware
/// 50.42.1.0, after an iPhone reset, was connected with its command characteristic discovered — so
/// `commandChannelReady` was true and this object reported `.sent` — while the strap rejected every single
/// write with ATT "Authentication is insufficient", because the encrypted pairing was gone from the phone and
/// the strap would not grant a new one. The verdict now depends on the write's RESULT (`bondRefused`, fed from
/// `didWriteValueFor`), and that state has its own `Delivery` case, because telling this user "your strap
/// isn't connected" is worse than saying nothing: their strap is connected, it will stay connected, and the
/// only thing that helps is re-pairing it.
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
    /// Whether the CURRENT (or last) attempt fell back to buzzing the PHONE because nothing could reach
    /// the strap. False before the first ring of the session — false is "we have not needed it", never
    /// "the strap worked".
    ///
    /// It is a separate fact from `lastDelivery` on purpose: the phone buzz is not a substitute for the
    /// strap buzz and must never be reported as one. It is a weaker thing — it needs NOOP awake, it is
    /// on the bedside table rather than the wrist, and it cannot be felt through a pillow — so the sheet
    /// states it as the fallback it is.
    @Published private(set) var lastPhoneFallback = false
    /// Whether the suspension-proof backstop is actually registered with the OS. nil = not resolved yet
    /// (no `reschedule` has run, or the answer has not come back), which is NOT "it is fine".
    ///
    /// This is the only path that can fire while NOOP is suspended or force-quit, so whether it exists
    /// decides what the alarm is worth on a phone whose strap is away — and a denied notification
    /// permission used to leave that with no surface anywhere in the app.
    @Published private(set) var backupState: WakeBuzzAlarm.BackupState?

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
    /// Whether the strap is REFUSING NOOP's writes at the ATT layer — connected, characteristic present, and
    /// every write coming back "Authentication is insufficient" because the encrypted pairing is gone from
    /// this phone. Wired by `AppModel` to `LiveState.strapWritesRefused`, which `BLEManager` sets from the
    /// write COMPLETION.
    ///
    /// `strapReady` alone cannot carry this. It is a single boolean, so the best it could ever say is "no",
    /// and "no" is rendered everywhere as "your strap isn't connected" — the one instruction that is actively
    /// wrong for a strap that is connected and will stay connected. This is the second bit that makes the
    /// difference reportable: `.strapRefused` instead of `.noStrap`, and a fix the user can act on.
    ///
    /// UNWIRED counts as NOT refused, the same direction as `strapReady`: a host that has told us nothing has
    /// not told us there is a problem, and inventing a failure is the mirror image of inventing a success.
    var bondRefused: (() -> Bool)?
    /// Best-effort "cut the motor now" (STOP_HAPTICS). A no-op on a 5/MG, whose send allowlist does not
    /// carry cmd 122 — stopping there simply means we send no further volleys and the last one ends.
    var cancelBuzz: (() -> Void)?
    /// THE PHONE-SIDE FALLBACK, for a wake minute the strap cannot hear.
    ///
    /// `buzz` was the only wake path this object had: a phone whose strap was flat, out of range or
    /// simply off the wrist got NOTHING from the ring, and the repeating backstop notification was the
    /// whole of the alarm. So a ring that cannot reach the strap now also buzzes the PHONE, once, and
    /// says in the sheet that it did.
    ///
    /// nil = use the app's own `summon` haptic (the one reserved for "the system wants attention"),
    /// which is a no-op on macOS and in the Simulator. Injectable so the tests can observe the fallback
    /// without a Taptic Engine.
    ///
    /// HONEST ABOUT ITS CEILING: a haptic needs NOOP awake and running. It cannot fire from a suspended
    /// or force-quit app, it is not a sound, and a phone across the room is not a wrist. It narrows the
    /// silent case; it does not close it, and the sheet says so rather than letting it read as a second
    /// alarm.
    var phoneFallback: (() -> Void)?
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
    /// Whether ANY volley of the current ring was dropped because the strap was refusing writes, so the
    /// tally line at stop can name that cause instead of the "(strap not connected)" it used to assume.
    /// Sticky for the ring on purpose: a ring that was refused and then re-paired mid-window still happened.
    private var ringHitRefusedBond = false
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
            // The arm note distinguishes the refused bond from a strap that is merely away, because the two
            // need opposite action before the wake minute: one is "have the strap on and connected", the
            // other is "re-pair it, waiting will not help".
            let reach: String
            switch WakeBuzzAlarm.reach(strapConnected: strapReady?() ?? true,
                                       bondRefused: bondRefused?() ?? false,
                                       pairingHint: nil) {
            case .canBuzz:      reach = "strap connected"
            case .notConnected: reach = "strap NOT connected — it must be back by then or nothing will buzz"
            case .refused:      reach = "strap connected but REFUSING NOOP's writes — nothing will buzz until it is re-paired"
            }
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
    /// loop spins up again: a 07:00 alarm on a phone first woken at 10:00 buzzed at 10:00.
    ///
    /// THE STAMP IS WRITTEN ONLY ONCE THE GUARD HAS PASSED. It used to be written first, which meant a
    /// skip CONSUMED the instant: a main-thread stall or a late run-loop spin longer than the 30 s grace
    /// burned the morning, and no later `reschedule()` — foreground, day rollover, settings edit — could
    /// retry it. Stamping on the skip path bought nothing, because `shouldRing` is MONOTONE in `now`: an
    /// instant already past the grace window stays past it, so an unstamped skip cannot ring later either.
    /// What it can do is stay available to a pass whose `now` is still inside the window, which is exactly
    /// the case the grace window exists for.
    ///
    /// Internal rather than private only so the tests can drive one delivery without a run loop — the same
    /// reason `deliverVolley` is. Nothing in the app calls it outside `reschedule` and `fireScheduled`.
    func fireIfNotAlreadyRung(for scheduled: Date, now: Date = Date()) {
        let epoch = Int(scheduled.timeIntervalSince1970)
        guard defaults.integer(forKey: WakeBuzzAlarm.Key.lastFired) != epoch else { return }
        guard WakeBuzzAlarm.shouldRing(scheduled: scheduled, now: now) else {
            log?("Wake buzz: skipped — the wake time passed \(Int(now.timeIntervalSince(scheduled)))s ago while NOOP was suspended, too late to buzz")
            return
        }
        defaults.set(epoch, forKey: WakeBuzzAlarm.Key.lastFired)
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
        ringHitRefusedBond = false
        // A fresh attempt reports itself from scratch. Carrying the previous ring's outcome over would both
        // show a stale verdict in the sheet and suppress this ring's first log line (the per-transition
        // guards below compare against it), so the second failed morning would leave no trace at all.
        lastDelivery = nil
        lastPhoneFallback = false
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

    /// The sheet's TEST, which is a different question from the alarm's.
    ///
    /// `start` deliberately RUNS a ring whose first volley could not be delivered, because the real 07:00
    /// window is worth retrying into — a link that comes up two seconds later still buzzes the wrist. A
    /// test is not that. It is a user standing there watching their wrist, and answering it with thirty
    /// seconds of "Stop" over a strap that cannot hear a thing is precisely the false success this whole
    /// type exists to stop: the button changed, the ring "ran", and nothing happened.
    ///
    /// So the test REFUSES to pretend. With no reachable strap it sends nothing, reports what is wrong,
    /// buzzes the phone so the fallback is something the user has actually felt, and leaves the button
    /// saying "Test" — because there is no ring to stop.
    @discardableResult
    func startTest() -> WakeBuzzAlarm.Delivery {
        lastPhoneFallback = false
        guard buzz != nil else {
            lastDelivery = .noSink
            log?("Wake buzz: test sent NOTHING — no buzz sink is wired in this build (app bug, not your strap)")
            firePhoneFallback(reason: .noSink)
            return .noSink
        }
        // The refused bond is its own refusal to pretend, and a louder one: the user is looking at a screen
        // that says their strap is connected, so "it isn't connected" would read as the app contradicting
        // itself and they would keep pressing Test.
        if bondRefused?() ?? false {
            lastDelivery = .strapRefused
            log?("Wake buzz: test sent NOTHING — the strap is connected but refusing everything NOOP writes (the encrypted pairing is gone from this phone). Re-pair it and the wrist buzz comes back")
            firePhoneFallback(reason: .strapRefused)
            return .strapRefused
        }
        guard strapReady?() ?? true else {
            lastDelivery = .noStrap
            log?("Wake buzz: test sent NOTHING — the strap isn't connected, so the write would be dropped")
            firePhoneFallback(reason: .noStrap)
            return .noStrap
        }
        return start(reason: "test")
    }

    /// Buzz the phone, at most once per attempt, and record that we had to.
    ///
    /// Logged as the fallback it is. `reason` is the volley outcome that forced it, so the strap log
    /// distinguishes "your strap was away" from "this build cannot buzz at all".
    ///
    /// NOTHING IS RECORDED WHEN NOTHING CAN FIRE. `lastPhoneFallback` drives a line in the sheet saying
    /// the phone buzzed, so it may be set only where a buzz was actually asked for. Two cases where it
    /// cannot be: macOS, where `SystemHaptics` is an unconditional no-op (there is no haptic engine), and
    /// a wearer who has turned the app-wide haptics off — that is their explicit choice, and it costs them
    /// this fallback, which is better than a sheet telling them their phone buzzed when it did not.
    ///
    /// What it DOES claim, like `.sent` on the strap side, is that the cue was fired — not that the
    /// hardware rendered it. Whether a Taptic Engine actually moved is a fact only a hand has.
    private func firePhoneFallback(reason: WakeBuzzAlarm.Delivery) {
        guard !lastPhoneFallback else { return }
        if let phoneFallback {
            phoneFallback()
        } else {
            #if os(iOS)
            // The one cue reserved for "the system wants attention".
            guard SystemHaptics.enabled else { return }
            SystemHaptics.play(.summon)
            #else
            return
            #endif
        }
        lastPhoneFallback = true
        log?(WakeBuzzAlarm.phoneFallbackLogLine(reason: reason))
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
        // ONE decision, made by the pure `verdict` rather than by a chain of guards here, so the precedence
        // between "refusing writes" and "not reachable" is pinned by a test instead of by statement order in
        // a @MainActor class no test can reach without a run loop.
        let outcome = WakeBuzzAlarm.verdict(hasSink: buzz != nil,
                                            strapReachable: strapReady?() ?? true,
                                            bondRefused: bondRefused?() ?? false)
        switch outcome {
        case .noSink:
            // A wiring bug, not a strap condition. Loud once per ring rather than silent.
            if lastDelivery != .some(.noSink) {
                log?("Wake buzz: no buzz sink is wired — NOOP cannot buzz the strap at all (app bug, not your strap)")
            }
            volleysDropped += 1
        case .strapRefused:
            volleysDropped += 1
            ringHitRefusedBond = true
            // First refusal only, same reason as the drop line below.
            if lastDelivery != .some(.strapRefused) {
                log?("Wake buzz: volley NOT sent — the strap is connected but refusing everything NOOP writes (the encrypted pairing is gone from this phone). Re-pair the strap: close the WHOOP app, put the band in pairing mode, forget it in iPhone Settings → Bluetooth, then Connect in NOOP")
            }
        case .noStrap:
            volleysDropped += 1
            // First drop only: a 30 s ring is ~10 volleys and ten identical lines bury the useful ones.
            if lastDelivery != .some(.noStrap) {
                log?("Wake buzz: volley NOT sent — the strap isn't connected, so the write would be dropped; still trying for the rest of the window")
            }
        case .sent:
            buzz?()
            volleysSent += 1
            if lastDelivery != .some(.sent) { log?("Wake buzz: volley sent to the strap") }
        }
        lastDelivery = outcome
        // Nothing could reach the wrist — buzz the phone instead, once for this ring.
        if outcome != .sent { firePhoneFallback(reason: outcome) }
        return outcome
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
            log?(WakeBuzzAlarm.deliveryLogLine(sent: volleysSent, dropped: volleysDropped,
                                               reason: reason, refusedBond: ringHitRefusedBond))
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
    /// arrives when the app was killed and no timer could run.
    ///
    /// NOTHING IS REMOVED FIRST. It used to `removePendingNotificationRequests` synchronously at the top
    /// while the matching `add` happened inside the ASYNC `getNotificationSettings` callback — so every
    /// foreground deleted the only suspension-proof path this alarm has and re-added it a moment later,
    /// and a suspend inside that window left the alarm deleted until the next foreground. The pre-emptive
    /// remove bought nothing either way: the identifier is constant and `add` REPLACES a pending request
    /// with the same identifier in place. The only remove left is `cancelBackupNotification`, on the path
    /// where the alarm is actually switched off.
    ///
    /// `.timeSensitive`, NOT `.active`. A wake alarm fires exactly while Sleep Focus is on, and `.active`
    /// — the default, which this had — is the one level Focus suppresses. See `WakeBuzzAlarm.BackupState`
    /// for what this does and does not buy on a sideloaded build.
    ///
    /// NOT a guaranteed wake, at any interruption level: a sideloaded build has no critical-alert
    /// entitlement, so silent mode and a Focus that does not allow NOOP through can still mute it. The
    /// sheet says so; `backupState` says whether it is even registered.
    private func scheduleBackupNotification(minutes: Int) {
        let center = UNUserNotificationCenter.current()
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Wake buzz")
        content.body = String(localized: "Your wake time is here. Double-tap your strap to stop the buzzing.")
        content.sound = .default
        content.categoryIdentifier = WakeBuzzAlarm.notificationCategoryId
        // Time Sensitive is the one level Sleep Focus lets through without the user allow-listing the app
        // by hand. It needs the `com.apple.developer.usernotifications.time-sensitive` capability in the
        // signed entitlements; WITHOUT it iOS silently downgrades this back to `.active` — it does not
        // fail, and nothing in the app can observe the downgrade. So this is set because it is correct
        // and free, and the UI copy does NOT promise it works: it tells the user the one thing that does
        // work on any build, which is allowing NOOP through their Sleep Focus.
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: WakeBuzzAlarm.notificationId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        )
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
                Task { @MainActor [weak self] in self?.backupState = .scheduled }
            case .notDetermined:
                // The user just turned the alarm on and may never have been asked — ask now, so the
                // FIRST morning is covered rather than some later re-arm. This is an explicit user
                // action (they flipped the alarm on), which is the only thing that may cold-prompt.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                    Task { @MainActor [weak self] in
                        self?.backupState = granted ? .scheduled : .denied
                        if !granted {
                            self?.log?("Wake buzz: backup notification NOT scheduled — notification permission was declined")
                        }
                    }
                }
            default:
                // Denied: the in-app buzz still works while NOOP is awake, and NOTHING works once it is
                // suspended. That is a material fact about the alarm, so it is published and logged
                // rather than swallowed.
                Task { @MainActor [weak self] in
                    guard let self, self.backupState != .denied else { return }
                    self.backupState = .denied
                    self.log?("Wake buzz: backup notification NOT scheduled — notifications are off for NOOP, so nothing can wake you while NOOP is suspended")
                }
            }
        }
    }

    private func cancelBackupNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [WakeBuzzAlarm.notificationId])
        backupState = .off
    }
    #else
    // macOS keeps just the in-app buzz — same shape as the firmware alarm's backup helpers, which are
    // iOS-only for the same reason.
    private func scheduleBackupNotification(minutes: Int) {}
    private func cancelBackupNotification() {}
    #endif
}
