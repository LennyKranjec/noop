import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// THE MORNING'S LEVEL DOES NOT MOVE. The reported bug: "in the morning the level is still updated
/// several times; as soon as all the necessary data is there it must be computed ONCE for the whole day
/// and then stay fixed."
///
/// Every day in the ledger was already immutable, but the headline was not: while the level day itself
/// was unwritten the strip showed "the newest written day", read afresh on every load — and the ledger
/// legitimately gains days through the morning (yesterday at its deadline once an analysis pass has
/// completed after it, plus any older day the app was not opened on, in a walk that commits in batches).
/// So the figure stepped through two or three different frozen days before today's own level arrived.
///
/// What is pinned here: the stand-in is picked ONCE per level day and held — across later days landing,
/// across repeated reads and across a relaunch — the level day's own entry is the one and only move,
/// provisional and committed stay distinguishable, and a day already settled cannot be moved by an input
/// that changes afterwards.
final class LevelMorningStabilityTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let suite = "LevelMorningStabilityTests"

    private var files: [URL] = []

    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
        UserDefaults.standard.removePersistentDomain(forName: Self.suite)
        super.tearDown()
    }

    private func defaults() throws -> UserDefaults {
        let d = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        d.removePersistentDomain(forName: Self.suite)
        return d
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LevelMorningStabilityTests-\(UUID().uuidString).json")
        files.append(url)
        return url
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

    private func row(_ day: Int, deep: Double? = 90, rem: Double? = 100, hrv: Double? = 60,
                     rhr: Int? = 55, sleep: Double? = 450) -> DailyMetric {
        DailyMetric(day: String(format: "2026-09-%02d", day), totalSleepMin: sleep, efficiency: nil,
                    deepMin: deep, remMin: rem, lightMin: nil, disturbances: nil, restingHr: rhr,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil, respRateBpm: nil,
                    steps: 9_000)
    }

    private func timings(_ days: ClosedRange<Int>) -> [String: SleepTiming] {
        var out: [String: SleepTiming] = [:]
        for d in days { out[String(format: "2026-09-%02d", d)] = SleepTiming(onsetMinute: 23 * 60, wakeMinute: 7 * 60) }
        return out
    }

    // MARK: - One number while the level day waits

    /// The stand-in is chosen once. A day landing LATER in the same morning — yesterday written at its
    /// deadline, an older day the app was not opened on — does not become the new headline.
    func testTheStandInIsPickedOnceAndALaterDayLandingDoesNotMoveIt() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        ledger.write(level("2026-09-14", 61))

        // The morning of the 16th, today unwritten: the 14th stands in.
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-14")

        // Mid-morning the 15th is written at its deadline (an analysis pass has now completed after it),
        // and an older gap is backfilled. Neither moves what the strip is holding up.
        ledger.write(level("2026-09-15", 73))
        ledger.write(level("2026-09-13", 44))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-14")
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.level, 61)
    }

    /// Repeated reads — every refresh, every screen, every poll of the morning brief — give the identical
    /// entry, not merely an equal number.
    func testRepeatedReadsGiveTheIdenticalStandIn() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        let held = level("2026-09-15", 68)
        ledger.write(held)
        for _ in 0..<12 {
            XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d), held)
        }
    }

    /// A relaunch mid-morning recomputes nothing and re-picks nothing: the same stand-in comes back from
    /// disk, even though a newer day was written in between.
    func testARelaunchMidMorningHoldsTheSameStandIn() throws {
        let url = tempURL()
        let d = try defaults()
        let first = LevelLedger(fileURL: url, legacy: d)
        first.write(level("2026-09-14", 61))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: first, d)?.day, "2026-09-14")
        first.write(level("2026-09-15", 73))

        // A fresh process reads the ledger file and the held stand-in.
        let reopened = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(reopened.entry("2026-09-15")?.level, 73)
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: reopened, d)?.day, "2026-09-14")
    }

    /// The one move there is: the level day's OWN entry. Before it the state is provisional and says so;
    /// after it, it is not, and the composed read every surface does answers with today rather than with
    /// the stand-in it was holding.
    func testTheLevelDaysOwnEntryIsTheOnlyMoveAndIsDistinguishable() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        ledger.write(level("2026-09-15", 61))
        LevelDayFreeze.beginDay(now: at(16, 8, 0), calendar: calendar, d)

        // Provisional: what is shown is a stand-in, and `isPendingToday` says so.
        XCTAssertNil(ledger.entry("2026-09-16"))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-15")
        XCTAssertTrue(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(16, 8, 1), calendar: calendar, d))

        // Committed: today's own entry, and no longer pending.
        ledger.write(level("2026-09-16", 57))
        XCTAssertEqual(ledger.entry("2026-09-16")?.level, 57)
        XCTAssertFalse(LevelDayFreeze.isPendingToday(ledger: ledger, now: at(16, 8, 2), calendar: calendar, d))

        // THE COMMITTED DAY WINS OVER THE HELD STAND-IN. This is the read every surface does — the strip,
        // the timeline and the coach all take `entry(levelDay) ?? standIn(levelDay)` — so what is pinned
        // is the composed answer, not that the stand-in forgets itself. It is still held, harmlessly, and
        // simply never consulted again for this level day; holding it is what stops a day landing later in
        // the morning from becoming a new headline.
        let shown = ledger.entry("2026-09-16") ?? LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)
        XCTAssertEqual(shown?.day, "2026-09-16")
        XCTAssertEqual(shown?.level, 57)
        // And a stand-in is never the level day's OWN entry: asked for a level day that IS written but has
        // no stand-in held, it offers nothing rather than passing that day's level off as a stand-in for
        // itself. (Without the `day < levelDay` guard this would hand back the 15th's own level.)
        XCTAssertNil(LevelDayFreeze.standIn(levelDay: "2026-09-15", ledger: ledger, d))
    }

    /// Nothing written before the level day is no number at all — "–" — rather than a figure that will
    /// move. And nothing is latched, so the first day to land is picked cleanly.
    func testAnEmptyLedgerStandsInWithNothing() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        XCTAssertNil(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d))
        ledger.write(level("2026-09-15", 64))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-15")
    }

    /// A new recipe epoch empties the ledger, which is the one thing that may move a held stand-in: what
    /// it pointed at is gone, so it is picked again rather than leaving the strip on nothing.
    func testANewEpochEmptyingTheLedgerRepicksTheStandIn() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        ledger.write(level("2026-09-14", 61))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-14")
        ledger.resetAll(epoch: LevelLedger.currentEpoch)
        XCTAssertNil(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d))
        ledger.write(level("2026-09-15", 70))
        XCTAssertEqual(LevelDayFreeze.standIn(levelDay: "2026-09-16", ledger: ledger, d)?.day, "2026-09-15")
    }

    // MARK: - A committed day cannot be moved by later data

    /// ONE COMMIT PER DAY. The night lands, the day is written — and the same night re-scored from a fuller
    /// store (a deeper night, a better HRV, a lower resting HR) is refused, in memory and on disk. The
    /// second score is asserted to be genuinely different, so this pins the refusal and not inert inputs.
    func testADayIsWrittenOnceAndALaterInputChangeCannotMoveIt() throws {
        let url = tempURL()
        let d = try defaults()
        let ledger = LevelLedger(fileURL: url, legacy: d)
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))

        let asSynced = LevelWiring.byDay((10...16).map { row($0) })
        guard case .level(let first)? = LevelLedger.settle(day: "2026-09-16", byDay: asSynced, series: series,
                                                           baselines: LevelBaselines.table, calendar: calendar,
                                                           deadlinePassed: false, now: at(16, 8, 0))
        else { return XCTFail("a landed night should be written") }
        XCTAssertFalse(first.partial)
        XCTAssertEqual(ledger.commit([.level(first)]), 1)

        // The night grows: the sleep session is re-segmented and the cloud rewrites the row.
        var grown = (10...15).map { row($0) }
        grown.append(row(16, deep: 220, rem: 210, hrv: 130, rhr: 38, sleep: 600))
        guard case .level(let rescored)? = LevelLedger.settle(day: "2026-09-16", byDay: LevelWiring.byDay(grown),
                                                              series: series, baselines: LevelBaselines.table,
                                                              calendar: calendar, deadlinePassed: false,
                                                              now: at(16, 11, 0))
        else { return XCTFail("the re-scored night should still produce a level") }
        XCTAssertNotEqual(rescored.level, first.level, "the fixture must actually score differently")

        // Refused: the ledger keeps what it wrote, in this process and in the next one.
        XCTAssertEqual(ledger.commit([.level(rescored)]), 0)
        XCTAssertEqual(ledger.entry("2026-09-16"), first)
        let reopened = LevelLedger(fileURL: url, legacy: d)
        XCTAssertEqual(reopened.entry("2026-09-16")?.level ?? .nan, first.level, accuracy: 1e-9)
        XCTAssertFalse(reopened.write(rescored))
        XCTAssertEqual(reopened.entry("2026-09-16")?.level ?? .nan, first.level, accuracy: 1e-9)
    }

    /// Every attempt the morning makes — the launch load, each sync, the settle check booked at wake + half
    /// an hour, the deadline — lands on one entry, and the wearer's number is the first one written.
    func testManySettleAttemptsThroughTheMorningLeaveOneEntry() throws {
        let d = try defaults()
        let ledger = LevelLedger(fileURL: nil, legacy: d)
        let series = LevelSeries(vo2max: [], muscleByDay: [:], meditation: [:], sleepTimings: timings(10...16))
        let byDay = LevelWiring.byDay((10...16).map { row($0) })

        var committed = 0
        for hour in [8, 9, 10, 11, 12, 13, 14, 15] {
            guard case .level(let scored)? = LevelLedger.settle(day: "2026-09-16", byDay: byDay, series: series,
                                                                baselines: LevelBaselines.table, calendar: calendar,
                                                                deadlinePassed: hour >= 14, now: at(16, hour, 0))
            else { return XCTFail("a landed night should be written at \(hour):00") }
            committed += ledger.commit([.level(scored)])
        }
        XCTAssertEqual(committed, 1)
        XCTAssertEqual(ledger.entries(from: "2026-09-16", through: "2026-09-16").count, 1)
        XCTAssertEqual(ledger.entry("2026-09-16")?.computedAt, at(16, 8, 0))
    }
}
