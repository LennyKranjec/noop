import Foundation

// EffortStrainCalibration.swift — a per-wearer map from NOOP's 0–100 Effort onto WHOOP's 0–21 Day Strain.
//
// WHY THIS EXISTS (O8). The app shows Effort on WHOOP's axis as `effort / 100 × 21` and compares it with
// WHOOP's optimal-strain band. That straight line assumes NOOP's log curve and WHOOP's share a shape, and
// nothing calibrated them: NOOP's `100 × ln(TRIMP+1) / ln(7201)` and WHOOP's proprietary curve can sit
// several points apart for the same day, so "12.4 of 21" and the "optimum reached" alert were guesses.
//
// THE FIT. Given days that carry BOTH the app's own Effort (0–100, computed lane) and WHOOP's own day
// strain (0–21, cloud source), fit the monotone 2-parameter power law
//
//     strain21 = a × effort100^b          (a > 0, b > 0 ⇒ strictly increasing, 0 ↦ 0)
//
// by least squares in log–log space (ln s = ln a + b ln e), which makes the error RELATIVE — a 1-point
// miss on a 4-strain rest day weighs as much as a 3-point miss on a 12-strain day. ROBUST: after each fit,
// pairs whose log residual exceeds `outlierK` robust standard deviations (1.4826 × MAD) are dropped and the
// fit is repeated, up to `maxRefits` times, so a day whose strap was off for the workout (or a WHOOP day
// scored from a different window) cannot drag the curve. Fewer than `minPairs` usable pairs — before or
// after trimming — is no calibration at all, and the caller keeps the linear ×21/100.
//
// Pure and platform-free on purpose, so the math is covered by `swift test` without the app.

public struct EffortStrainCalibration: Codable, Equatable, Sendable {

    /// Scale term of `strain21 = a × effort100^b`.
    public let a: Double
    /// Exponent of `strain21 = a × effort100^b`. Always > 0, so the map is strictly increasing.
    public let b: Double
    /// How many paired days survived outlier trimming and went into the final fit.
    public let pairs: Int

    /// The fewest paired days that are allowed to replace the linear mapping.
    public static let minPairs = 10
    /// WHOOP's Day Strain ceiling. Calibrated output is clamped to [0, whoopMax].
    public static let whoopMax = 21.0
    /// NOOP's Effort ceiling (`StrainScorer.maxStrain`). The inverse is clamped to [0, effortMax].
    public static let effortMax = StrainScorer.maxStrain
    /// The uncalibrated factor the app has always used, 21/100 — the fallback when no calibration exists.
    public static let linearFactor = 21.0 / 100.0

    /// Pairs below these are dropped before fitting: ln() needs positive values, and a sub-1 Effort or a
    /// sub-0.1 strain is a no-data day rather than a measurement of a calm one.
    static let minEffort = 1.0
    static let minStrain = 0.1
    /// Robust-SD multiple beyond which a log residual is an outlier.
    static let outlierK = 3.0
    /// Floor on the robust SD so a near-perfect fit does not trim good points over rounding noise.
    static let minRobustSD = 0.03
    static let maxRefits = 3
    /// Plausibility band for the exponent. Outside it the two curves are not the same kind of thing, and a
    /// fit that lands there is refused rather than shown.
    static let exponentRange: ClosedRange<Double> = 0.2...3.0

    public init(a: Double, b: Double, pairs: Int) {
        self.a = a
        self.b = b
        self.pairs = pairs
    }

    /// NOOP Effort (0–100) → WHOOP-calibrated Day Strain (0–21). Non-finite or ≤ 0 input maps to 0.
    public func strain21(effort100: Double) -> Double {
        guard effort100.isFinite, effort100 > 0 else { return 0 }
        let s = a * pow(effort100, b)
        guard s.isFinite else { return Self.whoopMax }
        return min(max(s, 0), Self.whoopMax)
    }

    /// The exact inverse: the Effort (0–100) whose calibrated strain equals `strain21`. Used to place a
    /// WHOOP-scale target (the optimal-strain ceiling) on the app's own 0–100 axis.
    public func effort100(strain21: Double) -> Double {
        guard strain21.isFinite, strain21 > 0 else { return 0 }
        let e = pow(strain21 / a, 1.0 / b)
        guard e.isFinite else { return Self.effortMax }
        return min(max(e, 0), Self.effortMax)
    }

    /// Fit the calibration from paired days, or nil when there is not enough (or not sane enough) data —
    /// the caller then keeps the linear ×21/100 mapping.
    public static func fit(_ pairs: [(effort100: Double, strain21: Double)]) -> EffortStrainCalibration? {
        var pts: [(x: Double, y: Double)] = pairs.compactMap { p -> (x: Double, y: Double)? in
            guard p.effort100.isFinite, p.strain21.isFinite,
                  p.effort100 >= minEffort, p.effort100 <= effortMax,
                  p.strain21 >= minStrain, p.strain21 <= whoopMax else { return nil }
            return (x: log(p.effort100), y: log(p.strain21))
        }
        guard pts.count >= minPairs, var line = ols(pts) else { return nil }

        for _ in 0..<maxRefits {
            let residuals = pts.map { $0.y - (line.intercept + line.slope * $0.x) }
            let center = median(residuals)
            let robustSD = max(1.4826 * median(residuals.map { abs($0 - center) }), minRobustSD)
            let kept: [(x: Double, y: Double)] = zip(pts, residuals)
                .filter { abs($0.1 - center) <= outlierK * robustSD }
                .map { $0.0 }
            if kept.count == pts.count { break }                 // nothing trimmed — converged
            guard kept.count >= minPairs, let refit = ols(kept) else { return nil }
            pts = kept
            line = refit
        }

        let a = exp(line.intercept)
        let b = line.slope
        guard a.isFinite, a > 0, b.isFinite, exponentRange.contains(b) else { return nil }
        return EffortStrainCalibration(a: a, b: b, pairs: pts.count)
    }

    // MARK: - Helpers

    /// Ordinary least squares y = intercept + slope·x; nil when x has (near) no spread.
    static func ols(_ pts: [(x: Double, y: Double)]) -> (intercept: Double, slope: Double)? {
        let n = Double(pts.count)
        guard n >= 2 else { return nil }
        let mx = pts.reduce(0) { $0 + $1.x } / n
        let my = pts.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, sxy = 0.0
        for p in pts {
            sxx += (p.x - mx) * (p.x - mx)
            sxy += (p.x - mx) * (p.y - my)
        }
        // Every day at (almost) the same Effort says nothing about the curve's shape.
        guard sxx / n > 1e-4 else { return nil }
        let slope = sxy / sxx
        return (my - slope * mx, slope)
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
