import XCTest
import UserNotifications
@testable import Strand

/// Pins the three wake-alarm failures a robustness audit found, all of which are about the alarm being
/// LESS than the UI claimed:
///
///  1. A scheduled instant was CONSUMED even when the ring was skipped, so one main-thread stall longer
///     than the 30 s grace window burned the morning and no later pass could retry it.
///  2. The sheet's Test flipped to "Stop" over a strap that could not hear a thing.
///  3. There was no phone-side path at all: strap away ⇒ nothing happened, and nothing said so.
///
/// Everything here is driven directly — no run loop turn, no strap, no view, no notification centre.
/// The ringer's timers are invalidated by the `stop` each ringing test ends with.
final class WakeBuzzSuspensionTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WakeBuzzSuspensionTests.\(UUID().uuidString)")!
    }

    /// A whole-second instant, so the epoch stamp the ringer writes is exactly this date's and the test
    /// is not reasoning about truncated fractions.
    private let scheduled = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - (1) A skipped instant must stay available

    /// THE BUG: `lastFired` was stamped BEFORE the `shouldRing` grace check, so an instant that arrived
    /// too late to ring was still marked as rung. `reschedule()` runs on every foreground, every settings
    /// edit and every day rollover, and every one of those passes then found the instant already
    /// consumed — the alarm was gone for that morning because the app had been busy for 31 seconds.
    ///
    /// Stamping on the skip path bought nothing, because `shouldRing` is monotone in `now`: an instant
    /// past the window stays past it, so an UNSTAMPED skip cannot ring late either. What it can do is
    /// still be there for a pass whose `now` is inside the window — which is this test.
    @MainActor
    func testSkippedInstant_isNotConsumedAndCanStillRing() {
        let defaults = freshDefaults()
        let ringer = WakeBuzzRinger(defaults: defaults)
        var log: [String] = []
        ringer.buzz = {}
        ringer.strapReady = { true }
        ringer.phoneFallback = {}
        ringer.log = { log.append($0) }

        // A stall well past the grace window: too late to buzz, so it is skipped.
        ringer.fireIfNotAlreadyRung(for: scheduled,
                                    now: scheduled.addingTimeInterval(WakeBuzzAlarm.missedGraceSeconds + 60))

        XCTAssertFalse(ringer.isRinging, "past the grace window the ring must be skipped, not fired late")
        XCTAssertTrue(log.contains { $0.contains("skipped") }, "\(log)")
        XCTAssertEqual(defaults.integer(forKey: WakeBuzzAlarm.Key.lastFired), 0,
                       "a skipped instant must NOT be stamped — that is what burned the morning")

        // The retry the grace window exists for: a pass that lands inside it still delivers the alarm.
        ringer.fireIfNotAlreadyRung(for: scheduled, now: scheduled.addingTimeInterval(5))

        XCTAssertTrue(ringer.isRinging, "an unconsumed instant inside the window must still ring")
        XCTAssertEqual(defaults.integer(forKey: WakeBuzzAlarm.Key.lastFired),
                       Int(scheduled.timeIntervalSince1970),
                       "the stamp belongs on the path that actually rang")
        ringer.stop(reason: "Stop button")
    }

    /// The other half of the same rule: once it HAS rung, the instant is consumed for good. The grace
    /// window must not turn into a second buzz from the next foreground.
    @MainActor
    func testRungInstant_isConsumedExactlyOnce() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        ringer.buzz = {}
        ringer.strapReady = { true }

        ringer.fireIfNotAlreadyRung(for: scheduled, now: scheduled)
        XCTAssertTrue(ringer.isRinging)
        ringer.stop(reason: "Stop button")

        ringer.fireIfNotAlreadyRung(for: scheduled, now: scheduled.addingTimeInterval(3))
        XCTAssertFalse(ringer.isRinging, "the same instant must never ring twice")
    }

    // MARK: - (2) Test must not claim a ring it cannot deliver

    /// THE BUG: Test called `start`, which runs the ring whatever the link says — correct for the real
    /// 07:00 window, which is worth retrying into, and wrong for a button pressed by somebody watching
    /// their wrist. It flipped to "Stop" for thirty seconds and nothing left the phone.
    @MainActor
    func testStartTest_withNoStrap_sendsNothingAndStartsNoRing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var strapBuzzes = 0
        var phoneBuzzes = 0
        var log: [String] = []
        ringer.buzz = { strapBuzzes += 1 }
        ringer.strapReady = { false }
        ringer.phoneFallback = { phoneBuzzes += 1 }
        ringer.log = { log.append($0) }

        XCTAssertEqual(ringer.startTest(), .noStrap)

        XCTAssertFalse(ringer.isRinging, "no ring means the button stays on Test — there is nothing to stop")
        XCTAssertEqual(ringer.lastDelivery, .some(.noStrap), "the sheet must be able to say nothing was sent")
        XCTAssertEqual(strapBuzzes, 0, "a write that would be dropped must not be counted as a buzz")
        XCTAssertEqual(phoneBuzzes, 1, "the test still shows the user what the fallback feels like")
        XCTAssertTrue(log.contains { $0.contains("test sent NOTHING") }, "\(log)")
    }

    /// An unwired buzz is an APP bug, and a Test must not run a ring over it either.
    @MainActor
    func testStartTest_withNoBuzzWired_reportsAWiringBugAndStartsNoRing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        ringer.strapReady = { true }
        ringer.phoneFallback = {}

        XCTAssertEqual(ringer.startTest(), .noSink)
        XCTAssertFalse(ringer.isRinging)
        XCTAssertEqual(ringer.lastDelivery, .some(.noSink))
    }

    /// And with a reachable strap the Test is still the REAL ring — same cadence, same auto-stop, same
    /// stop gestures. A test that behaved differently from the alarm would prove nothing about it.
    @MainActor
    func testStartTest_withAConnectedStrap_runsTheRealRing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var strapBuzzes = 0
        var phoneBuzzes = 0
        ringer.buzz = { strapBuzzes += 1 }
        ringer.strapReady = { true }
        ringer.phoneFallback = { phoneBuzzes += 1 }

        XCTAssertEqual(ringer.startTest(), .sent)
        XCTAssertTrue(ringer.isRinging)
        XCTAssertEqual(strapBuzzes, 1)
        XCTAssertEqual(phoneBuzzes, 0, "the fallback is for a strap that cannot be reached, not a spare buzz")
        XCTAssertFalse(ringer.lastPhoneFallback)
        ringer.stop(reason: "Stop button")
    }

    // MARK: - (3) The phone-side fallback

    /// THE BUG: `buzz` was wired only to the strap, so a wake minute with the strap flat, out of range or
    /// off the wrist produced NOTHING while NOOP sat there awake and able to buzz the phone.
    ///
    /// Once per RING, not once per volley: a 30 s window is ~10 volleys, and ten phone buzzes is a
    /// different feature.
    @MainActor
    func testRing_withNoStrap_buzzesThePhoneOncePerRing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var phoneBuzzes = 0
        var log: [String] = []
        ringer.buzz = {}
        ringer.strapReady = { false }
        ringer.phoneFallback = { phoneBuzzes += 1 }
        ringer.log = { log.append($0) }

        ringer.start(reason: "wake time")
        XCTAssertEqual(phoneBuzzes, 1)
        XCTAssertTrue(ringer.lastPhoneFallback)
        XCTAssertTrue(log.contains { $0.contains("buzzed the PHONE instead") }, "\(log)")

        // Drive two more volleys the way the cadence timer would.
        ringer.deliverVolley()
        ringer.deliverVolley()
        XCTAssertEqual(phoneBuzzes, 1, "one phone buzz per ring, not one per volley")

        ringer.stop(reason: "auto-stop")

        // A NEW attempt is a new ring, and gets its own fallback.
        ringer.start(reason: "wake time")
        XCTAssertEqual(phoneBuzzes, 2)
        ringer.stop(reason: "Stop button")
    }

    /// A ring that reaches the strap never falls back, and never reports that it did.
    @MainActor
    func testRing_withAConnectedStrap_neverBuzzesThePhone() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var phoneBuzzes = 0
        ringer.buzz = {}
        ringer.strapReady = { true }
        ringer.phoneFallback = { phoneBuzzes += 1 }

        ringer.start(reason: "wake time")
        ringer.deliverVolley()
        XCTAssertEqual(phoneBuzzes, 0)
        XCTAssertFalse(ringer.lastPhoneFallback)
        ringer.stop(reason: "Stop button")
    }

    /// The fallback's log line names it as a FALLBACK, not as the alarm. The strap log is what a future
    /// "it didn't buzz" report is settled from, so it must not read as a success.
    func testPhoneFallbackLogLine_saysWhatItIsAndIsNotClaimedAsTheAlarm() {
        let away = WakeBuzzAlarm.phoneFallbackLogLine(reason: .noStrap)
        XCTAssertTrue(away.contains("PHONE"), away)
        XCTAssertTrue(away.contains("isn't connected"), away)
        XCTAssertTrue(away.lowercased().contains("fallback"), away)

        let unwired = WakeBuzzAlarm.phoneFallbackLogLine(reason: .noSink)
        XCTAssertTrue(unwired.contains("app bug"), unwired)
    }
}

/// The permission gates the same audit found: a launch path that cold-prompted for notifications, and
/// screens whose switches could sit ON against an OS that would deliver nothing.
final class NotificationGateTests: XCTestCase {

    // MARK: - What counts as "the OS will deliver"

    func testDelivers_onlyForStatusesThatActuallyDeliver() {
        XCTAssertTrue(NotificationPermission.delivers(.authorized))
        XCTAssertTrue(NotificationPermission.delivers(.provisional))
        XCTAssertFalse(NotificationPermission.delivers(.denied))
        XCTAssertFalse(NotificationPermission.delivers(.notDetermined),
                       "nobody has been asked yet, which is not permission")
    }

    // MARK: - The day rituals' registration gate

    /// THE BUG: `DayRitualScheduler.schedule()` called `requestAuthorization` COLD from a `.task` that
    /// runs at launch — behind the onboarding wizard and the un-accepted Terms gate. It was the only cold
    /// prompt in the app, it spent the one system dialog an install ever gets before the user had agreed
    /// to anything, and it made the wizard's own Notifications step decorative.
    @MainActor
    func testMayRegister_neverRegistersOnAnUnaskedInstall() {
        XCTAssertFalse(DayRitualScheduler.mayRegister(enabled: true, hasScoredDay: true, status: .notDetermined),
                       "`.notDetermined` is where the cold prompt used to happen; this is not the place that asks")
    }

    /// THE OTHER HALF: the morning knock says "Last night is scored." On an install with no strap nothing
    /// has been scored, so registering it scheduled a daily notification asserting something that had
    /// never happened.
    @MainActor
    func testMayRegister_waitsForADayToActuallyHaveBeenScored() {
        XCTAssertFalse(DayRitualScheduler.mayRegister(enabled: true, hasScoredDay: false, status: .authorized))
    }

    @MainActor
    func testMayRegister_respectsTheSwitchAndADeniedOS() {
        XCTAssertFalse(DayRitualScheduler.mayRegister(enabled: false, hasScoredDay: true, status: .authorized))
        XCTAssertFalse(DayRitualScheduler.mayRegister(enabled: true, hasScoredDay: true, status: .denied))
    }

    /// And once all three hold — switched on, permission already granted somewhere the user asked for it,
    /// and a day genuinely scored — the triggers go in.
    @MainActor
    func testMayRegister_registersOnceEverythingHolds() {
        XCTAssertTrue(DayRitualScheduler.mayRegister(enabled: true, hasScoredDay: true, status: .authorized))
        XCTAssertTrue(DayRitualScheduler.mayRegister(enabled: true, hasScoredDay: true, status: .provisional))
    }
}
