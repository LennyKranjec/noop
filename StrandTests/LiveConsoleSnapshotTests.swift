import XCTest
import WhoopStore
@testable import Strand

/// Pins the invalidation contract of `LiveConsoleSnapshot` — the value that replaced `LiveView`'s
/// `@EnvironmentObject` on `LiveState` and `AppModel`.
///
/// The screen's whole correctness now rests on ONE property: the snapshot compares unequal for every coarse
/// field the parent body renders from, and compares EQUAL for everything that moves at the live rate. Get
/// the first wrong and a readout freezes; get the second wrong and the ~700-line parent is back on a
/// per-packet redraw and the pass bought nothing. Neither failure is visible in a diff, and there is no
/// screenshot test that would catch either — hence these cases.
///
/// Pure: no SwiftUI host, no BLE, no `AppModel`. @MainActor only because `AppModel.ActiveWorkout` is reached
/// through `AppModel`.
@MainActor
final class LiveConsoleSnapshotTests: XCTestCase {

    // MARK: - A changed coarse field must invalidate

    /// Every field the parent gates layout or copy on, mutated one at a time off the same base. A field that
    /// survives this comparison equal is a field the parent will never re-read.
    func testEveryCoarseFieldInvalidates() {
        let base = LiveConsoleSnapshot()

        var mutations: [(String, LiveConsoleSnapshot)] = []
        func mutate(_ name: String, _ change: (inout LiveConsoleSnapshot) -> Void) {
            var next = base
            change(&next)
            mutations.append((name, next))
        }

        mutate("connected") { $0.connected = true }
        mutate("bonded") { $0.bonded = true }
        mutate("encryptedBond") { $0.encryptedBond = true }
        mutate("streamingLiveHR") { $0.streamingLiveHR = true }
        mutate("backfilling") { $0.backfilling = true }
        mutate("reconnectGuide") { $0.reconnectGuide = "re-pair your strap" }
        mutate("pairingHint") { $0.pairingHint = "free the strap in the WHOOP app" }
        mutate("standardHRMode") { $0.standardHRMode = "low bandwidth" }
        mutate("activeIsWhoop") { $0.activeIsWhoop = false }
        mutate("activeDeviceName") { $0.activeDeviceName = "Oura Ring 4" }
        mutate("workout") { $0.workout = clock() }
        mutate("lastWorkout") { $0.lastWorkout = savedWorkout() }

        for (name, changed) in mutations {
            XCTAssertNotEqual(base, changed,
                              "\(name) changed but the snapshot compared equal — the parent would never re-render it")
        }
    }

    /// An unchanged coarse field does NOT invalidate: this is what lets the `.onReceive` guard drop the
    /// replay every re-subscription performs instead of writing `@State` and inviting a render loop.
    func testIdenticalCoarseStateDoesNotInvalidate() {
        let a = LiveConsoleSnapshot(
            connected: true, bonded: true, encryptedBond: true, streamingLiveHR: false,
            backfilling: true, reconnectGuide: nil, pairingHint: "hint", standardHRMode: nil,
            activeIsWhoop: true, activeDeviceName: "WHOOP",
            workout: clock(), lastWorkout: savedWorkout())
        var b = a
        XCTAssertEqual(a, b)
        // Re-deriving the workout clock from the same inputs also compares equal (value semantics, no
        // identity), so a repeated publish of an unchanged workout is dropped rather than re-rendered.
        b.workout = clock()
        XCTAssertEqual(a, b)
    }

    // MARK: - Live-rate fields must NOT be in the snapshot

    /// The 1 Hz `activeWorkout` rewrite must not reach the parent. `avgHr` / `peakHr` / `liveStrain` /
    /// `samples` change every second of a workout; if any of them were carried here, the parent would
    /// re-evaluate at 1 Hz through a whole workout — which is the bug this file exists to close.
    /// `ActiveWorkoutLive` reads them off its own observed `AppModel`.
    func testLiveWorkoutStatsAreNotPartOfTheSnapshot() {
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 1_000))
        workout.sport = "Rowing"
        let before = LiveConsoleSnapshot.WorkoutClock.make(from: workout)

        // One second of a live session: new samples, a new average, a new peak, more effort.
        workout.avgHr = 141
        workout.peakHr = 176
        workout.liveStrain = 12.5
        workout.samples = []

        XCTAssertEqual(before, LiveConsoleSnapshot.WorkoutClock.make(from: workout),
                       "a live-rate workout stat leaked into the snapshot: the parent will re-render at 1 Hz")

        var a = LiveConsoleSnapshot()
        a.workout = before
        var b = LiveConsoleSnapshot()
        b.workout = LiveConsoleSnapshot.WorkoutClock.make(from: workout)
        XCTAssertEqual(a, b)
    }

    /// Pause/resume, by contrast, IS coarse and must invalidate — the card's label swaps to "Paused" and its
    /// clock has to start subtracting. Carried by value for the reason #1533 taught: a card cannot subtract
    /// paused time it was never handed.
    func testPauseStateIsCoarseAndInvalidates() {
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 1_000))
        let running = LiveConsoleSnapshot.WorkoutClock.make(from: workout)

        workout.pausedAt = Date(timeIntervalSince1970: 1_060)
        let paused = LiveConsoleSnapshot.WorkoutClock.make(from: workout)
        XCTAssertNotEqual(running, paused)
        XCTAssertEqual(paused?.isPaused, true)
        XCTAssertEqual(running?.isPaused, false)

        // Resumed after 30 s paused: `pausedDuration` banks it, which is again a coarse change.
        workout.pausedAt = nil
        workout.pausedDuration = 30
        let resumed = LiveConsoleSnapshot.WorkoutClock.make(from: workout)
        XCTAssertNotEqual(running, resumed)
        XCTAssertEqual(resumed?.isPaused, false)

        // And the clock the card renders still subtracts the paused time — same rule as every other surface.
        XCTAssertEqual(resumed?.elapsed(at: Date(timeIntervalSince1970: 1_100)), 70)
    }

    /// No workout means no card: the `nil` branch the parent's `if let` takes.
    func testNoWorkoutMakesNoClock() {
        XCTAssertNil(LiveConsoleSnapshot.WorkoutClock.make(from: nil))
    }

    // MARK: - Derived link states

    /// `activeConnection` needs all three, and `activeIsWhoop` in particular: `LiveState` is one object every
    /// live source writes into, so `connected && bonded` stays true for a bonded strap while an Oura ring is
    /// the device on screen (#2075). `ringStreaming` is the ring's own trusted-stream branch (#69 twin).
    func testDerivedLinkStates() {
        var s = LiveConsoleSnapshot()
        XCTAssertFalse(s.activeConnection)
        XCTAssertFalse(s.ringStreaming)

        s.connected = true
        s.bonded = true
        XCTAssertTrue(s.activeConnection, "a bonded WHOOP link is the trusted case")

        s.activeIsWhoop = false
        XCTAssertFalse(s.activeConnection, "#2075: a ring on screen must not inherit the strap's bond")
        XCTAssertFalse(s.ringStreaming, "a ring that is not streaming live HR is not a trusted stream")

        s.streamingLiveHR = true
        XCTAssertTrue(s.ringStreaming)
        XCTAssertFalse(s.activeConnection, "the ring stream must never unlock the bond-only controls")
    }

    // MARK: - The device readout the snapshot carries

    /// The name + kind resolve exactly as the parent's own registry reads did, including the WHOOP-first
    /// fallback for a registry that has not opened or an active id that names no row (#1303).
    func testDeviceNameAndKindFallBackToWhoopFirst() {
        XCTAssertEqual(LiveConsoleSnapshot.deviceName(devices: [], activeId: nil), "WHOOP")
        XCTAssertEqual(LiveConsoleSnapshot.deviceName(devices: [], activeId: "whoop-ABC"), "WHOOP")
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [], activeId: nil))

        let ring = device(id: "oura-123", brand: "Oura", model: "Oura Ring 4")
        XCTAssertEqual(LiveConsoleSnapshot.deviceName(devices: [ring], activeId: "oura-123"), "Oura Ring 4")
        XCTAssertFalse(LiveConsoleReadout.activeIsWhoop(devices: [ring], activeId: "oura-123"))

        let named = device(id: "my-whoop", brand: "WHOOP", model: "WHOOP 4.0", nickname: "Left wrist")
        XCTAssertEqual(LiveConsoleSnapshot.deviceName(devices: [named], activeId: "my-whoop"), "Left wrist")
        XCTAssertTrue(LiveConsoleReadout.activeIsWhoop(devices: [named], activeId: "my-whoop"))
    }

    // MARK: - Fixtures

    private func clock() -> LiveConsoleSnapshot.WorkoutClock {
        LiveConsoleSnapshot.WorkoutClock(start: Date(timeIntervalSince1970: 1_000))
    }

    private func savedWorkout() -> WorkoutRow {
        WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "Rowing", source: "live",
                   durationS: 1_000, energyKcal: nil, avgHr: 130, maxHr: 170, strain: 9.5,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func device(id: String, brand: String, model: String, nickname: String? = nil) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nickname,
                     sourceKind: .liveBLE, capabilities: [], status: .active,
                     addedAt: 0, lastSeenAt: 0)
    }
}
