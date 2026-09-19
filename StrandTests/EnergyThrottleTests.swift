import XCTest
@testable import Strand

/// Energy reworks that must not change behaviour: the bedroom-climate history held in memory with a
/// throttled write, and the WiZ automation loop sleeping until the next window instead of polling.
@MainActor
final class EnergyThrottleTests: XCTestCase {

    // MARK: - ClimateHistory

    private let historyKey = "climate.history.v1"
    private var savedHistory: Data?

    private func reading(_ at: Date, _ t: Double = 18.5, _ h: Double = 45) -> ClimateReading {
        ClimateReading(temperatureC: t, humidityPct: h, battery: 80, deviceName: "H5075", source: "govee-ble", at: at)
    }

    private func persistedPoints() -> [ClimateHistory.Point] {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([ClimateHistory.Point].self, from: data)) ?? []
    }

    override func setUp() {
        super.setUp()
        savedHistory = UserDefaults.standard.data(forKey: historyKey)
        UserDefaults.standard.removeObject(forKey: historyKey)
        ClimateHistory.resetCacheForTesting()
    }

    override func tearDown() {
        if let savedHistory {
            UserDefaults.standard.set(savedHistory, forKey: historyKey)
        } else {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
        ClimateHistory.resetCacheForTesting()
        super.tearDown()
    }

    func testHistoryReadsTheMemoryCopyAndWritesOnAThrottle() {
        let t0 = Date().addingTimeInterval(-3600)
        ClimateHistory.record(reading(t0))
        XCTAssertEqual(ClimateHistory.all().count, 1)
        XCTAssertEqual(persistedPoints().count, 1, "the first change is written at once")

        // A second point, far enough apart to append: visible immediately, written later.
        ClimateHistory.record(reading(t0.addingTimeInterval(10 * 60), 19))
        XCTAssertEqual(ClimateHistory.all().map(\.temperatureC), [18.5, 19])
        XCTAssertEqual(persistedPoints().count, 1, "within the write interval the defaults copy waits")

        ClimateHistory.flush()
        XCTAssertEqual(persistedPoints().map(\.temperatureC), [18.5, 19])
    }

    /// Same spacing rule as before: a reading inside `minSpacing` replaces the last point.
    func testCloseReadingStillReplacesTheLastPoint() {
        let t0 = Date().addingTimeInterval(-3600)
        ClimateHistory.record(reading(t0))
        ClimateHistory.record(reading(t0.addingTimeInterval(60), 20))
        XCTAssertEqual(ClimateHistory.all().count, 1)
        XCTAssertEqual(ClimateHistory.all().last?.temperatureC, 20)
    }

    /// Readings older than the retention window are pruned exactly as before.
    func testRetentionStillPrunes() {
        ClimateHistory.record(reading(Date().addingTimeInterval(-Double(ClimateHistory.keepDays + 1) * 86_400)))
        XCTAssertEqual(ClimateHistory.all().count, 0)
    }

    /// Existing data on disk is what the memory copy starts from.
    func testMemoryCopyLoadsFromDefaults() throws {
        let p = ClimateHistory.Point(at: Date().addingTimeInterval(-7200), temperatureC: 17, humidityPct: 50)
        UserDefaults.standard.set(try JSONEncoder().encode([p]), forKey: historyKey)
        ClimateHistory.resetCacheForTesting()
        XCTAssertEqual(ClimateHistory.all(), [p])
        XCTAssertEqual(ClimateHistory.since(p.at.addingTimeInterval(1)), [])
    }

    /// A non-standard defaults (only tests pass one) keeps the old read-modify-write behaviour.
    func testCustomDefaultsBypassesTheCache() {
        let suite = "EnergyThrottleTests.climate"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        ClimateHistory.record(reading(Date().addingTimeInterval(-60)), d)
        XCTAssertEqual(ClimateHistory.all(d).count, 1)
        XCTAssertEqual(ClimateHistory.all().count, 0, "the standard history is untouched")
    }

    // MARK: - WiZ automation cadence

    func testAutomationSleepsUntilTheNextWindowCappedAtFiveMinutes() {
        let store = WizLightStore.shared
        let saved = (store.wakeLightOn, store.wakeMinute, store.windDownOn, store.windDownMinute)
        defer {
            store.wakeLightOn = saved.0; store.wakeMinute = saved.1
            store.windDownOn = saved.2; store.windDownMinute = saved.3
        }
        let cal = Calendar.current
        let day = cal.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            cal.date(bySettingHour: h, minute: m, second: s, of: day)!
        }
        store.wakeLightOn = true
        store.wakeMinute = 6 * 60 + 30
        store.windDownOn = false
        store.windDownMinute = 21 * 60 + 30

        // One minute before the wake window opens: sleep exactly to it.
        XCTAssertEqual(store.secondsUntilNextAutomationCheck(now: at(6, 29)), 60, accuracy: 0.001)
        // Hours before it: capped, so a clock / time-zone change is re-evaluated in time.
        XCTAssertEqual(store.secondsUntilNextAutomationCheck(now: at(3, 0)), WizLightStore.automationMaxSleep,
                       accuracy: 0.001)
        // Inside the (already handled) window: next opening is tomorrow, so the cap applies.
        XCTAssertEqual(store.secondsUntilNextAutomationCheck(now: at(6, 31)), WizLightStore.automationMaxSleep,
                       accuracy: 0.001)
        // A disabled automation never shortens the sleep.
        XCTAssertEqual(store.secondsUntilNextAutomationCheck(now: at(21, 29)), WizLightStore.automationMaxSleep,
                       accuracy: 0.001)
        store.windDownOn = true
        XCTAssertEqual(store.secondsUntilNextAutomationCheck(now: at(21, 28, 30)), 90, accuracy: 0.001)
        // Never a busy loop at the boundary.
        XCTAssertGreaterThanOrEqual(store.secondsUntilNextAutomationCheck(now: at(21, 29, 59)), 1)
    }
}
