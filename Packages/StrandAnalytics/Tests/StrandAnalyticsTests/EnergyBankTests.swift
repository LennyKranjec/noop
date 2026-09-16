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
}
