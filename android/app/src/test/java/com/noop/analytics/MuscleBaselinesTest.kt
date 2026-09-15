package com.noop.analytics

import com.noop.ingest.MuscleGroup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The muscle colour scale.
 *
 * What these pin is the CONSTANCY, because that is the whole claim the card makes: a colour means the
 * same thing on any muscle in any month. A test that only checked "more volume is redder" would pass
 * just as happily on the ranking this replaced.
 */
class MuscleBaselinesTest {

    private fun windows(vararg v: Double) = v.toList()

    @Test
    fun aGroupWithTooLittleHistoryHasNoScaleAtAll() {
        // 27 days is one day short. Freezing on a thin sample would be permanent, so it does not.
        assertNull(MuscleBaselines.derive(List(MuscleBaselines.MIN_WINDOWS - 1) { 1000.0 }))
        assertNotNull(MuscleBaselines.derive(List(MuscleBaselines.MIN_WINDOWS) { 1000.0 }))
    }

    @Test
    fun aMuscleNeverTrainedIsNotFrozenAtZero() {
        // Otherwise its mean is 0 with no spread, and the first set the wearer ever does for it paints
        // it at the top of the scale for good.
        assertNull(MuscleBaselines.derive(List(200) { 0.0 }))
    }

    @Test
    fun aNormalWeekSitsInTheMiddleOfTheScale() {
        val b = MuscleBaseline(mean = 4000.0, sd = 1000.0)
        assertEquals(0.5, MuscleBaselines.fraction(b, 4000.0), 1e-9)
    }

    @Test
    fun theEndsOfTheScaleAreTwoStandardDeviationsEitherSide() {
        val b = MuscleBaseline(mean = 4000.0, sd = 1000.0)
        assertEquals(0.0, MuscleBaselines.fraction(b, 2000.0), 1e-9)
        assertEquals(1.0, MuscleBaselines.fraction(b, 6000.0), 1e-9)
        // Past the end there is no further shade — the scale clips rather than running off.
        assertEquals(1.0, MuscleBaselines.fraction(b, 60_000.0), 1e-9)
        assertEquals(0.0, MuscleBaselines.fraction(b, 0.0), 1e-9)
    }

    @Test
    fun theSameZScoreIsTheSameColourOnDifferentMuscles() {
        // THE POINT OF THE WHOLE FILE. A calf that does 400 kg in a normal week and a chest that does
        // 8,000 must land on the same shade when each has had a normal week.
        val calves = MuscleBaseline(mean = 400.0, sd = 120.0)
        val chest = MuscleBaseline(mean = 8000.0, sd = 2400.0)
        assertEquals(
            MuscleBaselines.fraction(calves, 400.0 + 120.0),
            MuscleBaselines.fraction(chest, 8000.0 + 2400.0),
            1e-9,
        )
    }

    @Test
    fun aHeavyWeekDoesNotBecomeNormalBecauseTheNextWeekIsHeavier() {
        // The ranking this replaced could not tell these apart: in both, the group IS the peak.
        val b = MuscleBaseline(mean = 4000.0, sd = 1000.0)
        val heavy = MuscleBaselines.fraction(b, 5000.0)
        val heavier = MuscleBaselines.fraction(b, 6000.0)
        assertTrue(heavy < heavier)
        // And a light week reads light, rather than reading as "the most I did this week".
        assertTrue(MuscleBaselines.fraction(b, 2500.0) < 0.5)
    }

    @Test
    fun aFlatHistoryGetsASpreadOnTheRightScale() {
        // sd = 0 exactly. Falling back to 1.0 would make a 4,000 kg week read as 4,000 SD from normal.
        val b = MuscleBaselines.derive(List(60) { 4000.0 })!!
        assertEquals(0.0, b.sd, 1e-9)
        assertEquals(2000.0, b.safeSd, 1e-9)
        assertEquals(0.5, MuscleBaselines.fraction(b, 4000.0), 1e-9)
        assertEquals(1.0, MuscleBaselines.fraction(b, 8000.0), 1e-9)
    }

    @Test
    fun restDaysAreInTheWindowsBecauseTheyAreInTheFigure() {
        // The card shows a trailing week on whatever day it is opened, so the distribution the colour is
        // judged against has to include the days that sum to little. A history of one heavy Monday runs
        // 1000 for seven days and then falls back to zero.
        val w = MuscleBaselines.rollingWindows(mapOf("2026-09-01" to 1000.0, "2026-09-20" to 500.0))
        assertEquals(20, w.size)
        assertEquals(1000.0, w.first(), 1e-9)
        assertEquals(1000.0, w[6], 1e-9)
        assertEquals(0.0, w[7], 1e-9)
        assertEquals(500.0, w.last(), 1e-9)
    }

    @Test
    fun aGapInTheLogIsTimePassingNotTimeSkipped() {
        // Running over the ENTRIES rather than the calendar would turn a fortnight off into no time at
        // all, and the frozen spread would come out far tighter than the wearer's training really is.
        val sparse = mapOf("2026-01-01" to 1000.0, "2026-06-01" to 1000.0)
        assertEquals(152, MuscleBaselines.rollingWindows(sparse).size)
    }

    @Test
    fun onlyTheGroupsWithHistoryAreFrozen() {
        val frozen = MuscleBaselines.deriveAll(
            mapOf(
                MuscleGroup.CHEST to List(60) { 4000.0 },
                MuscleGroup.CALVES to windows(400.0, 400.0),
            ),
        )
        assertTrue(frozen.containsKey(MuscleGroup.CHEST))
        assertFalse(frozen.containsKey(MuscleGroup.CALVES))
    }

    @Test
    fun theStoredScaleSurvivesARoundTrip() {
        val scale = mapOf(
            MuscleGroup.CHEST to MuscleBaseline(8000.0, 2400.0),
            MuscleGroup.CALVES to MuscleBaseline(400.0, 120.0),
        )
        assertEquals(scale, MuscleBaselineStore.decode(MuscleBaselineStore.encode(scale)))
    }

    @Test
    fun anUnreadableStoredGroupIsAbsentRatherThanInvented() {
        // There is no table value for "kilograms a shoulder normally does", so a broken entry must drop
        // out rather than be filled in with a number nobody measured.
        val decoded = MuscleBaselineStore.decode(
            """{"CHEST":{"mean":8000,"sd":2400},"CALVES":{"mean":0,"sd":0},"LATS":{}}""",
        )
        assertEquals(setOf(MuscleGroup.CHEST), decoded.keys)
    }
}
