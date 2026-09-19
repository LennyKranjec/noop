import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// A past level is written once and never moves. Four claims are pinned: an entry cannot be overwritten
/// (not even through a reopened file), a day is only written on time once ALL of its night is in, a night
/// that never fully lands is written at the deadline marked partial, and a NaN input cannot stop a day
/// from being stored.
final class LevelLedgerTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        super.tearDown()
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LevelLedgerTests-\(UUID().uuidString).json")
        files.append(url)
        return url
    }

    private func defaults() throws -> UserDefaults {
        let d = try XCTUnwrap(UserDefaults(suiteName: "LevelLedgerTests"))
        d.removePersistentDomain(forName: "LevelLedgerTests")
        return d
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func level(_ day: String, _ value: Double) -> FrozenLevel {
        FrozenLevel(day: day,
                    breakdown: LevelBreakdown(components: [LevelComponent(part: .sleep, score: value, effectiveWeight: 1)],
                                              raw: value, stepPenalty: 1, level: value, coverage: 1),
                    drivers: [:], computedAt: Date(timeIntervalSince1970: 1_789_000_000))
    }

    /// A fully landed night: HRV, resting HR, total sleep, deep and REM.
    private func fullRow(_ day: Int, deep: Double? = 90, resp: Double? = nil) -> DailyMetric {
        DailyMetric(day: String(format: "2026-09-%02d", day), totalSleepMin: 450, efficiency: nil,
                    deepMin: deep, remMin: 100, lightMin: nil, disturbances: nil, restingHr: 55,
                    avgHrv: 60, recovery: nil, strain: nil, exerciseCount: nil, respRateBpm: resp, steps: 9_000)
    }

    private func timings(_ days: ClosedRange<Int>) -> [String: SleepTiming] {
        var out: [String: SleepTiming] = [:]
        for d in days { out[String(format: "2026-09-%02d", d)] = SleepTiming(onsetMinute: 23 * 60, wakeMinute: 7 * 60) }
        return out
    }

    // MARK: - Immutability

    func testAWrittenDayIsNeverOverwritten() throws {
        let url = tempURL()
        let d = try defaults()
        let ledger = LevelLedger(fileURL: url, legacy: d)
        let first = level("2026-09-16", 61)
        XCTAssertTrue(ledger.write(first))
        // A later sync scores the same day higher: the ledger keeps what it had.
        XCTAssertFalse(ledger.write(level("2026-09-16", 74)))
        XCTAssertEqual(ledger.commit([.level(level("2026-09-16", 80)), .empty("2026-09-16")]), 0)
        XCTAssertEqual(ledger.entry("2026-09-16"), first)
        ledger.markBackfilled()

        // And from disk, in a fresh process.
        let reopened = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(reopened.entry("2026-09-16"), first)
        XCTAssertTrue(reopened.hasBackfilled)
        XCTAssertFalse(reopened.write(level("2026-09-16", 90)))
        XCTAssertEqual(reopened.entry("2026-09-16")?.level, 61)
    }

    func testTheOldFrozenDayIsCarriedIntoTheLedgerOnce() throws {
        let d = try defaults()
        let old = level("2026-09-15", 58)
        d.set(try JSONEncoder().encode(old), forKey: LevelDayFreeze.legacyKey)
        let ledger = LevelLedger(fileURL: tempURL(), legacy: d)
        XCTAssertEqual(ledger.entry("2026-09-15")?.level, 58)
        XCTAssertNil(d.data(forKey: LevelDayFreeze.legacyKey))
    }

    func testGapsAndNeighboursReadOnlyWhatWasWritten() {
        let ledger = LevelLedger(fileURL: nil, legacy: UserDefaults(suiteName: "LevelLedgerTests.gaps")!)
        ledger.write(level("2026-09-10", 50))
        ledger.write(level("2026-09-12", 55))
        ledger.commit([.empty("2026-09-13")])
        XCTAssertNil(ledger.entry("2026-09-11"))
        XCTAssertTrue(ledger.isSettled("2026-09-13"))
        XCTAssertEqual(ledger.latest(onOrBefore: "2026-09-14")?.day, "2026-09-12")
        XCTAssertEqual(ledger.entries(from: "2026-09-01", through: "2026-09-30").map(\.day),
                       ["2026-09-10", "2026-09-12"])
    }

    // MARK: - Readiness

    func testAPartialNightIsNotReadyAndAFullOneIs() {
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))
        // HRV, resting HR and sleep are in, but the stages are not: the night has not landed.
        var days = (10...15).map { fullRow($0) }
        days.append(fullRow(16, deep: nil))
        XCTAssertFalse(LevelLedger.isReady(day: "2026-09-16", byDay: LevelWiring.byDay(days), series: series,
                                           calendar: calendar))
        XCTAssertEqual(LevelLedger.nightMissing(day: "2026-09-16", byDay: LevelWiring.byDay(days), series: series,
                                                calendar: calendar), ["deep"])

        // The full row is ready.
        days[days.count - 1] = fullRow(16)
        XCTAssertTrue(LevelLedger.isReady(day: "2026-09-16", byDay: LevelWiring.byDay(days), series: series,
                                          calendar: calendar))

        // Without bed and wake times it is not.
        let noTiming = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...15))
        XCTAssertFalse(LevelLedger.isReady(day: "2026-09-16", byDay: LevelWiring.byDay(days), series: noTiming,
                                           calendar: calendar))
    }

    func testTheBreathingRateIsRequiredOnlyWhereTheHistoryHasIt() {
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))
        var days = (10...15).map { fullRow($0, resp: 14) }
        days.append(fullRow(16))
        XCTAssertEqual(LevelLedger.nightMissing(day: "2026-09-16", byDay: LevelWiring.byDay(days), series: series,
                                                calendar: calendar), ["respRate"])
        // A source that never records it is not held to it.
        let never = (10...16).map { fullRow($0) }
        XCTAssertTrue(LevelLedger.isReady(day: "2026-09-16", byDay: LevelWiring.byDay(never), series: series,
                                          calendar: calendar))
    }

    // MARK: - Deadline

    func testTheDeadlineIsTwoInTheAfternoonOrTheNextMorningsFlow() {
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                  now: at(16, 13, 59), calendar: calendar))
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                 now: at(16, 14, 0), calendar: calendar))
        // The next morning's flow has begun: the day before is due whatever the hour.
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-17",
                                                 now: at(17, 6, 0), calendar: calendar))
    }

    func testAPartialNightWaitsThenIsWrittenAtTheDeadlineMarkedPartial() throws {
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))
        var days = (10...15).map { fullRow($0) }
        days.append(fullRow(16, deep: nil))
        let byDay = LevelWiring.byDay(days)

        // Before the deadline: wait for the rest of the night.
        XCTAssertNil(LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                        baselines: LevelBaselines.table, calendar: calendar,
                                        deadlinePassed: false, now: at(16, 9, 0)))

        // At the deadline: written with what there is, partial, and saying what it went without.
        let settled = LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                         baselines: LevelBaselines.table, calendar: calendar,
                                         deadlinePassed: true, now: at(16, 14, 0))
        guard case .level(let written)? = settled else { return XCTFail("expected a level, got \(String(describing: settled))") }
        XCTAssertTrue(written.partial)
        XCTAssertEqual(written.day, "2026-09-16")
        XCTAssertTrue(written.missingInputs.contains(.vo2max))

        // A full night is written on time, not partial.
        let full = LevelWiring.byDay((10...16).map { fullRow($0) })
        guard case .level(let onTime)? = LevelLedger.settle(day: "2026-09-16", byDay: full, series: series,
                                                            baselines: LevelBaselines.table, calendar: calendar,
                                                            deadlinePassed: false, now: at(16, 9, 0))
        else { return XCTFail("a landed night should be written before the deadline") }
        XCTAssertFalse(onTime.partial)
    }

    // MARK: - NaN

    func testANaNLevelIsCleanedAndStillStored() throws {
        let broken = LevelBreakdown(
            components: [LevelComponent(part: .sleep, score: 70, effectiveWeight: 0.5),
                         LevelComponent(part: .lungs, score: .nan, effectiveWeight: 0.5)],
            raw: .nan, stepPenalty: 1, level: .nan, coverage: .infinity)
        let frozen = FrozenLevel(day: "2026-09-16", breakdown: broken, drivers: [:])
        XCTAssertTrue(frozen.level.isFinite)
        XCTAssertEqual(frozen.level, 70, accuracy: 1e-9)
        XCTAssertNil(frozen.parts[1].score)
        XCTAssertEqual(frozen.coverage, 0)
        XCTAssertNoThrow(try JSONEncoder().encode(frozen))

        let url = tempURL()
        let d = try defaults()
        XCTAssertTrue(LevelLedger(fileURL: url, legacy: d).write(frozen))
        XCTAssertEqual(LevelLedger(fileURL: url, legacy: d).entry("2026-09-16")?.level ?? 0, 70, accuracy: 1e-9)
    }

    func testANaNInputIsTreatedAsMissingNotAsAScore() throws {
        let series = LevelSeries(vo2max: [(day: "2026-09-10", value: .nan)], muscleByDay: [:], meditation: [:],
                                 sleepTimings: timings(10...16),
                                 strengthIndex: [(day: "2026-09-12", value: .infinity)])
        let byDay = LevelWiring.byDay((10...16).map { fullRow($0) })
        guard case .level(let written)? = LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                                             baselines: LevelBaselines.table, calendar: calendar,
                                                             deadlinePassed: true)
        else { return XCTFail("expected a level") }
        XCTAssertTrue(written.level.isFinite)
        XCTAssertTrue(written.missingInputs.contains(.vo2max))
        XCTAssertTrue(written.missingInputs.contains(.strength))
        XCTAssertNoThrow(try JSONEncoder().encode(written))
    }
}
