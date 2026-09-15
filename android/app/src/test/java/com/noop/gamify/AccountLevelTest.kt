package com.noop.gamify

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Byte-identity pin for the XP curve. The same totals MUST produce the same levels and bar fractions
 * as the Swift twin `AccountLevelTests`; the two platforms disagreeing about the wearer's own level is
 * the most visible parity break this app could ship.
 *
 * WHY A LITERAL TABLE AND NOT A RECOMPUTED FORMULA. Asserting `xpForLevel(n) == (120 * (n-1).pow(1.45))
 * .toInt()` would pass on any platform whose `pow` differs, which is exactly the drift the table exists
 * to catch. These values came out of an oracle run over the whole band, and the SAME literals are
 * pasted into the Swift test — that is what makes this a two-sided guard rather than a tautology.
 *
 * ON `pow` ROUNDING: `pow` is not guaranteed correctly-rounded by every libm, so a table like this is
 * only safe if no value sits within a few ULPs of an integer — truncation would then land on different
 * sides. Measured across levels 1–40, the closest any raw value comes to an integer boundary is 0.0287
 * (level 19), against a ULP of ~1.4e-14 at that magnitude. The one exact landing is level 2, where
 * `pow(1.0, 1.45)` is required by IEEE 754 to be exactly 1.0. Re-run the oracle before changing BASE
 * or EXPONENT.
 */
class AccountLevelTest {

    /** Cumulative XP to REACH each level, levels 1…20. Oracle output, pasted verbatim. */
    private val thresholds = intArrayOf(
        0, 120, 327, 590, 895, 1237, 1612, 2016, 2447, 2902,
        3382, 3883, 4405, 4947, 5508, 6088, 6685, 7300, 7930, 8577,
    )

    @Test
    fun theCurveMatchesTheOracle() {
        thresholds.forEachIndexed { index, expected ->
            assertEquals("level ${index + 1}", expected, AccountLevel.xpForLevel(index + 1))
        }
    }

    @Test
    fun theCurveTruncatesRatherThanRounds() {
        // Level 3's raw value is 327.8497. Rounding would give 328 and put every threshold above it on
        // a different integer than Swift's `Int(...)`, which truncates.
        assertEquals(327, AccountLevel.xpForLevel(3))
        assertEquals(4405, AccountLevel.xpForLevel(13))   // raw 4405.4883
    }

    @Test
    fun levelOneAndBelowCostNothing() {
        assertEquals(0, AccountLevel.xpForLevel(1))
        assertEquals(0, AccountLevel.xpForLevel(0))
        assertEquals(0, AccountLevel.xpForLevel(-5))
    }

    @Test
    fun aFreshInstallReadsExactlyFifteen() {
        // The whole point of the provisional baseline: nothing has been measured, so the badge starts
        // at 15 and every point above it was earned. If this drifts, a fresh install shows 14 or 16 and
        // the "provisional" framing silently becomes a lie.
        assertEquals(5751, AccountLevel.baselineXp())
        assertEquals(15, AccountLevel.levelForXp(AccountLevel.baselineXp()))
    }

    @Test
    fun theBoundaryIsInclusive() {
        // Reaching a threshold IS the level, not one short of it.
        assertEquals(1, AccountLevel.levelForXp(119))
        assertEquals(2, AccountLevel.levelForXp(120))
        assertEquals(2, AccountLevel.levelForXp(121))
    }

    @Test
    fun standingSplitsTheTotalAcrossTheCurrentLevel() {
        val s = AccountLevel.standingFor(5751)
        assertEquals(15, s.level)
        assertEquals(243, s.xpIntoLevel)      // 5751 - 5508
        assertEquals(580, s.xpSpanOfLevel)    // 6088 - 5508
        assertEquals(337, s.xpToNextLevel)
        assertEquals(243f / 580f, s.progress, 0.000_001f)
    }

    @Test
    fun progressIsClampedAtBothEnds() {
        assertEquals(0f, AccountLevel.standingFor(0).progress, 0.000_001f)
        // A total sitting exactly on a threshold is at the START of the new level, not the end of the old.
        assertEquals(0f, AccountLevel.standingFor(120).progress, 0.000_001f)
    }

    @Test
    fun aCorruptedTotalCannotSpinTheWalk() {
        // The walk is bounded, so a nonsense total returns rather than hanging the render that asked.
        assertTrue(AccountLevel.levelForXp(Int.MAX_VALUE) in 1..999)
        assertEquals(1, AccountLevel.levelForXp(-1))
    }

    @Test
    fun theProvisionalOverloadsAgreeWithTheDerivedOnes() {
        // Two ways to ask the same question must not answer differently, or a surface using the
        // no-argument overload shows a different level than one using the Context overload.
        assertEquals(AccountLevel.level(), AccountLevel.standingFor(AccountLevel.baselineXp()).level)
        assertEquals(AccountLevel.currentXp(), AccountLevel.baselineXp())
        assertFalse(AccountLevel.xpSpanOfLevel() == 0)
    }
}
