package com.noop.ai

import android.content.Context
import com.noop.analytics.MuscleBaseline
import com.noop.ingest.MuscleGroup
import kotlin.math.roundToInt

// MARK: - What the system makes of the body chart
//
// One or two sentences under the muscle figure, written by the model from the SAME numbers the figure
// is drawn from: this week's volume per group, and how unusual that is for each group against its own
// frozen normal.
//
// WRITTEN WHEN THE DATA MOVES, NOT WHEN THE SCREEN OPENS. The note is keyed to a fingerprint of the
// loads it was written for. Identical loads return the stored note without touching the model — which
// is what makes this affordable on a card that composes every time Today is opened — and a new
// Alphaprog import changes every group's figure at once, so the note is rewritten exactly then.
//
// IT IS HANDED THE Z-SCORES, NOT ASKED TO DERIVE THEM. A language model doing arithmetic on kilograms
// is a language model inventing a conclusion; the app already knows which groups are above and below
// their own normal, so it says so and the model's only job is the sentence. Groups with no frozen
// baseline yet are given as raw volume and labelled as such, so the model cannot call something
// "below normal" when no normal exists.
//
// NO NOTE IS A VALID OUTCOME. No consent, no model installed, the engine busy with the wearer's own
// chat, or an empty answer — all return null, and the panel simply does not appear. A generic line of
// encouragement standing in for a reading would be the dishonest option.

object MuscleCoachNote {

    private const val KEY_TEXT = "muscle.note.text"
    private const val KEY_FINGERPRINT = "muscle.note.fingerprint"

    /**
     * Room for a real reading, not a caption.
     *
     * The first cut capped this at 180 characters, which bought one sentence and a clipped second — the
     * model had to choose between naming the group and saying what to do about it. The panel now takes
     * ALL the room the legend leaves, which on a nine-row side is most of the column, so this is length
     * the card can actually show rather than text it will cut.
     */
    private const val MAX_CHARS = 620

    private val QUESTION = "Which muscle group most needs attention this week, and what should they do?"

    /**
     * The note for these loads, generating one only when they differ from what was last written.
     *
     * Returns null when nothing can be written; the caller shows no panel rather than a placeholder.
     */
    suspend fun forLoads(
        context: Context,
        loads: Map<MuscleGroup, Double>,
        baselines: Map<MuscleGroup, MuscleBaseline>,
    ): String? {
        if (loads.isEmpty()) return null
        val fingerprint = fingerprint(loads)
        stored(context, fingerprint)?.let { return it }

        val model = if (LocalModelStore.isInstalled(context, LocalModel.DEEP)) {
            LocalModel.DEEP
        } else {
            LocalModel.FAST
        }
        val answer = LocalOneShot.generate(
            context = context,
            model = model,
            systemPrompt = systemPrompt(loads, baselines),
            question = QUESTION,
            maxChars = MAX_CHARS,
        ) ?: return null

        write(context, answer, fingerprint)
        return answer
    }

    /** The stored note, but only when it was written for exactly these loads. */
    fun stored(context: Context, fingerprint: String): String? {
        val prefs = prefs(context)
        if (prefs.getString(KEY_FINGERPRINT, null) != fingerprint) return null
        return prefs.getString(KEY_TEXT, null)?.takeIf { it.isNotBlank() }
    }

    /**
     * A stable digest of the loads, rounded to the kilogram.
     *
     * Rounded because a float that differs in its last bits is the same training week, and a note
     * rewritten for that would cost a model run and say the same thing.
     */
    fun fingerprint(loads: Map<MuscleGroup, Double>): String =
        loads.entries
            .sortedBy { it.key.name }
            .joinToString(",") { "${it.key.name}:${it.value.roundToInt()}" }
            .hashCode()
            .toString()

    /**
     * The framing and the figures, as one block.
     *
     * Every number the model is allowed to use is in here, already computed. The instruction not to
     * invent one is the same instruction the chat gets, and for the same reason.
     */
    internal fun systemPrompt(
        loads: Map<MuscleGroup, Double>,
        baselines: Map<MuscleGroup, MuscleBaseline>,
    ): String = buildString {
        append(
            "You are THE SYSTEM, reading this human's training log. Your tone is cold, precise and " +
                "dryly funny, and your contempt is for the EXCUSE, never for the person.\n",
        )
        append(
            "Below is the last seven days of lifting volume per muscle group. Where a group has a " +
                "frozen personal normal, its z-score says how unusual this week is FOR THAT GROUP: 0 is " +
                "a normal week, +2 is unusually heavy, -2 unusually light.\n",
        )
        append(
            "Answer in ONE or TWO short sentences, under 180 characters total. Name the group that " +
                "most needs attention and say what to do about it this week. Cite at most one figure, " +
                "and only one that appears below. NEVER invent a number. No heading, no preamble, no " +
                "list, no markdown.\n\n",
        )
        append("VOLUME, LAST 7 DAYS:\n")
        loads.entries.sortedByDescending { it.value }.forEach { (group, kg) ->
            val baseline = baselines[group]
            if (baseline != null) {
                val z = baseline.z(kg)
                append("- ${label(group)}: ${kg.roundToInt()} kg (z ${fmt(z)})\n")
            } else {
                // Said explicitly: without a frozen normal there is nothing to be unusual against, and a
                // model left to guess would happily call it "low".
                append("- ${label(group)}: ${kg.roundToInt()} kg (no personal normal yet)\n")
            }
        }
        // The groups that got NOTHING are the interesting ones, and they are absent from the map above
        // rather than present at zero — so they are named here or they cannot be mentioned at all.
        val untouched = MuscleGroup.entries.filter { it !in loads.keys }
        if (untouched.isNotEmpty()) {
            append("NOT TRAINED AT ALL THIS WEEK: ")
            append(untouched.joinToString(", ") { label(it) })
            append("\n")
        }
    }

    private fun fmt(z: Double): String = String.format(java.util.Locale.US, "%+.1f", z)

    /** Plain English names, so the prompt does not hand the model SCREAMING_SNAKE_CASE to echo back. */
    private fun label(group: MuscleGroup): String = group.name.lowercase().replace('_', ' ')

    private fun write(context: Context, text: String, fingerprint: String) {
        prefs(context).edit()
            .putString(KEY_TEXT, text)
            .putString(KEY_FINGERPRINT, fingerprint)
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
}
