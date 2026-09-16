import Foundation
import WhoopStore

// QuestTriggers.swift — what the numbers say is wrong today.
//
// Pure + deterministic so it is unit-testable without a strap or an app target, and so the output is
// byte-identical to the Android twin `com.noop.ai.QuestTriggers` (the cross-platform parity contract).
//
// The model writes the NAME and the INSULT. This file decides whether there is anything to name, and
// what the target is — because a language model handed a day of metrics and asked "should they
// stretch, and how much?" will answer yes, always, with a number it made up.
//
// Every trigger here is a plain threshold over a figure the app already measures, and each one states
// the target in the user's own units. If none fire, no side quest is issued, and a day with nothing
// wrong is allowed to be a day with nothing wrong.

/// One condition that can raise a side quest, with the directive it would raise.
public struct QuestTrigger: Equatable, Sendable {
    /// Stable id, so the same condition cannot raise two quests in a day.
    public let id: String
    /// What the system saw, in a sentence, handed to the model as the reason.
    public let observation: String
    /// The directive, with its number already in it. Never model-written.
    public let target: String
    public let rewards: [QuestReward]
    public let xp: Int
    /// What closes it — stated beside the directive rather than parsed back out of it, because the
    /// trigger already knows the number it just wrote into the sentence.
    public let goal: QuestGoal?

    public init(id: String, observation: String, target: String, rewards: [QuestReward], xp: Int,
                goal: QuestGoal? = nil) {
        self.id = id
        self.observation = observation
        self.target = target
        self.rewards = rewards
        self.xp = xp
        self.goal = goal
    }
}

public enum QuestTriggers {

    /// Below this many steps, a day counts as not having happened.
    public static let stepsFloor = 3_000

    /// The step target a sedentary day earns. Reachable the same evening, which is the point.
    public static let stepsTarget = 8_000

    /// Effort at or above this, with charge on the floor, is training into a hole.
    public static let effortHigh: Double = 14

    /// Charge at or below this is the body asking for the day off.
    public static let chargeLow: Double = 34

    /// Sleep under this many hours is the single biggest thing wrong with the day.
    public static let sleepShortHours: Double = 6

    /// Every trigger that fires for `today`, most urgent first.
    ///
    /// `recent` is the trailing window (oldest first) and is used for the "how long has this been going
    /// on" triggers; `today` is the day being judged. Both may be absent — a phone with no synced data
    /// raises nothing, rather than inventing a reason to nag.
    public static func evaluate(today: DailyMetric?, recent: [DailyMetric]) -> [QuestTrigger] {
        guard let day = today else { return [] }
        var out: [QuestTrigger] = []

        // OVERREACHING — hard effort on an empty tank. First, because continuing to train through it
        // is the one thing here that does lasting damage.
        if let charge = day.recovery, let effort = day.strain,
           charge <= chargeLow, effort >= effortHigh {
            out.append(QuestTrigger(
                id: "overreach",
                observation: "They trained hard (effort \(fmt(effort))) on a recovery score of "
                    + "\(Int(charge.rounded()))%, which is training into a hole.",
                target: "20 minutes of Zone 2 or mobility only — nothing hard, and in bed early",
                rewards: [.heart, .muscle, .sleep],
                xp: 60,
                goal: QuestGoal(metric: .workoutMinutes, threshold: 20)
            ))
        }

        // SHORT SLEEP — measured, and the lever with the largest effect on tomorrow.
        if let minutes = day.totalSleepMin, minutes / 60 < sleepShortHours {
            out.append(QuestTrigger(
                id: "short-sleep",
                observation: "They slept \(fmt(minutes / 60)) hours, which is under six.",
                target: "Lights out 45 minutes earlier than last night. No screen in bed",
                rewards: [.sleep, .brain],
                xp: 50,
                goal: QuestGoal(metric: .bedtimeEarlier, threshold: 45)
            ))
        }

        // SEDENTARY — the "you have not moved at all" case. Only when steps are actually being
        // counted: a nil is a missing sensor, not a still day, and the difference matters because one
        // of them deserves a quest and the other deserves silence.
        if let steps = day.steps, steps < stepsFloor {
            out.append(QuestTrigger(
                id: "sedentary",
                observation: "They have taken \(steps) steps today, which is essentially none.",
                target: "\(stepsTarget) steps before the day is out",
                rewards: [.heart, .lungs],
                xp: 40,
                goal: QuestGoal(metric: .steps, threshold: Double(stepsTarget))
            ))
        }

        // NOTHING LOGGED IN DAYS — the quiet drift, only visible across the window.
        let lastFour = recent.suffix(4)
        let trainedRecently = lastFour.contains { ($0.strain ?? 0) >= 8 }
        if recent.count >= 4 && !trainedRecently {
            out.append(QuestTrigger(
                id: "idle-streak",
                observation: "Nothing above light effort has been recorded in four days.",
                target: "One 30-minute session today. Anything that raises your heart rate",
                rewards: [.heart, .muscle],
                xp: 55,
                goal: QuestGoal(metric: .workoutMinutes, threshold: 30)
            ))
        }

        // STRESS / LOW HRV against their own baseline — relative, because an absolute HRV threshold
        // means nothing across people.
        let priorHrv = recent.dropLast().compactMap(\.avgHrv)
        if let hrv = day.avgHrv, priorHrv.count >= 5 {
            let baseline = priorHrv.reduce(0, +) / Double(priorHrv.count)
            if hrv < baseline * 0.8 {
                out.append(QuestTrigger(
                    id: "hrv-dip",
                    observation: "Their HRV is \(Int(hrv.rounded()))ms against a baseline of "
                        + "\(Int(baseline.rounded()))ms — a fifth below normal for them.",
                    target: "10 minutes of slow breathing or meditation before this evening",
                    rewards: [.brain, .stress, .heart],
                    xp: 45,
                    goal: QuestGoal(metric: .meditationMinutes, threshold: 10)
                ))
            }
        }

        return out
    }

    /// At most this many side quests a day. A system that can interrupt five times before lunch is
    /// uninstalled by lunch.
    public static let maxSidePerDay = 2

    /// Whether a side quest may be raised for `trigger` today: one per condition, and within budget.
    public static func mayRaise(existingToday: [Quest], trigger: QuestTrigger) -> Bool {
        let sideToday = existingToday.filter { $0.kind == .side }.count
        if sideToday >= maxSidePerDay { return false }
        return !existingToday.contains { $0.target == trigger.target }
    }

    /// The trigger to raise now, or nil.
    ///
    /// Only ONE, even when several fire: they are ordered by urgency in `evaluate`, and the user is
    /// shown the most urgent thing that is not already on their list.
    public static func next(
        today: DailyMetric?,
        recent: [DailyMetric],
        existingToday: [Quest]
    ) -> QuestTrigger? {
        evaluate(today: today, recent: recent)
            .first { mayRaise(existingToday: existingToday, trigger: $0) }
    }

    /// One decimal, or none when the value is whole. Locale-fixed so the sentence handed to the model
    /// reads the same on a German phone as on an American one — and matches the Kotlin twin's
    /// `Locale.US` formatting.
    private static func fmt(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(v))
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), v)
    }
}
