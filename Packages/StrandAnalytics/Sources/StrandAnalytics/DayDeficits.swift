import Foundation

// DayDeficits.swift — what today is short of.
//
// The State card's content: the handful of things a day is measurably behind on, named in the order
// they are worth acting on. Hydration, steps, protein, stress, sleep debt — each one a figure the app
// already holds, each one still fixable before the day ends.
//
// ONLY WHAT IS MEASURED. A deficit needs a reading to be short OF: a day with no hydration log has no
// hydration deficit, it has no hydration DATA, and the two must never render the same. Every rule here
// returns nothing when its input is absent, which is why a fresh install shows an empty card rather
// than a list of failures the wearer never had a chance to avoid.
//
// ONLY WHAT IS STILL ACTIONABLE. Sleep is the exception that proves it: last night cannot be changed,
// so a short night appears only as debt — a thing tonight can answer — and never as "you slept badly",
// which is a verdict with no move attached.
//
// SEVERITY ORDERS THE LIST, not the order the rules are written in. A wearer reads the first two lines
// and acts on the first one, so the first one has to be the one worth acting on.

/// One thing today is short of.
public struct DayDeficit: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case hydration
        case steps
        case protein
        case stress
        case sleepDebt
        case training
    }

    public let kind: Kind
    /// What to say. One line, with the figure in it — "1.1 of 2.6 L" is actionable, "drink more" is not.
    public let text: String
    /// 0–1, how far behind this is. Orders the list; never shown as a number.
    public let severity: Double

    public var id: String { kind.rawValue }

    public init(kind: Kind, text: String, severity: Double) {
        self.kind = kind
        self.text = text
        self.severity = severity
    }
}

public enum DayDeficits {

    /// Below this share of a target, a thing counts as short. Above it the day is close enough that
    /// naming it would be nagging.
    public static let shortOf = 0.8

    /// The step floor a day is judged against. Low on purpose: this is a floor, not a goal.
    public static let stepFloor = 6_000

    /// Grams of protein per kilogram of body mass, the low end of the range every guideline agrees on.
    /// Used only to decide whether the day is SHORT — never printed as a prescription.
    public static let proteinPerKg = 1.6

    /// Minutes of non-activity high stress past which the day is worth naming.
    public static let stressBudgetMin: Double = 4 * 60

    /// Sleep debt past which tonight is worth planning.
    public static let debtLimitMin: Double = 60

    /// Days without a counted session past which the week is worth naming.
    public static let untrainedDays = 3

    /// Everything today is measurably short of, worst first.
    ///
    /// Every parameter is optional and absent means UNMEASURED, not zero — see the note at the top.
    public static func evaluate(
        hydrationML: Double?,
        hydrationGoalML: Int?,
        steps: Int?,
        proteinG: Double?,
        bodyMassKg: Double?,
        stressMinutes: Double?,
        sleepDebtMin: Double?,
        daysSinceTraining: Int?
    ) -> [DayDeficit] {
        var out: [DayDeficit] = []

        if let hydrationML, let goal = hydrationGoalML, goal > 0 {
            let share = hydrationML / Double(goal)
            if share < shortOf {
                out.append(DayDeficit(
                    kind: .hydration,
                    text: String(format: "Water: %.1f of %.1f L", hydrationML / 1000, Double(goal) / 1000),
                    severity: 1 - share))
            }
        }

        if let steps, steps < stepFloor {
            let share = Double(steps) / Double(stepFloor)
            out.append(DayDeficit(
                kind: .steps,
                text: "Steps: \(steps) of \(stepFloor)",
                severity: 1 - share))
        }

        // The protein rule needs BOTH the intake and the body mass. Without the mass there is no target
        // to be short of, and a fixed 100 g would be a prescription aimed at nobody in particular.
        if let proteinG, let bodyMassKg, bodyMassKg > 0 {
            let target = bodyMassKg * proteinPerKg
            let share = proteinG / target
            if share < shortOf {
                out.append(DayDeficit(
                    kind: .protein,
                    text: "Protein: \(Int(proteinG.rounded())) of \(Int(target.rounded())) g",
                    severity: 1 - share))
            }
        }

        if let stressMinutes, stressMinutes > stressBudgetMin {
            let over = (stressMinutes - stressBudgetMin) / stressBudgetMin
            out.append(DayDeficit(
                kind: .stress,
                text: "Stress: \(Int((stressMinutes / 60).rounded())) h of non-exercise load today",
                severity: Swift.min(over, 1)))
        }

        if let sleepDebtMin, sleepDebtMin > debtLimitMin {
            out.append(DayDeficit(
                kind: .sleepDebt,
                text: String(format: "Sleep debt: %.1f h — tonight is the answer", sleepDebtMin / 60),
                severity: Swift.min(sleepDebtMin / (debtLimitMin * 6), 1)))
        }

        if let daysSinceTraining, daysSinceTraining >= untrainedDays {
            out.append(DayDeficit(
                kind: .training,
                text: "No counted session in \(daysSinceTraining) days",
                severity: Swift.min(Double(daysSinceTraining) / 7, 1)))
        }

        // Worst first, and STABLY: two deficits at the same severity keep the order the rules are
        // written in, so the card does not reshuffle between two renders of the same day.
        return out.enumerated()
            .sorted { lhs, rhs in
                lhs.element.severity == rhs.element.severity
                    ? lhs.offset < rhs.offset
                    : lhs.element.severity > rhs.element.severity
            }
            .map(\.element)
    }

    /// The deficits as one line for the coach's grounding block.
    ///
    /// Given to the model already RANKED and already worded, so its job is what to do about them rather
    /// than which of them matters — a model asked to rank six figures will rank them by how interesting
    /// they are to talk about.
    public static func promptLine(_ deficits: [DayDeficit]) -> String? {
        guard !deficits.isEmpty else { return nil }
        return "TODAY IS SHORT OF (worst first): "
            + deficits.map(\.text).joined(separator: "; ")
    }
}
