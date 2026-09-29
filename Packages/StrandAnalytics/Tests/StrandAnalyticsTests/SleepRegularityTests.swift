import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 S2 §2.5 — the one canonical regularity.
final class SleepRegularityTests: XCTestCase {

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func keys(_ count: Int, endingOn end: String = "2026-09-28") -> [String] {
        let parts = end.split(separator: "-").map { Int($0)! }
        let last = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))!
        return (0..<count).reversed().map { back in
            let d = utc.date(byAdding: .day, value: -back, to: last)!
            let c = utc.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
    }

    /// SplitMix64, so the "random sleep" runs are the same on every machine.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func coin() -> Bool { next() & 1 == 1 }
    }

    /// Asleep 00:00–07:00 and 23:00–24:00 each day.
    private func regularDay(_ key: String, coverage: Double = 1) -> SleepRegularity.DayMinutes {
        SleepRegularity.dayMinutes(day: key, sleepBlocks: [(0, 7 * 60), (23 * 60, 24 * 60)], coverage: coverage)
    }

    // MARK: - SRI

    func testIdenticalDaysScoreOneHundred() throws {
        let days = keys(8).map { regularDay($0) }
        XCTAssertEqual(try XCTUnwrap(SleepRegularity.sri(days)), 100, accuracy: 1e-9)
    }

    func testIndependentRandomSleepScoresAboutZero() throws {
        for seed in UInt64(1)...5 {
            var rng = SplitMix64(state: seed)
            let days = keys(14).map { key -> SleepRegularity.DayMinutes in
                // 144 independent ten-minute blocks, each asleep with probability ½.
                var blocks: [(start: Int, end: Int)] = []
                for b in 0..<144 where rng.coin() { blocks.append((start: b * 10, end: b * 10 + 10)) }
                return SleepRegularity.dayMinutes(day: key, sleepBlocks: blocks, coverage: 1)
            }
            let sri = try XCTUnwrap(SleepRegularity.sri(days))
            XCTAssertEqual(sri, 0, accuracy: 10, "seed \(seed)")
        }
    }

    func testLowCoverageDaysAreExcludedFromPairsNotReadAsAwake() throws {
        var days = keys(10).map { regularDay($0) }
        // Day 5 was barely worn: all "awake" in the data. It must not drag the index down.
        days[5] = SleepRegularity.DayMinutes(day: days[5].day,
                                              asleep: Array(repeating: false, count: 1440), coverage: 0.5)
        XCTAssertEqual(try XCTUnwrap(SleepRegularity.sri(days)), 100, accuracy: 1e-9)
        // With only 8 days, losing two pairs leaves 5 — fewer than 7 — so there is no index at all.
        var short = keys(8).map { regularDay($0) }
        short[4] = SleepRegularity.DayMinutes(day: short[4].day, asleep: short[4].asleep, coverage: 0.2)
        XCTAssertNil(SleepRegularity.sri(short))
    }

    // MARK: - Spread

    func testWakeSdIsCircular() throws {
        let ns = zip(keys(8), [23 * 60 + 50, 10, 23 * 60 + 50, 10, 23 * 60 + 50, 10, 23 * 60 + 50, 10]).map {
            SleepTimingNight(wakeDay: $0.0, onsetMin: 16 * 60, wakeMin: $0.1)
        }
        let sd = try XCTUnwrap(SleepRegularity.wakeSdMin(ns))
        XCTAssertLessThan(sd, 15, "23:50 and 00:10 are twenty minutes apart, not twenty-three hours")
        XCTAssertNil(SleepRegularity.wakeSdMin(Array(ns.prefix(6))), "needs seven nights")
    }

    func testMidsleepWrapsAcrossMidnight() {
        XCTAssertEqual(SleepRegularity.midsleepMin(onsetMin: 23 * 60 + 30, wakeMin: 7 * 60 + 30), 3.5 * 60, accuracy: 1e-9)
        XCTAssertEqual(SleepRegularity.midsleepMin(onsetMin: 30, wakeMin: 8 * 60 + 30), 4.5 * 60, accuracy: 1e-9)
    }

    // MARK: - Social jet lag

    func testSocialJetlagAbstainsWithoutEnoughWeekendNights() throws {
        // 2026-09-21 (Mon) … 2026-09-25 (Fri): five work nights, no free ones.
        let work = keys(5, endingOn: "2026-09-25").map {
            SleepTimingNight(wakeDay: $0, onsetMin: 23 * 60, wakeMin: 7 * 60)
        }
        XCTAssertNil(SleepRegularity.socialJetlagMin(work))
        XCTAssertTrue(SleepRegularity.evaluate(nights: work).reasons.contains(.tooFewFreeNights))
        // Add the weekend, sleeping 90 minutes later: the jet lag is those 90 minutes.
        let weekend = ["2026-09-26", "2026-09-27"].map {
            SleepTimingNight(wakeDay: $0, onsetMin: 30, wakeMin: 8 * 60 + 30)
        }
        XCTAssertEqual(try XCTUnwrap(SleepRegularity.socialJetlagMin(work + weekend)), 90, accuracy: 0.5)
    }
}
