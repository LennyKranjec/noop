import Foundation

// GoalCoachSummary.swift — the coach's compact, DATED goals block (DESIGN_V2 decision 14).
//
// The coach receives the active goals (target, date, current value with its week, required weekly rate,
// verdict and the projected range at the date) so it can plan toward them and say plainly when one is too
// ambitious — including what would make it realistic. The block is registered with the coach context
// budget by the Strand/AI owner in two forms: `block(…, maxChars:)` (full) and `shortBlock(…, maxChars:)`
// (one line per goal). Both cut at WHOLE LINES and say how many goals were left out, so a trimmed block is
// never read as a complete one.
//
// Pure. Swift-only.

public enum GoalCoachSummary {

    public static let header = "GOALS"
    /// Default caps (characters). ~150 tokens full, ~75 short at 4 chars/token.
    public static let defaultMaxChars = 600
    public static let defaultShortMaxChars = 300

    /// The rules the coach must follow when it uses the block (part of the block, first line after the header).
    public static let rule = "Plan toward these as fast as is realistic. Say plainly when a goal is too ambitious "
        + "and what would make it realistic (the realistic date or value given). Goals never change measured "
        + "values; a passed date is reviewed, never penalised. These are projections, not promises."

    /// One full line per goal.
    public static func line(_ a: GoalAssessment) -> String {
        let m = a.goal.metric
        var s = "- \(m.displayName): target \(m.formatWithUnit(a.goal.target)) by \(a.goal.targetDate)"
        if let c = a.current {
            s += "; now \(m.formatWithUnit(c))" + (a.currentWeek.map { " (week of \($0))" } ?? "")
        } else {
            s += "; no current reading"
        }
        if let r = a.requiredPerWeek { s += "; needs \(m.formatRate(r))" }
        if let b = a.projectedAtDate { s += "; trend band at date \(m.format(b.low))–\(m.format(b.high))" }
        s += "; verdict: \(a.verdict.title.lowercased())"
        if a.verdict == .unrealistic {
            if let d = a.realisticDate { s += " (realistic date \(d))" }
            if let v = a.realisticValue { s += " (realistic by then: \(m.formatWithUnit(v)))" }
        }
        return s
    }

    /// One short line per goal.
    public static func shortLine(_ a: GoalAssessment) -> String {
        let m = a.goal.metric
        return "- \(m.displayName) \(m.formatWithUnit(a.goal.target)) by \(a.goal.targetDate): "
            + a.verdict.title.lowercased()
    }

    /// The full block, ≤ `maxChars`. Empty when there are no active goals.
    public static func block(_ assessments: [GoalAssessment], asOf: String, maxChars: Int = defaultMaxChars) -> String {
        assemble(assessments, asOf: asOf, maxChars: maxChars, includeRule: true, line: { GoalCoachSummary.line($0) })
    }

    /// The short block, ≤ `maxChars`.
    public static func shortBlock(_ assessments: [GoalAssessment], asOf: String,
                                  maxChars: Int = defaultShortMaxChars) -> String {
        assemble(assessments, asOf: asOf, maxChars: maxChars, includeRule: false, line: { GoalCoachSummary.shortLine($0) })
    }

    static func assemble(_ assessments: [GoalAssessment], asOf: String, maxChars: Int, includeRule: Bool,
                         line: (GoalAssessment) -> String) -> String {
        let active = assessments.filter { !$0.goal.archived }
            .sorted { ($0.goal.targetDate, $0.goal.id) < ($1.goal.targetDate, $1.goal.id) }
        guard !active.isEmpty else { return "" }
        var out = "\(header) (as of \(asOf); \(active.count) active)"
        guard out.count <= maxChars else { return "" }
        if includeRule, out.count + 1 + rule.count <= maxChars { out += "\n" + rule }
        var shown = 0
        for a in active {
            let l = line(a)
            let remaining = active.count - shown - 1
            // Reserve room for the "left out" note unless this is the last goal.
            let note = remaining > 0 ? "\n(+\(remaining) more goals not shown)" : ""
            if out.count + 1 + l.count + note.count <= maxChars {
                out += "\n" + l
                shown += 1
            } else {
                break
            }
        }
        if shown < active.count {
            let note = "\n(+\(active.count - shown) more goals not shown)"
            if out.count + note.count <= maxChars { out += note }
        }
        return out
    }
}
