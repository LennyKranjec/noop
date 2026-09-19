import XCTest
@testable import Strand
import StrandAnalytics

/// #277 — IntelligenceEngine's LOCAL-midnight floor used to re-bucket daily metrics by the device's
/// local calendar day (the bucket the dashboard reads). Mirrors the Android
/// LocalDayBucketingTest.midnightLocal_* cases byte-for-byte in logic/constants.
final class LocalDayMidnightTests: XCTestCase {

    func testMidnightLocalFloorsToLocalMidnightWestOfUTC() {
        // UTC-4: local 21:00 on 2021-06-15 == 01:00 UTC 2021-06-16 == 1623805200. Local midnight is
        // 2021-06-15 00:00 local == 04:00 UTC == 1623729600.
        let offset = -4 * 3600
        let tsUtc = 1_623_805_200
        XCTAssertEqual(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset), 1_623_729_600)
        // The floored value, re-keyed under the same offset, is the local day.
        XCTAssertEqual(
            AnalyticsEngine.dayString(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset),
                                      offsetSec: offset),
            "2021-06-15")
    }

    func testMidnightLocalOffsetZeroEqualsMidnightUtc() {
        // floorMod-based local floor with offset 0 must equal the legacy UTC midnight floor for any sign.
        for ts in [1_609_459_200, 1_609_459_200 + 45_000, 0, 86_399, -1, -86_401] {
            XCTAssertEqual(IntelligenceEngine.midnightLocal(ts, offsetSec: 0),
                           IntelligenceEngine.midnightUtc(ts),
                           "midnightLocal(offset=0) must equal midnightUtc for ts=\(ts)")
        }
    }

    func testMidnightLocalNegativeOffsetSignCorrect() {
        // The floored local midnight must be <= ts and land exactly on a local-day boundary
        // (ts+offset divisible by 86400). Guards floorMod sign for negative offsets/timestamps.
        let offset = -5 * 3600 // UTC-5
        for ts in [1_623_805_200, 1_600_000_000, 100] {
            let mid = IntelligenceEngine.midnightLocal(ts, offsetSec: offset)
            let mod = ((mid + offset) % 86_400 + 86_400) % 86_400
            XCTAssertEqual(mod, 0, "must land on a local-day boundary")
            XCTAssertLessThanOrEqual(mid, ts, "midnight floor must not exceed ts")
            XCTAssertLessThan(ts - mid, 86_400, "floor must be within the same local day")
        }
    }

    // MARK: - F6: per-day scan

    /// On a stretch with no DST transition the per-day scan is EXACTLY the old single-offset arithmetic
    /// (`midnightLocal(now) - k*86400`, keyed with the one offset), so no non-DST history moves.
    func testLocalDayScanMatchesFixedOffsetArithmeticWithoutATransition() {
        let zone = TimeZone(secondsFromGMT: -4 * 3600)!
        let offset = -4 * 3600
        let now = 1_623_805_200   // 2021-06-15 21:00 local
        let scan = IntelligenceEngine.localDayScan(now: now, count: 21, timeZone: zone)
        let midnight = IntelligenceEngine.midnightLocal(now, offsetSec: offset)
        XCTAssertEqual(scan.count, 21)
        for (k, w) in scan.enumerated() {
            let start = Int(w.start.timeIntervalSince1970)
            XCTAssertEqual(start, midnight - k * 86_400)
            XCTAssertEqual(w.utcOffsetSeconds, offset)
            XCTAssertEqual(AnalyticsEngine.dayString(start, offsetSec: w.utcOffsetSeconds),
                           AnalyticsEngine.dayString(midnight - k * 86_400, offsetSec: offset))
            // A past 24 h day's read window ends exactly where the old fixed arithmetic ended it.
            XCTAssertEqual(IntelligenceEngine.sleepReadWindowEnd(
                               dayStart: start, nowLocalMidnight: midnight, now: now,
                               nextDayStart: Int(w.nextStart.timeIntervalSince1970)),
                           IntelligenceEngine.sleepReadWindowEnd(dayStart: start, nowLocalMidnight: midnight,
                                                                 now: now))
        }
    }

    /// Across a DST transition each day keeps its OWN local midnight: the day before Berlin's 2025-03-30
    /// spring-forward starts at 23:00Z (+1h), where the old arithmetic (today's +2h, minus whole days)
    /// put it at 22:00Z, and the 23-hour transition day's read window ends at the next day's real start.
    func testLocalDayScanAnchorsDaysBeyondATransitionToTheirOwnMidnight() {
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let now = 1_743_588_000   // 2025-04-02T10:00:00Z
        let scan = IntelligenceEngine.localDayScan(now: now, count: 6, timeZone: zone)
        let byKey = Dictionary(uniqueKeysWithValues: scan.map {
            (AnalyticsEngine.dayString(Int($0.start.timeIntervalSince1970), offsetSec: $0.utcOffsetSeconds), $0)
        })
        XCTAssertEqual(byKey["2025-03-29"].map { Int($0.start.timeIntervalSince1970) }, 1_743_202_800) // 23:00Z
        XCTAssertEqual(byKey["2025-03-29"]?.utcOffsetSeconds, 3600)
        let transition = byKey["2025-03-30"]!
        let tStart = Int(transition.start.timeIntervalSince1970)
        XCTAssertEqual(tStart, 1_743_289_200)                                                          // 23:00Z
        XCTAssertEqual(IntelligenceEngine.sleepReadWindowEnd(
                           dayStart: tStart, nowLocalMidnight: Int(scan[0].start.timeIntervalSince1970),
                           now: now, nextDayStart: Int(transition.nextStart.timeIntervalSince1970)),
                       tStart + 23 * 3600)
    }
}
