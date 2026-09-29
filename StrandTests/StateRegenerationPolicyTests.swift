import XCTest
@testable import Strand

/// WHY THIS FILE EXISTS. The STATE tile's text was written once a day (the mission) or once per set of
/// today's workouts (the suggestions), so an instruction written at 07:00 was still on screen at 19:00 after
/// a hard session had made it wrong, and the refresh button was the only way out. `StateRegenerationPolicy`
/// is the decision that fixes it, and every one of these is a way that decision can go wrong: firing in the
/// background (battery, provider quota and, historically, a starved BLE drain), firing three times for one
/// sync, firing on every live-Effort tick, or refusing to fire at all.
final class StateRegenerationPolicyTests: XCTestCase {

    private let day = "2026-09-29"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func inputs(day: String? = nil, workouts: Int = 1, refresh: Int = 1,
                        choices: String = "all", effortNow: Double? = 20, effortTarget: Double? = 60,
                        charge: Double? = 70, stress: Double? = 1.0,
                        mindful: Double? = 0) -> StateRegenerationInputs {
        StateRegenerationInputs(dayKey: day ?? self.day, workoutsSeq: workouts, refreshSeq: refresh,
                                choicesSignature: choices, effortNow: effortNow,
                                effortTarget: effortTarget, charge: charge, stress: stress,
                                mindfulMinutesToday: mindful)
    }

    // MARK: - Background suppression

    /// THE ONE THAT MATTERS MOST. A background request spends the wearer's battery and their provider quota
    /// to rewrite text nobody is looking at, and this repo's own history says a background generation is how
    /// you starve a BLE drain. It is checked before anything else, so not even a rolled-over day gets through.
    func testNothingIsAskedWhileTheAppIsInTheBackground() {
        let decision = StateRegenerationPolicy.decide(
            previous: inputs(day: "2026-09-28"), generatedAt: now.addingTimeInterval(-40_000),
            current: inputs(), lastAutoAttempt: nil, foreground: false, now: now)
        XCTAssertEqual(decision, .skip(.background))
    }

    // MARK: - Which signal triggers

    func testNoStoredTextAtAllIsAFirstRun() {
        XCTAssertEqual(
            StateRegenerationPolicy.decide(previous: nil, generatedAt: nil, current: inputs(),
                                           lastAutoAttempt: nil, foreground: true, now: now),
            .regenerate(.firstRun))
    }

    func testARolledOverDayRegenerates() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(day: "2026-09-28"), generatedAt: now,
                                           current: inputs(), now: now),
            .dayRolled)
    }

    /// A saved or deleted workout bumps `workoutsSeq`, which is the signal the whole "a workout logged 20
    /// minutes ago must be visible to the very next refresh" requirement hangs on.
    func testASavedWorkoutRegenerates() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(workouts: 4), generatedAt: now,
                                           current: inputs(workouts: 5), now: now),
            .workoutsChanged)
    }

    func testTickingADifferentWorkoutSelectionRegenerates() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(choices: "all"), generatedAt: now,
                                           current: inputs(choices: "3f2a"), now: now),
            .selectionChanged)
    }

    /// Crossing the target is its own cause, ahead of the plain effort step: the advice changes from "here
    /// is what is left" to "you are done", which is the sentence the wearer asked for.
    func testCrossingTheEffortTargetIsItsOwnCause() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(effortNow: 40, effortTarget: 60),
                                           generatedAt: now,
                                           current: inputs(effortNow: 61, effortTarget: 60), now: now),
            .targetReached)
    }

    func testEffortCreepingUpByLessThanAStepChangesNothing() {
        XCTAssertNil(
            StateRegenerationPolicy.reason(previous: inputs(effortNow: 20), generatedAt: now,
                                           current: inputs(effortNow: 24), now: now),
            "the live Effort score creeps up every few seconds; a request per tick is the bug")
    }

    func testEffortMovingByAWholeStepRegenerates() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(effortNow: 20), generatedAt: now,
                                           current: inputs(effortNow: 20 + StateRegenerationPolicy.effortStep),
                                           now: now),
            .effortMoved)
    }

    func testChargeAndStressEachHaveTheirOwnStep() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(charge: 70), generatedAt: now,
                                           current: inputs(charge: 61), now: now),
            .chargeMoved)
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(stress: 1.0), generatedAt: now,
                                           current: inputs(stress: 2.0), now: now),
            .stressMoved)
    }

    func testALoggedMeditationRegenerates() {
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(mindful: 0), generatedAt: now,
                                           current: inputs(mindful: 20), now: now),
            .mindfulLogged)
    }

    /// The plain staleness bound: with nothing else moving, text older than the bound is rewritten anyway,
    /// which is what stops a morning instruction standing all evening.
    func testTextOlderThanTheStalenessBoundIsRewritten() {
        let old = now.addingTimeInterval(-StateRegenerationPolicy.staleAfter - 1)
        XCTAssertEqual(
            StateRegenerationPolicy.reason(previous: inputs(), generatedAt: old, current: inputs(), now: now),
            .stale)
        let fresh = now.addingTimeInterval(-60)
        XCTAssertNil(
            StateRegenerationPolicy.reason(previous: inputs(), generatedAt: fresh, current: inputs(), now: now))
    }

    func testNothingMovingAsksNothing() {
        XCTAssertEqual(
            StateRegenerationPolicy.decide(previous: inputs(), generatedAt: now.addingTimeInterval(-60),
                                           current: inputs(), lastAutoAttempt: nil, foreground: true,
                                           now: now),
            .skip(.unchanged))
    }

    // MARK: - Coalescing

    /// A sync bumps `refreshSeq`, `workoutsSeq` and the day's figures inside the same second. Without a
    /// spacing rule that is three requests for one event; with it, the first one runs and the rest come back
    /// as `.wait`, which the controller turns into ONE scheduled re-evaluation.
    func testSeveralSignalsInsideTheSpacingWindowCoalesceIntoAWait() {
        let justRan = now.addingTimeInterval(-10)
        let decision = StateRegenerationPolicy.decide(
            previous: inputs(workouts: 4), generatedAt: now.addingTimeInterval(-600),
            current: inputs(workouts: 5), lastAutoAttempt: justRan, foreground: true, now: now)
        guard case .wait(let seconds) = decision else {
            return XCTFail("expected a wait, got \(decision)")
        }
        XCTAssertEqual(seconds, StateRegenerationPolicy.minAutoInterval - 10, accuracy: 0.001)
    }

    func testTheSpacingExpiresAndTheChangeThenRuns() {
        let longAgo = now.addingTimeInterval(-StateRegenerationPolicy.minAutoInterval - 1)
        XCTAssertEqual(
            StateRegenerationPolicy.decide(previous: inputs(workouts: 4),
                                           generatedAt: now.addingTimeInterval(-600),
                                           current: inputs(workouts: 5), lastAutoAttempt: longAgo,
                                           foreground: true, now: now),
            .regenerate(.workoutsChanged))
    }

    /// A new day is NEVER coalesced: there is no text for today at all, and making the wearer wait ninety
    /// seconds for the first thing they see in the morning is not a saving.
    func testANewDayIsNotHeldBackByTheSpacing() {
        XCTAssertEqual(
            StateRegenerationPolicy.decide(previous: inputs(day: "2026-09-28"), generatedAt: now,
                                           current: inputs(), lastAutoAttempt: now.addingTimeInterval(-1),
                                           foreground: true, now: now),
            .regenerate(.dayRolled))
    }

    /// THE SEPARATION THE BRIEF ASKS FOR. The automatic spacing and the manual button's throttle are two
    /// different clocks: a signal ninety seconds ago must not refuse a tap, and a tap must not refuse a
    /// signal. `RefreshThrottle` is the button's; the policy never sees it.
    func testTheManualThrottleIsAWhollySeparateClock() {
        var throttle = RefreshThrottle(minInterval: 20)
        XCTAssertTrue(throttle.tryStart(at: now), "a tap is allowed")
        XCTAssertFalse(throttle.allows(at: now.addingTimeInterval(5)), "and then held for its own 20 s")
        // The automatic side is unaffected by that tap: only `lastAutoAttempt` spaces it.
        XCTAssertEqual(
            StateRegenerationPolicy.decide(previous: inputs(workouts: 4),
                                           generatedAt: now.addingTimeInterval(-600),
                                           current: inputs(workouts: 5), lastAutoAttempt: nil,
                                           foreground: true, now: now.addingTimeInterval(5)),
            .regenerate(.workoutsChanged))
        // And the reverse: an automatic run a second ago does not stop the button.
        // Bound to a var: `tryStart` is mutating, so it cannot be called on a temporary.
        var fresh = RefreshThrottle(minInterval: 20)
        XCTAssertTrue(fresh.tryStart(at: now.addingTimeInterval(1)))
    }

    // MARK: - Honest comparisons

    /// A figure APPEARING counts (the text was written without it); a figure VANISHING does not — that is a
    /// read that has not landed yet, and regenerating on it would rewrite good text from a worse position.
    func testAFigureAppearingCountsAndAFigureVanishingDoesNot() {
        XCTAssertTrue(StateRegenerationPolicy.moved(nil, 40, by: 8))
        XCTAssertFalse(StateRegenerationPolicy.moved(40, nil, by: 8))
        XCTAssertFalse(StateRegenerationPolicy.moved(nil, nil, by: 8))
    }

    /// "Not measured" is never a crossing in either direction: an unmeasured target cannot become met, and a
    /// met target that loses its figure has not become unmet.
    func testAnUnmeasuredTargetIsNeverACrossing() {
        XCTAssertNil(
            StateRegenerationPolicy.reason(previous: inputs(effortNow: nil, effortTarget: nil),
                                           generatedAt: now,
                                           current: inputs(effortNow: nil, effortTarget: nil), now: now))
        // Losing the target figure must not read as "no longer done".
        let after = StateRegenerationPolicy.reason(previous: inputs(effortNow: 70, effortTarget: 60),
                                                   generatedAt: now,
                                                   current: inputs(effortNow: 70, effortTarget: nil),
                                                   now: now)
        XCTAssertNotEqual(after, .targetReached)
    }
}
