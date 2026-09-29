import XCTest
@testable import StrandAnalytics

/// The trial RNG is part of the audit trail: a registered schedule must re-draw bit for bit on any
/// platform. These pins are the reference SplitMix64 stream (seed 0 → 0xE220A8397B1DCDAF is the published
/// first output) and values reproduced by an independent Python twin.
final class DeterministicRNGTests: XCTestCase {

    func testSplitMix64ReferenceStream() {
        var r = DeterministicRNG(seed: 0)
        XCTAssertEqual(r.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(r.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(r.next(), 0x06C4_5D18_8009_454F)
        var s = DeterministicRNG(seed: 42)
        XCTAssertEqual(s.next(), 0xBDD7_3226_2FEB_6E95)
        XCTAssertEqual(s.next(), 0x28EF_E333_B266_F103)
    }

    func testDerivedValuesMatchTwin() {
        var r = DeterministicRNG(seed: 7)
        XCTAssertEqual(r.nextDouble(), 0.3898297483912715, accuracy: 1e-15)
        XCTAssertEqual(r.nextInt(below: 10), 4)
        XCTAssertEqual(r.nextGaussian(), -1.8642558067312274, accuracy: 1e-12)
        XCTAssertEqual(DeterministicRNG.derive(1, stream: 2, index: 3), 0xCDF4_3FB9_452F_6621)
        XCTAssertEqual(HabitTrialSchedule.permutationSeed(registered: 12_345, index: 0), 0xF429_E35D_CA18_92B0)
    }

    func testSameSeedSameStreamDifferentSeedDifferentStream() {
        var a = DeterministicRNG(seed: 99)
        var b = DeterministicRNG(seed: 99)
        var c = DeterministicRNG(seed: 100)
        var xa: [UInt64] = [], xb: [UInt64] = [], xc: [UInt64] = []
        for _ in 0..<16 {
            xa.append(a.next())
            xb.append(b.next())
            xc.append(c.next())
        }
        XCTAssertEqual(xa, xb)
        XCTAssertNotEqual(xa, xc)
    }

    func testNextIntIsInRangeAndRoughlyUniform() {
        var r = DeterministicRNG(seed: 5)
        var counts = [Int](repeating: 0, count: 7)
        for _ in 0..<70_000 {
            let v = r.nextInt(below: 7)
            XCTAssertTrue((0..<7).contains(v))
            counts[v] += 1
        }
        for c in counts { XCTAssertEqual(Double(c), 10_000, accuracy: 400) }
    }

    func testShuffleIsAPermutation() {
        var r = DeterministicRNG(seed: 1)
        var v = Array(0..<20)
        r.shuffle(&v)
        XCTAssertEqual(v.sorted(), Array(0..<20))
        XCTAssertNotEqual(v, Array(0..<20))
    }

    func testGaussianMoments() {
        var r = DeterministicRNG(seed: 3)
        var xs: [Double] = []
        for _ in 0..<20_000 { xs.append(r.nextGaussian()) }
        XCTAssertEqual(HabitStats.mean(xs)!, 0, accuracy: 0.03)
        XCTAssertEqual(HabitStats.sampleSD(xs)!, 1, accuracy: 0.03)
    }

    func testDerivedSubstreamsDoNotOverlap() {
        // Consecutive sub-seeds must not be one step apart on the same stream.
        let s0 = DeterministicRNG.derive(77, stream: 1, index: 0)
        let s1 = DeterministicRNG.derive(77, stream: 1, index: 1)
        var a = DeterministicRNG(seed: s0)
        _ = a.next()
        var b = DeterministicRNG(seed: s1)
        XCTAssertNotEqual(a.next(), b.next())
        XCTAssertNotEqual(s1 &- s0, DeterministicRNG.gamma)
    }

    func testRegistrationSeedFitsIn53Bits() {
        let entropies: [UInt64] = [0, 1, UInt64.max, 0xDEAD_BEEF]
        for e in entropies {
            XCTAssertLessThan(DeterministicRNG.registrationSeed(from: e), UInt64(1) << 53)
        }
    }
}
