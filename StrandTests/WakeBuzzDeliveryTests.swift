import XCTest
@testable import Strand

/// Pins the HONESTY half of the Sleep tab's wake buzz: whether a buzz volley actually reached the strap,
/// and whether the ringer and the strap log say so.
///
/// This is the behaviour the feature shipped without, and it is why "the vibration for the alarm doesn't
/// work at all" could not be diagnosed from anything the app showed or recorded. `WakeBuzzRinger.buzz`
/// ends in `BLEManager.send`, which DROPS the write and returns when the link is down; the ringer could
/// not tell that from a delivered write, so it set `isRinging`, logged "ringing", and the sheet showed
/// "Stop" for thirty seconds over a strap that never heard a thing.
///
/// Everything here runs with no strap, no run loop turn and no view: the ringer is driven directly, its
/// timers are invalidated by the `stop` each test ends with, and the log is captured into an array.
final class WakeBuzzDeliveryTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WakeBuzzDeliveryTests.\(UUID().uuidString)")!
    }

    // MARK: - The pure log line

    func testDeliveryLogLine_namesTheAllDroppedCaseExplicitly() {
        let line = WakeBuzzAlarm.deliveryLogLine(sent: 0, dropped: 10, reason: "auto-stop")
        XCTAssertTrue(line.contains("NOTHING reached the strap"), line)
        XCTAssertTrue(line.contains("10"), line)
        XCTAssertTrue(line.contains("auto-stop"), line)
    }

    func testDeliveryLogLine_reportsBothHalvesOfAMixedRing() {
        let line = WakeBuzzAlarm.deliveryLogLine(sent: 4, dropped: 6, reason: "strap double-tap")
        XCTAssertTrue(line.contains("4 volleys sent"), line)
        XCTAssertTrue(line.contains("6 dropped"), line)
    }

    func testDeliveryLogLine_cleanRingDoesNotMentionDrops() {
        let line = WakeBuzzAlarm.deliveryLogLine(sent: 10, dropped: 0, reason: "Stop button")
        XCTAssertTrue(line.contains("10 volleys sent"), line)
        XCTAssertFalse(line.lowercased().contains("dropped"), line)
    }

    /// A ring that was stopped before any volley was attempted must not claim a tally it doesn't have.
    func testDeliveryLogLine_noVolleysAttempted() {
        let line = WakeBuzzAlarm.deliveryLogLine(sent: 0, dropped: 0, reason: "alarm turned off")
        XCTAssertTrue(line.contains("no volleys were attempted"), line)
    }

    // MARK: - What a ring reports

    /// The case the user is actually in: the alarm rings, the strap is out of range, and NOTHING is sent.
    /// The old code called `buzz` anyway, `send` dropped it, and every surface reported success.
    @MainActor
    func testRing_withNoStrapConnected_sendsNothingAndSaysSo() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var buzzes = 0
        var log: [String] = []
        ringer.buzz = { buzzes += 1 }
        ringer.strapReady = { false }
        ringer.log = { log.append($0) }

        let outcome = ringer.start(reason: "test")

        XCTAssertEqual(outcome, .noStrap)
        XCTAssertEqual(ringer.lastDelivery, .some(.noStrap))
        XCTAssertEqual(buzzes, 0, "a write that would be dropped must not be counted as a buzz")
        XCTAssertTrue(log.contains { $0.contains("NOT sent") }, "\(log)")

        ringer.stop(reason: "Stop button")
        XCTAssertTrue(log.contains { $0.contains("NOTHING reached the strap") }, "\(log)")
    }

    @MainActor
    func testRing_withAConnectedStrap_sendsTheFirstVolleyImmediately() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var buzzes = 0
        ringer.buzz = { buzzes += 1 }
        ringer.strapReady = { true }

        let outcome = ringer.start(reason: "wake time")

        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(ringer.lastDelivery, .some(.sent))
        XCTAssertEqual(buzzes, 1, "the wrist must feel the first volley at the chosen minute, not one cadence later")
        ringer.stop(reason: "Stop button")
    }

    /// An unwired buzz is an APP bug and has to look like one. It used to be indistinguishable from a
    /// quiet strap, which is the single worst failure mode for a feature the user can only judge by feel.
    @MainActor
    func testRing_withNoBuzzWired_reportsAWiringBugNotAQuietStrap() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var log: [String] = []
        ringer.log = { log.append($0) }
        ringer.strapReady = { true }

        XCTAssertEqual(ringer.start(reason: "test"), .noSink)
        XCTAssertEqual(ringer.lastDelivery, .some(.noSink))
        XCTAssertTrue(log.contains { $0.contains("no buzz sink") }, "\(log)")
        ringer.stop(reason: "Stop button")
    }

    /// `strapReady` unwired counts as reachable. The ringer must not invent a FAILURE it cannot observe
    /// any more than it may invent a success — and a host that never wired the link state (a test, a
    /// preview) has not told it anything.
    @MainActor
    func testRing_withNoReadinessWired_stillBuzzesRatherThanInventingAFailure() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var buzzes = 0
        ringer.buzz = { buzzes += 1 }

        XCTAssertEqual(ringer.start(reason: "test"), .sent)
        XCTAssertEqual(buzzes, 1)
        ringer.stop(reason: "Stop button")
    }

    /// A strap that comes back mid-ring must flip the report to `.sent`. The 30 s window is there to be
    /// retried into, so the UI cannot be left claiming failure once a volley has landed.
    @MainActor
    func testRing_reportsRecoveryWhenTheLinkComesBackMidRing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var connected = false
        var buzzes = 0
        var log: [String] = []
        ringer.buzz = { buzzes += 1 }
        ringer.strapReady = { connected }
        ringer.log = { log.append($0) }

        XCTAssertEqual(ringer.start(reason: "wake time"), .noStrap)
        connected = true
        // Drive one more volley the way the cadence timer would, without spinning a run loop for 3 s.
        ringer.deliverVolley()

        XCTAssertEqual(ringer.lastDelivery, .some(.sent))
        XCTAssertEqual(buzzes, 1)
        ringer.stop(reason: "auto-stop")
        XCTAssertTrue(log.contains { $0.contains("1 volleys sent") && $0.contains("1 dropped") }, "\(log)")
    }

    /// The strap double-tap still owns the gesture, and the stop it produces still carries the tally.
    @MainActor
    func testDoubleTap_stopsARingAndTheTallyIsLogged() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var log: [String] = []
        ringer.buzz = {}
        ringer.strapReady = { true }
        ringer.log = { log.append($0) }

        let start = Date()
        ringer.start(reason: "wake time", now: start)
        XCTAssertTrue(ringer.handleDoubleTap(at: start.addingTimeInterval(2)))
        XCTAssertFalse(ringer.isRinging)
        XCTAssertTrue(log.contains { $0.contains("strap double-tap") && $0.contains("1 volleys sent") }, "\(log)")
    }

    // MARK: - Arming

    /// The arm line is what makes a future "it didn't buzz" report decidable — before it, nothing in the
    /// log distinguished "never armed" from "armed and dropped on the wire". It must be logged once per
    /// changed instant, NOT once per `reschedule`: that runs on every foreground, every settings edit and
    /// every day rollover.
    @MainActor
    func testReschedule_logsTheArmOncePerChangedInstantAndNamesTheStrapState() {
        let defaults = freshDefaults()
        WakeBuzzAlarm.setEnabled(true, defaults)
        WakeBuzzAlarm.setMinutes(7 * 60, defaults)
        let ringer = WakeBuzzRinger(defaults: defaults)
        var log: [String] = []
        ringer.log = { log.append($0) }
        ringer.strapReady = { false }

        // A FIXED `now`, for two reasons: the resolved instant must be identical across the three calls
        // for "logged once" to mean anything, and a real `now` inside the 30 s after 07:00 would take the
        // catch-up branch and legitimately arm tomorrow instead — a once-a-day flake. Kept in the future
        // so the fire timer this arms is never already due.
        let now = Date().addingTimeInterval(30 * 86_400)

        ringer.reschedule(now: now)
        let armLines = log.filter { $0.contains("Wake buzz: armed for") }
        XCTAssertEqual(armLines.count, 1, "\(log)")
        XCTAssertTrue(armLines[0].contains("strap NOT connected"), armLines[0])
        XCTAssertNotNil(ringer.nextFire)

        ringer.reschedule(now: now)
        ringer.reschedule(now: now)
        XCTAssertEqual(log.filter { $0.contains("Wake buzz: armed for") }.count, 1,
                       "a re-resolve of the SAME instant must not re-log the arm: \(log)")

        // Turning it off is its own line, and the schedule clears.
        WakeBuzzAlarm.setEnabled(false, defaults)
        ringer.reschedule(now: now)
        XCTAssertTrue(log.contains { $0.contains("disarmed") }, "\(log)")
        XCTAssertNil(ringer.nextFire)
    }

    /// The alarm being off must produce no arm line at all — an alarm nobody switched on is not armed.
    @MainActor
    func testReschedule_offAlarmLogsNoArm() {
        let defaults = freshDefaults()
        let ringer = WakeBuzzRinger(defaults: defaults)
        var log: [String] = []
        ringer.log = { log.append($0) }

        ringer.reschedule(now: Date().addingTimeInterval(30 * 86_400))

        XCTAssertNil(ringer.nextFire)
        XCTAssertFalse(log.contains { $0.contains("Wake buzz: armed for") }, "\(log)")
        XCTAssertFalse(log.contains { $0.contains("disarmed") },
                       "nothing was armed, so there is nothing to disarm: \(log)")
    }
}
