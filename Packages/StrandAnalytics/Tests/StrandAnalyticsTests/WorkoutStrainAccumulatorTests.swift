import XCTest
import Foundation
@testable import StrandAnalytics
import WhoopProtocol

/// Pins `WorkoutStrainAccumulator` to `StrainScorer.strain` with EXACT (`==`) equality, not a tolerance:
/// the live workout card swapped a full re-score per sample for the running sum, and the number it shows
/// must be the number the scorer would have produced. Every prefix of each randomized series is compared,
/// so the sparse / dense data-gate crossings and every gap shape are covered on the way.
final class WorkoutStrainAccumulatorTests: XCTestCase {

    /// Deterministic SplitMix64 so a failure reproduces.
    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }
    }

    /// A workout-shaped series: mostly ~1 Hz with jitter, same-second repeats (zero gaps), occasional
    /// pauses / dropouts longer than the 2-minute clamp, sparse stretches, and a random-walk bpm.
    private func series(seed: UInt64, count: Int) -> [HRSample] {
        var rng = Rng(state: seed)
        var ts = 1_700_000_000 + rng.int(0...1000)
        var bpm = rng.int(60...120)
        var out: [HRSample] = []
        for _ in 0..<count {
            out.append(HRSample(ts: ts, bpm: bpm))
            switch rng.int(0...99) {
            case 0..<8:   ts += 0                          // same-second repeat
            case 8..<80:  ts += 1
            case 80..<90: ts += rng.int(2...5)
            case 90..<96: ts += rng.int(20...40)           // sparse cadence
            default:      ts += rng.int(121...900)         // pause / dropout beyond the clamp
            }
            bpm = min(205, max(45, bpm + rng.int(-6...6)))
        }
        return out
    }

    private func assertMatchesScorerAtEveryPrefix(_ samples: [HRSample], maxHR: Double?, restingHR: Double,
                                                  method: StrainScorer.Method, sex: String,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        var acc = WorkoutStrainAccumulator(maxHR: maxHR, restingHR: restingHR, method: method, sex: sex)
        var prefix: [HRSample] = []
        for s in samples {
            acc.append(s)
            prefix.append(s)
            let expected = StrainScorer.strain(prefix, maxHR: maxHR, restingHR: restingHR,
                                               method: method, sex: sex)
            XCTAssertEqual(acc.strain, expected, "n=\(prefix.count) \(method) \(sex)", file: file, line: line)
            XCTAssertEqual(acc.bpmSum, prefix.map(\.bpm).reduce(0, +), file: file, line: line)
            XCTAssertEqual(acc.count, prefix.count, file: file, line: line)
        }
        // The rebuild-from-series initializer lands on the same value as the incremental path.
        let rebuilt = WorkoutStrainAccumulator(samples: samples, maxHR: maxHR, restingHR: restingHR,
                                               method: method, sex: sex)
        XCTAssertEqual(rebuilt.strain, acc.strain, file: file, line: line)
    }

    func testEqualsScorerOnRandomizedSeriesBothMethods() {
        let configs: [(maxHR: Double?, rest: Double, sex: String)] = [
            (187, 60, "male"), (190, 52, "female"), (nil, 60, "male"), (172, 71, "F"),
        ]
        for (i, c) in configs.enumerated() {
            let samples = series(seed: UInt64(0xC0FFEE + i), count: 720)   // crosses the 600 dense gate
            for method in [StrainScorer.Method.edwards, .banister] {
                assertMatchesScorerAtEveryPrefix(samples, maxHR: c.maxHR, restingHR: c.rest,
                                                 method: method, sex: c.sex)
            }
        }
    }

    func testEqualsScorerOnSparseSeries() {
        // A 5/MG-like ~30 s cadence: scored through the sparse span gate, not the dense count.
        var rng = Rng(state: 42)
        var ts = 1_700_000_000
        var samples: [HRSample] = []
        for _ in 0..<60 {
            samples.append(HRSample(ts: ts, bpm: rng.int(90...180)))
            ts += rng.int(25...35)
        }
        for method in [StrainScorer.Method.edwards, .banister] {
            assertMatchesScorerAtEveryPrefix(samples, maxHR: 185, restingHR: 58, method: method, sex: "male")
        }
    }

    func testReplaceLastEqualsScorerOnTheReplacedSeries() {
        // The live capture keeps one sample per whole second by overwriting the last bpm; the running
        // sum must stay exact across those overwrites.
        var rng = Rng(state: 7)
        for method in [StrainScorer.Method.edwards, .banister] {
            var acc = WorkoutStrainAccumulator(maxHR: 188, restingHR: 60, method: method, sex: "male")
            var samples: [HRSample] = []
            var ts = 1_700_000_000
            for _ in 0..<700 {
                let bpm = rng.int(70...195)
                if let last = samples.last, last.ts == ts {
                    samples[samples.count - 1] = HRSample(ts: ts, bpm: bpm)
                    acc.replaceLast(bpm: bpm)
                } else {
                    let s = HRSample(ts: ts, bpm: bpm)
                    samples.append(s)
                    acc.append(s)
                }
                XCTAssertEqual(acc.strain, StrainScorer.strain(samples, maxHR: 188, restingHR: 60,
                                                               method: method, sex: "male"))
                XCTAssertEqual(acc.bpmSum, samples.map(\.bpm).reduce(0, +))
                if rng.int(0...2) != 0 { ts += 1 }   // ~1/3 of arrivals land in the same second
            }
        }
    }

    func testRefusalsMatchScorer() {
        // Too few readings, and an HRmax at or below resting HR, both refuse (nil) like the scorer.
        var acc = WorkoutStrainAccumulator(maxHR: 180, restingHR: 60, method: .edwards, sex: "male")
        XCTAssertNil(acc.strain)
        acc.append(HRSample(ts: 1_700_000_000, bpm: 150))
        XCTAssertNil(acc.strain)
        let flat = (0..<700).map { HRSample(ts: 1_700_000_000 + $0, bpm: 150) }
        let invalid = WorkoutStrainAccumulator(samples: flat, maxHR: 55, restingHR: 60, method: .edwards,
                                               sex: "male")
        XCTAssertNil(invalid.strain)
        XCTAssertNil(StrainScorer.strain(flat, maxHR: 55, restingHR: 60))
    }

    func testMatchesReportsConfigChanges() {
        let acc = WorkoutStrainAccumulator(maxHR: 187, method: .edwards, sex: "male")
        XCTAssertTrue(acc.matches(maxHR: 187, method: .edwards, sex: "male"))
        XCTAssertFalse(acc.matches(maxHR: 186, method: .edwards, sex: "male"))
        XCTAssertFalse(acc.matches(maxHR: 187, method: .banister, sex: "male"))
        XCTAssertFalse(acc.matches(maxHR: 187, method: .edwards, sex: "female"))
    }
}
