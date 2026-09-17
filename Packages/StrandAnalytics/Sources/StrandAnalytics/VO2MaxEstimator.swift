import Foundation

// VO2MaxEstimator.swift — VO₂max from the wearer's own runs and walks.
//
// WHOOP estimates VO₂max from training. The idea behind every such estimate is the same, and it is
// old, public physiology: at a steady submaximal effort, the oxygen a movement COSTS is known from its
// speed (the ACSM metabolic equations), and the fraction of the wearer's capacity it USED is read off
// their heart rate (the heart-rate reserve tracks the VO₂ reserve almost one-to-one — Swain & Leutholtz
// 1997). Divide one by the other and the result is the capacity itself:
//
//   VO₂(effort)  = 3.5 + 0.2 × speed           running, speed in m/min      (ACSM)
//                = 3.5 + 0.1 × speed           walking
//   %HRR         = (avg HR − resting HR) / (HRmax − resting HR)
//   VO₂max       = 3.5 + (VO₂(effort) − 3.5) / %HRR
//
// So this uses exactly what the app already has for a session with a distance: its duration, its
// distance and its average heart rate, plus the wearer's resting HR and HRmax.
//
// WHAT IT IGNORES, stated plainly: gradient (the equations are for level ground — a hilly run reads
// low), wind, heat, and cardiac drift over a long session. That is why a single session is never the
// answer: it takes the MEDIAN of the most recent valid sessions, and an effort outside the band where
// the method holds (too easy, near-maximal, implausible speeds, too short) is not used at all.
//
// WITH NO USABLE SESSION it falls back to Uth et al. 2004 — 15.3 × HRmax / resting HR — which needs no
// training at all and is rougher, and says so in its method.

public enum VO2MaxEstimator {

    /// One session the estimator can read.
    public struct Session: Equatable, Sendable {
        public let start: Date
        public let durationS: Double
        public let distanceM: Double
        public let avgHr: Double
        public init(start: Date, durationS: Double, distanceM: Double, avgHr: Double) {
            self.start = start
            self.durationS = durationS
            self.distanceM = distanceM
            self.avgHr = avgHr
        }
    }

    public enum Method: String, Sendable {
        /// From runs / walks: speed against heart-rate reserve.
        case submaximal
        /// Uth 2004: HRmax / resting HR.
        case hrRatio
    }

    public struct Estimate: Equatable, Sendable {
        public let vo2max: Double
        public let method: Method
        /// How many sessions the submaximal median was taken over (0 for the HR-ratio fallback).
        public let sessions: Int
    }

    /// The effort band where HR reserve tracks VO₂ reserve well enough to extrapolate from.
    public static let hrrBand: ClosedRange<Double> = 0.50...0.90
    /// Sessions at least this long; shorter ones have not reached a steady heart rate.
    public static let minDurationS: Double = 10 * 60
    public static let maxDurationS: Double = 150 * 60
    /// Speed bands, m/min. Between the two is jogging-or-brisk-walking, where neither equation holds.
    public static let walkBand: ClosedRange<Double> = 50...100
    public static let runBand: ClosedRange<Double> = 134...400
    /// How far back sessions are read, and how many of the newest are pooled.
    public static let lookbackDays = 90
    public static let pooled = 5
    public static let minSessions = 2

    /// VO₂max from one session, or nil when the session is outside where the method holds.
    public static func fromSession(_ s: Session, restingHr: Double, hrMax: Double) -> Double? {
        guard s.durationS >= minDurationS, s.durationS <= maxDurationS, s.distanceM > 0,
              hrMax > restingHr + 20 else { return nil }
        let speed = s.distanceM / (s.durationS / 60)
        let cost: Double
        if runBand.contains(speed) {
            cost = 3.5 + 0.2 * speed
        } else if walkBand.contains(speed) {
            cost = 3.5 + 0.1 * speed
        } else {
            return nil
        }
        let hrr = (s.avgHr - restingHr) / (hrMax - restingHr)
        guard hrrBand.contains(hrr) else { return nil }
        let vo2max = 3.5 + (cost - 3.5) / hrr
        // A human range; anything outside it is a mis-logged distance or a broken HR trace.
        return (15...90).contains(vo2max) ? vo2max : nil
    }

    /// Uth 2004.
    public static func hrRatio(restingHr: Double, hrMax: Double) -> Double? {
        guard restingHr > 25, hrMax > restingHr else { return nil }
        return 15.3 * hrMax / restingHr
    }

    /// The estimate as of `now`: the median of the newest valid sessions, or the HR-ratio fallback.
    public static func estimate(sessions: [Session], restingHr: Double?, hrMax: Double?,
                                now: Date = Date()) -> Estimate? {
        guard let rhr = restingHr, let hrMax else { return nil }
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        let valid = sessions
            .filter { $0.start >= cutoff && $0.start <= now }
            .sorted { $0.start > $1.start }
            .compactMap { fromSession($0, restingHr: rhr, hrMax: hrMax) }
            .prefix(pooled)
        if valid.count >= minSessions {
            let sorted = valid.sorted()
            let mid = sorted.count / 2
            let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
            return Estimate(vo2max: median, method: .submaximal, sessions: sorted.count)
        }
        return hrRatio(restingHr: rhr, hrMax: hrMax).map { Estimate(vo2max: $0, method: .hrRatio, sessions: 0) }
    }
}
