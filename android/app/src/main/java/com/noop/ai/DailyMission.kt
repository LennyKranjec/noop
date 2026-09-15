package com.noop.ai

import android.content.Context
import org.json.JSONObject
import java.time.LocalDate

// MARK: - One thing to do today, written overnight
//
// At 06:45 the deep model reads the day's metrics and the wearer's goals and writes ONE mission, worth
// some XP. Not a plan, not a list — a single thing, because a list of five is a list nobody starts.
//
// WHY THE DEEP MODEL. This is the one generation nobody is waiting for: it runs while the phone is on a
// charger at quarter to seven, so the 2B's minutes cost nothing, and it is the only place its extra
// reasoning is affordable. The Fast model is the fallback, not the choice.
//
// THE XP IS THE MODEL'S OWN CALL, BOUNDED. It is told the range and asked to weigh the mission against
// it, because "run 8k on 3h sleep" and "go to bed before midnight" are not worth the same. A number
// outside the range, or no number at all, falls back to the middle — the mission still stands, it just
// stops pretending to a precision the parse did not get.

/** One day's mission. [xp] is what claiming it awards; [claimed] is held in [XpLedger], not here. */
data class DailyMission(
    val dayKey: String,
    val text: String,
    val xp: Int,
    val createdAtMs: Long = System.currentTimeMillis(),
) {
    /** The ledger key, so a mission can be claimed exactly once. */
    val claimKey: String get() = "mission-$dayKey"
}

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
                xp = o.optInt("xp", DEFAULT_XP).coerceIn(MIN_XP, MAX_XP),
                createdAtMs = o.optLong("createdAt", 0L),
            )
        }.getOrNull()
    }

    fun write(context: Context, mission: DailyMission) {
        val o = JSONObject()
            .put("day", mission.dayKey)
            .put("text", mission.text)
            .put("xp", mission.xp)
            .put("createdAt", mission.createdAtMs)
        prefs(context).edit().putString(KEY, o.toString()).apply()
    }

    fun clear(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)

    /** The XP a mission may be worth. Wide enough to mean something, narrow enough not to break the curve. */
    const val MIN_XP = 10
    const val MAX_XP = 120
    const val DEFAULT_XP = 45
}

object DailyMissionWriter {

    /**
     * The framing the mission is written under.
     *
     * The output shape is stated twice — as a rule and as an example — because a small model given one
     * line of format instruction produces the right thing about half the time. [parse] is written to
     * survive it getting the shape wrong anyway.
     */
    fun systemPrompt(context: Context, grounding: String): String = buildString {
        append("You are the user's coach: motivating, dryly sarcastic, aimed at the excuse and never ")
        append("at the person. You are writing TODAY'S MISSION — one single concrete thing to do ")
        append("today, chosen from their numbers and their goals. Not a list, not a plan for the ")
        append("week. It must be doable today and it must suit the state their data is in: do not ")
        append("prescribe a hard session on a wrecked night.\n\n")
        append("Answer in EXACTLY this shape and nothing else:\n")
        append("XP: <a number between ").append(DailyMissionStore.MIN_XP)
        append(" and ").append(DailyMissionStore.MAX_XP).append(">\n")
        append("<the mission, two or three sentences, sarcastic and motivating>\n\n")
        append("Example:\n")
        append("XP: 40\n")
        append("Bed by 22:30. Yes, that early. Your HRV has been filing complaints for three days ")
        append("and no amount of Zone 2 is going to out-train a 5-hour night.\n\n")
        append("Weigh the XP by how hard it actually is for them today, not by how virtuous it sounds.")
        append("\n\n").append(grounding)
        CoachGoals.promptSection(context)?.let { append("\n\n").append(it) }
    }

    /** What the model is asked, once the framing above is in place. */
    const val QUESTION = "Write today's mission."

    /**
     * Read a mission out of the model's answer.
     *
     * Returns null only when there is no usable text at all. A missing or out-of-range XP line is NOT
     * a failure — the mission is the valuable half, and dropping it because a number was malformed
     * would be letting the scoring tail wag the coaching dog.
     */
    fun parse(answer: String, dayKey: String): DailyMission? {
        val lines = answer.lines()
        val xp = lines.firstNotNullOfOrNull { line ->
            XP_LINE.find(line)?.groupValues?.get(1)?.toIntOrNull()
        }
        // Everything that is not the XP line is the mission. Dropped rather than kept-and-trimmed so
        // an "XP: 40" sitting mid-paragraph cannot end up in the text the wearer reads.
        val text = lines
            .filterNot { XP_LINE.containsMatchIn(it) }
            .joinToString("\n")
            .trim()
            .ifEmpty { return null }

        return DailyMission(
            dayKey = dayKey,
            text = text,
            xp = xp?.coerceIn(DailyMissionStore.MIN_XP, DailyMissionStore.MAX_XP)
                ?: DailyMissionStore.DEFAULT_XP,
        )
    }

    /**
     * `XP: 40`, with or without the colon or surrounding asterisks, anywhere on its own line.
     *
     * The digit run is generous rather than tight: a model that writes `XP: 99999` has stated an absurd
     * number, and matching it so it can be CLAMPED is better than failing to match and silently
     * defaulting — the first is a bounded award, the second loses the model's intent entirely.
     */
    private val XP_LINE = Regex("""^\s*\**xp\**\s*:?\s*(\d{1,9})\s*\**\s*$""", RegexOption.IGNORE_CASE)
}
