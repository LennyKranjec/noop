import Foundation
import StrandImport

// StrengthProgressionCopy.swift — the words and the numbers for the Progression section.
//
// SEPARATE FROM THE MODEL ON PURPOSE. `StrengthProgression` ships no string catalog and must not: it is a
// pure package type, and a sentence assembled there would reach a German wearer in English. It returns
// structured facts — a step, a weight, a rep count, a rep range, an increment — and this file is the one
// place those become a sentence, once, for every surface that shows one.
//
// SEPARATE FROM THE VIEWS TOO, because the card and the detail view have to say the same thing. The card's
// one-liner and the detail view's reasoning list are built from the same fields here, so the card cannot
// claim 77,5 kg while the detail view explains 80.
//
// WEIGHTS ARE FORMATTED IN THE WEARER'S LOCALE. A German wearer's machine is labelled 77,5 kg, and
// "77.5 kg" reads as a different number to them. `kg` itself is not converted to pounds: every stored
// weight is kilograms because every export NOOP reads is (or was converted at parse), and a pound display
// would need a conversion on the way out that the suggestion's increment arithmetic — which is in the
// wearer's own observed kilogram steps — cannot survive without inventing a step they never used.
//
// NO `+` INSIDE A LOCALIZED LITERAL, anywhere in this file. `String(localized:)` takes a
// `String.LocalizationValue`, and `"a" + "b"` is a `String` — the concatenation either fails to compile or,
// in a `Text(…)`, silently selects the NON-localizing `StringProtocol` overload and ships English to every
// language (the #540 defect). Long literals stay on one line instead.

enum StrengthProgressionCopy {

    /// A weight, in the wearer's locale, with at most one decimal and no trailing ",0".
    ///
    /// 77.5 → "77,5" in German, "77.5" in English; 75.0 → "75" in both. Machine steps are halves and
    /// quarters of a kilo at worst, so one decimal is the whole precision the figure has.
    static func kg(_ value: Double) -> String {
        weightFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private static let weightFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()

    /// A weight with its unit. NOT localized: "kg" is the SI symbol and is written "kg" in every language
    /// this app ships, so a catalog key of "%@ kg" would be four identical translations of nothing.
    static func kgUnit(_ value: Double) -> String { "\(kg(value)) kg" }

    /// A signed delta, for a trend readout: "+3,1 kg" / "−1,4 kg".
    ///
    /// A REAL MINUS SIGN, not a hyphen, so it matches the height of the digits beside it.
    static func signedKg(_ value: Double) -> String {
        "\(value < 0 ? "\u{2212}" : "+")\(kg(abs(value))) kg"
    }

    /// A date, short, in the wearer's locale — for a session row and a "best ever" line.
    static func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    // MARK: - The suggestion

    /// The one-line suggestion, as the card and the detail view both show it.
    ///
    /// "Try 77,5 kg × 8". Deliberately an INSTRUCTION with the numbers in it and nothing else: the
    /// reasoning belongs in `reasons(for:)`, where there is room for it, and a row in a list has to be
    /// readable at a glance.
    static func suggestion(_ s: StrengthProgression.Suggestion) -> String {
        String(localized: "Try \(kgUnit(s.weightKg)) × \(s.reps)")
    }

    /// Why that suggestion, in the order it was decided. Shown as a list in the detail view.
    ///
    /// EVERY LINE IS A FACT FROM THE MODEL, not a restatement of the rule in general terms. A wearer
    /// reading "add reps before weight" learns the rule; reading "you did 75 kg × 9 last time, and your
    /// recent sets have run 8–12 reps" learns why the app said what it said to them specifically.
    static func reasons(for exercise: StrengthProgression.Exercise) -> [String] {
        guard let s = exercise.suggestion else { return [] }
        var out = [
            String(localized: "Last time: \(kgUnit(s.fromWeightKg)) × \(s.fromReps)."),
            String(localized: "Your recent sets run \(s.repRangeLow)–\(s.repRangeHigh) reps."),
        ]
        switch s.step {
        case .addReps:
            out.append(String(localized: "Reps before weight: one more rep at a load you have already lifted is the smaller ask."))
        case .addWeight:
            if let increment = s.incrementKg {
                out.append(String(localized: "Top of that range reached, so one step up — \(kgUnit(increment)), the smallest step your own history for this lift shows — and back to \(s.repRangeLow) reps."))
            }
        }
        if let stall = exercise.stall { out.append(stalledLine(stall)) }
        return out
    }

    /// The stall marker's own line: what has not moved, and for how long.
    static func stalledLine(_ stall: StrengthProgression.Stall) -> String {
        guard let weight = stall.stuckAtKg else {
            return String(localized: "\(stall.sessions) sessions with no new best, over \(stall.days) days.")
        }
        return String(localized: "\(stall.sessions) sessions at \(kgUnit(weight)) with no new best, over \(stall.days) days.")
    }

    // MARK: - Abstention

    /// Why an exercise shows no figures. Never a number, because there is not one to show.
    static func abstention(_ reason: StrengthProgression.Abstention) -> String {
        switch reason {
        case .tooFewSessions(let have, let need):
            return String(localized: "Not enough sessions yet — \(have) of \(need).")
        case .noUsableSets:
            return String(localized: "No set in this exercise carried both a weight and a rep count.")
        }
    }

    /// What was left out of the estimates, when something was. Empty when nothing was.
    ///
    /// SAID OUT LOUD rather than silently narrowing the input. A wearer looking at a hyperextension with no
    /// figure needs to know the reason is that their log records the ADDED weight and not the total, which
    /// is a fact about their export and not a fault in their training.
    static func exclusions(_ exercise: StrengthProgression.Exercise) -> [String] {
        var out: [String] = []
        if exercise.excludedBodyweightSets > 0 {
            out.append(String(localized: "\(exercise.excludedBodyweightSets) sets left out: the log records weight ADDED to bodyweight, not the total load, so no one-rep max can be estimated from them."))
        }
        if exercise.excludedOutOfRangeSets > 0 {
            out.append(String(localized: "\(exercise.excludedOutOfRangeSets) sets left out: above \(StrengthProgression.maxReps) reps a one-rep-max estimate is extrapolation, not arithmetic."))
        }
        return out
    }

    // MARK: - Trend

    /// A trend readout: "+3,1 kg / 8 weeks". Built only for a window the exercise has a fit for.
    static func trend(_ t: StrengthProgression.Trend) -> String {
        String(localized: "\(signedKg(t.deltaKg)) / \(t.windowWeeks) weeks")
    }

    /// The SF Symbol for a direction. A glyph on screen; `directionLabel` is what VoiceOver reads.
    static func arrow(_ direction: StrengthProgression.Direction) -> String {
        switch direction {
        case .up: return "arrow.up.right"
        case .flat: return "arrow.right"
        case .down: return "arrow.down.right"
        }
    }

    static func directionLabel(_ direction: StrengthProgression.Direction) -> String {
        switch direction {
        case .up: return String(localized: "rising")
        case .flat: return String(localized: "flat")
        case .down: return String(localized: "falling")
        }
    }
}
