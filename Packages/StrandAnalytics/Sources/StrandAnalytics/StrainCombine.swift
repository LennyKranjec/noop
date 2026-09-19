import Foundation

// StrainCombine.swift — adding two Efforts on the log axis.
//
// Effort is NOT additive: it is 100 × ln(TRIMP + 1) / ln(D), so a day at 40 plus a workout at 40 is not
// 80. The live-workout "day so far" read-out needs exactly that sum (the day's Effort before the session
// + the session's running Effort), so both are taken back to TRIMP, added there — where load IS
// additive — and mapped forward again through the same denominator.
//
// An approximation, stated plainly: Banister's day score also nets off a sedentary baseline over the
// day's minutes, which a two-number combine cannot see. It is a live estimate for a progress bar, not a
// stored score; the daily pass remains the number of record.

public extension StrainScorer {

    /// The inverse of `trimpToStrain`: the TRIMP that maps onto `strain` (0–100) under `denominator`.
    /// 0 for a non-positive / non-finite strain or an out-of-domain denominator.
    static func strainToTRIMP(_ strain: Double, denominator: Double = strainDenominator) -> Double {
        guard strain.isFinite, strain > 0, denominator > 1 else { return 0 }
        return exp(strain / maxStrain * log(denominator)) - 1.0
    }

    /// Two Efforts (0–100) combined as their summed TRIMP, back on the 0–100 axis (capped at `maxStrain`).
    static func combinedStrain(_ a: Double, _ b: Double, denominator: Double = strainDenominator) -> Double {
        let trimp = strainToTRIMP(a, denominator: denominator) + strainToTRIMP(b, denominator: denominator)
        return Swift.min(trimpToStrain(trimp, denominator: denominator), maxStrain)
    }
}
