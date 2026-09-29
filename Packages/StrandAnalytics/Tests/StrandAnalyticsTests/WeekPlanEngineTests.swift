import XCTest
@testable import StrandAnalytics

/// The weekly movement plan (HEALTH_V2 S3 §3.3–3.5, §3.8). Pinned here:
///   * calibrating below 3 valid baseline weeks — no personal target;
///   * the aerobic ramp (b = 0/100/200/290 → 20/120/220/300) and the ramp guard for every b in 0…400;
///   * hold at the top of the range, on a load spike and on monotony;
///   * each easy trigger on its own; (d) is OFFERED and a decline changes nothing;
///   * steps only through the reliability gate, +1000 toward the plateau, hold at/above it;
///   * the DayGuidance precedence table, including nil tier and nil Charge;
///   * frozen weeks: re-running mid-week never moves the plan;
///   * the quest bridge: no training factor above 1.0 and no strain push on easy/low-Charge days,
///     and training shortfalls are not chargeable there.
final class WeekPlanEngineTests: XCTestCase {

    /// A Monday.
    private let today = "2026-09-28"

    private func add(_ d: String, _ n: Int) -> String { WeeklyDigestEngine.addDays(d, n) }

    /// `weeks` complete weeks before `today`, each with `weekly` mvpaEq spread over 7 worn days.
    private func history(weekly: Double, weeks: Int = 4, wear: Double = 0.9, trimp: Double? = 100,
                         steps: Double? = nil, reliable: Bool = false, strengthPerWeek: Int = 0,
                         hardPerWeek: Int = 0) -> [DayActivity] {
        var out: [DayActivity] = []
        for w in 1...weeks {
            let start = add(today, -7 * w)
            for i in 0..<7 {
                out.append(DayActivity(day: add(start, i), mvpaEq: weekly / 7, moderateMin: weekly / 7,
                                       vigorousMin: 0, hardSession: i < hardPerWeek,
                                       strengthSession: i < strengthPerWeek, steps: steps,
                                       stepsReliable: reliable, trimp: trimp, wearCoverage: wear))
            }
        }
        return out
    }

    private func inputs(days: [DayActivity], tier: ReadinessTier? = .normal,
                        last7: [ReadinessTier?] = Array(repeating: .normal, count: 7), nights: Int = 30,
                        charge: Double? = 70, illnessDays: [String] = [], illnessNow: Bool = false,
                        debt: Double? = 0, age: Int? = 35) -> WeekPlanInputs {
        WeekPlanInputs(today: today, days: days, hrvTier: tier, hrvTierLast7: last7, hrvValidNights: nights,
                       charge: charge, illnessRaisedDays: illnessDays, illnessRaisedNow: illnessNow,
                       sleepDebtMin: debt, age: age)
    }

    // MARK: Baseline

    func testCalibratingBelowThreeValidWeeks() {
        var days = history(weekly: 100, weeks: 2)
        days += history(weekly: 100, weeks: 4, wear: 0.2).filter { $0.day < add(today, -14) }
        let plan = WeekPlanEngine.decide(inputs(days: days))
        XCTAssertNil(plan.baselineMvpa)
        XCTAssertEqual(plan.validBaselineWeeks, 2)
        XCTAssertNil(plan.aerobicTarget, "no personal target before the baseline exists")
        XCTAssertTrue(plan.isCalibrating)
    }

    func testAWeekNeedsFiveWornDays() {
        var days = history(weekly: 100, weeks: 4)
        // Knock the wear out of 3 days of the oldest week.
        let oldest = add(today, -28)
        days = days.map { d in
            guard d.day >= oldest && d.day < add(oldest, 3) else { return d }
            return DayActivity(day: d.day, mvpaEq: d.mvpaEq, trimp: d.trimp, wearCoverage: 0.5)
        }
        let (b, valid) = WeekPlanEngine.baseline(days: days, weekStart: today)
        XCTAssertEqual(valid, 3)
        XCTAssertEqual(b ?? -1, 100, accuracy: 1e-6)
    }

    // MARK: Aerobic targets

    func testBuildTargetsFromTheSpecTable() {
        XCTAssertEqual(WeekPlanEngine.buildAerobicTarget(b: 0), 20)
        XCTAssertEqual(WeekPlanEngine.buildAerobicTarget(b: 100), 120)
        XCTAssertEqual(WeekPlanEngine.buildAerobicTarget(b: 200), 220)
        XCTAssertEqual(WeekPlanEngine.buildAerobicTarget(b: 290), 300)
    }

    func testBuildTargetThroughDecide() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100)))
        XCTAssertEqual(plan.type, .build)
        XCTAssertEqual(plan.aerobicTarget, 120)
    }

    func testTopOfRangeHoldsAtBaseline() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 400)))
        XCTAssertEqual(plan.type, .hold)
        XCTAssertEqual(plan.reasons.first?.code, .topOfRange)
        XCTAssertEqual(plan.aerobicTarget, 400)
    }

    func testRampGuardSweep() {
        for i in 0...400 {
            let b = Double(i)
            if b < WeekPlanEngine.whoHigh {
                let t = WeekPlanEngine.aerobicTarget(type: .build, b: b)!
                XCTAssertLessThanOrEqual(t, max(1.3 * b, b + 20) + 1e-9, "ramp guard at b=\(i)")
                XCTAssertLessThanOrEqual(t, 300, "never above 300 in a build week (b=\(i))")
                XCTAssertGreaterThanOrEqual(t, 0)
            }
            XCTAssertLessThanOrEqual(WeekPlanEngine.buildAerobicTarget(b: b), 300)
        }
    }

    func testEasyAndHoldTargets() {
        XCTAssertEqual(WeekPlanEngine.aerobicTarget(type: .easy, b: 200), 120)
        XCTAssertEqual(WeekPlanEngine.aerobicTarget(type: .hold, b: 203), 205)
        XCTAssertNil(WeekPlanEngine.aerobicTarget(type: .build, b: nil))
    }

    // MARK: Hold triggers

    func testHoldOnLoadSpike() {
        var days = history(weekly: 100, weeks: 4, trimp: 50)
        let lastStart = add(today, -7)
        days = days.map { d in
            guard d.day >= lastStart else { return d }
            return DayActivity(day: d.day, mvpaEq: d.mvpaEq, trimp: 200, wearCoverage: 0.9)
        }
        let plan = WeekPlanEngine.decide(inputs(days: days))
        XCTAssertEqual(plan.type, .hold)
        XCTAssertTrue(plan.reasons.contains { $0.code == .loadSpike })
        XCTAssertFalse(plan.reasons.contains { $0.code == .monotony }, "a constant week has no SD, no monotony")
        XCTAssertEqual(plan.aerobicTarget, 100)
    }

    func testHoldOnMonotony() {
        var days = history(weekly: 100, weeks: 4)
        let lastStart = add(today, -7)
        days = days.map { d in
            guard d.day >= lastStart, let ymd = WeeklyDigestEngine.parseYMD(d.day) else { return d }
            return DayActivity(day: d.day, mvpaEq: d.mvpaEq, trimp: ymd.2 % 2 == 0 ? 100 : 110, wearCoverage: 0.9)
        }
        let plan = WeekPlanEngine.decide(inputs(days: days))
        XCTAssertEqual(plan.type, .hold)
        XCTAssertTrue(plan.reasons.contains { $0.code == .monotony })
        XCTAssertGreaterThanOrEqual(plan.monotony ?? 0, 2.0)
    }

    func testMonotonyNeedsFourDaysAndSpread() {
        XCTAssertNil(WeekPlanEngine.monotony(dailyLoads: [1, 2, 3]))
        XCTAssertNil(WeekPlanEngine.monotony(dailyLoads: [5, 5, 5, 5]))
        XCTAssertNotNil(WeekPlanEngine.monotony(dailyLoads: [5, 6, 5, 6]))
    }

    // MARK: Easy triggers, each on its own

    func testEasyOnSuppressedHrvFiveOfSeven() {
        let five: [ReadinessTier?] = [.normal, .normal, .suppressed, .suppressed, .suppressed, .suppressed, .suppressed]
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100), last7: five))
        XCTAssertEqual(plan.type, .easy)
        XCTAssertEqual(plan.reasons.first?.code, .hrvSuppressed)
        XCTAssertEqual(plan.reasons.first?.value, 5)
        XCTAssertEqual(plan.aerobicTarget, 60)
        XCTAssertTrue(plan.strength.holdLoads)
        XCTAssertEqual(WeekPlanEngine.header(plan),
                       "EASY WEEK — your 7-day HRV has been below your normal range for 5 days")

        let four: [ReadinessTier?] = [.normal, .normal, .normal, .suppressed, .suppressed, .suppressed, .suppressed]
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(weekly: 100), last7: four)).type, .build)
    }

    func testEasyOnRecentIllness() {
        let recent = WeekPlanEngine.decide(inputs(days: history(weekly: 100), illnessDays: [add(today, -2)]))
        XCTAssertEqual(recent.type, .easy)
        XCTAssertEqual(recent.reasons.map(\.code), [.illnessRecent])
        let old = WeekPlanEngine.decide(inputs(days: history(weekly: 100), illnessDays: [add(today, -5)]))
        XCTAssertEqual(old.type, .build)
    }

    func testEasyOnSleepDebt() {
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(weekly: 100), debt: 180)).type, .easy)
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(weekly: 100), debt: 179)).type, .build)
    }

    private func frozenBuild(_ start: String) -> WeekPlan {
        WeekPlan(version: 1, weekStart: start, decidedOn: start, type: .build, reasons: [], baselineMvpa: 90,
                 validBaselineWeeks: 4, chronicLoad: nil, lastWeekLoad: nil, monotony: nil, aerobicTarget: 100,
                 hardSessionTarget: 0, hardSessionOptional: false,
                 strength: StrengthTarget(minSessions: 1, maxSessions: 1, holdLoads: false, setsFactor: 1),
                 stepsTarget: nil, stepsMedian: nil, stepsPlateau: 8000, ageKnown: true,
                 stepGate: StepGate(passed: false, reliableDays: 0, windowDays: 28), easyOffer: nil)
    }

    func testBuildStreakIsOfferedAndDeclineChangesNothing() {
        let days = history(weekly: 105, strengthPerWeek: 1)
        let frozen = [1, 2, 3].map { frozenBuild(add(today, -7 * $0)) }
        let plan = WeekPlanEngine.decide(inputs(days: days), frozen: frozen)
        XCTAssertEqual(plan.type, .build, "(d) is offered, never imposed")
        XCTAssertEqual(plan.easyOffer, .offered)

        let declined = WeekPlanEngine.respond(to: plan, accept: false, days: days)
        XCTAssertEqual(declined.easyOffer, .declined)
        XCTAssertEqual(declined.type, plan.type)
        XCTAssertEqual(declined.aerobicTarget, plan.aerobicTarget)
        XCTAssertEqual(declined.strength, plan.strength)
        XCTAssertEqual(declined.stepsTarget, plan.stepsTarget)
        // A decline carries nothing the quest layer could charge: the day's chargeability is unchanged.
        let g = WeekPlanEngine.guidance(day: today, weekType: declined.type, hrvTier: .normal, hrvValidNights: 30,
                                        charge: 70, illnessRaised: false, sleepDebtMin: 0)
        XCTAssertEqual(g.kind, .asPlanned)

        let accepted = WeekPlanEngine.respond(to: plan, accept: true, days: days)
        XCTAssertEqual(accepted.type, .easy)
        XCTAssertEqual(accepted.easyOffer, .accepted)
        XCTAssertEqual(accepted.aerobicTarget, WeekPlanEngine.aerobicTarget(type: .easy, b: plan.baselineMvpa))
    }

    func testNoOfferWhenAStreakWeekWasMissed() {
        let days = history(weekly: 30, strengthPerWeek: 1)   // 30 of 100 ⇒ missed
        let frozen = [1, 2, 3].map { frozenBuild(add(today, -7 * $0)) }
        XCTAssertNil(WeekPlanEngine.decide(inputs(days: days), frozen: frozen).easyOffer)
    }

    // MARK: Hard sessions and strength

    func testNoHardSessionsBelowTheWhoMinimum() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100, hardPerWeek: 2)))
        XCTAssertEqual(plan.hardSessionTarget, 0)
    }

    func testFirstHardSessionIsOptional() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 200)))
        XCTAssertEqual(plan.hardSessionTarget, 1)
        XCTAssertTrue(plan.hardSessionOptional)
        let habitual = WeekPlanEngine.decide(inputs(days: history(weekly: 200, hardPerWeek: 2)))
        XCTAssertEqual(habitual.hardSessionTarget, 2)
        XCTAssertFalse(habitual.hardSessionOptional)
    }

    func testStrengthStepsInAtOne() {
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(weekly: 100))).strength.minSessions, 1)
        XCTAssertEqual(WeekPlanEngine.decide(inputs(days: history(weekly: 100, strengthPerWeek: 2)))
            .strength.minSessions, 2)
    }

    // MARK: Steps

    func testStepTargets() {
        XCTAssertEqual(WeekPlanEngine.stepsTarget(median: 5000, plateau: 8000, lastWeekTarget: nil), 6000)
        XCTAssertEqual(WeekPlanEngine.stepsTarget(median: 7600, plateau: 8000, lastWeekTarget: nil), 8000)
        XCTAssertEqual(WeekPlanEngine.stepsTarget(median: 9000, plateau: 8000, lastWeekTarget: nil), 9000)
        XCTAssertEqual(WeekPlanEngine.stepsTarget(median: 7000, plateau: 8000, lastWeekTarget: 6000), 7000,
                       "never more than +1000 above last week's target")
    }

    func testPlateauByAge() {
        XCTAssertEqual(WeekPlanEngine.plateau(age: 35), 8000)
        XCTAssertEqual(WeekPlanEngine.plateau(age: 60), 7000)
        XCTAssertEqual(WeekPlanEngine.plateau(age: nil), 7000)
    }

    func testUnreliableStepsGiveNoTarget() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100, steps: 5000, reliable: false)))
        XCTAssertNil(plan.stepsTarget)
        XCTAssertFalse(plan.stepGate.passed)
        let reliable = WeekPlanEngine.decide(inputs(days: history(weekly: 100, steps: 5000, reliable: true)))
        XCTAssertEqual(reliable.stepsTarget, 6000)
    }

    func testStepGateNeedsSeventyPercent() {
        func days(_ n: Int) -> [DayActivity] {
            (1...28).map { i in
                DayActivity(day: add(today, -i), steps: 6000, stepsReliable: i <= n)
            }
        }
        XCTAssertFalse(WeekPlanEngine.stepGate(days: days(19), today: today).passed)
        XCTAssertTrue(WeekPlanEngine.stepGate(days: days(20), today: today).passed)
    }

    // MARK: Day guidance

    private func g(tier: ReadinessTier?, charge: Double?, illness: Bool = false, week: WeekType = .build,
                   debt: Double = 0) -> DayGuidance {
        WeekPlanEngine.guidance(day: today, weekType: week, hrvTier: tier, hrvValidNights: tier == nil ? 9 : 30,
                                charge: charge, illnessRaised: illness, sleepDebtMin: debt)
    }

    func testGuidancePrecedence() {
        XCTAssertEqual(g(tier: .normal, charge: 80, illness: true, week: .easy).kind, .rest, "illness wins")
        XCTAssertEqual(g(tier: .normal, charge: 80, week: .easy).kind, .easy)
        XCTAssertEqual(g(tier: .suppressed, charge: 30).kind, .easy)
        XCTAssertEqual(g(tier: .suppressed, charge: 70, debt: 120).kind, .easy)
        XCTAssertEqual(g(tier: .suppressed, charge: 70, debt: 119).kind, .moveHard)
        XCTAssertEqual(g(tier: .normal, charge: 20).kind, .moveHard)
        XCTAssertEqual(g(tier: .primed, charge: 70).kind, .asPlanned)
        XCTAssertEqual(g(tier: .normal, charge: 34).kind, .asPlanned, "the spec's line is Charge < 34")
    }

    func testGuidanceWithMissingInputs() {
        let noTier = g(tier: nil, charge: 70)
        XCTAssertEqual(noTier.kind, .asPlanned)
        XCTAssertTrue(noTier.notes.contains(.hrvCalibrating))
        XCTAssertEqual(noTier.qualifiers.first, "HRV trend still calibrating (9 of 14 nights)")

        let noTierLow = g(tier: nil, charge: 20)
        XCTAssertEqual(noTierLow.kind, .moveHard, "Charge alone still moves the hard session")

        let nothing = g(tier: nil, charge: nil)
        XCTAssertEqual(nothing.kind, .asPlanned)
        XCTAssertTrue(nothing.notes.contains(.noReading))
        XCTAssertTrue(nothing.qualifiers.contains("No reading this morning"))
    }

    func testSuppressedDayNeverAdvisesAHardSession() {
        for charge in [nil, 10.0, 50.0, 95.0] {
            let day = g(tier: .suppressed, charge: charge)
            XCTAssertFalse(day.hardSessionAdvised)
            XCTAssertFalse(day.allowsTrainingFactorAboveOne)
        }
    }

    // MARK: Freezing

    func testFrozenPlanIsNotRecomputedMidWeek() {
        let first = WeekPlanEngine.plan(inputs(days: history(weekly: 100)), frozen: [])
        XCTAssertEqual(first.type, .build)
        // Wednesday: the data now says easy — the week stays as decided.
        let midWeek = WeekPlanInputs(today: add(today, 2), days: history(weekly: 250), hrvTier: .suppressed,
                                     hrvTierLast7: Array(repeating: .suppressed, count: 7), hrvValidNights: 30,
                                     charge: 20, illnessRaisedDays: [], illnessRaisedNow: false,
                                     sleepDebtMin: 400, age: 35)
        XCTAssertEqual(WeekPlanEngine.plan(midWeek, frozen: [first]), first)
    }

    // MARK: Progress

    func testMidWeekLoadNote() {
        var days = history(weekly: 100, trimp: 100)   // chronic 700
        let plan = WeekPlanEngine.decide(inputs(days: days))
        days.append(DayActivity(day: today, mvpaEq: 30, trimp: 500))
        days.append(DayActivity(day: add(today, 1), mvpaEq: 30, trimp: 500))
        let p = WeekPlanEngine.progress(plan: plan, days: days, today: add(today, 1))
        XCTAssertEqual(p.aerobicDone, 60, accuracy: 1e-9)
        XCTAssertTrue(p.midWeekLoadNote, "1000 > 1.3 × 700")
    }

    func testOptimumNoticeFollowsThePlanNotTheBand() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100, trimp: 100)))   // chronic 700
        let easyShare = 700.0 / 7 * WeekPlanEngine.easyAerobicFactor                           // 60
        let easy = g(tier: .suppressed, charge: 30)
        XCTAssertTrue(WeekPlanEngine.optimumNoticeDue(plan: plan, guidance: easy, todayLoad: easyShare + 1))
        XCTAssertFalse(WeekPlanEngine.optimumNoticeDue(plan: plan, guidance: easy, todayLoad: easyShare - 1))
        XCTAssertFalse(WeekPlanEngine.optimumNoticeDue(plan: plan, guidance: g(tier: .normal, charge: 80),
                                                       todayLoad: 10_000), "never on an as-planned day")
        XCTAssertFalse(WeekPlanEngine.optimumNoticeDue(plan: plan, guidance: g(tier: .normal, charge: 80, illness: true),
                                                       todayLoad: 10_000), "never while the illness heads-up is up")
    }

    // MARK: Quest bridge

    private func relentlessTargets() -> [QuestPlanTarget] {
        QuestDayPlan.targets(baseline: QuestBaseline(medianSteps: 8000, medianTrainingMinutes: 60,
                                                     effortBand21: 10...14),
                             difficulty: .relentless, day: today)
    }

    func testEasyDayRelentlessIssuesNoFactorAboveOne() {
        let easy = g(tier: .suppressed, charge: 30)
        let out = WeekPlanQuestBridge.apply(relentlessTargets(), guidance: easy, difficulty: .relentless, charge: 30)
        let training = out.first { $0.goal.metric == .workoutMinutes }
        XCTAssertNotNil(training)
        XCTAssertLessThanOrEqual(training!.goal.threshold, 60 * 1.0, "no training factor above 1.0")
        XCTAssertLessThanOrEqual(training!.goal.threshold, WeekPlanQuestBridge.easyMovementCapMin)
        XCTAssertFalse(out.contains { $0.goal.metric == .strain }, "no strain push on an easy day")
        let steps = out.first { $0.goal.metric == .steps }
        XCTAssertEqual(steps?.goal.threshold, relentlessTargets().first { $0.goal.metric == .steps }?.goal.threshold,
                       "walking is compatible with recovery — steps untouched")
    }

    func testRestDayDropsTraining() {
        let rest = g(tier: .normal, charge: 80, illness: true)
        let out = WeekPlanQuestBridge.apply(relentlessTargets(), guidance: rest, difficulty: .relentless, charge: 80)
        XCTAssertFalse(out.contains { $0.goal.metric == .workoutMinutes || $0.goal.metric == .strain })
    }

    func testNoPlanYetStillNeverPushesLoadOnALowChargeMorning() {
        let low = WeekPlanQuestBridge.apply(relentlessTargets(), guidance: nil, difficulty: .relentless, charge: 25)
        let training = low.first { $0.goal.metric == .workoutMinutes }
        XCTAssertLessThanOrEqual(training?.goal.threshold ?? 0, WeekPlanQuestBridge.easyMovementCapMin)
        XCTAssertFalse(low.contains { $0.goal.metric == .strain })
        XCTAssertEqual(WeekPlanQuestBridge.apply(relentlessTargets(), guidance: nil, difficulty: .relentless,
                                                 charge: 80), relentlessTargets(),
                       "no plan and a good morning: the gear's own day, unchanged")
    }

    func testAsPlannedIsUnchanged() {
        let ok = g(tier: .normal, charge: 80)
        XCTAssertEqual(WeekPlanQuestBridge.apply(relentlessTargets(), guidance: ok, difficulty: .relentless,
                                                 charge: 80), relentlessTargets())
    }

    func testTrainingShortfallChargeability() {
        let easy = g(tier: .suppressed, charge: 30)
        let ok = g(tier: .normal, charge: 80)
        XCTAssertFalse(WeekPlanQuestBridge.isChargeable(metric: .workoutMinutes, guidance: easy, charge: 30))
        XCTAssertFalse(WeekPlanQuestBridge.isChargeable(metric: .strain, guidance: easy, charge: 30))
        XCTAssertTrue(WeekPlanQuestBridge.isChargeable(metric: .workoutMinutes, guidance: ok, charge: 80))
        XCTAssertFalse(WeekPlanQuestBridge.isChargeable(metric: .workoutMinutes, guidance: ok, charge: nil),
                       "unknown Charge counts as low")
        XCTAssertTrue(WeekPlanQuestBridge.isChargeable(metric: .steps, guidance: easy, charge: 30))
        XCTAssertFalse(WeekPlanQuestBridge.isChargeable(metric: .sleepHours, guidance: ok, charge: 80),
                       "physiology is never charged")
    }

    func testAerobicQuestIsLoggedMinutesAndOnlyOnGoodDays() {
        let plan = WeekPlanEngine.decide(inputs(days: history(weekly: 100)))
        let progress = WeekPlanEngine.progress(plan: plan, days: [], today: today)
        let ok = g(tier: .normal, charge: 80)
        let q = WeekPlanQuestBridge.aerobicQuest(plan: plan, progress: progress, guidance: ok, charge: 80,
                                                 day: today, xp: 40)
        XCTAssertEqual(q?.goal.metric, .workoutMinutes)
        XCTAssertTrue(WeekPlanQuestBridge.aerobicQuestRange.contains(q?.goal.threshold ?? -1))
        XCTAssertNil(WeekPlanQuestBridge.aerobicQuest(plan: plan, progress: progress, guidance: ok, charge: 30,
                                                      day: today, xp: 40), "never on a low-Charge day")
        XCTAssertNil(WeekPlanQuestBridge.aerobicQuest(plan: plan, progress: progress,
                                                      guidance: g(tier: .suppressed, charge: 80), charge: 80,
                                                      day: today, xp: 40))
        let done = WeekPlanEngine.progress(plan: plan, days: [DayActivity(day: today, mvpaEq: 200)], today: today)
        XCTAssertNil(WeekPlanQuestBridge.aerobicQuest(plan: plan, progress: done, guidance: ok, charge: 80,
                                                      day: today, xp: 40), "no quest once the week is met")
    }
}
