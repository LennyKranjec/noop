import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// A past level is written once and never moves. The claims pinned: an entry cannot be overwritten (not
/// even through a reopened file), a day is only written on time once ALL of its night is in and over, a
/// night that never fully lands is written at the deadline marked partial (a past day only once a pass has
/// completed since that deadline, a day with no row only once a later day has one), a NaN input cannot
/// stop a day from being stored, a ledger from before the re-score is emptied exactly once, and a file
/// that will not read is never overwritten.
final class LevelLedgerTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private var files: [URL] = []

    private static let suites = ["LevelLedgerTests", "LevelLedgerTests.gaps"]

    override func tearDown() {
        for url in files {
            try? FileManager.default.removeItem(at: url)
            for aside in asides(of: url) { try? FileManager.default.removeItem(at: aside) }
        }
        files = []
        for suite in Self.suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    /// The copies of a ledger file that were put aside, beside it.
    private func asides(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.map { dir.appendingPathComponent($0) }
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

    func testTheDeadlineIsTwoInTheAfternoonAndAPastDayWaitsForAPassAfterIt() {
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                  now: at(16, 13, 59), calendar: calendar))
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                 now: at(16, 14, 0), calendar: calendar))
        // The next morning's flow has begun, but no pass has completed since the day's deadline: its night
        // may still be on the strap, so it is not written yet.
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-17",
                                                  now: at(17, 6, 0), calendar: calendar))
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-17",
                                                  now: at(17, 6, 0), calendar: calendar,
                                                  lastCompletedPass: at(16, 13, 0)))
        // A pass completed after it: due.
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-17",
                                                 now: at(17, 6, 0), calendar: calendar,
                                                 lastCompletedPass: at(16, 20, 0)))
        // Past on the calendar though still the level day (the morning flow has not run): the same rule.
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                  now: at(17, 9, 0), calendar: calendar))
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16",
                                                 now: at(17, 9, 0), calendar: calendar,
                                                 lastCompletedPass: at(17, 8, 0)))
    }

    func testALateMorningFlowMovesTheDeadlineTwoHoursPastIt() {
        // An early start keeps 14:00.
        XCTAssertEqual(LevelLedger.deadline(day: "2026-09-16", beganAt: at(16, 9, 0), calendar: calendar),
                       at(16, 14, 0))
        XCTAssertEqual(LevelLedger.deadline(day: "2026-09-16", beganAt: nil, calendar: calendar), at(16, 14, 0))
        // A start at 13:00 gives the night until 15:00.
        XCTAssertEqual(LevelLedger.deadline(day: "2026-09-16", beganAt: at(16, 13, 0), calendar: calendar),
                       at(16, 15, 0))
        // The first open at 23:00: not written on the spot, but at 01:00.
        let late = at(16, 23, 0)
        XCTAssertEqual(LevelLedger.deadline(day: "2026-09-16", beganAt: late, calendar: calendar), at(17, 1, 0))
        XCTAssertFalse(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16", now: at(16, 23, 5),
                                                  calendar: calendar, beganAt: late,
                                                  lastCompletedPass: at(16, 23, 4)))
        XCTAssertTrue(LevelLedger.deadlinePassed(day: "2026-09-16", levelDay: "2026-09-16", now: at(17, 1, 30),
                                                 calendar: calendar, beganAt: late,
                                                 lastCompletedPass: at(17, 1, 10)))
    }

    func testTheDeadlineIsTwoOnTheClockOnADaylightSavingDay() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        // The clocks go forward on 29 March 2026 and back on 25 October: fourteen hours after midnight is
        // 15:00 on the first and 13:00 on the second. The deadline is 14:00 on both.
        for day in ["2026-03-29", "2026-10-25"] {
            let deadline = try XCTUnwrap(LevelLedger.deadline(day: day, calendar: berlin))
            let c = berlin.dateComponents([.hour, .minute], from: deadline)
            XCTAssertEqual(c.hour, 14, day)
            XCTAssertEqual(c.minute, 0, day)
            XCTAssertEqual(LevelWiring.key(from: deadline, calendar: berlin), day)
        }
    }

    // MARK: - Settling gates

    func testNothingIsSettledBeforeTheRescoreOrWhileTheStoreIsBeingWritten() {
        XCTAssertFalse(LevelLedger.maySettle(rescoreDone: false, dataInFlight: false))
        XCTAssertFalse(LevelLedger.maySettle(rescoreDone: true, dataInFlight: true))
        XCTAssertFalse(LevelLedger.maySettle(rescoreDone: false, dataInFlight: true))
        XCTAssertTrue(LevelLedger.maySettle(rescoreDone: true, dataInFlight: false))
    }

    func testANightIsNotReadyUntilHalfAnHourAfterWaking() {
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))
        let byDay = LevelWiring.byDay((10...16).map { fullRow($0) })
        // Woke at 07:00: every figure is in, but the night's last stretch is still being scored.
        XCTAssertFalse(LevelLedger.isReady(day: "2026-09-16", byDay: byDay, series: series, calendar: calendar,
                                           now: at(16, 7, 20)))
        XCTAssertEqual(LevelLedger.nightMissing(day: "2026-09-16", byDay: byDay, series: series,
                                                calendar: calendar, now: at(16, 7, 20)), ["wakeSettling"])
        XCTAssertNil(LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                        baselines: LevelBaselines.table, calendar: calendar,
                                        deadlinePassed: false, now: at(16, 7, 20)))
        XCTAssertTrue(LevelLedger.isReady(day: "2026-09-16", byDay: byDay, series: series, calendar: calendar,
                                          now: at(16, 7, 31)))
    }

    func testADayWithNoRowClosesOnlyOnceALaterDayHasOneAndTwoDaysHavePassed() throws {
        let deadline = at(16, 14, 0)
        // A day with a row is never held back by this.
        XCTAssertTrue(LevelLedger.absentNightMayClose(hasRow: true, newestRowDay: nil, day: "2026-09-16",
                                                      deadline: deadline, now: deadline))
        // No row and nothing after it: the sync has not got this far.
        XCTAssertFalse(LevelLedger.absentNightMayClose(hasRow: false, newestRowDay: "2026-09-15", day: "2026-09-16",
                                                       deadline: deadline, now: at(19, 14, 0)))
        XCTAssertFalse(LevelLedger.absentNightMayClose(hasRow: false, newestRowDay: nil, day: "2026-09-16",
                                                       deadline: deadline, now: at(19, 14, 0)))
        // A later row, but not yet 48 hours past the deadline.
        XCTAssertFalse(LevelLedger.absentNightMayClose(hasRow: false, newestRowDay: "2026-09-17", day: "2026-09-16",
                                                       deadline: deadline, now: at(18, 13, 0)))
        // A later row and 48 hours: it may close.
        XCTAssertTrue(LevelLedger.absentNightMayClose(hasRow: false, newestRowDay: "2026-09-17", day: "2026-09-16",
                                                      deadline: deadline, now: at(18, 14, 0)))

        // And `settle` honours it: past the deadline, a day with no row writes nothing, not even a gap,
        // until it may close.
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...15))
        let byDay = LevelWiring.byDay((10...15).map { fullRow($0) })
        XCTAssertNil(LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                        baselines: LevelBaselines.table, calendar: calendar,
                                        deadlinePassed: true, now: at(17, 9, 0), absentNightMayClose: false))
        XCTAssertNotNil(LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                           baselines: LevelBaselines.table, calendar: calendar,
                                           deadlinePassed: true, now: at(18, 14, 0), absentNightMayClose: true))
    }

    // MARK: - Epoch

    /// The ledger as commit 40a774fb wrote it: backfilled, no epoch.
    private struct PreEpochFile: Encodable {
        let entries: [String: FrozenLevel]
        let empty: [String]
        let backfilled: Bool
    }

    func testABackfilledLedgerFromBeforeTheRescoreIsEmptiedOnceWithItsBaselines() throws {
        let url = tempURL()
        let d = try defaults()
        try JSONEncoder().encode(PreEpochFile(entries: ["2026-09-16": level("2026-09-16", 61)],
                                              empty: ["2026-09-12"], backfilled: true)).write(to: url)
        let ledger = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(ledger.epoch, 0)
        XCTAssertTrue(ledger.hasBackfilled)
        XCTAssertEqual(ledger.entry("2026-09-16")?.level, 61)

        // Not before the nights have been re-scored.
        var refrozen = 0
        XCTAssertFalse(ledger.adoptCurrentEpochIfNeeded(rescoreDone: false) { refrozen += 1 })
        XCTAssertEqual(refrozen, 0)
        XCTAssertEqual(ledger.entry("2026-09-16")?.level, 61)

        // After: the baselines are frozen again, then every day goes and the epoch is stamped.
        XCTAssertTrue(ledger.adoptCurrentEpochIfNeeded(rescoreDone: true) { refrozen += 1 })
        XCTAssertEqual(refrozen, 1)
        XCTAssertNil(ledger.entry("2026-09-16"))
        XCTAssertFalse(ledger.isSettled("2026-09-12"))
        XCTAssertFalse(ledger.hasBackfilled)
        XCTAssertEqual(ledger.epoch, LevelLedger.currentEpoch)

        // Once only, and it holds on disk: the days written after it are never emptied again.
        XCTAssertTrue(ledger.write(level("2026-09-17", 64)))
        let reopened = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(reopened.epoch, LevelLedger.currentEpoch)
        XCTAssertFalse(reopened.adoptCurrentEpochIfNeeded(rescoreDone: true) { refrozen += 1 })
        XCTAssertEqual(refrozen, 1)
        XCTAssertEqual(reopened.entry("2026-09-17")?.level, 64)
        XCTAssertNil(reopened.entry("2026-09-16"))
    }

    func testTheSettledSpanIsKeptAndOnlyMovesForward() throws {
        let url = tempURL()
        let d = try defaults()
        let ledger = LevelLedger(fileURL: url, legacy: d)
        XCTAssertNil(ledger.settledSpan)
        ledger.markSettled(from: "2026-09-01", through: "2026-09-15")
        ledger.markSettled(from: "2026-09-01", through: "2026-09-10")
        let reopened = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(reopened.settledSpan?.from, "2026-09-01")
        XCTAssertEqual(reopened.settledSpan?.through, "2026-09-15")
        reopened.resetAll(epoch: LevelLedger.currentEpoch)
        XCTAssertNil(reopened.settledSpan)
    }

    // MARK: - A file that will not read

    func testALedgerFileThatIsNotALedgerIsPutAsideAndNeverOverwritten() throws {
        let url = tempURL()
        let d = try defaults()
        let garbage = Data("{ not a ledger".utf8)
        try garbage.write(to: url)
        let ledger = LevelLedger(fileURL: url, legacy: d)
        XCTAssertFalse(ledger.isWritable)
        XCTAssertFalse(ledger.write(level("2026-09-16", 61)))
        XCTAssertNil(ledger.entry("2026-09-16"))
        // Moved aside, as it was, rather than saved over.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let aside = asides(of: url)
        XCTAssertEqual(aside.count, 1)
        if let first = aside.first { XCTAssertEqual(try Data(contentsOf: first), garbage) }
        // The next launch starts a fresh one.
        XCTAssertTrue(LevelLedger(fileURL: url, legacy: d).isWritable)
    }

    func testOneBadEntryCostsOneDayNotTheLedger() throws {
        let url = tempURL()
        let d = try defaults()
        let good = try JSONSerialization.jsonObject(with: JSONEncoder().encode(level("2026-09-16", 61)))
        let file: [String: Any] = [
            "entries": ["2026-09-16": good, "2026-09-17": ["day": "2026-09-17"]] as [String: Any],
            "empty": ["2026-09-12"],
            "backfilled": true,
            "epoch": LevelLedger.currentEpoch,
        ]
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let ledger = LevelLedger(fileURL: url, legacy: d)
        XCTAssertTrue(ledger.isWritable)
        XCTAssertEqual(ledger.entry("2026-09-16")?.level, 61)
        XCTAssertNil(ledger.entry("2026-09-17"))
        XCTAssertTrue(ledger.isSettled("2026-09-12"))
        XCTAssertTrue(ledger.hasBackfilled)
        XCTAssertEqual(ledger.epoch, LevelLedger.currentEpoch)
        // The file as it was is kept beside it.
        XCTAssertEqual(asides(of: url).count, 1)
    }

    func testTheOldFrozenDayIsKeptUntilTheLedgerIsSaved() throws {
        let d = try defaults()
        d.set(try JSONEncoder().encode(level("2026-09-15", 58)), forKey: LevelDayFreeze.legacyKey)
        // A directory that does not exist: the save fails.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LevelLedgerTests-missing-" + UUID().uuidString)
            .appendingPathComponent("level_ledger.json")
        let ledger = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(ledger.entry("2026-09-15")?.level, 58)
        XCTAssertNotNil(d.data(forKey: LevelDayFreeze.legacyKey))
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
