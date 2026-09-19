import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// F4 — the personal Rest need/regularity the analysis pass scores with is recorded and every other Rest
/// read resolves through it, so the persisted `sleep_performance`, the Charge "Rest quality" term and the
/// display recomputes can no longer disagree about the same night.
final class RestEngineInputsTests: XCTestCase {
    private typealias Rest = AnalyticsEngine.Rest

    private var defaults: UserDefaults!
    private let suite = "RestEngineInputsTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A 7 h night — short of a long sleeper's need, so the need actually moves the score.
    private func night() -> DailyMetric {
        DailyMetric(day: "2026-07-02", totalSleepMin: 420, efficiency: 0.9,
                    deepMin: 70, remMin: 90, lightMin: 260, disturbances: nil,
                    restingHr: 52, avgHrv: 65, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil)
    }

    func testBeforeAnyPassIsTheDefaultComposite() {
        XCTAssertNil(Rest.engineNeedHours(defaults))
        XCTAssertNil(Rest.engineConsistency(defaults))
        XCTAssertEqual(Rest.compositeWithEngineInputs(daily: night(), defaults: defaults),
                       Rest.composite(daily: night()))
    }

    func testRecordedInputsAreWhatTheDisplayScoresWith() {
        Rest.recordEngineInputs(needHours: 9.0, consistency: 0.9, defaults: defaults)
        XCTAssertEqual(Rest.engineNeedHours(defaults), 9.0)
        XCTAssertEqual(Rest.engineConsistency(defaults), 0.9)
        let display = Rest.compositeWithEngineInputs(daily: night(), defaults: defaults)
        // Exactly the engine's own call with the same pair...
        XCTAssertEqual(display, Rest.composite(daily: night(), needHours: 9.0, consistency: 0.9))
        // ...and not the 8 h / neutral default the display used to fall back to.
        XCTAssertNotEqual(display, Rest.composite(daily: night()))
    }

    func testNilConsistencyClearsAStaleValue() {
        Rest.recordEngineInputs(needHours: 8.5, consistency: 0.7, defaults: defaults)
        Rest.recordEngineInputs(needHours: 8.5, consistency: nil, defaults: defaults)
        XCTAssertNil(Rest.engineConsistency(defaults))
        XCTAssertEqual(Rest.compositeWithEngineInputs(daily: night(), defaults: defaults),
                       Rest.composite(daily: night(), needHours: 8.5, consistency: nil))
    }
}
