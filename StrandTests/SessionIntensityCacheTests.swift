import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import Strand

/// The session-intensity cache's two guarantees (HEALTH_V2 S3 §3.8, app):
///   * CHUNKED READS: a session longer than the repository's 8,000-row cap is read in full;
///   * IDEMPOTENT RE-RUNS: the same inputs give the same fingerprint (so nothing is recomputed) and the
///     same rows (so an upsert replaces, never appends).
/// Plus the week-plan archive's bounds.
@MainActor
final class SessionIntensityCacheTests: XCTestCase {

    /// A fake store read with the real cap: ascending, truncated at `limit` rows.
    private func fakeFetch(_ all: [HRSample]) -> (Int, Int, Int) async -> [HRSample] {
        { from, to, limit in Array(all.filter { $0.ts >= from && $0.ts <= to }.prefix(limit)) }
    }

    func testChunkedReadBeyondTheRowCap() async {
        // 5 h at 1 Hz = 18,000 samples, more than twice the cap.
        let all = (0..<18_000).map { HRSample(ts: 1_000 + $0, bpm: 120) }
        let got = await SessionIntensityCache.readChunked(from: 1_000, to: 1_000 + 17_999, limit: 8000,
                                                          sliceSeconds: 7200, fetch: fakeFetch(all))
        XCTAssertEqual(got.count, 18_000)
        XCTAssertEqual(got.map(\.ts), all.map(\.ts), "every second once, in order")
    }

    func testDenseSliceIsHalvedNotTruncated() async {
        // 4 samples per second for 1 h: a 7,200 s slice would return the cap, so it must be split.
        let all = (0..<14_400).map { HRSample(ts: 5_000 + $0 / 4, bpm: 100) }
        let got = await SessionIntensityCache.readChunked(from: 5_000, to: 5_000 + 3_599, limit: 8000,
                                                          sliceSeconds: 7200, fetch: fakeFetch(all))
        XCTAssertEqual(got.count, 14_400)
    }

    func testFingerprintIsStableAndMovesWithTheData() {
        let a = [SessionIntensity.Window(start: 10, end: 610, sport: "Running"),
                 SessionIntensity.Window(start: 1000, end: 1600, sport: "Strength")]
        let fp1 = SessionIntensityCache.fingerprint(sessions: a, hrCount: 1200, liftSession: false,
                                                    restingHR: 55, hrMax: 185)
        let fp2 = SessionIntensityCache.fingerprint(sessions: a.reversed(), hrCount: 1200, liftSession: false,
                                                    restingHR: 55, hrMax: 185)
        XCTAssertEqual(fp1, fp2, "order of the rows does not matter")
        XCTAssertNotEqual(fp1, SessionIntensityCache.fingerprint(sessions: a, hrCount: 1300, liftSession: false,
                                                                 restingHR: 55, hrMax: 185),
                          "HR landing after the workout was logged forces a recompute")
        XCTAssertNotEqual(fp1, SessionIntensityCache.fingerprint(sessions: a, hrCount: 1200, liftSession: false,
                                                                 restingHR: nil, hrMax: 185))
    }

    func testRowsAreTheSameOnARerun() {
        let s = SessionIntensity.day(sessions: [.init(start: 0, end: 600, sport: "Running")],
                                     hr: (0..<600).map { HRSample(ts: $0, bpm: 130) },
                                     restingHR: 60, hrMax: 160)
        let first = SessionIntensityCache.points(day: "2026-09-28", s)
        let second = SessionIntensityCache.points(day: "2026-09-28", s)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.map(\.key)).count, first.count, "one row per key: an upsert replaces")
        XCTAssertEqual(first.first { $0.key == SessionIntensityCache.keyAbstained }?.value, 0)
    }

    func testZone45IsBankedAndItsEdgeMovesTheFingerprint() {
        let a = [SessionIntensity.Window(start: 10, end: 610, sport: "Running")]
        let fp = SessionIntensityCache.fingerprint(sessions: a, hrCount: 600, liftSession: false,
                                                   restingHR: 60, hrMax: 160, zone4Lower: 140)
        XCTAssertNotEqual(fp, SessionIntensityCache.fingerprint(sessions: a, hrCount: 600, liftSession: false,
                                                                restingHR: 60, hrMax: 160, zone4Lower: 150),
                          "a custom zone-4 edge recomputes the day")
        XCTAssertTrue(fp.hasPrefix("v2|"), "days banked before zone45_min existed are recomputed once")
        let s = SessionIntensity.day(sessions: [.init(start: 0, end: 600, sport: "Running")],
                                     hr: (0..<600).map { HRSample(ts: $0, bpm: 145) },
                                     restingHR: 60, hrMax: 160, zone4LowerBpm: 140)
        let points = SessionIntensityCache.points(day: "2026-09-28", s)
        XCTAssertEqual(points.first { $0.key == SessionIntensityCache.keyZone45 }?.value ?? -1, 10, accuracy: 1e-9)
    }

    func testWeekPlanArchiveIsBounded() {
        var a = WeekPlanArchive()
        a.guidance = ["2026-01-01": .easy, "2026-09-27": .asPlanned]
        a.illnessDays = ["2026-01-02", "2026-09-26", "2026-09-26"]
        let p = WeekPlanSource.pruned(a, today: "2026-09-28")
        XCTAssertEqual(p.guidance.keys.sorted(), ["2026-09-27"])
        XCTAssertEqual(p.illnessDays, ["2026-09-26"])
    }
}
