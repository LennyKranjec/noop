import XCTest
import StrandAnalytics
@testable import Strand

/// The State tile's own, lean grounding — and the ONE merged request that replaced its two parallel ones.
///
/// THE BUG THESE PIN. The tile reused the chat's whole context (`buildFullContext()`, measured at about 5,200
/// estimated tokens) and sent it TWICE at once, for the mission and for the workout list, against a Groq
/// on-demand allowance of 8,000 tokens PER MINUTE. One half was refused with a 413: "Limit 8000, Requested
/// 8646". The fix is a grounding built from what the tile's prompt actually names, and one request instead of
/// two — so the thing worth testing is that the lean grounding still contains every figure the prompt refers
/// to, and that both halves still come back out of one answer.
final class StateGroundingTests: XCTestCase {

    private let cal = Calendar.current

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    private func dayKey(_ d: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func fact(_ sport: String, hoursBefore: Double, from: Date, effort: Double? = nil) -> StateWorkoutFact {
        let start = from.addingTimeInterval(-hoursBefore * 3600)
        return StateWorkoutFact(sport: sport, start: start, end: start.addingTimeInterval(2_400),
                               durationMin: 40, avgHr: 141, maxHr: 168, effort: effort, zoneMinutes: nil)
    }

    private func figures() -> StateTrainingFigures {
        var f = StateTrainingFigures(charge: 71, effortNow: 34, effortTarget: 62, sleepDebtMin: 90,
                                     stress: 1.2, hrvDeltaPct: -12, rhrDeltaBpm: 3)
        f.mindfulMinutesToday = 10
        f.levelGaps = [StateLevelGap(part: "lungs", headroom: 4.2, score: 41)]
        f.levelPartsWithoutData = ["muscle"]
        return f
    }

    /// The grounding as the tile builds it, without the controller (which needs a store).
    private func grounding(budget: Int, reserved: Int, now: Date) -> CoachContextFit {
        let schedule = RoomClimateSchedule.fallback
        let recent = (1...14).map { fact("Cycling", hoursBefore: Double($0) * 24, from: now, effort: 65) }
        func training(_ limit: Int) -> String {
            StateTrainingContext.block(
                figures: figures(),
                zones: [HRZoneBPMRange(zone: 1, lower: 120, upper: 133),
                        HRZoneBPMRange(zone: 2, lower: 134, upper: 147)],
                today: [fact("Running", hoursBefore: 4, from: now, effort: 41)],
                recent: recent, now: now, bedtimeMinute: schedule.bedtimeMinute,
                recentLimit: limit, calendar: cal)
        }
        let blocks = StateGrounding.blocks(
            dayFrame: CoachDayFrame.compactBlock(now: now),
            training: training(6),
            trainingShort: training(0),
            schedule: StateDayPlanContext.block(now: now, schedule: schedule, calendar: cal),
            history: "RECENT DAYS (newest first) — charge(0-100)…",
            stress: StateGrounding.stressBlock(day: dayKey(now), now: 1.8,
                                               hourly: (8...18).map { (hour: $0, level: 1.0) },
                                               stressIndex: 140),
            routines: "THEIR ROUTINES — hard constraints…",
            memory: "YOUR MEMORY FILE — notes you wrote…",
            closing: CoachDayFrame.closingRule,
            // The longest guidance line the week plan writes, as the controller wraps it.
            weekPlan: "WEEK PLAN, TODAY (\(dayKey(now))): "
                + "Move today's hard session — HRV below your range.")
        return CoachContextBudget.fit(blocks, budget: budget, reserved: reserved)
    }

    /// The week plan's line rides the lean grounding, next to the training state it bounds.
    func testTheWeekPlanGuidanceRidesTheLeanGrounding() {
        let text = grounding(budget: CoachRequestBudget.stateTile.tokens, reserved: 900, now: at(14, 30)).text
        XCTAssertTrue(text.contains("WEEK PLAN, TODAY"), text)
        XCTAssertTrue(text.contains("Move today's hard session"), text)
    }

    // MARK: - The lean grounding still carries the figures the prompt names

    /// THE ONE THAT MATTERS. `WorkoutSuggestionWriter.rules` tells the model to read: the sessions already
    /// completed today, the day's Effort so far against its target, the time now and the waking time left
    /// before bedtime, charge, sleep debt, HRV and resting HR against baseline, stress, and the last two
    /// weeks of training. `levelObjective` adds the level's gaps. Every one of those has to be IN the lean
    /// grounding, or the prompt is asking about figures it was not given.
    func testTheLeanGroundingContainsEveryFigureTheTilesPromptRefersTo() {
        let now = at(14, 30)
        let text = grounding(budget: CoachRequestBudget.stateTile.tokens, reserved: 900, now: now).text
        let key = dayKey(now)
        // Today's sessions, and the day's effort against its target.
        XCTAssertTrue(text.contains("Workouts ALREADY COMPLETED on \(key)"), text)
        XCTAssertTrue(text.contains("Running"), text)
        XCTAssertTrue(text.contains("Effort so far on \(key)"), text)
        XCTAssertTrue(text.contains("the recommended target for \(key)"), text)
        XCTAssertTrue(text.contains("Effort target is NOT yet reached"), text)
        // Charge, sleep debt, stress score.
        XCTAssertTrue(text.contains("Charge 71"), text)
        XCTAssertTrue(text.contains("Sleep debt: 1.5 h"), text)
        XCTAssertTrue(text.contains("Stress score for \(key)"), text)
        // HRV and resting HR against baseline — the numbers the stress objective keys on.
        XCTAssertTrue(text.contains("vs its 30-day median: -12%"), text)
        XCTAssertTrue(text.contains("+3 bpm"), text)
        // Meditation already logged, which the down-regulation rule needs.
        XCTAssertTrue(text.contains("Meditation / breathwork / NSDR logged on \(key): 10 min"), text)
        // The zones every suggestion's `zone` field is on.
        XCTAssertTrue(text.contains("Z1 120-133, Z2 134-147"), text)
        // The clock, the bedtime and the time actually left.
        XCTAssertTrue(text.contains("Time now: 14:30"), text)
        XCTAssertTrue(text.contains("Bedtime: 22:30"), text)
        XCTAssertTrue(text.contains("Waking time left"), text)
        XCTAssertTrue(text.contains("Wind-down"), text)
        // The last two weeks, and the level's gaps the advice is aimed at.
        XCTAssertTrue(text.contains("Workouts in the previous 14 days"), text)
        XCTAssertTrue(text.contains("Most recent hard session"), text)
        XCTAssertTrue(text.contains("THE LEVEL'S BIGGEST GAPS"), text)
        XCTAssertTrue(text.contains("lungs"), text)
        // Stress now and the shape of the curve.
        XCTAssertTrue(text.contains("Stress right now"), text)
        XCTAssertTrue(text.contains("Stress by hour"), text)
        // And which day everything belongs to.
        XCTAssertTrue(text.contains("TODAY is \(key)"), text)
        XCTAssertTrue(text.contains("NOT MEASURED"), text)
    }

    /// It is LEAN. The whole point is that this is a fraction of what the chat's context costs; a regression
    /// that quietly reattached a big block would pass every assertion above.
    func testTheLeanGroundingIsAFractionOfTheBudgetRatherThanAllOfIt() {
        let fit = grounding(budget: CoachRequestBudget.stateTile.tokens, reserved: 900, now: at(14, 30))
        XCTAssertTrue(fit.isComplete, "shortened \(fit.shortened), dropped \(fit.dropped)")
        XCTAssertLessThanOrEqual(fit.requestTokens, CoachRequestBudget.stateTile.tokens,
                                 "the tile's whole request came to \(fit.requestTokens) tokens")
        // And the request plus its retry at half fit inside one minute of the allowance the 413 was reported
        // against — which two parallel requests over the chat's context did not.
        XCTAssertLessThan(fit.requestTokens + CoachRequestBudget.halved(fit.requestTokens), 8_000)
    }

    /// A NOT-MEASURED PART IS NEVER CALLED WEAK, in the tile's own grounding as everywhere else.
    func testAnUnmeasuredLevelPartIsNamedAsUnmeasuredNotAsLow() {
        let text = grounding(budget: CoachRequestBudget.stateTile.tokens, reserved: 900, now: at(14, 30)).text
        XCTAssertTrue(text.contains("NOT MEASURED, so NOT weak"), text)
        XCTAssertTrue(text.contains("muscle"), text)
    }

    /// Squeezed, the block the tile's question is ABOUT survives, the memory file does not, and the context
    /// says it was trimmed.
    ///
    /// SELF-CALIBRATING: the budget is derived from what the complete grounding actually costs, so this pins
    /// the ORDER things are given up in rather than a hard-coded size that drifts with every prompt edit.
    func testUnderPressureTodaysStateSurvivesAndTheMemoryFileGoesFirst() {
        let now = at(14, 30)
        let reserved = 700
        let whole = grounding(budget: 99_999, reserved: reserved, now: now)
        XCTAssertTrue(whole.isComplete)
        // Two thirds of what it wants: enough to keep the dear blocks, not enough for all of them.
        let fit = grounding(budget: reserved + (whole.requestTokens - reserved) * 2 / 3, reserved: reserved,
                            now: now)
        XCTAssertFalse(fit.isComplete, "two thirds of the room should not fit everything")
        XCTAssertFalse(fit.dropped.contains("today's training state"),
                       "the block the question is about must be the last thing to go: \(fit.dropped)")
        XCTAssertTrue(fit.dropped.contains("the coach's memory file"), "\(fit.dropped)")
        XCTAssertTrue(fit.text.contains("Charge 71"), fit.text)
        XCTAssertTrue(fit.text.contains("CONTEXT TRIMMED"), fit.text)
    }

    // MARK: - The stress block

    /// The hourly curve is THINNED, not sent hour by hour: the objective asks whether stress is rising, which
    /// a handful of readings across the day answers.
    func testTheStressCurveIsThinnedAcrossTheDayKeepingTheFirstAndTheLast() {
        let hours = (6...20).map { (hour: $0, level: Double($0) / 10) }
        let thinned = StateGrounding.thin(hours, keeping: 5)
        XCTAssertEqual(thinned.count, 5)
        XCTAssertEqual(thinned.first?.hour, 6)
        XCTAssertEqual(thinned.last?.hour, 20)
        XCTAssertEqual(StateGrounding.thin(hours, keeping: 50).count, hours.count,
                       "fewer readings than the cap are all kept")
        XCTAssertTrue(StateGrounding.thin(hours, keeping: 0).isEmpty)
    }

    /// EVERY PART OF THE STRESS BLOCK ABSTAINS. Nothing at all means no block — never a heading over no
    /// figures, which is an invitation to invent some.
    func testTheStressBlockIsAbsentRatherThanEmpty() {
        XCTAssertNil(StateGrounding.stressBlock(day: "2026-09-29", now: nil, hourly: [], stressIndex: nil))
        let onlyNow = StateGrounding.stressBlock(day: "2026-09-29", now: 2.1, hourly: [], stressIndex: nil)
        XCTAssertNotNil(onlyNow)
        XCTAssertTrue(onlyNow!.contains("2.1"), onlyNow!)
        XCTAssertFalse(onlyNow!.contains("Stress by hour"), onlyNow!)
    }

    /// The Stress Index sentence is the engine's own, not a second copy of it.
    func testTheStressIndexSentenceIsTheOneTheRestOfTheAppUses() {
        let block = StateGrounding.stressBlock(day: "2026-09-29", now: nil, hourly: [], stressIndex: 140)
        XCTAssertTrue(block?.contains(AICoachEngine.stressIndexSummary(si: 140)) == true, block ?? "nil")
    }

    // MARK: - The merged request

    /// THE INSTRUCTIONS ARE THE EXISTING ONES. The merged prompt must ask for exactly what the two separate
    /// prompts asked for — the same rules, the same level and stress objectives, the same allowed list, the
    /// same goal-line vocabulary — because this change is about size, not about substance.
    func testTheMergedPromptAsksForBothHalvesWithTheSameRulesAsBefore() {
        let p = StatePlanWriter.systemPrompt(grounding: "GROUNDING", choices: .all)
        XCTAssertTrue(p.contains(WorkoutSuggestionWriter.rules), p)
        XCTAssertTrue(p.contains(DailyMissionWriter.rules), p)
        XCTAssertTrue(p.contains(WorkoutSuggestionWriter.levelObjective))
        XCTAssertTrue(p.contains(StateDayPlanContext.stressObjective))
        XCTAssertTrue(p.contains(StateDayPlanContext.missionStressNote))
        XCTAssertTrue(p.contains(WorkoutSuggestionWriter.fieldSpec))
        XCTAssertTrue(p.contains(DailyMissionWriter.goalLines))
        XCTAssertTrue(p.contains("ALLOWED SESSIONS"))
        XCTAssertTrue(p.contains("\"mission\""))
        XCTAssertTrue(p.contains("\"mission_goal\""))
        XCTAssertTrue(p.hasSuffix("GROUNDING"), "the grounding is the last thing the model reads")
    }

    /// The separate workout prompt is UNCHANGED by the refactor that let the merged one share its rules.
    func testTheSeparateWorkoutPromptStillReadsExactlyAsItDid() {
        let p = WorkoutSuggestionWriter.systemPrompt(grounding: "G", choices: .all)
        XCTAssertTrue(p.hasPrefix("You are the user's training coach. Answer ONE question: WHAT IS STILL DUE TODAY"))
        XCTAssertTrue(p.contains("- Prefer sports the user actually does.\n\nAIM AT THE LEVEL"), p)
        XCTAssertTrue(p.contains("Answer with JSON ONLY, no prose and no code fence, exactly in this shape:\n{"), p)
        XCTAssertTrue(p.contains("why: one short sentence in the user's language.\n\nG"), p)
    }

    /// One answer, both halves.
    func testOneMergedAnswerYieldsBothThePlanAndTheMission() {
        let raw = """
        {"left_today":"One Zone 2 ride and a wind-down.",
         "workouts":[{"sport":"Cycling","minutes":45,"zone":2,"effort":30,"window":"17:00-17:45","why":"Base."}],
         "mission":"Bed by 22:30. Your HRV has been filing complaints.",
         "mission_goal":"GOAL: BEDTIME_BY 22:30"}
        """
        let answer = StatePlanWriter.parse(raw)
        XCTAssertEqual(answer.plan?.workouts.count, 1)
        XCTAssertEqual(answer.plan?.workouts.first?.sport, "Cycling")
        XCTAssertEqual(answer.plan?.leftToday, "One Zone 2 ride and a wind-down.")
        let mission = DailyMissionWriter.parse(try! XCTUnwrap(answer.missionText), dayKey: "2026-09-29")
        XCTAssertEqual(mission?.goal?.metric, .bedtimeBy)
        XCTAssertTrue(mission?.text.contains("Bed by 22:30") == true)
        XCTAssertFalse(mission?.text.contains("GOAL:") == true, "the goal line never reaches the strip")
    }

    /// THE TWO HALVES FAIL SEPARATELY. A reply that gets the workout list right and forgets the mission must
    /// still have its list used — the two-request shape had that for free, and losing it would be a
    /// regression.
    func testAMissingMissionDoesNotCostTheWorkoutListOrViceVersa() {
        let noMission = StatePlanWriter.parse(
            #"{"left_today":"Done.","workouts":[{"sport":"Walking","minutes":20,"zone":1,"effort":3,"window":"18:00-18:20","why":"Steps."}]}"#)
        XCTAssertEqual(noMission.plan?.workouts.count, 1)
        XCTAssertNil(noMission.missionText)

        let noWorkouts = StatePlanWriter.parse(
            #"{"mission":"Ten minutes of slow breathing after dinner.","mission_goal":"MEDITATION_MIN 10"}"#)
        XCTAssertNil(noWorkouts.plan, "no left_today and no workouts is not a usable plan")
        XCTAssertNotNil(noWorkouts.missionText)
        // A goal written without the label still means a goal line; the label is added, never replaced.
        XCTAssertTrue(noWorkouts.missionText!.contains("GOAL: MEDITATION_MIN 10"), noWorkouts.missionText!)
    }

    /// The tolerant parsing the tile already had survives the merge: a code fence and a sentence around the
    /// object, and an empty list with a sentence ("you are done") as a legitimate answer.
    func testTheMergedParseKeepsTheToleranceTheOldOneHad() {
        let fenced = """
        Here you go:
        ```json
        {"left_today":"You are done for today.","workouts":[],
         "mission":"Lights out by 22:15.","mission_goal":"GOAL: BEDTIME_BY 22:15"}
        ```
        """
        let answer = StatePlanWriter.parse(fenced)
        XCTAssertEqual(answer.plan?.workouts.count, 0)
        XCTAssertEqual(answer.plan?.leftToday, "You are done for today.")
        XCTAssertNotNil(answer.missionText)
    }

    /// A reply with no JSON in it at all yields nothing, rather than half a plan built out of prose.
    func testProseWithNoJsonYieldsNeitherHalf() {
        let answer = StatePlanWriter.parse("I would go for a run this afternoon, around five.")
        XCTAssertNil(answer.plan)
        XCTAssertNil(answer.missionText)
    }

    // MARK: - The compact day frame

    /// EVERY RULE IS STILL THERE, shortened. The compact frame is what the tile sends in place of the chat's
    /// 1,400-character validity essay, and a rule that went missing is a figure the model may misread.
    func testTheCompactDayFrameKeepsEveryValidityRule() {
        let now = at(9, 15)
        let s = CoachDayFrame.compactBlock(now: now)
        XCTAssertTrue(s.contains("TODAY is \(dayKey(now))"), s)
        XCTAssertTrue(s.contains("still INCOMPLETE"), s)
        for rule in ["charge/recovery", "effort/strain", "NIGHT THAT ENDED", "meditation minutes",
                     "frozen on the morning", "NOT MEASURED"] {
            XCTAssertTrue(s.contains(rule), "the compact frame lost \"\(rule)\": \(s)")
        }
        XCTAssertLessThan(s.count, CoachDayFrame.block(now: now).count,
                          "the compact frame has to actually be smaller")
    }
}
