import Foundation
import WhoopProtocol

// SessionIntensity.swift — aerobic minutes per recorded session, by relative intensity (HEALTH_V2 S3 §3.2).
//
// WHAT IT COUNTS. Minutes inside recorded sessions (manual, imported and detected `workout` rows), each
// heart-rate sample classed by its fraction of heart-rate reserve (ACSM, Garber 2011 position stand):
//
//     f = (hr − rhrZone) / (hrMax − rhrZone)
//     moderate  0.40 ≤ f < 0.60
//     vigorous  f ≥ 0.60
//     hard      f ≥ 0.80   (reported separately; hard minutes are also vigorous minutes)
//
// and summed into the WHO equivalence `mvpaEq = moderate + 2 × vigorous` (Bull 2020: 75 vigorous minutes
// count as 150 moderate ones).
//
// WHAT IT DOES NOT COUNT, stated to the wearer in the detail view: brisk walking outside a session, and
// the minutes a very fit person spends below the moderate line. This is a session counter, not a
// whole-day activity monitor.
//
// HONESTY RULES (each one has a test):
//   * No zone inputs (no measured resting HR, or an HRmax that leaves < 20 bpm of reserve) ⇒ the day
//     abstains (`zoneInputsMissing`); a 60-bpm placeholder is never used as a resting HR.
//   * A session window with < 50 % heart-rate coverage is `unmeasured`: counted as a session, adding NO
//     minutes, and never scored as 0 minutes of activity.
//   * A session with no strap HR but WHOOP-imported zone percentages is counted from those (z2–z3
//     moderate, z4–z5 vigorous), flagged `importedZones`, and shown as approximate ("≈"). Imported zones
//     are %HRmax, not %HRR, and give no "hard" minutes.
//   * Overlapping windows (a detected bout inside a logged workout) are UNIONED, so no minute is counted
//     twice.
//   * A sample is credited with the gap to the next one, capped at `StrainScorer.maxSampleGapMin` (2 min)
//     and never past the window's end — so one reading before a dropout cannot invent minutes.
//
// ZONE 4–5 MINUTES (the week plan's high-intensity line). Counted by the same sample walk, inside the same
// sessions: a strap sample at or above the lower edge of ZONE 4 of the app's display zones
// (`ProfileStore.hrZoneSet` — Karvonen 80 % of heart-rate reserve, or the wearer's custom boundary) adds its
// credited time. Without an explicit edge the Karvonen zone-4 edge is used, which is exactly `hardLow`
// (f ≥ 0.80), so zone 4–5 minutes and "hard" minutes are the same number on the default zones. An
// imported-zones session adds WHOOP's own z4 + z5 share ("≈"); an unmeasured session adds nothing.
//
// Pure, deterministic, DB-free. Swift-only engine (HEALTH_V2 platform note): platform-neutral arithmetic
// so a Kotlin twin can be added later without changing results.

public enum SessionIntensity {

    // MARK: - Thresholds (each with its reason)

    /// Lower edge of moderate intensity as a fraction of heart-rate reserve (ACSM / Garber 2011: 40–59 %).
    public static let moderateLow: Double = 0.40
    /// Lower edge of vigorous intensity (ACSM: 60–89 % HRR).
    public static let vigorousLow: Double = 0.60
    /// "Hard" minutes, reported separately: the top of the vigorous band (≥ 80 % HRR), the intensity the
    /// HRV-guided training studies move away from suppressed days.
    public static let hardLow: Double = 0.80
    /// A session is a "hard session" with ≥ 10 hard minutes: long enough to be a deliberate interval /
    /// tempo block rather than a hill or a sprint to the bus.
    public static let hardSessionMinutes: Double = 10
    /// Below 50 % of the window covered by heart rate the minutes are not a measurement of the session.
    public static let minCoverage: Double = 0.50
    /// Coverage bucket width (s). Bucketed, not sample-counted, so the 5/MG's ~30 s cadence reads as full
    /// coverage — the same rule as `WorkoutDetector.hrCoveragePct`.
    public static let coverageBucketSeconds: Int = 60
    /// A strength-category workout counts as a strength session from 20 min: shorter entries are warm-ups
    /// or mis-taps, and the muscle-strengthening evidence (Momma 2022) is at 30–60 min per week, i.e. two
    /// sessions of roughly this length.
    public static let strengthMinMinutes: Double = 20
    /// HRmax must exceed the zone resting HR by at least this much for %HRR to mean anything (the same
    /// floor `VO2MaxEstimator.fromSession` applies).
    public static let minReserveBpm: Double = 20

    // MARK: - Types

    /// Where a session's minutes came from.
    public enum Source: String, Codable, Equatable, Sendable {
        /// Strap heart rate covered the window (≥ `minCoverage`).
        case strapHR
        /// No usable strap HR; WHOOP-imported zone percentages. Approximate ("≈").
        case importedZones
        /// Neither: counted as a session, adds no minutes.
        case unmeasured
    }

    /// Why a day's intensity could not be computed at all.
    public enum Abstention: String, Codable, Equatable, Sendable {
        /// No measured resting HR or HRmax (or a reserve under `minReserveBpm`).
        case zoneInputsMissing
    }

    /// One recorded session as the classifier needs it.
    public struct Window: Equatable, Sendable {
        public let start: Int
        public let end: Int
        /// The workout's sport label (used for the strength category).
        public let sport: String
        /// WHOOP-imported zone percentages z1…z5 (0–100 of the duration), or nil.
        public let zonePercents: [Double]?

        public init(start: Int, end: Int, sport: String, zonePercents: [Double]? = nil) {
            self.start = start
            self.end = end
            self.sport = sport
            self.zonePercents = zonePercents
        }

        public var durationMin: Double { Double(max(0, end - start)) / 60.0 }
    }

    /// Minutes for one (possibly unioned) session interval.
    public struct SessionMinutes: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public let moderateMin: Double
        public let vigorousMin: Double
        public let hardMin: Double
        /// Minutes at or above the zone-4 edge (zones 4 + 5 of the display zones).
        public let zone45Min: Double
        /// Fraction of the window covered by HR (0–1), nil when no HR was read.
        public let coverage: Double?
        public let source: Source

        public var mvpaEq: Double { moderateMin + 2 * vigorousMin }
        public var hardSession: Bool { hardMin >= SessionIntensity.hardSessionMinutes }
    }

    /// One day's summary — what `SessionIntensityCache` persists.
    public struct DaySummary: Equatable, Sendable {
        public let moderateMin: Double
        public let vigorousMin: Double
        public let hardMin: Double
        /// Zone 4–5 minutes inside the day's sessions (strap HR, or imported z4 + z5 when approximate).
        /// Meaningless (0) when `abstained` is set — read it as unknown then, never as zero.
        public let zone45Min: Double
        public let hardSession: Bool
        public let strengthSession: Bool
        /// Sessions (after union) seen that day.
        public let sessionCount: Int
        /// Sessions that were `unmeasured` (no minutes added).
        public let unmeasuredCount: Int
        /// True when any minutes came from imported zones (the card marks the figure "≈").
        public let approximate: Bool
        /// Non-nil ⇒ the minute fields are all 0 and MUST NOT be read as "no activity".
        public let abstained: Abstention?

        public var mvpaEq: Double { moderateMin + 2 * vigorousMin }

        public static func abstaining(_ reason: Abstention, sessions: Int, strength: Bool) -> DaySummary {
            DaySummary(moderateMin: 0, vigorousMin: 0, hardMin: 0, zone45Min: 0, hardSession: false,
                       strengthSession: strength, sessionCount: sessions, unmeasuredCount: sessions,
                       approximate: false, abstained: reason)
        }
    }

    public enum IntensityClass: Equatable, Sendable { case below, moderate, vigorous, hard }

    // MARK: - Classification

    /// The %HRR fraction for one reading, nil when the zone inputs cannot support one.
    public static func hrrFraction(bpm: Double, restingHR: Double, hrMax: Double) -> Double? {
        guard bpm.isFinite, restingHR.isFinite, hrMax.isFinite, hrMax - restingHR >= minReserveBpm else {
            return nil
        }
        return (bpm - restingHR) / (hrMax - restingHR)
    }

    /// Class of one HRR fraction. Edges are inclusive at the bottom: exactly 0.40 is moderate, exactly
    /// 0.60 vigorous, exactly 0.80 hard.
    public static func classify(_ f: Double) -> IntensityClass {
        if f >= hardLow { return .hard }
        if f >= vigorousLow { return .vigorous }
        if f >= moderateLow { return .moderate }
        return .below
    }

    /// Whether a sport label is a strength-category session. The catalogue names ("Strength",
    /// "Bodybuilding", "Weightlifting") plus the common import spellings (WHOOP "Functional Fitness",
    /// "Powerlifting", Apple "Traditional Strength Training"). Case-insensitive.
    public static func isStrengthSport(_ sport: String) -> Bool {
        let s = sport.lowercased()
        let needles = ["strength", "weightlift", "weight lift", "bodybuild", "powerlift", "functional fitness",
                       "crossfit", "kettlebell", "resistance"]
        return needles.contains { s.contains($0) }
    }

    // MARK: - Union

    /// Merge overlapping or touching intervals. Output sorted by start. Degenerate (end ≤ start) intervals
    /// are dropped.
    public static func union(_ intervals: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [(start: Int, end: Int)] = []
        for iv in sorted {
            if let last = out.last, iv.start <= last.end {
                out[out.count - 1] = (last.start, max(last.end, iv.end))
            } else {
                out.append(iv)
            }
        }
        return out
    }

    // MARK: - One window from strap HR

    /// Minutes by class inside `[start, end)` from `hr` (any order; out-of-window samples ignored).
    ///
    /// Each in-window sample is credited with the gap to the next in-window sample, capped at
    /// `StrainScorer.maxSampleGapMin` and at the window end; the last sample gets the smaller of the
    /// previous gap (the `StrainScorer` convention), the cap and the time left in the window.
    ///
    /// - Parameter zone4LowerBpm: the lower edge of zone 4 of the display zones (bpm). nil (or not a
    ///   positive finite number) ⇒ the Karvonen zone-4 edge, i.e. f ≥ `hardLow`.
    public static func minutes(hr: [HRSample], start: Int, end: Int,
                               restingHR: Double, hrMax: Double,
                               zone4LowerBpm: Double? = nil) -> SessionMinutes {
        let inWin = hr.filter { $0.ts >= start && $0.ts < end }.sorted { $0.ts < $1.ts }
        let coverage = WorkoutDetector.hrCoveragePct(sampleTs: inWin.map { $0.ts }, start: start, end: end,
                                                     bucketSeconds: coverageBucketSeconds).map { $0 / 100.0 }
        guard !inWin.isEmpty, let cov = coverage, cov >= minCoverage else {
            return SessionMinutes(start: start, end: end, moderateMin: 0, vigorousMin: 0, hardMin: 0,
                                  zone45Min: 0, coverage: inWin.isEmpty ? nil : coverage, source: .unmeasured)
        }
        let cap = StrainScorer.maxSampleGapMin
        let z4Edge: Double? = zone4LowerBpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        var mod = 0.0, vig = 0.0, hard = 0.0, z45 = 0.0
        var prevGap = 1.0 / 60.0
        for i in inWin.indices {
            let s = inWin[i]
            let toEnd = Double(end - s.ts) / 60.0
            var dur: Double
            if i + 1 < inWin.count {
                let gap = Double(inWin[i + 1].ts - s.ts) / 60.0
                dur = gap > 0 ? gap : 1.0 / 60.0
                prevGap = dur
            } else {
                dur = prevGap
            }
            dur = min(dur, cap, toEnd)
            guard dur > 0, let f = hrrFraction(bpm: Double(s.bpm), restingHR: restingHR, hrMax: hrMax) else {
                continue
            }
            switch classify(f) {
            case .below: break
            case .moderate: mod += dur
            case .vigorous: vig += dur
            case .hard: vig += dur; hard += dur
            }
            if z4Edge.map({ Double(s.bpm) >= $0 }) ?? (f >= hardLow) { z45 += dur }
        }
        return SessionMinutes(start: start, end: end, moderateMin: mod, vigorousMin: vig, hardMin: hard,
                              zone45Min: z45, coverage: cov, source: .strapHR)
    }

    /// Minutes from WHOOP-imported zone percentages: z2–z3 moderate, z4–z5 vigorous. No hard minutes.
    public static func minutesFromZones(_ percents: [Double], durationMin: Double) -> (moderate: Double, vigorous: Double)? {
        guard percents.count >= 5, durationMin > 0 else { return nil }
        let p = percents.map { min(max($0, 0), 100) / 100.0 }
        let moderate = durationMin * (p[1] + p[2])
        let vigorous = durationMin * (p[3] + p[4])
        guard moderate + vigorous >= 0 else { return nil }
        return (moderate, vigorous)
    }

    /// Zone 4–5 minutes from WHOOP-imported zone percentages (z4 + z5 of the duration). WHOOP's own zones,
    /// not the app's — the caller marks the figure approximate ("≈"). nil without five zones or a duration.
    public static func zone45FromZones(_ percents: [Double], durationMin: Double) -> Double? {
        guard percents.count >= 5, durationMin > 0 else { return nil }
        let p = percents.map { min(max($0, 0), 100) / 100.0 }
        return durationMin * (p[3] + p[4])
    }

    // MARK: - One day

    /// The day's summary from its session windows, the HR that covers them, and the zone inputs.
    ///
    /// - Parameters:
    ///   - sessions: the day's workout windows (manual, imported, detected).
    ///   - hr: strap HR covering at least the union of the windows.
    ///   - restingHR: the zone resting HR (median of 7 sleep RHRs); nil when not measured — never the
    ///     60-bpm placeholder.
    ///   - hrMax: the zone HRmax (learned / Tanaka floor / override).
    ///   - liftSession: a lift-log session exists on this day (counts as strength regardless of duration,
    ///     because its sets are the evidence).
    ///   - zone4LowerBpm: the lower edge of zone 4 of the display zones; nil ⇒ the Karvonen edge (f ≥ 0.80).
    public static func day(sessions: [Window], hr: [HRSample], restingHR: Double?, hrMax: Double?,
                           liftSession: Bool = false, zone4LowerBpm: Double? = nil) -> DaySummary {
        let strength = liftSession || sessions.contains {
            isStrengthSport($0.sport) && $0.durationMin >= strengthMinMinutes
        }
        let merged = union(sessions.map { (start: $0.start, end: $0.end) })
        guard let rhr = restingHR, let mx = hrMax, mx - rhr >= minReserveBpm else {
            if merged.isEmpty {
                // No sessions: nothing to classify, so nothing to abstain from.
                return DaySummary(moderateMin: 0, vigorousMin: 0, hardMin: 0, zone45Min: 0, hardSession: false,
                                  strengthSession: strength, sessionCount: 0, unmeasuredCount: 0,
                                  approximate: false, abstained: nil)
            }
            return .abstaining(.zoneInputsMissing, sessions: merged.count, strength: strength)
        }
        var mod = 0.0, vig = 0.0, hard = 0.0, z45 = 0.0
        var anyHard = false
        var unmeasured = 0
        var approximate = false
        for iv in merged {
            let m = minutes(hr: hr, start: iv.start, end: iv.end, restingHR: rhr, hrMax: mx,
                            zone4LowerBpm: zone4LowerBpm)
            if m.source == .strapHR {
                mod += m.moderateMin; vig += m.vigorousMin; hard += m.hardMin; z45 += m.zone45Min
                if m.hardSession { anyHard = true }
                continue
            }
            // No usable strap HR for this interval: fall back to imported zones of the constituent rows.
            var zoneMod = 0.0, zoneVig = 0.0, zoneZ45 = 0.0, usedZones = false
            for w in sessions where w.start < iv.end && w.end > iv.start {
                guard let p = w.zonePercents,
                      let z = minutesFromZones(p, durationMin: w.durationMin) else { continue }
                zoneMod += z.moderate; zoneVig += z.vigorous; usedZones = true
                zoneZ45 += zone45FromZones(p, durationMin: w.durationMin) ?? 0
            }
            if usedZones {
                mod += zoneMod; vig += zoneVig; z45 += zoneZ45; approximate = true
            } else {
                unmeasured += 1
            }
        }
        return DaySummary(moderateMin: mod, vigorousMin: vig, hardMin: hard, zone45Min: z45, hardSession: anyHard,
                          strengthSession: strength, sessionCount: merged.count, unmeasuredCount: unmeasured,
                          approximate: approximate, abstained: nil)
    }

    /// The honest limit, shown in the detail view.
    public static let limitNote =
        "Only minutes inside recorded sessions count. Brisk walking outside a session is not counted, and "
        + "very fit people may walk below the moderate threshold."
}
