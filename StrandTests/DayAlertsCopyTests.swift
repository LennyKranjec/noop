import XCTest
@testable import Strand

/// HEALTH_V2 H2 — the "Optimum reached" screen stays (coordinator decision 4), but it no longer claims a
/// certain cost off a population band, and it is not raised over an illness heads-up.
@MainActor
final class DayAlertsCopyTests: XCTestCase {

    func testTheOptimumMessageMakesNoClaimOfCertainCost() {
        let message = DayAlerts.optimumMessage
        XCTAssertFalse(message.contains("paid for tomorrow"))
        XCTAssertFalse(message.lowercased().contains("recovery can carry"))
        XCTAssertTrue(message.contains("range suggested for this morning's Charge"))
        XCTAssertTrue(message.contains("More is your call"))
        XCTAssertEqual(DayAlerts.Optimum(effort: "71", target: "67").message, message)
    }

    func testTheOptimumIsNotRaisedOverAnIllnessHeadsUp() {
        XCTAssertFalse(DayAlerts.mayRaiseOptimum(illnessHeadsUp: true))
        XCTAssertTrue(DayAlerts.mayRaiseOptimum(illnessHeadsUp: false))
    }
}
