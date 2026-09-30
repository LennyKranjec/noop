import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// The owner's 2026-09-29 meditation rules, through the wiring (epoch 5 keeps them):
///
///   * a January-like day — before any meditation was ever logged — scores IDENTICALLY whether or not the
///     wearer starts meditating later, so the history is comparable;
///   * a meditation-era day that met the minimum equals the same day with no meditation term at all;
///   * a missed era day is lower by exactly `LevelEngine.meditationMissPenaltyPoints`;
///   * a day with no data is "not measured", never "missed";
///   * the minimum is date-effective (6 min counts before 2026-09-29, not from it), and the Focus badge,
///     the quest floor and the level term agree on the same day;
///   * the epoch bump empties the ledger once and re-derives.
final class LevelMeditationEraTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A night with sleep, stages and heart figures — enough for sleep + heart, over the coverage floor.
    private func row(_ day: String) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 450, efficiency: nil, deepMin: 90, remMin: 100, lightMin: nil,
                    disturbances: nil, restingHr: 55, avgHrv: 60, recovery: nil, strain: nil,
                    exerciseCount: nil, steps: 9_000)
    }

    private func rows(_ keys: [String]) -> [String: DailyMetric] {
        LevelWiring.byDay(keys.map(row))
    }

    private func series(meditation: [String: Double]) -> LevelSeries {
        var s = LevelSeries(vo2max: [], muscleByDay: [:], meditation: meditation)
        s.sleepNeedHours = 8
        return s
    }

    private func level(_ day: String, _ byDay: [String: DailyMetric], _ s: LevelSeries) throws -> Double {
        let inputs = LevelWiring.dayInputs(byDay: byDay, day: day, series: s, calendar: calendar)
        return try XCTUnwrap(LevelEngine.compute(inputs: inputs, baselines: LevelBaselines.table)).level
    }

    // MARK: - Comparability

    func testAJanuaryDayScoresTheSameWhetherOrNotMeditationStartsLater() throws {
        let jan = LevelWiring.keysBack("2026-01-20", 20, calendar)
        let byDay = rows(jan)
        let never = series(meditation: [:])
        let later = series(meditation: ["2026-06-01": 12, "2026-06-02": 3, "2026-09-10": 20])
        let a = LevelWiring.dayInputs(byDay: byDay, day: "2026-01-20", series: never, calendar: calendar)
        let b = LevelWiring.dayInputs(byDay: byDay, day: "2026-01-20", series: later, calendar: calendar)
        XCTAssertEqual(a, b)
        XCTAssertNil(b.meditationMissedDays)
        XCTAssertEqual(try level("2026-01-20", byDay, never), try level("2026-01-20", byDay, later), accuracy: 1e-12)
    }

    func testAMetEraDayEqualsTheSameDayWithNoMeditationTerm() throws {
        let keys = LevelWiring.keysBack("2026-09-20", 20, calendar)
        let byDay = rows(keys)
        var minutes: [String: Double] = [:]
        for k in keys { minutes[k] = 12 }
        let met = series(meditation: minutes)
        let none = series(meditation: [:])
        let inputs = LevelWiring.dayInputs(byDay: byDay, day: "2026-09-20", series: met, calendar: calendar)
        XCTAssertEqual(inputs.meditationMissedDays, 0)
        XCTAssertEqual(try level("2026-09-20", byDay, met), try level("2026-09-20", byDay, none), accuracy: 1e-12)
    }

    func testAMissedEraDayCostsExactlyThePenalty() throws {
        let keys = LevelWiring.keysBack("2026-09-20", 20, calendar)
        let byDay = rows(keys)
        var minutes: [String: Double] = [:]
        for k in keys { minutes[k] = 12 }
        let met = series(meditation: minutes)
        // The frozen day reads the window ending on the day BEFORE (09-19): miss 09-17.
        minutes["2026-09-17"] = 2
        let missed = series(meditation: minutes)
        let diff = try level("2026-09-20", byDay, met) - level("2026-09-20", byDay, missed)
        XCTAssertEqual(diff, LevelEngine.meditationMissPenaltyPoints, accuracy: 1e-9)
    }

    func testADayWithNoDataIsNotMeasuredNotMissed() {
        var keys = LevelWiring.keysBack("2026-09-20", 20, calendar)
        keys.removeAll { $0 == "2026-09-18" }          // no row at all that day
        let byDay = rows(keys)
        var minutes: [String: Double] = [:]
        for k in keys { minutes[k] = 12 }             // and nothing logged on it either
        XCTAssertEqual(LevelWiring.meditationMissedDays("2026-09-20", series(meditation: minutes), byDay, calendar), 0)
    }

    // MARK: - The date-effective minimum, one rule everywhere

    func testSixMinutesCountBeforeTheChangeoverAndMissAfterIt() {
        // 2026-09-22 … 2026-10-05, a row every day, six minutes logged every day.
        let keys = LevelWiring.keysBack("2026-10-05", 14, calendar)
        let byDay = rows(keys)
        var minutes: [String: Double] = [:]
        for k in keys { minutes[k] = 6 }
        let six = series(meditation: minutes)
        // Window 09-22 … 09-28: all before the changeover, all met.
        XCTAssertEqual(LevelWiring.meditationMissedDays("2026-09-28", six, byDay, calendar), 0)
        // Window 09-29 … 10-05: all from the changeover, all missed.
        XCTAssertEqual(LevelWiring.meditationMissedDays("2026-10-05", six, byDay, calendar), 7)
        // Window 09-26 … 10-02: three before (met), four from (missed).
        XCTAssertEqual(LevelWiring.meditationMissedDays("2026-10-02", six, byDay, calendar), 4)
    }

    func testTheBadgeTheQuestFloorAndTheLevelTermAgreeOnTheSameDay() {
        for day in ["2026-09-28", "2026-09-29"] {
            let floor = LevelEngine.meditationMinMinutes(on: day)
            // Quest floor: a tiny usual sits at that day's minimum.
            let quest = QuestDayPlan.targets(baseline: QuestBaseline(medianMeditationMinutes: 1),
                                             difficulty: .steady, day: day)
                .first { $0.goal.metric == .meditationMinutes }?.goal.threshold
            XCTAssertEqual(quest, floor, day)
            for minutes in [floor - 0.5, floor, floor + 0.5] {
                // Badge / circles.
                let badge = MeditationLog.isDayDone(minutes: minutes, day: day)
                // Level term: a one-day window in the era.
                let byDay = rows([day])
                let term = LevelWiring.meditationMissedDays(day, series(meditation: [day: minutes, "2026-01-01": 1]),
                                                            byDay, calendar)
                XCTAssertEqual(badge, term == 0, "\(day) \(minutes) min")
                XCTAssertEqual(badge, minutes >= floor)
            }
        }
    }

    // MARK: - The recompute

    func testTheEpochIsFiveAndALedgerFromEpochFourIsEmptiedOnceThenHolds() throws {
        XCTAssertEqual(LevelLedger.currentEpoch, 5)
        let ledger = LevelLedger(fileURL: nil)
        let written = FrozenLevel(
            day: "2026-09-16",
            breakdown: LevelBreakdown(components: [LevelComponent(part: .sleep, score: 60, effectiveWeight: 1)],
                                      raw: 60, stepPenalty: 1, level: 60, coverage: 1),
            drivers: [:])
        ledger.resetAll(epoch: 4)
        XCTAssertTrue(ledger.write(written))
        var refrozen = 0
        XCTAssertTrue(ledger.adoptCurrentEpochIfNeeded(rescoreDone: true) { refrozen += 1 })
        XCTAssertEqual(refrozen, 1, "the baselines are re-derived first")
        XCTAssertNil(ledger.entry("2026-09-16"), "every day is walked again under the new recipe")
        XCTAssertEqual(ledger.epoch, 5)
        // From here on, a committed day never changes again.
        XCTAssertTrue(ledger.write(written))
        XCTAssertFalse(ledger.adoptCurrentEpochIfNeeded(rescoreDone: true) { refrozen += 1 })
        XCTAssertFalse(ledger.write(FrozenLevel(day: "2026-09-16", breakdown: written.breakdown, drivers: [:])))
        XCTAssertEqual(ledger.entry("2026-09-16")?.level, 60)
    }

    func testTheBaselineHistoryCarriesTheSleepInputsAndNoMeditation() {
        let keys = LevelWiring.keysBack("2026-09-20", 20, calendar)
        var timings: [String: SleepTiming] = [:]
        for k in keys { timings[k] = SleepTiming(onsetMinute: 23 * 60, wakeMinute: 7 * 60) }
        var s = series(meditation: [:])
        s.sleepTimings = timings
        let history = LevelWiring.baselineHistory(days: keys.map(row), series: s, calendar: calendar)
        // Epoch 5: sleep duration against need is not a level input any more.
        XCTAssertTrue(history[.sleepDurationRatio, default: []].isEmpty)
        XCTAssertFalse(history[.sleepRegularityMin, default: []].isEmpty)
        XCTAssertEqual(history[.sleepRegularityMin]?.last ?? -1, 0, accuracy: 1e-6, "same bed and wake every night")
    }
}
