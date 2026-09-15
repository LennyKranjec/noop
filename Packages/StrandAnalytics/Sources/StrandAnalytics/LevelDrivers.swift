import Foundation

// LevelDrivers.swift — naming the lever.
//
// Swift twin of the Android `com.noop.analytics.LevelDrivers` (the cross-platform parity contract).
//
// The header says which PART has the most room — sleep, heart, lungs, muscle, focus. A glyph alone
// leaves the wearer to guess what to do about it: a heart icon could be asking for more sleep, less
// caffeine or an easier week, and the answer is none of those if the figure actually dragging it down
// is a resting heart rate.
//
// SO THE LEVER NAMES THE METRIC, not the part. "rhr" under the heart, "consistency" under the moon —
// and the moon is what makes "consistency" unambiguous, which is why the word can stay this short.
//
// PICKED BY THE SAME RULE THE PARTS ARE. Within a part, the driver is the sub-metric with the most
// room to 100 AFTER its own share of the part — not the lowest number. Sleep score at 0.8 of the sleep
// term and consistency at 0.2 means a score of 70 is worth more to fix than a consistency of 40, and
// pointing at the smaller number would send them after the smaller prize.
//
// A PART WITH ONE INPUT HAS NO DRIVER TO CHOOSE. Muscle is volume load and nothing else, so it names
// itself; there is no second figure it could have been.

/// The named metric behind a part's score, as the header's lever labels it.
public enum LevelDriver: String, CaseIterable, Sendable, Codable {
    case sleepScore
    case sleepConsistency
    case hrv
    case rhr
    case vo2max
    case respRate
    case muscleVolume
    case stress
    case meditation

    public var part: LevelPart {
        switch self {
        case .sleepScore, .sleepConsistency: return .sleep
        case .hrv, .rhr: return .heart
        case .vo2max, .respRate: return .lungs
        case .muscleVolume: return .muscle
        case .stress, .meditation: return .focus
        }
    }
}

public enum LevelDrivers {

    /// Sleep's own split, from `LevelEngine.sleep`.
    private static let sleepScoreShare: Double = 0.8
    private static let sleepConsistencyShare: Double = 0.2

    /// Lungs' own split, from `LevelEngine.lungs`.
    private static let vo2Share: Double = 0.6
    private static let respShare: Double = 0.4

    /// Which metric inside `part` has the most room, or nil when nothing measured it.
    ///
    /// Computed from the same inputs and the same frozen baselines the score itself came from, so the
    /// label can never name a metric the score was not actually built on.
    public static func driver(
        for part: LevelPart,
        inputs: LevelInputs,
        baselines: [LevelMetric: Baseline]
    ) -> LevelDriver? {
        switch part {
        case .sleep:
            let s = Array(inputs.sleepScores.suffix(3))
            let c = Array(inputs.consistencyScores.suffix(3))
            let score = s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
            let consistency = c.isEmpty ? nil : c.reduce(0, +) / Double(c.count)
            return pick([
                (.sleepScore, score.map { (100 - $0) * sleepScoreShare }),
                (.sleepConsistency, consistency.map { (100 - $0) * sleepConsistencyShare }),
            ])

        case .heart:
            // The two enter the heart term as `z(hrv) − z(rhr)`, in equal and opposite measure, so
            // their room is compared on the same 0–100 scale each z maps to.
            let hrv = inputs.hrv.flatMap { v in baselines[.hrv].map { LevelEngine.toScale(LevelEngine.z(v, $0)) } }
            let rhr = inputs.rhr.flatMap { v in baselines[.rhr].map { 100 - LevelEngine.toScale(LevelEngine.z(v, $0)) } }
            return pick([
                (.hrv, hrv.map { 100 - $0 }),
                (.rhr, rhr.map { 100 - $0 }),
            ])

        case .lungs:
            let vo2 = inputs.vo2max.flatMap { v in baselines[.vo2max].map { LevelEngine.toScale(LevelEngine.z(v, $0)) } }
            let resp = inputs.respRate.flatMap { v in baselines[.respRate].map { 100 - LevelEngine.toScale(LevelEngine.z(v, $0)) } }
            return pick([
                (.vo2max, vo2.map { (100 - $0) * vo2Share }),
                (.respRate, resp.map { (100 - $0) * respShare }),
            ])

        case .muscle:
            // One input, so there is nothing to choose between. Nil when it has no sessions at all,
            // because a lever is only ever shown for a part that scored.
            return inputs.muscleSessions.isEmpty ? nil : .muscleVolume

        case .focus:
            let s = Array(inputs.stressScores.suffix(3))
            guard !s.isEmpty else { return nil }
            let stress = s.reduce(0, +) / Double(s.count)
            // Meditation is a MULTIPLIER on the calm score (0.5 with none, 1.01 with three days), so
            // its room is what the remaining days would add — not a distance to 100 like the others.
            let days = Swift.min(Swift.max(inputs.meditationDays, 0), 3)
            let calm = 100 - stress
            let bonusNow = 0.5 + LevelEngine.meditationBonusPerDay * Double(days)
            let bonusFull = 0.5 + LevelEngine.meditationBonusPerDay * 3
            return pick([
                (.stress, (100 - calm) * bonusNow),
                (.meditation, calm * (bonusFull - bonusNow)),
            ])
        }
    }

    /// The driver with the most room. Ties go to the first named, which is the larger share.
    private static func pick(_ options: [(LevelDriver, Double?)]) -> LevelDriver? {
        var best: (LevelDriver, Double)?
        for (driver, room) in options {
            guard let room else { continue }
            if let current = best, room <= current.1 { continue }
            best = (driver, room)
        }
        return best?.0
    }
}
