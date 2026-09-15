package com.noop.gamify

import android.content.Context
import kotlin.math.pow

// MARK: - Account level and XP
//
// HALF PROVISIONAL, HALF REAL. The starting position is still a fixed level 15 parked partway through
// it — nothing about the wearer's history has been measured. But XP claimed from a finished daily
// mission IS real, lives in [XpLedger], and is added on top. A fresh install therefore reads exactly
// 15, and every point above that line was earned by finishing something.
//
// So the level is now DERIVED from the total rather than asserted: claim enough missions and the badge
// moves, which is the only thing that makes showing it worth anything. The provisional half must still
// never be presented as a claim about the wearer's past — it is a starting position, not a history.
//
// READ THE [Context] OVERLOADS on anything the wearer looks at, so their earned XP is included. The
// no-argument ones are the baseline, kept for the pure-math call sites and the unit tests.

object AccountLevel {

    /** The curve: cumulative XP needed to REACH [level]. Level 1 is zero. */
    fun xpForLevel(level: Int): Int =
        if (level <= 1) 0 else (BASE * (level - 1).toDouble().pow(EXPONENT)).toInt()

    private const val BASE = 120.0
    private const val EXPONENT = 1.45

    private const val PROVISIONAL_LEVEL = 15
    private const val PROVISIONAL_PROGRESS = 0.42

    /** The baseline XP total: level 15, partway through. What a fresh install starts from. */
    fun baselineXp(): Int {
        val floor = xpForLevel(PROVISIONAL_LEVEL)
        val ceiling = xpForLevel(PROVISIONAL_LEVEL + 1)
        return floor + ((ceiling - floor) * PROVISIONAL_PROGRESS).toInt()
    }

    /** Everything the level surfaces need, resolved once so a bar and its badge cannot disagree. */
    data class Standing(
        val level: Int,
        val totalXp: Int,
        val xpIntoLevel: Int,
        val xpSpanOfLevel: Int,
        val earnedXp: Int,
    ) {
        /** 0–1 through the current level. */
        val progress: Float get() = (xpIntoLevel.toFloat() / xpSpanOfLevel).coerceIn(0f, 1f)

        /** XP still to go before the next level. Never negative. */
        val xpToNextLevel: Int get() = (xpSpanOfLevel - xpIntoLevel).coerceAtLeast(0)
    }

    /** The wearer's standing: baseline plus whatever they have actually earned. */
    fun standing(context: Context): Standing = standingFor(baselineXp() + XpLedger.earned(context))
        .copy(earnedXp = XpLedger.earned(context))

    /** The standing a given XP total produces. Pure, so the curve has a test without a Context. */
    fun standingFor(totalXp: Int): Standing {
        val level = levelForXp(totalXp)
        val floor = xpForLevel(level)
        return Standing(
            level = level,
            totalXp = totalXp,
            xpIntoLevel = totalXp - floor,
            xpSpanOfLevel = (xpForLevel(level + 1) - floor).coerceAtLeast(1),
            earnedXp = 0,
        )
    }

    /**
     * The highest level whose threshold [totalXp] has reached.
     *
     * Walked rather than solved: the inverse of `BASE * (l-1)^EXPONENT` is a `pow` that rounds the
     * wrong way at exactly the boundaries where a wearer is watching, and the loop is over tens of
     * iterations. Capped so a corrupted XP total cannot spin here.
     */
    fun levelForXp(totalXp: Int): Int {
        var level = 1
        while (level < MAX_LEVEL && xpForLevel(level + 1) <= totalXp) level++
        return level
    }

    private const val MAX_LEVEL = 999

    // The provisional-baseline overloads. Equivalent to `standingFor(baselineXp())`.

    fun level(): Int = PROVISIONAL_LEVEL

    fun currentXp(): Int = baselineXp()

    /** XP earned since the current level began. */
    fun xpIntoLevel(): Int = currentXp() - xpForLevel(level())

    /** XP still to go before the next level. Never negative. */
    fun xpToNextLevel(): Int = (xpForLevel(level() + 1) - currentXp()).coerceAtLeast(0)

    /** The span of the current level, i.e. the bar's denominator. */
    fun xpSpanOfLevel(): Int = (xpForLevel(level() + 1) - xpForLevel(level())).coerceAtLeast(1)

    /** 0–1 through the current level. */
    fun progress(): Float = (xpIntoLevel().toFloat() / xpSpanOfLevel()).coerceIn(0f, 1f)
}
