import XCTest
@testable import WhoopStore

/// `upsertAppleDaily(coalesceNulls:)` — what a NIL column means on a row that already exists.
///
/// The live HealthKit reader used to upsert with `steps = excluded.steps` on every column, a full
/// replace. HealthKit never reveals READ authorization and answers a declined, partially-granted or
/// transiently-failing read with an EMPTY result rather than an error, so one bad read wrote NULL over
/// that day's stored steps, calories, VO₂max and weight — the user watched real figures turn into "—".
///
/// The file/export importers must keep the replace semantic: they parse a complete dump, so a nil there
/// genuinely means "no value in this export" and has to clear a stale one. Hence the flag, and hence
/// both directions are pinned here.
final class AppleDailyCoalesceTests: XCTestCase {

    private func full(_ day: String) -> AppleDaily {
        AppleDaily(day: day, steps: 9_123, activeKcal: 540.2, basalKcal: 1_600, vo2max: 48.5,
                   avgHr: 62, maxHr: 171, walkingHr: 98, weightKg: 78.4)
    }

    private func allNil(_ day: String) -> AppleDaily {
        AppleDaily(day: day, steps: nil, activeKcal: nil, basalKcal: nil, vo2max: nil,
                   avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
    }

    private func row(_ store: WhoopStore, _ day: String) async throws -> AppleDaily {
        let rows = try await store.appleDaily(deviceId: "devA", from: day, to: day)
        return try XCTUnwrap(rows.first)
    }

    /// THE REGRESSION: a read that came back empty must not erase what is stored.
    func testCoalescingUpsertKeepsStoredValuesWhenTheReadCameBackEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-05-23"
        try await store.upsertAppleDaily([full(day)], deviceId: "devA")

        // A whole sync's worth of failed/denied reads: every column nil.
        try await store.upsertAppleDaily([allNil(day)], deviceId: "devA", coalesceNulls: true)

        let kept = try await row(store, day)
        XCTAssertEqual(kept, full(day), "an all-nil coalescing upsert must change nothing")
    }

    /// Coalescing is not "ignore the row": a value that DID read still lands, and only the nil
    /// neighbours are left alone. (A partial grant — steps yes, weight no — is the common real case.)
    func testCoalescingUpsertStillAppliesTheValuesThatDidRead() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-05-24"
        try await store.upsertAppleDaily([full(day)], deviceId: "devA")

        let partial = AppleDaily(day: day, steps: 12_000, activeKcal: nil, basalKcal: nil, vo2max: nil,
                                 avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: 77.0)
        try await store.upsertAppleDaily([partial], deviceId: "devA", coalesceNulls: true)

        let merged = try await row(store, day)
        XCTAssertEqual(merged.steps, 12_000, "a value that read must win")
        XCTAssertEqual(merged.weightKg, 77.0)
        XCTAssertEqual(merged.activeKcal, 540.2, "a nil must leave the stored value alone")
        XCTAssertEqual(merged.vo2max, 48.5)
        XCTAssertEqual(merged.avgHr, 62)
        XCTAssertEqual(merged.maxHr, 171)
        XCTAssertEqual(merged.walkingHr, 98)
        XCTAssertEqual(merged.basalKcal, 1_600)
    }

    /// The DEFAULT is unchanged: a file/export importer's nil still clears, because for a complete dump
    /// a nil is a real absence rather than a failed read.
    func testDefaultUpsertStillReplacesWithNulls() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-05-25"
        try await store.upsertAppleDaily([full(day)], deviceId: "devA")

        try await store.upsertAppleDaily([allNil(day)], deviceId: "devA")

        let replaced = try await row(store, day)
        XCTAssertNil(replaced.steps)
        XCTAssertNil(replaced.activeKcal)
        XCTAssertNil(replaced.basalKcal)
        XCTAssertNil(replaced.vo2max)
        XCTAssertNil(replaced.avgHr)
        XCTAssertNil(replaced.maxHr)
        XCTAssertNil(replaced.walkingHr)
        XCTAssertNil(replaced.weightKg)
    }

    /// A day that does not exist yet is an INSERT either way, so coalescing cannot fabricate a value
    /// out of a row that was never there.
    func testCoalescingUpsertInsertsNilsOnAFreshDay() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-05-26"
        try await store.upsertAppleDaily([allNil(day)], deviceId: "devA", coalesceNulls: true)
        let fresh = try await row(store, day)
        XCTAssertNil(fresh.steps)
        XCTAssertNil(fresh.weightKg)
    }
}
