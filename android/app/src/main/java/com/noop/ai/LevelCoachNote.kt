package com.noop.ai

import android.content.Context
import com.noop.analytics.LevelBreakdown
import com.noop.analytics.LevelPart
import java.time.LocalDate
import kotlin.math.roundToInt

// MARK: - What the system makes of the level
//
// One line at the head of the level panel, written from the SAME breakdown the radar is drawn from:
// each of the five parts, what it scored, and what it is actually worth to the number in the middle.
//
// IT COMMENTS ON THE WEIGHTING, which is the thing the radar cannot say on its own. A pentagon leaning
// toward sleep and muscle looks the same whether those two are carrying the level or merely happen to
// be the two that were measured; "strong sleep and training volume, but your lungs are giving back four
// points" is the sentence a shape cannot make.
//
// REWRITTEN WHEN THE LEVEL MOVES, and at most once a day. The note is keyed to a fingerprint of the day
// and the rounded figures, so a level that has not changed returns the stored line without touching the
// model — and a new day, or a new level, writes a new one. That is what the wearer asked for: a fresh
// comment with each new level.
//
// IT IS HANDED THE ARITHMETIC, NOT ASKED TO DO IT. Contribution and headroom are computed here, in
// points of final level, and the model's only job is the sentence. A language model multiplying scores
// by weights is a language model inventing a conclusion.

object LevelCoachNote {

    private const val KEY_TEXT = "level.note.text"
    private const val KEY_FINGERPRINT = "level.note.fingerprint"

    /** Two sentences at the head of a panel. Longer and it competes with the chart under it. */
    private const val MAX_CHARS = 240

    private const val QUESTION = "Comment on how my metrics are carrying my level right now."

    /** The stored line, but only when it was written for exactly this level on this day. */
    fun stored(context: Context, fingerprint: String): String? {
        val prefs = prefs(context)
        if (prefs.getString(KEY_FINGERPRINT, null) != fingerprint) return null
        return prefs.getString(KEY_TEXT, null)?.takeIf { it.isNotBlank() }
    }

    /**
     * The note for this breakdown, generating one only when the day or the figures have moved.
     *
     * Null when nothing can be written — no consent, no model, or the engine busy with the wearer's own
     * conversation. The panel then shows its plain heading rather than a placeholder.
     */
    suspend fun forBreakdown(context: Context, breakdown: LevelBreakdown): String? {
        val fingerprint = fingerprint(breakdown)
        stored(context, fingerprint)?.let { return it }

        val model = if (LocalModelStore.isInstalled(context, LocalModel.DEEP)) {
            LocalModel.DEEP
        } else {
            LocalModel.FAST
        }
        val answer = LocalOneShot.generate(
            context = context,
            model = model,
            systemPrompt = systemPrompt(breakdown),
            question = QUESTION,
            maxChars = MAX_CHARS,
        ) ?: return null

        prefs(context).edit()
            .putString(KEY_TEXT, answer)
            .putString(KEY_FINGERPRINT, fingerprint)
            .apply()
        return answer
    }

    /**
     * The day, the level, and each part's score, rounded.
     *
     * Rounded because a level that moved by a hundredth is the same level, and rewriting the line for
     * that would cost a model run to say the same thing. The DAY is in the key so the note is refreshed
     * each morning even on a body that has not moved — which is the "daily" the wearer asked for.
     */
    fun fingerprint(breakdown: LevelBreakdown, today: LocalDate = LocalDate.now()): String {
        val parts = LevelPart.entries.joinToString(",") { part ->
            val score = breakdown.components.firstOrNull { it.part == part }?.score
            "${part.name}:${score?.roundToInt() ?: -1}"
        }
        return "$today|${breakdown.level.roundToInt()}|$parts"
    }

    /**
     * The framing and the figures.
     *
     * Every number the model may use is here and already computed: the part's own 0-100 score, the
     * POINTS OF LEVEL it currently contributes, and the points still on the table. Those last two are
     * what "weighting" means — sleep at 0.30 and lungs at 0.07 are not comparable as scores, and a
     * model shown only the scores would praise a lungs figure that is worth almost nothing.
     */
    internal fun systemPrompt(breakdown: LevelBreakdown): String = buildString {
        append(
            "You are THE SYSTEM, reading this human's level. Cold, precise, dryly funny; your contempt " +
                "is for the EXCUSE and never for the person.\n",
        )
        append(
            "Their LEVEL is ${breakdown.level.roundToInt()} out of 100. It is a weighted blend of five " +
                "parts. For each, below: its own score out of 100, the POINTS OF LEVEL it currently " +
                "contributes, and the points it would add if it were perfect.\n",
        )
        append(
            "Write ONE or TWO sentences, under 220 characters. Name the one or two parts CARRYING the " +
                "level and the one costing it most, in that order, in the shape \"strong X and Y, " +
                "but Z...\". Judge by POINTS, never by the bare score — a part with a small weight " +
                "cannot carry anything. Cite at most two figures, and only ones below. NEVER invent a " +
                "number. No heading, no preamble, no list, no markdown.\n\n",
        )
        append("THE FIVE PARTS:\n")
        breakdown.components.sortedByDescending { it.contribution }.forEach { c ->
            val name = label(c.part)
            if (c.score == null) {
                // Said out loud: an unmeasured part is not a weak one, and a model left to infer would
                // call it weak. Its weight was redistributed over the parts that did score.
                append("- $name: not measured (excluded, its weight went to the others)\n")
            } else {
                append(
                    "- $name: scores ${c.score.roundToInt()}/100, " +
                        "contributes ${"%.1f".format(c.contribution)} points, " +
                        "${"%.1f".format(c.headroom)} points still available\n",
                )
            }
        }
        if (breakdown.stepPenalty < 1.0) {
            val lost = (breakdown.raw - breakdown.level)
            append("STEP PENALTY: ${"%.1f".format(lost)} points lost for a day under the step floor.\n")
        }
    }

    private fun label(part: LevelPart): String = when (part) {
        LevelPart.SLEEP -> "sleep"
        LevelPart.HEART -> "heart"
        LevelPart.LUNGS -> "lungs"
        LevelPart.MUSCLE -> "training volume"
        LevelPart.FOCUS -> "focus"
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
}
