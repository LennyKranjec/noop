import Foundation

// HabitCoachSummary.swift — the coach's compact, dated view of habits and trials.
//
// HEALTH_V2 §S1-A.6. A fixed layout of at most `maxChars` (900 ≈ 225 tokens), dated, and truncated by
// DROPPING WHOLE LINES FROM THE BOTTOM — never cut mid-line — in this priority:
//   1. the running trial (always), 2. finished trials in the last 90 days (≤ 2), 3. possible links (≤ 3,
//   largest |β|/MCID first), 4. proposals (≤ 2).
// It replaces the raw 7-day journal dump and the `EffectRanker` lines in the coach context, so the net
// context gets smaller. A running trial's line carries day count, adherence and the seal date — never an
// estimate: `HabitTrialProgress` has no field that could hold one.

/// A finished trial as the coach sees it.
public struct HabitCoachFinishedTrial: Equatable, Sendable {
    public let interventionId: String
    /// The day it ended (completed or stopped).
    public let endedOn: String
    public let outcome: HabitOutcome
    public let verdict: HabitTrialVerdict?
    public let estimate: Double?
    public let lower: Double?
    public let upper: Double?

    public init(result: HabitTrialResult, endedOn: String) {
        interventionId = result.interventionId
        self.endedOn = endedOn
        outcome = result.primaryOutcome
        verdict = result.verdict
        estimate = result.estimate
        lower = result.lower
        upper = result.upper
    }
}

/// The trial part of the summary.
public struct HabitCoachTrials: Equatable, Sendable {
    public let running: HabitTrialProgress?
    public let finished: [HabitCoachFinishedTrial]

    public init(running: HabitTrialProgress? = nil, finished: [HabitCoachFinishedTrial] = []) {
        self.running = running
        self.finished = finished
    }
}

public enum HabitCoachSummary {

    public static let defaultMaxChars = 900

    /// What the coach must not advise on while each trial runs.
    public static let trialTopics: [String: String] = [
        "caffeineCutoff14": "afternoon caffeine",
        "screensOff60": "evening screens",
        "bedroom18": "bedroom temperature",
        "walkAfterDinner10": "evening walks",
        "morningDaylight": "morning light",
        "dinner3h": "dinner timing",
        "breathing10": "evening breathing sessions",
        "alcoholFree": "alcohol",
    ]

    public static let rulesLine = "Rules: a possible link is a pattern, never a cause; give no advice on a running "
        + "trial's behaviour; quote trial verdicts exactly."

    /// The block.
    public static func render(report: HabitAssociationReport?, trials: HabitCoachTrials,
                              proposals: [TrialProposal], asOf: String,
                              maxChars: Int = defaultMaxChars) -> String {
        var lines: [String] = []
        if let report {
            lines.append("HABITS (as of \(asOf); nights \(report.windowStart)..\(report.windowEnd); associations, not causes)")
        } else {
            lines.append("HABITS (as of \(asOf); no habit analysis yet)")
        }
        lines.append(rulesLine)

        // 1. Running trial — counts and dates only.
        if let run = trials.running {
            var line = "TRIAL RUNNING \(run.interventionId): day \(run.dayNumber)/\(run.lengthDays)"
            if let a = run.adherence { line += ", adherence \(Int((a * 100).rounded()))%" }
            line += ", results sealed until \(run.sealedUntil)."
            if let topic = trialTopics[run.interventionId] { line += " Do not advise on \(topic)." }
            lines.append(line)
        }

        // 2. Finished trials in the last 90 days, newest first, at most 2.
        let recent = trials.finished
            .filter { t in (HabitDay.days(from: t.endedOn, to: asOf).map { $0 >= 0 && $0 <= 90 }) ?? false }
            .sorted { $0.endedOn > $1.endedOn }
            .prefix(2)
        for t in recent {
            var line = "TRIAL DONE \(t.endedOn) \(t.interventionId) -> \(t.outcome.label): "
            switch t.verdict {
            case .some(.helped), .some(.noMeaningfulEffect):
                line += (t.verdict?.headline ?? "").lowercased()
                if let e = t.estimate, let lo = t.lower, let hi = t.upper {
                    line += " (\(ascii(e, t.outcome, signed: true)) [\(ascii(lo, t.outcome, signed: true)),\(ascii(hi, t.outcome, signed: true))])"
                }
                if case .some(.noMeaningfulEffect(true)) = t.verdict { line += ", pointed the other way" }
                line += "."
            case .some(.inconclusive(let reason)):
                line += "inconclusive (\(reason.rawValue)). No trend may be read into it."
            case .none:
                line += "no verdict (record altered)."
            }
            lines.append(line)
        }

        // 3. Possible links, strongest first, at most 3.
        if let report {
            let links = report.rows.filter { $0.label == .possibleLink }
                .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.habit < $1.habit }
                .prefix(3)
            for row in links {
                guard let e = row.estimate, let lo = row.lower, let hi = row.upper else { continue }
                var line = "- \(row.habitLabel.lowercased()): \(row.outcome.label) \(ascii(e, row.outcome, signed: true)) "
                    + "[\(ascii(lo, row.outcome, signed: true)),\(ascii(hi, row.outcome, signed: true))] "
                    + "(\(row.yesCount) yes / \(row.noCount) no) possible link"
                if let first = row.cooccurLabels.first { line += "; often with \(first.lowercased())" }
                lines.append(line)
            }
        }

        // 4. Proposals, at most 2.
        let props = proposals.prefix(2)
        if !props.isEmpty {
            let items = props.map { "\($0.entryId) (\($0.fromOwnData ? "possible link in your data" : "untested"))" }
            lines.append("CANDIDATE TRIALS: " + items.joined(separator: ", "))
        }

        // Priority truncation: whole lines from the bottom.
        while lines.count > 1 && joinedCount(lines) > maxChars { lines.removeLast() }
        if joinedCount(lines) > maxChars { return "" }
        return lines.joined(separator: "\n")
    }

    private static func joinedCount(_ lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.count } + Swift.max(0, lines.count - 1)
    }

    /// ASCII number for the coach: "+8%", "-21 min", "+1.5 bpm".
    static func ascii(_ value: Double, _ outcome: HabitOutcome, signed: Bool) -> String {
        let v = outcome.display(value)
        let digits = (outcome == .nightRhr || outcome == .sleepEfficiency) ? 1 : 0
        var s = String(format: digits == 0 ? "%.0f" : "%.1f", abs(v))
        if signed { s = (v < 0 ? "-" : "+") + s }
        let unit = outcome.displayUnit
        if unit == "%" { return s + "%" }
        return unit.isEmpty ? s : s + " " + unit
    }
}
