import XCTest
import SQLite3
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The one-shot FULL-HISTORY passes — the #313 Effort re-axis, the nightly-metrics v2 rework and the
/// #547 bad-clock purge — are each guarded by a persisted "done" flag in UserDefaults.
///
/// Two failures pinned here:
///
/// 1. They were CONSUMED AGAINST AN EMPTY DATABASE. After a reinstall UserDefaults and the store are
///    both empty and the launch cascade fires all three ~6 s in: they ran over nothing, found nothing,
///    and marked themselves done anyway. Nothing re-armed them (`importWhoop` only refreshed, and the
///    flags are deliberately absent from the `.noopbak` settings whitelist), so the history the user
///    restored or synced minutes later was never re-axed, never re-scored under the current nightly
///    recipe and never purged — and `LevelBarModel` then froze its baselines off it.
/// 2. Nothing cleared them when a whole history DID land. A restore and a WHOOP archive import now
///    re-arm all three, watermarks included — clearing a flag but leaving its watermark would make the
///    re-armed pass skip everything up to it, which is the same bug wearing a different hat.
///
/// No `setUp`/`tearDown` overrides on purpose (the class is `@MainActor` and the engine is too): each
/// test brackets its own `.standard` keys and its own temp directory, so the developer's real NOOP
/// profile is put back exactly as it was.
@MainActor
final class OneShotHistoryRearmTests: XCTestCase {

    /// Run `body` with every one-shot key cleared out of `.standard`, then restore the previous values.
    private func withCleanOneShotDefaults(_ body: () async throws -> Void) async throws {
        let keys = IntelligenceEngine.oneShotHistoryDefaultsKeys + [
            IntelligenceEngine.timestampHealPendingKey,
            IntelligenceEngine.lastCompletedAnalysisKey,
            "noop.analyzeWatermark", "analyzeRecent.stepsMotionCache.v1",
        ]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        try await body()
    }

    /// A throwaway directory for the real-file restore tests.
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oneshot-rearm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    /// A suite-scoped UserDefaults, so a restore test never writes into the runner's real domain.
    private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "oneshot-rearm-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { throw fixtureError("no suite defaults") }
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        try body(d)
    }

    private func engine(over store: WhoopStore) -> IntelligenceEngine {
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop")
    }

    // MARK: - 1. An empty store must not consume the one-shots

    func testEmptyStoreDoesNotConsumeTheOneShotFullHistoryPasses() async throws {
        try await withCleanOneShotDefaults {
            let store = try await WhoopStore.inMemory()   // a reinstall: nothing in it at all
            let engine = engine(over: store)

            await engine.runTimestampHealIfNeeded()
            await engine.runEffortRescoreIfNeeded()
            _ = await engine.runNightlyMetricsRescoreIfNeeded()

            XCTAssertFalse(UserDefaults.standard.bool(forKey: IntelligenceEngine.timestampHealFlagKey),
                           "the #547 purge must not be marked done over a database with nothing in it")
            XCTAssertFalse(UserDefaults.standard.bool(forKey: IntelligenceEngine.effortRescoreFlagKey),
                           "the #313 Effort re-axis must not be marked done over an empty store")
            XCTAssertFalse(UserDefaults.standard.bool(forKey: IntelligenceEngine.nightlyMetricsRescoreFlagKey),
                           "the nightly-metrics rework must not be marked done over an empty store")
        }
    }

    /// The guard is a SKIP, not a block: once the store holds raw HR the pass runs and marks itself.
    func testStoreWithHeartRateStillCompletesAndMarksTheEffortRescore() async throws {
        try await withCleanOneShotDefaults {
            let store = try await WhoopStore.inMemory()
            let now = Int(Date().timeIntervalSince1970)
            let hr = (0..<600).map { HRSample(ts: now - 7_200 + $0 * 10, bpm: 58 + ($0 % 5)) }
            _ = try await store.insert(Streams(hr: hr), deviceId: "my-whoop")
            let engine = engine(over: store)

            await engine.runEffortRescoreIfNeeded(historyDays: 3)

            XCTAssertTrue(UserDefaults.standard.bool(forKey: IntelligenceEngine.effortRescoreFlagKey),
                          "a store with raw HR must still consume the one-shot exactly once")
            XCTAssertNil(UserDefaults.standard.string(forKey: IntelligenceEngine.effortRescoreWatermarkKey),
                         "a completed pass clears its resume watermark")
        }
    }

    // MARK: - 2. The Effort rescore is resumable, so it carries its own watermark

    /// The Effort pass was one unchunked 4000-day call that only marked its flag at the very end — so on
    /// a large library it restarted from zero every launch and never finished, starving the resumable
    /// nightly pass behind it. It now walks the same `rescorePlan` chunks, against a watermark OF ITS
    /// OWN: sharing the nightly pass's watermark would have each of them skip the other's history.
    func testEffortRescoreHasItsOwnResumeWatermark() {
        XCTAssertNotEqual(IntelligenceEngine.effortRescoreWatermarkKey,
                          IntelligenceEngine.nightlyMetricsRescoreWatermarkKey)
        XCTAssertTrue(IntelligenceEngine.oneShotHistoryDefaultsKeys
            .contains(IntelligenceEngine.effortRescoreWatermarkKey),
                      "a re-arm that cleared the flag but left the watermark would have the re-armed "
                      + "pass skip everything up to it")
    }

    /// The plan the Effort pass now drives: chunked oldest-first, clamped to the first raw HR sample and
    /// resumable from a watermark. (`rescorePlan` itself is shared with the nightly pass.)
    func testEffortRescorePlanIsChunkedClampedAndResumable() {
        let day = 86_400
        let base = 1_700_000_000
        let days = (0..<300).map { i in
            (key: String(format: "day-%03d", i), asOf: base + i * day)
        }
        let chunk = IntelligenceEngine.rescoreChunkDays
        // Clamped: days that end before the first HR sample are dropped entirely.
        let clamped = IntelligenceEngine.rescorePlan(oldestFirst: days, firstDataAsOf: days[100].asOf,
                                                     completedThrough: nil, chunkDays: chunk)
        XCTAssertEqual(clamped.historical.map(\.maxDays), [chunk])
        XCTAssertEqual(clamped.finalDays, 200 - chunk, "200 days with data: one full chunk, the rest last")
        // Resumable: a watermark skips what has already been walked.
        let resumed = IntelligenceEngine.rescorePlan(oldestFirst: days, firstDataAsOf: days[0].asOf,
                                                     completedThrough: days[250].key, chunkDays: chunk)
        XCTAssertTrue(resumed.historical.isEmpty)
        XCTAssertEqual(resumed.finalDays, 49)
        // No raw HR at all: nothing to walk — the empty-store case above, at the pure layer.
        let empty = IntelligenceEngine.rescorePlan(oldestFirst: days, firstDataAsOf: nil,
                                                   completedThrough: nil, chunkDays: chunk)
        XCTAssertTrue(empty.historical.isEmpty)
        XCTAssertEqual(empty.finalDays, 0)
    }

    // MARK: - 1b. A landing history re-arms all three

    func testRearmClearsEveryOneShotFlagAndBothWatermarks() throws {
        try withFreshDefaults { d in
            for key in IntelligenceEngine.oneShotHistoryDefaultsKeys { d.set("consumed", forKey: key) }

            IntelligenceEngine.rearmOneShotHistoryPasses(defaults: d)

            for key in IntelligenceEngine.oneShotHistoryDefaultsKeys {
                XCTAssertNil(d.object(forKey: key), "\(key) must be cleared so the pass runs again")
            }
        }
    }

    /// A `.noopbak` restore lands a whole history at once. It carries no UserDefaults, so on a reinstall
    /// the three flags this device set over its own empty store survive the swap — and the restored
    /// history is never re-scored. The restore must re-arm them.
    func testNoopbakRestoreRearmsTheOneShotFullHistoryPasses() throws {
        try withTempDir { tmp in
            let sourceDB = tmp.appendingPathComponent("source.sqlite")
            try makeNoopDatabase(at: sourceDB)
            let backup = tmp.appendingPathComponent("history.noopbak")
            try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

            try withFreshDefaults { defaults in
                // What a reinstall looks like the moment before the restore: every one-shot already burned.
                defaults.set(true, forKey: IntelligenceEngine.effortRescoreFlagKey)
                defaults.set(true, forKey: IntelligenceEngine.nightlyMetricsRescoreFlagKey)
                defaults.set(true, forKey: IntelligenceEngine.timestampHealFlagKey)
                defaults.set("2020-01-01", forKey: IntelligenceEngine.nightlyMetricsRescoreWatermarkKey)
                defaults.set("2020-01-01", forKey: IntelligenceEngine.effortRescoreWatermarkKey)

                let liveDB = tmp.appendingPathComponent("live.sqlite")
                let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path,
                                                settingsDefaults: defaults)
                guard case .imported = result else {
                    return XCTFail("restore should succeed, got \(result)")
                }

                XCTAssertFalse(defaults.bool(forKey: IntelligenceEngine.effortRescoreFlagKey))
                XCTAssertFalse(defaults.bool(forKey: IntelligenceEngine.nightlyMetricsRescoreFlagKey))
                XCTAssertFalse(defaults.bool(forKey: IntelligenceEngine.timestampHealFlagKey))
                XCTAssertNil(defaults.string(forKey: IntelligenceEngine.nightlyMetricsRescoreWatermarkKey))
                XCTAssertNil(defaults.string(forKey: IntelligenceEngine.effortRescoreWatermarkKey))
            }
        }
    }

    /// A FAILED restore changes nothing — including this. (A foreign SQLite with no `grdb_migrations`
    /// is rejected before the swap.)
    func testRejectedRestoreLeavesTheOneShotFlagsAlone() throws {
        try withTempDir { tmp in
            let foreign = tmp.appendingPathComponent("foreign.sqlite")
            try makeForeignDatabase(at: foreign)

            try withFreshDefaults { defaults in
                defaults.set(true, forKey: IntelligenceEngine.effortRescoreFlagKey)

                let liveDB = tmp.appendingPathComponent("live2.sqlite")
                let result = DataBackup.restore(from: foreign, toDatabaseAt: liveDB.path,
                                                settingsDefaults: defaults)
                guard case .failure = result else {
                    return XCTFail("a foreign DB must be rejected, got \(result)")
                }
                XCTAssertTrue(defaults.bool(forKey: IntelligenceEngine.effortRescoreFlagKey),
                              "nothing landed, so nothing is re-armed")
            }
        }
    }

    // MARK: - Fixtures

    private func makeNoopDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw fixtureError("open \(url.path)") }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO device (id) VALUES ('my-whoop')")
    }

    private func makeForeignDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw fixtureError("open \(url.path)") }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE room_master_table (id INTEGER PRIMARY KEY)")
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw fixtureError(sql) }
    }

    private func fixtureError(_ what: String) -> NSError {
        NSError(domain: "OneShotHistoryRearmTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: what])
    }
}
