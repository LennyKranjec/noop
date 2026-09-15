package com.noop.ingest

import com.noop.ingest.HealthConnectImporter.Macros
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Picking today's food log out of everything mirroring into the health store.
 *
 * The failure this guards is silent and large: two apps mirroring the same meals double every macro,
 * and a tile reading 320 g of protein looks like a good day rather than a bug.
 */
class HealthConnectMacrosTest {

    private fun log(kcal: Double?, p: Double?, c: Double?, f: Double?) = Macros(kcal, p, c, f)

    @Test
    fun twoAppsMirroringTheSameMealsDoNotDoubleTheDay() {
        val mirrored = log(2400.0, 160.0, 240.0, 80.0)
        val picked = HealthConnectImporter.pickMacroLog(
            mapOf("com.diary" to mirrored, "com.mirror" to mirrored),
        )!!
        assertEquals(160.0, picked.proteinG!!, 1e-9)
    }

    @Test
    fun theFullestLogWins() {
        val full = log(2400.0, 160.0, 240.0, 80.0)
        val partial = log(600.0, 40.0, 60.0, 20.0)
        assertSame(
            full,
            HealthConnectImporter.pickMacroLog(mapOf("a" to partial, "b" to full)),
        )
    }

    @Test
    fun aDayIsTakenWholeRatherThanAssembledFromTwoDiaries() {
        // The protein must not come from one app and the carbohydrate from another: that describes a
        // meal nobody ate. The fuller log is taken entire, gaps included.
        val proteinOnly = log(null, 200.0, null, null)
        val balanced = log(2000.0, 120.0, 220.0, 70.0)
        val picked = HealthConnectImporter.pickMacroLog(mapOf("a" to proteinOnly, "b" to balanced))!!
        assertEquals(120.0, picked.proteinG!!, 1e-9)
        assertEquals(220.0, picked.carbsG!!, 1e-9)
    }

    @Test
    fun anEmptyStoreYieldsNothingRatherThanZero() {
        // "You ate nothing" and "your diary has not been opened yet" are different statements, and the
        // tile shows a dash for one of them.
        assertNull(HealthConnectImporter.pickMacroLog(emptyMap()))
        assertNull(HealthConnectImporter.pickMacroLog(mapOf("a" to log(null, null, null, null))))
    }

    @Test
    fun aMissingMacroFieldAddsNothingAndStaysMissing() {
        // A record carrying calories but no fat must leave fat absent, not turn it into 0 g.
        assertNull(HealthConnectImporter.add(null, null))
        assertEquals(12.0, HealthConnectImporter.add(null, 12.0)!!, 1e-9)
        assertEquals(12.0, HealthConnectImporter.add(12.0, null)!!, 1e-9)
        assertEquals(30.0, HealthConnectImporter.add(12.0, 18.0)!!, 1e-9)
    }
}
