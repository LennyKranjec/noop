import XCTest
import StrandAnalytics
@testable import Strand

/// The check-in store: one answer per slot per day, pending answers matched to the next balance, and
/// the tile's figure drawn under the weights the verdict chose.
@MainActor
final class EnergyCheckInStoreTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EnergyCheckInStoreTests-\(UUID().uuidString)")
    }

    /// 10:00 local on a fixed day — the morning slot, well clear of the 04:00 rollover.
    private func morning(_ offsetMinutes: Double = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 29; c.hour = 10
        return Calendar.current.date(from: c)!.addingTimeInterval(offsetMinutes * 60)
    }

    func testASecondAnswerInTheSameSlotReplacesTheFirst() {
        let store = EnergyCheckInStore(defaults: defaults)
        store.record(felt: 2, at: morning())
        store.record(felt: 4, at: morning(5))
        XCTAssertEqual(store.checkIns.count, 1)
        XCTAssertEqual(store.checkIns.first?.felt, 4)
        XCTAssertEqual(store.checkIns.first?.slot, .morning)
        XCTAssertNil(store.openSlot(now: morning(10)), "the morning is answered")
        XCTAssertEqual(store.openSlot(now: morning(4 * 60)), .afternoon)
    }

    func testAnOutOfRangeAnswerIsIgnored() {
        let store = EnergyCheckInStore(defaults: defaults)
        store.record(felt: 0, at: morning())
        store.record(felt: 6, at: morning())
        XCTAssertTrue(store.checkIns.isEmpty)
    }

    func testAPendingCheckInIsMatchedOnlyWithinTheWindow() {
        let store = EnergyCheckInStore(defaults: defaults)
        store.record(felt: 3, slot: .morning, at: morning())
        let inputs = EnergyInputs(recovery: 70, sleepScore: 80)
        store.attach(inputs, now: morning(4 * 60))                    // four hours on: too late
        XCTAssertNil(store.checkIns.first?.inputs)
        store.attach(inputs, now: morning(20))
        XCTAssertEqual(store.checkIns.first?.inputs, inputs)
    }

    func testCheckInsSurviveARelaunch() {
        EnergyCheckInStore(defaults: defaults).record(felt: 5, at: morning(), inputs: EnergyInputs(recovery: 60))
        let reopened = EnergyCheckInStore(defaults: defaults)
        XCTAssertEqual(reopened.checkIns.count, 1)
        XCTAssertEqual(reopened.checkIns.first?.inputs?.recovery, 60)
        XCTAssertEqual(reopened.verdict.status, .calibrating)
    }

    func testTheTileFigureIsRedrawnUnderTheVerdictsWeights() {
        let store = EnergyCheckInStore(defaults: defaults)
        let given = EnergyBank.balance(recovery: 70, sleepScore: 60, strain: 9, stressMinutes: 60, calmMinutes: 30)
        XCTAssertEqual(store.calibrated(given), given, "calibrating: the defaults, so the same figure")
        let legacy = EnergyBalance(opening: 50, strainSpend: 0, stressSpend: 0, restReturn: 0, balance: 50)
        XCTAssertEqual(store.calibrated(legacy), legacy, "no inputs to redraw from: shown as given")
        XCTAssertNil(store.calibrated(nil))
    }

    func testTheCoachIsToldTheReportOutranksTheModel() {
        let store = EnergyCheckInStore(defaults: defaults)
        store.record(felt: 2, at: morning())
        let line = store.coachLine(EnergyBank.balance(recovery: 80, sleepScore: 80, strain: 4,
                                                      stressMinutes: 0, calmMinutes: 0),
                                   now: morning(30)) ?? ""
        XCTAssertTrue(line.contains("ESTIMATE"), line)
        XCTAssertTrue(line.contains("2/5"), line)
        XCTAssertTrue(line.contains("go by the report"), line)
    }
}
