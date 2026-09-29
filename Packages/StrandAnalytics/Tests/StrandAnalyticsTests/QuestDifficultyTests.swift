import Foundation
import XCTest
@testable import StrandAnalytics

/// The morning's gear choice scales the day's targets off the WEARER'S OWN numbers. What matters here:
///
///   * A HARDER GEAR ASKS FOR MORE, from the same baseline — and the numbers are the multiplier table
///     (`QuestDifficulty.Scale`) applied to that baseline, not constants wearing a difficulty label.
///   * A BASELINE THAT IS NOT THERE PRODUCES NO TARGET. Nil is nil: no substituted default, no
///     population average, and no directive the data could not check.
///   * AN ABSTAINING LEVEL PART IS NEVER THE FOCUS. A part the level had no data for scores nil, and nil
///     is not a low score — the day must not be aimed at whichever measurement is simply missing.
///   * RELENTLESS NEVER EXCEEDS THE DAY'S OWN RECOMMENDED EFFORT BAND. A difficulty setting must not be
///     able to talk the wearer into overreaching.
final class QuestDifficultyTests: XCTestCase {

    private let day = "2026-09-29"

    /// A wearer with a full set of baselines: 9,000-step median, tracks water, trains ~40 min, meditates
    /// ~8 min, needs 7.6 h, usually asleep at 23:20, and a yellow-day effort band.
    private var full: QuestBaseline {
        QuestBaseline(medianSteps: 9_000, hydrationGoalMl: 3_400, medianTrainingMinutes: 40,
                      medianMeditationMinutes: 8, sleepNeedHours: 7.6,
                      medianSleepOnsetMinute: 23 * 60 + 20, effortBand21: 10...14)
    }

    private func threshold(_ targets: [QuestPlanTarget], _ metric: QuestMetric) -> Double? {
        targets.first { $0.goal.metric == metric }?.goal.threshold
    }

    private func all(_ difficulty: QuestDifficulty, _ baseline: QuestBaseline) -> [QuestPlanTarget] {
        QuestDayPlan.targets(baseline: baseline, difficulty: difficulty, day: day)
    }

    // MARK: - Scaling

    func testStepsScaleWithTheGearOffTheWearersOwnMedian() {
        // 9,000 × 1.00 / 1.15 / 1.35 = 9,000 / 10,350 / 12,150, each to the nearest 250.
        XCTAssertEqual(threshold(all(.steady, full), .steps), 9_000)
        XCTAssertEqual(threshold(all(.push, full), .steps), 10_250)
        XCTAssertEqual(threshold(all(.relentless, full), .steps), 12_250)
    }

    func testEveryScaledTargetRisesOrHoldsWithTheGear() {
        for metric in [QuestMetric.steps, .sleepHours, .workoutMinutes, .meditationMinutes,
                       .waterMl, .strain] {
            let steady = threshold(all(.steady, full), metric)
            let push = threshold(all(.push, full), metric)
            let hard = threshold(all(.relentless, full), metric)
            XCTAssertNotNil(steady, "\(metric) should be scalable from a full baseline")
            XCTAssertLessThanOrEqual(steady ?? 0, push ?? 0, "\(metric) must not fall from Steady to Push")
            XCTAssertLessThanOrEqual(push ?? 0, hard ?? 0, "\(metric) must not fall from Push to Relentless")
        }
        // A bedtime is the one that goes DOWN as the gear goes up: earlier is harder.
        let steady = threshold(all(.steady, full), .bedtimeBy)
        let hard = threshold(all(.relentless, full), .bedtimeBy)
        XCTAssertEqual(steady, Double(23 * 60 + 20))
        XCTAssertEqual(hard, Double(22 * 60 + 40))
    }

    func testStepsNeverTargetBelowTheFloorAtWhichADayCounted() {
        // A wearer whose median is 900 steps: Steady would otherwise ask for 900, which is not a target.
        let thin = QuestBaseline(medianSteps: 900)
        XCTAssertEqual(threshold(all(.steady, thin), .steps), Double(QuestTriggers.stepsFloor))
        XCTAssertEqual(threshold(all(.relentless, thin), .steps), Double(QuestTriggers.stepsFloor))
    }

    func testSleepBarelyMovesAndIsMeasuredAgainstTheirOwnNeed() {
        XCTAssertEqual(threshold(all(.steady, full), .sleepHours), 7.25)  // 7.6 × 0.95 = 7.22 → 7.25
        XCTAssertEqual(threshold(all(.push, full), .sleepHours), 7.5)     // 7.6 × 1.00 → 7.5
        XCTAssertEqual(threshold(all(.relentless, full), .sleepHours), 8.0) // 7.6 × 1.05 = 7.98 → 8.0
    }

    func testMeditationIsFlooredAtWhatCountsAsASessionAtAll() {
        let barely = QuestBaseline(medianMeditationMinutes: 2)
        XCTAssertEqual(threshold(all(.steady, barely), .meditationMinutes),
                       LevelEngine.meditationMinMinutes)
    }

    // MARK: - The effort band

    func testTheGearPicksAPointInTheDaysOwnBandAndNeverPastItsTop() {
        XCTAssertEqual(threshold(all(.steady, full), .strain), 10)
        XCTAssertEqual(threshold(all(.push, full), .strain), 12)
        XCTAssertEqual(threshold(all(.relentless, full), .strain), 14)
        // A red day's band is lower, and Relentless still respects it.
        var red = full
        red.effortBand21 = 4...10
        XCTAssertEqual(threshold(all(.relentless, red), .strain), 10)
    }

    // MARK: - Abstention

    func testAnAbsentBaselineProducesNoTargetForThatMetric() {
        var missing = full
        missing.medianSteps = nil
        missing.hydrationGoalMl = nil
        missing.effortBand21 = nil
        let targets = all(.relentless, missing)
        XCTAssertNil(threshold(targets, .steps))
        XCTAssertNil(threshold(targets, .waterMl))
        XCTAssertNil(threshold(targets, .strain))
        // And what IS measured still produces its target.
        XCTAssertNotNil(threshold(targets, .sleepHours))
    }

    func testAnEmptyBaselineProducesNoDirectivesAtAll() {
        for difficulty in QuestDifficulty.allCases {
            XCTAssertTrue(QuestDayPlan.plan(baseline: QuestBaseline(), difficulty: difficulty,
                                            day: day).isEmpty)
        }
    }

    func testAZeroBaselineIsNotATarget() {
        // Zero is not a baseline: a wearer whose median training day is zero minutes has no training
        // baseline, and "0 minutes of training" would be a quest that is met by doing nothing.
        let zeros = QuestBaseline(medianSteps: 0, hydrationGoalMl: 0, medianTrainingMinutes: 0,
                                  medianMeditationMinutes: 0, sleepNeedHours: 0)
        XCTAssertTrue(all(.relentless, zeros).isEmpty)
    }

    func testEveryTargetCarriesACheckableGoal() {
        for difficulty in QuestDifficulty.allCases {
            for target in all(difficulty, full) {
                XCTAssertFalse(target.target.isEmpty)
                XCTAssertTrue(QuestMetric.allCases.contains(target.goal.metric))
                XCTAssertGreaterThan(target.goal.threshold, 0)
            }
        }
    }

    // MARK: - The count

    func testTheGearSetsHowManyDirectivesTheDayCarries() {
        XCTAssertEqual(QuestDayPlan.plan(baseline: full, difficulty: .steady, day: day).count, 2)
        XCTAssertEqual(QuestDayPlan.plan(baseline: full, difficulty: .push, day: day).count, 3)
        XCTAssertEqual(QuestDayPlan.plan(baseline: full, difficulty: .relentless, day: day).count, 4)
    }

    func testAThinBaselineNeverPadsTheCountToTheGearsPromise() {
        let thin = QuestBaseline(medianSteps: 9_000)
        XCTAssertEqual(QuestDayPlan.plan(baseline: thin, difficulty: .relentless, day: day).count, 1)
    }

    // MARK: - The level's weakest MEASURED part

    private func component(_ part: LevelPart, _ score: Double?, _ weight: Double) -> LevelComponent {
        LevelComponent(part: part, score: score, effectiveWeight: weight)
    }

    private func breakdown(_ components: [LevelComponent]) -> LevelBreakdown {
        LevelBreakdown(components: components, raw: 60, stepPenalty: 1, level: 60, coverage: 1)
    }

    func testTheFocusIsTheWeakestMeasuredPart() {
        let b = breakdown([
            component(.sleep, 90, 0.30),
            component(.heart, 95, 0.23),
            component(.lungs, 40, 0.12),
            component(.muscle, 88, 0.24),
            component(.focus, 92, 0.11),
        ])
        // lungs: (100 - 40) × 0.12 = 7.2, the most headroom of the five.
        XCTAssertEqual(QuestDayPlan.focus(b), .lungs)
    }

    func testAnAbstainingPartIsNeverTheFocus() {
        // muscle has NO score — the wearer logs no lifting. It must not be read as the weakest part
        // just because there is nothing there.
        let b = breakdown([
            component(.sleep, 88, 0.34),
            component(.heart, 96, 0.26),
            component(.lungs, 99, 0.14),
            component(.muscle, nil, 0),
            component(.focus, 97, 0.13),
        ])
        XCTAssertEqual(QuestDayPlan.focus(b), .sleep)
        XCTAssertNotEqual(QuestDayPlan.focus(b), .muscle)
    }

    func testNoLevelMeansNoFocusRatherThanAGuessedOne() {
        XCTAssertNil(QuestDayPlan.focus(nil))
        XCTAssertNil(QuestDayPlan.focus(breakdown([component(.muscle, nil, 0)])))
    }

    func testTheFocusPutsItsOwnDirectivesFirstAndKeepsTheRestInOrder() {
        // Steady carries two directives. With sleep as the focus, both of them are the sleep ones.
        let ordered = QuestDayPlan.plan(baseline: full, difficulty: .steady, focus: .sleep, day: day)
        XCTAssertEqual(ordered.map(\.goal.metric), [.sleepHours, .bedtimeBy])
        // With focus on muscle, the training and effort directives lead instead.
        let muscle = QuestDayPlan.plan(baseline: full, difficulty: .steady, focus: .muscle, day: day)
        XCTAssertEqual(muscle.map(\.goal.metric), [.workoutMinutes, .strain])
        // And the SAME inputs always produce the same day — nothing here is order-dependent on a
        // dictionary or a clock.
        XCTAssertEqual(QuestDayPlan.plan(baseline: full, difficulty: .push, focus: .heart, day: day)
            .map(\.goal.metric),
                       QuestDayPlan.plan(baseline: full, difficulty: .push, focus: .heart, day: day)
            .map(\.goal.metric))
    }

    func testWaterIsNeverTheFocusBecauseTheLevelDoesNotReadIt() {
        let water = all(.steady, full).first { $0.goal.metric == .waterMl }
        XCTAssertNotNil(water)
        XCTAssertTrue(water?.parts.isEmpty == true)
        for part in LevelPart.allCases {
            XCTAssertFalse(water?.parts.contains(part) == true)
        }
    }

    // MARK: - Ids

    func testAPlanQuestIsRecognisableAndStablePerDayAndMetric() {
        let id = QuestDayPlan.questId(day: day, metric: .steps)
        XCTAssertEqual(id, QuestDayPlan.questId(day: day, metric: .steps))
        XCTAssertNotEqual(id, QuestDayPlan.questId(day: "2026-09-30", metric: .steps))
        XCTAssertNotEqual(id, QuestDayPlan.questId(day: day, metric: .waterMl))
        let planned = Quest(id: id, kind: .side, title: "t", taunt: "", target: "x", rewards: [], xp: 10,
                            dayKey: day, createdAtMs: 0)
        XCTAssertTrue(QuestDayPlan.isPlanQuest(planned))
        let triggered = Quest(kind: .side, title: "t", taunt: "", target: "x", rewards: [], xp: 10,
                              dayKey: day, createdAtMs: 0)
        XCTAssertFalse(QuestDayPlan.isPlanQuest(triggered))
    }

    // MARK: - Medians

    func testAMedianNeedsEnoughOfTheWearersOwnDays() {
        XCTAssertNil(QuestDayPlan.median([1, 2, 3, 4]))
        XCTAssertEqual(QuestDayPlan.median([1, 2, 3, 4, 5]), 3)
        XCTAssertEqual(QuestDayPlan.median([1, 2, 3, 4, 5, 6]), 3.5)
    }

    func testAMedianIsNotMovedByOneHugeDay() {
        let ordinary = [8_000.0, 8_200, 7_900, 8_100, 8_050]
        let withHike = ordinary + [42_000]
        XCTAssertEqual(QuestDayPlan.median(ordinary) ?? 0, 8_050, accuracy: 0.001)
        XCTAssertLessThan(QuestDayPlan.median(withHike) ?? 0, 8_200)
    }

    func testOnsetsEitherSideOfMidnightAverageToAnEveningTime() {
        // 23:40, 23:50, 00:10, 00:20, 00:00 — an evening median, not the middle of the afternoon.
        let onsets = [23 * 60 + 40, 23 * 60 + 50, 10, 20, 0]
        let median = QuestDayPlan.medianOnsetMinute(onsets)
        XCTAssertEqual(median, 0)
        XCTAssertNil(QuestDayPlan.medianOnsetMinute([23 * 60, 10]))
    }
}

/// A chosen-difficulty day ends in ONE outcome, in three honest categories. What matters here:
///
///   * MET / SHORT / NOT MEASURED are three different things. A directive whose metric was never read is
///     never reported as a miss, and a partial day is partial rather than a zero.
///   * A COMPLETION IS NOT RE-LITIGATED. A quest the data already closed reads as met whatever a later
///     look at the evidence says.
///   * A DAY THAT WENT ENTIRELY RIGHT SAYS NOTHING. Every met directive already had its own card with its
///     XP on it.
///   * THE READING IS THE ONE THAT DECIDED IT, so the summary can never quote a different number.
final class QuestPlanReportTests: XCTestCase {

    private let day = "2026-09-29"

    private func report(_ lines: [QuestPlanLine],
                        _ difficulty: QuestDifficulty = .relentless) -> QuestPlanDayReport {
        QuestPlanDayReport(day: day, difficulty: difficulty, lines: lines)
    }

    // MARK: - Measured or not

    func testAMetricTheDayNeverReadIsNotMeasuredRatherThanMissed() {
        let steps = QuestGoal(metric: .steps, threshold: 12_250)
        XCTAssertFalse(steps.isMeasured(by: QuestEvidence()))
        XCTAssertTrue(steps.isMeasured(by: QuestEvidence(steps: 0)))
        let line = QuestPlanDayReport.line(target: "12250 steps before the day is out", goal: steps,
                                          completed: false, evidence: QuestEvidence())
        XCTAssertEqual(line.outcome, .notMeasured)
        XCTAssertTrue(line.reading.isEmpty)
        XCTAssertTrue(line.text.hasPrefix("Not measured · "), line.text)
    }

    func testZeroIsMeasuredAndIsShortNotUnmeasured() {
        // The difference the honesty rule turns on: no step count is not zero steps, but zero steps IS a
        // reading, and a directive measured at zero fell short rather than going unread.
        let line = QuestPlanDayReport.line(target: "12250 steps before the day is out",
                                          goal: QuestGoal(metric: .steps, threshold: 12_250),
                                          completed: false, evidence: QuestEvidence(steps: 0))
        XCTAssertEqual(line.outcome, .short)
    }

    func testABedtimeNeedsBothNightsBeforeItCountsAsMeasured() {
        let earlier = QuestGoal(metric: .bedtimeEarlier, threshold: 45)
        XCTAssertFalse(earlier.isMeasured(by: QuestEvidence(nextSleepOnsetMinute: 1_320)))
        XCTAssertTrue(earlier.isMeasured(by: QuestEvidence(nextSleepOnsetMinute: 1_320,
                                                          previousSleepOnsetMinute: 1_380)))
    }

    func testEveryMetricHasAMeasurabilityReading() {
        // Nothing may fall through to a default: a metric added later must be classified explicitly, or
        // its directives would silently become "not measured" forever.
        let full = QuestEvidence(steps: 1, workoutMinutes: 1, meditationMinutes: 1, waterMl: 1,
                                 strain: 1, journaled: true, nextSleepHours: 1,
                                 nextSleepOnsetMinute: 1, previousSleepOnsetMinute: 1)
        for metric in QuestMetric.allCases {
            XCTAssertTrue(QuestGoal(metric: metric, threshold: 1).isMeasured(by: full),
                          "\(metric) should read as measured from full evidence")
            XCTAssertFalse(QuestGoal(metric: metric, threshold: 1).isMeasured(by: QuestEvidence()),
                           "\(metric) should read as unmeasured from empty evidence")
        }
    }

    // MARK: - Short carries the reading

    func testAShortDirectiveSaysHowCloseItGot() {
        let goal = QuestGoal(metric: .steps, threshold: 12_250)
        let evidence = QuestEvidence(steps: 8_400)
        let line = QuestPlanDayReport.line(target: "12250 steps before the day is out", goal: goal,
                                          completed: false, evidence: evidence)
        XCTAssertEqual(line.outcome, .short)
        // THE READING IS THE ONE THAT DECIDED IT — the same sentence the completion card would have
        // printed, off the same evidence, so the two can never quote different numbers. Compared as a
        // string rather than by digits, which are grouped differently per locale.
        XCTAssertEqual(line.reading, goal.summary(evidence))
        XCTAssertFalse(line.reading.isEmpty)
        XCTAssertTrue(line.text.hasPrefix("Short · "), line.text)
        XCTAssertTrue(line.text.hasSuffix(goal.summary(evidence)), line.text)
    }

    func testACompletedDirectiveIsMetWhateverALaterReadSays() {
        let line = QuestPlanDayReport.line(target: "12250 steps before the day is out",
                                          goal: QuestGoal(metric: .steps, threshold: 12_250),
                                          completed: true, evidence: QuestEvidence())
        XCTAssertEqual(line.outcome, .met)
        XCTAssertTrue(line.reading.isEmpty)
    }

    func testADirectiveWithNoGoalAtAllIsNotMeasured() {
        let line = QuestPlanDayReport.line(target: "stretch after lunch", goal: nil, completed: false,
                                          evidence: QuestEvidence())
        XCTAssertEqual(line.outcome, .notMeasured)
    }

    // MARK: - The whole day

    func testAMixedDayIsReportedInThreeCategories() {
        let r = report([
            QuestPlanLine(target: "8.0 hours of sleep tonight", outcome: .met, reading: "8.2 against 8.0."),
            // A met line shows the DIRECTIVE, not its reading: it is done, and four readings would not
            // fit on the card.
            QuestPlanLine(target: "12250 steps", outcome: .short, reading: "8,400 against 12,250."),
            QuestPlanLine(target: "50 minutes of training logged today", outcome: .short,
                          reading: "20 against 50."),
            QuestPlanLine(target: "A day strain of 14 on WHOOP's scale", outcome: .notMeasured),
        ])
        XCTAssertEqual(r.met.count, 1)
        XCTAssertEqual(r.short.count, 2)
        XCTAssertEqual(r.notMeasured.count, 1)
        XCTAssertEqual(r.headline, "1 of 4 met")
        XCTAssertTrue(r.subtitle.contains("RELENTLESS"), r.subtitle)
        XCTAssertTrue(r.subtitle.contains("4 DIRECTIVES"), r.subtitle)
        XCTAssertTrue(r.subtitle.contains("1 NOT MEASURED"), r.subtitle)
        // Every line appears exactly once, and the unmeasured one is not described as a failure.
        for line in r.lines { XCTAssertTrue(r.body.contains(line.text), line.text) }
        XCTAssertTrue(r.body.contains("Not measured · A day strain of 14 on WHOOP's scale"))
        XCTAssertTrue(r.body.contains("Met · 8.0 hours of sleep tonight"))
        XCTAssertFalse(r.body.contains("8.2 against 8.0."))
        XCTAssertFalse(r.body.lowercased().contains("failed"))
        XCTAssertTrue(r.isWorthShowing)
    }

    func testADayThatWentEntirelyRightHasNothingToSummarise() {
        let r = report([
            QuestPlanLine(target: "a", outcome: .met, reading: "x"),
            QuestPlanLine(target: "b", outcome: .met, reading: "y"),
        ])
        XCTAssertFalse(r.isWorthShowing)
        XCTAssertEqual(r.headline, "2 of 2 met")
    }

    func testADayWithNoDirectivesHasNothingToSummarise() {
        XCTAssertFalse(report([]).isWorthShowing)
    }

    func testTheLeadReadsAsAnOutcomeNotAScolding() {
        let partial = report([QuestPlanLine(target: "a", outcome: .met),
                              QuestPlanLine(target: "b", outcome: .short, reading: "x")])
        XCTAssertTrue(partial.lead.contains("took part of it"), partial.lead)
        let none = report([QuestPlanLine(target: "b", outcome: .short, reading: "x")])
        XCTAssertTrue(none.lead.contains("did not land"), none.lead)
        // Nothing measured: nothing is called a miss.
        let unread = report([QuestPlanLine(target: "b", outcome: .notMeasured)])
        XCTAssertTrue(unread.lead.contains("not being called a miss"), unread.lead)
        XCTAssertTrue(unread.isWorthShowing)
        for r in [partial, none, unread] {
            XCTAssertFalse(r.lead.isEmpty)
            XCTAssertFalse(r.body.isEmpty)
        }
    }

    func testASingleDirectiveDayIsNotPluralised() {
        let one = report([QuestPlanLine(target: "b", outcome: .short, reading: "x")], .steady)
        XCTAssertEqual(one.subtitle, "STEADY · 1 DIRECTIVE")
        XCTAssertEqual(one.headline, "0 of 1 met")
    }
}
