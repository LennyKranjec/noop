import XCTest
@testable import Strand

/// Pins the case a real WHOOP 5/MG owner (firmware 50.42.1.0, after an iPhone reset and an app reinstall)
/// lost days to: the strap CONNECTED, the command characteristic discovered, and every proprietary write
/// rejected at the ATT layer with "Authentication is insufficient" (`cbAttError5`) because the encrypted
/// pairing was gone from the phone and the strap would not grant a new one.
///
/// What the app did with that, verbatim from their strap log:
///
///     → Run Haptics Pattern payload=012f98000000000000000002 (puffin cmd=0x13)
///     → Run Alarm payload=0201 (puffin)
///     Buzz: one-shot fired (5/MG maverick buzz + runAlarm rev2, acked)
///     Wake buzz: volley sent to the strap
///     Confirmed write failed: Authentication is insufficient. [cbAttError5]
///     Confirmed write failed: Authentication is insufficient. [cbAttError5]
///
/// Three claims of success above two refusals. "acked" was logged at WRITE time, before any acknowledgement
/// could have arrived; the ringer reported `.sent`; and the alarm sheet showed "Stop" for thirty seconds.
/// The verdict now comes from the write's RESULT, and these tests pin the two pure decisions that carry it:
/// which `Delivery` a volley is given, and which message the user is shown.
///
/// Everything here runs with no strap, no CoreBluetooth, no run loop turn and no view.
final class WakeBuzzBondRefusalTests: XCTestCase {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "WakeBuzzBondRefusalTests.\(UUID().uuidString)")!
    }

    // MARK: - The delivery verdict

    func testVerdict_aRefusedBondIsNeverReportedAsSent() {
        XCTAssertEqual(WakeBuzzAlarm.verdict(hasSink: true, strapReachable: true, bondRefused: true),
                       .strapRefused)
    }

    /// THE PRECEDENCE THAT MATTERS. `strapReachable` carries `BLEManager.commandChannelReady`, which is now
    /// false while writes are refused — so both bits are "bad" at once, and checking reachability first
    /// would collapse a refused strap into `.noStrap`, i.e. "your strap isn't connected". That is the one
    /// instruction that cannot possibly help someone whose strap is sitting there connected.
    func testVerdict_refusalOutranksUnreachable() {
        XCTAssertEqual(WakeBuzzAlarm.verdict(hasSink: true, strapReachable: false, bondRefused: true),
                       .strapRefused)
    }

    /// An app-wiring bug outranks everything: it is ours, and it is the one failure that otherwise looks
    /// exactly like a quiet strap.
    func testVerdict_noSinkOutranksEverything() {
        XCTAssertEqual(WakeBuzzAlarm.verdict(hasSink: false, strapReachable: false, bondRefused: true),
                       .noSink)
    }

    func testVerdict_plainDisconnectedStrapStillReportsNoStrap() {
        XCTAssertEqual(WakeBuzzAlarm.verdict(hasSink: true, strapReachable: false, bondRefused: false),
                       .noStrap)
    }

    func testVerdict_aUsableLinkReportsSent() {
        XCTAssertEqual(WakeBuzzAlarm.verdict(hasSink: true, strapReachable: true, bondRefused: false),
                       .sent)
    }

    // MARK: - Which message the user is shown

    /// The BLE layer's own observation wins when it has one: #78's "held by the WHOOP app or a stale
    /// pairing", #747's paused hint, #1635's unanswered handshake. They are closer to the evidence than
    /// anything the alarm sheet could assert on its own.
    func testReach_prefersTheObservedPairingHint() {
        let hint = BondRefusalGiveUp.pairingRefusedHint()
        XCTAssertEqual(WakeBuzzAlarm.reach(strapConnected: true, bondRefused: true, pairingHint: hint),
                       .refused(hint))
    }

    /// With no observation to quote, the refusal itself is still enough to say what is wrong and what to do
    /// — silence was the actual bug, and an empty string would reproduce it.
    func testReach_fallsBackToTheRefusedWriteGuidanceWithNoHint() {
        guard case .refused(let text) = WakeBuzzAlarm.reach(strapConnected: true,
                                                           bondRefused: true,
                                                           pairingHint: nil) else {
            return XCTFail("a refused bond must produce guidance, not a bare warning")
        }
        XCTAssertEqual(text, BondRefusalGiveUp.writesRefusedHint())
        // The two actions the user cannot work out for themselves.
        XCTAssertTrue(text.contains("WHOOP app"), text)
        XCTAssertTrue(text.contains("pairing mode"), text)
    }

    /// Same precedence as `verdict`, for the same reason: a refused link reads as disconnected through
    /// `commandChannelReady`, so "not connected" must not win.
    func testReach_refusalOutranksTheConnectedFlag() {
        XCTAssertEqual(WakeBuzzAlarm.reach(strapConnected: false, bondRefused: true, pairingHint: "x"),
                       .refused("x"))
    }

    func testReach_unchangedForTheTwoStatesThatAlreadyWorked() {
        XCTAssertEqual(WakeBuzzAlarm.reach(strapConnected: true, bondRefused: false, pairingHint: nil),
                       .canBuzz)
        XCTAssertEqual(WakeBuzzAlarm.reach(strapConnected: false, bondRefused: false, pairingHint: nil),
                       .notConnected)
        // A stale hint must not, on its own, turn a working link into a warning: the hint outlives the
        // condition in several BLE paths (it deliberately survives `bonded` flipping true, #69).
        XCTAssertEqual(WakeBuzzAlarm.reach(strapConnected: true, bondRefused: false, pairingHint: "stale"),
                       .canBuzz)
    }

    /// The guidance the alarm sheet and Devices both show is ONE string, not two literals that drift.
    func testPairingHintIsSharedNotRetyped() {
        XCTAssertTrue(BondRefusalGiveUp.pairingRefusedHint().contains("Forget This Device"))
        XCTAssertNotEqual(BondRefusalGiveUp.pairingRefusedHint(), BondRefusalGiveUp.writesRefusedHint(),
                          "the refused-WRITE case is a different observation and must read differently")
        // Project rule: no em-dash in these shared strings (they are byte-matched against the Android twins).
        XCTAssertFalse(BondRefusalGiveUp.writesRefusedHint().contains("—"))
    }

    // MARK: - What a ring does with it

    /// The headline regression. Previously: `strapReady` false ⇒ `.noStrap` ⇒ "your strap isn't connected",
    /// or — before that — `.sent` and a thirty-second "Stop" over a strap receiving nothing.
    @MainActor
    func testRing_withARefusedBond_sendsNothingAndNamesThePairing() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var buzzes = 0
        var log: [String] = []
        ringer.buzz = { buzzes += 1 }
        // Exactly how AppModel wires it: `commandChannelReady` is false BECAUSE writes are refused.
        ringer.strapReady = { false }
        ringer.bondRefused = { true }
        ringer.log = { log.append($0) }

        let outcome = ringer.start(reason: "wake time")

        XCTAssertEqual(outcome, .strapRefused)
        XCTAssertEqual(ringer.lastDelivery, .some(.strapRefused))
        XCTAssertEqual(buzzes, 0, "a write the strap rejects must not be counted as a buzz")
        XCTAssertTrue(log.contains { $0.contains("refusing everything NOOP writes") }, "\(log)")
        XCTAssertFalse(log.contains { $0.contains("volley sent to the strap") }, "\(log)")
        // And the tally names the right cause instead of the "(strap not connected)" it used to assume.
        ringer.stop(reason: "auto-stop")
        XCTAssertTrue(log.contains { $0.contains("refusing NOOP's writes") }, "\(log)")
    }

    /// The phone fallback still fires — the wake minute is not silent just because the strap is unpaired —
    /// and it is logged as the refusal it answered, not as an absent strap.
    @MainActor
    func testRing_withARefusedBond_fallsBackToThePhoneAndSaysWhy() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var phoneBuzzes = 0
        var log: [String] = []
        ringer.buzz = {}
        ringer.strapReady = { false }
        ringer.bondRefused = { true }
        ringer.phoneFallback = { phoneBuzzes += 1 }
        ringer.log = { log.append($0) }

        ringer.start(reason: "wake time")
        ringer.deliverVolley()   // a second volley must not re-buzz the phone

        XCTAssertEqual(phoneBuzzes, 1)
        XCTAssertTrue(ringer.lastPhoneFallback)
        XCTAssertTrue(log.contains { $0.contains("buzzed the PHONE instead") && $0.contains("refusing") },
                      "\(log)")
        ringer.stop(reason: "Stop button")
    }

    /// The Test button is the one path a user triggers while watching their wrist, so it must refuse to run
    /// a ring it knows cannot land — and must not tell them the strap is disconnected while the screen
    /// beside it says connected.
    @MainActor
    func testStartTest_withARefusedBond_runsNoRingAtAll() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var buzzes = 0
        var log: [String] = []
        ringer.buzz = { buzzes += 1 }
        ringer.strapReady = { false }
        ringer.bondRefused = { true }
        ringer.log = { log.append($0) }

        XCTAssertEqual(ringer.startTest(), .strapRefused)
        XCTAssertFalse(ringer.isRinging, "there is no ring to stop, so the button must stay on Test")
        XCTAssertEqual(buzzes, 0)
        XCTAssertTrue(log.contains { $0.contains("test sent NOTHING") && $0.contains("refusing") }, "\(log)")
    }

    /// RE-PAIRING HEALS IT, with no recovery path of its own: `BLEManager` clears the flag on the first
    /// confirmed write that comes back clean (on a 5/MG, the CLIENT_HELLO ack), and the very next volley
    /// reports `.sent`. This is the pure-side proof of that claim.
    @MainActor
    func testRing_recoversTheMomentTheStrapAcceptsWritesAgain() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        var refused = true
        var buzzes = 0
        ringer.buzz = { buzzes += 1 }
        ringer.strapReady = { !refused }
        ringer.bondRefused = { refused }

        XCTAssertEqual(ringer.start(reason: "wake time"), .strapRefused)
        refused = false
        XCTAssertEqual(ringer.deliverVolley(), .sent)
        XCTAssertEqual(ringer.lastDelivery, .some(.sent))
        XCTAssertEqual(buzzes, 1)
        ringer.stop(reason: "auto-stop")
    }

    /// An unwired `bondRefused` must not invent a failure — the mirror of the `strapReady` rule. A host that
    /// told us nothing (a test, a preview) has not told us the bond is broken.
    @MainActor
    func testRing_withNoRefusalWired_behavesExactlyAsBefore() {
        let ringer = WakeBuzzRinger(defaults: freshDefaults())
        ringer.buzz = {}
        ringer.strapReady = { true }

        XCTAssertEqual(ringer.start(reason: "test"), .sent)
        ringer.stop(reason: "Stop button")
    }

    /// The arm note has to distinguish the two, because they need OPPOSITE action before the wake minute:
    /// one is "have the strap on and connected", the other is "re-pair it, waiting will not help".
    @MainActor
    func testArmLine_namesTheRefusedBondRatherThanAnAbsentStrap() {
        let defaults = freshDefaults()
        WakeBuzzAlarm.setEnabled(true, defaults)
        WakeBuzzAlarm.setMinutes(7 * 60, defaults)
        let ringer = WakeBuzzRinger(defaults: defaults)
        var log: [String] = []
        ringer.log = { log.append($0) }
        ringer.strapReady = { false }
        ringer.bondRefused = { true }

        // Fixed, far-future `now` for the same reasons as WakeBuzzDeliveryTests' arm test: a stable resolved
        // instant, and a fire timer that is never already due.
        ringer.reschedule(now: Date().addingTimeInterval(30 * 86_400))

        let arm = log.filter { $0.contains("Wake buzz: armed for") }
        XCTAssertEqual(arm.count, 1, "\(log)")
        XCTAssertTrue(arm[0].contains("REFUSING"), arm[0])
        XCTAssertFalse(arm[0].contains("NOT connected"),
                       "a connected strap must not be reported as absent: \(arm[0])")
    }

    // MARK: - The log line

    func testPhoneFallbackLogLine_hasItsOwnRefusedBondCase() {
        let line = WakeBuzzAlarm.phoneFallbackLogLine(reason: .strapRefused)
        XCTAssertTrue(line.contains("connected but refusing"), line)
        XCTAssertTrue(line.contains("Re-pair"), line)
    }

    /// The default keeps every existing caller (and the lines `WakeBuzzDeliveryTests` pins) byte-identical.
    func testDeliveryLogLine_causeIsOptedIntoNotAssumed() {
        XCTAssertTrue(WakeBuzzAlarm.deliveryLogLine(sent: 0, dropped: 3, reason: "auto-stop")
            .contains("(strap not connected)"))
        XCTAssertTrue(WakeBuzzAlarm.deliveryLogLine(sent: 0, dropped: 3, reason: "auto-stop", refusedBond: true)
            .contains("refusing NOOP's writes"))
    }
}
