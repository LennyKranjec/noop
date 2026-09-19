import XCTest
import Combine
@testable import Strand

/// Pins the perf rework of the strap-log sink without behaviour change:
///  · the lines live in `LiveLog` (`live.logStore`), so a new line no longer fires `LiveState`'s own
///    `objectWillChange` (which re-rendered every LiveState observer), while `live.log` reads the same;
///  · the durable UserDefaults tail is written on a time throttle, plus immediately on disconnect;
///  · `redactPii`'s precompiled regexes produce byte-identical output to the old inline
///    `replacingOccurrences(of:with:options: .regularExpression)` chain.
@MainActor
final class LiveStateLogStorePerfTests: XCTestCase {
    private let tailKey = "strapLog.tail"
    private let gensKey = "strapLog.generations"
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        LiveState.resetGenerationRollLatchForTesting()
    }

    override func tearDown() {
        bag.removeAll()
        UserDefaults.standard.removeObject(forKey: tailKey)
        UserDefaults.standard.removeObject(forKey: gensKey)
        LiveState.resetGenerationRollLatchForTesting()
        super.tearDown()
    }

    // MARK: - LiveLog split

    func testLogReadsThroughTheStore() {
        let live = LiveState()
        live.append(log: "one")
        live.append(log: "two", domain: .sleep)
        XCTAssertEqual(live.log, ["one", "[sleep] two"])
        XCTAssertEqual(live.logStore.lines, live.log)
    }

    func testAppendNotifiesOnlyTheLogStore() {
        let live = LiveState()
        var liveChanges = 0
        var logChanges = 0
        live.objectWillChange.sink { _ in liveChanges += 1 }.store(in: &bag)
        live.logStore.objectWillChange.sink { _ in logChanges += 1 }.store(in: &bag)

        live.append(log: "a line")

        XCTAssertEqual(liveChanges, 0, "a log line must not re-render every LiveState observer")
        XCTAssertGreaterThan(logChanges, 0, "the log views must still update")
    }

    func testTrimStillBoundsTheBuffer() {
        let live = LiveState()
        for i in 0..<(LiveState.maxLogLines + 300) { live.append(log: "l\(i)") }
        XCTAssertLessThanOrEqual(live.log.count, LiveState.maxLogLines + 256)
        XCTAssertEqual(live.log.last, "l\(LiveState.maxLogLines + 299)")
    }

    // MARK: - Time-throttled durable tail

    func testFirstLineIsMirroredThenWritesAreThrottledUntilFlush() {
        let live = LiveState()
        live.append(log: "first")
        XCTAssertEqual(LiveState.persistedLogTail(), ["first"], "the first line of a process is mirrored at once")

        live.append(log: "second")
        XCTAssertEqual(LiveState.persistedLogTail(), ["first"], "within the interval the mirror waits")

        live.flushLogTail()
        XCTAssertEqual(LiveState.persistedLogTail(), ["first", "second"])
    }

    func testDisconnectFlushesTheTail() {
        let live = LiveState()
        live.append(log: "first")
        live.append(log: "second")
        live.clearBiometrics()
        XCTAssertEqual(LiveState.persistedLogTail(), ["first", "second"])
    }

    // MARK: - redactPii equivalence

    /// The old implementation, verbatim, as the oracle.
    private static func legacyRedactTextRules(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(
            of: "([0-9A-Fa-f]{2}):[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:([0-9A-Fa-f]{2})",
            with: "$1:••:••:••:••:$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "WHOOP (?=[0-9A-Za-z]{6,})[0-9A-Za-z]*[0-9][0-9A-Za-z]*", with: "WHOOP <serial>", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "(?![0-9A-Fa-f]{8}-(?:0000-1000-8000-00805f9b34fb|8d6d-82b8-614a-1c8cb0f8dcc6))[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
            with: "<device>", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(
            of: "whoop-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}(-noop)",
            with: "whoop-$1…$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "whoop-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}",
            with: "whoop-$1…", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "oura-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}(-noop)",
            with: "oura-$1…$2", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "oura-([A-Za-z0-9]{3})[A-Za-z0-9-]{3,}",
            with: "oura-$1…", options: .regularExpression)
        out = out.replacingOccurrences(
            of: "[\\p{L}\\p{N}_.\\-]+(['\u{2019}]s\\s+(?i:whoop))",
            with: "<name>$1", options: .regularExpression)
        return out
    }

    func testPrecompiledRedactionMatchesTheLegacyChain() {
        let corpus = [
            "",
            "connected ok",
            "peer AA:BB:CC:DD:EE:FF rssi -60 and 01:23:45:67:89:ab",
            "saw WHOOP 4C1594026 advertise; WHOOP MGB0779473; WHOOP PUFFIN service 1150; WHOOP 4.0",
            "peripheral 1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D connecting",
            "peripheral 1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d (lowercase)",
            "service 0000180d-0000-1000-8000-00805f9b34fb and 61080001-8d6d-82b8-614a-1c8cb0f8dcc6",
            "SERVICE 0000180D-0000-1000-8000-00805F9B34FB upper",
            "device whoop-4C1594026 and whoop-MGB0779473-noop and my-whoop and my-whoop-noop",
            "device oura-ABCDEF1234 and oura-XYZ98765-noop",
            "Discovered Ryan's Whoop (rssi -55) - connecting",
            "Discovered Ryan\u{2019}s WHOOP 4.0",
            "Ryan B's Whoop",
            "price $1 and \\backslash \\1 $2 kept literally",
            "emoji 😀 AA:BB:CC:DD:EE:FF then Zoë's whoop",
            "mixed [connection] WHOOP 4C1594026 at 01:23:45:67:89:AB via whoop-ABC123 -noop",
        ]
        for line in corpus {
            XCTAssertEqual(LiveState.redactPii(line), Self.legacyRedactTextRules(line), "diverged on: \(line)")
        }
    }
}
