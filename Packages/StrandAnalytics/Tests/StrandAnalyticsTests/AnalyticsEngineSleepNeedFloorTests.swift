import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Public `analyzeDay` contract for degenerate sleep-need inputs. The mirrored Android test uses the
/// same provided 30-second light-sleep session and asserts the same rounded Rest projection.
final class AnalyticsEngineSleepNeedFloorTests: XCTestCase {
    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let day = "2025-06-10"
    private let sessionStart = 1_749_517_200

    private func rest(sleepNeedHours: Double) throws -> Double {
        let provided = SleepSession(
            start: sessionStart,
            end: sessionStart + 30,
            efficiency: 1,
            stages: [StageSegment(start: sessionStart, end: sessionStart + 30, stage: "light")],
            restingHR: nil,
            avgHRV: nil)

        return try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: day,
            profile: profile,
            sleepNeedHours: sleepNeedHours,
            providedSleep: [provided]
        ).restScore)
    }

    /// The session is 30 s of LIGHT sleep, so it is unstaged (no deep, no REM) and the day carries no
    /// regularity signal: `Rest.composite` drops both of those terms and renormalises over the remaining
    /// 0.70 of weight. That is what moved these literals from 29.17/29.13 — the projection is still
    /// duration + efficiency, it is simply no longer diluted by a zeroed restorative term and a
    /// substituted neutral consistency. The BOUNDARY this test exists for is unchanged: every need at or
    /// below the 0.1 h floor lands on one value, and 0.101 h is the first to differ.
    func testSleepNeedUsesPointOneHourFloorAtAndAcrossBoundary() throws {
        let cases: [(need: Double, expectedRest: Double)] = [
            (-1.0, 34.52),
            (0.0, 34.52),
            (0.099, 34.52),
            (0.1, 34.52),
            (0.101, 34.46),
        ]

        let actual = try cases.map { try rest(sleepNeedHours: $0.need) }
        XCTAssertEqual(actual, cases.map(\.expectedRest))
    }
}
