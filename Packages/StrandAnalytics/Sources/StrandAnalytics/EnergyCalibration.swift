import Foundation

// EnergyCalibration.swift — does the energy bank match how the wearer says they feel?
//
// The bank is a model of a feeling. The only honest test of a model of a feeling is the feeling, so the
// wearer is asked — one tap, 1 to 5, in the morning and once in the afternoon — and every answer is
// stored with the exact inputs the model saw at that moment (`EnergyCheckIn`). From those:
//
//   1. AGREEMENT. Spearman's rank correlation between the model's balance at each check-in and the
//      reported energy, with a 95 % interval (Fisher z, SE = √(1.06 / (n − 3)), the Fieller–Hartley–
//      Pearson variance for a rank correlation). RANKS, because a 1–5 tap and a 0–100 balance share no
//      units: the question is only whether higher model days are higher-feeling days.
//
//   2. A SMALL, WELL-POSED FIT. Once there are `minCheckIns` check-ins on at least `minDays` different
//      days, the model's six free weights (`EnergyBank.Parameters`) are refitted to the reports by a
//      Gaussian-prior (ridge) regression centred on the shipped defaults. Every weight enters the
//      balance linearly (ignoring the 0–100 clamp and the rest-credit cap), so this is one 6 × 6 linear
//      solve, not a search: posterior mean = (D + XᵀX/σ²)⁻¹ (D·θ₀ + Xᵀy/σ²), with D the prior precisions.
//      With a handful of reports the prior dominates and the weights stay near the defaults; with many
//      the reports do. The fitted set is then projected into the model's ranges (a share in 0–1, no
//      negative costs — a spend is never credited, so if strain does not tire this wearer its cost goes
//      to zero, not below).
//
//   3. HONEST AFTER-AGREEMENT. The "after" figure is LEAVE-ONE-OUT: each check-in is predicted by a fit
//      that never saw it. An in-sample figure would always look better and mean nothing.
//
//   4. THE VERDICT. If the better of before/after reaches ρ ≥ `weakRho` with an interval that excludes
//      zero, the number is presented as the wearer's energy. Otherwise it is NOT — the tile says plainly
//      that it does not track how the wearer feels and relabels itself a physiological-load estimate
//      (or hides, at the wearer's choice). Contradicting a person about their own tiredness with false
//      confidence is the failure this whole file exists to stop.

/// One reported energy level, with what the model saw when it was reported.
public struct EnergyCheckIn: Codable, Equatable, Sendable, Identifiable {
    public enum Slot: String, Codable, Sendable, CaseIterable {
        case morning
        case afternoon
    }

    public let id: String
    public let at: Date
    /// The `yyyy-MM-dd` day it belongs to.
    public let day: String
    public let slot: Slot
    /// 1 (empty) … 5 (full).
    public let felt: Int
    /// The model's inputs at (or just after) the check-in. Nil until Today has computed them — a check-in
    /// taken in the morning flow is matched to the first balance Today computes for its day.
    public var inputs: EnergyInputs?

    public init(id: String = UUID().uuidString, at: Date, day: String, slot: Slot, felt: Int,
                inputs: EnergyInputs? = nil) {
        self.id = id
        self.at = at
        self.day = day
        self.slot = slot
        self.felt = felt
        self.inputs = inputs
    }
}

public enum EnergyCalibration {

    // MARK: - Thresholds (stated once)

    /// Check-ins needed before the model is refitted or judged. Fourteen is two weeks of mornings; below
    /// it the rank correlation's interval is wider than the whole useful range.
    public static let minCheckIns = 14
    /// …on at least this many different days, so one day's five taps cannot pass for a relationship.
    public static let minDays = 10
    /// The agreement below which the number stops being presented as "your energy". 0.3 is the
    /// conventional floor of a moderate correlation; the interval must also exclude zero.
    public static let weakRho = 0.3
    /// The most recent check-ins judged — about two months at two a day.
    public static let window = 120
    /// Assumed spread of a report around the truth, in balance points (≈ one step of the 1–5 scale is 25).
    public static let reportNoiseSD = 20.0
    /// How far each weight may plausibly sit from its default — the prior's standard deviations.
    public static let priorSD = EnergyBank.Parameters(
        bias: 15, recoveryShare: 0.2, strainCost: 25, stressCost: 15, restReturnMax: 10,
        awakeCostPerHour: 2)

    /// A 1–5 report on the balance's 0–100 axis: 1 → 0, 3 → 50, 5 → 100. Nil outside 1–5.
    public static func feltPoints(_ felt: Int) -> Double? {
        guard (1...5).contains(felt) else { return nil }
        return Double(felt - 1) * 25
    }

    // MARK: - Agreement

    /// A rank correlation and its 95 % interval.
    public struct Agreement: Equatable, Sendable {
        public let rho: Double
        public let lower: Double
        public let upper: Double
        public let n: Int

        /// True when the interval lies wholly above zero.
        public var excludesZero: Bool { lower > 0 }
    }

    /// Spearman's ρ between `x` and `y` (ties take their average rank), with a Fisher-z 95 % interval.
    /// Nil when the lengths differ, fewer than four pairs exist, or either side has no spread (every
    /// report the same says nothing about agreement).
    public static func spearman(_ x: [Double], _ y: [Double]) -> Agreement? {
        let n = x.count
        guard n == y.count, n >= 4 else { return nil }
        guard x.allSatisfy({ $0.isFinite }), y.allSatisfy({ $0.isFinite }) else { return nil }
        guard let rho = pearson(ranks(x), ranks(y)) else { return nil }
        let z = atanh(Swift.min(Swift.max(rho, -0.999_999), 0.999_999))
        let se = (1.06 / Double(n - 3)).squareRoot()
        return Agreement(rho: rho, lower: tanh(z - 1.96 * se), upper: tanh(z + 1.96 * se), n: n)
    }

    /// 1-based ranks, ties sharing their average rank.
    public static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var out = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let average = Double(i + j) / 2 + 1
            for k in i...j { out[order[k]] = average }
            i = j + 1
        }
        return out
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let n = Double(a.count)
        guard a.count == b.count, a.count > 1 else { return nil }
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var sab = 0.0, saa = 0.0, sbb = 0.0
        for i in a.indices {
            let da = a[i] - ma, db = b[i] - mb
            sab += da * db
            saa += da * da
            sbb += db * db
        }
        guard saa > 0, sbb > 0 else { return nil }
        return sab / (saa * sbb).squareRoot()
    }

    // MARK: - The fit

    /// One training pair: what the model saw, and the report on the 0–100 axis.
    public struct Sample: Equatable, Sendable {
        public let inputs: EnergyInputs
        public let target: Double
        public init(inputs: EnergyInputs, target: Double) {
            self.inputs = inputs
            self.target = target
        }
    }

    /// The balance's linear form (no clamps, no rest-credit cap): what the fit regresses on.
    public static func linearPrediction(_ f: EnergyBank.Features, _ p: EnergyBank.Parameters) -> Double {
        f.base + p.bias + p.recoveryShare * f.shareSpread
            - p.strainCost * f.strainFraction - p.stressCost * f.stressFraction
            + p.restReturnMax * f.calmFraction - p.awakeCostPerHour * f.hoursAwake
    }

    /// The regularised fit. Samples without an opening, or with a non-finite target, are skipped. With no
    /// usable sample this returns the prior, projected — never a guess.
    public static func fit(_ samples: [Sample],
                           prior: EnergyBank.Parameters = .defaults,
                           priorSD: EnergyBank.Parameters = EnergyCalibration.priorSD,
                           noiseSD: Double = EnergyCalibration.reportNoiseSD) -> EnergyBank.Parameters {
        let theta0 = vector(prior)
        let sd = vector(priorSD)
        let k = theta0.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [Double](repeating: 0, count: k)
        for j in 0..<k {
            let precision = 1 / (sd[j] * sd[j])
            a[j][j] = precision
            b[j] = precision * theta0[j]
        }
        let w = 1 / (noiseSD * noiseSD)
        var used = 0
        for s in samples {
            guard s.target.isFinite, let f = EnergyBank.features(s.inputs) else { continue }
            // θ = (bias, share, strainCost, stressCost, restMax, awake); prediction = base + x·θ.
            let x = [1, f.shareSpread, -f.strainFraction, -f.stressFraction, f.calmFraction, -f.hoursAwake]
            let y = s.target - f.base
            for r in 0..<k {
                b[r] += w * x[r] * y
                for c in 0..<k { a[r][c] += w * x[r] * x[c] }
            }
            used += 1
        }
        guard used > 0, let theta = solve(a, b) else { return prior.projected }
        return parameters(theta).projected
    }

    static func vector(_ p: EnergyBank.Parameters) -> [Double] {
        [p.bias, p.recoveryShare, p.strainCost, p.stressCost, p.restReturnMax, p.awakeCostPerHour]
    }

    static func parameters(_ v: [Double]) -> EnergyBank.Parameters {
        EnergyBank.Parameters(bias: v[0], recoveryShare: v[1], strainCost: v[2], stressCost: v[3],
                              restReturnMax: v[4], awakeCostPerHour: v[5])
    }

    /// Gaussian elimination with partial pivoting. The system here is symmetric positive definite (a
    /// positive prior precision on every weight), so a pivot near zero means corrupt input, not a
    /// singular problem — nil then.
    static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var m = matrix
        var v = rhs
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(m[r][col]) > abs(m[pivot][col]) { pivot = r }
            guard abs(m[pivot][col]) > 1e-12, m[pivot][col].isFinite else { return nil }
            if pivot != col {
                m.swapAt(pivot, col)
                v.swapAt(pivot, col)
            }
            for r in (col + 1)..<n {
                let factor = m[r][col] / m[col][col]
                if factor == 0 { continue }
                for c in col..<n { m[r][c] -= factor * m[col][c] }
                v[r] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[r]
            for c in (r + 1)..<n { sum -= m[r][c] * x[c] }
            x[r] = sum / m[r][r]
        }
        return x.allSatisfy({ $0.isFinite }) ? x : nil
    }

    // MARK: - The verdict

    public enum Status: String, Equatable, Sendable {
        /// Fewer than `minCheckIns` usable check-ins, or fewer than `minDays` days. Shown as an estimate.
        case calibrating
        /// Agreement reaches `weakRho` with an interval above zero. Shown as the wearer's energy.
        case tracks
        /// Enough check-ins, and the model still does not track them. Shown as a load estimate, or hidden.
        case weak
    }

    public struct Verdict: Equatable, Sendable {
        public let status: Status
        /// Check-ins with a report in 1–5 and an opening to compare it against.
        public let usable: Int
        /// Distinct days among them.
        public let days: Int
        /// Agreement under the default weights (nil below four check-ins or with no spread).
        public let before: Agreement?
        /// Leave-one-out agreement under the fitted weights (nil while calibrating).
        public let after: Agreement?
        /// The weights the tile should draw with: the fitted set when it did better out of sample,
        /// otherwise the defaults.
        public let params: EnergyBank.Parameters
        /// True when `params` is the fitted set.
        public let fitted: Bool

        /// The agreement the status was decided on.
        public var decidingAgreement: Agreement? { fitted ? after : (before ?? after) }
    }

    /// Judge the model against the wearer's check-ins.
    public static func evaluate(_ checkIns: [EnergyCheckIn],
                                prior: EnergyBank.Parameters = .defaults) -> Verdict {
        var samples: [Sample] = []
        var days = Set<String>()
        // The most recent `window` only: bounds the leave-one-out work, and lets the verdict follow a
        // wearer whose relationship with the model changes (the model itself was just repaired).
        for c in checkIns.sorted(by: { $0.at < $1.at }).suffix(window) {
            guard let inputs = c.inputs, let target = feltPoints(c.felt),
                  EnergyBank.features(inputs) != nil else { continue }
            samples.append(Sample(inputs: inputs, target: target))
            days.insert(c.day)
        }
        let targets = samples.map(\.target)
        let defaultValues = samples.compactMap { EnergyBank.balance($0.inputs, params: prior)?.balance }
        let before = spearman(defaultValues, targets)

        guard samples.count >= minCheckIns, days.count >= minDays else {
            return Verdict(status: .calibrating, usable: samples.count, days: days.count,
                           before: before, after: nil, params: prior.projected, fitted: false)
        }

        // Leave-one-out: each report predicted by a fit that never saw it.
        var held: [Double] = []
        held.reserveCapacity(samples.count)
        for i in samples.indices {
            var rest = samples
            rest.remove(at: i)
            let p = fit(rest, prior: prior)
            held.append(EnergyBank.balance(samples[i].inputs, params: p)?.balance ?? .nan)
        }
        let after = spearman(held, targets)
        let full = fit(samples, prior: prior)

        let useFitted: Bool
        switch (before, after) {
        case let (b?, a?): useFitted = a.rho >= b.rho
        case (nil, _?): useFitted = true
        default: useFitted = false
        }
        let deciding = useFitted ? after : before
        let tracks = deciding.map { $0.rho >= weakRho && $0.excludesZero } ?? false
        return Verdict(status: tracks ? .tracks : .weak, usable: samples.count, days: days.count,
                       before: before, after: after,
                       params: useFitted ? full : prior.projected, fitted: useFitted)
    }
}

// MARK: - What the tile may claim

extension EnergyCalibration {

    /// How the Today tile presents the balance. Decided here, not in the view, so the rule "a model that
    /// has not earned the word energy does not get to use it" is tested rather than drawn.
    public enum TileMode: Equatable, Sendable {
        /// No opening balance: a dash.
        case unknown
        /// Not enough check-ins yet: an approximate value, the `calibrating` tier and a check-in prompt.
        case calibrating(checkIns: Int, needed: Int, days: Int, neededDays: Int)
        /// It tracks the wearer: shown as their energy.
        case energy
        /// It does not track the wearer: shown as a labelled load estimate (or hidden, by choice).
        case loadEstimate
    }

    public static func tileMode(balance: EnergyBalance?, verdict: Verdict) -> TileMode {
        guard let balance, balance.balance.isFinite else { return .unknown }
        switch verdict.status {
        case .calibrating:
            return .calibrating(checkIns: Swift.min(verdict.usable, minCheckIns), needed: minCheckIns,
                                days: Swift.min(verdict.days, minDays), neededDays: minDays)
        case .tracks:
            return .energy
        case .weak:
            return .loadEstimate
        }
    }

    /// The figure as the tile prints it. Only a model that tracks the wearer is printed to the point;
    /// while calibrating, and as a load estimate, it is rounded to the nearest 5 and marked "≈" — a
    /// precision the model has not earned would read as a measurement. Never a decimal; "–" when absent
    /// or non-finite.
    public static func displayValue(_ balance: Double?, mode: TileMode) -> String {
        guard let balance, balance.isFinite else { return "–" }
        let clamped = Swift.min(Swift.max(balance, 0), 100)
        switch mode {
        case .unknown:
            return "–"
        case .energy:
            return "\(Int(clamped.rounded()))"
        case .calibrating, .loadEstimate:
            return "≈\(Int((clamped / 5).rounded()) * 5)"
        }
    }
}
