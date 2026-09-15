package com.noop.ai

import com.noop.data.DailyMetric
import kotlin.math.roundToInt

// MARK: - What the numbers say is wrong today
//
// The model writes the NAME and the INSULT. This file decides whether there is anything to name, and
// what the target is — because a language model handed a day of metrics and asked "should they
// stretch, and how much?" will answer yes, always, with a number it made up.
//
// Every trigger here is a plain threshold over a figure the app already measures, and each one states
// the target in the wearer's own units. If none fire, no side quest is issued, and a day with nothing
// wrong is allowed to be a day with nothing wrong.

/** One condition that can raise a side quest, with the directive it would raise. */
data class QuestTrigger(
    /** Stable id, so the same condition cannot raise two quests in a day. */
    val id: String,
    /** What the system saw, in a sentence, handed to the model as the reason. */
    val observation: String,
    /** The directive, with its number already in it. Never model-written. */
    val target: String,
    val rewards: List<QuestReward>,
    val xp: Int,
)

object QuestTriggers {

    /** Below this many steps, a day counts as not having happened. */
    const val STEPS_FLOOR = 3_000

    /** The step target a sedentary day earns. Reachable the same evening, which is the point. */
    const val STEPS_TARGET = 8_000

    /** Effort at or above this, with charge on the floor, is training into a hole. */
    const val EFFORT_HIGH = 14.0

    /** Charge at or below this is the body asking for the day off. */
    const val CHARGE_LOW = 34.0

    /** Sleep under this many hours is the single biggest thing wrong with the day. */
    const val SLEEP_SHORT_HOURS = 6.0

    /**
     * Every trigger that fires for [today], most urgent first.
     *
     * [recent] is the trailing window (oldest first) and is used for the "how long has this been going
     * on" triggers; [today] is the day being judged. Both may be absent — a phone with no synced data
     * raises nothing, rather than inventing a reason to nag.
     */
    fun evaluate(today: DailyMetric?, recent: List<DailyMetric>): List<QuestTrigger> {
        val day = today ?: return emptyList()
        val out = mutableListOf<QuestTrigger>()

        // OVERREACHING — hard effort on an empty tank. First, because continuing to train through it is
        // the one thing here that does lasting damage.
        val charge = day.recovery
        val effort = day.strain
        if (charge != null && effort != null && charge <= CHARGE_LOW && effort >= EFFORT_HIGH) {
            out.add(
                QuestTrigger(
                    id = "overreach",
                    observation = "They trained hard (effort ${fmt(effort)}) on a recovery score of " +
                        "${charge.roundToInt()}%, which is training into a hole.",
                    target = "20 minutes of Zone 2 or mobility only — nothing hard, and in bed early",
                    rewards = listOf(QuestReward.HEART, QuestReward.MUSCLE, QuestReward.SLEEP),
                    xp = 60,
                ),
            )
        }

        // SHORT SLEEP — measured, and the lever with the largest effect on tomorrow.
        val sleepHours = day.totalSleepMin?.div(60.0)
        if (sleepHours != null && sleepHours < SLEEP_SHORT_HOURS) {
            out.add(
                QuestTrigger(
                    id = "short-sleep",
                    observation = "They slept ${fmt(sleepHours)} hours, which is under six.",
                    target = "Lights out 45 minutes earlier than last night. No screen in bed",
                    rewards = listOf(QuestReward.SLEEP, QuestReward.BRAIN),
                    xp = 50,
                ),
            )
        }

        // SEDENTARY — the "you have not moved at all" case the wearer named. Only when steps are
        // actually being counted: a null is a missing sensor, not a still day, and the difference
        // matters because one of them deserves a quest and the other deserves silence.
        val steps = day.steps
        if (steps != null && steps < STEPS_FLOOR) {
            out.add(
                QuestTrigger(
                    id = "sedentary",
                    observation = "They have taken $steps steps today, which is essentially none.",
                    target = "$STEPS_TARGET steps before the day is out",
                    rewards = listOf(QuestReward.HEART, QuestReward.LUNGS),
                    xp = 40,
                ),
            )
        }

        // NOTHING LOGGED IN DAYS — the quiet drift, only visible across the window.
        val trainedRecently = recent.takeLast(4).any { (it.strain ?: 0.0) >= 8.0 }
        if (recent.size >= 4 && !trainedRecently) {
            out.add(
                QuestTrigger(
                    id = "idle-streak",
                    observation = "Nothing above light effort has been recorded in four days.",
                    target = "One 30-minute session today. Anything that raises your heart rate",
                    rewards = listOf(QuestReward.HEART, QuestReward.MUSCLE),
                    xp = 55,
                ),
            )
        }

        // STRESS / LOW HRV against their own baseline — relative, because an absolute HRV threshold
        // means nothing across people.
        val hrv = day.avgHrv
        val baseline = recent.dropLast(1).mapNotNull { it.avgHrv }.takeIf { it.size >= 5 }?.average()
        if (hrv != null && baseline != null && hrv < baseline * 0.8) {
            out.add(
                QuestTrigger(
                    id = "hrv-dip",
                    observation = "Their HRV is ${hrv.roundToInt()}ms against a baseline of " +
                        "${baseline.roundToInt()}ms — a fifth below normal for them.",
                    target = "10 minutes of slow breathing or meditation before this evening",
                    rewards = listOf(QuestReward.BRAIN, QuestReward.STRESS, QuestReward.HEART),
                    xp = 45,
                ),
            )
        }

        return out
    }

    private fun fmt(v: Double): String =
        if (v % 1.0 == 0.0) v.toInt().toString() else String.format(java.util.Locale.US, "%.1f", v)
}
