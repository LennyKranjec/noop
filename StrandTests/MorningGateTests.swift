import XCTest
import StrandAnalytics
@testable import Strand

/// The morning flow's last page does not hand the day over until the night behind its figures is in.
/// What is pinned here:
///
///   * ALL THREE CONDITIONS, or no continue: the strap's backlog drained, the pass that scores the night
///     finished, and today's level actually resolved.
///   * "NO BACKLOG EVIDENCE" IS NOT "SYNCED". `historyPendingSync` is left false when the strap's range
///     answer never arrives — the WHOOP 5/MG case — so a connected strap also owes a sync that COMPLETED
///     after the flow opened. Without that clause the gate would pass instantly on exactly the strap it
///     is least able to see.
///   * IT NEVER BLOCKS FOREVER: after `timeoutSeconds` the wearer may go on, and the stage says so.
///   * READY BEATS TIMED OUT. A gate satisfied on the same tick it runs out must not tell the wearer
///     their figures may still move when they may not.
///   * THE TWO CLOCKS ARE DIFFERENT. Sync freshness is measured from the flow opening; the bounded wait
///     is measured from the last page appearing, so time spent writing a dream is not time on the clock.
final class MorningGateTests: XCTestCase {

    private let opened = Date(timeIntervalSince1970: 1_800_000_000)

    /// Everything in, nothing running — the state the gate exists to recognise.
    private func satisfied() -> MorningGateInputs {
        var i = MorningGateInputs()
        i.strapLinked = true
        i.offloadRunning = false
        i.backlogPending = false
        i.lastSyncedAt = opened.addingTimeInterval(20)
        i.analysisRunning = false
        i.analysisCompletedAt = opened.addingTimeInterval(35)
        i.levelResolved = true
        i.flowOpenedAt = opened
        i.waitingSince = opened.addingTimeInterval(40)
        i.now = opened.addingTimeInterval(50)
        return i
    }

    // MARK: - Ready

    func testEverythingInIsReady() {
        XCTAssertEqual(MorningGate.stage(satisfied()), .ready)
        XCTAssertTrue(MorningGateStage.ready.allowsContinue)
    }

    func testASettledNightThatWasNeverRecordedStillResolvesTheLevel() {
        // `levelResolved` covers the honest "no level for today" as well as a written one: no amount of
        // waiting turns a night that was never recorded into one that was.
        var i = satisfied()
        i.levelResolved = true
        XCTAssertEqual(MorningGate.stage(i), .ready)
    }

    // MARK: - Each condition on its own

    func testARunningOffloadHoldsTheGate() {
        var i = satisfied()
        i.offloadRunning = true
        XCTAssertEqual(MorningGate.stage(i), .syncing)
    }

    func testAnAdvertisedBacklogHoldsTheGateEvenWithoutAnOffload() {
        var i = satisfied()
        i.backlogPending = true
        XCTAssertEqual(MorningGate.stage(i), .syncing)
    }

    func testAConnectedStrapOwesASyncThatFinishedAfterTheFlowOpened() {
        // The 5/MG shape: no offload, no backlog flag — and nothing has actually come in since the flow
        // put its forced sync out. That is not "caught up".
        var i = satisfied()
        i.lastSyncedAt = opened.addingTimeInterval(-3_600)
        XCTAssertEqual(MorningGate.stage(i), .syncing)
        i.lastSyncedAt = nil
        XCTAssertEqual(MorningGate.stage(i), .syncing)
    }

    func testASyncFromJustBeforeTheFlowOpenedCountsAsThisMorningsSync() {
        // The flow's own sync request is rate-limited by the 90-second foreground floor, so when one has
        // only just run there is nothing left to start. Inside the grace it counts; outside it does not.
        var i = satisfied()
        i.lastSyncedAt = opened.addingTimeInterval(-MorningGate.syncFreshnessGrace + 1)
        i.analysisCompletedAt = i.now
        XCTAssertFalse(MorningGate.syncOutstanding(i))
        i.lastSyncedAt = opened.addingTimeInterval(-MorningGate.syncFreshnessGrace - 1)
        XCTAssertTrue(MorningGate.syncOutstanding(i))
    }

    func testAnUnlinkedStrapIsNotWaitedForAtAll() {
        // No strap connected: nothing is going to arrive, so the sync condition stands aside and the
        // other two decide. A cloud-only or import-only wearer must not be held for a strap they do not
        // have connected.
        var i = satisfied()
        i.strapLinked = false
        i.lastSyncedAt = nil
        i.analysisCompletedAt = opened.addingTimeInterval(-86_400)
        XCTAssertFalse(MorningGate.syncOutstanding(i))
        XCTAssertEqual(MorningGate.stage(i), .ready)
    }

    func testAPassOlderThanTheSyncHasNotSeenTheNight() {
        var i = satisfied()
        i.analysisCompletedAt = i.lastSyncedAt?.addingTimeInterval(-60)
        XCTAssertEqual(MorningGate.stage(i), .analysing)
    }

    func testAPassStillRunningHoldsTheGate() {
        var i = satisfied()
        i.analysisRunning = true
        XCTAssertEqual(MorningGate.stage(i), .analysing)
    }

    func testAPassThatHasNeverRunHoldsTheGate() {
        var i = satisfied()
        i.analysisCompletedAt = nil
        XCTAssertEqual(MorningGate.stage(i), .analysing)
    }

    func testAnUnresolvedLevelHoldsTheGateAfterEverythingElseIsIn() {
        var i = satisfied()
        i.levelResolved = false
        XCTAssertEqual(MorningGate.stage(i), .scoring)
        XCTAssertFalse(MorningGateStage.scoring.allowsContinue)
    }

    func testTheSyncIsNamedBeforeTheScoreWhenBothAreOutstanding() {
        var i = satisfied()
        i.offloadRunning = true
        i.levelResolved = false
        i.analysisCompletedAt = nil
        XCTAssertEqual(MorningGate.stage(i), .syncing)
    }

    // MARK: - The bounded wait

    func testTheGateOpensAfterTheBoundedWait() {
        var i = satisfied()
        i.levelResolved = false
        i.offloadRunning = true
        i.waitingSince = opened
        i.now = opened.addingTimeInterval(MorningGate.timeoutSeconds)
        XCTAssertEqual(MorningGate.stage(i), .timedOut)
        XCTAssertTrue(MorningGateStage.timedOut.allowsContinue)
    }

    func testJustUnderTheBoundedWaitStillHolds() {
        var i = satisfied()
        i.levelResolved = false
        i.waitingSince = opened
        i.now = opened.addingTimeInterval(MorningGate.timeoutSeconds - 1)
        XCTAssertEqual(MorningGate.stage(i), .scoring)
    }

    func testReadyBeatsTheTimeout() {
        var i = satisfied()
        i.waitingSince = opened
        i.now = opened.addingTimeInterval(MorningGate.timeoutSeconds * 10)
        XCTAssertEqual(MorningGate.stage(i), .ready)
    }

    func testTheWaitIsMeasuredFromTheLastPageNotFromTheFlowOpening() {
        // Five minutes writing a dream, ten seconds on the last page: the wearer is not already out of
        // time the moment the brief appears.
        var i = satisfied()
        i.levelResolved = false
        i.flowOpenedAt = opened
        i.waitingSince = opened.addingTimeInterval(300)
        i.now = opened.addingTimeInterval(310)
        XCTAssertEqual(MorningGate.waited(i), 10)
        XCTAssertEqual(MorningGate.stage(i), .scoring)
    }

    func testASyncFromDuringTheDreamPageStillCounts() {
        // ...and the sync that landed while they were writing is exactly the one being waited for, so
        // freshness is anchored to the flow opening rather than to their arrival.
        var i = satisfied()
        i.flowOpenedAt = opened
        i.lastSyncedAt = opened.addingTimeInterval(45)
        i.waitingSince = opened.addingTimeInterval(300)
        i.now = opened.addingTimeInterval(310)
        XCTAssertFalse(MorningGate.syncOutstanding(i))
        XCTAssertEqual(MorningGate.stage(i), .ready)
    }

    // MARK: - What it says

    func testAFailedSyncIsNamedRatherThanHiddenBehindASpinner() {
        var i = satisfied()
        i.offloadRunning = true
        i.syncError = "the strap went quiet mid-sync"
        let line = MorningGate.detail(i, stage: .syncing)
        XCTAssertTrue(line.contains("the strap went quiet mid-sync"), line)
        XCTAssertTrue(MorningGate.detail(i, stage: .timedOut).contains("the strap went quiet mid-sync"))
    }

    func testProgressIsAChunkCountAndNeverAPercentage() {
        var i = satisfied()
        i.offloadRunning = true
        i.syncChunks = 12
        let line = MorningGate.detail(i, stage: .syncing)
        XCTAssertTrue(line.contains("12 chunks"), line)
        XCTAssertFalse(line.contains("%"), line)
    }

    func testTheTimedOutLineSaysTheFiguresMayStillMove() {
        var i = satisfied()
        i.syncError = nil
        XCTAssertTrue(MorningGate.detail(i, stage: .timedOut).contains("may still"))
        XCTAssertFalse(MorningGate.headline(.timedOut).isEmpty)
        for stage in [MorningGateStage.syncing, .analysing, .scoring, .ready, .timedOut] {
            XCTAssertFalse(MorningGate.headline(stage).isEmpty)
            XCTAssertFalse(MorningGate.detail(i, stage: stage).isEmpty)
        }
    }
}

/// The gear picked in the morning is recorded PER DAY, and a day that was never asked has no gear.
@MainActor
final class QuestModeStoreTests: XCTestCase {

    private func store() -> QuestModeStore {
        let suite = UserDefaults(suiteName: "questmode.test.\(UUID().uuidString)")!
        return QuestModeStore(defaults: suite)
    }

    func testADayWithNoChoiceHasNoGear() {
        XCTAssertNil(store().mode(for: "2026-09-29"))
    }

    func testAChoiceIsKeptForItsOwnDayOnly() {
        let s = store()
        s.set(.relentless, for: "2026-09-29")
        XCTAssertEqual(s.mode(for: "2026-09-29"), .relentless)
        XCTAssertNil(s.mode(for: "2026-09-30"))
        XCTAssertNil(s.mode(for: "2026-09-28"))
    }

    func testRePickingReplacesTheDaysGear() {
        let s = store()
        s.set(.steady, for: "2026-09-29")
        s.set(.push, for: "2026-09-29")
        XCTAssertEqual(s.mode(for: "2026-09-29"), .push)
        XCTAssertEqual(s.byDay.count, 1)
    }

    func testAChoiceSurvivesARelaunch() {
        let suite = UserDefaults(suiteName: "questmode.test.\(UUID().uuidString)")!
        QuestModeStore(defaults: suite).set(.push, for: "2026-09-29")
        XCTAssertEqual(QuestModeStore(defaults: suite).mode(for: "2026-09-29"), .push)
    }

    func testOnlyTheLastFortnightOfChoicesIsKept() {
        let s = store()
        for day in 1...(QuestModeStore.kept + 5) {
            s.set(.steady, for: String(format: "2026-09-%02d", day))
        }
        XCTAssertEqual(s.byDay.count, QuestModeStore.kept)
        // The OLDEST fall off; the newest are what a screen ever reads.
        XCTAssertNil(s.mode(for: "2026-09-01"))
        XCTAssertEqual(s.mode(for: String(format: "2026-09-%02d", QuestModeStore.kept + 5)), .steady)
    }

    func testAnUnknownStoredGearIsDroppedRatherThanFailingTheRead() {
        let suite = UserDefaults(suiteName: "questmode.test.\(UUID().uuidString)")!
        suite.set(["2026-09-29": "FROM_A_NEWER_BUILD", "2026-09-28": "PUSH"], forKey: QuestModeStore.key)
        let s = QuestModeStore(defaults: suite)
        XCTAssertNil(s.mode(for: "2026-09-29"))
        XCTAssertEqual(s.mode(for: "2026-09-28"), .push)
    }
}
