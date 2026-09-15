package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The level.
 *
 * NO ORACLE FROM THE SPEC. The specification's worked example does not reproduce its own code — five of
 * nine figures disagree, and its `focus` omits the meditation bonus the formula applies. So these pin
 * the BEHAVIOUR that was decided, each case chosen for a rule that would be easy to break silently,
 * rather than copying numbers that were never computed.
 */
class LevelEngineTest {

    private val base = LevelBaselines.DEFAULT

    /** An identity range: a load of 70 sits at 70 on it, which keeps the muscle cases readable. */
    private val pct = Baseline(mean = 50.0, sd = 20.0, min = 0.0, max = 100.0)

    // --- The pieces ---------------------------------------------------------------------------

    @Test
    fun theScaleIsCentredAtFiftyAndQuarterOfAnSdIsFivePoints() {
        assertEquals(50.0, LevelEngine.toScale(0.0), 1e-9)
        assertEquals(75.0, LevelEngine.toScale(1.0), 1e-9)
        assertEquals(25.0, LevelEngine.toScale(-1.0), 1e-9)
    }

    @Test
    fun theScaleIsClippedSoAFreakReadingCannotLeaveTheRange() {
        assertEquals(100.0, LevelEngine.toScale(4.0), 1e-9)
        assertEquals(0.0, LevelEngine.toScale(-4.0), 1e-9)
    }

    @Test
    fun zIsClippedAtThreeSdsBeforeItIsScaled() {
        // One corrupt HRV reading must not be able to swing the level on its own.
        val huge = LevelEngine.z(10_000.0, Baseline(50.0, 15.0, 20.0, 80.0))
        assertEquals(LevelEngine.Z_CLIP, huge, 1e-9)
    }

    @Test
    fun aMetricThatNeverMovesDoesNotDivideByZero() {
        // A wearer whose reading is identical every day has an SD of 0.
        val z = LevelEngine.z(50.0, Baseline(50.0, 0.0, 50.0, 50.0))
        assertTrue(z.isFinite())
        assertEquals(0.0, z, 1e-9)
    }

    @Test
    fun heartRewardsHighHrvAndLowRhr() {
        // HRV one SD up, RHR one SD down: both good, so the two add rather than cancel.
        val good = LevelEngine.heart(hrv = 65.0, rhr = 50.0, baselines = base)!!
        val neutral = LevelEngine.heart(hrv = 50.0, rhr = 60.0, baselines = base)!!
        assertEquals(50.0, neutral, 1e-9)
        assertEquals(100.0, good, 1e-9)      // 50 + 25*(1 - (-1)) = 100
    }

    @Test
    fun aFastRespiratoryRateIsTheBadDirection() {
        val slow = LevelEngine.lungs(vo2max = null, respRate = 13.0, baselines = base)!!
        val fast = LevelEngine.lungs(vo2max = null, respRate = 19.0, baselines = base)!!
        assertTrue("slow breathing should score higher", slow > fast)
    }

    @Test
    fun lungsSurvivesWithOnlyOneOfItsTwoInputs() {
        // VO2max is the one most wearers do not have. Scoring lungs as zero without it would mark them
        // down for a reading their strap cannot take.
        assertNotNull(LevelEngine.lungs(vo2max = 45.0, respRate = null, baselines = base))
        assertNotNull(LevelEngine.lungs(vo2max = null, respRate = 16.0, baselines = base))
        assertNull(LevelEngine.lungs(vo2max = null, respRate = null, baselines = base))
    }

    @Test
    fun muscleWeightsTodayAboveLastWeek() {
        val fresh = LevelEngine.muscle(listOf(80.0 to 0, 20.0 to 4), pct)!!
        val stale = LevelEngine.muscle(listOf(20.0 to 0, 80.0 to 4), pct)!!
        assertTrue("the recent session should dominate", fresh > stale)
    }

    @Test
    fun muscleWithOneSessionIsThatSession() {
        assertEquals(70.0, LevelEngine.muscle(listOf(70.0 to 0), pct)!!, 1e-9)
    }

    @Test
    fun onlyTheLastThreeSessionsCount() {
        val many = listOf(0.0 to 9, 0.0 to 8, 90.0 to 2, 90.0 to 1, 90.0 to 0)
        assertEquals(90.0, LevelEngine.muscle(many, pct)!!, 1e-6)
    }

    @Test
    fun focusRisesWithMeditationAndFallsWithStress() {
        val calmMeditated = LevelEngine.focus(listOf(10.0), 3)!!
        val calmNot = LevelEngine.focus(listOf(10.0), 0)!!
        val stressed = LevelEngine.focus(listOf(90.0), 3)!!
        assertTrue(calmMeditated > calmNot)
        assertTrue(calmNot > stressed)
    }

    @Test
    fun focusCannotExceedTheScale() {
        // Zero stress with three meditation days is 100 * 1.01 before clamping.
        assertEquals(100.0, LevelEngine.focus(listOf(0.0), 3)!!, 1e-9)
    }

    @Test
    fun sleepWithoutAConsistencyReadingIsScoredOnItsScoreAlone() {
        // A missing measurement must not read as a bad one.
        assertEquals(80.0, LevelEngine.sleep(listOf(80.0), emptyList())!!, 1e-9)
        assertEquals(0.8 * 80 + 0.2 * 40, LevelEngine.sleep(listOf(80.0), listOf(40.0))!!, 1e-9)
    }

    // --- Steps: a penalty, never a component ---------------------------------------------------

    @Test
    fun stepsAtOrAboveTheFloorChangeNothing() {
        assertEquals(1.0, LevelEngine.stepPenalty(6_000), 1e-9)
        assertEquals(1.0, LevelEngine.stepPenalty(25_000), 1e-9)
    }

    @Test
    fun thereIsNoCliffAtTheFloor() {
        // The spec's earlier draft also SCORED steps, which put 72 points between 5,999 and 6,000.
        // With steps as a penalty only, one step either side must be almost indistinguishable.
        val just = LevelEngine.stepPenalty(5_999)
        val at = LevelEngine.stepPenalty(6_000)
        assertTrue("a single step must not move the level", at - just < 0.0001)
    }

    @Test
    fun theWorstStepPenaltyIsFifteenPercent() {
        assertEquals(1.0 - LevelEngine.STEPS_MAX_PENALTY, LevelEngine.stepPenalty(0), 1e-9)
        assertEquals(0.925, LevelEngine.stepPenalty(3_000), 1e-9)
    }

    @Test
    fun unrecordedStepsAreNotPunished() {
        // Null is a phone that does not count steps. Punishing it would mark the wearer down for
        // hardware they do not have, every single day, with no way to fix it.
        assertEquals(1.0, LevelEngine.stepPenalty(null), 1e-9)
    }

    // --- The whole thing ----------------------------------------------------------------------

    private fun full() = LevelInputs(
        sleepScores = listOf(72.0, 68.0, 75.0),
        consistencyScores = listOf(65.0, 70.0, 72.0),
        hrv = 65.0, rhr = 58.0, vo2max = 48.0, respRate = 15.0,
        muscleSessions = listOf(70.0 to 0, 55.0 to 2, 60.0 to 4),
        stressScores = listOf(35.0, 40.0, 38.0),
        meditationDays = 2,
        stepsToday = 4_500,
    )

    @Test
    fun aFullDayScoresWithEveryComponentPresent() {
        val b = LevelEngine.compute(full(), base)!!
        assertEquals(1.0, b.coverage, 1e-9)
        assertTrue(b.components.all { it.score != null })
        assertTrue(b.level in 0.0..100.0)
        // The penalty is applied, not merely computed.
        assertTrue(b.level < b.raw)
        assertEquals(b.raw * b.stepPenalty, b.level, 1e-9)
    }

    @Test
    fun weightIsRedistributedOverWhatWasActuallyMeasured() {
        // No VO2max and no respiratory rate: lungs is absent, and the other four must still add to the
        // full weight — otherwise a missing sensor silently reads as a zero score.
        val noLungs = full().copy(vo2max = null, respRate = null)
        val b = LevelEngine.compute(noLungs, base)!!
        assertNull(b.components.single { it.part == LevelPart.LUNGS }.score)
        assertEquals(0.0, b.components.single { it.part == LevelPart.LUNGS }.effectiveWeight, 1e-9)
        assertEquals(1.0, b.components.sumOf { it.effectiveWeight }, 1e-9)
        assertEquals(1.0 - LevelPart.LUNGS.weight, b.coverage, 1e-9)
    }

    @Test
    fun aMissingComponentDoesNotDragTheLevelDown() {
        val withLungs = LevelEngine.compute(full(), base)!!
        // Replace lungs with nothing; the remaining components are unchanged, so the level should move
        // only by the reweighting — not collapse as it would if the absence scored zero.
        val without = LevelEngine.compute(full().copy(vo2max = null, respRate = null), base)!!
        assertTrue(kotlin.math.abs(without.level - withLungs.level) < 10.0)
    }

    @Test
    fun nothingMeasuredIsNullRatherThanZero() {
        // A zero level reads as "you are in terrible shape". It means "nothing was recorded", and the
        // difference is the whole reason this returns null.
        assertNull(LevelEngine.compute(LevelInputs(), base))
    }

    @Test
    fun leversAreRankedByWhatTheyAreWorthNotByHowLowTheyAre() {
        // Lungs 20 is a worse NUMBER than sleep 60, but at weight 0.07 against 0.30 fixing sleep is
        // worth more than twice as much level. Ranking by the low score would point at the wrong one.
        val inputs = LevelInputs(
            sleepScores = listOf(60.0),
            hrv = 50.0, rhr = 60.0,
            vo2max = 20.0, respRate = 25.0,
            muscleSessions = listOf(50.0 to 0),
            stressScores = listOf(50.0),
            meditationDays = 0,
        )
        val b = LevelEngine.compute(inputs, base)!!
        val top = b.levers().first()
        assertEquals(LevelPart.SLEEP, top.part)
        assertTrue(
            "lungs must rank below sleep despite the lower score",
            b.levers().indexOfFirst { it.part == LevelPart.LUNGS } > 0,
        )
    }

    @Test
    fun contributionsAddUpToTheRawScore() {
        val b = LevelEngine.compute(full(), base)!!
        assertEquals(b.raw, b.components.sumOf { it.contribution }, 1e-9)
    }

    // --- Baselines ----------------------------------------------------------------------------

    @Test
    fun aShortHistoryFallsBackToTheTable() {
        val thin = List(LevelBaselines.MIN_SAMPLES - 1) { 55.0 }
        assertEquals(LevelBaselines.DEFAULT.getValue(LevelMetric.HRV), LevelBaselines.derive(LevelMetric.HRV, thin))
    }

    @Test
    fun enoughHistoryScoresTheWearerAgainstThemselves() {
        // An HRV of 30 is unremarkable for someone whose own mean is 30, and the level must say so
        // rather than scoring them against a stranger's 50.
        val own = List(40) { 30.0 + (it % 5) }
        val b = LevelBaselines.derive(LevelMetric.HRV, own)
        assertTrue(b.mean in 31.0..33.0)
        assertTrue(b.sd > 0.0)
        assertTrue(kotlin.math.abs(LevelEngine.z(32.0, b)) < 1.0)
    }

    @Test
    fun theRangeIgnoresTheTailsSoOneBadReadingCannotSetTheScaleForever() {
        // The range is FROZEN. A single corrupt sample taken on the day it is derived would otherwise
        // define the scale for the life of the install.
        val sane = List(50) { 40.0 + it % 10 }          // 40..49
        val withGlitch = sane + listOf(100_000.0, -5_000.0)
        val b = LevelBaselines.derive(LevelMetric.MUSCLE_LOAD, withGlitch)
        assertTrue("the glitch must not become the maximum", b.max < 100.0)
        assertTrue("nor the minimum", b.min > 0.0)
    }

    @Test
    fun aValueIsPlacedOnTheFrozenRangeAndClippedToIt() {
        val b = Baseline(mean = 50.0, sd = 10.0, min = 20.0, max = 70.0)
        assertEquals(0.0, b.position(20.0), 1e-9)
        assertEquals(100.0, b.position(70.0), 1e-9)
        assertEquals(50.0, b.position(45.0), 1e-9)
        // Beyond the frozen ends, not outside the scale: the range is fixed, the readings are not.
        assertEquals(100.0, b.position(9_999.0), 1e-9)
        assertEquals(0.0, b.position(-9_999.0), 1e-9)
    }

    @Test
    fun aDegenerateRangeDoesNotDivideByZero() {
        val flat = Baseline(mean = 5.0, sd = 0.0, min = 5.0, max = 5.0)
        assertTrue(flat.position(5.0).isFinite())
    }

    @Test
    fun muscleLoadIsPlacedOnItsFrozenRangeRatherThanUsedRaw() {
        // Volume load arrives in kilograms and can be 12,000. Used raw it would clip to 100 forever.
        val kg = Baseline(mean = 6_000.0, sd = 2_000.0, min = 2_000.0, max = 10_000.0)
        val mid = LevelEngine.muscle(listOf(6_000.0 to 0), kg)!!
        assertEquals(50.0, mid, 1e-9)
        assertEquals(100.0, LevelEngine.muscle(listOf(10_000.0 to 0), kg)!!, 1e-9)
        assertEquals(0.0, LevelEngine.muscle(listOf(2_000.0 to 0), kg)!!, 1e-9)
    }

    @Test
    fun theSpreadIsThePopulationFormSoBothPlatformsAgree() {
        // numpy's std divides by n; the sample form (n-1) would put Swift and Kotlin a fraction apart
        // on every single score.
        val xs = List(20) { it.toDouble() }
        val mean = xs.average()
        val expected = kotlin.math.sqrt(xs.sumOf { (it - mean) * (it - mean) } / xs.size)
        assertEquals(expected, LevelBaselines.derive(LevelMetric.HRV, xs).sd, 1e-9)
    }
}
