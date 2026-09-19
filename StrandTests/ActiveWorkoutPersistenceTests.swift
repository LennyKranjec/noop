import XCTest
import Foundation
import WhoopProtocol
@testable import Strand

/// Pins the durable manual-workout codec (#529): the persist -> rehydrate round-trip that lets a
/// manually-started session survive iOS killing the app mid-session so it can still be ended and saved.
/// Pure + `UserDefaults`-backed, mirroring the Android `ActiveWorkoutPersistenceTest` case for case.
final class ActiveWorkoutPersistenceTests: XCTestCase {

    private func sample(_ ts: Int, _ bpm: Int) -> HRSample { HRSample(ts: ts, bpm: bpm) }

    private func snapshot(
        startSec: Int = 1_700_000_000,
        sport: String = "Tennis",
        samples: [HRSample] = [HRSample(ts: 1_700_000_001, bpm: 120), HRSample(ts: 1_700_000_061, bpm: 145)],
        avgHr: Int = 133,
        peakHr: Int = 145,
        liveStrain: Double = 8.4,
        pausedAtSec: Int? = nil,
        pausedDurationSec: Int? = nil
    ) -> ActiveWorkoutPersistence.Snapshot {
        ActiveWorkoutPersistence.Snapshot(startSec: startSec, sport: sport, samples: samples,
                                          avgHr: avgHr, peakHr: peakHr, liveStrain: liveStrain,
                                          pausedAtSec: pausedAtSec, pausedDurationSec: pausedDurationSec)
    }

    /// A throwaway, isolated defaults suite so the test never touches the real store.
    private func freshDefaults() -> UserDefaults {
        let name = "test.activeWorkout.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - pure codec round-trip

    func testEncodeDecodeRoundTripsEveryField() {
        let original = snapshot(pausedAtSec: 1_700_000_120, pausedDurationSec: 45)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNoSamples() {
        // A session that started but hasn't captured a sample yet (strap not streaming) must still
        // persist + rehydrate — otherwise a kill right after Start loses the start time.
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(samples: [], avgHr: 0, peakHr: 0, liveStrain: 0)))
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.samples.isEmpty)
        XCTAssertEqual(decoded!.startSec, 1_700_000_000)
        XCTAssertEqual(decoded!.sport, "Tennis")
    }

    func testRoundTripSportNameWithSpacesPreserved() {
        let decoded = ActiveWorkoutPersistence.decode(
            ActiveWorkoutPersistence.encode(snapshot(sport: "Traditional Strength Training")))
        XCTAssertEqual(decoded!.sport, "Traditional Strength Training")
    }

    // MARK: - header + sample log store / load / clear

    /// A throwaway sample-log file in the temp directory, removed at teardown.
    private func freshLog() -> ActiveWorkoutPersistence.SampleLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.activeWorkout.\(UUID().uuidString).bin")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ActiveWorkoutPersistence.SampleLog(url: url)
    }

    private func header(startSec: Int = 1_700_000_000, sport: String = "Tennis",
                        pausedAtSec: Int? = nil, pausedDurationSec: Int? = nil,
                        lockedZone: Int? = nil) -> ActiveWorkoutPersistence.Header {
        ActiveWorkoutPersistence.Header(startSec: startSec, sport: sport, pausedAtSec: pausedAtSec,
                                        pausedDurationSec: pausedDurationSec, lockedZone: lockedZone)
    }

    func testStoreLoadClearRoundTrip() {
        let defaults = freshDefaults()
        let log = freshLog()
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults, log: log))   // nothing yet
        let h = header(pausedAtSec: 1_700_000_120, pausedDurationSec: 45, lockedZone: 3)
        ActiveWorkoutPersistence.storeHeader(h, into: defaults)
        log.replaceAll([])
        let samples = [sample(1_700_000_001, 120), sample(1_700_000_002, 131), sample(1_700_000_061, 145)]
        for s in samples { log.append(s) }
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults, log: log),
                       ActiveWorkoutPersistence.Restored(header: h, samples: samples, fromLegacy: false))
        // Ending the session clears it — a relaunch then rehydrates nothing, and the file is gone.
        ActiveWorkoutPersistence.clear(from: defaults, log: log)
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults, log: log))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url!.path))
    }

    func testHeaderWithNoSamplesStillRehydrates() {
        // A kill right after Start, before any HR sample landed, must keep the start time.
        let defaults = freshDefaults()
        let log = freshLog()
        ActiveWorkoutPersistence.storeHeader(header(), into: defaults)
        let restored = ActiveWorkoutPersistence.load(from: defaults, log: log)
        XCTAssertEqual(restored?.header.startSec, 1_700_000_000)
        XCTAssertEqual(restored?.samples, [])
        XCTAssertEqual(restored?.fromLegacy, false)
    }

    func testStoreHeaderOverwritesPreviousHeader() {
        // Pause / resume / lock re-store the header; the latest write wins.
        let defaults = freshDefaults()
        ActiveWorkoutPersistence.storeHeader(header(), into: defaults)
        let later = header(pausedAtSec: 1_700_000_300, pausedDurationSec: 12, lockedZone: 2)
        ActiveWorkoutPersistence.storeHeader(later, into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults, log: freshLog())?.header, later)
    }

    func testHeaderDecodeBoundChecks() {
        XCTAssertNil(ActiveWorkoutPersistence.decodeHeader(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decodeHeader(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decodeHeader(
            ActiveWorkoutPersistence.encodeHeader(header(startSec: 0))))
        let dirty = ActiveWorkoutPersistence.decodeHeader(ActiveWorkoutPersistence.encodeHeader(
            header(pausedAtSec: -1, pausedDurationSec: -5, lockedZone: 9)))
        XCTAssertNotNil(dirty)
        XCTAssertNil(dirty?.pausedAtSec)
        XCTAssertEqual(dirty?.pausedDurationSec, 0)
        XCTAssertNil(dirty?.lockedZone)
    }

    // MARK: - sample log

    func testSampleLogRoundTripsAndDropsImplausibleOnLoad() {
        let defaults = freshDefaults()
        let log = freshLog()
        ActiveWorkoutPersistence.storeHeader(header(), into: defaults)
        log.append(sample(1_700_000_001, 150))
        log.append(sample(1_700_000_002, 0))      // bpm 0 — rejected on load
        log.append(sample(1_700_000_003, 400))    // bpm out of range — rejected on load
        log.append(sample(1_700_000_004, 151))
        XCTAssertEqual(log.readAll().count, 4)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults, log: log)?.samples,
                       [sample(1_700_000_001, 150), sample(1_700_000_004, 151)])
    }

    func testSameSecondRecordsFoldToTheLaterReading() {
        // The live capture overwrites a same-second sample; the append-only log carries both records.
        let defaults = freshDefaults()
        let log = freshLog()
        ActiveWorkoutPersistence.storeHeader(header(), into: defaults)
        for s in [sample(1_700_000_001, 120), sample(1_700_000_001, 124), sample(1_700_000_002, 126)] {
            log.append(s)
        }
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults, log: log)?.samples,
                       [sample(1_700_000_001, 124), sample(1_700_000_002, 126)])
    }

    func testTornTrailingRecordIsIgnoredAndTrimmedBeforeTheNextAppend() throws {
        let log = freshLog()
        log.append(sample(1_700_000_001, 120))
        // A kill mid-write: a partial record at the tail.
        let h = try FileHandle(forWritingTo: log.url!)
        _ = try h.seekToEnd()
        try h.write(contentsOf: Data([1, 2, 3, 4, 5]))
        try h.close()
        XCTAssertEqual(log.readAll(), [sample(1_700_000_001, 120)])
        // A fresh handle (as after a relaunch) cuts the torn bytes, so the next record stays aligned.
        let reopened = ActiveWorkoutPersistence.SampleLog(url: log.url)
        reopened.append(sample(1_700_000_002, 130))
        XCTAssertEqual(reopened.readAll(), [sample(1_700_000_001, 120), sample(1_700_000_002, 130)])
    }

    func testReplaceAllResetsTheLog() {
        let log = freshLog()
        log.append(sample(1_700_000_001, 120))
        XCTAssertTrue(log.replaceAll([]))
        XCTAssertEqual(log.readAll(), [])
        log.append(sample(1_700_000_005, 140))
        XCTAssertEqual(log.readAll(), [sample(1_700_000_005, 140)])
    }

    // MARK: - legacy migration

    func testLegacySnapshotStillLoads() {
        // A session written by the previous build (the whole thing JSON-encoded under the old key) must
        // survive the update.
        let defaults = freshDefaults()
        let legacy = snapshot(pausedAtSec: 1_700_000_120, pausedDurationSec: 45)
        defaults.set(ActiveWorkoutPersistence.encode(legacy), forKey: ActiveWorkoutPersistence.defaultsKey)
        let restored = ActiveWorkoutPersistence.load(from: defaults, log: freshLog())
        XCTAssertEqual(restored?.fromLegacy, true)
        XCTAssertEqual(restored?.samples, legacy.samples)
        XCTAssertEqual(restored?.header, header(pausedAtSec: 1_700_000_120, pausedDurationSec: 45))
    }

    func testHeaderWinsOverALeftoverLegacyBlobAndClearDropsBoth() {
        let defaults = freshDefaults()
        let log = freshLog()
        defaults.set(ActiveWorkoutPersistence.encode(snapshot(sport: "Old")),
                     forKey: ActiveWorkoutPersistence.defaultsKey)
        ActiveWorkoutPersistence.storeHeader(header(sport: "New"), into: defaults)
        XCTAssertEqual(ActiveWorkoutPersistence.load(from: defaults, log: log)?.header.sport, "New")
        ActiveWorkoutPersistence.clear(from: defaults, log: log)
        XCTAssertNil(defaults.data(forKey: ActiveWorkoutPersistence.defaultsKey))
        XCTAssertNil(ActiveWorkoutPersistence.load(from: defaults, log: log))
    }

    // MARK: - honest failure (no revived bogus card)

    func testDecodeNilOrEmptyIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(nil))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data()))
    }

    func testDecodeGarbageIsNil() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("not json".utf8)))
        XCTAssertNil(ActiveWorkoutPersistence.decode(Data("{\"unexpected\":1}".utf8)))
    }

    func testDecodeRejectsNonPositiveStart() {
        let bad = snapshot(startSec: 0)
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bad)))
    }

    // MARK: - bound-checked untrusted samples

    func testDecodeDropsOutOfRangeSamples() {
        // A corrupt blob with a bpm=0, bpm=400, and ts<=0 sample — only the in-range one survives.
        let dirty = snapshot(samples: [
            sample(1_700_000_001, 150),   // good
            sample(1_700_000_002, 0),     // bpm 0 — rejected
            sample(1_700_000_003, 400),   // bpm out of range — rejected
            sample(0, 120),               // ts <= 0 — rejected
        ])
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertEqual(decoded?.samples, [sample(1_700_000_001, 150)])
    }

    func testDecodeClampsNegativeDerivedStats() {
        let dirty = snapshot(samples: [], avgHr: -5, peakHr: -9, liveStrain: -3)
        let decoded = ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(dirty))
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded!.avgHr, 0)
        XCTAssertEqual(decoded!.peakHr, 0)
        XCTAssertEqual(decoded!.liveStrain, 0, accuracy: 1e-9)
    }

    func testDecodePreservesAbsentPauseDurationAndClampsPresentNegative() {
        let absent = snapshot()
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(absent))?.pausedDurationSec)

        var negative = snapshot()
        negative.pausedDurationSec = -5
        XCTAssertEqual(
            ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(negative))?.pausedDurationSec,
            0
        )
    }

    /// ZONE LOCK: the locked target zone round-trips, an old snapshot without the field reads unlocked,
    /// and an out-of-range persisted zone is dropped rather than reviving a lock on a zone that isn't one.
    func testLockedZoneRoundTripsAndValidates() {
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(snapshot()))?.lockedZone)

        var locked = snapshot()
        locked.lockedZone = 3
        XCTAssertEqual(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(locked))?.lockedZone, 3)

        var bogus = snapshot()
        bogus.lockedZone = 9
        XCTAssertNil(ActiveWorkoutPersistence.decode(ActiveWorkoutPersistence.encode(bogus))?.lockedZone)
    }
}
