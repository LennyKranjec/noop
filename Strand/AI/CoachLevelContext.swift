import Foundation
import StrandAnalytics

// CoachLevelContext.swift — the level, its parts and the arithmetic behind them, for the coach.
//
// The level is the number the whole app is organised around, and the coach used to be the one voice in
// the app that could not see it. It gave sensible advice about sleep and training with no idea which of
// those the day's level was actually short on, or by how much.
//
// SO IT GETS THE WHOLE THING: today's frozen level, every part's score, weight, contribution and
// headroom, the step penalty, the meditation deduction, the metric driving each part, and the formula
// itself. The formula is written from the engine's own constants, so the explanation cannot drift from the
// calculation it explains.
//
// THE LEVEL IS A LENS, NOT THE OBJECTIVE (HEALTH_V2 H5). It used to be told that raising this number was
// its primary objective, which is how a coach ends up advising more load or less sleep for points. The
// objective is the wearer's health; the level is one view of the long-term trend.

enum CoachLevelContext {

    /// The opening line: what the level is for, and what the coach may never trade for it.
    static let objective = "The level is one lens on long-term trends. Your objective is the wearer's "
        + "health. Never advise more training load, less sleep or skipping recovery to raise the level."

    static func promptSection() -> String {
        var s = "THE LEVEL. " + objective + " When a recommendation moves a part of the level, you may "
        s += "say which part and roughly how many points.\n"

        // FROM THE LEDGER, like every other surface: the current day's written level, or — while it is
        // not today's — the last day that was written, said to be exactly that and why. "Not today's" is
        // three different things and the coach is told which: the morning flow has not run yet (the level
        // day is still yesterday), last night is still syncing, or last night was never recorded.
        let calendar = Calendar.current
        let now = Date()
        let dayKey = LevelWiring.key(from: LevelDayFreeze.levelDay(now: now, calendar: calendar), calendar: calendar)
        let todayKey = LevelWiring.key(from: now, calendar: calendar)
        let ledger = LevelLedger.shared
        let pending = LevelDayFreeze.isPendingToday(ledger: ledger, now: now, calendar: calendar)
        /// Why today's level is not the one below, or nil when it is.
        func pendingReason(shownDay: String?) -> String? {
            guard pending else { return nil }
            let shown = shownDay.map { "the figure below is the level for \($0)" } ?? "there is no earlier level either"
            if dayKey != todayKey {
                return "Today's level is not set yet: it is set when they first open the app this morning; \(shown).\n"
            }
            if ledger.isSettled(dayKey) {
                return "No level for today: last night wasn't recorded; \(shown).\n"
            }
            return "Today's level is not set yet (last night is still syncing); \(shown).\n"
        }
        // The SAME held stand-in the strip shows (`LevelDayFreeze.standIn`), not a fresh read of the
        // newest written day: the coach citing a different day from the one on the bar is two answers.
        if let frozen = ledger.entry(dayKey) ?? LevelDayFreeze.standIn(levelDay: dayKey, ledger: ledger) {
            let b = frozen.breakdown
            if let reason = pendingReason(shownDay: frozen.day) { s += reason }
            if frozen.partial {
                s += "That level was set at the day's deadline with the night only partly synced.\n"
            }
            s += String(format: "Level for %@: %.1f (no upper limit; 100 = every part at the wearer's own 95th percentile; set on the first app open of the morning and held all day).\n", frozen.day, b.level)
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
            s += String(format: "Before steps: %.1f. Step multiplier applied: ×%.3f.", b.raw, b.stepPenalty)
            let meditation = b.meditationPenalty
            s += meditation > 0.05
                ? String(format: " Meditation deduction: −%.1f points.\n", meditation)
                : " Meditation deduction: none.\n"
            let levers = b.levers().prefix(3).map {
                String(format: "%@ (+%.1f)", $0.part.rawValue, $0.headroom * b.stepPenalty)
            }
            if !levers.isEmpty {
                // Named by the day they were read from: a lever list off yesterday's level is not today's.
                let heading = pending ? "Biggest levers on the \(frozen.day) level" : "Biggest levers today"
                s += heading + ": " + levers.joined(separator: ", ") + ".\n"
            }
        } else {
            s += pendingReason(shownDay: nil) ?? "Today's level has not been computed yet.\n"
        }

        s += recipe()
        return s
    }

    /// HOW THE LEVEL IS CALCULATED, from the engine's own constants (ledger epoch 4). Pure: no store read.
    static func recipe() -> String {
        func share(_ v: Double) -> String { String(format: "%.2f", v) }
        let sleep = LevelEngine.sleepShares
        let heart = LevelEngine.heartShares
        let lungs = LevelEngine.lungsShares
        let muscle = LevelEngine.muscleShares
        let before = LevelEngine.meditationMinChangeoverDay
        var s = "HOW IT IS CALCULATED (no ceiling, no floor):\n"
        s += "- Every input is scored against the wearer's own frozen baseline: 50 = their average day, 100 = their own 95th-percentile day in the good direction, linear and UNBOUNDED both ways. Beating their 95th percentile scores above 100. No input is capped.\n"
        s += "- level = (sum of part score × weight, weights re-shared over the parts that have data) × step multiplier − meditation deduction. Not clamped: all five parts at their own 100 with no step penalty and no deduction is a level of 100, more is more.\n"
        s += "- Weights: " + LevelPart.allCases.map { "\($0.rawValue) \(Int(($0.weight * 100).rounded()))%" }
            .joined(separator: ", ") + ".\n"
        s += "- A LEVEL OF STATE: every physiological input is a 7-day mean, strength a 12-week best, training load a 42-day chronic figure — one bad day barely moves it.\n"
        s += "- sleep = \(share(sleep.restorative)) × deep+REM minutes + \(share(sleep.hrv)) × night HRV + \(share(sleep.regularity)) × bed/wake regularity (how far bedtime and wake time moved against the night before; lower is better). 7-night means.\n"
        s += "- heart = \(share(heart.hrv)) × HRV + \(share(heart.rhr)) × resting HR (lower is better).\n"
        s += "- lungs = \(share(lungs.vo2max)) × VO2max (NOOP's own estimate: runs and walks — speed against heart-rate reserve — blended with the HUNT model from the weekly training days, minutes and zone-4–5 share) + \(share(lungs.respRate)) × respiratory rate (lower is better).\n"
        s += "- muscle = \(share(muscle.strength)) × strength (estimated-1RM index: each exercise's best e1RM over 12 weeks as a ratio of its own median) + \(share(muscle.load)) × chronic training load (42-day exponentially weighted volume, not capped: it measures training done, not adaptation).\n"
        s += "- focus = daytime calm only (RMSSD of still waking hours). Meditation adds nothing to focus.\n"
        s += "- steps (7-day average): below \(LevelEngine.stepsFloor) the level is multiplied down, linearly, by up to \(Int(LevelEngine.stepsMaxPenalty * 100))% at zero steps.\n"
        s += String(format: "- meditation only deducts: %.0f point per missed day in the level's 7-day window, and only in its era (from their first logged session; before it there is no meditation term at all). A day counts as meditated at %.0f min before %@ and %.0f min from it. A day with no data is not a miss.\n",
                    LevelEngine.meditationMissPenaltyPoints, LevelEngine.meditationMinMinutesBeforeChangeover,
                    before, LevelEngine.meditationMinMinutes)
        s += "- The day's level is fixed when they first open the app in the morning, from the night that ended that morning and the previous full day's activity (steps, calm, training load, strength), so what they do TODAY shows up in TOMORROW's level.\n"
        s += "Because the level tracks state, advise for the weeks ahead — sustained sleep, progressive strength, aerobic base — rather than for tomorrow's number."
        return s
    }
}
