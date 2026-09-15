package com.noop.ai

import android.content.Context

// MARK: - What the wearer is actually training for
//
// Free text, written by the wearer, handed to the coach as context on EVERY session. Not a structured
// goal model with a target, a deadline and a progress bar: the things people actually want are
// sentences ("get back under 20 min for 5k without wrecking my sleep", "stop skipping legs"), and a
// schema would have forced those into fields that lose the point.
//
// It is also the only place the coach learns anything the numbers cannot tell it. Charge, effort and
// sleep say how the body is; the goal says what it is FOR, and advice without it is generic by
// construction. The daily mission is generated from this plus the day's metrics, which is why a blank
// goal produces a noticeably blander mission.

object CoachGoals {

    private const val KEY = "coach.goals"

    /** Bounded because it rides in the system prompt, and every character there is prompt-processing time. */
    const val MAX_CHARS = 600

    fun read(context: Context): String =
        prefs(context).getString(KEY, null)?.trim().orEmpty()

    fun write(context: Context, text: String) {
        val clean = text.trim().take(MAX_CHARS)
        prefs(context).edit().apply {
            if (clean.isEmpty()) remove(KEY) else putString(KEY, clean)
        }.apply()
    }

    /**
     * The goal block for the system prompt, or null when nothing is set.
     *
     * Null rather than a placeholder: "the user has not set a goal" is a sentence the model would then
     * coach about, and the absence of a goal is not a thing to be coached about.
     */
    fun promptSection(context: Context): String? {
        val goals = read(context)
        if (goals.isEmpty()) return null
        return "THEIR GOALS, in their own words — everything you advise should serve these:\n$goals"
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
}
