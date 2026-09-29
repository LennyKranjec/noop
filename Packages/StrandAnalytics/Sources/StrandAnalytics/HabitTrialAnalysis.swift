import Foundation

// HabitTrialAnalysis.swift — the analysis of a finished habit trial. Pure and deterministic.
//
// HEALTH_V2 §S1-B.4–B.6. The design choices, each for a stated reason:
//
// INTENTION-TO-TREAT. Every day with an observed outcome is analysed in the arm it was ASSIGNED to,
// whatever the adherence. (a) The permutation test is exact only for the randomised assignment; dropping
// non-adherent days breaks exchangeability. (b) Adherence is not random — people skip "screens off" on
// stressful evenings, which are also low-HRV evenings — so per-protocol would manufacture a benefit.
// (c) Non-adherence dilutes ITT toward zero: it can cost power, never create a false "helped".
// Per-protocol is computed as an EXPLORATORY secondary and never touches the verdict.
//
// MISSING IS MISSING. A night with no outcome (strap off, no sleep detected, calibrating input, an HRV
// night outside plausibility bounds — all decided app-side, which passes no value) is excluded from the
// observed statistic AND from every permuted statistic. Never zero, never carried forward, never imputed.
// A day without its Effort covariate is dropped the same way (Effort is not moved by the assignment for
// the interventions that use day D's Effort; `walkAfterDinner10` uses D−1's).
//
// INFERENCE BY RANDOMISATION. The model `y = β0 + τ·ON + β1·effort + β2·t [+ β3·weekend]
// [+ β4·prevAssignedOn] + ε` is fitted by OLS, and τ̂ is compared with the τ̂* of the SAME model refitted
// under 10,000 assignments re-drawn with the EXACT registered procedure (`HabitTrialSchedule.redraw`, same
// design and constraints, sub-seeds derived from the registered seed). Under the sharp null the outcome
// series is fixed and only the assignment is random, so the null distribution is exact whatever the
// autocorrelation of the nights: autocorrelation costs power, it cannot inflate the false-positive rate.
// The same model is refitted per draw via Frisch–Waugh–Lovell: τ̂ = (M d)·(M y) / (M d)·(M d), with M the
// residual-maker of the fixed covariates, computed once; `prevAssignedOn` is assignment-derived, so for
// short carry-over it is rebuilt from each permuted schedule and partialled out per draw.
//
// 95 % INTERVAL BY TEST INVERSION under the constant-additive-effect model: every δ for which "the effect
// is δ" is not rejected at 2.5 % in either tail. Under the shift y − δ·d_obs every permuted statistic is
// linear in δ (a* − δ·b*), so each draw's rejection region is a half-line whose end is known in closed
// form; the interval is found EXACTLY by one sort over those ends, re-using the same stored draws — so it
// is deterministic and consistent with the p-value. (HEALTH_V2 describes a bisection; this computes the
// same set without iteration.)
//
// SEALED. Nothing calls this while a trial runs (`HabitTrialStore` has no path to it before
// `completed`), and a stopped-early trial gets `stoppedEarly(...)`, which runs no analysis at all.

/// What the analysis reads. Values the app could not trust are simply not in the dictionaries.
public struct HabitTrialObservations: Equatable, Sendable {
    /// Primary outcome in analysis units (HRV as ln RMSSD), keyed by OUTCOME key (the wake day).
    public var outcomes: [String: Double]
    /// Day Effort keyed by calendar day (any fixed linear scale).
    public var effort: [String: Double]
    /// Per assignment day: did the wearer do the ON behaviour?
    public var behaviour: [String: HabitTrialBehaviour]
    /// Assignment days on which the illness heads-up was raised.
    public var illnessRaisedDays: Set<String>
    /// Outcome keys of nights that followed an evening with alcohol (exploratory sensitivity only).
    public var alcoholNights: Set<String>
    /// Secondary outcomes in analysis units, keyed by outcome key. Always exploratory.
    public var secondaryOutcomes: [HabitOutcome: [String: Double]]

    public init(outcomes: [String: Double], effort: [String: Double],
                behaviour: [String: HabitTrialBehaviour] = [:], illnessRaisedDays: Set<String> = [],
                alcoholNights: Set<String> = [], secondaryOutcomes: [HabitOutcome: [String: Double]] = [:]) {
        self.outcomes = outcomes
        self.effort = effort
        self.behaviour = behaviour
        self.illnessRaisedDays = illnessRaisedDays
        self.alcoholNights = alcoholNights
        self.secondaryOutcomes = secondaryOutcomes
    }
}

/// An exploratory estimate: a point estimate and its arm sizes, never a verdict.
public struct HabitTrialExploratory: Equatable, Codable, Sendable {
    public let name: String
    public let outcome: HabitOutcome
    /// Analysis units. Nil when it could not be fitted.
    public let estimate: Double?
    public let nOn: Int
    public let nOff: Int
    /// Always "Exploratory".
    public var label: String { "Exploratory" }
}

/// The analysis of a trial.
public struct HabitTrialResult: Equatable, Codable, Sendable {
    public let trialId: String
    public let interventionId: String
    public let primaryOutcome: HabitOutcome
    public let direction: EffectDirection
    public let mcid: Double
    /// The record's hash matched the stored one.
    public let recordIntact: Bool
    /// Nil only when the record was altered ("trial record altered — no verdict").
    public let verdict: HabitTrialVerdict?
    /// The gate that forced Inconclusive, if any (the estimate is then not computed).
    public let gate: HabitTrialInconclusiveReason?

    /// τ̂ in analysis units (HRV: ln ratio). Nil when a gate failed or the design was singular.
    public let estimate: Double?
    public let lower: Double?
    public let upper: Double?
    /// One-sided randomisation p in the registered direction.
    public let pOneSided: Double?
    public let permutations: Int

    public let lengthDays: Int
    public let plannedPerArm: Int
    public let nOn: Int
    public let nOff: Int
    /// Planned analysable days per arm without a usable value (outcome or covariate missing).
    public let missingOn: Int
    public let missingOff: Int
    /// Of those, days dropped only because their Effort covariate was missing.
    public let droppedForCovariate: Int
    public let washoutDays: Int
    public let onDays: Int
    public let offDays: Int
    /// Share of ON days answered "did it" (unknown counts as not followed).
    public let adherenceOn: Double
    /// Share of OFF days answered "did it anyway".
    public let contaminationOff: Double
    public let illnessDays: Int

    /// Raw arm means of the analysed days (analysis units). Only when the analysis ran.
    public let meanOn: Double?
    public let meanOff: Double?
    /// Lag-1 autocorrelation of the model residuals, reported (not modelled away).
    public let residualLag1: Double?
    /// "≈ N more valid days" for Inconclusive(tooFewDays / imprecise).
    public let moreValidDaysNeeded: Int?
    /// The smallest allowed length whose MDE ≤ 2 × MCID with this trial's residual SD and ρ.
    public let recommendedLengthDays: Int?

    public let perProtocol: HabitTrialExploratory?
    public let secondaries: [HabitTrialExploratory]
    public let alcoholExcluded: HabitTrialExploratory?
}

public enum HabitTrialAnalysis {

    /// Share of ON days that must be followed.
    public static let minAdherence = 0.70
    /// Share of OFF days that may be contaminated.
    public static let maxContamination = 0.30
    /// Share of each arm's scheduled analysable days that must be analysable.
    public static let minValidShare = 0.70
    /// Illness-raised trial days that make a trial Inconclusive.
    public static let illnessDaysLimit = 3

    // MARK: Entry points

    /// Analyse a COMPLETED trial. `permutations` overrides the registered count (tests only).
    public static func analyse(registration r: HabitTrialRegistration, storedHash: String,
                               observations obs: HabitTrialObservations,
                               permutations: Int? = nil) -> HabitTrialResult {
        let intact = r.verify(storedHash: storedHash)
            && r.schedule == HabitTrialSchedule.assignments(design: r.design, lengthDays: r.lengthDays, seed: r.seed)
            && r.schedule.count == r.lengthDays
        let B = Swift.max(1, permutations ?? r.permutations)
        let plannedPerArm = HabitTrialSchedule.analysableDaysPerArm(design: r.design, lengthDays: r.lengthDays)
        guard intact else {
            return empty(r, intact: false, verdict: nil, gate: nil, B: B, plannedPerArm: plannedPerArm)
        }

        // Day table.
        let washout = HabitTrialSchedule.washoutMask(design: r.design, lengthDays: r.lengthDays)
        let useWeekend = r.covariates.contains(.weekend)
        let useShort = r.covariates.contains(.prevAssignedOn)
        let effortLag = r.covariates.contains(.effortPreviousDay) ? -1 : 0

        var onDays = 0, offDays = 0, onFollowed = 0, offContaminated = 0, illness = 0
        var rowsIdx: [Int] = []
        var y: [Double] = []
        var effortCol: [Double] = []
        var missingOn = 0, missingOff = 0, droppedForCovariate = 0, washoutDays = 0
        var outcomeKeys: [String] = []
        for i in 0..<r.lengthDays {
            guard let day = HabitDay.adding(i, to: r.startDay) else { continue }
            let on = r.schedule[i]
            let b = obs.behaviour[day] ?? .unknown
            if on {
                onDays += 1
                if b == .did { onFollowed += 1 }
            } else {
                offDays += 1
                if b == .did { offContaminated += 1 }
            }
            if obs.illnessRaisedDays.contains(day) { illness += 1 }
            if washout[i] {
                washoutDays += 1
                continue
            }
            guard let key = r.lag.outcomeKey(for: day), let value = obs.outcomes[key], value.isFinite else {
                if on { missingOn += 1 } else { missingOff += 1 }
                continue
            }
            guard let effortDay = HabitDay.adding(effortLag, to: day), let e = obs.effort[effortDay], e.isFinite else {
                droppedForCovariate += 1
                if on { missingOn += 1 } else { missingOff += 1 }
                continue
            }
            rowsIdx.append(i)
            y.append(value)
            effortCol.append(e)
            outcomeKeys.append(key)
        }
        let adherence = onDays > 0 ? Double(onFollowed) / Double(onDays) : 0
        let contamination = offDays > 0 ? Double(offContaminated) / Double(offDays) : 0
        let nOn = rowsIdx.filter { r.schedule[$0] }.count
        let nOff = rowsIdx.count - nOn

        func gated(_ reason: HabitTrialInconclusiveReason, more: Int? = nil) -> HabitTrialResult {
            HabitTrialResult(
                trialId: r.trialId, interventionId: r.interventionId, primaryOutcome: r.primaryOutcome,
                direction: r.direction, mcid: r.mcid, recordIntact: true, verdict: .inconclusive(reason),
                gate: reason, estimate: nil, lower: nil, upper: nil, pOneSided: nil, permutations: B,
                lengthDays: r.lengthDays, plannedPerArm: plannedPerArm, nOn: nOn, nOff: nOff,
                missingOn: missingOn, missingOff: missingOff, droppedForCovariate: droppedForCovariate,
                washoutDays: washoutDays, onDays: onDays, offDays: offDays, adherenceOn: adherence,
                contaminationOff: contamination, illnessDays: illness, meanOn: nil, meanOff: nil,
                residualLag1: nil, moreValidDaysNeeded: more, recommendedLengthDays: nil, perProtocol: nil,
                secondaries: [], alcoholExcluded: nil)
        }

        // Gates, in a fixed order.
        if illness >= illnessDaysLimit { return gated(.illness) }
        if adherence < minAdherence || contamination > maxContamination { return gated(.adherence) }
        let needPerArm = Int((minValidShare * Double(plannedPerArm)).rounded(.up))
        if nOn < needPerArm || nOff < needPerArm {
            return gated(.tooFewDays, more: Swift.max(needPerArm - nOn, 0) + Swift.max(needPerArm - nOff, 0))
        }
        let imbalanceLimit = Swift.max(3.0, 0.15 * Double(plannedPerArm))
        if Double(abs(missingOn - missingOff)) > imbalanceLimit { return gated(.missingImbalance) }

        // Fixed covariates Z = [1, effort, t, (weekend)].
        var zRows: [[Double]] = []
        zRows.reserveCapacity(rowsIdx.count)
        for (k, i) in rowsIdx.enumerated() {
            var row: [Double] = [1, effortCol[k], Double(i)]
            if useWeekend {
                let day = HabitDay.adding(i, to: r.startDay) ?? r.startDay
                row.append(HabitDay.isWeekendEvening(day) ? 1 : 0)
            }
            zRows.append(row)
        }
        guard let M = HabitStats.Residualizer(covariateRows: zRows) else { return gated(.singularDesign) }
        let kernel = PermutationKernel(M: M, y: y, rowsIdx: rowsIdx, observed: r.schedule, useShort: useShort)
        guard let observed = kernel.statistic(r.schedule), !observed.degenerate else {
            return gated(.singularDesign)
        }
        let tauHat = observed.a

        // Permutations: the registered procedure, fresh sub-seeds.
        var draws: [(a: Double, b: Double, degenerate: Bool)] = []
        draws.reserveCapacity(B)
        for k in 0..<B {
            let seed = HabitTrialSchedule.permutationSeed(registered: r.seed, index: k)
            let d = HabitTrialSchedule.redraw(design: r.design, days: r.lengthDays, seed: seed)
            if let s = kernel.statistic(d) {
                draws.append((a: s.a, b: s.b, degenerate: s.degenerate))
            } else {
                draws.append((a: 0, b: 0, degenerate: true))
            }
        }

        // One-sided p in the registered direction (degenerate draws count as extreme: conservative).
        let sign = r.direction.sign
        let tieTol = 1e-12 * (1 + abs(tauHat))
        var extreme = 0
        for d in draws where d.degenerate || sign * d.a >= sign * tauHat - tieTol { extreme += 1 }
        let p = Double(1 + extreme) / Double(1 + B)

        let ci = invertInterval(tauHat: tauHat, draws: draws, alpha: r.alpha, B: B)

        // Descriptives and exploratory pieces.
        var onVals: [Double] = [], offVals: [Double] = []
        for (k, i) in rowsIdx.enumerated() {
            if r.schedule[i] { onVals.append(y[k]) } else { offVals.append(y[k]) }
        }
        let fullFit = fitOLS(y: y, rowsIdx: rowsIdx, zRows: zRows, assignment: r.schedule, useShort: useShort)
        let rho: Double? = fullFit.flatMap { HabitStats.lag1Autocorrelation(values: $0.residuals, positions: rowsIdx) }
        let residSD: Double? = fullFit.flatMap { (fit: HabitStats.OLSFit) -> Double? in
            let df = fit.residuals.count - fit.columns
            guard df > 0 else { return nil }
            var ss = 0.0
            for e in fit.residuals { ss += e * e }
            return (ss / Double(df)).squareRoot()
        }
        var recommended: Int? = nil
        if let sd = residSD {
            for length in r.design.allowedLengths {
                let perArm = HabitTrialSchedule.analysableDaysPerArm(design: r.design, lengthDays: length)
                if let m = minimumDetectableEffect(sd: sd, rho: rho ?? 0, nOn: perArm, nOff: perArm),
                   m <= 2 * r.mcid {
                    recommended = length
                    break
                }
            }
        }

        let verdict = HabitTrialVerdict.decide(estimate: tauHat, lower: ci?.lower, upper: ci?.upper,
                                               direction: r.direction, mcid: r.mcid, gate: nil)
        var more: Int? = nil
        if case .inconclusive(.imprecise) = verdict, let ci {
            let half = (ci.upper - ci.lower) / 2
            let target = r.mcid / 2
            if half > target, target > 0 {
                let factor = (half / target) * (half / target)
                more = Int((Double(nOn + nOff) * (factor - 1)).rounded(.up))
            }
        }

        // Per-protocol (exploratory): followed ON days vs not-contaminated OFF days.
        var ppKeep: [Bool] = []
        for i in rowsIdx {
            let day = HabitDay.adding(i, to: r.startDay) ?? r.startDay
            let b = obs.behaviour[day] ?? .unknown
            ppKeep.append(r.schedule[i] ? b == .did : b != .did)
        }
        let perProtocol = exploratory(name: "Per-protocol (followed ON vs uncontaminated OFF)",
                                      outcome: r.primaryOutcome, y: y, rowsIdx: rowsIdx, zRows: zRows,
                                      keep: ppKeep, assignment: r.schedule, useShort: useShort)

        // Secondaries (exploratory): the same model on each secondary outcome.
        var secondaries: [HabitTrialExploratory] = []
        for outcome in r.secondaryOutcomes {
            guard let series = obs.secondaryOutcomes[outcome] else {
                secondaries.append(HabitTrialExploratory(name: outcome.label, outcome: outcome, estimate: nil,
                                                         nOn: 0, nOff: 0))
                continue
            }
            var sy: [Double] = [], sIdx: [Int] = [], sZ: [[Double]] = []
            for (k, i) in rowsIdx.enumerated() {
                if let v = series[outcomeKeys[k]], v.isFinite {
                    sy.append(v)
                    sIdx.append(i)
                    sZ.append(zRows[k])
                }
            }
            secondaries.append(exploratory(name: outcome.label, outcome: outcome, y: sy, rowsIdx: sIdx,
                                           zRows: sZ, keep: nil, assignment: r.schedule, useShort: useShort))
        }

        // Alcohol-night sensitivity (exploratory), when alcohol is not the intervention.
        var alcoholExcluded: HabitTrialExploratory? = nil
        if r.interventionId != "alcoholFree", !obs.alcoholNights.isDisjoint(with: Set(outcomeKeys)) {
            let keep = outcomeKeys.map { !obs.alcoholNights.contains($0) }
            alcoholExcluded = exploratory(name: "Excluding nights after alcohol", outcome: r.primaryOutcome,
                                          y: y, rowsIdx: rowsIdx, zRows: zRows, keep: keep,
                                          assignment: r.schedule, useShort: useShort)
        }

        return HabitTrialResult(
            trialId: r.trialId, interventionId: r.interventionId, primaryOutcome: r.primaryOutcome,
            direction: r.direction, mcid: r.mcid, recordIntact: true, verdict: verdict, gate: nil,
            estimate: tauHat, lower: ci?.lower, upper: ci?.upper, pOneSided: p, permutations: B,
            lengthDays: r.lengthDays, plannedPerArm: plannedPerArm, nOn: nOn, nOff: nOff,
            missingOn: missingOn, missingOff: missingOff, droppedForCovariate: droppedForCovariate,
            washoutDays: washoutDays, onDays: onDays, offDays: offDays, adherenceOn: adherence,
            contaminationOff: contamination, illnessDays: illness, meanOn: HabitStats.mean(onVals),
            meanOff: HabitStats.mean(offVals), residualLag1: rho, moreValidDaysNeeded: more,
            recommendedLengthDays: recommended, perProtocol: perProtocol, secondaries: secondaries,
            alcoholExcluded: alcoholExcluded)
    }

    /// A trial the wearer ended early: Inconclusive(stoppedEarly), no numbers, no analysis run.
    public static func stoppedEarly(registration r: HabitTrialRegistration, storedHash: String) -> HabitTrialResult {
        let intact = r.verify(storedHash: storedHash)
        let planned = HabitTrialSchedule.analysableDaysPerArm(design: r.design, lengthDays: r.lengthDays)
        return empty(r, intact: intact, verdict: intact ? .inconclusive(.stoppedEarly) : nil,
                     gate: intact ? .stoppedEarly : nil, B: 0, plannedPerArm: planned)
    }

    // MARK: Minimum detectable effect

    /// `2.8 · σ · √(1/nOn + 1/nOff) · √((1+ρ)/(1−ρ))`, ρ clamped to [0, 0.6] (80 % power at two-sided 5 %,
    /// with an AR(1) variance inflation).
    public static func minimumDetectableEffect(sd: Double, rho: Double, nOn: Int, nOff: Int) -> Double? {
        guard sd.isFinite, sd >= 0, nOn > 0, nOff > 0 else { return nil }
        let r = Swift.min(0.6, Swift.max(0, rho.isFinite ? rho : 0))
        return 2.8 * sd * (1 / Double(nOn) + 1 / Double(nOff)).squareRoot() * ((1 + r) / (1 - r)).squareRoot()
    }

    // MARK: OLS

    /// OLS of `y` on `[Z | ON | (prevAssignedOn)]`; the ON coefficient is at index `Z.count`.
    /// Nil (abstain) on a singular design. ≤ 6 regressors.
    public static func fitOLS(y: [Double], rowsIdx: [Int], zRows: [[Double]], assignment: [Bool],
                              useShort: Bool) -> HabitStats.OLSFit? {
        guard y.count == rowsIdx.count, zRows.count == y.count else { return nil }
        var rows: [[Double]] = []
        rows.reserveCapacity(y.count)
        for (k, i) in rowsIdx.enumerated() {
            guard i >= 0, i < assignment.count else { return nil }
            var row = zRows[k]
            row.append(assignment[i] ? 1 : 0)
            if useShort { row.append(i > 0 && assignment[i - 1] ? 1 : 0) }
            rows.append(row)
        }
        return HabitStats.ols(y: y, rows: rows)
    }

    // MARK: Internals

    private static func exploratory(name: String, outcome: HabitOutcome, y: [Double], rowsIdx: [Int],
                                    zRows: [[Double]], keep: [Bool]?, assignment: [Bool],
                                    useShort: Bool) -> HabitTrialExploratory {
        var ky: [Double] = [], kIdx: [Int] = [], kZ: [[Double]] = []
        for k in 0..<y.count where keep?[k] ?? true {
            ky.append(y[k])
            kIdx.append(rowsIdx[k])
            kZ.append(zRows[k])
        }
        let nOn = kIdx.filter { assignment[$0] }.count
        let nOff = kIdx.count - nOn
        var estimate: Double? = nil
        if nOn >= 3, nOff >= 3,
           let fit = fitOLS(y: ky, rowsIdx: kIdx, zRows: kZ, assignment: assignment, useShort: useShort),
           let firstZ = kZ.first {
            estimate = fit.coefficients[firstZ.count]
        }
        return HabitTrialExploratory(name: name, outcome: outcome, estimate: estimate, nOn: nOn, nOff: nOff)
    }

    private static func empty(_ r: HabitTrialRegistration, intact: Bool, verdict: HabitTrialVerdict?,
                              gate: HabitTrialInconclusiveReason?, B: Int, plannedPerArm: Int) -> HabitTrialResult {
        HabitTrialResult(
            trialId: r.trialId, interventionId: r.interventionId, primaryOutcome: r.primaryOutcome,
            direction: r.direction, mcid: r.mcid, recordIntact: intact, verdict: verdict, gate: gate,
            estimate: nil, lower: nil, upper: nil, pOneSided: nil, permutations: B, lengthDays: r.lengthDays,
            plannedPerArm: plannedPerArm, nOn: 0, nOff: 0, missingOn: 0, missingOff: 0, droppedForCovariate: 0,
            washoutDays: 0, onDays: 0, offDays: 0, adherenceOn: 0, contaminationOff: 0, illnessDays: 0,
            meanOn: nil, meanOff: nil, residualLag1: nil, moreValidDaysNeeded: nil, recommendedLengthDays: nil,
            perProtocol: nil, secondaries: [], alcoholExcluded: nil)
    }

    /// The exact test-inversion interval. Nil when unbounded on either side (the data cannot bound it).
    static func invertInterval(tauHat: Double, draws: [(a: Double, b: Double, degenerate: Bool)],
                               alpha: Double, B: Int) -> (lower: Double, upper: Double)? {
        // Draw k's statistic under "effect = δ" is a − δ·b; the observed one is τ̂ − δ.
        //   U_k (counts toward the UPPER-tail p) = {δ : a − δb ≥ τ̂ − δ} = {(1 − b)δ ≥ τ̂ − a}
        //   L_k (LOWER-tail p)                   = {δ : a − δb ≤ τ̂ − δ} = {(1 − b)δ ≤ τ̂ − a}
        // b < 1: U = [c, ∞), L = (−∞, c];  b > 1: U = (−∞, c], L = [c, ∞);  c = (τ̂ − a)/(1 − b).
        var lessC: [Double] = []
        var moreC: [Double] = []
        var constUp = 0, constLow = 0
        let tol = 1e-12 * (1 + abs(tauHat))
        for d in draws {
            if d.degenerate {
                constUp += 1
                constLow += 1
                continue
            }
            let oneMinusB = 1 - d.b
            if abs(oneMinusB) < 1e-12 {
                if d.a >= tauHat - tol { constUp += 1 }
                if d.a <= tauHat + tol { constLow += 1 }
                continue
            }
            let c = (tauHat - d.a) / oneMinusB
            guard c.isFinite else {
                constUp += 1
                constLow += 1
                continue
            }
            if oneMinusB > 0 { lessC.append(c) } else { moreC.append(c) }
        }
        lessC.sort()
        moreC.sort()
        // Accept δ iff (1 + N)/(B + 1) > α/2 in BOTH tails.
        let bar = alpha / 2 * Double(B + 1)
        func accepted(_ delta: Double) -> Bool {
            let up = constUp + countLE(lessC, delta) + countGE(moreC, delta)
            let low = constLow + countGE(lessC, delta) + countLE(moreC, delta)
            return Double(1 + up) > bar && Double(1 + low) > bar
        }
        let breaks = (lessC + moreC).sorted()
        guard let first = breaks.first, let last = breaks.last else { return nil }
        let span = Swift.max(1, abs(first), abs(last))
        // Outside every break the counts are constant: acceptance there means the set is unbounded.
        if accepted(first - span) || accepted(last + span) { return nil }
        // The acceptance set is closed (every half-line is closed), so its extremes are breakpoints.
        var lo: Double? = nil, hi: Double? = nil
        for c in breaks where accepted(c) {
            if lo == nil { lo = c }
            hi = c
        }
        guard let lower = lo, let upper = hi else { return nil }
        return (lower: lower, upper: upper)
    }

    private static func countLE(_ sorted: [Double], _ x: Double) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] <= x { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func countGE(_ sorted: [Double], _ x: Double) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return sorted.count - lo
    }
}

/// The per-draw statistic: τ̂* = (M d*)·(M y) / ‖M d*‖² and b* = (M d*)·(M d_obs) / ‖M d*‖², with
/// `prevAssignedOn` partialled out per draw for short carry-over.
struct PermutationKernel {
    let M: HabitStats.Residualizer
    let y: [Double]
    let rowsIdx: [Int]
    let observed: [Bool]
    let useShort: Bool
    let My: [Double]
    let MdObs: [Double]

    init(M: HabitStats.Residualizer, y: [Double], rowsIdx: [Int], observed: [Bool], useShort: Bool) {
        self.M = M
        self.y = y
        self.rowsIdx = rowsIdx
        self.observed = observed
        self.useShort = useShort
        self.My = M.apply(y)
        var d = [Double](repeating: 0, count: rowsIdx.count)
        for (k, i) in rowsIdx.enumerated() where observed[i] { d[k] = 1 }
        self.MdObs = M.apply(d)
    }

    /// Nil when the assignment vector has the wrong length.
    func statistic(_ assign: [Bool]) -> (a: Double, b: Double, degenerate: Bool)? {
        let n = rowsIdx.count
        guard assign.count == observed.count else { return nil }
        var d = [Double](repeating: 0, count: n)
        for k in 0..<n where assign[rowsIdx[k]] { d[k] = 1 }
        var md = M.apply(d)
        var my = My
        var mdObs = MdObs
        if useShort {
            var prev = [Double](repeating: 0, count: n)
            for k in 0..<n {
                let i = rowsIdx[k]
                if i > 0 && assign[i - 1] { prev[k] = 1 }
            }
            let rp = M.apply(prev)
            var rpp = 0.0
            for k in 0..<n { rpp += rp[k] * rp[k] }
            if rpp > 1e-9 {
                var c1 = 0.0, c2 = 0.0, c3 = 0.0
                for k in 0..<n {
                    c1 += rp[k] * md[k]
                    c2 += rp[k] * my[k]
                    c3 += rp[k] * mdObs[k]
                }
                c1 /= rpp
                c2 /= rpp
                c3 /= rpp
                for k in 0..<n {
                    md[k] -= rp[k] * c1
                    my[k] -= rp[k] * c2
                    mdObs[k] -= rp[k] * c3
                }
            }
        }
        var den = 0.0, numA = 0.0, numB = 0.0
        for k in 0..<n {
            den += md[k] * md[k]
            numA += md[k] * my[k]
            numB += md[k] * mdObs[k]
        }
        guard den > 1e-8 else { return (a: 0, b: 0, degenerate: true) }
        return (a: numA / den, b: numB / den, degenerate: false)
    }
}
