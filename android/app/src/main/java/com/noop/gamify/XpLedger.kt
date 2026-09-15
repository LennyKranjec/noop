package com.noop.gamify

import android.content.Context

// MARK: - XP that was actually earned
//
// [AccountLevel] was a placeholder: a constant 15 and an XP figure derived from it, so the bar showed a
// plausible fraction of nothing. This is the first real source — XP claimed from a completed daily
// mission — and it is kept apart from the placeholder on purpose. The level the wearer sees is the
// provisional floor PLUS what this holds, so on a fresh install the badge still reads 15 and every
// point above that line was genuinely earned.
//
// CLAIMED ONCE, EVER. Each award carries a key (the mission's day, "mission-2026-09-15"); the key is
// recorded and a second claim under the same key adds nothing. Without that, reopening the app and
// tapping the same finished mission would print XP, which would make the number meaningless — and a
// gamified figure that can be farmed by tapping is worse than no figure.

object XpLedger {

    private const val KEY_TOTAL = "xp.earnedTotal"
    private const val KEY_CLAIMED = "xp.claimedKeys"

    /** How many claim keys are remembered. Oldest fall off; a months-old mission cannot be re-claimed
     *  anyway because its day is gone from the mission store. */
    private const val MAX_CLAIMED_KEYS = 120

    /** Total XP earned, across everything that awards it. Never negative. */
    fun earned(context: Context): Int = prefs(context).getInt(KEY_TOTAL, 0).coerceAtLeast(0)

    fun isClaimed(context: Context, key: String): Boolean = claimedKeys(context).contains(key)

    /**
     * Add [amount] XP under [key], unless that key has already been claimed.
     *
     * Returns true when the award actually happened, so the caller can decide whether to celebrate.
     * [amount] is clamped: the figure originates from a language model, and an award of 100000 would
     * end the level system in one tap.
     */
    fun award(context: Context, key: String, amount: Int): Boolean {
        if (key.isBlank() || amount <= 0) return false
        if (isClaimed(context, key)) return false
        val keys = (claimedKeys(context) + key).takeLast(MAX_CLAIMED_KEYS)
        prefs(context).edit()
            .putInt(KEY_TOTAL, earned(context) + amount.coerceAtMost(MAX_AWARD))
            .putString(KEY_CLAIMED, keys.joinToString(","))
            .apply()
        return true
    }

    /** The most a single award may be worth. A day's work, not a level. */
    const val MAX_AWARD = 200

    private fun claimedKeys(context: Context): List<String> =
        prefs(context).getString(KEY_CLAIMED, null)
            ?.split(',')
            ?.filter { it.isNotBlank() }
            ?: emptyList()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)
}
