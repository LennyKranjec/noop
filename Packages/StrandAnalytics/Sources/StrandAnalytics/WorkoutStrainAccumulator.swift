import Foundation
import WhoopProtocol

// WorkoutStrainAccumulator.swift — the live manual-workout Effort, kept as a running sum.
//
// The live workout card re-scored its whole growing HR window on every captured sample, which is O(n²)
// over a session (a two-hour session re-integrates ~7,200 samples every second by the end) and churned
// `StrainScorer`'s small memo with one never-reused entry per sample.
//
// Nothing about the score needs that. Each reading's TRIMP term depends only on its own bpm and the gap
// to the NEXT reading (`StrainScorer.sampleDurationsMinutes`), so once a successor arrives a term is final.
// Only the LAST reading is provisional: it has no successor and borrows the gap before it. This keeps the
// finalized terms as one running sum, added in the scorer's own index order through the scorer's own
// per-sample helpers, and adds the provisional last term on read — so `strain` is the same Double, bit for
// bit, as `StrainScorer.strain(samples, maxHR:restingHR:method:sex:)` over the same samples (pinned by
// WorkoutStrainAccumulatorTests on randomized series). The data gate (dense count, or sparse span) and the
// invalid-HRR refusal are cheap running scalars, re-checked on every read exactly as the scorer checks them.
//
// Scope: the scorer's DEFAULT denominator for the method and the ungated zone 1 — what a workout uses.
// A day integral (`.day` gate) or a denominator override still goes through `StrainScorer.strain`.

public struct WorkoutStrainAccumulator: Sendable {
    public let maxHR: Double?
    public let restingHR: Double
    public let method: StrainScorer.Method
    public let sex: String

    /// Readings folded in so far, and the integer sum of their bpm (for a running average).
    public private(set) var count: Int = 0
    public private(set) var bpmSum: Int = 0

    // Resolved once, exactly as `strainUncached` resolves them per call.
    private let effMax: Double
    private let hrReserve: Double
    private let denominator: Double
    private let banisterB: Double
    private let banisterFloor: Double

    /// Σ TRIMP over every reading but the last, in index order.
    private var finalized: Double = 0
    private var last: HRSample?
    /// The (clamped) gap from the second-to-last reading to `last` — the duration `last` borrows.
    private var lastGapMin: Double?
    private var minTs = Int.max
    private var maxTs = Int.min

    public init(maxHR: Double?, restingHR: Double = StrainScorer.defaultRestingHR,
                method: StrainScorer.Method = .edwards, sex: String = "male") {
        self.maxHR = maxHR
        self.restingHR = restingHR
        self.method = method
        self.sex = sex
        effMax = maxHR ?? Double(StrainScorer.defaultMaxHR())
        hrReserve = effMax - restingHR
        denominator = StrainScorer.logMapDenominator(method: method, sex: sex)
        banisterB = sex.lowercased().hasPrefix("f") ? StrainScorer.banisterBWomen : StrainScorer.banisterBMen
        banisterFloor = StrainScorer.banisterBaselineRatePerMinute(b: banisterB)
    }

    /// Rebuild from a whole series (rehydrate, or a profile / method change mid-session). O(n) once.
    public init(samples: [HRSample], maxHR: Double?, restingHR: Double = StrainScorer.defaultRestingHR,
                method: StrainScorer.Method = .edwards, sex: String = "male") {
        self.init(maxHR: maxHR, restingHR: restingHR, method: method, sex: sex)
        for s in samples { append(s) }
    }

    /// Whether this accumulator scores with these inputs — false means rebuild it.
    public func matches(maxHR: Double?, restingHR: Double = StrainScorer.defaultRestingHR,
                        method: StrainScorer.Method, sex: String) -> Bool {
        self.maxHR == maxHR && self.restingHR == restingHR && self.method == method && self.sex == sex
    }

    /// Fold in the next reading. The previous last reading now has a successor, so its term is final.
    public mutating func append(_ s: HRSample) {
        if let prev = last {
            // Same expression as `sampleDurationsMinutes`, clamp included.
            let deltaS = abs(Double(s.ts - prev.ts))
            let minutes = deltaS > 0 ? deltaS / 60.0 : StrainScorer.fallbackSampleMin
            let d = min(minutes, StrainScorer.maxSampleGapMin)
            if let t = term(prev, duration: d) { finalized += t }
            lastGapMin = d
        }
        last = s
        count += 1
        bpmSum += s.bpm
        minTs = Swift.min(minTs, s.ts)
        maxTs = Swift.max(maxTs, s.ts)
    }

    /// Swap the last reading's bpm (same timestamp). Exact: the last term is never part of the running sum.
    public mutating func replaceLast(bpm: Int) {
        guard let prev = last else { return }
        bpmSum += bpm - prev.bpm
        last = HRSample(ts: prev.ts, bpm: bpm)
    }

    /// `StrainScorer.strain(samples, maxHR:restingHR:method:sex:)` over everything appended so far.
    public var strain: Double? {
        // The scorer's gate, spelled the same way (including how a NaN HRmax falls through it).
        let enoughData: Bool
        if count >= StrainScorer.minReadings {
            enoughData = true
        } else if count >= StrainScorer.minSparseReadings {
            enoughData = (maxTs - minTs) >= StrainScorer.minSpanSeconds
        } else {
            enoughData = false
        }
        if !enoughData || effMax <= restingHR { return nil }
        guard let last else { return nil }
        // A lone reading has no gap to borrow; the scorer credits it the 1 s fallback.
        var trimp = finalized
        if let t = term(last, duration: lastGapMin ?? StrainScorer.fallbackSampleMin) { trimp += t }
        return StrainScorer.trimpToStrain(trimp, denominator: denominator)
    }

    private func term(_ s: HRSample, duration: Double) -> Double? {
        switch method {
        case .edwards:
            return StrainScorer.edwardsSampleTRIMP(s, restingHR: restingHR, hrReserve: hrReserve,
                                                   duration: duration, zone1Gate: .ungated)
        case .banister:
            return StrainScorer.banisterSampleTRIMP(s, restingHR: restingHR, hrReserve: hrReserve,
                                                    duration: duration, b: banisterB,
                                                    floorRatePerMinute: banisterFloor)
        }
    }
}
