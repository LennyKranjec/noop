import Foundation
import StrandAnalytics

// CoachLevelContext.swift — the level, its parts and the arithmetic behind them, for the coach.
//
// The level is the number the whole app is organised around, and the coach used to be the one voice in
// the app that could not see it. It gave sensible advice about sleep and training with no idea which of
// those the day's level was actually short on, or by how much.
//
// SO IT GETS THE WHOLE THING: today's frozen level, every part's score, weight, contribution and
// headroom, the step penalty, the metric driving each part, and the formula itself — and the instruction
// that raising this number is its primary objective. The formula is written from the engine's own
// constants, so the explanation cannot drift from the calculation it explains.

enum CoachLevelContext {

    static func promptSection() -> String {
        var s = "THE LEVEL — YOUR PRIMARY OBJECTIVE IS TO RAISE THIS SCORE. Every recommendation should "
        s += "say which part of the level it moves and roughly how many points it is worth.\n"

        if let frozen = LevelDayFreeze.stored() {
            let b = frozen.breakdown
            s += String(format: "Level for %@: %.1f / 100 (set at 06:40 and held all day).\n", frozen.day, b.level)
            s += "Parts (score 0-100 · effective weight · points contributed · points still available):\n"
            for c in b.components {
                let name = c.part.rawValue
                let driver = frozen.drivers[c.part].map { " · driven by \($0.rawValue)" } ?? ""
                if let score = c.score {
                    s += String(format: "- %@: %.0f · %.0f%% · %.1f · +%.1f%@\n",
                                name, score, c.effectiveWeight * 100, c.contribution, c.headroom, driver)
                } else {
                    s += "- \(name): not measured (its weight is shared across the other parts)\n"
                }
            }
            s += String(format: "Before steps: %.1f. Step multiplier applied: ×%.3f.\n", b.raw, b.stepPenalty)
            let levers = b.levers().prefix(3).map {
                String(format: "%@ (+%.1f)", $0.part.rawValue, $0.headroom * b.stepPenalty)
            }
            if !levers.isEmpty { s += "Biggest levers today: " + levers.joined(separator: ", ") + ".\n" }
        } else {
            s += "Today's level has not been computed yet.\n"
        }

        s += "HOW IT IS CALCULATED:\n"
        s += "- level = (sum of part score × weight, weights re-shared over the parts that have data) × step multiplier, clamped 0-100.\n"
        s += "- Weights: " + LevelPart.allCases.map { "\($0.rawValue) \(Int(($0.weight * 100).rounded()))%" }
            .joined(separator: ", ") + ".\n"
        s += "- sleep = 0.8 × mean of the last 3 sleep scores + 0.2 × mean of the last 3 sleep-consistency figures.\n"
        s += "- heart = 50 + 25 × (z(HRV) − z(RHR)) against the wearer's frozen baselines, z clipped to ±\(Int(LevelEngine.zClip)).\n"
        s += "- lungs = 0.6 × VO2max scaled the same way + 0.4 × (100 − respiratory rate scaled), whichever exist.\n"
        s += String(format: "- muscle = the last 3 training sessions' volume load placed between the wearer's lightest and heaviest, weighted by e^(−%.1f × days ago).\n", LevelEngine.muscleDecay)
        s += String(format: "- focus = (100 − mean stress of the last 3 days) × (0.5 + %.2f × meditation days in the last 3), capped at 100.\n", LevelEngine.meditationBonusPerDay)
        s += "- steps: below \(LevelEngine.stepsFloor) the level is multiplied down, linearly, by up to \(Int(LevelEngine.stepsMaxPenalty * 100))% at zero steps.\n"
        s += "- The day's level is fixed at 06:40 from the night that ended that morning and the previous full day's activity, so what they do TODAY shows up in TOMORROW's level."
        return s
    }
}
