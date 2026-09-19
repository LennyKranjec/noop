import Foundation
import XCTest
@testable import StrandAnalytics

/// F6 — `LocalDayWindows.trailingWindows(count:)`, the per-day scan `IntelligenceEngine` now walks instead of
/// stepping back from today's midnight in fixed 86,400-second blocks under ONE (today's) UTC offset.
///
/// Two properties matter: on a stretch with no transition the scan is EXACTLY the old arithmetic (so no
/// user's history moves outside a DST week), and across a transition each day starts at its own local
/// midnight with its own offset (so the far side of the transition is no longer an hour off).
final class LocalDayWindowsScanTests: XCTestCase {

    private func utc(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// The incumbent arithmetic, re-derived inline: floor `now` to a local midnight with the offset in
    /// effect at `now`, then subtract whole days.
    private func fixedOffsetStarts(now: Date, zone: TimeZone, count: Int) -> [Int] {
        let offset = zone.secondsFromGMT(for: now)
        let ts = Int(now.timeIntervalSince1970)
        let local = ts + offset
        let r = local % 86_400
        let floorMod = (r != 0 && r < 0) ? r + 86_400 : r
        let midnight = ts - floorMod
        return (0..<count).map { midnight - $0 * 86_400 }
    }

    func testNoTransitionStretchIsIdenticalToFixedOffsetArithmetic() {
        // A fixed-offset zone has no transitions at all: every window must match the old arithmetic.
        let zone = TimeZone(secondsFromGMT: -4 * 3600)!
        let now = utc("2021-06-16T01:00:00Z")   // 21:00 local on 2021-06-15
        let scan = LocalDayWindows(timeZone: zone, referenceInstant: now).trailingWindows(count: 21)

        XCTAssertEqual(scan.count, 21)
        XCTAssertEqual(scan.map { Int($0.start.timeIntervalSince1970) },
                       fixedOffsetStarts(now: now, zone: zone, count: 21))
        XCTAssertTrue(scan.allSatisfy { $0.utcOffsetSeconds == -4 * 3600 && $0.duration == 86_400 })
        XCTAssertEqual(scan.first?.date.key, "2021-06-15")   // newest first
        XCTAssertEqual(scan.last?.date.key, "2021-05-26")
    }

    func testDaylightSavingZoneAwayFromATransitionIsIdentical() {
        // Berlin in high summer: 21 days entirely inside CEST, so the scan equals the old arithmetic.
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let now = utc("2025-07-20T10:00:00Z")
        let scan = LocalDayWindows(timeZone: zone, referenceInstant: now).trailingWindows(count: 21)

        XCTAssertEqual(scan.map { Int($0.start.timeIntervalSince1970) },
                       fixedOffsetStarts(now: now, zone: zone, count: 21))
        XCTAssertTrue(scan.allSatisfy { $0.utcOffsetSeconds == 7200 })
    }

    func testAcrossSpringForwardEachDayKeepsItsOwnMidnightAndOffset() {
        // Europe/Berlin springs forward on 2025-03-30 (CET +1h → CEST +2h). Scanning from 2025-04-02:
        let zone = TimeZone(identifier: "Europe/Berlin")!
        let now = utc("2025-04-02T10:00:00Z")
        let scan = LocalDayWindows(timeZone: zone, referenceInstant: now).trailingWindows(count: 6)
        let byKey = Dictionary(uniqueKeysWithValues: scan.map { ($0.date.key, $0) })

        // After the transition: local midnight is 22:00Z with a +2h offset (same as the old arithmetic).
        XCTAssertEqual(byKey["2025-03-31"]?.start, utc("2025-03-30T22:00:00Z"))
        XCTAssertEqual(byKey["2025-03-31"]?.utcOffsetSeconds, 7200)
        // The transition day itself is 23 hours long and starts in CET.
        XCTAssertEqual(byKey["2025-03-30"]?.start, utc("2025-03-29T23:00:00Z"))
        XCTAssertEqual(byKey["2025-03-30"]?.duration, 23 * 3600)
        XCTAssertEqual(byKey["2025-03-30"]?.utcOffsetSeconds, 3600)
        // Before it: midnight is 23:00Z (+1h). The old arithmetic put this day at 22:00Z — an hour early.
        XCTAssertEqual(byKey["2025-03-29"]?.start, utc("2025-03-28T23:00:00Z"))
        XCTAssertEqual(byKey["2025-03-29"]?.utcOffsetSeconds, 3600)
        let old = fixedOffsetStarts(now: now, zone: zone, count: 6)
        XCTAssertEqual(old[4], Int(utc("2025-03-28T22:00:00Z").timeIntervalSince1970))
        XCTAssertNotEqual(Int(byKey["2025-03-29"]!.start.timeIntervalSince1970), old[4])

        // Newest first, and consecutive windows meet exactly (no gap, no overlap).
        XCTAssertEqual(scan.map { $0.date.key },
                       ["2025-04-02", "2025-04-01", "2025-03-31", "2025-03-30", "2025-03-29", "2025-03-28"])
        for i in 1..<scan.count {
            XCTAssertEqual(scan[i].nextStart, scan[i - 1].start)
        }
    }

    func testZeroCountIsEmpty() {
        let helper = LocalDayWindows(timeZone: TimeZone(identifier: "UTC")!, referenceInstant: Date())
        XCTAssertTrue(helper.trailingWindows(count: 0).isEmpty)
    }
}
