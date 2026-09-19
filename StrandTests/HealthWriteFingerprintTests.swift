import XCTest
@testable import Strand

/// The Apple Health write-back skip logic (`HealthWriteFingerprint` / `HealthHRWriteRecord`). The contract:
/// a pass may skip or shorten its HealthKit delete + save ONLY when Health would end up holding exactly
/// what the full delete + rewrite would have written.
final class HealthWriteFingerprintTests: XCTestCase {

    // MARK: - Fingerprint

    func testEmptyFingerprintIsTheFNVOffsetBasis() {
        XCTAssertEqual(HealthWriteFingerprint().value, 0xcbf2_9ce4_8422_2325)
    }

    /// Stable across processes (never `hashValue`): the same values always give the same hash.
    func testFingerprintIsDeterministicAndValueSensitive() {
        func fp(_ bpm: Double, _ key: String) -> HealthWriteFingerprint {
            var h = HealthWriteFingerprint(seed: ["noop-hk-write", "v1", "vitals", "my-whoop", "my-whoop"])
            h.add(key); h.add(bpm); h.add(Int(1_700_000_000)); h.add(Date(timeIntervalSince1970: 1_700_000_060))
            return h
        }
        XCTAssertEqual(fp(52, "noop:rhr:2026-09-18"), fp(52, "noop:rhr:2026-09-18"))
        XCTAssertNotEqual(fp(52, "noop:rhr:2026-09-18"), fp(52.000_000_001, "noop:rhr:2026-09-18"))
        XCTAssertNotEqual(fp(52, "noop:rhr:2026-09-18"), fp(52, "noop:rhr:2026-09-19"))
        XCTAssertEqual(fp(52, "k").hex.count, 16)
    }

    /// Strings carry their length, so a different split of the same bytes is a different fingerprint.
    func testStringBoundariesMatter() {
        var a = HealthWriteFingerprint(); a.add("ab"); a.add("c")
        var b = HealthWriteFingerprint(); b.add("a"); b.add("bc")
        XCTAssertNotEqual(a, b)
    }

    func testDeviceScopeChangesTheSeed() {
        let a = HealthWriteFingerprint(seed: ["noop-hk-write", "v1", "sleep", "my-whoop", "my-whoop"])
        let b = HealthWriteFingerprint(seed: ["noop-hk-write", "v1", "sleep", "my-whoop", "whoop-ABC123"])
        XCTAssertNotEqual(a, b)
    }

    func testStoreMatchesOnlyAfterStoreAndForgetsOnClear() {
        let suite = "HealthWriteFingerprintTests.store"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        var fp = HealthWriteFingerprint(); fp.add("x")
        XCTAssertFalse(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d))
        HealthWriteFingerprintStore.store(.vitals, fp, defaults: d)
        XCTAssertTrue(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d))
        XCTAssertFalse(HealthWriteFingerprintStore.matches(.sleep, fp, defaults: d))
        HealthHRWriteRecord(seed: 1, from: 0, entries: []).save(defaults: d)
        HealthWriteFingerprintStore.clearAll(defaults: d)
        XCTAssertFalse(HealthWriteFingerprintStore.matches(.vitals, fp, defaults: d))
        XCTAssertNil(HealthHRWriteRecord.load(defaults: d))
    }

    // MARK: - HR record

    private func entries(_ tss: [Int], bpm: Double = 60, nowTs: Int = .max) -> [HealthHRWriteRecord.Entry] {
        tss.map { .init(ts: $0, digest: HealthHRWriteRecord.digest(ts: $0, endTs: min($0 + 60, nowTs), bpm: bpm)) }
    }

    func testRecordRoundTrips() {
        let r = HealthHRWriteRecord(seed: 0xDEAD_BEEF_0123_4567, from: -5, entries: entries([60, 120, 600]))
        XCTAssertEqual(HealthHRWriteRecord(encoded: r.encoded), r)
        XCTAssertNil(HealthHRWriteRecord(encoded: Data([1, 2, 3])))
    }

    func testNoRecordOrForeignSeedIsFull() {
        let e = entries([0, 60])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: nil, seed: 1, windowStart: 0, entries: e), .full)
        let other = HealthHRWriteRecord(seed: 2, from: 0, entries: e)
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: other, seed: 1, windowStart: 0, entries: e), .full)
    }

    /// A record that does not reach back to this window's start cannot vouch for it.
    func testRecordStartingAfterTheWindowIsFull() {
        let prev = HealthHRWriteRecord(seed: 1, from: 600, entries: entries([600, 660]))
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: entries([600, 660])),
                       .full)
    }

    func testUnchangedIsSkip() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 60, 120]))
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: entries([0, 60, 120])),
                       .skip)
    }

    /// The window slid forward; the minutes it still covers are unchanged and new ones arrived: append.
    func testSlidWindowWithOnlyNewerMinutesAppends() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 60, 120, 180]))
        let now = entries([120, 180, 240, 300])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 120, entries: now),
                       .append(fromIndex: 2))
    }

    func testChangedMinuteRewritesFromThere() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 60, 120, 180]))
        var now = entries([0, 60, 120, 180, 240])
        now[2] = .init(ts: 120, digest: HealthHRWriteRecord.digest(ts: 120, endTs: 180, bpm: 61))
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: now),
                       .rewrite(deleteFromTs: 120, fromIndex: 2))
    }

    /// The live-edge minute was written clamped to "now"; the next pass writes it whole. That is a change
    /// (the full rewrite would replace it), so the rewrite starts at that minute.
    func testClampedLiveEdgeMinuteIsRewritten() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 60, 120], nowTs: 150))
        let now = entries([0, 60, 120, 180])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: now),
                       .rewrite(deleteFromTs: 120, fromIndex: 2))
    }

    /// A backfilled minute inserted before already-written ones: delete from it, rewrite from it.
    func testInsertedEarlierMinuteRewritesFromIt() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 120, 180]))
        let now = entries([0, 60, 120, 180])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: now),
                       .rewrite(deleteFromTs: 60, fromIndex: 1))
    }

    /// A minute Health holds that the store no longer has must go (the full rewrite deleted it too).
    func testRemovedMinuteRewritesFromIt() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([0, 60, 120, 180]))
        let now = entries([0, 120, 180])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: now),
                       .rewrite(deleteFromTs: 60, fromIndex: 1))
        let trailingGone = entries([0, 60])
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 0, entries: trailingGone),
                       .rewrite(deleteFromTs: 120, fromIndex: 2))
    }

    /// An unaligned window start re-averages its first (partial) minute: that minute is a change.
    func testPartialHeadMinuteIsACompareCandidate() {
        let prev = HealthHRWriteRecord(seed: 1, from: 0, entries: entries([60, 120, 180]))
        var now = entries([60, 120, 180])
        now[0] = .init(ts: 60, digest: HealthHRWriteRecord.digest(ts: 60, endTs: 120, bpm: 70))
        XCTAssertEqual(HealthHRWriteRecord.plan(previous: prev, seed: 1, windowStart: 90, entries: now),
                       .rewrite(deleteFromTs: 60, fromIndex: 0))
    }
}
