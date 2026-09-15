package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Streaks.
 *
 * Two rules carry the whole file, and both are the kind that are easy to get wrong in a way nobody
 * notices until a real user complains:
 *
 *   · A DAY WITH NO DATA neither breaks nor extends. The strap comes off; that is the app's gap, not
 *     the wearer's failure, and it is also not a day that can be credited.
 *   · MIDNIGHT IS NOT A WALL. 23:50 and 00:10 are twenty minutes apart. Get that wrong and the
 *     regularity streak breaks nightly for exactly the people whose bedtime sits near midnight.
 */
class StreaksTest {

    private val today = LocalDate.of(2026, 9, 15)

    private fun day(
        date: LocalDate,
        sleepMin: Double? = null,
        steps: Int? = null,
        strain: Double? = null,
    ) = DailyMetric(
        deviceId = "d",
        day = date.toString(),
        totalSleepMin = sleepMin,
        steps = steps,
        strain = strain,
    )

    private fun run(vararg days: DailyMetric) = Streaks.evaluate(days.toList(), today = today)

    private fun of(kind: StreakKind, vararg days: DailyMetric): Streak =
        run(*days).single { it.kind == kind }

    @Test
    fun midnightIsNotAWall() {
        // 23:50 = 1430, 00:10 = 10. Twenty minutes apart, not 1,420.
        assertEquals(20.0, Streaks.clockDistance(1430, 10), 0.001)
        assertEquals(20.0, Streaks.clockDistance(10, 1430), 0.001)
        assertEquals(0.0, Streaks.clockDistance(600, 600), 0.001)
        // The furthest two clock times can be is twelve hours.
        assertEquals(720.0, Streaks.clockDistance(0, 720), 0.001)
    }

    @Test
    fun consecutiveGoodNightsCount() {
        val days = (0..4).map { day(today.minusDays(it.toLong()), sleepMin = 8 * 60.0) }
        val streak = Streaks.evaluate(days, today = today).single { it.kind == StreakKind.SLEEP_DURATION }
        assertEquals(5, streak.days)
        assertTrue(streak.todaySecured)
    }

    @Test
    fun aShortNightEndsIt() {
        val days = listOf(
            day(today, sleepMin = 8 * 60.0),
            day(today.minusDays(1), sleepMin = 8 * 60.0),
            day(today.minusDays(2), sleepMin = 5 * 60.0),   // the break
            day(today.minusDays(3), sleepMin = 8 * 60.0),
        )
        assertEquals(2, Streaks.evaluate(days, today = today).single { it.kind == StreakKind.SLEEP_DURATION }.days)
    }

    @Test
    fun aDayWithNoDataIsSpannedRatherThanCountedEitherWay() {
        val days = listOf(
            day(today, sleepMin = 8 * 60.0),
            day(today.minusDays(1)),                        // strap was off: no reading at all
            day(today.minusDays(2), sleepMin = 8 * 60.0),
        )
        // Two measured nights, and the gap between them did not reset the count.
        assertEquals(2, Streaks.evaluate(days, today = today).single { it.kind == StreakKind.SLEEP_DURATION }.days)
    }

    @Test
    fun todayNotBeingDoneYetDoesNotReadAsABrokenStreak() {
        // At 09:00 nobody has hit their step count. A streak that reads zero every morning is a streak
        // that feels broken all day, so an unfinished today is excluded rather than failed.
        val days = listOf(
            day(today, steps = 200),
            day(today.minusDays(1), steps = 9_000),
            day(today.minusDays(2), steps = 9_000),
        )
        val streak = Streaks.evaluate(days, today = today).single { it.kind == StreakKind.MOVEMENT }
        assertEquals(2, streak.days)
        // …but it is honest about today not being banked.
        assertTrue(!streak.todaySecured)
    }

    @Test
    fun aHardSessionCountsAsMovementEvenWithAlmostNoSteps() {
        // Two hours on a bike puts up no steps. A movement streak that breaks on a ride is one the
        // wearer stops believing.
        val days = listOf(
            day(today, steps = 400, strain = 15.0),
            day(today.minusDays(1), steps = 9_000),
        )
        assertEquals(2, Streaks.evaluate(days, today = today).single { it.kind == StreakKind.MOVEMENT }.days)
    }

    @Test
    fun regularityIsMeasuredAgainstTheirOwnMedianBedtime() {
        val days = (0..4).map { day(today.minusDays(it.toLong()), sleepMin = 7.5 * 60) }
        // A rock-solid 03:00 sleeper is REGULAR. Judging them against a bedtime someone else picked
        // would be the app imposing a lifestyle rather than reading one.
        val onsets = days.associate { it.day to 3 * 60 }
        val streak = Streaks.evaluate(days, onsets, today).single { it.kind == StreakKind.SLEEP_REGULARITY }
        assertEquals(5, streak.days)
    }

    @Test
    fun regularityIsNotOfferedWithoutEnoughNightsToHaveAUsualBedtime() {
        val days = (0..4).map { day(today.minusDays(it.toLong()), sleepMin = 7.5 * 60) }
        // Two nights is not a habit. Showing a zero would imply a rule was broken; showing nothing is
        // the honest state.
        val onsets = mapOf(days[0].day to 1380, days[1].day to 1380)
        assertTrue(Streaks.evaluate(days, onsets, today).none { it.kind == StreakKind.SLEEP_REGULARITY })
    }

    @Test
    fun aWildlyDifferentNightBreaksRegularity() {
        val days = (0..4).map { day(today.minusDays(it.toLong()), sleepMin = 7.5 * 60) }
        val onsets = days.associate { it.day to 1380 }.toMutableMap()   // 23:00 every night
        onsets[days[2].day] = 240                                        // except one 04:00
        val streak = Streaks.evaluate(days, onsets, today).single { it.kind == StreakKind.SLEEP_REGULARITY }
        assertEquals(2, streak.days)
    }

    @Test
    fun noDaysMeansNoStreaks() {
        assertTrue(Streaks.evaluate(emptyList(), today = today).isEmpty())
    }
}
