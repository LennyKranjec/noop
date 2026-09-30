import Foundation

// ProjectionMetric.swift — WHICH figures "Look ahead" projects and the Goals screen can target
// (DESIGN_V2 coordinator decisions 13 and 14), and the few facts the math needs about each one.
//
// A metric is an id (kind + optional qualifier: the Level part, or the lift's name) plus:
//   * how a week of daily readings becomes ONE weekly value (median for physiology, sum for behaviour
//     totals, mean for steps/day) and how many readings a week needs before it has a value;
//   * whether the quantity is non-negative BY DEFINITION (minutes, steps, kilograms, milliseconds).
//     That is arithmetic, not physiology: the lower band edge of a count is never drawn below 0. The
//     Level and its parts are NOT bounded in any way (decision 9);
//   * a measurement error the estimate itself carries (VO₂max: ±5 ml/kg/min, the SEE of the session
//     estimate — HEALTH_V2 §1.2), drawn as an outer band;
//   * which training dose the plan scenario moves it with (aerobic minutes, strength sessions, or none).
//
// No physiological ceiling or floor lives here or anywhere in the projection code.
//
// Pure, Codable, `yyyy-MM-dd` strings only. Swift-only engine; a Kotlin twin can follow unchanged.

public enum ProjectionMetricKind: String, Codable, CaseIterable, Sendable {
    case level
    case levelPart
    case restingHR
    case hrv
    case vo2max
    case aerobicMinutes
    case steps
    case e1rm
    case sleepRegularity
    case meditationMinutes
}

/// How the days of one week become the week's single value.
public enum WeeklyAggregation: String, Codable, Sendable {
    /// Median of the week's daily readings (physiology: robust to one odd night).
    case median
    /// Sum of the week's daily values (behaviour totals: minutes per week).
    case sum
    /// Mean of the week's daily values (steps per day, over the reliable days only).
    case mean
}

/// The training dose the plan scenario moves a metric with.
public enum ProjectionDose: String, Codable, Sendable {
    /// WHO-equivalent aerobic minutes per week (`SessionIntensity` mvpaEq).
    case aerobic
    /// Strength sessions per week.
    case strength
}

public struct ProjectionMetricID: Codable, Hashable, Sendable, Identifiable {
    public let kind: ProjectionMetricKind
    /// The Level part's raw value, or the lift's name; nil for every other kind.
    public let qualifier: String?

    public init(kind: ProjectionMetricKind, qualifier: String? = nil) {
        self.kind = kind
        self.qualifier = qualifier
    }

    public static let level = ProjectionMetricID(kind: .level)
    public static let restingHR = ProjectionMetricID(kind: .restingHR)
    public static let hrv = ProjectionMetricID(kind: .hrv)
    public static let vo2max = ProjectionMetricID(kind: .vo2max)
    public static let aerobicMinutes = ProjectionMetricID(kind: .aerobicMinutes)
    public static let steps = ProjectionMetricID(kind: .steps)
    public static let sleepRegularity = ProjectionMetricID(kind: .sleepRegularity)
    public static let meditationMinutes = ProjectionMetricID(kind: .meditationMinutes)
    public static func part(_ p: LevelPart) -> ProjectionMetricID {
        ProjectionMetricID(kind: .levelPart, qualifier: p.rawValue)
    }
    public static func e1rm(lift: String) -> ProjectionMetricID {
        ProjectionMetricID(kind: .e1rm, qualifier: lift)
    }

    /// Stable string key (storage, dictionary keys, SwiftUI identity).
    public var id: String {
        if let q = qualifier { return kind.rawValue + ":" + q }
        return kind.rawValue
    }

    /// Parse a stable key (`id`) back into a metric; nil for an unknown kind.
    public init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let first = parts.first, let kind = ProjectionMetricKind(rawValue: first) else { return nil }
        self.init(kind: kind, qualifier: parts.count > 1 ? parts[1] : nil)
    }

    public var levelPart: LevelPart? {
        guard kind == .levelPart, let q = qualifier else { return nil }
        return LevelPart(rawValue: q)
    }

    /// English display name (the app localises in its integration pass).
    public var displayName: String {
        switch kind {
        case .level: return "Level"
        case .levelPart:
            let name = qualifier ?? "part"
            return "Level · " + name.prefix(1).uppercased() + String(name.dropFirst())
        case .restingHR: return "Resting heart rate"
        case .hrv: return "HRV"
        case .vo2max: return "VO₂max (estimate)"
        case .aerobicMinutes: return "Aerobic minutes / week"
        case .steps: return "Steps / day"
        case .e1rm: return "Estimated 1RM · " + (qualifier ?? "lift")
        case .sleepRegularity: return "Wake-time spread"
        case .meditationMinutes: return "Meditation minutes / week"
        }
    }

    public var unit: String {
        switch kind {
        case .level, .levelPart: return ""
        case .restingHR: return "bpm"
        case .hrv: return "ms"
        case .vo2max: return "ml/kg/min"
        case .aerobicMinutes, .meditationMinutes: return "min"
        case .steps: return "steps"
        case .e1rm: return "kg"
        case .sleepRegularity: return "min SD"
        }
    }

    /// Decimals shown.
    public var decimals: Int {
        switch kind {
        case .vo2max, .e1rm: return 1
        default: return 0
        }
    }

    /// Lower is the healthier direction (for coach wording only; a goal's direction is its own).
    public var lowerIsBetter: Bool { kind == .restingHR || kind == .sleepRegularity }

    /// Non-negative by definition (arithmetic, not physiology). The Level and its parts: never bounded.
    public var nonNegative: Bool {
        switch kind {
        case .level, .levelPart: return false
        case .restingHR, .hrv, .vo2max, .aerobicMinutes, .steps, .e1rm, .sleepRegularity, .meditationMinutes:
            return true
        }
    }

    public var aggregation: WeeklyAggregation {
        switch kind {
        case .aerobicMinutes, .meditationMinutes: return .sum
        case .steps: return .mean
        default: return .median
        }
    }

    /// Daily readings a week needs before it has a weekly value. Sums need a mostly-observed week
    /// (otherwise "no session" cannot be told from "not worn"); per-session estimates need one.
    public var minReadingsPerWeek: Int {
        switch kind {
        case .level, .levelPart, .restingHR, .hrv: return 3
        case .vo2max, .e1rm: return 1
        case .aerobicMinutes, .meditationMinutes: return 5
        case .steps: return 4
        case .sleepRegularity: return 1   // already a weekly figure (SD of wake times over ≥ 4 nights)
        }
    }

    /// The estimate's own error, drawn as an outer band (VO₂max session estimate SEE ≈ 5 ml/kg/min).
    public var measurementError: Double? { kind == .vo2max ? 5 : nil }

    /// The dose the plan scenario moves this metric with (nil: the plan does not move it measurably).
    public var dose: ProjectionDose? {
        switch kind {
        case .restingHR, .hrv, .vo2max, .level: return .aerobic
        case .levelPart:
            switch levelPart {
            case .some(.heart), .some(.lungs): return .aerobic
            case .some(.muscle): return .strength
            default: return nil
            }
        case .e1rm: return .strength
        case .aerobicMinutes, .steps, .sleepRegularity, .meditationMinutes: return nil
        }
    }

    /// Format a value of this metric (fixed decimals; steps grouped with ",").
    public func format(_ v: Double) -> String {
        if kind == .steps {
            let r = Int(v.rounded())
            let digits = String(abs(r))
            var out = ""
            for (i, ch) in digits.reversed().enumerated() {
                if i > 0 && i % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            return (r < 0 ? "\u{2212}" : "") + String(out.reversed())
        }
        let s = String(format: "%.\(decimals)f", abs(v))
        return (v < 0 && s.contains(where: { $0 != "0" && $0 != "." }) ? "\u{2212}" : "") + s
    }

    /// Value with its unit, e.g. "52 bpm".
    public func formatWithUnit(_ v: Double) -> String {
        unit.isEmpty ? format(v) : format(v) + " " + unit
    }

    /// Signed rate per week, e.g. "+0.4 ml/kg/min/wk" or "−1 bpm/wk" (true minus).
    /// Rates are small, so they carry one decimal more than the value (steps: whole steps).
    public func formatRate(_ perWeek: Double) -> String {
        let d = kind == .steps ? 0 : decimals + 1
        let mag = String(format: "%.\(d)f", abs(perWeek))
        let sign: String
        if mag.allSatisfy({ $0 == "0" || $0 == "." }) {
            sign = "±"
        } else {
            sign = perWeek > 0 ? "+" : "\u{2212}"
        }
        return sign + mag + (unit.isEmpty ? "" : " " + unit) + "/wk"
    }

    /// The metrics Look ahead shows, in order (lifts are appended by the caller).
    public static var lookAheadOrder: [ProjectionMetricID] {
        [.level] + LevelPart.allCases.map { ProjectionMetricID.part($0) }
            + [.restingHR, .hrv, .vo2max, .aerobicMinutes, .steps]
    }

    /// Every kind a goal may target (lifts and parts are chosen with their qualifier).
    public static var goalKinds: [ProjectionMetricKind] { ProjectionMetricKind.allCases }
}
