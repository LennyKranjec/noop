import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Aerobic minutes per session by %HRR (HEALTH_V2 S3 §3.2). Pinned here:
///   * class edges at exactly 0.40, 0.60 and 0.80;
///   * the 2-minute gap cap (one reading before a dropout cannot invent minutes);
///   * overlapping sessions are unioned (a detected bout inside a logged workout counts once);
///   * < 50 % HR coverage gives `unmeasured` — a session with no minutes, never "0 minutes of activity";
///   * imported zones are mapped z2–z3 moderate / z4–z5 vigorous and flagged approximate;
///   * no zone inputs ⇒ the day abstains instead of using a placeholder resting HR.
final class SessionIntensityTests: XCTestCase {

    // rhr 60, max 160 ⇒ reserve 100 bpm, so f = (bpm − 60) / 100 exactly.
    private let rhr = 60.0
    private let hrMax = 160.0

    private func hr(_ from: Int, _ through: Int, bpm: Int, step: Int = 1) -> [HRSample] {
        stride(from: from, through: through, by: step).map { HRSample(ts: $0, bpm: bpm) }
    }

    // MARK: Class edges

    func testClassEdgesAreInclusiveAtTheBottom() {
        XCTAssertEqual(SessionIntensity.classify(0.3999), .below)
        XCTAssertEqual(SessionIntensity.classify(0.40), .moderate)
        XCTAssertEqual(SessionIntensity.classify(0.5999), .moderate)
        XCTAssertEqual(SessionIntensity.classify(0.60), .vigorous)
        XCTAssertEqual(SessionIntensity.classify(0.7999), .vigorous)
        XCTAssertEqual(SessionIntensity.classify(0.80), .hard)
    }

    func testEdgesFromBpmThroughTheReserve() {
        let f40 = SessionIntensity.hrrFraction(bpm: 100, restingHR: rhr, hrMax: hrMax)!
        let f60 = SessionIntensity.hrrFraction(bpm: 120, restingHR: rhr, hrMax: hrMax)!
        let f80 = SessionIntensity.hrrFraction(bpm: 140, restingHR: rhr, hrMax: hrMax)!
        XCTAssertEqual(SessionIntensity.classify(f40), .moderate)
        XCTAssertEqual(SessionIntensity.classify(f60), .vigorous)
        XCTAssertEqual(SessionIntensity.classify(f80), .hard)
        XCTAssertEqual(SessionIntensity.classify(
            SessionIntensity.hrrFraction(bpm: 99, restingHR: rhr, hrMax: hrMax)!), .below)
    }

    func testHardMinutesAreAlsoVigorousMinutes() {
        let m = SessionIntensity.minutes(hr: hr(0, 599, bpm: 145), start: 0, end: 600, restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(m.source, .strapHR)
        XCTAssertEqual(m.hardMin, 10, accuracy: 1e-9)
        XCTAssertEqual(m.vigorousMin, 10, accuracy: 1e-9)
        XCTAssertEqual(m.mvpaEq, 20, accuracy: 1e-9)
        XCTAssertTrue(m.hardSession, "≥ 10 hard minutes is a hard session")
    }

    // MARK: Gap cap

    func testAGapIsCappedAtTwoMinutes() {
        // 5 min at 1 Hz, a 301 s dropout, 5 min at 1 Hz. Window 15 min, coverage 10/15 buckets.
        let samples = hr(0, 299, bpm: 130) + hr(600, 899, bpm: 130)
        let m = SessionIntensity.minutes(hr: samples, start: 0, end: 900, restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(m.source, .strapHR)
        // Block 1: 299 s + the pre-gap sample capped at 2 min. Block 2: 300 s (last sample clipped to the end).
        XCTAssertEqual(m.vigorousMin, 299.0 / 60.0 + 2.0 + 5.0, accuracy: 1e-9)
        XCTAssertLessThan(m.vigorousMin, 15.0, "the 301 s gap must not be credited in full")
    }

    // MARK: Union

    func testOverlappingSessionsAreCountedOnce() {
        let samples = hr(0, 899, bpm: 110)   // f = 0.5 ⇒ moderate throughout
        let sessions = [
            SessionIntensity.Window(start: 0, end: 600, sport: "Running"),
            SessionIntensity.Window(start: 300, end: 900, sport: "Detected activity"),
        ]
        let day = SessionIntensity.day(sessions: sessions, hr: samples, restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(day.sessionCount, 1)
        XCTAssertEqual(day.moderateMin, 15, accuracy: 1e-9, "the 5 overlapping minutes are counted once")
        XCTAssertEqual(day.mvpaEq, 15, accuracy: 1e-9)
    }

    func testUnionMergesTouchingAndDropsDegenerate() {
        let u = SessionIntensity.union([(start: 10, end: 20), (start: 0, end: 10), (start: 30, end: 30),
                                        (start: 25, end: 40)])
        XCTAssertEqual(u.count, 2)
        XCTAssertEqual(u[0].start, 0); XCTAssertEqual(u[0].end, 20)
        XCTAssertEqual(u[1].start, 25); XCTAssertEqual(u[1].end, 40)
    }

    // MARK: Coverage

    func testLowCoverageIsUnmeasuredNotZero() {
        // 20-min window, HR only in the first 5 minutes ⇒ 25 % coverage.
        let samples = hr(0, 299, bpm: 130)
        let m = SessionIntensity.minutes(hr: samples, start: 0, end: 1200, restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(m.source, .unmeasured)
        XCTAssertEqual(m.coverage ?? -1, 0.25, accuracy: 1e-9)

        let day = SessionIntensity.day(sessions: [.init(start: 0, end: 1200, sport: "Cycling")], hr: samples,
                                       restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(day.sessionCount, 1, "still counted as a session")
        XCTAssertEqual(day.unmeasuredCount, 1)
        XCTAssertEqual(day.mvpaEq, 0, "adds no minutes")
        XCTAssertNil(day.abstained, "an unmeasured session is not a day-level abstention")
    }

    func testThirtySecondCadenceIsFullCoverage() {
        let m = SessionIntensity.minutes(hr: hr(0, 1170, bpm: 110, step: 30), start: 0, end: 1200,
                                         restingHR: rhr, hrMax: hrMax)
        XCTAssertEqual(m.source, .strapHR)
        XCTAssertEqual(m.moderateMin, 20, accuracy: 1e-9)
    }

    // MARK: Imported zones

    func testImportedZonesAreMappedAndFlagged() {
        let w = SessionIntensity.Window(start: 0, end: 3600, sport: "Running", zonePercents: [10, 20, 30, 20, 10])
        let day = SessionIntensity.day(sessions: [w], hr: [], restingHR: rhr, hrMax: hrMax)
        XCTAssertTrue(day.approximate, "imported-zone minutes are marked ≈")
        XCTAssertEqual(day.moderateMin, 30, accuracy: 1e-9)    // z2 + z3 = 50 % of 60
        XCTAssertEqual(day.vigorousMin, 18, accuracy: 1e-9)    // z4 + z5 = 30 % of 60
        XCTAssertEqual(day.hardMin, 0, "imported %HRmax zones give no hard minutes")
        XCTAssertEqual(day.unmeasuredCount, 0)
    }

    // MARK: Abstention

    func testNoZoneInputsAbstains() {
        let w = SessionIntensity.Window(start: 0, end: 600, sport: "Running")
        let noRhr = SessionIntensity.day(sessions: [w], hr: hr(0, 599, bpm: 130), restingHR: nil, hrMax: hrMax)
        XCTAssertEqual(noRhr.abstained, .zoneInputsMissing)
        let noReserve = SessionIntensity.day(sessions: [w], hr: hr(0, 599, bpm: 130), restingHR: 100, hrMax: 110)
        XCTAssertEqual(noReserve.abstained, .zoneInputsMissing)
        let noSessions = SessionIntensity.day(sessions: [], hr: [], restingHR: nil, hrMax: nil)
        XCTAssertNil(noSessions.abstained, "nothing to classify ⇒ nothing to abstain from")
        XCTAssertEqual(noSessions.sessionCount, 0)
    }

    // MARK: Strength

    func testStrengthSessionNeedsTwentyMinutesOrALiftLog() {
        let long = SessionIntensity.day(sessions: [.init(start: 0, end: 25 * 60, sport: "Strength")], hr: [],
                                        restingHR: rhr, hrMax: hrMax)
        XCTAssertTrue(long.strengthSession)
        let short = SessionIntensity.day(sessions: [.init(start: 0, end: 15 * 60, sport: "Weightlifting")], hr: [],
                                         restingHR: rhr, hrMax: hrMax)
        XCTAssertFalse(short.strengthSession)
        let lift = SessionIntensity.day(sessions: [], hr: [], restingHR: rhr, hrMax: hrMax, liftSession: true)
        XCTAssertTrue(lift.strengthSession)
        XCTAssertTrue(SessionIntensity.isStrengthSport("Functional Fitness"))
        XCTAssertFalse(SessionIntensity.isStrengthSport("Running"))
    }
}
