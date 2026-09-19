import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// The Rest composite's inputs in Explore (statistics). A strap-only wearer had "Hours vs Needed",
/// "Restorative Sleep" and friends listed in the catalog but backed only by a WHOOP CSV import, so the
/// rows were permanently empty even though the engine computed every one of them for the Sleep Score.
/// Pure: no store, no app.
final class RestComponentsExploreTests: XCTestCase {

    private let whoop = Repository.whoopSource

    private func night(asleep: Double? = 420, deep: Double? = 70, rem: Double? = 90,
                       disturbances: Int? = 5, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(day: "2026-09-18", totalSleepMin: asleep, efficiency: 0.9, deepMin: deep, remMin: rem,
                    lightMin: 260, disturbances: disturbances, restingHr: rhr, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    // MARK: Daily-column derivation (history the analysis pass has not persisted)

    /// Hours vs needed derives with the SAME need `sleep_performance`'s daily-column derivation scores
    /// with (the engine's recorded need, else the default), so the two lines agree on an unpersisted day.
    func testHoursVsNeededDerivesWithTheEngineNeed() throws {
        let need = AnalyticsEngine.Rest.engineNeedHours() ?? AnalyticsEngine.Rest.defaultNeedHours
        let v = try XCTUnwrap(Repository.dailyColumn(key: "hours_vs_needed_pct", day: night()))
        XCTAssertEqual(v, 420 / (need * 60) * 100, accuracy: 1e-9)
        let needMin = try XCTUnwrap(Repository.dailyColumn(key: "sleep_need_min", day: night()))
        XCTAssertEqual(needMin, need * 60, accuracy: 1e-9)
    }

    func testRestorativeDeepAndDisturbancesDerive() throws {
        let d = night()
        XCTAssertEqual(try XCTUnwrap(Repository.dailyColumn(key: "restorative_min", day: d)), 160, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Repository.dailyColumn(key: "restorative_pct", day: d)),
                       160.0 / 420 * 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Repository.dailyColumn(key: "sleep_deep_pct", day: d)),
                       70.0 / 420 * 100, accuracy: 1e-9)
        XCTAssertEqual(Repository.dailyColumn(key: "sleep_disturbances", day: d), 5)
    }

    func testNoSleepDerivesNothing() {
        let d = night(asleep: nil)
        for key in ["hours_vs_needed_pct", "sleep_need_min", "restorative_pct", "restorative_min",
                    "sleep_deep_pct", "sleep_disturbances"] {
            XCTAssertNil(Repository.dailyColumn(key: key, day: d), key)
        }
    }

    /// Regularity is a pass-wide trait: only the pass that scored a night knows which value it used, so it
    /// is never back-derived onto history from today's value.
    func testConsistencyIsNotDerivedFromTheDailyRow() {
        XCTAssertNil(Repository.dailyColumn(key: "sleep_consistency", day: night()))
    }

    // MARK: Catalog

    func testEveryRestComponentHasAStatisticsRow() {
        for key in AnalyticsEngine.Rest.ComponentKey.persisted {
            XCTAssertNotNil(MetricCatalog.metric(key: key, source: whoop), "\(key) has no Explore row")
        }
        for key in ["sleep_disturbances", "rhr_waking"] {
            XCTAssertNotNil(MetricCatalog.metric(key: key, source: whoop), "\(key) has no Explore row")
        }
    }

    func testCatalogIdsStayUnique() {
        let ids = MetricCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testNewRowsCarryUnitsAndDirection() throws {
        let deep = try XCTUnwrap(MetricCatalog.metric(key: "sleep_deep_pct", source: whoop))
        XCTAssertEqual(deep.unit, "%"); XCTAssertEqual(deep.category, "Rest"); XCTAssertEqual(deep.higherIsBetter, true)
        let waking = try XCTUnwrap(MetricCatalog.metric(key: "rhr_waking", source: whoop))
        XCTAssertEqual(waking.unit, "bpm"); XCTAssertEqual(waking.higherIsBetter, false)
        let hvn = try XCTUnwrap(MetricCatalog.metric(key: "hours_vs_needed_pct", source: whoop))
        XCTAssertEqual(hvn.unit, "%"); XCTAssertNotNil(hvn.description)
    }

    // MARK: No-data dot agrees with the new fallbacks

    func testDerivedComponentRowsAreNotMarkedEmptyForAStrapOnlyUser() throws {
        let catalog = try ["hours_vs_needed_pct", "restorative_pct", "sleep_deep_pct"].map {
            try XCTUnwrap(MetricCatalog.metric(key: $0, source: whoop))
        }
        let ids = Repository.nonEmptyMetricIDs(catalog, keysBySource: [whoop: []], days: [night()],
                                               whoopSource: whoop)
        XCTAssertEqual(ids, Set(catalog.map(\.id)))
    }

    func testDayStressIsNotMarkedEmptyWhenTheStressScreenCanScoreIt() throws {
        let stress = try XCTUnwrap(MetricCatalog.metric(key: "stress", source: whoop))
        XCTAssertEqual(Repository.nonEmptyMetricIDs([stress], keysBySource: [whoop: []],
                                                    days: [night(rhr: 55)], whoopSource: whoop),
                       [stress.id])
        XCTAssertTrue(Repository.nonEmptyMetricIDs([stress], keysBySource: [whoop: []],
                                                   days: [night()], whoopSource: whoop).isEmpty)
    }

    func testSleepDebtIsNotMarkedEmptyWhenTheLedgerHasANight() throws {
        let debt = try XCTUnwrap(MetricCatalog.metric(key: "sleep_debt_min", source: whoop))
        XCTAssertEqual(Repository.nonEmptyMetricIDs([debt], keysBySource: [whoop: []],
                                                    days: [night()], whoopSource: whoop),
                       [debt.id])
        XCTAssertTrue(Repository.nonEmptyMetricIDs([debt], keysBySource: [whoop: []],
                                                   days: [night(asleep: nil)], whoopSource: whoop).isEmpty)
    }
}
