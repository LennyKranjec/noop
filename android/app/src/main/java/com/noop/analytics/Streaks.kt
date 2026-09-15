package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate

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

/**
 * The three streaks, and nothing else.
 *
 * Each is a rule the wearer named, each is a threshold on a figure the app already computes, and none
 * of them can be satisfied by using the app. A fourth would dilute the row: three flames fit across a
 * thin strip, and three things are the most anybody actually holds in mind.
 */
enum class StreakKind {
    /** Sleep CONSISTENCY at or above 80 %: the spread of four weeks of nights, not one night. */
    SLEEP_CONSISTENCY,

    /** Sleep DEBT under an hour: the rolling ledger, not a single short night. */
    SLEEP_DEBT,

    /** Under six hours of high stress that was NOT exercise. */
    STRESS_TIME,
}

object Streaks {

    /** Consistency at or above this holds the streak, on the 0-100 scale [VitalityEngine] produces. */
    const val CONSISTENCY_TARGET_PCT = 80.0

    /** How many nights the consistency figure is measured over. Four weeks, as everywhere else here. */
    const val CONSISTENCY_WINDOW_NIGHTS = 28

    /** Debt below this holds the streak. An hour is a late film, not a deficit worth acting on. */
    const val DEBT_LIMIT_MIN = 60.0

    /**
     * Nightly need the debt balance is measured against.
     *
     * The same seven hours the rest of the app treats as the adult floor. Held here rather than read
     * from a profile because a personal need the wearer has never set would be a default wearing a
     * personal label.
     */
    const val SLEEP_NEED_HOURS = 7.0

    /**
     * High stress below this many minutes holds the streak.
     *
     * NON-ACTIVITY by construction, not by subtraction: [DaytimeStress] masks ambulatory hours as
     * exertion and leaves them unscored, so the minutes counted here are already only the ones where
     * the wearer was still and the autonomic load was high anyway. A hard session does not spend this
     * budget, which is the whole point of the rule.
     */
    const val STRESS_LIMIT_MIN = 6 * 60.0

    /**
     * Every streak worth showing, longest first.
     *
     * [days] is oldest-first, as [com.noop.data.WhoopRepository.daysMerged] returns it. A streak of
     * zero is still returned: the row that says "no streak yet" is how the wearer learns the streak
     * exists at all, and hiding it until it is non-zero means it is never discovered.
     */
    fun evaluate(
        days: List<DailyMetric>,
        /**
         * Minutes of NON-ACTIVITY high stress per local day, as the stress read banked them.
         *
         * Supplied rather than derived: the figure costs a whole day of heart rate and R-R to compute,
         * so recomputing it across a year of history inside a card is not an option. A day with no
         * banked row is unmeasured, which neither breaks nor extends - the rule every gap here follows.
         */
        stressMinutesByDay: Map<String, Double> = emptyMap(),
        today: LocalDate = LocalDate.now(),
    ): List<Streak> {
        if (days.isEmpty()) return emptyList()
        // FIXED ORDER, not sorted by length. The strip is three fixed columns and the wearer learns
        // which flame is which by position; re-ordering them as the numbers move would make the row
        // unreadable at a glance, which is the only way it is ever read.
        return listOf(
            consistency(days, today),
            debt(days, today),
            stressTime(days, stressMinutesByDay, today),
        )
    }

    /**
     * Sleep consistency at or above 80 %.
     *
     * The figure for a day is the spread of the [CONSISTENCY_WINDOW_NIGHTS] nights ENDING on it, which
     * is how the level's own sleep term reads it - so the streak and the level cannot disagree about
     * whether a stretch was regular. A day with fewer than three nights behind it is unmeasured rather
     * than a failure: consistency over two nights is not a number.
     */
    private fun consistency(days: List<DailyMetric>, today: LocalDate): Streak {
        val index = days.withIndex().associate { (i, d) -> d.day to i }
        return countBack(days, today) { d ->
            val i = index[d.day]
            if (i == null) {
                null
            } else {
                val window = days.subList(maxOf(0, i - (CONSISTENCY_WINDOW_NIGHTS - 1)), i + 1)
                    .mapNotNull { it.totalSleepMin?.div(60.0) }
                VitalityEngine.sleepConsistency(window)?.let { it * 100.0 >= CONSISTENCY_TARGET_PCT }
            }
        }.let { (n, secured) -> Streak(StreakKind.SLEEP_CONSISTENCY, n, secured) }
    }

    /**
     * Sleep debt under an hour.
     *
     * Read as the balance stood ON each day - the rolling shortfall of the fortnight before it, not
     * today's balance applied backwards. A streak computed from one current figure would light or break
     * every day at once, which is not a streak.
     *
     * Only the SHORTFALL counts. Surplus nights do not repay debt hour for hour in any model worth
     * quoting, so a balance that nets positive reads as no debt rather than as credit.
     */
    private fun debt(days: List<DailyMetric>, today: LocalDate): Streak {
        val index = days.withIndex().associate { (i, d) -> d.day to i }
        return countBack(days, today) { d ->
            val i = index[d.day]
            if (i == null) {
                null
            } else {
                val window = days.subList(maxOf(0, i - (SleepDebt.DEFAULT_WINDOW_NIGHTS - 1)), i + 1)
                val slept = window.mapNotNull { n -> n.totalSleepMin?.takeIf { it > 0.0 } }
                // Three nights is the fewest a rolling balance means anything over. Below that the day
                // is unmeasured rather than debt-free, which would hand out a streak nobody earned.
                if (slept.size < 3) {
                    null
                } else {
                    val needMin = SLEEP_NEED_HOURS * 60.0
                    val balance = slept.sumOf { it - needMin }
                    (if (balance < 0.0) -balance else 0.0) < DEBT_LIMIT_MIN
                }
            }
        }.let { (n, secured) -> Streak(StreakKind.SLEEP_DEBT, n, secured) }
    }

    /** Under six hours of high stress that was not exercise. */
    private fun stressTime(
        days: List<DailyMetric>,
        stressMinutesByDay: Map<String, Double>,
        today: LocalDate,
    ): Streak = countBack(days, today) { d ->
        stressMinutesByDay[d.day]?.let { it < STRESS_LIMIT_MIN }
    }.let { (n, secured) -> Streak(StreakKind.STRESS_TIME, n, secured) }

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

}
