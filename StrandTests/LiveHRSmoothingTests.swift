import XCTest
@testable import Strand

/// Pins the live-HR smoothing that feeds `AppModel.bpm` — the number every live surface shows.
///
/// THE BUG THESE PIN. `hrWindow` is pruned against the WALL CLOCK but used to be fed only by the two
/// `LiveState` sinks, and both HR publishers are change-guarded (`FrameRouter`'s `state.heartRate != hr`
/// and `BLEManager`'s standard-profile twin; the realtime stream usually reports `rr_count = 0`, so the
/// R-R sink cannot be relied on to tick either). On a steady bpm the window was therefore fed nothing at
/// all: it aged out completely, and the next genuine change refilled it from almost empty and moved the
/// displayed number in ONE step. The documented "~10 s median" was in practice a median over CHANGES,
/// which smooths hardest exactly when the wearer's heart rate is moving fastest and not at all when it
/// is holding — the opposite of what a spike filter is for. Feeding the same window on a 1 Hz clock
/// (`AppModel.tickSmoothing`) makes it the time window it claims to be.
///
/// Pure / @MainActor: no strap, no app host.
@MainActor
final class LiveHRSmoothingTests: XCTestCase {

    // MARK: - The instantaneous reading a packet carries

    func testReportedHeartRateWins() {
        XCTAssertEqual(AppModel.instantHR(heartRate: 62, rr: [1000]), 62)
    }

    /// No reported HR (or an implausible one) falls through to 60000/R-R, which is the only live value a
    /// standard-profile-only link supplies.
    func testFallsBackToRRWhenReportedHeartRateIsUnusable() {
        XCTAssertEqual(AppModel.instantHR(heartRate: nil, rr: [1000]), 60)
        XCTAssertEqual(AppModel.instantHR(heartRate: 0, rr: [1000]), 60)
        XCTAssertEqual(AppModel.instantHR(heartRate: 500, rr: [1000]), 60)
    }

    /// Absent input yields nothing — never a substituted default (the readout shows "—").
    func testAbsentOrImplausibleInputYieldsNothing() {
        XCTAssertNil(AppModel.instantHR(heartRate: nil, rr: []))
        XCTAssertNil(AppModel.instantHR(heartRate: nil, rr: [0]))
        XCTAssertNil(AppModel.instantHR(heartRate: nil, rr: [-1]))
        // 60000/200 ms = 300 bpm: out of the plausible 30–220 band.
        XCTAssertNil(AppModel.instantHR(heartRate: nil, rr: [200]))
        XCTAssertNil(AppModel.instantHR(heartRate: 25, rr: []))
        XCTAssertNil(AppModel.instantHR(heartRate: 221, rr: []))
    }

    // MARK: - The window

    /// Folding the same reading once a second holds the median steady at it. This is the case the
    /// change-guarded feed could not produce at all, because a steady bpm published nothing.
    func testSteadyClockedFeedHoldsTheMedianAtTheReading() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var window: [(t: Date, v: Double)] = []
        var bpm: Int?
        for second in 0...9 {
            let folded = AppModel.fold(window: window, inst: 60, now: t0.addingTimeInterval(Double(second)))
            window = folded.window
            bpm = folded.bpm
        }
        XCTAssertEqual(bpm, 60)
        XCTAssertEqual(window.count, 10)
    }

    /// THE REGRESSION, exactly. Fed only on change, a 30-second hold at 60 followed by a step to 70 ages
    /// the whole window out, so the "median" is a single sample and the displayed number jumps 60 → 70 in
    /// one go with no smoothing applied at all.
    func testEventOnlyFeedAgesOutAndPublishesAnUnsmoothedStep() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let first = AppModel.fold(window: [], inst: 60, now: t0)
        XCTAssertEqual(first.bpm, 60)
        let afterHold = AppModel.fold(window: first.window, inst: 70,
                                      now: t0.addingTimeInterval(30))
        XCTAssertEqual(afterHold.window.count, 1, "the held-at-60 samples are all older than the window")
        XCTAssertEqual(afterHold.bpm, 70, "no smoothing survived the hold")
    }

    /// Clocked, the same step is smoothed instead of jumped: the median walks and reaches the new reading
    /// about half a window later. Half of ~10 s is the group delay the window costs by construction — the
    /// price of the stability a readout wants, and why the zone cue reads `zoneCueSmoothingSeconds`
    /// instead of this value.
    func testClockedFeedSmoothsAStepAndReachesItAboutHalfAWindowLater() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var window: [(t: Date, v: Double)] = []
        for second in 0...9 {
            window = AppModel.fold(window: window, inst: 60, now: t0.addingTimeInterval(Double(second))).window
        }
        var reachedAt: Int?
        for second in 10...20 {
            let folded = AppModel.fold(window: window, inst: 70, now: t0.addingTimeInterval(Double(second)))
            window = folded.window
            if folded.bpm == 70, reachedAt == nil { reachedAt = second }
        }
        XCTAssertEqual(reachedAt, 15, "a 10 s median lags a real step by about 5 s")
    }

    /// The window is bounded in BOTH directions — by age and by count — so a burst-mode feed cannot grow
    /// it without limit.
    func testWindowIsBoundedByAgeAndByCount() {
        XCTAssertEqual(AppModel.hrSmoothingSeconds, 10)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        // Age: a sample older than the window is gone, whatever fed it.
        let stale = AppModel.fold(window: [], inst: 60, now: t0)
        XCTAssertEqual(AppModel.fold(window: stale.window, inst: 61,
                                     now: t0.addingTimeInterval(11)).window.count, 1)
        var window: [(t: Date, v: Double)] = []
        // 200 readings inside one second: the cap, not the age, is what bounds this.
        for i in 0..<200 {
            window = AppModel.fold(window: window, inst: 60,
                                   now: t0.addingTimeInterval(Double(i) / 200)).window
        }
        XCTAssertEqual(window.count, AppModel.hrSmoothingMaxSamples)
    }

    /// A single garbage spike inside an otherwise steady window must not reach the screen — the reason the
    /// median exists (a real ~92 read as 170+ by a PPG harmonic).
    func testAnIsolatedSpikeIsRejected() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var window: [(t: Date, v: Double)] = []
        for second in 0...8 {
            window = AppModel.fold(window: window, inst: 92, now: t0.addingTimeInterval(Double(second))).window
        }
        let spiked = AppModel.fold(window: window, inst: 184, now: t0.addingTimeInterval(9))
        XCTAssertEqual(spiked.bpm, 92)
    }
}
