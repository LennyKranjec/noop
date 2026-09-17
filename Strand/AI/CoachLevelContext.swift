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
            s += String(format: "Level for %@: %.1f (no upper limit; 100 = every part at the wearer's own 95th percentile; set at 06:40 and held all day).\n", frozen.day, b.level)
            s += "Parts (score, 50 = average and 100 = own 95th percentile · effective weight · points contributed · points still missing to 100):\n"
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

        s += "HOW IT IS CALCULATED (no ceiling, no floor):\n"
        s += "- Every input is scored against the wearer's own frozen baseline: 50 = their average day, 100 = their own 95th-percentile day in the good direction, linear and UNBOUNDED both ways. Beating their 95th percentile scores above 100.\n"
        s += "- level = (sum of part score × weight, weights re-shared over the parts that have data) × step multiplier. Not clamped: all five parts at their own 100 with no step penalty is a level of 100, more is more.\n"
        s += "- Weights: " + LevelPart.allCases.map { "\($0.rawValue) \(Int(($0.weight * 100).rounded()))%" }
            .joined(separator: ", ") + ".\n"
        s += "- sleep = 0.60 × deep+REM minutes (3-night mean) + 0.25 × night HRV (3-night mean) + 0.15 × bedtime/wake regularity (minutes moved vs the night before, lower is better).\n"
        s += "- heart = 0.5 × HRV + 0.5 × resting HR (lower is better).\n"
        s += "- lungs = 0.6 × VO2max + 0.4 × respiratory rate (lower is better).\n"
        s += String(format: "- muscle = the last 3 training sessions' volume load, each scored against the baseline, weighted by e^(−%.1f × days ago).\n", LevelEngine.muscleDecay)
        s += String(format: "- focus = 0.5 × daytime calm (RMSSD of still waking hours, 3-day mean) + 0.5 × meditation, where meditation = 100 × (1 − e^(−minutes/%.0f)) over the UNBROKEN run of consecutive days meditated — one missed day resets it to 0.\n", LevelEngine.meditationTauMin)
        s += "- steps: below \(LevelEngine.stepsFloor) the level is multiplied down, linearly, by up to \(Int(LevelEngine.stepsMaxPenalty * 100))% at zero steps.\n"
        s += "- The day's level is fixed at 06:40 from the night that ended that morning and the previous full day's activity (steps, calm, meditation run, training), so what they do TODAY shows up in TOMORROW's level.\n"
        s += "The cheapest points are usually: never breaking the daily meditation run, deep+REM sleep, and bedtime regularity."
        return s
    }
}
