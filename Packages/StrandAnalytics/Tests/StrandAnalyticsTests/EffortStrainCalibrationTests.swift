import XCTest
@testable import StrandAnalytics

/// O8 — the per-wearer Effort (0–100) → WHOOP Day Strain (0–21) calibration.
final class EffortStrainCalibrationTests: XCTestCase {

    private let knownA = 1.35
    private let knownB = 0.58

    /// 30 paired days from a KNOWN curve, Effort 5…92, with ±3 % deterministic multiplicative noise.
    private func syntheticPairs() -> [(effort100: Double, strain21: Double)] {
        (0..<30).map { i -> (effort100: Double, strain21: Double) in
            let e = 5.0 + Double(i) * 3.0
            let noise = 1.0 + 0.03 * sin(Double(i) * 1.7)
            return (e, knownA * pow(e, knownB) * noise)
        }
    }

    func testRecoversAKnownCurve() throws {
        let cal = try XCTUnwrap(EffortStrainCalibration.fit(syntheticPairs()))
        XCTAssertEqual(cal.a, knownA, accuracy: knownA * 0.05)
        XCTAssertEqual(cal.b, knownB, accuracy: 0.02)
        XCTAssertEqual(cal.pairs, 30)
        // And the mapped values land where the true curve puts them.
        for e in [10.0, 40.0, 75.0] {
            XCTAssertEqual(cal.strain21(effort100: e), knownA * pow(e, knownB), accuracy: 0.3)
        }
    }

    /// Gross outliers (a strap-off workout day, a WHOOP day scored from another window) must not drag
    /// the curve: they are trimmed and the fit still recovers the known parameters.
    func testIsRobustToOutliers() throws {
        let dirty = syntheticPairs() + [(20.0, 19.5), (80.0, 2.0), (50.0, 0.5)]
        let cal = try XCTUnwrap(EffortStrainCalibration.fit(dirty))
        XCTAssertEqual(cal.a, knownA, accuracy: knownA * 0.05)
        XCTAssertEqual(cal.b, knownB, accuracy: 0.02)
        XCTAssertLessThanOrEqual(cal.pairs, 30, "the three outliers are not in the final fit")
    }

    /// Under `minPairs` usable days there is no calibration — the caller keeps the linear ×21/100.
    func testTooFewPairsFallsBackToLinear() {
        XCTAssertNil(EffortStrainCalibration.fit(Array(syntheticPairs().prefix(9))))
        XCTAssertNil(EffortStrainCalibration.fit([]))
        // Ten pairs of which two are no-data days (Effort < 1 / strain < 0.1) is still only eight usable.
        var mixed = Array(syntheticPairs().prefix(8))
        mixed.append((0.4, 5.0))
        mixed.append((30.0, 0.0))
        XCTAssertNil(EffortStrainCalibration.fit(mixed))
        XCTAssertEqual(EffortStrainCalibration.linearFactor, 21.0 / 100.0, accuracy: 1e-12)
    }

    /// Every day at the same Effort says nothing about the curve's shape — refused, not guessed.
    func testDegenerateSpreadIsRefused() {
        let flat = (0..<15).map { i in (effort100: 40.0, strain21: 10.0 + Double(i % 3)) }
        XCTAssertNil(EffortStrainCalibration.fit(flat))
    }

    /// Monotone and invertible: the inverse places a WHOOP-scale target back on the 0–100 axis exactly,
    /// and both directions are clamped to their scales.
    func testMonotoneInverseAndClamps() throws {
        let cal = try XCTUnwrap(EffortStrainCalibration.fit(syntheticPairs()))
        var prev = -1.0
        for e in stride(from: 0.0, through: 100.0, by: 5.0) {
            let s = cal.strain21(effort100: e)
            XCTAssertGreaterThanOrEqual(s, prev)
            prev = s
        }
        for target in [4.0, 10.0, 14.0, 18.0] {
            let e = cal.effort100(strain21: target)
            XCTAssertEqual(cal.strain21(effort100: e), target, accuracy: 1e-9)
        }
        XCTAssertEqual(cal.strain21(effort100: 0), 0)
        XCTAssertEqual(cal.strain21(effort100: -3), 0)
        XCTAssertEqual(cal.effort100(strain21: 0), 0)
        let steep = EffortStrainCalibration(a: 1.0, b: 1.0, pairs: 10)
        XCTAssertEqual(steep.strain21(effort100: 90), 21.0, "clamped to WHOOP's ceiling")
        XCTAssertEqual(steep.effort100(strain21: 21), 21.0, accuracy: 1e-12)
        let shallow = EffortStrainCalibration(a: 0.1, b: 1.0, pairs: 10)
        XCTAssertEqual(shallow.effort100(strain21: 20), 100.0, "clamped to Effort's ceiling")
    }

    /// Persisted as JSON in UserDefaults by the app — the round trip must be lossless.
    func testCodableRoundTrip() throws {
        let cal = EffortStrainCalibration(a: 1.234, b: 0.567, pairs: 42)
        let data = try JSONEncoder().encode(cal)
        XCTAssertEqual(try JSONDecoder().decode(EffortStrainCalibration.self, from: data), cal)
    }
}
