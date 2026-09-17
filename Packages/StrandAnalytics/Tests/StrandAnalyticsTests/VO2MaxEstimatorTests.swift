import XCTest
@testable import StrandAnalytics

/// VO₂max from runs and walks: speed against heart-rate reserve, with the HR-ratio fallback.
final class VO2MaxEstimatorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func run(daysAgo: Double, km: Double, minutes: Double, hr: Double) -> VO2MaxEstimator.Session {
        VO2MaxEstimator.Session(start: now.addingTimeInterval(-daysAgo * 86_400),
                                durationS: minutes * 60, distanceM: km * 1000, avgHr: hr)
    }

    func testASteadyRunExtrapolatesThroughHeartRateReserve() throws {
        // 10 km in 50 min = 200 m/min → cost 43.5. RHR 50, HRmax 190 → HRR 140; avg 162 → 80 %.
        // VO₂max = 3.5 + 40 / 0.8 = 53.5.
        let v = try XCTUnwrap(VO2MaxEstimator.fromSession(run(daysAgo: 1, km: 10, minutes: 50, hr: 162),
                                                          restingHr: 50, hrMax: 190))
        XCTAssertEqual(v, 53.5, accuracy: 1e-9)
    }

    func testEffortsOutsideWhereTheMethodHoldsAreNotUsed() {
        // Too easy (HRR 30 %), near-maximal (HRR 97 %), too short, and a jog-walk speed.
        XCTAssertNil(VO2MaxEstimator.fromSession(run(daysAgo: 1, km: 10, minutes: 50, hr: 92), restingHr: 50, hrMax: 190))
        XCTAssertNil(VO2MaxEstimator.fromSession(run(daysAgo: 1, km: 10, minutes: 50, hr: 186), restingHr: 50, hrMax: 190))
        XCTAssertNil(VO2MaxEstimator.fromSession(run(daysAgo: 1, km: 2, minutes: 8, hr: 160), restingHr: 50, hrMax: 190))
        XCTAssertNil(VO2MaxEstimator.fromSession(run(daysAgo: 1, km: 6, minutes: 50, hr: 140), restingHr: 50, hrMax: 190))
    }

    func testTheEstimateIsTheMedianOfRecentValidSessions() throws {
        let sessions = [
            run(daysAgo: 1, km: 10, minutes: 50, hr: 162),   // 53.5
            run(daysAgo: 5, km: 8, minutes: 40, hr: 169),    // 3.5 + 40 / 0.85 = 50.56
            run(daysAgo: 9, km: 12, minutes: 60, hr: 155),   // 3.5 + 40 / 0.75 = 56.83
            run(daysAgo: 200, km: 10, minutes: 40, hr: 150), // too old
        ]
        let e = try XCTUnwrap(VO2MaxEstimator.estimate(sessions: sessions, restingHr: 50, hrMax: 190, now: now))
        XCTAssertEqual(e.method, .submaximal)
        XCTAssertEqual(e.sessions, 3)
        XCTAssertEqual(e.vo2max, 53.5, accuracy: 1e-9)
    }

    func testWithTooFewSessionsItFallsBackToTheHeartRateRatio() throws {
        let e = try XCTUnwrap(VO2MaxEstimator.estimate(sessions: [], restingHr: 50, hrMax: 190, now: now))
        XCTAssertEqual(e.method, .hrRatio)
        XCTAssertEqual(e.vo2max, 15.3 * 190 / 50, accuracy: 1e-9)
    }

    // MARK: - the zone-based model

    func testTheZoneModelIsTheHuntEquationWithTheWeeklyActivityIndex() throws {
        let week = VO2MaxEstimator.ActivityWeek(activeDays: 4, minutesPerActiveDay: 45, highIntensityFraction: 0.3)
        // PA index = 2.5 × 2 × 0.75 = 3.75. Men: 100.27 − 0.296·30 − 0.369·85 + 0.226·3.75 − 0.155·50.
        let v = try XCTUnwrap(VO2MaxEstimator.activityModel(age: 30, sex: "male", waistCm: 85, restingHr: 50, week: week))
        XCTAssertEqual(v, 100.27 - 0.296 * 30 - 0.369 * 85 + 0.226 * 3.75 - 0.155 * 50, accuracy: 1e-9)
        XCTAssertNil(VO2MaxEstimator.activityModel(age: 30, sex: "male", waistCm: 0, restingHr: 50, week: week))
    }

    func testRunsAndTheZoneModelBlendByHowManyRunsThereAre() throws {
        let sessions = [run(daysAgo: 1, km: 10, minutes: 50, hr: 162), run(daysAgo: 3, km: 10, minutes: 50, hr: 162)]
        let e = try XCTUnwrap(VO2MaxEstimator.estimate(sessions: sessions, restingHr: 50, hrMax: 190,
                                                       activityModel: 45.5, now: now))
        XCTAssertEqual(e.method, .blended)
        // Two runs at 53.5 → weight 2 / 4.
        XCTAssertEqual(e.vo2max, 0.5 * 53.5 + 0.5 * 45.5, accuracy: 1e-9)
    }

    func testWithoutRunsTheZoneModelBeatsTheHeartRateRatio() throws {
        let e = try XCTUnwrap(VO2MaxEstimator.estimate(sessions: [], restingHr: 50, hrMax: 190,
                                                       activityModel: 44, now: now))
        XCTAssertEqual(e.method, .activityModel)
        XCTAssertEqual(e.vo2max, 44, accuracy: 1e-9)
    }
}
