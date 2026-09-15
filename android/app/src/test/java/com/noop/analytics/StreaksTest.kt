package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * The three streaks.
 *
 * WHAT MATTERS HERE IS THE GAP RULE. A day with no data neither breaks a streak nor extends it — the
 * strap comes off, a sync fails, the phone dies. Counting a missing day as a failure punishes the wearer
 * for the app's own gaps; counting it as a success invents a day nobody measured. Nearly every bug this
 * file could have is a variation on getting that wrong, so most of these are about absence.
 *
 * The second thing is that TODAY IS NOT YET A FAILURE. A streak that reads zero every morning until the
 * day is secured is a streak that feels broken all day, so an unsatisfied today is simply not counted,
 * and `todaySecured` is what says whether it is banked.
 */
class StreaksTest {

    private val today = LocalDate.of(2026, 9, 15)

    private fun day(date: LocalDate, sleepMin: Double?) =
        DailyMetric(deviceId = "d", day = date.toString(), totalSleepMin = sleepMin)

    /** [n] days ending today, every night the same length. */
    private fun steady(n: Int, hours: Double): List<DailyMetric> =
        (n - 1 downTo 0).map { back -> day(today.minusDays(back.toLong()), hours * 60.0) }

    private fun kinds(streaks: List<Streak>) = streaks.map { it.kind }

    private fun of(streaks: List<Streak>, kind: StreakKind) = streaks.first { it.kind == kind }

    // --- what is offered at all ---

    @Test
    fun exactlyTheThreeRulesAreOfferedAndAlwaysInTheSameOrder() {
        // The strip is three fixed columns and the wearer learns which flame is which by POSITION.
        // Sorting by length — which the previous cut did — makes the row unreadable at a glance, which
        // is the only way it is ever read.
        val expected = listOf(
            StreakKind.SLEEP_CONSISTENCY,
            StreakKind.SLEEP_DEBT,
            StreakKind.STRESS_TIME,
        )
        assertEquals(expected, kinds(Streaks.evaluate(steady(30, 8.0), today = today)))
        assertEquals(expected, kinds(Streaks.evaluate(steady(3, 4.0), today = today)))
    }

    @Test
    fun noDaysAtAllOffersNothing() {
        assertTrue(Streaks.evaluate(emptyList(), today = today).isEmpty())
    }

    // --- sleep consistency > 80 % ---

    @Test
    fun steadyNightsHoldTheConsistencyStreak() {
        val s = of(Streaks.evaluate(steady(30, 8.0), today = today), StreakKind.SLEEP_CONSISTENCY)
        assertTrue("a month of identical nights must be a streak", s.days >= 20)
        assertTrue(s.todaySecured)
    }

    @Test
    fun wildlyVaryingNightsHoldNothing() {
        val erratic = (29 downTo 0).map { back ->
            day(today.minusDays(back.toLong()), if (back % 2 == 0) 3.0 * 60 else 10.0 * 60)
        }
        val s = of(Streaks.evaluate(erratic, today = today), StreakKind.SLEEP_CONSISTENCY)
        assertEquals(0, s.days)
        assertFalse(s.todaySecured)
    }

    @Test
    fun twoNightsAreNotAConsistencyReading() {
        // Consistency over two nights is not a number, so those days are UNMEASURED rather than
        // failures — the engine's floor is three. A streak awarded on two nights would be one nobody
        // earned; a streak broken on two would punish somebody for having just installed the app.
        val s = of(Streaks.evaluate(steady(2, 8.0), today = today), StreakKind.SLEEP_CONSISTENCY)
        assertEquals(0, s.days)
        assertFalse(s.todaySecured)
    }

    // --- sleep debt < 1h ---

    @Test
    fun sleepingTheNeedEveryNightKeepsTheDebtStreakLit() {
        val s = of(
            Streaks.evaluate(steady(20, Streaks.SLEEP_NEED_HOURS), today = today),
            StreakKind.SLEEP_DEBT,
        )
        assertTrue(s.days >= 15)
        assertTrue(s.todaySecured)
    }

    @Test
    fun aFortnightOfShortNightsBreaksTheDebtStreak() {
        // Six hours against a seven-hour need is an hour a night: the balance passes the limit on the
        // second night and never comes back.
        val s = of(Streaks.evaluate(steady(20, 6.0), today = today), StreakKind.SLEEP_DEBT)
        assertEquals(0, s.days)
        assertFalse(s.todaySecured)
    }

    @Test
    fun aSurplusIsNotCredit() {
        // Ten-hour nights do not bank hours against a future short one in any model worth quoting, so a
        // net-positive balance reads as NO DEBT rather than as a buffer.
        val s = of(Streaks.evaluate(steady(20, 10.0), today = today), StreakKind.SLEEP_DEBT)
        assertTrue(s.days >= 15)
    }

    @Test
    fun oneHalfHourShortfallIsInsideTheHour() {
        val nights = steady(20, Streaks.SLEEP_NEED_HOURS).toMutableList()
        nights[nights.size - 3] = day(today.minusDays(2), (Streaks.SLEEP_NEED_HOURS - 0.5) * 60.0)
        val s = of(Streaks.evaluate(nights, today = today), StreakKind.SLEEP_DEBT)
        assertTrue("a single half-hour shortfall is under the limit", s.days >= 3)
    }

    // --- non-activity stress < 6h ---

    @Test
    fun calmDaysHoldTheStressStreak() {
        val days = steady(10, 8.0)
        val stress = days.associate { it.day to 60.0 }
        val s = of(
            Streaks.evaluate(days, stressMinutesByDay = stress, today = today),
            StreakKind.STRESS_TIME,
        )
        assertEquals(10, s.days)
        assertTrue(s.todaySecured)
    }

    @Test
    fun aDayOverTheLimitBreaksIt() {
        val days = steady(10, 8.0)
        val stress = days.associate { it.day to 60.0 }.toMutableMap()
        stress[today.minusDays(3).toString()] = Streaks.STRESS_LIMIT_MIN + 1
        val s = of(
            Streaks.evaluate(days, stressMinutesByDay = stress, today = today),
            StreakKind.STRESS_TIME,
        )
        assertEquals(3, s.days)
    }

    @Test
    fun exactlyTheLimitIsOverIt() {
        // The rule the wearer stated is "under six hours". Six hours is not under six hours, and a
        // boundary that quietly rounds in the wearer's favour is a boundary that means nothing.
        val days = steady(4, 8.0)
        val stress = days.associate { it.day to Streaks.STRESS_LIMIT_MIN }
        val s = of(
            Streaks.evaluate(days, stressMinutesByDay = stress, today = today),
            StreakKind.STRESS_TIME,
        )
        assertEquals(0, s.days)
    }

    @Test
    fun daysWithNoBankedStressNeitherBreakNorExtend() {
        // THE GAP DOCTRINE, on the streak most exposed to it: the figure is only banked on days the
        // stress read actually ran, so most history has no row at all. Those days must SPAN, not fail —
        // otherwise the streak reads zero forever for a wearer who has simply not opened that screen.
        val days = steady(10, 8.0)
        val stress = mapOf(
            today.toString() to 30.0,
            today.minusDays(9).toString() to 30.0,
        )
        val s = of(
            Streaks.evaluate(days, stressMinutesByDay = stress, today = today),
            StreakKind.STRESS_TIME,
        )
        assertEquals("both measured days count, the eight unmeasured ones span", 2, s.days)
        assertTrue(s.todaySecured)
    }

    // --- today is not yet a failure ---

    @Test
    fun anUnsecuredTodayDoesNotBreakYesterdaysStreak() {
        val days = steady(6, 8.0)
        val stress = days.associate { it.day to 30.0 }.toMutableMap()
        // Today has already blown the budget; the days before it stand.
        stress[today.toString()] = Streaks.STRESS_LIMIT_MIN + 120
        val s = of(
            Streaks.evaluate(days, stressMinutesByDay = stress, today = today),
            StreakKind.STRESS_TIME,
        )
        assertEquals(5, s.days)
        assertFalse("today is not banked", s.todaySecured)
    }
}
