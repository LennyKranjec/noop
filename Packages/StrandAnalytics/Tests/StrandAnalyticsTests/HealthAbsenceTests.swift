import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-A.5 — one absence vocabulary for every new 2.0 surface.
final class HealthAbsenceTests: XCTestCase {

    func testFixedShortTexts() {
        XCTAssertEqual(HealthAbsence.notLogged.text, "Not logged")
        XCTAssertEqual(HealthAbsence.tooFewNights(have: 5, need: 8).text, "5 of 8 nights so far")
        XCTAssertEqual(HealthAbsence.sealedUntil(day: "2026-10-16").text, "Sealed until 2026-10-16")
        XCTAssertEqual(HealthAbsence.calibrating(days: 3, need: 14).text, "Calibrating (3 of 14 days)")
        XCTAssertEqual(HealthAbsence.notLogged.line, "— Not logged")
    }

    func testEveryReasonHasAShortNonEmptyLine() {
        let all: [HealthAbsence] = [.notLogged, .tooFewNights(have: 1, need: 2), .sensorNotPaired, .stepsUncalibrated,
                                    .stagingSparse, .noMotionEvidence, .sealedUntil(day: "2026-01-01"),
                                    .calibrating(days: 1, need: 2), .illnessFlagged, .cannotSeparate]
        for a in all {
            XCTAssertFalse(a.text.isEmpty)
            XCTAssertLessThanOrEqual(a.text.count, 60)
            XCTAssertTrue(a.line.hasPrefix(HealthAbsence.dash))
        }
    }

    func testCodableRoundTrip() throws {
        let values: [HealthAbsence] = [.tooFewNights(have: 3, need: 8), .sealedUntil(day: "2026-10-16"), .notLogged]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([HealthAbsence].self, from: data), values)
    }
}
