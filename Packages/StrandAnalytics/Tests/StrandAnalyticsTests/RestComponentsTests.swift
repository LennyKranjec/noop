import XCTest
@testable import StrandAnalytics
import WhoopStore

/// The Rest composite's inputs as plottable per-day values (`RestComponents.swift`). They must be the SAME
/// quantities the composite reads, so a charted component can never disagree with the Rest it explains,
/// and they must never fabricate a value for a night that cannot supply one.
final class RestComponentsTests: XCTestCase {
    private typealias Rest = AnalyticsEngine.Rest
    private typealias Key = AnalyticsEngine.Rest.ComponentKey

    private func night(asleep: Double? = 420, deep: Double? = 70, rem: Double? = 90,
                       efficiency: Double? = 0.9, disturbances: Int? = 4) -> DailyMetric {
        DailyMetric(day: "2026-09-18", totalSleepMin: asleep, efficiency: efficiency,
                    deepMin: deep, remMin: rem, lightMin: 260, disturbances: disturbances,
                    restingHr: 52, avgHrv: 65, recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: Hours vs needed

    func testHoursVsNeededIsAsleepOverNeedInPercent() throws {
        // 7 h asleep against an 8 h need = 87.5 %.
        XCTAssertEqual(try XCTUnwrap(Rest.hoursVsNeededPct(asleepMin: 420, needHours: 8)), 87.5, accuracy: 1e-9)
    }

    func testHoursVsNeededIsNotClampedAtOneHundred() throws {
        // The composite clamps its duration SUB-SCORE, but the chart shows the real ratio.
        XCTAssertEqual(try XCTUnwrap(Rest.hoursVsNeededPct(asleepMin: 540, needHours: 8)), 112.5, accuracy: 1e-9)
    }

    func testHoursVsNeededNilWithoutSleepOrNeed() {
        XCTAssertNil(Rest.hoursVsNeededPct(asleepMin: nil, needHours: 8))
        XCTAssertNil(Rest.hoursVsNeededPct(asleepMin: 0, needHours: 8))
        XCTAssertNil(Rest.hoursVsNeededPct(asleepMin: 420, needHours: 0))
    }

    /// The component is the composite's duration term: a night whose other terms are held fixed moves its
    /// Rest by exactly wDuration × Δ(hours-vs-needed) while under the need.
    func testHoursVsNeededMatchesTheCompositesDurationTerm() throws {
        let short = night(asleep: 360), long = night(asleep: 420)
        // Hold restorative + deep shares fixed by scaling the stages with the night.
        let shortScaled = DailyMetric(day: short.day, totalSleepMin: 360, efficiency: 0.9,
                                      deepMin: 60, remMin: 360.0 * 90 / 420, lightMin: 200, disturbances: nil,
                                      restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
        let a = try XCTUnwrap(Rest.composite(daily: shortScaled, needHours: 8, consistency: 0.5))
        let b = try XCTUnwrap(Rest.composite(daily: long, needHours: 8, consistency: 0.5))
        let hA = try XCTUnwrap(Rest.hoursVsNeededPct(asleepMin: shortScaled.totalSleepMin, needHours: 8))
        let hB = try XCTUnwrap(Rest.hoursVsNeededPct(asleepMin: long.totalSleepMin, needHours: 8))
        XCTAssertEqual(b - a, Rest.wDuration * (hB - hA), accuracy: 0.02)   // composite rounds to 2 dp
    }

    // MARK: Restorative / deep

    func testRestorativeAndDeepShares() throws {
        let d = night()
        XCTAssertEqual(try XCTUnwrap(Rest.restorativeMin(daily: d)), 160, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Rest.restorativePct(daily: d)), 160.0 / 420 * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Rest.deepPct(daily: d)), 70.0 / 420 * 100, accuracy: 1e-9)
    }

    func testUnstagedNightHasNoRestorativeFigure() {
        // A total with no stage split must not read as 0 % restorative.
        let d = night(deep: nil, rem: nil)
        XCTAssertNil(Rest.restorativeMin(daily: d))
        XCTAssertNil(Rest.restorativePct(daily: d))
        XCTAssertNil(Rest.deepPct(daily: d))
    }

    // MARK: Points

    func testComponentPointsCarryEveryKeyWithThePassInputs() throws {
        let pts = Rest.componentPoints(daily: night(), needHours: 8.5, consistency: 0.82)
        XCTAssertEqual(pts.map(\.key), Key.persisted)
        XCTAssertTrue(pts.allSatisfy { $0.day == "2026-09-18" })
        let byKey = Dictionary(uniqueKeysWithValues: pts.map { ($0.key, $0.value) })
        XCTAssertEqual(try XCTUnwrap(byKey[Key.sleepNeedMin]), 510, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byKey[Key.consistencyPct]), 82, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(byKey[Key.hoursVsNeededPct]), 420.0 / 510 * 100, accuracy: 1e-9)
    }

    func testNoRegularitySignalEmitsNoConsistencyPoint() {
        // A thin-history pass scores with the neutral term; there is no regularity to chart.
        let keys = Rest.componentPoints(daily: night(), needHours: 8, consistency: nil).map(\.key)
        XCTAssertFalse(keys.contains(Key.consistencyPct))
        XCTAssertTrue(keys.contains(Key.hoursVsNeededPct))
    }

    func testNoSleepEmitsNothing() {
        XCTAssertTrue(Rest.componentPoints(daily: night(asleep: nil), needHours: 8, consistency: 0.8).isEmpty)
        XCTAssertTrue(Rest.componentPoints(daily: night(asleep: 0), needHours: 8, consistency: 0.8).isEmpty)
    }

    func testConsistencyIsClampedToZeroToOneHundred() throws {
        let v = try XCTUnwrap(Rest.componentValue(key: Key.consistencyPct, daily: night(),
                                                  needHours: 8, consistency: 1.4))
        XCTAssertEqual(v, 100, accuracy: 1e-9)
    }

    func testUnknownKeyIsNil() {
        XCTAssertNil(Rest.componentValue(key: "sleep_performance", daily: night(), needHours: 8, consistency: 0.5))
    }

    /// The keys are the SAME ones the WHOOP export importer writes, so an import outranks the computed
    /// figure per day in Explore instead of the two living under different names.
    func testKeysMatchTheImportersSeriesKeys() {
        XCTAssertEqual(Key.hoursVsNeededPct, "hours_vs_needed_pct")
        XCTAssertEqual(Key.sleepNeedMin, "sleep_need_min")
        XCTAssertEqual(Key.consistencyPct, "sleep_consistency")
        XCTAssertEqual(Key.restorativePct, "restorative_pct")
        XCTAssertEqual(Key.restorativeMin, "restorative_min")
    }
}
