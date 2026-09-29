import Foundation

// DeterministicRNG.swift — the one random source the habit trials use.
//
// SplitMix64 (Steele, Lea & Flood 2014): a 64-bit counter pushed through a fixed mixing function. It is
// chosen for exactly one property — it is trivially portable. Every step is a wrapping add, a shift, an
// xor or a wrapping multiply on an unsigned 64-bit integer, so a Kotlin twin (`ULong`) reproduces the same
// stream bit for bit, and a trial schedule drawn on one platform can be re-drawn and audited on the other.
//
// It is NOT Swift's `SystemRandomNumberGenerator`, and nothing here uses the standard library's
// `shuffle(using:)` / `random(in:using:)`: their algorithms are not specified and may change between
// toolchains, which would silently change a registered trial's schedule and its permutation null.
//
// The type is deliberately not named `SplitMix64`: the app target already has an internal type of that
// name (`AppleDemoSeeder.swift`), and a public one here would shadow-collide in files that import this
// package.

/// SplitMix64 pseudo-random generator. Deterministic, platform-neutral, not cryptographic.
public struct DeterministicRNG: Equatable, Sendable {

    /// The SplitMix64 increment (the 64-bit golden ratio).
    public static let gamma: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// The internal counter. Public so a test can pin the stream.
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// The SplitMix64 finaliser: a bijective avalanche mix of one 64-bit word.
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The next 64 random bits.
    public mutating func next() -> UInt64 {
        state = state &+ DeterministicRNG.gamma
        return DeterministicRNG.mix(state)
    }

    /// A uniform double in [0, 1), from the top 53 bits.
    public mutating func nextDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A uniform integer in [0, bound). Unbiased (rejection of the short top range). `bound` must be ≥ 1.
    public mutating func nextInt(below bound: Int) -> Int {
        precondition(bound >= 1, "bound must be positive")
        let b = UInt64(bound)
        // 2^64 mod b, computed without overflow: (0 − b) mod b.
        let threshold = (0 &- b) % b
        while true {
            let r = next()
            if r >= threshold { return Int(r % b) }
        }
    }

    /// A standard normal deviate (Box–Muller, cosine branch only, no cached pair — so the stream position
    /// after each call is always exactly two draws further on, which keeps twins in lock-step).
    public mutating func nextGaussian() -> Double {
        let u1 = 1.0 - nextDouble()          // (0, 1], so the log is finite
        let u2 = nextDouble()
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Double.pi * u2)
    }

    /// Fisher–Yates (Durstenfeld) shuffle, from the last index down. The exact loop is part of the
    /// contract: the schedule and its permutation null depend on it.
    public mutating func shuffle<T>(_ values: inout [T]) {
        var i = values.count - 1
        while i > 0 {
            let j = nextInt(below: i + 1)
            if j != i { values.swapAt(i, j) }
            i -= 1
        }
    }

    /// An independent seed for sub-stream `index` of `seed`.
    ///
    /// Two plain `seed + k·gamma` seeds would give OVERLAPPING streams (one is the other shifted by a
    /// step), so every derived seed goes through the finaliser twice: sub-streams start at unrelated
    /// points of the 2^64 cycle.
    public static func derive(_ seed: UInt64, stream: UInt64, index: UInt64) -> UInt64 {
        let base = mix(seed ^ mix(stream &+ 0x6A09_E667_F3BC_C909))
        return mix(base &+ (index &+ 1) &* gamma)
    }

    /// A seed suitable for a registration: 53 bits, so it survives any JSON number codec exactly.
    public static func registrationSeed(from entropy: UInt64) -> UInt64 {
        mix(entropy) >> 11
    }
}
