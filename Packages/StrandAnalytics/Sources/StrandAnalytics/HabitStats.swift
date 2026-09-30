import Foundation

// HabitStats.swift — the small numerical kernel the habit model and the habit trials share.
//
// HEALTH_V2 §S1-A.8. Deliberately small and dependency-free: a dense normal-equations OLS for ≤ 7
// regressors solved by Cholesky on an equilibrated Gram matrix (with a condition check that ABSTAINS
// rather than returning a coefficient from a near-singular design), the Frisch–Waugh–Lovell residualiser
// the permutation test is built on, a Newey–West (HAC) standard error with a Bartlett kernel on
// calendar-day distances, Student-t quantiles (Hill 1970) and tail probabilities, Benjamini–Hochberg,
// and a Jaccard overlap. Every loop runs in a fixed order, so results are bit-reproducible run to run.

public enum HabitStats {

    /// Condition-number estimate above which a design is treated as singular.
    public static let maxCondition = 1e10

    // MARK: Linear algebra

    /// A Cholesky factorisation of a symmetric positive-definite matrix, after equilibration
    /// (`S A S` with `S = diag(1/√A_ii)`), so the condition check measures collinearity rather than the
    /// columns' units.
    public struct Cholesky: Sendable {
        public let size: Int
        /// Lower-triangular factor of the equilibrated matrix, row-major.
        let lower: [Double]
        /// The equilibration scales.
        let scale: [Double]
        /// Condition-number estimate of the equilibrated matrix: (max L_ii / min L_ii)².
        public let conditionEstimate: Double

        /// Factorises `matrix` (row-major, size×size). Nil when the matrix is not positive-definite or the
        /// condition estimate exceeds `HabitStats.maxCondition`.
        public init?(_ matrix: [Double], size: Int) {
            guard size >= 1, matrix.count == size * size else { return nil }
            var s = [Double](repeating: 0, count: size)
            for i in 0..<size {
                let d = matrix[i * size + i]
                guard d.isFinite, d > 0 else { return nil }
                s[i] = 1.0 / d.squareRoot()
            }
            var l = [Double](repeating: 0, count: size * size)
            var minPivot = Double.infinity
            var maxPivot = 0.0
            for i in 0..<size {
                for j in 0...i {
                    var sum = matrix[i * size + j] * s[i] * s[j]
                    var k = 0
                    while k < j {
                        sum -= l[i * size + k] * l[j * size + k]
                        k += 1
                    }
                    if i == j {
                        guard sum.isFinite, sum > 1e-300 else { return nil }
                        let pivot = sum.squareRoot()
                        l[i * size + i] = pivot
                        minPivot = Swift.min(minPivot, pivot)
                        maxPivot = Swift.max(maxPivot, pivot)
                    } else {
                        l[i * size + j] = sum / l[j * size + j]
                    }
                }
            }
            let ratio = maxPivot / minPivot
            let cond = ratio * ratio
            guard cond.isFinite, cond <= HabitStats.maxCondition else { return nil }
            self.size = size
            self.lower = l
            self.scale = s
            self.conditionEstimate = cond
        }

        /// Solves `A x = b`.
        public func solve(_ b: [Double]) -> [Double] {
            let n = size
            // A = S⁻¹ (L Lᵀ) S⁻¹  ⇒  x = S (L Lᵀ)⁻¹ S b
            var z = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var sum = b[i] * scale[i]
                var k = 0
                while k < i {
                    sum -= lower[i * n + k] * z[k]
                    k += 1
                }
                z[i] = sum / lower[i * n + i]
            }
            var x = [Double](repeating: 0, count: n)
            var i = n - 1
            while i >= 0 {
                var sum = z[i]
                var k = i + 1
                while k < n {
                    sum -= lower[k * n + i] * x[k]
                    k += 1
                }
                x[i] = sum / lower[i * n + i]
                i -= 1
            }
            for j in 0..<n { x[j] *= scale[j] }
            return x
        }

        /// The inverse, row-major.
        public func inverse() -> [Double] {
            let n = size
            var inv = [Double](repeating: 0, count: n * n)
            for c in 0..<n {
                var e = [Double](repeating: 0, count: n)
                e[c] = 1
                let col = solve(e)
                for r in 0..<n { inv[r * n + c] = col[r] }
            }
            return inv
        }
    }

    /// The Gram matrix `Xᵀ X` of row-major design rows.
    public static func gram(_ rows: [[Double]], columns p: Int) -> [Double] {
        var g = [Double](repeating: 0, count: p * p)
        for row in rows {
            for i in 0..<p {
                let xi = row[i]
                if xi == 0 { continue }
                for j in 0...i { g[i * p + j] += xi * row[j] }
            }
        }
        for i in 0..<p {
            for j in 0..<i { g[j * p + i] = g[i * p + j] }
        }
        return g
    }

    /// An ordinary-least-squares fit.
    public struct OLSFit: Equatable, Sendable {
        public let coefficients: [Double]
        public let residuals: [Double]
        /// `(XᵀX)⁻¹`, row-major.
        public let xtxInverse: [Double]
        public let columns: Int
        public let conditionEstimate: Double
    }

    /// OLS of `y` on the design `rows` (each row includes the intercept column if one is wanted).
    /// Nil — ABSTAIN — when the design is singular or near-singular, or the shapes disagree.
    public static func ols(y: [Double], rows: [[Double]]) -> OLSFit? {
        let n = y.count
        guard n >= 1, rows.count == n, let p = rows.first?.count, p >= 1, p <= 12, n > p,
              rows.allSatisfy({ $0.count == p }) else { return nil }
        let g = gram(rows, columns: p)
        guard let chol = Cholesky(g, size: p) else { return nil }
        var xty = [Double](repeating: 0, count: p)
        for i in 0..<n {
            for j in 0..<p { xty[j] += rows[i][j] * y[i] }
        }
        let beta = chol.solve(xty)
        var resid = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var fit = 0.0
            for j in 0..<p { fit += rows[i][j] * beta[j] }
            resid[i] = y[i] - fit
        }
        return OLSFit(coefficients: beta, residuals: resid, xtxInverse: chol.inverse(), columns: p,
                      conditionEstimate: chol.conditionEstimate)
    }

    // MARK: Frisch–Waugh–Lovell

    /// The residual-maker `M = I − Z (ZᵀZ)⁻¹ Zᵀ` of a fixed covariate block, applied without forming M.
    ///
    /// By FWL, the coefficient of `d` in `y ~ Z + d` is `(M d)·(M y) / (M d)·(M d)`. The permutation test
    /// uses this to refit the SAME model under every re-drawn assignment at O(n·p) per draw.
    public struct Residualizer: Sendable {
        public let rows: Int
        public let columns: Int
        let z: [Double]          // row-major n×p
        let gramInverse: [Double]

        /// Nil when `Z` is singular or near-singular.
        public init?(covariateRows: [[Double]]) {
            guard let p = covariateRows.first?.count, p >= 1, covariateRows.count > p,
                  covariateRows.allSatisfy({ $0.count == p }) else { return nil }
            guard let chol = Cholesky(HabitStats.gram(covariateRows, columns: p), size: p) else { return nil }
            rows = covariateRows.count
            columns = p
            var flat = [Double](repeating: 0, count: covariateRows.count * p)
            for (i, r) in covariateRows.enumerated() {
                for j in 0..<p { flat[i * p + j] = r[j] }
            }
            z = flat
            gramInverse = chol.inverse()
        }

        /// `M v`.
        public func apply(_ v: [Double]) -> [Double] {
            let n = rows, p = columns
            var ztv = [Double](repeating: 0, count: p)
            for i in 0..<n {
                let vi = v[i]
                if vi == 0 { continue }
                for j in 0..<p { ztv[j] += z[i * p + j] * vi }
            }
            var coef = [Double](repeating: 0, count: p)
            for r in 0..<p {
                var s = 0.0
                for c in 0..<p { s += gramInverse[r * p + c] * ztv[c] }
                coef[r] = s
            }
            var out = v
            for i in 0..<n {
                var fit = 0.0
                for j in 0..<p { fit += z[i * p + j] * coef[j] }
                out[i] -= fit
            }
            return out
        }
    }

    // MARK: Newey–West

    /// Newey–West (HAC) standard error of coefficient `index` of `fit`, Bartlett kernel, where the lag is
    /// counted in CALENDAR days: residual pairs `h` days apart get weight `1 − h/(lag+1)` for `h ≤ lag`
    /// and 0 beyond — so a gap in the nights never makes two distant nights look adjacent.
    ///
    /// The Bartlett (triangular) kernel is a positive-definite function of the time difference, so the
    /// estimate is non-negative for any set of positions.
    public static func neweyWestSE(fit: OLSFit, rows: [[Double]], positions: [Int], index: Int,
                                   lag: Int) -> Double? {
        let n = fit.residuals.count
        let p = fit.columns
        guard rows.count == n, positions.count == n, index >= 0, index < p, lag >= 0 else { return nil }
        // u_i = e_i · (c · x_i), c = row `index` of (XᵀX)⁻¹.
        var u = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var cx = 0.0
            for j in 0..<p { cx += fit.xtxInverse[index * p + j] * rows[i][j] }
            u[i] = fit.residuals[i] * cx
        }
        var v = 0.0
        for i in 0..<n {
            v += u[i] * u[i]
            var j = i + 1
            while j < n {
                let h = abs(positions[j] - positions[i])
                if h <= lag {
                    let w = 1.0 - Double(h) / Double(lag + 1)
                    v += 2.0 * w * u[i] * u[j]
                }
                j += 1
            }
        }
        guard v.isFinite else { return nil }
        return Swift.max(0, v).squareRoot()
    }

    /// The classical OLS standard error of coefficient `index`: √(s² · (XᵀX)⁻¹_kk), s² = RSS/(n − p).
    public static func olsSE(fit: OLSFit, index: Int) -> Double? {
        let n = fit.residuals.count
        let p = fit.columns
        guard index >= 0, index < p, n > p else { return nil }
        var rss = 0.0
        for e in fit.residuals { rss += e * e }
        let v = rss / Double(n - p) * fit.xtxInverse[index * p + index]
        guard v.isFinite, v >= 0 else { return nil }
        return v.squareRoot()
    }

    // MARK: Distributions

    /// Standard normal CDF.
    public static func normalCDF(_ x: Double) -> Double {
        0.5 * erfc(-x / 2.0.squareRoot())
    }

    /// Standard normal quantile (Acklam's rational approximation, relative error < 1.2e-9), refined by
    /// one Halley step against `erfc`.
    public static func normalQuantile(_ p: Double) -> Double {
        guard p > 0, p < 1 else { return p <= 0 ? -Double.infinity : Double.infinity }
        let a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                 6.680131188771972e+01, -1.328068155288572e+01]
        let c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                 -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                 3.754408661907416e+00]
        let plow = 0.02425
        var x: Double
        if p < plow {
            let q = (-2 * log(p)).squareRoot()
            x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        } else if p <= 1 - plow {
            let q = p - 0.5
            let r = q * q
            x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
        } else {
            let q = (-2 * log(1 - p)).squareRoot()
            x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        // One Halley refinement.
        let e = normalCDF(x) - p
        let u = e * (2 * Double.pi).squareRoot() * exp(x * x / 2)
        x -= u / (1 + x * u / 2)
        return x
    }

    /// Regularised incomplete beta `I_x(a, b)` (continued fraction, modified Lentz).
    public static func incompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let lnFront = lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x)
        let front = exp(lnFront)
        if x < (a + 1) / (a + b + 2) {
            return front * betaContinuedFraction(x, a: a, b: b) / a
        }
        return 1 - front * betaContinuedFraction(1 - x, a: b, b: a) / b
    }

    private static func betaContinuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        var m = 1
        while m <= 300 {
            let mm = Double(m)
            let m2 = 2 * mm
            var aa = mm * (b - mm) * x / ((qam + m2) * (a + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            aa = -(a + mm) * (qab + mm) * x / ((a + m2) * (qap + m2))
            d = 1 + aa * d
            if abs(d) < tiny { d = tiny }
            c = 1 + aa / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let del = d * c
            h *= del
            if abs(del - 1) < 1e-15 { break }
            m += 1
        }
        return h
    }

    /// Student-t CDF, `P(T ≤ t)` with `df` degrees of freedom.
    public static func studentTCDF(_ t: Double, df: Double) -> Double {
        guard df > 0, t.isFinite else { return t > 0 ? 1 : 0 }
        let x = df / (df + t * t)
        let tail = 0.5 * incompleteBeta(x, a: df / 2, b: 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    /// Two-sided p-value of a t statistic.
    public static func studentTTwoSidedP(_ t: Double, df: Double) -> Double {
        guard df > 0, t.isFinite else { return t.isNaN ? 1 : 0 }
        let x = df / (df + t * t)
        return Swift.min(1, incompleteBeta(x, a: df / 2, b: 0.5))
    }

    /// Student-t quantile: the `t` with `P(T ≤ t) = prob`.
    ///
    /// G. W. Hill (1970), "Algorithm 396: Student's t-quantiles", Comm. ACM 13(10) — the same
    /// approximation R's `qt` starts from — followed by one Newton step on the exact CDF above.
    public static func studentTQuantile(_ prob: Double, df: Int) -> Double {
        guard df >= 1, prob > 0, prob < 1 else {
            return prob <= 0 ? -Double.infinity : (prob >= 1 ? Double.infinity : .nan)
        }
        if prob == 0.5 { return 0 }
        let n = Double(df)
        let pTwo = 2 * Swift.min(prob, 1 - prob)   // two-tailed probability
        var q: Double
        if df == 1 {
            let pp = pTwo * Double.pi / 2
            q = cos(pp) / sin(pp)
        } else if df == 2 {
            q = (2 / (pTwo * (2 - pTwo)) - 2).squareRoot()
        } else {
            let a: Double = 1 / (n - 0.5)
            let b: Double = 48 / (a * a)
            var c: Double = ((20_700 * a / b - 98) * a - 16) * a + 96.36
            let d: Double = ((94.5 / (b + c) - 3) / b + 1) * (a * Double.pi / 2).squareRoot() * n
            var y: Double = pow(d * pTwo, 2 / n)
            if y > 0.05 + a {
                let x = normalQuantile(0.5 * pTwo)
                y = x * x
                if n < 5 { c += 0.3 * (n - 4.5) * (x + 0.6) }
                c = (((0.05 * d * x - 5) * x - 7) * x - 2) * x + b + c
                y = (((((0.4 * y + 6.3) * y + 36) * y + 94.5) / c - y - 3) / b + 1) * x
                y = expm1(a * y * y)
            } else {
                let inner: Double = (n + 6) / (n * y) - 0.089 * d - 0.822
                let bracket: Double = 1 / (inner * (n + 2) * 3) + 0.5 / (n + 4)
                let scaled: Double = (bracket * y - 1) * (n + 1) / (n + 2)
                y = scaled + 1 / y
            }
            q = (n * y).squareRoot()
        }
        // One Newton step on P(T ≤ q) = 1 − pTwo/2 (upper quantile), using the t density.
        let target = 1 - pTwo / 2
        let logNorm: Double = lgamma((n + 1) / 2) - lgamma(n / 2)
        let norm: Double = exp(logNorm) / (n * Double.pi).squareRoot()
        let kernel: Double = pow(1 + q * q / n, -(n + 1) / 2)
        let density: Double = norm * kernel
        if density > 0, density.isFinite {
            let step = (studentTCDF(q, df: n) - target) / density
            if step.isFinite, abs(step) < 0.5 * Swift.max(1, q) { q -= step }
        }
        return prob > 0.5 ? q : -q
    }

    // MARK: Multiplicity

    /// Benjamini–Hochberg step-up at level `q`. Returns, for each p-value, whether it is rejected.
    public static func benjaminiHochberg(_ pValues: [Double], q: Double) -> [Bool] {
        let m = pValues.count
        guard m > 0 else { return [] }
        let order = pValues.indices.sorted { a, b in
            pValues[a] != pValues[b] ? pValues[a] < pValues[b] : a < b
        }
        var cutoff = -1
        for (rank, idx) in order.enumerated() {
            let threshold = Double(rank + 1) / Double(m) * q
            if pValues[idx] <= threshold { cutoff = rank }
        }
        var out = [Bool](repeating: false, count: m)
        if cutoff >= 0 {
            for rank in 0...cutoff { out[order[rank]] = true }
        }
        return out
    }

    // MARK: Descriptives

    /// Jaccard overlap `|A ∩ B| / |A ∪ B|`. Nil when both are empty.
    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double? {
        let union = a.union(b).count
        guard union > 0 else { return nil }
        return Double(a.intersection(b).count) / Double(union)
    }

    public static func mean(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        var s = 0.0
        for x in v { s += x }
        return s / Double(v.count)
    }

    /// Sample standard deviation (n − 1). Nil below two values.
    public static func sampleSD(_ v: [Double]) -> Double? {
        guard v.count >= 2, let m = mean(v) else { return nil }
        var s = 0.0
        for x in v { s += (x - m) * (x - m) }
        return (s / Double(v.count - 1)).squareRoot()
    }

    /// The median. Nil when empty.
    public static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Lag-1 autocorrelation over pairs exactly one position apart (gaps break pairs). Nil with fewer than
    /// 3 pairs or no variance.
    public static func lag1Autocorrelation(values: [Double], positions: [Int]) -> Double? {
        guard values.count == positions.count, let m = mean(values) else { return nil }
        var byPos: [Int: Double] = [:]
        for (i, pos) in positions.enumerated() { byPos[pos] = values[i] }
        var num = 0.0
        var pairs = 0
        for pos in positions.sorted() {
            guard let a = byPos[pos], let b = byPos[pos + 1] else { continue }
            num += (a - m) * (b - m)
            pairs += 1
        }
        var den = 0.0
        for x in values { den += (x - m) * (x - m) }
        guard pairs >= 3, den > 0 else { return nil }
        // Scale the pair sum to the full-series normalisation, so gaps do not bias ρ toward 0.
        return (num / Double(pairs)) / (den / Double(values.count))
    }
}
