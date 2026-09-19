import Foundation
import WhoopProtocol

// HRZones.swift — HR-max + 5 heart-rate zones and time-in-zone from an HR stream.
//
// HR-max uses Tanaka et al. (2001): HRmax = 208 − 0.7 × age (gender-independent),
// with an optional manual override. The five zones use the conventional 50/60/70/80/90/100 % edges:
//
//   Zone 1 (50–60%) — very light / recovery
//   Zone 2 (60–70%) — light / fat-burn
//   Zone 3 (70–80%) — moderate / aerobic
//   Zone 4 (80–90%) — hard / threshold
//   Zone 5 (90–100%) — maximum
//
// TWO MODELS, ONE SET OF EDGES:
//   - %HRmax (`zones(maxHR:)`, `zones(age:)`): edge = p × HRmax. The analytics engine and the old
//     display zones.
//   - KARVONEN %HRR (`zones(maxHR:restingHR:)`): edge = RHR + p × (HRmax − RHR). THE APP'S DISPLAY /
//     TRAINING ZONES since the WHOOP-style zone rework: WHOOP bases its zones on heart-rate RESERVE, so a
//     fitter heart (lower RHR) or a higher learned HRmax moves every boundary, instead of the zones
//     sitting still at fixed fractions of an age formula. HRmax is learned from the wearer's own workout
//     peaks (`observedZoneHRmax` / `learnedZoneHRmax`) and RHR from recent nights (`zoneRestingHR`).
//
// NOTE: Effort (StrainScorer, Edwards) is NOT affected by the display model. The Python source (strain.py)
// applied Edwards' cut-offs to Karvonen %HRR; since O6 StrainScorer applies them to %HRmax, as Edwards
// published them, against the resolved Effort HRmax (override, else Tanaka). The display zones here are
// deliberately allowed to differ from that: they are a TRAINING guide, Effort is a score.

/// A single heart-rate zone defined as a bpm interval [lower, upper).
public struct HRZone: Equatable, Sendable {
    /// Zone number 1...5.
    public let number: Int
    /// Lower bound (bpm), inclusive.
    public let lower: Double
    /// Upper bound (bpm); exclusive except for the top zone where it is inclusive.
    public let upper: Double
    /// Fraction-of-HRmax lower bound (e.g. 0.50 for Zone 1 on the %HRmax model). ALWAYS lower ÷ HRmax,
    /// also on the Karvonen model (where it then sits above the 0.50 reserve edge), so a "% max HR" label
    /// built from it stays literally true whichever model built the set.
    public let lowerPct: Double
    /// Fraction-of-HRmax upper bound (e.g. 0.60 for Zone 1 on the %HRmax model).
    public let upperPct: Double

    public init(number: Int, lower: Double, upper: Double, lowerPct: Double, upperPct: Double) {
        self.number = number
        self.lower = lower
        self.upper = upper
        self.lowerPct = lowerPct
        self.upperPct = upperPct
    }
}

/// Five HR zones derived from a max HR or personalized BPM boundaries, plus the max HR itself and
/// its source.
public struct HRZoneSet: Equatable, Sendable {
    /// The five zones, z1...z5, in ascending order.
    public let zones: [HRZone]
    /// Max HR (bpm) the zones were built from.
    public let maxHR: Double
    /// "tanaka" (age formula), "manual" (caller override), "learned" (from workout peaks), or "custom"
    /// (personalized boundaries).
    public let source: String
    /// Resting HR (bpm) the Karvonen (%HRR) edges were built from; nil for the %HRmax model or custom
    /// boundaries.
    public let restingHR: Double?

    public init(zones: [HRZone], maxHR: Double, source: String, restingHR: Double? = nil) {
        self.zones = zones
        self.maxHR = maxHR
        self.source = source
        self.restingHR = restingHR
    }

    /// Whole-bpm display ranges, z1...z5, that classify integer bpm EXACTLY like `zoneNumber(forBPM:)`:
    /// a zone starts at its lower edge rounded UP and ends one bpm before the next zone starts; the top
    /// zone ends at HRmax. E.g. RHR 50 / HRmax 190 → 120–133, 134–147, 148–161, 162–175, 176–190.
    public var bpmRanges: [HRZoneBPMRange] {
        // Non-finite edges (a corrupt HRmax) read as 0 rather than trapping in Int(_:).
        func whole(_ v: Double, _ rule: FloatingPointRoundingRule) -> Int {
            v.isFinite ? Int(v.rounded(rule)) : 0
        }
        return zones.indices.map { i -> HRZoneBPMRange in
            let z = zones[i]
            let lo = whole(z.lower, .up)
            let hi = i + 1 < zones.count
                ? whole(zones[i + 1].lower, .up) - 1
                : whole(z.upper, .toNearestOrAwayFromZero)
            return HRZoneBPMRange(zone: z.number, lower: lo, upper: max(lo, hi))
        }
    }
}

/// One zone as an inclusive whole-bpm range, for display (`HRZoneSet.bpmRanges`).
public struct HRZoneBPMRange: Equatable, Hashable, Sendable, Identifiable {
    /// Zone number 1...5.
    public let zone: Int
    /// First bpm in the zone.
    public let lower: Int
    /// Last bpm in the zone.
    public let upper: Int
    public var id: Int { zone }

    public init(zone: Int, lower: Int, upper: Int) {
        self.zone = zone
        self.lower = lower
        self.upper = upper
    }
}

extension HRZoneSet {

    /// Return the zone number (1...5) for a bpm value, or 0 when below Zone 1.
    public func zoneNumber(forBPM bpm: Double) -> Int {
        for z in zones {
            // Top zone is inclusive at its upper edge so HRmax itself lands in z5.
            if z.number == 5 {
                if bpm >= z.lower { return 5 }
            } else if bpm >= z.lower && bpm < z.upper {
                return z.number
            }
        }
        return 0
    }
}

/// Time spent in each zone (seconds), including below-Zone-1 time as `belowZone1`.
public struct TimeInZone: Equatable, Sendable {
    /// Seconds in each of the five zones, indexed z1...z5 (zone[0] == Zone 1).
    public let seconds: [Double]
    /// Seconds spent below Zone 1 (HR under 50% HRmax).
    public let belowZone1: Double

    public init(seconds: [Double], belowZone1: Double) {
        self.seconds = seconds
        self.belowZone1 = belowZone1
    }

    /// Total counted seconds (Zone 1...5 plus below-Zone-1).
    public var total: Double { seconds.reduce(0, +) + belowZone1 }

    /// Seconds in a specific zone (1...5); 0 for out-of-range zone numbers.
    public func seconds(inZone zone: Int) -> Double {
        guard zone >= 1 && zone <= 5 else { return 0 }
        return seconds[zone - 1]
    }
}

public enum HRZones {

    /// %HRmax band edges for zones 1...5: [0.50, 0.60, 0.70, 0.80, 0.90, 1.00].
    public static let zoneEdges: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Sensible editable BPM range for personalized zone starts. The analytics API accepts any
    /// positive finite values; the app UIs use this range to keep steppers practical.
    public static let customBPMRange: ClosedRange<Int> = 30...250

    /// Tanaka (2001) age-predicted max HR: 208 − 0.7 × age (gender-independent).
    public static func tanakaMaxHR(age: Double) -> Double {
        208.0 - 0.7 * age
    }

    /// Build the 5-zone set from age (Tanaka) or a manual `maxHROverride`.
    ///
    /// - Parameters:
    ///   - age: age in years (used only when `maxHROverride` is nil).
    ///   - maxHROverride: explicit HRmax (bpm); when provided, `source == "manual"`.
    public static func zones(age: Double,
                             maxHROverride: Double? = nil,
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let maxHR: Double
        let source: String
        if let override = maxHROverride {
            maxHR = override
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age: age)
            source = "tanaka"
        }
        return zones(maxHR: maxHR, source: source, customLowerBounds: customLowerBounds)
    }

    /// Build the 5-zone set directly from a known max HR, optionally replacing the conventional
    /// percentage edges with five personalized inclusive lower bounds in BPM. Invalid custom input
    /// falls back to the conventional model, so malformed restored preferences can never create gaps.
    public static func zones(maxHR: Double,
                             source: String = "manual",
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        zones(maxHR: maxHR, restingHR: nil, source: source, customLowerBounds: customLowerBounds)
    }

    /// Karvonen (%HRR) zone edge: RHR + p × (HRmax − RHR). With no usable resting HR (nil, non-finite,
    /// ≤ 0, or not below HRmax) this is the plain %HRmax edge p × HRmax.
    public static func karvonenEdge(_ pct: Double, maxHR: Double, restingHR: Double?) -> Double {
        guard let r = usableRestingHR(restingHR, maxHR: maxHR) else { return pct * maxHR }
        // Snapped to 1e-6 bpm: 50 + 0.6 × 140 must be 134, not 134.00000000000003 (which would start the
        // zone at 135 once rounded up to a whole bpm).
        return ((r + pct * (maxHR - r)) * 1e6).rounded() / 1e6
    }

    /// The resting HR the Karvonen model will actually use, or nil (→ %HRmax) when it can't be.
    static func usableRestingHR(_ restingHR: Double?, maxHR: Double) -> Double? {
        guard let r = restingHR, r.isFinite, r > 0, maxHR.isFinite, r < maxHR else { return nil }
        return r
    }

    /// Build the 5-zone set on the KARVONEN (%HRR) model: zone k starts at RHR + p_k × (HRmax − RHR),
    /// p = 0.50, 0.60, 0.70, 0.80, 0.90, and the top zone ends at HRmax. A nil / unusable `restingHR`
    /// builds the %HRmax set (so this is a strict superset of `zones(maxHR:source:customLowerBounds:)`).
    /// Valid `customLowerBounds` still win over both models.
    public static func zones(maxHR: Double,
                             restingHR: Double?,
                             source: String = "manual",
                             customLowerBounds: [Double]? = nil) -> HRZoneSet {
        let custom = customLowerBounds.flatMap(validCustomLowerBounds)
        let rest = custom == nil ? usableRestingHR(restingHR, maxHR: maxHR) : nil
        var built: [HRZone] = []
        for i in 0..<5 {
            let lower = custom?[i] ?? karvonenEdge(zoneEdges[i], maxHR: maxHR, restingHR: rest)
            let upper = custom.map { i < 4 ? $0[i + 1] : max(maxHR, $0[i]) }
                ?? karvonenEdge(zoneEdges[i + 1], maxHR: maxHR, restingHR: rest)
            let loPct = maxHR > 0 ? lower / maxHR : 0
            let hiPct = maxHR > 0 ? upper / maxHR : 0
            built.append(HRZone(
                number: i + 1,
                lower: lower,
                upper: upper,
                lowerPct: loPct,
                upperPct: hiPct
            ))
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: custom == nil ? source : "custom",
                         restingHR: rest)
    }

    /// The conventional five inclusive lower bounds, rounded up to whole BPM for an editor. Rounding
    /// up preserves the existing integer-sample classification (e.g. a 93.5 edge starts at 94 bpm).
    public static func defaultLowerBounds(maxHR: Double) -> [Int] {
        defaultLowerBounds(maxHR: maxHR, restingHR: nil)
    }

    /// Same, on the Karvonen model (nil `restingHR` → %HRmax), so switching custom zones ON seeds the
    /// editor with exactly the zones the wearer was just looking at.
    public static func defaultLowerBounds(maxHR: Double, restingHR: Double?) -> [Int] {
        Array(zoneEdges.prefix(5)).map { Int(ceil(karvonenEdge($0, maxHR: maxHR, restingHR: restingHR))) }
    }

    // MARK: - Dynamic HRmax / resting HR for the display zones (WHOOP-style)

    /// Trailing window (days) of workouts whose peaks feed the learned zone HRmax. A peak older than this
    /// stops holding the HRmax up, so a one-off season of racing doesn't pin the zones forever.
    public static let zoneHRmaxWindowDays: Int = 180
    /// Workouts with a plausible peak needed before the learned HRmax trusts them (fewer than
    /// `StrainScorer.robustHRmaxMinWorkouts`: the zones only ever move UP from the age formula with it).
    public static let zoneHRmaxMinWorkouts: Int = 3
    /// How fast (bpm/day) a learned HRmax may SINK towards a lower target once its supporting peaks age
    /// out of the window. Rises are immediate; falls are slow (about 7.5 bpm a month) so the zones drift
    /// rather than jump when one old peak leaves the window.
    public static let zoneHRmaxDecayPerDay: Double = 0.25
    /// Nights of sleep resting HR whose median sets the zones' resting HR.
    public static let zoneRestingHRNights: Int = 7
    /// Resting HR used when there is no measured one at all.
    public static let defaultZoneRestingHR: Double = 60
    /// Physiological bounds for a resting HR fed to the zones; anything outside is ignored.
    public static let zoneRestingHRPlausible: ClosedRange<Double> = 30...110

    /// Where the zones' HRmax came from.
    public enum HRmaxSource: String, Equatable, Sendable {
        /// The user's Settings override.
        case manual
        /// The wearer's own workout peaks pushed it above the age formula.
        case learned
        /// Tanaka from age (no / too few / too low workout peaks).
        case ageFormula
    }

    /// A resolved zone HRmax and its provenance.
    public struct ZoneHRmax: Equatable, Sendable {
        public let bpm: Double
        public let source: HRmaxSource
        public init(bpm: Double, source: HRmaxSource) { self.bpm = bpm; self.source = source }
    }

    /// Where the zones' resting HR came from.
    public enum RestingHRSource: String, Equatable, Sendable {
        /// Median of the last `zoneRestingHRNights` nights' sleep resting HR.
        case sleepMedian
        /// Median of the waking resting HR series (`WakingRestingHR.metricKey`): no sleep RHR available.
        case waking
        /// Nothing measured: `defaultZoneRestingHR`.
        case fallback
    }

    /// A resolved zone resting HR and its provenance.
    public struct ZoneRestingHR: Equatable, Sendable {
        public let bpm: Double
        public let source: RestingHRSource
        public init(bpm: Double, source: RestingHRSource) { self.bpm = bpm; self.source = source }
    }

    /// The robust OBSERVED HRmax for the zones: the SECOND-highest plausible (100–220 bpm) workout peak
    /// among workouts that started within `windowDays` of `now`, once at least `minWorkouts` carry one;
    /// nil otherwise. The single highest peak is dropped as the likeliest artefact (a loose-strap spike
    /// that still lands inside the plausible band). Pure.
    ///
    /// - Parameters:
    ///   - workoutPeaks: per-workout (start unix seconds, peak bpm).
    ///   - now: unix seconds.
    public static func observedZoneHRmax(workoutPeaks: [(ts: Int, bpm: Double)],
                                         now: Int,
                                         windowDays: Int = zoneHRmaxWindowDays,
                                         minWorkouts: Int = zoneHRmaxMinWorkouts) -> Double? {
        let cutoff = now - windowDays * 86_400
        let recent: [Double] = workoutPeaks.filter { $0.ts >= cutoff }.map { $0.bpm }
        return StrainScorer.robustObservedHRmax(workoutPeaks: recent, minWorkouts: minWorkouts)
    }

    /// The LEARNED zone HRmax (ignores any manual override; see `resolveZoneHRmax`).
    ///
    /// TARGET = max(Tanaka(age), observed). It RISES immediately: a target above the previous value is
    /// taken as is. It FALLS slowly: when the target is below the previous learned value (its peaks aged
    /// out of the window), the value sinks by at most `decayPerDay` × days since `previousAt`, never below
    /// the target. So a stale peak can't pin the zones forever, and one peak leaving the window doesn't
    /// make every boundary jump. Pure.
    ///
    /// - Parameters:
    ///   - age: years (≤ 0 → no formula floor; with no workouts either, the age-30 default).
    ///   - observed: `observedZoneHRmax(...)`, or nil.
    ///   - previous: the last learned value this returned (persisted by the caller), or nil.
    ///   - previousAt / now: unix seconds of that value and of this evaluation.
    public static func learnedZoneHRmax(age: Double,
                                        observed: Double?,
                                        previous: Double?,
                                        previousAt: Int?,
                                        now: Int,
                                        decayPerDay: Double = zoneHRmaxDecayPerDay) -> ZoneHRmax {
        let formula = age > 0 ? tanakaMaxHR(age: age) : tanakaMaxHR(age: 30)
        let obs: Double? = observed.flatMap {
            $0.isFinite && StrainScorer.robustHRmaxPlausible.contains($0) ? $0 : nil
        }
        let target = max(formula, obs ?? 0)
        var bpm = target
        if let prev = previous, prev.isFinite, StrainScorer.robustHRmaxPlausible.contains(prev), prev > target,
           let at = previousAt {
            let days = max(0, Double(now - at) / 86_400)
            bpm = max(target, prev - decayPerDay * days)
        }
        return ZoneHRmax(bpm: bpm, source: bpm > formula + 1e-9 ? .learned : .ageFormula)
    }

    /// The zone HRmax actually used: the manual override when set (> 0), else the learned value.
    public static func resolveZoneHRmax(overrideBpm: Double?, learned: ZoneHRmax) -> ZoneHRmax {
        if let o = overrideBpm, o > 0, o.isFinite { return ZoneHRmax(bpm: o, source: .manual) }
        return learned
    }

    /// The zones' resting HR: the MEDIAN of the most recent `nights` plausible sleep resting HRs (input
    /// oldest → newest); else the median of the most recent plausible waking resting HRs
    /// (`WakingRestingHR.metricKey`, used as is); else `defaultZoneRestingHR`. Pure.
    public static func zoneRestingHR(sleepRestingHRs: [Double],
                                     wakingRestingHRs: [Double] = [],
                                     nights: Int = zoneRestingHRNights) -> ZoneRestingHR {
        let n = max(1, nights)
        let sleep = Array(sleepRestingHRs.filter { $0.isFinite && zoneRestingHRPlausible.contains($0) }.suffix(n))
        if let m = median(sleep) { return ZoneRestingHR(bpm: m, source: .sleepMedian) }
        let waking = Array(wakingRestingHRs.filter { $0.isFinite && zoneRestingHRPlausible.contains($0) }.suffix(n))
        if let m = median(waking) { return ZoneRestingHR(bpm: m, source: .waking) }
        return ZoneRestingHR(bpm: defaultZoneRestingHR, source: .fallback)
    }

    /// Median of `values`, or nil when empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted()
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }

    /// Return a valid five-boundary custom model, or nil unless values are positive, finite, and
    /// strictly increasing. Kept public so persistence layers can reject hand-edited backup values
    /// using the exact same invariant as the analytics engine.
    public static func validCustomLowerBounds(_ values: [Double]) -> [Double]? {
        guard values.count == 5,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        for i in 1..<values.count where values[i] <= values[i - 1] { return nil }
        return values
    }

    /// Compute time-in-zone (seconds) from a time-ordered HR stream.
    ///
    /// Each sample is credited with the duration until the next sample (the
    /// "hold until next reading" convention). The final sample is credited with
    /// the median inter-sample interval (so a constant-rate stream is fully
    /// accounted for). Samples are sorted defensively by ts.
    ///
    /// - Parameters:
    ///   - hr: time-ordered (or unordered) `[HRSample]`.
    ///   - zoneSet: the zone definitions to bucket against.
    public static func timeInZone(_ hr: [HRSample], zoneSet: HRZoneSet) -> TimeInZone {
        let sorted = hr.sorted { $0.ts < $1.ts }
        var zoneSeconds = [Double](repeating: 0, count: 5)
        var below: Double = 0

        guard !sorted.isEmpty else {
            return TimeInZone(seconds: zoneSeconds, belowZone1: 0)
        }

        // Tail sample gets the median inter-sample gap so the series is fully counted.
        let tailDuration = medianInterval(sorted)

        for i in 0..<sorted.count {
            let dur: Double
            if i < sorted.count - 1 {
                let gap = Double(sorted[i + 1].ts - sorted[i].ts)
                // Guard against zero/negative or pathological gaps; cap at the median
                // so a single huge wall-clock gap doesn't blow up one bucket.
                dur = (gap > 0) ? min(gap, tailDuration) : tailDuration
            } else {
                dur = tailDuration
            }
            let z = zoneSet.zoneNumber(forBPM: Double(sorted[i].bpm))
            if z >= 1 {
                zoneSeconds[z - 1] += dur
            } else {
                below += dur
            }
        }
        return TimeInZone(seconds: zoneSeconds, belowZone1: below)
    }

    /// Median spacing between consecutive timestamps, restricted to plausible
    /// (0, 300 s] gaps. Falls back to 1.0 s when no plausible gap exists.
    static func medianInterval(_ sorted: [HRSample]) -> Double {
        guard sorted.count >= 2 else { return 1.0 }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = Double(sorted[i].ts - sorted[i - 1].ts)
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 1.0 }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }
}
