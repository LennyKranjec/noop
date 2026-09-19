import XCTest
import WhoopProtocol
@testable import Strand

/// The gravity read behind the Steps calibration screen (#1643).
///
/// Swift twin of Android's `GravityReadUnionTest` (@kavemang, #1644). The bug was the same shape on both
/// platforms and opposite in detail: Android hardcoded the canonical id and missed a re-added strap's live
/// motion; this side read the ACTIVE id alone and missed the canonical history. Either way the screen
/// disagreed with the estimator it exists to reconstruct.
final class GravityReadUnionTests: XCTestCase {

    private func sample(_ ts: Int, _ x: Double) -> GravitySample {
        GravitySample(ts: ts, x: x, y: 0, z: 1)
    }

    /// The active strap wins a shared timestamp, and nothing double-counts — the two properties the
    /// screen's motion total depends on.
    func testActiveWinsTiesAndTheStreamIsTimeOrdered() {
        let active = [sample(101, 9.0), sample(103, 9.2)]
        let canonical = [sample(100, 5.0), sample(101, 5.1), sample(102, 5.2)]

        let merged = Repository.mergeGravityByTs([active, canonical])

        XCTAssertEqual(merged.map(\.ts), [100, 101, 102, 103])
        XCTAssertEqual(merged.first { $0.ts == 101 }?.x, 9.0)   // active, not canonical
    }

    /// A re-added strap with no canonical history must still populate: this is the reported failure on
    /// the Android side, and the union has to cover it here too.
    func testActiveOnlyMotionSurfacesWhenCanonicalIsEmpty() {
        let active = [sample(100, 0.1), sample(101, 0.2)]
        XCTAssertEqual(Repository.mergeGravityByTs([active, []]).map(\.ts), [100, 101])
    }

    /// The mirror case, which is the half THIS platform had: canonical history and no active-id rows.
    func testCanonicalHistorySurfacesWhenTheActiveIdIsEmpty() {
        let canonical = [sample(100, 0.1), sample(101, 0.2)]
        XCTAssertEqual(Repository.mergeGravityByTs([[], canonical]).map(\.ts), [100, 101])
    }

    /// A single-device install collapses to one id, and that read is returned UNCHANGED — so this change
    /// cannot alter what the overwhelmingly common install already saw.
    func testASingleIdReadIsReturnedUntouched() {
        let rows = [sample(100, 0.1), sample(101, 0.2)]
        XCTAssertEqual(Repository.mergeGravityByTs([rows]), rows)
    }

    func testNoMotionUnderEitherIdStaysEmpty() {
        XCTAssertTrue(Repository.mergeGravityByTs([[], []]).isEmpty)
    }

    /// Unsorted input still comes back time-ordered: the store returns rows per id, and concatenating two
    /// id-ordered lists is not itself ordered.
    func testOutOfOrderInputIsSorted() {
        let a = [sample(300, 1), sample(100, 2)]
        let b = [sample(200, 3)]
        XCTAssertEqual(Repository.mergeGravityByTs([a, b]).map(\.ts), [100, 200, 300])
    }
    /// PERF: the multi-id sample merges are a linear k-way merge of the store's ascending lists. Pinned
    /// against the dictionary form they replaced (first list wins a timestamp, first sample within it,
    /// sorted by ts) on random sorted AND unsorted inputs, with duplicate timestamps inside one list too.
    func testLinearMergeMatchesTheDictionaryFormOnRandomLists() {
        func reference(_ lists: [[HRSample]]) -> [HRSample] {
            var byTs: [Int: HRSample] = [:]
            for list in lists { for s in list where byTs[s.ts] == nil { byTs[s.ts] = s } }
            return byTs.values.sorted { $0.ts < $1.ts }
        }
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for trial in 0..<500 {
            let listCount = 1 + next(3)
            var lists: [[HRSample]] = []
            for l in 0..<listCount {
                var ts = next(20)
                var list: [HRSample] = []
                for k in 0..<next(40) {
                    ts += next(3)   // 0 steps make duplicate timestamps inside one list
                    // `bpm` records (list, position) so WHICH sample won a timestamp is compared, not just ts.
                    list.append(HRSample(ts: ts, bpm: l * 1000 + k))
                }
                if trial % 7 == 0 { list.shuffle() }   // the fallback path: an unsorted list
                lists.append(list)
            }
            XCTAssertEqual(Repository.mergeFirstWinsByTs(lists, ts: { $0.ts }), reference(lists), "trial \(trial)")
        }
    }
}
