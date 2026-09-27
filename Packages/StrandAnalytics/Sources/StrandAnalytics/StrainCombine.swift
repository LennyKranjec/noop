import Foundation

// StrainCombine.swift — adding two Efforts on the log axis.
//
// Effort is NOT additive: it is 100 × ln(TRIMP + 1) / ln(D), so a day at 40 plus a workout at 40 is not
// 80. Where two Efforts genuinely have to be summed, both are taken back to TRIMP, added there — where
// load IS additive — and mapped forward again through the same denominator.
//
// An approximation, stated plainly: Banister's day score also nets off a sedentary baseline over the
// day's minutes, which a two-number combine cannot see. It is an estimate for a progress bar, not a
// stored score; the daily pass remains the number of record.
//
// NOT FOR "THE DAY PLUS THE LIVE SESSION". The live-workout screen used to build its day read-out that
// way — the day's resolved Effort plus the in-progress session's running Effort — and it drifted from the
// figure Today, the Key Metrics tile, the Effort detail and the widget show (they all read
// `Repository.todayEffortNow`), because the two are readings of the SAME beats: the session's heart rate
// reaches the day's own score through the strap's history, so the sum counts the overlap twice. No
// production caller sums a day and a session any more; the session's Effort is shown as its own figure.

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
