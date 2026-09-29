import Foundation
import XCTest
@testable import StrandAnalytics

/// The energy bank's arithmetic.
///
/// The model is a stated arrangement rather than a measured physiology, so what these pin is not "is
/// this the right number" — it is that the number behaves the way the model SAYS it behaves. Every one
/// of them is a rule a reader could otherwise only discover by running the app for a day:
///
///   * NO OPENING BALANCE MEANS NO BANK. A balance drawn from an assumed 50 would be a figure about
///     nobody, and it would look exactly like a real one.
///   * SPENDING IS BOUNDED BY THE SCALE, not by the input. A strain of 40 on a 0–21 axis must not spend
///     twice a maximal day.
///   * RESTING CANNOT PRINT ENERGY. Calm hours recover a day; a quiet day that ended ABOVE the balance
///     it woke with would say that doing nothing beats a night's sleep.
final class EnergyBankTests: XCTestCase {

    func testNoRecoveryAndNoSleepMeansNoBank() {
        XCTAssertNil(EnergyBank.balance(recovery: nil, sleepScore: nil, strain: 12,
                                        stressMinutes: 120, calmMinutes: 200))
    }

    func testTheOpeningBalanceLeadsWithRecovery() {
        let b = EnergyBank.balance(recovery: 80, sleepScore: 60, strain: nil,
                                   stressMinutes: nil, calmMinutes: nil)
        // 0.7 × 80 + 0.3 × 60 = 74. Recovery leads because it is the overnight verdict on the whole
        // picture, and the sleep score is one input to that verdict.
        XCTAssertEqual(b?.opening ?? 0, 74, accuracy: 1e-9)
        XCTAssertEqual(b?.balance ?? 0, 74, accuracy: 1e-9, "nothing spent, nothing returned")
    }

    func testSleepAloneIsAWeakerClaimThanRecovery() {
        // A night scored well after a hard week is not a full tank, and the bank should not pretend the
        // two inputs are interchangeable.
        let b = EnergyBank.balance(recovery: nil, sleepScore: 90, strain: nil,
                                   stressMinutes: nil, calmMinutes: nil)
        XCTAssertEqual(b?.opening ?? 0, 81, accuracy: 1e-9)
    }

    func testAMaximalStrainDaySpendsMostOfTheBalanceButNotAllOfIt() {
        let b = EnergyBank.balance(recovery: 100, sleepScore: 100, strain: EnergyBank.strainMax,
                                   stressMinutes: 0, calmMinutes: 0)
        XCTAssertEqual(b?.strainSpend ?? 0, EnergyBank.strainCost, accuracy: 1e-9)
        // A person at 21 strain is tired, not incapable.
        XCTAssertEqual(b?.balance ?? 0, 100 - EnergyBank.strainCost, accuracy: 1e-9)
        XCTAssertGreaterThan(b?.balance ?? 0, 0)
    }

    func testStrainIsClampedToItsOwnScale() {
        // 40 on a 0–21 axis is a bad reading, not a doubly hard day.
        let wild = EnergyBank.balance(recovery: 100, sleepScore: 100, strain: 40,
                                      stressMinutes: 0, calmMinutes: 0)
        let maxed = EnergyBank.balance(recovery: 100, sleepScore: 100, strain: EnergyBank.strainMax,
                                       stressMinutes: 0, calmMinutes: 0)
        XCTAssertEqual(wild?.balance ?? 0, maxed?.balance ?? -1, accuracy: 1e-9)
    }

    func testStressSpendsOnTopOfStrain() {
        let calm = EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 10,
                                      stressMinutes: 0, calmMinutes: 0)
        let tense = EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 10,
                                       stressMinutes: EnergyBank.wakingMinutes, calmMinutes: 0)
        XCTAssertEqual(tense?.stressSpend ?? 0, EnergyBank.stressCost, accuracy: 1e-9)
        XCTAssertLessThan(tense?.balance ?? 0, calm?.balance ?? 0)
    }

    func testRestingCannotPrintEnergy() {
        // A whole day of calm, nothing spent. The return has nothing to credit against, so the balance
        // must not rise above the one the day opened with.
        let b = EnergyBank.balance(recovery: 70, sleepScore: 70, strain: 0,
                                   stressMinutes: 0, calmMinutes: EnergyBank.wakingMinutes)
        XCTAssertEqual(b?.restReturn ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(b?.balance ?? 0, 70, accuracy: 1e-9)
    }

    func testRestReturnsSomeOfWhatWasSpent() {
        let spent = EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 10,
                                       stressMinutes: 240, calmMinutes: 0)
        let rested = EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 10,
                                        stressMinutes: 240, calmMinutes: EnergyBank.wakingMinutes)
        XCTAssertGreaterThan(rested?.balance ?? 0, spent?.balance ?? 0)
        // …but never more than the day actually spent.
        XCTAssertLessThanOrEqual(rested?.restReturn ?? 0,
                                 (spent?.strainSpend ?? 0) + (spent?.stressSpend ?? 0))
    }

    func testAnAbsentSpendSimplySpendsNothing() {
        // A day with no stress read still has a strain figure worth spending.
        let b = EnergyBank.balance(recovery: 60, sleepScore: 60, strain: 10,
                                   stressMinutes: nil, calmMinutes: nil)
        XCTAssertEqual(b?.stressSpend ?? -1, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(b?.strainSpend ?? 0, 0)
    }

    func testTheBalanceNeverLeavesItsRange() {
        let floored = EnergyBank.balance(recovery: 10, sleepScore: 10, strain: EnergyBank.strainMax,
                                         stressMinutes: EnergyBank.wakingMinutes, calmMinutes: 0)
        XCTAssertEqual(floored?.balance ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(floored?.fraction ?? -1, 0, accuracy: 1e-9)
    }

    func testTheStateBandsReadInOrder() {
        XCTAssertEqual(EnergyBank.state(5), "spent")
        XCTAssertEqual(EnergyBank.state(30), "low")
        XCTAssertEqual(EnergyBank.state(50), "steady")
        XCTAssertEqual(EnergyBank.state(70), "good")
        XCTAssertEqual(EnergyBank.state(95), "full")
    }

    // MARK: - Bugs fixed in the audit (each failed, or could not be expressed, on the shipped code)

    func testANonFiniteOpeningAbstainsInsteadOfTrappingTheTile() {
        // Shipped: NaN flowed through `min`/`max` into `balance`, and the tile's `Int(balance.rounded())`
        // traps on NaN. An unreadable input is an absent one.
        XCTAssertNil(EnergyBank.balance(recovery: .nan, sleepScore: nil, strain: 5,
                                        stressMinutes: nil, calmMinutes: nil))
        XCTAssertNil(EnergyBank.balance(recovery: .infinity, sleepScore: .nan, strain: nil,
                                        stressMinutes: nil, calmMinutes: nil))
    }

    func testANonFiniteSpendSpendsNothingRatherThanPoisoningTheBalance() {
        let b = EnergyBank.balance(recovery: 70, sleepScore: nil, strain: .nan,
                                   stressMinutes: .nan, calmMinutes: .nan)
        XCTAssertNotNil(b)
        XCTAssertTrue(b?.balance.isFinite ?? false)
        XCTAssertEqual(b?.balance ?? -1, 70, accuracy: 1e-9)
    }

    func testTheOpeningIsClampedBeforeAnythingIsSpent() {
        // Shipped: clamped only on the way out, so a 130 opening hid the first 30 points of spend.
        let strain = EnergyBank.strainMax * 0.2                      // spends 0.2 × 55 = 11
        let b = EnergyBank.balance(recovery: 130, sleepScore: nil, strain: strain,
                                   stressMinutes: nil, calmMinutes: nil)
        XCTAssertEqual(b?.opening ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(b?.balance ?? -1, 100 - 0.2 * EnergyBank.strainCost, accuracy: 1e-9)
    }

    func testCalmIsOnlyMeasuredLowBandCoveredMinutes() {
        // Shipped wiring: calm = 960 − stress minutes, so every unworn, unscored and not-yet-lived minute
        // was calm. Now: covered minutes of scored, still, low-band hours only.
        let hours = [
            DaytimeStress.HourPoint(hour: 8, startTs: 0, level: 0.4, meanHR: 60, rmssd: nil, coveredMinutes: 50),
            DaytimeStress.HourPoint(hour: 9, startTs: 3600, level: 0.9, meanHR: 62, rmssd: nil, coveredMinutes: 12),
            DaytimeStress.HourPoint(hour: 10, startTs: 7200, level: 1.5, meanHR: 70, rmssd: nil, coveredMinutes: 60),
            DaytimeStress.HourPoint(hour: 11, startTs: 10800, level: 2.4, meanHR: 80, rmssd: nil, coveredMinutes: 60),
            DaytimeStress.HourPoint(hour: 12, startTs: 14400, level: nil, meanHR: nil, rmssd: nil,
                                    maskedForActivity: true, coveredMinutes: 60),
            DaytimeStress.HourPoint(hour: 13, startTs: 18000, level: nil, meanHR: nil, rmssd: nil, coveredMinutes: 3),
        ]
        XCTAssertEqual(EnergyBank.calmMinutes(hours: hours), 62)
    }

    func testAnUnscoredDayHasNoCalmAtAll() {
        let hours = [DaytimeStress.HourPoint(hour: 8, startTs: 0, level: nil, meanHR: nil, rmssd: nil)]
        XCTAssertNil(EnergyBank.calmMinutes(hours: hours))
        XCTAssertNil(EnergyBank.calmMinutes(hours: []))
    }

    func testAMorningSessionIsNotRefundedByCalmThatHasNotHappenedYet() {
        // 08:00, a 10-strain session, no high stress, no calm measured yet.
        let key = "2026-09-29"
        let inputs = EnergyBank.inputs(dayKey: key,
                                       recovery: [EnergyBank.stamp(80, key)],
                                       sleepScore: [EnergyBank.stamp(80, key)],
                                       strain21: [EnergyBank.stamp(10, key)],
                                       stressMinutesByDay: [key: 0], calmMinutesByDay: [:], hoursAwake: nil)
        XCTAssertNil(inputs.calmMinutes, "calm is never derived from the stress figure")
        let now = EnergyBank.balance(inputs)
        XCTAssertEqual(now?.restReturn ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(now?.balance ?? -1, 80 - 10 / EnergyBank.strainMax * EnergyBank.strainCost, accuracy: 1e-9)
        // What the shipped wiring computed for the same moment: a full day of "calm" refunded 15 points.
        let shipped = EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 10, stressMinutes: 0,
                                         calmMinutes: EnergyBank.wakingMinutes - 0)
        XCTAssertEqual((shipped?.balance ?? 0) - (now?.balance ?? 0), EnergyBank.restReturnMax, accuracy: 1e-9)
    }

    func testYesterdaysFiguresNeverOpenOrSpendTodaysBank() {
        // After the 04:00 rollover, before today's night is scored, the only recovery, sleep score and
        // strain on hand are yesterday's (the carried cloud row, `repo.days.last`). Shipped: they opened
        // today's bank and spent yesterday's whole-day strain against it. Now: no bank until today scores.
        let today = "2026-09-29"
        let yesterday = "2026-09-28"
        let inputs = EnergyBank.inputs(dayKey: today,
                                       recovery: [EnergyBank.stamp(72, yesterday), EnergyBank.stamp(nil, today)],
                                       sleepScore: [EnergyBank.stamp(85, yesterday)],
                                       strain21: [EnergyBank.stamp(15.2, yesterday)],
                                       stressMinutesByDay: [yesterday: 200], calmMinutesByDay: [yesterday: 300],
                                       hoursAwake: 1)
        XCTAssertNil(inputs.recovery)
        XCTAssertNil(inputs.sleepScore)
        XCTAssertNil(inputs.strain21)
        XCTAssertNil(inputs.stressMinutes, "stress is looked up under the same day key as everything else")
        XCTAssertNil(inputs.calmMinutes)
        XCTAssertNil(EnergyBank.balance(inputs))
    }

    func testTodaysFigureWinsInPreferenceOrderAndAStaleOneIsSkipped() {
        let today = "2026-09-29"
        let yesterday = "2026-09-28"
        let inputs = EnergyBank.inputs(dayKey: today,
                                       recovery: [EnergyBank.stamp(40, yesterday), EnergyBank.stamp(66, today),
                                                  EnergyBank.stamp(90, today)],
                                       sleepScore: [EnergyBank.stamp(.nan, today), EnergyBank.stamp(70, today)],
                                       strain21: [EnergyBank.stamp(6, today)],
                                       stressMinutesByDay: [today: 30], calmMinutesByDay: [today: 120],
                                       hoursAwake: -2)
        XCTAssertEqual(inputs.recovery, 66)
        XCTAssertEqual(inputs.sleepScore, 70)
        XCTAssertEqual(inputs.strain21, 6)
        XCTAssertEqual(inputs.stressMinutes, 30)
        XCTAssertEqual(inputs.calmMinutes, 120)
        XCTAssertNil(inputs.hoursAwake, "a wake still ahead of now is not a negative day")
    }

    func testTheSourceCompatibleEntryPointMatchesTheDefaultWeights() {
        let legacy = EnergyBank.balance(recovery: 70, sleepScore: 60, strain: 9, stressMinutes: 120,
                                        calmMinutes: 200)
        let inputs = EnergyInputs(recovery: 70, sleepScore: 60, strain21: 9, stressMinutes: 120, calmMinutes: 200)
        XCTAssertEqual(legacy?.balance, EnergyBank.balance(inputs, params: .defaults)?.balance)
        XCTAssertEqual(legacy?.inputs, inputs, "the result carries what it was computed from")
    }

    func testTimeAwakeSpendsOnlyWhenItsWeightIsOn() {
        let inputs = EnergyInputs(recovery: 80, sleepScore: 80, strain21: 0, hoursAwake: 10)
        XCTAssertEqual(EnergyBank.balance(inputs)?.balance ?? -1, 80, accuracy: 1e-9)
        var p = EnergyBank.Parameters.defaults
        p.awakeCostPerHour = 2
        XCTAssertEqual(EnergyBank.balance(inputs, params: p)?.balance ?? -1, 60, accuracy: 1e-9)
        XCTAssertEqual(EnergyBank.hoursAwake(wakeMinute: 7 * 60, nowMinute: 15 * 60 + 30) ?? -1, 8.5,
                       accuracy: 1e-9)
        XCTAssertNil(EnergyBank.hoursAwake(wakeMinute: nil, nowMinute: 600))
    }
}
