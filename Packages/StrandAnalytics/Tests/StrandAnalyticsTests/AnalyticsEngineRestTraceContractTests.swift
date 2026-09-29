import XCTest
@testable import StrandAnalytics

final class AnalyticsEngineRestTraceContractTests: XCTestCase {
    private let day = "2025-06-10"

    private func analyze(stage: String, efficiency: Double) -> (AnalyticsEngine.DayResult, [String]) {
        let start = AnalyticsEngine.dayStartUtcSeconds(day) + 3_600
        let end = start + 1_800
        let provided = SleepSession(
            start: start,
            end: end,
            efficiency: efficiency,
            stages: [StageSegment(start: start, end: end, stage: stage)],
            restingHR: nil,
            avgHRV: nil
        )
        var lines: [String] = []
        let result = AnalyticsEngine.analyzeDay(
            day: day,
            profile: UserProfile(),
            providedSleep: [provided],
            traceSink: { lines.append($0) }
        )
        return (result, lines)
    }

    func testWakeOnlySessionOmitsRestScoreAndRestTrace() {
        let result = analyze(stage: "wake", efficiency: 0.0)
        XCTAssertNil(result.0.restScore)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [])
        XCTAssertTrue(result.1.contains(
            "sleep-motion day=2025-06-10 grav=0 hr=0 sparse=false stager=V1 family=whoop5"
        ), "non-Rest diagnostics must remain available when Rest is absent")
    }

    /// An all-light 30-minute session is UNSTAGED (no deep, no REM) and the day carries no regularity
    /// signal, so two of the four terms have no input. Both are dropped and the remaining weights
    /// renormalise (weightSum 0.7): the score reads 33.04 from duration + efficiency alone.
    ///
    /// It used to read 28.13, which was duration + efficiency PLUS a restorative term scored 0 and halved
    /// again by `deepFactor` 0.5, PLUS a consistency term scored at a substituted neutral 0.5 — a deduction
    /// for missing information and a made-up value for 10% of the score. The trace prints `absent` for both,
    /// because a trace that printed `restor=0.0` would state a measurement that was never made.
    func testPositiveSleepKeepsExactRestTrace() {
        let result = analyze(stage: "light", efficiency: 1.0)
        XCTAssertEqual(result.0.restScore, 33.04)
        XCTAssertEqual(result.1.filter { $0.hasPrefix("rest ") }, [
            "rest composite=33.04 dur=0.06*wDur=0.5 eff=1.0*wEff=0.2 "
                + "restor=absent*wRestor=0.2 deepFactor=absent consist=absent*wConsist=0.1 "
                + "weightSum=0.7 group=1 groupInBedMin=30",
        ])
        // The tier, not the score, is where "we could not split the stages" belongs.
        XCTAssertEqual(result.0.restConfidence, .building)
    }
}
