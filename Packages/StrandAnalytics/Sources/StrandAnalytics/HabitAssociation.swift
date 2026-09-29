import Foundation

// HabitAssociation.swift — what the wearer's own data suggests about each habit. Observational only.
//
// HEALTH_V2 §S1-A.3. For each BEHAVIOUR habit and its fixed primary outcome, over the last 90 nights:
//
//   rows   nights where the habit is observed (yes or no), the outcome is present, and the previous day's
//          Effort is present. A night without an observation is not a row: "not logged" is never "no".
//   gate   ≥ 8 yes AND ≥ 8 no rows, otherwise `notEnoughData`.
//   model  y = β0 + β·yes + γ1·effortPrevDay + γ2·weekend + γ3·dayIndex, OLS. HRV as ln RMSSD (reported %).
//   SE     Newey–West (HAC), Bartlett kernel, lag L = 3 CALENDAR days (⌊4(n/100)^{2/9}⌋ = 3 at n ≈ 90):
//          nights further apart than L get weight 0. The data are not randomised, so there is no
//          assignment to permute; HAC keeps the interval from being too narrow on autocorrelated nights.
//          Small-sample guard: SE = max(NW · √(n/(n−p)), OLS SE) — see `fitOne` for the measured reason.
//          95 % interval with Student-t, df = n − 5.
//   FDR    Benjamini–Hochberg at q = 0.10 across every primary test in the run. Secondary outcomes never
//          enter BH and never get a label: they are "exploratory".
//   label  possibleLink (BH-significant AND |β| ≥ MCID) · smallOrNone (the whole interval within ±MCID) ·
//          unclear (everything else with enough data) · notEnoughData (the gate failed or the design was
//          singular).
//
// Adjusted: prior-day Effort, weekend, drift. NOT adjusted: sleep duration (often a mediator) and other
// habits (reported through co-occurrence instead: a Jaccard overlap of yes-nights > 0.6 is shown as "often
// happens together with X — this data can't separate them"). Copy is always associational.

/// A habit association label.
public enum HabitAssociationLabel: String, Codable, Sendable {
    case possibleLink, smallOrNone, unclear, notEnoughData

    /// Display order: possibleLink → unclear → smallOrNone → notEnoughData.
    public var sortRank: Int {
        switch self {
        case .possibleLink: return 0
        case .unclear: return 1
        case .smallOrNone: return 2
        case .notEnoughData: return 3
        }
    }

    public var title: String {
        switch self {
        case .possibleLink: return "Possible link"
        case .smallOrNone: return "Small or none"
        case .unclear: return "Unclear"
        case .notEnoughData: return "Not enough data"
        }
    }
}

/// An exploratory secondary: estimate and interval, never a label.
public struct HabitAssociationExploratory: Equatable, Codable, Sendable {
    public let outcome: HabitOutcome
    public let estimate: Double?
    public let lower: Double?
    public let upper: Double?
    public let yesCount: Int
    public let noCount: Int
}

/// One habit's primary association.
public struct HabitAssociationRow: Equatable, Codable, Sendable {
    public let habit: HabitId
    public let habitLabel: String
    public let outcome: HabitOutcome
    public let label: HabitAssociationLabel
    public let yesCount: Int
    public let noCount: Int
    /// β in analysis units (HRV: ln ratio). Nil when not estimated.
    public let estimate: Double?
    public let lower: Double?
    public let upper: Double?
    public let mcid: Double?
    public let pValue: Double?
    public let bhSignificant: Bool
    /// Why there is no estimate, when there is none.
    public let absence: HealthAbsence?
    /// Habits whose yes-nights overlap this one's by Jaccard > 0.6.
    public let cooccursWith: [HabitId]
    public let cooccurLabels: [String]
    public let secondaries: [HabitAssociationExploratory]

    /// |β| / MCID, for ordering.
    public var strength: Double {
        guard let e = estimate, let m = mcid, m > 0 else { return 0 }
        return abs(e) / m
    }
}

/// A context or supplement habit: counts only.
public struct HabitCountRow: Equatable, Codable, Sendable {
    public let habit: HabitId
    public let habitLabel: String
    public let kind: HabitKind
    public let yesCount: Int
    public let noCount: Int
    public let cooccurLabels: [String]
}

/// The whole report.
public struct HabitAssociationReport: Equatable, Codable, Sendable {
    public let asOf: String
    public let windowStart: String
    public let windowEnd: String
    /// Behaviour habits, sorted possibleLink → unclear → smallOrNone → notEnoughData.
    public let rows: [HabitAssociationRow]
    /// Context and supplement habits ("Also logged").
    public let alsoLogged: [HabitCountRow]
    /// Observed nights per source (`HabitSource.rawValue`) in the window.
    public let sourceCounts: [String: Int]
}

public enum HabitAssociation {

    public static let windowNights = 90
    public static let minPerGroup = 8
    public static let fdrQ = 0.10
    public static let hacLagDays = 3
    public static let cooccurrenceJaccard = 0.6
    /// Yes-nights a habit needs before its overlap with another is judged.
    public static let cooccurrenceMinYes = 3

    /// The report as of `asOf` (the latest night key considered).
    public static func analyse(inputs: HabitLedgerInputs, asOf: String) -> HabitAssociationReport {
        let windowStart = HabitDay.adding(-(windowNights - 1), to: asOf) ?? asOf
        guard let startEpoch = HabitDay.epochDay(windowStart), let endEpoch = HabitDay.epochDay(asOf) else {
            return HabitAssociationReport(asOf: asOf, windowStart: windowStart, windowEnd: asOf, rows: [],
                                          alsoLogged: [], sourceCounts: [:])
        }
        func inWindow(_ key: String) -> Bool {
            guard let e = HabitDay.epochDay(key) else { return false }
            return e >= startEpoch && e <= endEpoch
        }

        let states = inputs.statesByHabit()
        let defs = inputs.allDefinitions

        // Source counts.
        var sourceCounts: [String: Int] = [:]
        var seenSourceNight = Set<String>()
        for o in inputs.observations where inWindow(o.nightKey) {
            let k = o.source.rawValue + "|" + o.nightKey
            if seenSourceNight.insert(k).inserted { sourceCounts[o.source.rawValue, default: 0] += 1 }
        }

        // Yes-night sets for co-occurrence.
        var yesSets: [HabitId: Set<String>] = [:]
        for (habit, byNight) in states {
            let yes = Set(byNight.filter { $0.value == .yes && inWindow($0.key) }.keys)
            if yes.count >= cooccurrenceMinYes { yesSets[habit] = yes }
        }
        let labelOf: [HabitId: String] = Dictionary(defs.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        func cooccurring(_ habit: HabitId) -> [HabitId] {
            guard let mine = yesSets[habit] else { return [] }
            return yesSets.keys.sorted().filter { other in
                guard other != habit, let theirs = yesSets[other],
                      let j = HabitStats.jaccard(mine, theirs) else { return false }
                return j > cooccurrenceJaccard
            }
        }

        // Primary fits.
        struct Pending {
            let def: HabitDefinition
            let fit: Fit?
            let yes: Int
            let no: Int
            let absence: HealthAbsence?
            let secondaries: [HabitAssociationExploratory]
        }
        var pending: [Pending] = []
        for def in defs where def.kind == .behaviour {
            guard let byNight = states[def.id], byNight.keys.contains(where: inWindow) else { continue }
            let primary = fitOne(byNight: byNight, outcome: def.primaryOutcome, inputs: inputs,
                                 inWindow: inWindow, startEpoch: startEpoch)
            var secondaries: [HabitAssociationExploratory] = []
            for outcome in def.secondaryOutcomes {
                let s = fitOne(byNight: byNight, outcome: outcome, inputs: inputs, inWindow: inWindow,
                               startEpoch: startEpoch)
                secondaries.append(HabitAssociationExploratory(
                    outcome: outcome, estimate: s.fit?.beta, lower: s.fit?.lower, upper: s.fit?.upper,
                    yesCount: s.yes, noCount: s.no))
            }
            pending.append(Pending(def: def, fit: primary.fit, yes: primary.yes, no: primary.no,
                                   absence: primary.absence, secondaries: secondaries))
        }

        // Benjamini–Hochberg over every primary test that produced a p-value.
        let tested = pending.enumerated().compactMap { (i, p) -> (Int, Double)? in
            guard let pv = p.fit?.p else { return nil }
            return (i, pv)
        }
        let rejected = HabitStats.benjaminiHochberg(tested.map { $0.1 }, q: fdrQ)
        var bh = [Bool](repeating: false, count: pending.count)
        for (k, t) in tested.enumerated() { bh[t.0] = rejected[k] }

        var rows: [HabitAssociationRow] = []
        for (i, p) in pending.enumerated() {
            let co = cooccurring(p.def.id)
            let label: HabitAssociationLabel
            if let f = p.fit, let m = f.mcid {
                if bh[i] && abs(f.beta) >= m {
                    label = .possibleLink
                } else if f.lower >= -m && f.upper <= m {
                    label = .smallOrNone
                } else {
                    label = .unclear
                }
            } else {
                label = .notEnoughData
            }
            rows.append(HabitAssociationRow(
                habit: p.def.id, habitLabel: p.def.label, outcome: p.def.primaryOutcome, label: label,
                yesCount: p.yes, noCount: p.no, estimate: p.fit?.beta, lower: p.fit?.lower, upper: p.fit?.upper,
                mcid: p.fit?.mcid, pValue: p.fit?.p, bhSignificant: bh[i], absence: p.absence,
                cooccursWith: co, cooccurLabels: co.map { labelOf[$0] ?? $0.raw }, secondaries: p.secondaries))
        }
        rows.sort { a, b in
            if a.label.sortRank != b.label.sortRank { return a.label.sortRank < b.label.sortRank }
            if a.strength != b.strength { return a.strength > b.strength }
            return a.habit < b.habit
        }

        var also: [HabitCountRow] = []
        for def in defs where def.kind != .behaviour {
            guard let byNight = states[def.id] else { continue }
            let inW = byNight.filter { inWindow($0.key) }
            guard !inW.isEmpty else { continue }
            let yes = inW.values.filter { $0 == .yes }.count
            also.append(HabitCountRow(habit: def.id, habitLabel: def.label, kind: def.kind, yesCount: yes,
                                      noCount: inW.count - yes,
                                      cooccurLabels: cooccurring(def.id).map { labelOf[$0] ?? $0.raw }))
        }
        also.sort { $0.habit < $1.habit }

        return HabitAssociationReport(asOf: asOf, windowStart: windowStart, windowEnd: asOf, rows: rows,
                                      alsoLogged: also, sourceCounts: sourceCounts)
    }

    // MARK: One fit

    struct Fit {
        let beta: Double
        let lower: Double
        let upper: Double
        let p: Double
        let mcid: Double?
        let n: Int
    }

    struct FitOutcome {
        let fit: Fit?
        let yes: Int
        let no: Int
        let absence: HealthAbsence?
    }

    static func fitOne(byNight: [String: ObservationState], outcome: HabitOutcome, inputs: HabitLedgerInputs,
                       inWindow: (String) -> Bool, startEpoch: Int) -> FitOutcome {
        let series = inputs.outcomes[outcome] ?? [:]
        var y: [Double] = []
        var rows: [[Double]] = []
        var positions: [Int] = []
        var yes = 0, no = 0
        for night in byNight.keys.sorted() where inWindow(night) {
            guard let state = byNight[night], let value = series[night], value.isFinite,
                  let evening = HabitDay.adding(-1, to: night), let effort = inputs.effortByDay[evening],
                  effort.isFinite, let e = HabitDay.epochDay(night) else { continue }
            let isYes: Double = state == .yes ? 1 : 0
            if state == .yes { yes += 1 } else { no += 1 }
            y.append(value)
            rows.append([1, isYes, effort, HabitDay.isWeekendEvening(evening) ? 1 : 0, Double(e - startEpoch)])
            positions.append(e - startEpoch)
        }
        guard yes >= minPerGroup, no >= minPerGroup else {
            return FitOutcome(fit: nil, yes: yes, no: no,
                              absence: .tooFewNights(have: Swift.min(yes, no), need: minPerGroup))
        }
        let df = y.count - (rows.first?.count ?? 0)
        guard df >= 3 else {
            return FitOutcome(fit: nil, yes: yes, no: no, absence: .tooFewNights(have: y.count, need: 8))
        }
        guard let fit = HabitStats.ols(y: y, rows: rows),
              let nw = HabitStats.neweyWestSE(fit: fit, rows: rows, positions: positions, index: 1,
                                              lag: hacLagDays),
              let olsSE = HabitStats.olsSE(fit: fit, index: 1) else {
            return FitOutcome(fit: nil, yes: yes, no: no, absence: .cannotSeparate)
        }
        // CONSERVATIVE GUARD. Newey–West is biased DOWN in samples this small, and its t tails are heavier
        // than Student-t: on independent null data (20 habits × 90 nights, 1,000 runs) plain NW gave a
        // false "possible link" in 16.5 % of runs where BH promises ≤ 10 %; with the n/(n−p) factor alone
        // still 14.9 %. Taking the larger of that and the plain OLS standard error brings it to 8.8 % while
        // keeping HAC's protection on autocorrelated nights (AR(1) ρ = 0.5 coverage 92 %).
        let se = Swift.max(nw * (Double(y.count) / Double(df)).squareRoot(), olsSE)
        guard se > 0, se.isFinite else {
            return FitOutcome(fit: nil, yes: yes, no: no, absence: .cannotSeparate)
        }
        let beta = fit.coefficients[1]
        let t = HabitStats.studentTQuantile(0.975, df: df)
        let p = HabitStats.studentTTwoSidedP(beta / se, df: Double(df))
        let mcid = outcome.mcid(baselineSD: HabitStats.sampleSD(y))
        return FitOutcome(fit: Fit(beta: beta, lower: beta - t * se, upper: beta + t * se, p: p, mcid: mcid,
                                   n: y.count),
                          yes: yes, no: no, absence: nil)
    }
}

/// Fixed associational copy. Never "causes", never "improves".
public enum HabitAssociationCopy {

    /// "On nights after X, your night HRV was about 8% lower (range −13% to −3%, 11 vs 64 nights). This is
    /// a pattern, not proof — a trial can test it."
    public static func sentence(_ row: HabitAssociationRow) -> String {
        let what = row.habitLabel.lowercased()
        guard let est = row.estimate, let lo = row.lower, let hi = row.upper else {
            return "\(row.habitLabel): \(row.absence?.line ?? HealthAbsence.dash)"
        }
        let o = row.outcome
        switch row.label {
        case .smallOrNone:
            return "On nights after \(what), your \(o.label) was about the same "
                + "(\(HabitTrialCopy.bare(lo, outcome: o)) to \(HabitTrialCopy.bare(hi, outcome: o)), "
                + "\(row.yesCount) vs \(row.noCount) nights). A pattern, not proof."
        default:
            let v = abs(o.display(est))
            let digits = (o == .nightRhr || o == .sleepEfficiency) ? 1 : 0
            let amount = HabitTrialCopy.format(v, digits: digits) + (o.displayUnit == "%" ? "%" : " " + o.displayUnit)
            let word: String
            switch o {
            case .onsetClockMin: word = est < 0 ? "earlier" : "later"
            case .totalSleepMin: word = est > 0 ? "longer" : "shorter"
            default: word = est > 0 ? "higher" : "lower"
            }
            return "On nights after \(what), your \(o.label) was about \(amount) \(word) "
                + "(range \(HabitTrialCopy.bare(lo, outcome: o)) to \(HabitTrialCopy.bare(hi, outcome: o)), "
                + "\(row.yesCount) vs \(row.noCount) nights). This is a pattern, not proof — a trial can test it."
        }
    }

    /// The co-occurrence note, or nil.
    public static func cooccurrence(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        return "Often happens together with \(labels.joined(separator: ", ").lowercased()) — this data can't separate them."
    }
}
