package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate
import kotlin.math.abs

// MARK: - Streaks
//
// How many days in a row a thing has held. The oldest gamification mechanic there is, and it works for
// the same reason it always has: a number you do not want to reset is a stronger argument than any
// amount of advice.
//
// EVERY STREAK HERE IS COMPUTED FROM A MEASURED FIGURE, never from an intention. "Bed on time" is the
// spread of actual sleep onsets, not a bedtime the wearer once typed in; "moved" is step counts. A
// streak the app awards for opening the app would be the kind of fake number this codebase does not
// ship — it looks the same on screen and means nothing.
//
// A DAY WITH NO DATA BREAKS NOTHING AND EXTENDS NOTHING. The strap comes off, the phone dies, a sync
// fails. Counting a missing day as a failure punishes the wearer for the app's gaps; counting it as a
// success invents a day that was never measured. So it is skipped, and the streak spans it.

/** One streak: what it measures, how long it is running, and whether today is already secured. */
data class Streak(
    val kind: StreakKind,
    val days: Int,
    /** True when today's own reading already satisfies the rule — the flame is lit, not at risk. */
    val todaySecured: Boolean,
)

enum class StreakKind {
    /** Falling asleep at a consistent hour. The single best predictor of how the rest reads. */
    SLEEP_REGULARITY,

    /** Seven hours or more, actually slept. */
    SLEEP_DURATION,

    /** A day that involved moving. */
    MOVEMENT,
}

object Streaks {

    /** Sleep onsets within this many minutes of the wearer's own median count as "on time". */
    const val REGULARITY_TOLERANCE_MIN = 60.0

    /** The duration bar, in hours. Not eight: eight is a slogan, seven is the floor most adults need. */
    const val DURATION_TARGET_HOURS = 7.0

    /** Steps that make a day count as moved. Low on purpose — this is a floor, not a goal. */
    const val MOVEMENT_TARGET_STEPS = 5_000

    /**
     * Every streak worth showing, longest first.
     *
     * [days] is oldest-first, as [com.noop.data.WhoopRepository.daysMerged] returns it. A streak of
     * zero is still returned: the row that says "no streak yet" is how the wearer learns the streak
     * exists at all, and hiding it until it is non-zero means it is never discovered.
     */
    fun evaluate(
        days: List<DailyMetric>,
        // Sleep ONSET is not on DailyMetric — the schema stores durations, not timestamps — so the
        // caller supplies it from the sleep sessions, keyed by local day (`yyyy-MM-dd`) as minutes
        // since midnight. Absent, the regularity streak is simply not offered: an onset guessed from a
        // duration would be a fabricated figure, and a streak built on one would be worse than none.
        onsetByDay: Map<String, Int> = emptyMap(),
        today: LocalDate = LocalDate.now(),
    ): List<Streak> {
        if (days.isEmpty()) return emptyList()
        return listOfNotNull(
            regularity(days, onsetByDay, today),
            duration(days, today),
            movement(days, today),
        ).sortedByDescending { it.days }
    }

    /**
     * Bed at a consistent hour.
     *
     * Measured against the wearer's OWN median onset over the window, not a clock time someone else
     * chose: a shift worker with a rock-solid 03:00 bedtime is regular, and telling them otherwise
     * would be the app imposing a lifestyle rather than reading one.
     */
    private fun regularity(
        days: List<DailyMetric>,
        onsetByDay: Map<String, Int>,
        today: LocalDate,
    ): Streak? {
        // Three nights is the minimum from which "their usual bedtime" means anything. Below that the
        // streak is not shown at all rather than shown as zero — a zero implies a rule was broken.
        if (onsetByDay.size < 3) return null
        val median = onsetByDay.values.sorted().let { it[it.size / 2] }
        return countBack(days, today) { d ->
            onsetByDay[d.day]?.let { clockDistance(it, median) <= REGULARITY_TOLERANCE_MIN }
        }.let { (n, secured) -> Streak(StreakKind.SLEEP_REGULARITY, n, secured) }
    }

    private fun duration(days: List<DailyMetric>, today: LocalDate): Streak =
        countBack(days, today) { d ->
            d.totalSleepMin?.let { it / 60.0 >= DURATION_TARGET_HOURS }
        }.let { (n, secured) -> Streak(StreakKind.SLEEP_DURATION, n, secured) }

    private fun movement(days: List<DailyMetric>, today: LocalDate): Streak =
        countBack(days, today) { d ->
            // Steps OR a logged effort: a two-hour ride puts up almost no steps and is obviously not a
            // sedentary day, and a streak that says otherwise is a streak the wearer stops believing.
            val stepped = d.steps?.let { it >= MOVEMENT_TARGET_STEPS }
            val trained = d.strain?.let { it >= 8.0 }
            when {
                stepped == true || trained == true -> true
                stepped == null && trained == null -> null
                else -> false
            }
        }.let { (n, secured) -> Streak(StreakKind.MOVEMENT, n, secured) }

    /**
     * Walk backwards from today counting days that satisfy [holds], stopping at the first that does not.
     *
     * [holds] returns null for "not measured", which neither breaks nor extends — see the note at the
     * top of this file. Today itself is allowed to be unsatisfied without breaking the streak: the day
     * is not over, and a streak that reads zero every morning until you have moved is a streak that
     * feels broken all day. `todaySecured` is what says whether it is banked or still at risk.
     */
    private fun countBack(
        days: List<DailyMetric>,
        today: LocalDate,
        holds: (DailyMetric) -> Boolean?,
    ): Pair<Int, Boolean> {
        val byDay = days.associateBy { it.day }
        val todaysVerdict = byDay[today.toString()]?.let(holds)
        var count = 0
        // Start at today when today already qualifies, otherwise at yesterday: an unfinished day must
        // not be counted as a failure.
        var cursor = if (todaysVerdict == true) today else today.minusDays(1)
        var guard = 0
        while (guard++ < MAX_LOOKBACK_DAYS) {
            val metric = byDay[cursor.toString()]
            when (metric?.let(holds)) {
                true -> count++
                false -> return count to (todaysVerdict == true)
                null -> Unit  // unmeasured: span it
            }
            cursor = cursor.minusDays(1)
        }
        return count to (todaysVerdict == true)
    }

    /** A year. Past this the number stops being motivating and starts being decoration. */
    private const val MAX_LOOKBACK_DAYS = 365

    /**
     * Distance between two minute-of-day values, THE SHORT WAY ROUND THE CLOCK.
     *
     * 23:50 and 00:10 are twenty minutes apart, not 1,420. Every naive version of this file gets that
     * wrong, and it gets it wrong precisely for the people whose bedtime sits near midnight — which is
     * most of them.
     */
    internal fun clockDistance(a: Int, b: Int): Double {
        val raw = abs(a - b).toDouble()
        return minOf(raw, MINUTES_PER_DAY - raw)
    }

    private const val MINUTES_PER_DAY = 1440.0
}
