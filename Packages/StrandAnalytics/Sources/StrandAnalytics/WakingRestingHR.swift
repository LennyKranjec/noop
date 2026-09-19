import Foundation
import WhoopProtocol

// WakingRestingHR.swift — the WAKING (seated, daytime) resting heart rate, for the formulas that were
// built on one (O7).
//
// THE PROBLEM: NOOP's resting HR (`DailyMetric.restingHr`) is a SLEEP figure (the mean of the night's
// last deep run). That is the right input for Charge — it is what WHOOP means by resting HR — but every
// published formula below was fitted on a WAKING resting HR measured sitting or lying quietly:
//   - Uth et al. 2004, VO₂max ≈ 15.3 · HRmax / HRrest
//   - the Karvonen heart-rate reserve (the run-based VO₂max, the Banister TRIMP, the Keytel active gate)
//   - Keytel 2005 fitness-adjusted energy (it reads the Uth VO₂max)
//   - Nes 2011 HUNT VO₂max and the Fitness Age built on it (its 65 bpm reference is a seated RHR)
// A sleeping RHR runs ~5–10 bpm below a waking one, so feeding it in inflated VO₂max by ~15% and made
// Fitness Age ~4 years younger.
//
// THE ESTIMATE: the 10th percentile of the day's WAKING per-minute mean HR — minutes inside a detected
// sleep session, or outside the 06:00–22:00 local waking window, are excluded. Motion is deliberately
// NOT masked: movement only ever RAISES heart rate, so it cannot pull a low percentile down; the lowest
// decile of an awake day is already its still, seated floor. A day with too little waking wear
// (`minWakingMinutes`), or whose floor sits implausibly far above the night (a day worn only for a
// workout), yields nil.
//
// THE FALLBACK: with no daytime estimate, sleep RHR + `sleepToWakingOffsetBpm` (6 bpm, the low end of
// the published 5–10 bpm sleep-vs-waking gap, so the correction is conservative).
//
// SCOPE: Charge / recovery and the level stay on the SLEEP resting HR. Only the waking-rest formulas
// above read this. Pure; no clock, no I/O.
public enum WakingRestingHR {

    /// Metric-series key the per-day daytime estimate is stored under (computed "-noop" source). Only a
    /// MEASURED daytime estimate is stored; readers resolve the sleep fallback per day themselves.
    public static let metricKey = "rhr_waking"
    /// Sleep → waking resting HR offset (bpm) used when no daytime estimate exists. Calibrated to the
    /// low end of the ~5–10 bpm gap between a sleeping and a seated waking resting HR.
    public static let sleepToWakingOffsetBpm: Double = 6.0
    /// Percentile of the waking per-minute mean HRs taken as the day's resting floor.
    public static let percentile: Double = 0.10
    /// Minimum waking minutes with HR before a day's own estimate is trusted.
    public static let minWakingMinutes: Int = 120
    /// A daytime floor more than this far above the sleep RHR is not a resting floor (a day worn only
    /// for a workout, say), so the day's estimate is dropped in favour of the fallback.
    public static let maxAboveSleepBpm: Double = 25.0
    /// Physiological bounds for a waking resting HR.
    public static let plausibleRange: ClosedRange<Double> = 35.0...110.0

    /// The day's own waking resting HR from its HR stream, or nil when it can't be measured.
    ///
    /// - Parameters:
    ///   - hr: the day's HR samples (wall-clock `ts`).
    ///   - sleepWindows: `[start, end)` wall-clock spans of detected sleep (naps included) to exclude.
    ///   - tzOffsetSeconds: seconds east of UTC, placing each minute on the local 06:00–22:00 window.
    ///   - sleepRestingHR: the night's (sleep) resting HR, if any. The result is never below it (a waking
    ///     rest cannot sit under the sleeping one), and a floor more than `maxAboveSleepBpm` above it is
    ///     rejected.
    public static func daytimeEstimate(hr: [HRSample],
                                       sleepWindows: [(start: Int, end: Int)],
                                       tzOffsetSeconds: Int = 0,
                                       sleepRestingHR: Double? = nil) -> Double? {
        guard !hr.isEmpty else { return nil }
        var sums: [Int: (sum: Double, n: Int)] = [:]
        for s in hr {
            guard s.bpm >= 30, s.bpm <= 220 else { continue }
            if sleepWindows.contains(where: { s.ts >= $0.start && s.ts < $0.end }) { continue }
            let localHourBucket = DaytimeStress.floorDiv(s.ts + tzOffsetSeconds, DaytimeStress.bucketSeconds)
                * DaytimeStress.bucketSeconds
            guard DaytimeStress.isWakingHour(localHourBucket) else { continue }
            let minute = DaytimeStress.floorDiv(s.ts, 60)
            let cur = sums[minute] ?? (0, 0)
            sums[minute] = (cur.sum + Double(s.bpm), cur.n + 1)
        }
        guard sums.count >= minWakingMinutes else { return nil }
        let minuteMeans = sums.values.map { $0.sum / Double($0.n) }.sorted()
        let floor = DaytimeStress.quantile(minuteMeans, percentile)
        guard plausibleRange.contains(floor) else { return nil }
        if let sleep = sleepRestingHR, sleep > 0 {
            if floor > sleep + maxAboveSleepBpm { return nil }
            return max(floor, sleep)
        }
        return floor
    }

    /// Sleep resting HR + the documented offset, or nil without a usable sleep RHR.
    public static func fromSleep(_ sleepRestingHR: Double?) -> Double? {
        guard let s = sleepRestingHR, s > 0 else { return nil }
        return s + sleepToWakingOffsetBpm
    }

    /// The waking resting HR to use for one day: its measured daytime estimate, else the sleep fallback.
    public static func resolve(daytime: Double?, sleepRestingHR: Double?) -> Double? {
        if let d = daytime, plausibleRange.contains(d) { return d }
        return fromSleep(sleepRestingHR)
    }

    /// The MEDIAN of the per-day resolved waking resting HRs, or nil when no day resolves. The rolling
    /// figure VO₂max and Fitness Age read (both previously took the median of the sleep RHRs).
    public static func typical(_ days: [(daytime: Double?, sleep: Double?)]) -> Double? {
        let v = days.compactMap { resolve(daytime: $0.daytime, sleepRestingHR: $0.sleep) }.sorted()
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }
}
