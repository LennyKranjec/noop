import XCTest
@testable import Strand
import WhoopProtocol
import WhoopStore

/// The safe-trim invariant, pinned end to end on the real `Backfiller` state machine rather than on its
/// comments.
///
/// The strap FREES the flash a chunk occupied the moment NOOP echoes its HISTORY_END token. So the order
/// decoded-rows-durable, then raw, then cursor, then ack is not a style choice: any step that moves ahead
/// of the ack loses a chunk permanently the first time it fails, and the failure is invisible because the
/// offload reports a clean sync. These tests assert the ORDER, and assert that every failure path holds the
/// ack rather than advancing past data that was never stored.
@MainActor
final class BackfillAckOrderingTests: XCTestCase {

    // MARK: - Spy

    /// What the Backfiller did, in the order it did it. The order is the whole assertion.
    enum Step: Equatable {
        case insert
        case raw
        case cursor(String, Int)
        case ack(UInt32)
    }

    @MainActor
    final class SpyStore: BackfillStoreWriting {
        var steps: [Step] = []
        var failInsert = false
        var failCursor = false
        var failRaw = false

        struct Boom: Error {}

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            steps.append(.insert)
            if failInsert { throw Boom() }
            return (hr: 0, rr: 0, events: 0, battery: 0,
                    spo2: 0, skinTemp: 0, resp: 0, gravity: 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            steps.append(.raw)
            if failRaw { throw Boom() }
        }

        func setCursor(_ name: String, _ value: Int) async throws {
            steps.append(.cursor(name, value))
            if failCursor { throw Boom() }
        }

        func cursor(_ name: String) async throws -> Int? { nil }
    }

    // MARK: - Frame fixtures

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    /// METADATA(49) HISTORY_START.
    private func startFrame() -> [UInt8] { frameFromPayload([], type: 49, seq: 0, cmd: 1) }

    /// METADATA(49) HISTORY_END. The payload is `unix(4) subsec(2) unk0(4) trim(4) next(4)` = 18 bytes, so
    /// the frame is long enough for `Backfiller.endData` to take the verbatim 8-byte ack token at
    /// `frame[17..<25]` — the token the strap requires echoed unchanged.
    private func endFrame(unix: UInt32 = 1_700_000_000, trim: UInt32) -> [UInt8] {
        let payload = le32(unix) + le16(0) + le32(0) + le32(trim) + le32(0)
        return frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
    }

    /// One HISTORICAL_DATA(47) record frame that NOOP cannot decode.
    ///
    /// Deliberately CRC-broken (one payload byte flipped after the envelope was built) rather than
    /// plausible-looking: it makes the frame's classification independent of any firmware field map, so
    /// this suite pins the persist/ack SEQUENCE and cannot start failing because a layout decoder learned
    /// or forgot a version. `classifyHistoricalMeta` reads it as `.other` (chunk payload) and
    /// `rejectedHistoricalRecords` reads it as an undecodable record, which is also the case whose bytes
    /// exist NOWHERE once the trim is acked - so it is the right frame for the archive-before-ack test too.
    private func recordFrame() -> [UInt8] {
        var f = frameFromPayload([UInt8](repeating: 0, count: 80), type: 47, seq: 24, cmd: 0)
        f[8] ^= 0xFF          // inside the record payload, so the trailing CRC32 no longer matches
        return f
    }

    private func makeBackfiller(store: SpyStore,
                                acks: AckLog,
                                rejectedSinkSucceeds: Bool = true) -> Backfiller {
        Backfiller(store: store,
                   deviceId: "dev1",
                   ackTrim: { trim, _ in
                       store.steps.append(.ack(trim))
                       acks.trims.append(trim)
                   },
                   enableRawCapture: false,
                   log: { _ in },
                   rejectedSink: { _, _, _ in rejectedSinkSucceeds },
                   // Bypass the real extractor: this suite is about the persist/ack SEQUENCE, not about
                   // what a record decodes to, and a fixed empty result makes the sequence deterministic.
                   extract: { _, _, _, _, _ in Streams() })
    }

    final class AckLog { var trims: [UInt32] = [] }

    // MARK: - The happy path

    /// Decoded rows durable FIRST, then the cursor, then the ack. Nothing may reach the strap before the
    /// rows are on disk.
    func testChunkPersistsThenAdvancesCursorThenAcks() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 4242))

        XCTAssertEqual(store.steps, [.insert, .cursor("strap_trim", 4242), .ack(4242)])
        XCTAssertEqual(acks.trims, [4242])
        XCTAssertEqual(bf.lastAckedTrim, 4242)
        XCTAssertFalse(bf.persistStalled)
    }

    /// With raw capture ON the raw batch is part of "durable", so it too lands before the cursor and the ack.
    func testRawCaptureIsDurableBeforeTheCursorAndAck() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = Backfiller(store: store, deviceId: "dev1",
                            ackTrim: { trim, _ in store.steps.append(.ack(trim)); acks.trims.append(trim) },
                            enableRawCapture: true,
                            log: { _ in },
                            rejectedSink: { _, _, _ in true },
                            extract: { _, _, _, _, _ in Streams() })
        bf.begin(family: .whoop4)
        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 7))

        XCTAssertEqual(store.steps, [.insert, .raw, .cursor("strap_trim", 7), .ack(7)])
    }

    /// An END with no records between it and the last one is metadata only: nothing to persist, but the
    /// cursor still advances and the ack still goes out, or the offload would never progress.
    func testEmptyChunkStillAdvancesCursorAndAcks() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(endFrame(trim: 11))

        XCTAssertEqual(store.steps, [.cursor("strap_trim", 11), .ack(11)])
    }

    // MARK: - Failure paths must hold the ack

    /// The row write failed, so the chunk is not stored. Acking would free it on the strap forever. Nothing
    /// after the insert may run.
    func testInsertFailureHoldsTheAckAndStallsTheSession() async {
        let store = SpyStore()
        store.failInsert = true
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 99))

        XCTAssertEqual(store.steps, [.insert])
        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertNil(bf.lastAckedTrim)
        XCTAssertTrue(bf.persistStalled)
    }

    /// The rows are down but the cursor write failed. Acking now would let the strap trim past a chunk whose
    /// position we did not record, so the ack is held and the strap re-offers the chunk next session.
    func testCursorFailureHoldsTheAck() async {
        let store = SpyStore()
        store.failCursor = true
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 55))

        XCTAssertEqual(store.steps, [.insert, .cursor("strap_trim", 55)])
        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertTrue(bf.persistStalled)
    }

    /// A chunk carrying records NOOP cannot decode is only recoverable from the raw archive, so a failed
    /// archive write must hold the ack exactly like a failed row write.
    func testRejectArchiveFailureHoldsTheAck() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks, rejectedSinkSucceeds: false)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 77))

        XCTAssertEqual(store.steps, [.insert])   // no cursor, no ack
        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertTrue(bf.persistStalled)
    }

    /// The #57 shape, and the one a per-chunk guard alone would miss: once a chunk has failed to persist,
    /// a LATER empty END must not ack either. An empty END skips the insert and never throws, so without
    /// the session-wide stall it would advance the strap's trim straight past the held records.
    func testAStalledSessionRefusesToAckEvenAnEmptyEnd() async {
        let store = SpyStore()
        store.failInsert = true
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 100))     // fails, stalls
        await bf.ingest(endFrame(trim: 200))     // empty END, must NOT ack past the held chunk

        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertFalse(store.steps.contains(.cursor("strap_trim", 200)))
    }

    /// A fresh session clears the stall, so a transient store failure does not wedge the offload forever.
    func testBeginClearsTheStallSoTheNextSessionCanAckAgain() async {
        let store = SpyStore()
        store.failInsert = true
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)
        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 1))
        XCTAssertTrue(bf.persistStalled)

        store.failInsert = false
        store.steps.removeAll()
        bf.begin(family: .whoop4)
        XCTAssertFalse(bf.persistStalled)
        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 2))

        XCTAssertEqual(store.steps, [.insert, .cursor("strap_trim", 2), .ack(2)])
    }

    // MARK: - Interruptions

    /// The strap went quiet mid-chunk. The buffered records were never committed, so nothing is acked and
    /// the strap keeps them: the next session re-offers everything past the last GOOD ack.
    func testTimeoutMidChunkNeverAcks() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        bf.timeoutFired()

        XCTAssertTrue(store.steps.isEmpty)
        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertFalse(bf.isBackfilling)
    }

    /// HISTORY_COMPLETE arriving with records still buffered discards them UNACKED rather than acking a
    /// partial chunk. The records stay on the strap, which is the whole point.
    func testCompleteWithABufferedPartialChunkDiscardsItUnacked() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(frameFromPayload([], type: 49, seq: 0, cmd: 3))   // HISTORY_COMPLETE

        XCTAssertTrue(acks.trims.isEmpty)
        XCTAssertFalse(bf.isBackfilling)
    }

    // MARK: - The verbatim ack token

    /// The ack echoes the strap's OWN eight bytes, taken at the family's offset, and refuses to invent them
    /// for a frame too short to carry them. A regenerated or mangled token is how an offload turns into a
    /// permanent re-flood, so "nil rather than something plausible" is the required behaviour.
    func testEndDataIsTheVerbatimEightByteTokenAtTheFamilyOffset() {
        let payload: [UInt8] = (0..<24).map { UInt8($0) }
        let f4 = frameFromPayload(payload, type: 49, seq: 0, cmd: 2)
        // WHOOP 4.0: metadata.data starts at frame[7], the token is data[10..<18].
        XCTAssertEqual(Backfiller.endData(from: f4, family: .whoop4), Array(f4[17..<25]))
        // WHOOP 5/MG: the puffin envelope is four bytes longer, so the same field sits at frame[21..<29].
        XCTAssertEqual(Backfiller.endData(from: f4, family: .whoop5), Array(f4[21..<29]))
    }

    func testEndDataIsNilWhenTheFrameCannotCarryTheToken() {
        let runt = [UInt8](repeating: 0xAA, count: 20)
        XCTAssertNil(Backfiller.endData(from: runt, family: .whoop4))
        XCTAssertNil(Backfiller.endData(from: runt, family: .whoop5))
        // Exactly one byte short of the WHOOP 5 slice, and long enough for the WHOOP 4 one: the guard is
        // per family, not a single shared length.
        let between = [UInt8](repeating: 0, count: 28)
        XCTAssertNotNil(Backfiller.endData(from: between, family: .whoop4))
        XCTAssertNil(Backfiller.endData(from: between, family: .whoop5))
    }

    /// Successive chunks ack in arrival order, each after its own persist. The drain is serialized for this
    /// reason: an ack that overtook an earlier chunk's persist would free flash NOOP had not stored.
    func testSuccessiveChunksAckInOrderEachAfterItsOwnPersist() async {
        let store = SpyStore()
        let acks = AckLog()
        let bf = makeBackfiller(store: store, acks: acks)
        bf.begin(family: .whoop4)

        await bf.ingest(startFrame())
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 10))
        await bf.ingest(recordFrame())
        await bf.ingest(endFrame(trim: 20))

        XCTAssertEqual(acks.trims, [10, 20])
        XCTAssertEqual(store.steps, [.insert, .cursor("strap_trim", 10), .ack(10),
                                     .insert, .cursor("strap_trim", 20), .ack(20)])
        XCTAssertEqual(bf.lastAckedTrim, 20)
    }
}
