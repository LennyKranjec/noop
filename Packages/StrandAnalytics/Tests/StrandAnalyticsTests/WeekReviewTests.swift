import XCTest
@testable import StrandAnalytics

/// The Monday review (HEALTH_V2 S3 §3.6, §3.8). Pinned here:
///   * a shortfall on a day the plan itself made easy is not a miss;
///   * a shortfall the data cannot see is `notMeasured`, not `missed`;
///   * the VO₂max month rule counts session-based estimates only (never the Uth fallback);
///   * there is always exactly one suggestion, and the rules are applied in order;
///   * the coach block never exceeds `maxChars` and never cuts a line.
final class WeekReviewTests: XCTestCase {

    private let start = "2026-09-21"   // Monday
    private func add(_ d: String, _ n: Int) -> String { WeeklyDigestEngine.addDays(d, n) }

    private func plan(aerobic: Double? = 140, strength: Int = 1, steps: Double? = nil) -> WeekPlan {
        WeekPlan(version: 1, weekStart: start, decidedOn: start, type: .build, reasons: [], baselineMvpa: 120,
                 validBaselineWeeks: 4, chronicLoad: nil, lastWeekLoad: nil, monotony: nil, aerobicTarget: aerobic,
                 hardSessionTarget: 0, hardSessionOptional: false,
                 strength: StrengthTarget(minSessions: strength, maxSessions: strength, holdLoads: false,
                                          setsFactor: 1),
                 stepsTarget: steps, stepsMedian: nil, stepsPlateau: 8000, ageKnown: true,
                 stepGate: StepGate(passed: steps != nil, reliableDays: 28, windowDays: 28), easyOffer: nil)
    }

    /// The reviewed week: `mvpa[i]` on day i, worn, strength on the listed day indices.
    private func week(_ mvpa: [Double], strengthOn: Set<Int> = [], unmeasured: Int = 0,
                      wear: Double = 0.9) -> [DayActivity] {
        (0..<7).map { i in
            DayActivity(day: add(start, i), mvpaEq: mvpa[i], strengthSession: strengthOn.contains(i),
                        wearCoverage: wear, unmeasuredSessions: i == 0 ? unmeasured : 0)
        }
    }

    private func status(_ c: [ComponentResult], _ k: WeekComponent) -> ComponentStatus? {
        c.first { $0.component == k }?.status
    }

    // MARK: Plan vs done

    func testEasyDayShortfallIsNotAMiss() {
        let days = week([0, 0, 0, 0, 0, 20, 20], strengthOn: [5])
        let easyDays = Dictionary(uniqueKeysWithValues: (0..<5).map { (add(start, $0), DayGuidance.Kind.easy) })
        let excused = WeekReview.planVsDone(plan: plan(), days: days, guidanceByDay: easyDays, liftDataFresh: true)
        XCTAssertEqual(status(excused, .aerobic), .met, "40 of the 40 minutes the plan still asked for")
        XCTAssertEqual(status(excused, .strength), .met)

        let plain = WeekReview.planVsDone(plan: plan(), days: days, guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(plain, .aerobic), .missed, "without the easy days the same week is a miss")
    }

    func testStatusBands() {
        XCTAssertEqual(WeekReview.status(ratio: 0.9), .met)
        XCTAssertEqual(WeekReview.status(ratio: 0.89), .partly)
        XCTAssertEqual(WeekReview.status(ratio: 0.5), .partly)
        XCTAssertEqual(WeekReview.status(ratio: 0.49), .missed)
    }

    func testUnseenShortfallsAreNotMeasured() {
        let noHr = WeekReview.planVsDone(plan: plan(), days: week([10, 10, 0, 0, 0, 0, 0], unmeasured: 2),
                                         guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(noHr, .aerobic), .notMeasured, "sessions without heart rate cannot be called a miss")

        let staleLifts = WeekReview.planVsDone(plan: plan(strength: 2), days: week([20, 20, 20, 20, 20, 20, 20]),
                                               guidanceByDay: [:], liftDataFresh: false)
        XCTAssertEqual(status(staleLifts, .strength), .notMeasured)

        let unworn = WeekReview.planVsDone(plan: plan(), days: week([0, 0, 0, 0, 0, 0, 0], wear: 0.1),
                                           guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(unworn, .aerobic), .notMeasured)
    }

    func testCalibratingAndUncalibratedAreNotAsked() {
        let c = WeekReview.planVsDone(plan: plan(aerobic: nil, steps: nil), days: week([0, 0, 0, 0, 0, 0, 0]),
                                      guidanceByDay: [:], liftDataFresh: true)
        XCTAssertEqual(status(c, .aerobic), .notAsked)
        XCTAssertEqual(status(c, .steps), .notAsked)
    }

    // MARK: VO₂max

    func testVO2MonthRuleExcludesTheUthFallback() {
        var e = [
            VO2SessionEstimate(day: "2026-08-05", vo2max: 40, sessionBased: true),
            VO2SessionEstimate(day: "2026-08-19", vo2max: 42, sessionBased: true),
            VO2SessionEstimate(day: "2026-09-03", vo2max: 43, sessionBased: true),
            VO2SessionEstimate(day: "2026-09-04", vo2max: 50, sessionBased: false),
            VO2SessionEstimate(day: "2026-09-10", vo2max: 51, sessionBased: false),
            VO2SessionEstimate(day: "2026-09-12", vo2max: 52, sessionBased: false),
        ]
        let (none, why) = WeekReview.vo2Trend(e, asOf: "2026-09-27")
        XCTAssertNil(none, "three Uth estimates do not make a month")
        XCTAssertEqual(why, .tooFewSessions)
        XCTAssertTrue(WeekReview.vo2Line(none, why).hasPrefix("VO₂max —"))

        e.append(VO2SessionEstimate(day: "2026-09-20", vo2max: 44, sessionBased: true))
        let (trend, _) = WeekReview.vo2Trend(e, asOf: "2026-09-27")
        XCTAssertEqual(trend?.month, "2026-09")
        XCTAssertEqual(trend?.previousMonth, "2026-08")
        XCTAssertEqual(trend?.median ?? 0, 43.5, accuracy: 1e-9)
        XCTAssertEqual(trend?.previousMedian ?? 0, 41, accuracy: 1e-9)
        XCTAssertEqual(trend?.band, 5)
        XCTAssertTrue(WeekReview.vo2Line(trend, nil).contains("smaller than the estimate's error"))
        XCTAssertTrue(WeekReview.vo2Line(trend, nil).contains("Not a target"))
    }

    // MARK: One suggestion

    private func review(_ p: WeekPlan, _ days: [DayActivity], history: [DayActivity] = [],
                        trends: WeekTrendInputs = WeekTrendInputs()) -> WeekReview {
        WeekReview.build(plan: p, days: history + days, guidanceByDay: [:], liftDataFresh: true, trends: trends,
                         vo2Estimates: [], trialStatus: nil)
    }

    func testMissedStrengthSuggestsTheWearersOwnDays() {
        // Past strength on Tuesdays (Sep 1, 8) and Fridays (Sep 4, 11); none in the reviewed week.
        let past = ["2026-09-01", "2026-09-08", "2026-09-04", "2026-09-11"].map {
            DayActivity(day: $0, mvpaEq: 0, strengthSession: true, wearCoverage: 0.9)
        }
        let r = review(plan(strength: 2), week([20, 20, 20, 20, 20, 20, 20]), history: past)
        XCTAssertEqual(r.suggestion.rule, .missedStrength)
        XCTAssertEqual(r.suggestion.text, "Put 2 strength sessions in the calendar — Tue and Fri worked for you before")
    }

    func testRulesApplyInOrder() {
        let metWeek = week([20, 20, 20, 20, 20, 20, 20], strengthOn: [1])
        XCTAssertEqual(review(plan(aerobic: 400), metWeek).suggestion.rule, .missedAerobic)

        let wake = WeekTrendInputs(wakeSdMin: 50, typicalWakeMinute: 420, sleepDebtMin: 300, bedtimeTargetMinute: 1350)
        let w = review(plan(), metWeek, trends: wake)
        XCTAssertEqual(w.suggestion.rule, .wakeRegularity)
        XCTAssertEqual(w.suggestion.text, "Keep wake time within 30 min of 07:00")

        let debt = WeekTrendInputs(wakeSdMin: 30, sleepDebtMin: 150, bedtimeTargetMinute: 1350)
        let d = review(plan(), metWeek, trends: debt)
        XCTAssertEqual(d.suggestion.rule, .sleepDebt)
        XCTAssertEqual(d.suggestion.text, "Bedtime 22:30 this week")

        let fine = review(plan(), metWeek, trends: WeekTrendInputs(wakeSdMin: 20, sleepDebtMin: 30))
        XCTAssertEqual(fine.suggestion.rule, .keepPlan)
        XCTAssertEqual(fine.suggestion.text, "Keep the same plan")
    }

    func testThereIsAlwaysExactlyOneSuggestion() {
        // Every combination of missed components and sleep inputs yields one non-empty suggestion.
        for aerobic in [nil, 50.0, 400.0] {
            for strength in [0, 1, 3] {
                for wake in [nil, 10.0, 60.0] {
                    let r = review(plan(aerobic: aerobic, strength: strength), week([10, 0, 0, 0, 0, 0, 0]),
                                   trends: WeekTrendInputs(wakeSdMin: wake, sleepDebtMin: 200))
                    XCTAssertFalse(r.suggestion.text.isEmpty)
                }
            }
        }
    }

    // MARK: Coach block

    func testCoachBlockStaysUnderMaxCharsAndKeepsWholeLines() {
        let trends = WeekTrendInputs(hrv: HRVReadinessResult(tier: .normal, baseline7Ms: 52, normalLowMs: 45,
                                                             normalHighMs: 60, overreachingWatch: false),
                                     rhrWeekMean: 55, rhr4WeekMean: 54, sleepWeekMeanMin: 430, sleepNeedMin: 480,
                                     wakeSdMin: 35)
        let r = WeekReview.build(plan: plan(steps: 8000), days: week([20, 20, 20, 20, 20, 20, 20], strengthOn: [2]),
                                 guidanceByDay: [:], liftDataFresh: true, trends: trends, vo2Estimates: [],
                                 trialStatus: "Caffeine cutoff trial, day 12 of 28")
        let full = r.coachBlock(maxChars: 10_000)
        let fullLines = Set(full.components(separatedBy: "\n"))
        for maxChars in [0, 10, 40, 80, 120, 200, 300, 500] {
            let block = r.coachBlock(maxChars: maxChars)
            XCTAssertLessThanOrEqual(block.count, maxChars)
            for line in block.components(separatedBy: "\n") where !line.isEmpty {
                XCTAssertTrue(fullLines.contains(line), "line was cut: \(line)")
            }
        }
        XCTAssertTrue(r.coachBlock(maxChars: 500).hasPrefix("WEEK REVIEW 2026-09-21..2026-09-27"))
        XCTAssertTrue(r.coachBlock(maxChars: 500).contains("Suggestion: "))
    }
}
