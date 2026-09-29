import XCTest
@testable import StrandAnalytics

/// HEALTH_V2 §S1-A.8 — the shared numerical kernel.
final class HabitStatsTests: XCTestCase {

    func testOLSAgainstAHandSolvedSystem() {
        // y = 1 + 2x exactly.
        let rows: [[Double]] = [[1, 0], [1, 1], [1, 2], [1, 3]]
        let fit = HabitStats.ols(y: [1, 3, 5, 7], rows: rows)!
        XCTAssertEqual(fit.coefficients[0], 1, accuracy: 1e-12)
        XCTAssertEqual(fit.coefficients[1], 2, accuracy: 1e-12)
        for e in fit.residuals { XCTAssertEqual(e, 0, accuracy: 1e-12) }

        // Three regressors: y = 2 − x1 + 0.5 x2 (hand-checked), with columns on very different scales.
        let rows3: [[Double]] = [[1, 0, 0], [1, 1, 100], [1, 2, 50], [1, 3, 200], [1, 4, 10]]
        let y3 = rows3.map { 2 - $0[1] + 0.5 * $0[2] }
        let fit3 = HabitStats.ols(y: y3, rows: rows3)!
        XCTAssertEqual(fit3.coefficients[0], 2, accuracy: 1e-9)
        XCTAssertEqual(fit3.coefficients[1], -1, accuracy: 1e-9)
        XCTAssertEqual(fit3.coefficients[2], 0.5, accuracy: 1e-9)
        // (XᵀX)⁻¹ really is the inverse.
        let g = HabitStats.gram(rows3, columns: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += g[i * 3 + k] * fit3.xtxInverse[k * 3 + j] }
                XCTAssertEqual(s, i == j ? 1 : 0, accuracy: 1e-8)
            }
        }
    }

    func testSingularDesignAbstains() {
        // Second column is twice the first.
        XCTAssertNil(HabitStats.ols(y: [1, 2, 3, 4], rows: [[1, 2], [1, 2], [1, 2], [1, 2]]))
        XCTAssertNil(HabitStats.ols(y: [1, 2, 3, 4], rows: [[1, 1, 2], [1, 2, 4], [1, 3, 6], [1, 4, 8]]))
        // Near-singular (condition far above 1e10) also abstains.
        let eps = 1e-9
        XCTAssertNil(HabitStats.ols(y: [1, 2, 3, 4], rows: [[1, 1], [1, 1 + eps], [1, 1], [1, 1 - eps]]))
        // An all-zero column.
        XCTAssertNil(HabitStats.ols(y: [1, 2, 3], rows: [[1, 0], [1, 0], [1, 0]]))
        XCTAssertNil(HabitStats.Residualizer(covariateRows: [[1, 5], [1, 5], [1, 5]]))
    }

    func testResidualizerMatchesFrischWaughLovell() {
        // Coefficient of d in y ~ [1, x, d] equals (Md·My)/(Md·Md).
        let x: [Double] = [0.5, 1.5, 2.0, 3.5, 4.0, 5.5, 6.0, 7.5]
        let d: [Double] = [1, 0, 1, 1, 0, 0, 1, 0]
        let y: [Double] = [2.1, 1.0, 3.3, 3.9, 2.2, 2.9, 5.1, 3.4]
        let full = HabitStats.ols(y: y, rows: (0..<8).map { [1, x[$0], d[$0]] })!
        let M = HabitStats.Residualizer(covariateRows: (0..<8).map { [1, x[$0]] })!
        let md = M.apply(d), my = M.apply(y)
        var num = 0.0, den = 0.0
        for i in 0..<8 {
            num += md[i] * my[i]
            den += md[i] * md[i]
        }
        XCTAssertEqual(num / den, full.coefficients[2], accuracy: 1e-10)
    }

    func testNeweyWestAgainstHandComputedExample() {
        // 12 points with calendar gaps (positions 0-3, 5-8, 10-13), lag 2. Reference values computed
        // independently (NumPy, explicit double sum).
        let x = (0..<12).map { Double($0) }
        let y: [Double] = [2.0, 2.9, 4.2, 4.8, 6.3, 6.9, 8.4, 8.8, 10.1, 11.2, 11.8, 13.3]
        let positions = [0, 1, 2, 3, 5, 6, 7, 8, 10, 11, 12, 13]
        let rows = x.map { [1, $0] }
        let fit = HabitStats.ols(y: y, rows: rows)!
        XCTAssertEqual(fit.coefficients[0], 2.0025641025641017, accuracy: 1e-10)
        XCTAssertEqual(fit.coefficients[1], 1.0101398601398603, accuracy: 1e-10)
        XCTAssertEqual(HabitStats.neweyWestSE(fit: fit, rows: rows, positions: positions, index: 0, lag: 2)!,
                       0.04310095548913239, accuracy: 1e-10)
        XCTAssertEqual(HabitStats.neweyWestSE(fit: fit, rows: rows, positions: positions, index: 1, lag: 2)!,
                       0.007140859772333652, accuracy: 1e-10)
        XCTAssertEqual(HabitStats.olsSE(fit: fit, index: 1)!, 0.018967470671679643, accuracy: 1e-10)
        // Lag 0 is White's heteroskedasticity-robust variance: never negative.
        XCTAssertGreaterThanOrEqual(HabitStats.neweyWestSE(fit: fit, rows: rows, positions: positions, index: 1,
                                                           lag: 0)!, 0)
    }

    func testStudentTQuantilesAgainstTable() {
        // Two-sided 95 % critical values.
        let table: [(Int, Double)] = [(3, 3.182446), (5, 2.570582), (10, 2.228139), (30, 2.042272), (120, 1.979930)]
        for (df, value) in table {
            XCTAssertEqual(HabitStats.studentTQuantile(0.975, df: df), value, accuracy: 1e-4, "df \(df)")
            XCTAssertEqual(HabitStats.studentTQuantile(0.025, df: df), -value, accuracy: 1e-4, "df \(df)")
        }
        XCTAssertEqual(HabitStats.studentTQuantile(0.975, df: 1), 12.706205, accuracy: 1e-4)
        XCTAssertEqual(HabitStats.studentTQuantile(0.975, df: 2), 4.302653, accuracy: 1e-4)
        XCTAssertEqual(HabitStats.studentTQuantile(0.5, df: 7), 0)
    }

    func testStudentTTailsAndNormal() {
        XCTAssertEqual(HabitStats.studentTTwoSidedP(2.228139, df: 10), 0.05, accuracy: 1e-5)
        XCTAssertEqual(HabitStats.studentTCDF(0, df: 4), 0.5, accuracy: 1e-12)
        XCTAssertEqual(HabitStats.normalCDF(1.959963985), 0.975, accuracy: 1e-9)
        XCTAssertEqual(HabitStats.normalQuantile(0.975), 1.959963985, accuracy: 1e-8)
        XCTAssertEqual(HabitStats.normalQuantile(1e-6), -4.753424309, accuracy: 1e-7)
    }

    func testBenjaminiHochbergTextbookExample() {
        // Benjamini & Hochberg (1995), the 15 p-values of their worked example: at q = 0.05 the first four
        // are rejected.
        let p = [0.0001, 0.0004, 0.0019, 0.0095, 0.0201, 0.0278, 0.0298, 0.0344, 0.0459, 0.3240, 0.4262,
                 0.5719, 0.6528, 0.7590, 1.000]
        let r = HabitStats.benjaminiHochberg(p, q: 0.05)
        XCTAssertEqual(r, [true, true, true, true] + [Bool](repeating: false, count: 11))
        // Step-UP: a later p under its threshold rescues earlier ones above theirs.
        XCTAssertEqual(HabitStats.benjaminiHochberg([0.04, 0.03], q: 0.05), [true, true])
        XCTAssertEqual(HabitStats.benjaminiHochberg([], q: 0.1), [])
        // Order of input does not matter.
        XCTAssertEqual(HabitStats.benjaminiHochberg(Array(p.reversed()), q: 0.05), Array(r.reversed()))
    }

    func testJaccardAndDescriptives() {
        XCTAssertEqual(HabitStats.jaccard(["a", "b", "c"], ["b", "c", "d"]), 0.5)
        XCTAssertNil(HabitStats.jaccard([], []))
        XCTAssertEqual(HabitStats.median([3, 1, 2, 10]), 2.5)
        XCTAssertNil(HabitStats.sampleSD([1]))
        // Gaps break autocorrelation pairs.
        XCTAssertNil(HabitStats.lag1Autocorrelation(values: [1, 2, 3, 4], positions: [0, 2, 4, 6]))
        let rho = HabitStats.lag1Autocorrelation(values: [1, 2, 3, 4, 5, 6], positions: [0, 1, 2, 3, 4, 5])!
        XCTAssertGreaterThan(rho, 0.4)
    }
}
