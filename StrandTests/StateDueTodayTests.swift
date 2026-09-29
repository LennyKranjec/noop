import XCTest
import StrandAnalytics
@testable import Strand

/// The STATE tile's answer to the question the wearer actually asks — "what is still due today?" — in the
/// half of it that runs with no model: the deterministic sentence, the completion matcher that ticks off a
/// session already done, and the level-aimed next step.
///
/// THE HONESTY RULE IS THE POINT OF MOST OF THESE. "You are done for today" may only be said when the Effort
/// target is KNOWN and KNOWN to be met; a level part with no data may never be called low; and a suggestion
/// is only marked done when a real session of the right kind and a real duration closed it.
final class StateDueTodayTests: XCTestCase {

    private func figures(effortNow: Double? = nil, effortTarget: Double? = nil,
                         gaps: [StateLevelGap] = [], missing: [String] = [],
                         stepPenalty: Double? = nil) -> StateTrainingFigures {
        var f = StateTrainingFigures()
        f.effortNow = effortNow
        f.effortTarget = effortTarget
        f.levelGaps = gaps
        f.levelPartsWithoutData = missing
        f.levelStepPenalty = stepPenalty
        return f
    }

    private func suggestion(_ sport: String, minutes: Int, zone: Int = 2, window: String? = "17:00–18:00",
                            done: Bool = false, label: String? = nil) -> WorkoutSuggestion {
        var s = WorkoutSuggestion(sport: sport, minutes: minutes, zone: zone, effort: nil,
                                  window: window, why: "because", label: label)
        s.done = done
        return s
    }

    private func fact(_ sport: String, minutes: Double?, hoursAgo: Double = 2) -> StateWorkoutFact {
        let end = Date().addingTimeInterval(-hoursAgo * 3600)
        return StateWorkoutFact(sport: sport, start: end.addingTimeInterval(-(minutes ?? 30) * 60), end: end,
                                durationMin: minutes, avgHr: nil, maxHr: nil, effort: nil, zoneMinutes: nil)
    }

    // MARK: - The target's three states

    /// THE ONE THE WEARER ASKED FOR. Target met, nothing outstanding: the answer is "you are done", in words.
    func testTargetMetAndNothingLeftSaysYouAreDone() {
        let s = StateDueToday.sentence(figures: figures(effortNow: 62, effortTarget: 60),
                                       stillDue: [], hour: 15)
        XCTAssertTrue(s.contains("target is met"), s)
        XCTAssertTrue(s.lowercased().contains("done for today"), s)
    }

    /// Target met but calm blocks remain: still "no more load", never "you are short".
    func testTargetMetWithCalmBlocksLeftSaysNoMoreLoad() {
        let s = StateDueToday.sentence(figures: figures(effortNow: 62, effortTarget: 60),
                                       stillDue: [suggestion("Meditation", minutes: 10, zone: 1)], hour: 18)
        XCTAssertTrue(s.contains("target is met"), s)
        XCTAssertTrue(s.contains("no more load"), s)
        XCTAssertFalse(s.lowercased().contains("still to go"), s)
    }

    /// A day whose three suggestions are all DONE reads as done, not as three things outstanding — the done
    /// rows are filtered out of "what is left" even though they stay on screen.
    func testDoneRowsDoNotCountAsOutstanding() {
        let s = StateDueToday.sentence(figures: figures(effortNow: 62, effortTarget: 60),
                                       stillDue: [suggestion("Running", minutes: 40, done: true)], hour: 15)
        XCTAssertTrue(s.lowercased().contains("done for today"), s)
    }

    func testTargetNotMetNamesWhatIsLeftAndTheNextSession() {
        let s = StateDueToday.sentence(figures: figures(effortNow: 20, effortTarget: 60),
                                       stillDue: [suggestion("Running", minutes: 40)], hour: 14)
        XCTAssertTrue(s.contains("40 Effort still to go"), s)
        XCTAssertTrue(s.contains("Running"), s)
    }

    /// THE ABSTENTION. With no target there is nothing to have reached, and the sentence says exactly that —
    /// it must not silently read as "done" and it must not read as "train more" either.
    func testAnUnmeasuredTargetIsNeverCalledDoneAndNeverCalledShort() {
        let s = StateDueToday.sentence(figures: figures(effortNow: nil, effortTarget: nil),
                                       stillDue: [], hour: 14)
        XCTAssertTrue(s.contains("isn't measured"), s)
        XCTAssertFalse(s.lowercased().contains("done for today"), s)
        XCTAssertFalse(s.contains("still to go"), s)
    }

    /// An Effort figure with no target is still not a target: `effortTargetMet` abstains on either half.
    func testEffortWithoutATargetStillAbstains() {
        XCTAssertNil(figures(effortNow: 55, effortTarget: nil).effortTargetMet)
        XCTAssertNil(figures(effortNow: nil, effortTarget: 60).effortTargetMet)
        XCTAssertEqual(figures(effortNow: 58, effortTarget: 60).effortTargetMet, true,
                       "within the slack counts as reached")
        XCTAssertEqual(figures(effortNow: 40, effortTarget: 60).effortTargetMet, false)
    }

    /// Late in the day, closing the gap is not the advice: the sentence says so rather than pushing a
    /// session into the hour before bed.
    func testLateInTheDayItSaysNotToChaseTheTarget() {
        let s = StateDueToday.sentence(figures: figures(effortNow: 20, effortTarget: 60),
                                       stillDue: [suggestion("Running", minutes: 40)], hour: 22)
        XCTAssertTrue(s.contains("It is late"), s)
    }

    // MARK: - The level lever

    /// The advice names the part AND what to do about it, per part — not a generic compliment.
    func testEachLevelPartGetsItsOwnConcreteAction() {
        for (part, needle) in [("sleep", "bed earlier"), ("heart", "calm hours"), ("lungs", "Zone 2"),
                               ("muscle", "lifting session"), ("focus", "meditation minutes")] {
            let gap = StateLevelGap(part: part, headroom: 3.4, score: 42)
            let line = StateDueToday.levelAction(for: gap, hour: 14)
            XCTAssertNotNil(line, part)
            XCTAssertTrue(line?.contains(needle) == true, "\(part): \(line ?? "nil")")
            XCTAssertTrue(line?.contains("+3.4") == true, "the points are named: \(line ?? "nil")")
        }
    }

    /// Late in the day a lifting session is put in TOMORROW, not in the hour before bed.
    func testMuscleLateInTheDayPointsAtTomorrow() {
        let gap = StateLevelGap(part: "muscle", headroom: 2.0, score: 40)
        XCTAssertTrue(StateDueToday.levelAction(for: gap, hour: 22)?.contains("tomorrow") == true)
    }

    /// An unknown part name produces NOTHING rather than a generic sentence: a part this code does not
    /// recognise is a part it has nothing defensible to say about.
    func testAnUnknownPartProducesNoAdvice() {
        XCTAssertNil(StateDueToday.levelAction(for: StateLevelGap(part: "vibes", headroom: 9, score: 1),
                                               hour: 12))
    }

    /// The step multiplier is only mentioned when it is actually costing something, and it is rounded to
    /// whole per cent — the multiplier itself is not a figure anyone can act on.
    func testTheStepLeverOnlyAppearsWhenStepsAreCostingPoints() {
        XCTAssertNil(StateDueToday.stepAction(penalty: 1.0))
        XCTAssertNil(StateDueToday.stepAction(penalty: nil))
        XCTAssertNil(StateDueToday.stepAction(penalty: 0.999), "a rounding artefact is not a lever")
        let line = StateDueToday.stepAction(penalty: 0.90)
        XCTAssertTrue(line?.contains("10%") == true, line ?? "nil")
    }

    /// THE FABRICATION RULE. A part the level ABSTAINED on never reaches the gap list, so no sentence here
    /// can call it low — and the grounding block names it as unmeasured instead.
    func testAnUnmeasuredLevelPartIsNamedAsUnmeasuredNeverAsLow() {
        let f = figures(effortNow: 62, effortTarget: 60, gaps: [], missing: ["lungs", "muscle"])
        let block = StateTrainingContext.levelLines(f)
        XCTAssertTrue(block.contains("NOT MEASURED, so NOT weak"), block)
        XCTAssertTrue(block.contains("lungs, muscle"), block)
        XCTAssertFalse(block.lowercased().contains("lungs: score"), block)
    }

    func testTheGapBlockNamesTheDayTheLevelWasFrozenFor() {
        var f = figures(gaps: [StateLevelGap(part: "sleep", headroom: 4.1, score: 38)])
        f.levelDayKey = "2026-09-29"
        let block = StateTrainingContext.levelLines(f)
        XCTAssertTrue(block.contains("level frozen for 2026-09-29"), block)
        XCTAssertTrue(block.contains("sleep: score 38"), block)
    }

    // MARK: - Reading the coach's own answer

    /// The sentence is read out of the reply alongside the rows.
    func testThePlanCarriesTheCoachsOwnLeftTodaySentence() throws {
        let raw = #"{"left_today":"Nothing more — you hit the target at lunch.","workouts":[]}"#
        let plan = try XCTUnwrap(WorkoutSuggestionParser.parsePlan(raw))
        XCTAssertEqual(plan.leftToday, "Nothing more — you hit the target at lunch.")
        XCTAssertTrue(plan.workouts.isEmpty)
    }

    /// AN EMPTY LIST WITH A SENTENCE IS A VALID ANSWER — it is how "you are done" arrives. `parse`, which
    /// only wants rows, still says nil for it, so no caller that expects rows is surprised.
    func testAnEmptyListWithASentenceIsAPlanButNotAListOfRows() {
        let raw = #"{"left_today":"You are done for today.","workouts":[]}"#
        XCTAssertNotNil(WorkoutSuggestionParser.parsePlan(raw))
        XCTAssertNil(WorkoutSuggestionParser.parse(raw))
    }

    /// An empty list with NO sentence is a reply the model got wrong, not a finished day.
    func testAnEmptyListWithNoSentenceIsStillARejectedReply() {
        XCTAssertNil(WorkoutSuggestionParser.parsePlan(#"{"workouts":[]}"#))
    }

    /// The alternative key names a model reaches for are read too, and a reply with rows but no sentence
    /// still parses (the deterministic sentence then stands in).
    func testTheAlternativeKeyNamesAreRead() throws {
        let raw = #"{"remaining":"One easy walk left.","workouts":[{"sport":"Walking","minutes":20,"zone":1,"why":"Steps."}]}"#
        let plan = try XCTUnwrap(WorkoutSuggestionParser.parsePlan(raw))
        XCTAssertEqual(plan.leftToday, "One easy walk left.")
        XCTAssertEqual(plan.workouts.count, 1)
        let noSentence = try XCTUnwrap(WorkoutSuggestionParser.parsePlan(
            #"{"workouts":[{"sport":"Walking","minutes":20,"zone":1,"why":"Steps."}]}"#))
        XCTAssertNil(noSentence.leftToday)
        XCTAssertEqual(noSentence.workouts.count, 1)
    }

    /// A BARE suggestion object that happens to carry a summary-ish key is still one suggestion, not an
    /// empty plan: the "sentence only" shortcut requires the absence of a sport.
    func testABareSuggestionObjectIsNotMistakenForASentenceOnlyReply() throws {
        let raw = #"{"summary":"Go run","sport":"Running","minutes":30,"zone":2,"why":"Base."}"#
        let plan = try XCTUnwrap(WorkoutSuggestionParser.parsePlan(raw))
        XCTAssertEqual(plan.workouts.count, 1)
        XCTAssertEqual(plan.workouts[0].sport, "Running")
    }

    // MARK: - What the model is asked

    /// The prompt has to ASK for the sentence, or the field is never filled. And it has to permit an empty
    /// list, or the model invents a session to fill it.
    func testThePromptAsksForTheSentenceAndPermitsAnEmptyList() {
        let p = WorkoutSuggestionWriter.systemPrompt(grounding: "…")
        XCTAssertTrue(p.contains("left_today"), "the field is named")
        XCTAssertTrue(p.contains("WHAT IS STILL DUE TODAY"), p.prefix(200).description)
        XCTAssertTrue(p.contains("Adding nothing at all is a correct answer"))
        XCTAssertTrue(p.contains("may be an empty"))
        XCTAssertTrue(p.contains("NOT MEASURED"), "the abstention is asked for too")
        XCTAssertTrue(p.contains("already completed today is DONE"))
        XCTAssertTrue(p.contains("waking time"))
    }

    /// And it has to aim at the LEVEL rather than at a compliment — with the abstention rule attached.
    func testThePromptAimsAtTheLevelAndForbidsCallingAnUnmeasuredPartLow() {
        let o = WorkoutSuggestionWriter.levelObjective
        XCTAssertTrue(o.contains("AIM AT THE LEVEL"), o)
        for part in ["sleep", "heart", "lungs", "muscle", "focus"] {
            XCTAssertTrue(o.contains(part + " short"), "\(part) has no named action: \(o)")
        }
        XCTAssertTrue(o.contains("Never call it low"), o)
        // The mission is written under the same objective, so the two cannot drift apart.
        XCTAssertTrue(StateDayPlanContext.missionObjective(choices: .all).contains("AIM AT THE LEVEL"))
    }

    // MARK: - Ticking off what is already done

    /// A run of 40 min closes a suggested 40 min run — and the clock window is deliberately NOT required,
    /// because people train when they can and a session moved by two hours is the same session.
    func testASessionOfTheRightKindAndLengthClosesItsSuggestion() {
        let s = suggestion("Running", minutes: 40, window: "17:00–18:00")
        XCTAssertTrue(StateSuggestionCompletion.satisfied(s, by: [fact("Running", minutes: 42, hoursAgo: 6)]))
    }

    /// Half the suggested duration is enough — the wearer did the session, it was just shorter.
    func testHalfTheSuggestedDurationIsEnough() {
        let s = suggestion("Cycling", minutes: 60)
        XCTAssertTrue(StateSuggestionCompletion.satisfied(s, by: [fact("Cycling", minutes: 31)]))
        XCTAssertFalse(StateSuggestionCompletion.satisfied(s, by: [fact("Cycling", minutes: 12)]),
                       "twelve minutes of a sixty-minute session is not that session")
    }

    /// A recovery block is short enough that a proportional rule is noise; five real minutes close it.
    func testARecoveryBlockIsClosedByAFewRealMinutes() {
        let s = suggestion("Meditation", minutes: 20, zone: 1, label: StateWorkoutChoices.nsdrKey)
        XCTAssertTrue(StateSuggestionCompletion.satisfied(s, by: [fact("Meditation", minutes: 6)]),
                      "an NSDR block is recorded as a Meditation session, which is what closes it")
        XCTAssertFalse(StateSuggestionCompletion.satisfied(s, by: [fact("Meditation", minutes: 2)]))
    }

    /// A DIFFERENT sport does not close it, whatever its length.
    func testADifferentSportDoesNotCloseIt() {
        let s = suggestion("Running", minutes: 40)
        XCTAssertFalse(StateSuggestionCompletion.satisfied(s, by: [fact("Cycling", minutes: 90)]))
    }

    /// A session the store could not TIME says nothing about whether the block was done, so it does not
    /// close it. Treating an absent duration as "long enough" is the fabrication this avoids.
    func testASessionWithNoDurationDoesNotCloseAnything() {
        let s = suggestion("Running", minutes: 40)
        XCTAssertFalse(StateSuggestionCompletion.satisfied(s, by: [fact("Running", minutes: nil)]))
    }

    /// Marked DONE, not removed: the row stays on the list with `done` set, because a suggestion that
    /// silently disappears reads as the tile forgetting what the wearer just did.
    func testACompletedSuggestionIsTickedOffRatherThanDropped() {
        let running = suggestion("Running", minutes: 40)
        var edits = StateWorkoutEdits(dayKey: "2026-09-29")
        edits.completed = StateSuggestionCompletion.completedKeys(in: [running],
                                                                 today: [fact("Running", minutes: 45)])
        let shown = edits.applied(to: [running])
        XCTAssertEqual(shown.count, 1, "still on the list")
        XCTAssertTrue(shown[0].done)
    }

    /// Edits written before `completed` existed must still decode — the same rule the pins and removals
    /// already live by, because losing them takes the whole day's edits down.
    func testEditsStoredBeforeTheCompletedSetStillDecode() throws {
        let legacy = #"{"dayKey":"2026-09-29","pinned":[],"dismissed":["running@1020"]}"#
        let decoded = try JSONDecoder().decode(StateWorkoutEdits.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.dayKey, "2026-09-29")
        XCTAssertEqual(decoded.dismissed, ["running@1020"])
        XCTAssertTrue(decoded.completed.isEmpty)
    }

    /// And a stored suggestion written before `done` existed, for the same reason.
    func testASuggestionStoredBeforeTheDoneFlagStillDecodes() throws {
        let legacy = #"{"sport":"Running","minutes":40,"zone":2,"why":"Base.","byUser":false}"#
        let decoded = try JSONDecoder().decode(WorkoutSuggestion.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.sport, "Running")
        XCTAssertFalse(decoded.done)
    }
}
