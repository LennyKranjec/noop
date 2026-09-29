import Foundation

// HabitTrialVerdict.swift — exactly three verdicts, decided mechanically from the registered rule.
//
// HEALTH_V2 §S1-B.6. In the pre-registered BENEFICIAL direction, with the frozen MCID:
//
//   * Helped — the 95 % interval excludes zero on the beneficial side AND the point estimate is at least
//     the MCID.
//   * No meaningful effect — the whole interval lies below the MCID on the beneficial side (confidently
//     small or absent), or it excludes zero on the HARMFUL side (`pointedOtherWay`). A statistically clear
//     effect smaller than the MCID is deliberately "no meaningful effect", never a small win.
//   * Inconclusive — a gate failed (too few valid days, lopsided missingness, adherence / contamination,
//     illness, stopped early, a singular design), or the interval is too wide to tell a meaningful effect
//     from none.
//
// "No meaningful effect" is as legitimate a result as "Helped", and the copy never implies failure.

/// Why a trial is Inconclusive.
public enum HabitTrialInconclusiveReason: String, Codable, Sendable {
    case tooFewDays
    case missingImbalance
    case adherence
    case illness
    case stoppedEarly
    case imprecise
    case singularDesign

    /// One plain sentence.
    public var text: String {
        switch self {
        case .tooFewDays: return "Too few valid nights to test it."
        case .missingImbalance:
            return "Nights went missing unevenly between the two kinds of days, so no estimate can be trusted."
        case .adherence: return "The plan wasn't followed closely enough to test it."
        case .illness: return "You were likely unwell during part of it."
        case .stoppedEarly: return "Stopped early — a partial trial is never analysed."
        case .imprecise: return "The data can't tell a meaningful effect from none."
        case .singularDesign:
            return "The two kinds of days could not be separated from other factors such as training load."
        }
    }
}

/// The verdict.
public enum HabitTrialVerdict: Equatable, Codable, Sendable {
    case helped
    case noMeaningfulEffect(pointedOtherWay: Bool)
    case inconclusive(HabitTrialInconclusiveReason)

    /// The verdict from a result: the result's own gate, or the interval rule.
    public static func decide(result: HabitTrialResult, registration: HabitTrialRegistration) -> HabitTrialVerdict {
        decide(estimate: result.estimate, lower: result.lower, upper: result.upper,
               direction: registration.direction, mcid: registration.mcid, gate: result.gate)
    }

    /// The rule itself.
    public static func decide(estimate: Double?, lower: Double?, upper: Double?, direction: EffectDirection,
                              mcid: Double, gate: HabitTrialInconclusiveReason?) -> HabitTrialVerdict {
        if let gate { return .inconclusive(gate) }
        guard let est = estimate, let lo = lower, let hi = upper,
              est.isFinite, lo.isFinite, hi.isFinite, lo <= hi, mcid > 0 else {
            return .inconclusive(.imprecise)
        }
        // Into beneficial units: positive = better.
        let s = direction.sign
        let bEst = s * est
        let bLo = s > 0 ? lo : -hi
        let bHi = s > 0 ? hi : -lo
        if bLo > 0 && bEst >= mcid { return .helped }
        if bHi < 0 { return .noMeaningfulEffect(pointedOtherWay: true) }
        if bHi < mcid { return .noMeaningfulEffect(pointedOtherWay: false) }
        return .inconclusive(.imprecise)
    }

    /// The verdict word.
    public var headline: String {
        switch self {
        case .helped: return "Helped"
        case .noMeaningfulEffect: return "No meaningful effect"
        case .inconclusive: return "Inconclusive"
        }
    }
}

/// Fixed copy for verdicts and effects. The coach reports these strings verbatim.
public enum HabitTrialCopy {

    public static let blinding = "Blinding was not possible: you knew which kind of day it was. Body measures like "
        + "HRV, resting heart rate and sleep timing are less exposed to that than how you felt."

    public static let altered = "Trial record altered — no verdict."

    /// A signed estimate in display units ("+4 %", "−12 min", "−1.5 bpm").
    public static func signed(_ value: Double, outcome: HabitOutcome) -> String {
        let v = outcome.display(value)
        let digits = (outcome == .nightRhr || outcome == .sleepEfficiency) ? 1 : 0
        let magnitude = format(abs(v), digits: digits)
        let sign = v > 0 ? "+" : (v < 0 ? "−" : "±")
        let unit = outcome.displayUnit
        if unit.isEmpty { return sign + magnitude }
        return unit == "%" ? "\(sign)\(magnitude)%" : "\(sign)\(magnitude) \(unit)"
    }

    /// "+4% [−1, +9]" style, for coach lines and the effect row.
    public static func estimateWithRange(estimate: Double, lower: Double, upper: Double,
                                         outcome: HabitOutcome) -> String {
        "\(signed(estimate, outcome: outcome)) [\(bare(lower, outcome: outcome)), \(bare(upper, outcome: outcome))]"
    }

    /// How much BETTER, in words ("about 12 min earlier", "about 4% higher").
    public static func better(_ value: Double, outcome: HabitOutcome) -> String {
        let beneficial = value * outcome.betterDirection.sign
        let v = abs(outcome.display(value))
        let digits = (outcome == .nightRhr || outcome == .sleepEfficiency) ? 1 : 0
        let amount = format(v, digits: digits) + (outcome.displayUnit == "%" ? "%" : " " + outcome.displayUnit)
        let word: String
        switch outcome {
        case .onsetClockMin: word = value < 0 ? "earlier" : "later"
        case .totalSleepMin: word = value > 0 ? "more" : "less"
        default: word = value > 0 ? "higher" : "lower"
        }
        return beneficial >= 0 ? "about \(amount) \(word)" : "about \(amount) \(word) (the worse way)"
    }

    /// The verdict's body copy.
    public static func body(verdict: HabitTrialVerdict, habit: String, result: HabitTrialResult) -> String {
        let outcome = result.primaryOutcome.label
        switch verdict {
        case .helped:
            guard let est = result.estimate, let lo = result.lower, let hi = result.upper else { return "" }
            return "Over \(result.lengthDays) days, \(habit.lowercased()) was followed by \(outcome) "
                + "\(better(est, outcome: result.primaryOutcome)) (range \(bare(lo, outcome: result.primaryOutcome)) "
                + "to \(bare(hi, outcome: result.primaryOutcome))). That's big enough to matter and unlikely to be "
                + "chance for you."
        case .noMeaningfulEffect(let other):
            let base = "For you, \(habit.lowercased()) didn't move \(outcome) by a meaningful amount. That's a real "
                + "result — you can drop it without losing anything we can measure."
            return other ? base + " The estimate pointed the other way." : base
        case .inconclusive(let reason):
            var text = reason.text
            if let more = result.moreValidDaysNeeded, more > 0,
               reason == .tooFewDays || reason == .imprecise {
                text += " About \(more) more valid days would be needed."
            }
            if reason == .imprecise, let length = result.recommendedLengthDays, length > result.lengthDays {
                text += " A \(length)-day trial would have a fair chance."
            }
            return text
        }
    }

    static func bare(_ value: Double, outcome: HabitOutcome) -> String {
        let v = outcome.display(value)
        let digits = (outcome == .nightRhr || outcome == .sleepEfficiency) ? 1 : 0
        let magnitude = format(abs(v), digits: digits)
        if v > 0 { return "+" + magnitude }
        if v < 0 { return "−" + magnitude }
        return magnitude
    }

    static func format(_ v: Double, digits: Int) -> String {
        String(format: digits == 0 ? "%.0f" : "%.1f", v)
    }
}
