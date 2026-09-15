package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which metric a lever names.
 *
 * The failure this guards is quiet and misleading rather than loud: a lever that names the wrong figure
 * sends the wearer after the wrong thing with the app's authority behind it, and nothing on screen would
 * contradict it.
 */
class LevelDriversTest {

    private val baselines = LevelBaselines.DEFAULT

    @Test
    fun sleepNamesTheFigureWorthMostNotTheLowestNumber() {
        // Score carries 0.8 of the sleep term and consistency 0.2. A score of 70 has 30 x 0.8 = 24 points
        // of room; a consistency of 40 has 60 x 0.2 = 12. The LOWER number is the smaller prize, and
        // ranking by "which looks worst" would point at it.
        val inputs = LevelInputs(sleepScores = listOf(70.0), consistencyScores = listOf(40.0))
        assertEquals(LevelDriver.SLEEP_SCORE, LevelDrivers.driver(LevelPart.SLEEP, inputs, baselines))
    }

    @Test
    fun sleepNamesConsistencyWhenThatIsWhereTheRoomIs() {
        val inputs = LevelInputs(sleepScores = listOf(95.0), consistencyScores = listOf(10.0))
        assertEquals(
            LevelDriver.SLEEP_CONSISTENCY,
            LevelDrivers.driver(LevelPart.SLEEP, inputs, baselines),
        )
    }

    @Test
    fun aRestingHeartRateWellAboveBaselineIsNamedOverAHealthyHrv() {
        // HRV 80 against a mean of 50 is excellent; RHR 80 against a mean of 60 is not. The heart glyph
        // alone cannot say which, which is the whole reason the label exists.
        val inputs = LevelInputs(hrv = 80.0, rhr = 80.0)
        assertEquals(LevelDriver.RHR, LevelDrivers.driver(LevelPart.HEART, inputs, baselines))
    }

    @Test
    fun aLowHrvIsNamedOverAGoodRestingHeartRate() {
        val inputs = LevelInputs(hrv = 20.0, rhr = 48.0)
        assertEquals(LevelDriver.HRV, LevelDrivers.driver(LevelPart.HEART, inputs, baselines))
    }

    @Test
    fun aPartWithOneInputNamesItself() {
        val inputs = LevelInputs(muscleSessions = listOf(4000.0 to 0))
        assertEquals(LevelDriver.MUSCLE_VOLUME, LevelDrivers.driver(LevelPart.MUSCLE, inputs, baselines))
    }

    @Test
    fun aPartWithNoDataNamesNothing() {
        // A lever is only ever drawn for a part that scored, so an unmeasured part must not produce a
        // label — a word under a dimmed glyph would read as advice about a metric nobody recorded.
        val empty = LevelInputs()
        assertNull(LevelDrivers.driver(LevelPart.SLEEP, empty, baselines))
        assertNull(LevelDrivers.driver(LevelPart.HEART, empty, baselines))
        assertNull(LevelDrivers.driver(LevelPart.LUNGS, empty, baselines))
        assertNull(LevelDrivers.driver(LevelPart.MUSCLE, empty, baselines))
        assertNull(LevelDrivers.driver(LevelPart.FOCUS, empty, baselines))
    }

    @Test
    fun focusNamesMeditationOnlyWhenThereIsBonusLeftToWin() {
        // Three days of meditation on a calm day: the bonus is already at its ceiling, so the only room
        // left is in the stress figure itself.
        val allThree = LevelInputs(stressScores = listOf(30.0), meditationDays = 3)
        assertEquals(LevelDriver.STRESS, LevelDrivers.driver(LevelPart.FOCUS, allThree, baselines))

        // A calm day with nothing sat: the remaining bonus is worth more than the small stress gap.
        val none = LevelInputs(stressScores = listOf(10.0), meditationDays = 0)
        assertEquals(LevelDriver.MEDITATION, LevelDrivers.driver(LevelPart.FOCUS, none, baselines))
    }

    @Test
    fun everyDriverBelongsToThePartItIsNamedFor() {
        // Structural: a driver filed under the wrong part would surface a lungs word beneath a heart.
        LevelDriver.entries.forEach { driver ->
            val inputs = LevelInputs(
                sleepScores = listOf(50.0),
                consistencyScores = listOf(50.0),
                hrv = 50.0,
                rhr = 60.0,
                vo2max = 45.0,
                respRate = 16.0,
                muscleSessions = listOf(4000.0 to 0),
                stressScores = listOf(50.0),
                meditationDays = 1,
            )
            val named = LevelDrivers.driver(driver.part, inputs, baselines)
            assertEquals(driver.part, named?.part)
        }
    }
}
