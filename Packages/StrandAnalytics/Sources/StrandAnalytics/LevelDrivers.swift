import Foundation

// LevelDrivers.swift — naming the lever.
//
// iOS lane; the Android twin is unchanged and names different metrics.
//
// The header says which PART has the most room. The lever names the METRIC inside it — "rhr" under the
// heart, "regularity" under the moon — because a glyph alone leaves the wearer to guess what to do.
//
// PICKED BY THE SAME RULE THE PARTS ARE: the sub-metric with the most room to the wearer's own 100,
// after its share of the part. When every sub-metric is already at or past 100 the lowest-scoring one is
// named, because that is still where the next point is cheapest.

/// The named metric behind a part's score, as the header's lever labels it.
public enum LevelDriver: String, CaseIterable, Sendable, Codable {
    case restorativeSleep
    case sleepHrv
    case sleepRegularity
    case hrv
    case rhr
    case vo2max
    case respRate
    case muscleVolume
    case daytimeCalm
    case meditation

    public var part: LevelPart {
        switch self {
        case .restorativeSleep, .sleepHrv, .sleepRegularity: return .sleep
        case .hrv, .rhr: return .heart
        case .vo2max, .respRate: return .lungs
        case .muscleVolume: return .muscle
        case .daytimeCalm, .meditation: return .focus
        }
    }
}

public enum LevelDrivers {

    /// Which metric inside `part` has the most room, or nil when nothing measured it.
    public static func driver(
        for part: LevelPart,
        inputs: LevelInputs,
        baselines: [LevelMetric: Baseline]
    ) -> LevelDriver? {
        let subs: [(LevelDriver, Double?, Double)]
        switch part {
        case .sleep: subs = LevelEngine.sleepSubScores(inputs, baselines)
        case .heart: subs = LevelEngine.heartSubScores(inputs, baselines)
        case .lungs: subs = LevelEngine.lungsSubScores(inputs, baselines)
        case .muscle: return inputs.muscleSessions.isEmpty ? nil : .muscleVolume
        case .focus: subs = LevelEngine.focusSubScores(inputs, baselines)
        }
        let present = subs.compactMap { s in s.1.map { (driver: s.0, score: $0, share: s.2) } }
        guard !present.isEmpty else { return nil }
        let withRoom = present.map { ($0.driver, Swift.max(0, 100 - $0.score) * $0.share, $0.score) }
        if let best = withRoom.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 }) { return best.0 }
        return withRoom.min(by: { $0.2 < $1.2 })?.0
    }
}
