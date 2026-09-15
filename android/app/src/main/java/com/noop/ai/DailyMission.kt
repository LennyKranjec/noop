package com.noop.ai

import android.content.Context
import org.json.JSONObject
import java.time.LocalDate

// MARK: - One thing to do today, written overnight
//
// At 06:45 the deep model reads the day's metrics and the wearer's goals and writes ONE mission. Not a
// plan, not a list — a single thing, because a list of five is a list nobody starts.
//
// WHY THE DEEP MODEL. This is the one generation nobody is waiting for: it runs while the phone is on a
// charger at quarter to seven, so the 2B's minutes cost nothing, and it is the only place its extra
// reasoning is affordable. The Fast model is the fallback, not the choice.
//
// IT CARRIES NO POINTS. An earlier cut had the model price each mission in XP. XP is gone: the level is
// measured from the body against a frozen scale, not awarded for finishing things, and a second
// currency running beside it would have been two different "levels" in one app. What a mission is worth
// is whether doing it moves the metrics — which the level then shows on its own, without being told.

/** One day's mission. */
data class DailyMission(
    val dayKey: String,
    val text: String,
    val createdAtMs: Long = System.currentTimeMillis(),
)

object DailyMissionStore {

    private const val KEY = "coach.dailyMission"

    /** Today's mission, or null when none has been generated for today yet. */
    fun today(context: Context, today: LocalDate = LocalDate.now()): DailyMission? =
        read(context)?.takeIf { it.dayKey == today.toString() }

    /**
     * The stored mission whatever day it is for.
     *
     * Separate from [today] because a mission from yesterday must NOT be shown as today's, but it is
     * still the thing the generator would be replacing, and a caller deciding whether to generate
     * needs to see it.
     */
    fun read(context: Context): DailyMission? {
        val raw = prefs(context).getString(KEY, null) ?: return null
        return runCatching {
            val o = JSONObject(raw)
            DailyMission(
                dayKey = o.getString("day"),
                text = o.getString("text"),
                createdAtMs = o.optLong("createdAt", 0L),
            )
        }.getOrNull()
    }

    fun write(context: Context, mission: DailyMission) {
        val o = JSONObject()
            .put("day", mission.dayKey)
            .put("text", mission.text)
            .put("createdAt", mission.createdAtMs)
        prefs(context).edit().putString(KEY, o.toString()).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
}

object DailyMissionWriter {

    /**
     * The framing the mission is written under.
     *
     * One instruction, stated once: write the mission. An earlier version also asked for an XP line,
     * which is gone with the currency — and removing it is a small mercy for a 0.8B model, which now
     * has one job in its output instead of a format to get right first.
     */
    fun systemPrompt(context: Context, grounding: String): String = buildString {
        append("You are the user's coach: motivating, dryly sarcastic, aimed at the excuse and never ")
        append("at the person. You are writing TODAY'S MISSION — one single concrete thing to do ")
        append("today, chosen from their numbers and their goals. Not a list, not a plan for the ")
        append("week. It must be doable today and it must suit the state their data is in: do not ")
        append("prescribe a hard session on a wrecked night.\n\n")
        append("Answer with the mission itself, two or three sentences, and nothing else — no heading, ")
        append("no preamble, no score.\n\n")
        append("Example:\n")
        append("Bed by 22:30. Yes, that early. Your HRV has been filing complaints for three days ")
        append("and no amount of Zone 2 is going to out-train a 5-hour night.")
        append("\n\n").append(grounding)
        CoachGoals.promptSection(context)?.let { append("\n\n").append(it) }
    }

    /** What the model is asked, once the framing above is in place. */
    const val QUESTION = "Write today's mission."

    /**
     * Read a mission out of the model's answer.
     *
     * Returns null only when there is no usable text at all. A stray `XP: 40` line is still stripped:
     * the instruction no longer asks for one, but a model that saw thousands of them in training will
     * occasionally volunteer one anyway, and it must not end up on the card.
     */
    fun parse(answer: String, dayKey: String): DailyMission? {
        val text = answer.lines()
            .filterNot { SCORE_LINE.containsMatchIn(it) }
            .joinToString("\n")
            .trim()
            .ifEmpty { return null }
        return DailyMission(dayKey = dayKey, text = text)
    }

    /** A leftover `XP: 40` line, with or without the colon or surrounding asterisks. */
    private val SCORE_LINE = Regex("""^\s*\**xp\**\s*:?\s*\d{1,9}\s*\**\s*$""", RegexOption.IGNORE_CASE)
}
