package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The two decisions in the meditation log that do not need a database behind them.
 *
 * THE THRESHOLD IS THE ONE THAT MATTERS. It was reported as "the timer does not work": starting and
 * stopping the stopwatch inside half a minute stored nothing and said nothing, which is indistinguishable
 * from a button that is not wired up. The guard itself is right — a mis-tap must not light a day's circle
 * and feed a meditation nobody sat into the level — so the fix was to make the refusal speak, and this
 * pins the boundary it refuses at.
 */
class MeditationStoreTest {

    @Test
    fun aSessionAtTheThresholdIsLoggedAndOneBelowItIsNot() {
        assertFalse(MeditationStore.isLoggable(0))
        assertFalse(MeditationStore.isLoggable(MeditationStore.MIN_SESSION_SECONDS - 1))
        assertTrue(MeditationStore.isLoggable(MeditationStore.MIN_SESSION_SECONDS))
        assertTrue(MeditationStore.isLoggable(20 * 60))
    }

    @Test
    fun aRefusalIsReportedRatherThanSilent() {
        // The outcome type exists precisely so the screen can say which of the three happened. A store
        // that returned only the unchanged total could not tell "too short" from "nothing to add".
        assertEquals(3, MeditationStore.Outcome.entries.size)
        assertTrue(MeditationStore.Outcome.TOO_SHORT in MeditationStore.Outcome.entries)
        assertTrue(MeditationStore.Outcome.FAILED in MeditationStore.Outcome.entries)
    }

    @Test
    fun theWindowCountsDaysWithAnythingOnThem() {
        // This is the figure the level's focus term multiplies by, so a miscount moves the score.
        assertEquals(0, MeditationStore.countDays(listOf(0.0, 0.0, 0.0)))
        assertEquals(1, MeditationStore.countDays(listOf(0.0, 12.0, 0.0)))
        assertEquals(3, MeditationStore.countDays(listOf(5.0, 12.0, 0.5)))
    }

    @Test
    fun theWindowIsThreeDaysWideBecauseTheLevelSaysSo() {
        // The circles on screen ARE this window. If the two ever disagree the wearer is shown one
        // number and scored on another.
        assertEquals(3, MeditationStore.WINDOW_DAYS)
    }
}
