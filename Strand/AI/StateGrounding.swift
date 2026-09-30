import Foundation
import StrandAnalytics

// StateGrounding.swift — the State tile's OWN grounding, and the ONE request it now sends.
//
// WHAT WENT WRONG. The tile reused the chat's grounding — `buildFullContext()`, every block of it — and
// then sent it TWICE in parallel, once for the workout suggestions and once for the mission. On a Groq
// on-demand key that is 8,000 tokens per MINUTE, shared, and one of the two was refused outright:
//
//   Request too large … on tokens per minute (TPM): Limit 8000, Requested 8646
//
// Measured, the tile's request was about 7,800 estimated tokens, of which about 5,200 was
// `buildFullContext()`: the whole level formula (~850), fourteen days of every metric (~680), ten sections
// of CoachExtraContext including the dream journal, the quest history, the per-exercise strength
// progression and the bedroom (~2,100 together), the three daily scores over a week (~420), the routines
// and the memory file. The tile's prompt asks about the next few hours. It reads almost none of that.
//
// SO IT GETS ITS OWN, and it is built from what its prompt actually names: today's training state (effort
// so far against target, charge, sleep debt, HRV and RHR against baseline, stress, zones, today's
// sessions, the level's gaps), the day's schedule, a SHORT history, stress today, and the routines the
// times have to fit inside. No dream text, no level formula, no strength progression, no fourteen-day
// table, no memory file unless there is room.
//
// AND IT IS ONE REQUEST, not two. `StatePlanWriter` asks for the mission line and the workout list in a
// single JSON object, which halves the cost outright and removes the collision two parallel requests had
// against a per-MINUTE limit. Both halves are parsed by the parsers that already existed
// (`WorkoutSuggestionParser.parsePlan`, `DailyMissionWriter.parse`) and both keep their fallbacks.

// MARK: - The lean grounding

enum StateGrounding {

    /// The blocks the tile's grounding is assembled from, most valuable first.
    ///
    /// PURE, and every piece is handed in already built: the caller does the reads, this decides what is
    /// worth what. That is what makes "does a lean grounding still contain the figures the prompt names"
    /// a test rather than an opinion.
    ///
    /// THE VALUES ARE THE TILE'S, not the chat's. Today's training state is the answer to the tile's only
    /// question, so it goes last; the memory file is a constraint on tone and is the first thing to go.
    static func blocks(dayFrame: String,
                       training: String,
                       trainingShort: String?,
                       schedule: String,
                       history: String?,
                       stress: String?,
                       routines: String?,
                       memory: String?,
                       closing: String,
                       weekPlan: String? = nil) -> [CoachContextBlock] {
        var out: [CoachContextBlock] = []
        // Declaration order is READING order, and it is deliberate: which day it is, then today's figures,
        // then the clock, then the background, then the rule to close on.
        out.append(CoachContextBlock(name: "which day each figure belongs to", value: 90, full: dayFrame))
        out.append(CoachContextBlock(name: "today's training state", value: 100,
                                     full: training, short: trainingShort))
        // THE WEEK PLAN'S WORD ON TODAY (HEALTH_V2 H9): one line, right after the training state it bounds.
        // The tile suggests sessions; on a day the plan made easy or rest, a hard one would contradict the
        // quests issued for the same day.
        if let weekPlan, !weekPlan.isEmpty {
            out.append(CoachContextBlock(name: "the week plan's guidance for today", value: 80, full: weekPlan))
        }
        out.append(CoachContextBlock(name: "today's schedule", value: 95, full: schedule))
        if let stress {
            out.append(CoachContextBlock(name: "stress today", value: 60, full: stress))
        }
        if let history {
            out.append(CoachContextBlock(name: "the last days' scores", value: 70, full: history))
        }
        if let routines {
            out.append(CoachContextBlock(name: "their routines", value: 50, full: routines))
        }
        if let memory {
            out.append(CoachContextBlock(name: "the coach's memory file", value: 30, full: memory))
        }
        out.append(CoachContextBlock(name: "the dating rule", value: 85, full: closing))
        return out
    }

    /// One line of stress for the tile, from the figures the stress objective actually names: stress now,
    /// the hour-by-hour curve, and the derived Stress Index.
    ///
    /// PURE and ABSTAINING. Every part is optional and a missing part is simply absent — nil when there is
    /// nothing at all, never a heading over no figures. The hourly curve is thinned to a handful of
    /// readings rather than all sixteen: the objective asks whether stress is RISING, which three points
    /// answer as well as sixteen and for a fifth of the tokens.
    static func stressBlock(day: String, now: Double?, hourly: [(hour: Int, level: Double)],
                            stressIndex: Double?) -> String? {
        var lines: [String] = []
        if let now {
            lines.append(String(format: "  Stress right now (the last 10 minutes of %@, at rest, 0-3): %.1f",
                                day, now))
        }
        let thinned = thin(hourly, keeping: 5)
        if !thinned.isEmpty {
            lines.append("  Stress by hour on \(day) (0-3, local clock, a few readings across the day): "
                         + thinned.map { String(format: "%02d:00 %.1f", $0.hour, $0.level) }
                            .joined(separator: ", "))
        }
        if let stressIndex {
            lines.append("  " + AICoachEngine.stressIndexSummary(si: stressIndex))
        }
        guard !lines.isEmpty else { return nil }
        return (["STRESS ON \(day):"] + lines).joined(separator: "\n")
    }

    /// `keeping` readings spread evenly across `values`, first and last always included.
    ///
    /// Evenly spaced rather than the first or the last N: the shape of the day is the point, and the last
    /// five hours of it say nothing about whether the curve is rising.
    static func thin<T>(_ values: [T], keeping: Int) -> [T] {
        guard keeping > 0 else { return [] }
        guard values.count > keeping else { return values }
        guard keeping > 1 else { return [values[values.count - 1]] }
        let last = values.count - 1
        var picked: [Int] = []
        for i in 0..<keeping {
            let index = Int((Double(i) * Double(last) / Double(keeping - 1)).rounded())
            if picked.last != index { picked.append(index) }
        }
        return picked.map { values[$0] }
    }
}

// MARK: - The one merged request

/// The State tile's single request: the mission line AND the workout list, in one JSON object.
///
/// WHY MERGED RATHER THAN SEQUENTIAL. The two requests shared a grounding word for word, so sending it
/// twice paid for the same tokens twice — and against a per-MINUTE limit two requests a second apart
/// collide with each other even when each one fits. One request halves the spend and cannot collide with
/// itself. The mission and the suggestions were already generated together from the same state; asking
/// for them together is the shape that was always implied.
///
/// THE INSTRUCTIONS ARE THE EXISTING ONES, verbatim: `WorkoutSuggestionWriter.rules`, `levelObjective`,
/// `StateDayPlanContext.stressObjective`, `allowedSection`, `fieldSpec` and `DailyMissionWriter.rules` /
/// `goalLines`. Nothing the coach is asked to DO has changed — only how many requests carry the asking.
enum StatePlanWriter {

    static let question = "Answer with today's mission and the further workouts, as one JSON object."

    static func systemPrompt(grounding: String, choices: StateWorkoutChoices = .all) -> String {
        var s = WorkoutSuggestionWriter.rules + "\n\n"
        s += "SECOND OUTPUT — TODAY'S MISSION. In the same answer you also write today's mission.\n"
        s += DailyMissionWriter.rules + "\n\n"
        s += WorkoutSuggestionWriter.levelObjective + "\n\n"
        s += StateDayPlanContext.stressObjective + "\n"
        s += StateDayPlanContext.missionStressNote
        s += StateDayPlanContext.missionChoicesNote(choices) + "\n\n"
        s += WorkoutSuggestionWriter.allowedSection(choices) + "\n\n"
        s += WorkoutSuggestionWriter.jsonHeader + "\n"
        s += jsonShape
        s += "\n"
        s += WorkoutSuggestionWriter.fieldSpec + "\n"
        s += missionFieldSpec + "\n\n"
        s += grounding
        return s
    }

    /// The merged shape: the workout object's own keys plus the two the mission needs.
    static let jsonShape =
        #"{"left_today":"one or two sentences: what is still due today, or that nothing is","workouts":[{"sport":"Running","minutes":40,"zone":2,"effort":12,"window":"17:00-18:00","why":"one short sentence"},{"sport":"NSDR","minutes":20,"zone":1,"effort":1,"window":"18:30-19:00","why":"one short sentence"}],"mission":"two or three sentences: the one thing to do today","mission_goal":"GOAL: BEDTIME_BY 22:30"}"#

    static let missionFieldSpec: String = {
        var s = "mission: REQUIRED. Two or three sentences in the user's language — the ONE concrete thing "
        s += "to do today. Not a list, not a plan for the week, no heading and no score.\n"
        s += "mission_goal: REQUIRED, and it must be the goal the mission is about, with the same number. "
        s += DailyMissionWriter.goalLines
        return s
    }()

    /// What the tile got back: the plan half and the mission half, each independently optional.
    struct Answer: Equatable {
        var plan: WorkoutPlan?
        /// The mission as `DailyMissionWriter.parse` wants to see it — the sentences, then the GOAL line.
        var missionText: String?
    }

    /// Read the merged answer.
    ///
    /// THE TWO HALVES FAIL SEPARATELY, on purpose. A model that writes a perfect workout list and forgets
    /// the mission key must still get its workout list used; the old two-request shape had that property
    /// for free and losing it would be a regression. So the plan goes through `parsePlan` exactly as
    /// before, and the mission is looked for independently — including in a reply whose JSON the plan
    /// parser could not use at all.
    static func parse(_ raw: String) -> Answer {
        Answer(plan: WorkoutSuggestionParser.parsePlan(raw), missionText: missionText(in: raw))
    }

    /// The `mission` + `mission_goal` pair, rebuilt into the two-line shape `DailyMissionWriter.parse`
    /// reads. nil when there is no mission in the answer.
    ///
    /// Tolerant of the key names a model actually uses, for the same reason `WorkoutSuggestionParser` is.
    static func missionText(in raw: String) -> String? {
        guard let json = WorkoutSuggestionParser.extractJSON(raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let dict = obj as? [String: Any]
        else { return nil }
        let mission = ["mission", "todays_mission", "todaysMission", "daily_mission", "dailyMission"]
            .lazy.compactMap { dict[$0] as? String }
            .first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mission, !mission.isEmpty else { return nil }
        let goal = ["mission_goal", "missionGoal", "goal"]
            .lazy.compactMap { dict[$0] as? String }
            .first?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let goal, !goal.isEmpty else { return mission }
        // A model that writes "BEDTIME_BY 22:30" without the label still means a goal line, and
        // `QuestGoal.parseLine` wants the label. Added, never replaced.
        let line = goal.uppercased().hasPrefix("GOAL:") ? goal : "GOAL: " + goal
        return mission + "\n" + line
    }
}
