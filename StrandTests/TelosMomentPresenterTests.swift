import XCTest
import StrandDesign
@testable import Strand

/// The one full-screen moment presenter (DESIGN_V2 decisions 7 + 17): priority order with arrival order on a
/// tie, one at a time, dedupe by id, held (not dropped) while a workout / the morning flow / a sheet is up,
/// a wearer-requested moment only held for a sheet, the strap cue requested once per moment, withdraw and
/// primary / secondary / close all run the source's close hook.
@MainActor
final class TelosMomentPresenterTests: XCTestCase {

    private func moment(_ id: String, _ kind: TelosMoment.Kind) -> TelosMoment {
        TelosMoment(id: id, kind: kind, overline: "O", headline: "H")
    }

    func testHigherPriorityShowsFirstAndTiesKeepArrivalOrder() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        p.setSuppression(.init(workout: false, morningFlow: false, covered: true))
        p.enqueue(moment("a", .coachMessage))
        p.enqueue(moment("b", .questCompleted))
        p.enqueue(moment("c", .penalty))
        p.enqueue(moment("d", .debtCleared))   // same priority as questCompleted, arrived later
        XCTAssertNil(p.current, "held while covered")
        p.setSuppression(.none)
        XCTAssertEqual(p.current?.id, "c")
        p.dismissCurrent()
        XCTAssertEqual(p.current?.id, "b")
        p.dismissCurrent()
        XCTAssertEqual(p.current?.id, "d")
        p.dismissCurrent()
        XCTAssertEqual(p.current?.id, "a")
        p.dismissCurrent()
        XCTAssertNil(p.current)
    }

    func testSameIdIsShownOnce() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        p.enqueue(moment("x", .goalCompleted))
        p.dismissCurrent()
        p.enqueue(moment("x", .goalCompleted))
        XCTAssertNil(p.current)
    }

    func testAMomentOnScreenIsPutBackWhenASheetOpensAndReturnsAfter() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        p.enqueue(moment("x", .levelSettle))
        XCTAssertEqual(p.current?.id, "x")
        p.setSuppression(.init(workout: false, morningFlow: false, covered: true))
        XCTAssertNil(p.current)
        p.setSuppression(.none)
        XCTAssertEqual(p.current?.id, "x")
    }

    func testWearerRequestedIsHeldOnlyForASheet() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        p.setSuppression(.init(workout: true, morningFlow: false, covered: false))
        p.enqueue(moment("auto", .optimumReached))
        p.enqueue(moment("asked", .stressDiagnostic), requestedByWearer: true)
        XCTAssertEqual(p.current?.id, "asked")
        p.dismissCurrent()
        XCTAssertNil(p.current, "the automatic one waits for the workout to end")
        p.setSuppression(.none)
        XCTAssertEqual(p.current?.id, "auto")
    }

    func testStrapCueIsRequestedOncePerMomentAndOnlyForRewardsAndPenalties() {
        var cues: [(TelosStrapCue, String)] = []
        let p = TelosMomentPresenter(strapCue: { cues.append(($0, $1)) }, gap: 0)
        p.enqueue(moment("goal", .goalCompleted))
        // Put back and shown again: still one cue.
        p.setSuppression(.init(workout: false, morningFlow: false, covered: true))
        p.setSuppression(.none)
        p.dismissCurrent()
        p.enqueue(moment("coach", .coachMessage))
        p.dismissCurrent()
        p.enqueue(moment("pen", .penalty))
        XCTAssertEqual(cues.map { $0.1 }, ["goal", "pen"])
        XCTAssertEqual(cues.map { $0.0 }, [TelosStrapCue.reward, TelosStrapCue.penalty])
    }

    func testPrimarySecondaryCloseAndWithdrawRunTheHooks() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        var log: [String] = []
        p.enqueue(moment("one", .goalCompleted), onPrimary: { log.append("primary") }, onClose: { log.append("close1") })
        XCTAssertTrue(p.currentHasPrimary)
        p.takePrimary()
        p.enqueue(moment("two", .stressDiagnostic), onClose: { log.append("close2") },
                  secondary: TelosMomentSecondaryAction("IGNORE") { log.append("secondary") })
        XCTAssertEqual(p.currentSecondaryTitle, "IGNORE")
        XCTAssertFalse(p.currentHasPrimary)
        p.takeSecondary()
        p.enqueue(moment("three", .optimumReached), onClose: { log.append("close3") })
        p.withdraw(id: "three")
        XCTAssertNil(p.current)
        XCTAssertEqual(log, ["primary", "close1", "secondary", "close2", "close3"])
    }

    func testRouteRequestIsConsumedOnce() {
        let p = TelosMomentPresenter(strapCue: { _, _ in }, gap: 0)
        p.requestRoute(.goals)
        XCTAssertEqual(p.requestedRoute, .goals)
        p.consumeRoute()
        XCTAssertNil(p.requestedRoute)
    }

    func testRadarScaleOnlyShrinksAndNeverClips() {
        XCTAssertEqual(levelRadarScaleDivisor([0.4, 1.0, 1.2]), 1, accuracy: 1e-12)
        XCTAssertEqual(levelRadarScaleDivisor([2.5]), 2.0, accuracy: 1e-12, "250 fits at the plate's reach")
        XCTAssertEqual(levelRadarScaleDivisor([]), 1, accuracy: 1e-12)
        XCTAssertEqual(levelRadarScaleDivisor([.nan, .infinity, 0.5]), 1, accuracy: 1e-12)
    }
}
