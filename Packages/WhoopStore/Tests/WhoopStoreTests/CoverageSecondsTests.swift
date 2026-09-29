import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The store half of the night-coverage diagnostic: the DISTINCT capture seconds a stream holds in a
/// window, which is the only thing that can separate "we synced 14,000 intervals" from "we hold the night".
///
/// The row counts these live beside already existed and already read fine; what did not exist was any way
/// to ask WHEN those rows landed, so a night that arrived as one dense forty-minute burst was
/// indistinguishable from one that arrived whole. Every assertion here is about that distinction.
final class CoverageSecondsTests: XCTestCase {

    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        return store
    }

    // MARK: - HR

    func testHrCoverageSecondsAreAscendingDistinctAndWindowScoped() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(hr: [
            HRSample(ts: 300, bpm: 60), HRSample(ts: 100, bpm: 61), HRSample(ts: 200, bpm: 62),
        ]), deviceId: "dev1")
        // A decoy on another device must never widen the coverage of this one.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 150, bpm: 99)]), deviceId: "other")

        let all = try await store.hrCoverageSeconds(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(all.seconds, [100, 200, 300])
        XCTAssertEqual(all.samples, 3)
        XCTAssertFalse(all.truncated)

        let windowed = try await store.hrCoverageSeconds(deviceId: "dev1", from: 150, to: 250)
        XCTAssertEqual(windowed.seconds, [200])      // inclusive bounds, same as hrSamples
        XCTAssertEqual(windowed.samples, 1)
    }

    /// A v25 / v26 night banks NO measured per-second heart rate at all: it is PPG-derived and lands in
    /// `ppgHrSample`. Counting only `hrSample` would report a fully-synced night of that firmware as empty,
    /// which is the single worst thing a completeness diagnostic can do.
    func testHrCoverageIncludesPpgDerivedSeconds() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: 500, bpm: 58, conf: 0.9),
            PpgHrSample(ts: 501, bpm: 59, conf: 0.9),
        ]), deviceId: "dev1")
        let c = try await store.hrCoverageSeconds(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(c.seconds, [500, 501])
        XCTAssertEqual(c.samples, 2)
    }

    /// A second present in BOTH tables is ONE covered second, not two. The union de-duplicates so the
    /// result stays a second list; the row count is taken separately and may legitimately be larger.
    func testHrCoverageDeDuplicatesASecondPresentInBothTables() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 700, bpm: 62)],
                                           ppgHr: [PpgHrSample(ts: 700, bpm: 61, conf: 0.8)]),
                                   deviceId: "dev1")
        let c = try await store.hrCoverageSeconds(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(c.seconds, [700])
        XCTAssertEqual(c.samples, 2)
    }

    func testHrCoverageEmptyWindowIsEmptyNotNil() async throws {
        let store = try await seeded()
        let c = try await store.hrCoverageSeconds(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertTrue(c.seconds.isEmpty)
        XCTAssertEqual(c.samples, 0)
        XCTAssertFalse(c.truncated)
    }

    /// A read that hit its cap describes a PREFIX of the window, so it must announce itself. A coverage
    /// figure taken from a truncated read understates the gap at the end of the night, which is the one
    /// direction that would turn this diagnostic into a false reassurance.
    func testHrCoverageFlagsTruncationAtTheCap() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(hr: (0..<5).map { HRSample(ts: 1_000 + $0, bpm: 60) }),
                                   deviceId: "dev1")
        let capped = try await store.hrCoverageSeconds(deviceId: "dev1", from: 0, to: 10_000, limit: 3)
        XCTAssertEqual(capped.seconds, [1_000, 1_001, 1_002])
        XCTAssertTrue(capped.truncated)
        // The row count is NOT capped: it is an aggregate, so it still reports the whole window honestly.
        XCTAssertEqual(capped.samples, 5)
    }

    // MARK: - R-R

    /// The stream where coverage and row count diverge hardest. Three seconds carrying five beats is
    /// three seconds of coverage, and reporting five would claim time the night does not hold.
    func testRrCoverageSecondsAreDistinctWhileIntervalsAreCounted() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(rr: [
            RRInterval(ts: 100, rrMs: 800),
            RRInterval(ts: 100, rrMs: 820),
            RRInterval(ts: 101, rrMs: 810),
            RRInterval(ts: 400, rrMs: 790),
            RRInterval(ts: 400, rrMs: 795),
        ]), deviceId: "dev1")
        let c = try await store.rrCoverageSeconds(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(c.seconds, [100, 101, 400])
        XCTAssertEqual(c.samples, 5)
    }

    func testRrCoverageIsDeviceAndWindowScoped() async throws {
        let store = try await seeded()
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800),
                                                RRInterval(ts: 900, rrMs: 800)]), deviceId: "dev1")
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 500, rrMs: 800)]), deviceId: "other")
        let c = try await store.rrCoverageSeconds(deviceId: "dev1", from: 50, to: 500)
        XCTAssertEqual(c.seconds, [100])
        XCTAssertEqual(c.samples, 1)
    }
}
