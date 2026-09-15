package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reading WHOOP's developer API.
 *
 * THE DANGEROUS CASES HERE ARE THE PLAUSIBLE-LOOKING ONES. A pending night written as a zero, a cycle
 * filed one day off, an HRV out by a factor of a thousand — none of them crash, none of them look wrong
 * in a list, and every one of them would put a number on Today that the wearer's own WHOOP app
 * contradicts. Those are what these cover.
 */
class WhoopCloudApiTest {

    private fun cycleBody(vararg records: String) =
        """{"records":[${records.joinToString(",")}],"next_token":null}"""

    private fun cycle(id: Long, start: String, offset: String, strain: Double?, state: String = "SCORED") =
        """{"id":$id,"start":"$start","timezone_offset":"$offset","score_state":"$state"""" +
            (if (strain != null) ""","score":{"strain":$strain}}""" else "}")

    // --- score_state ---

    @Test
    fun aPendingCycleContributesNoStrain() {
        // WHOOP has not finished grading it. A zero here would show a terrible day that is simply not
        // scored yet, and would be overwritten hours later — the wearer would watch history change.
        val body = cycleBody(cycle(1, "2026-09-14T06:00:00.000Z", "+02:00", null, state = "PENDING_SCORE"))
        val (days, ids) = WhoopCloudApi.parseCycles(body)
        assertTrue("no strain is stored", days.isEmpty())
        assertEquals("but the day is still known, so a recovery can be placed", 1, ids.size)
    }

    @Test
    fun aCalibratingRecoveryIsSkipped() {
        // `user_calibrating` is WHOOP saying its own figure is not yet meaningful. Storing it would put a
        // number on screen that the source does not stand behind.
        val body = """{"records":[{"cycle_id":7,"score_state":"SCORED","score":
            {"user_calibrating":true,"recovery_score":42}}]}""".trimIndent()
        val parsed = WhoopCloudApi.parseRecovery(body, mapOf("7" to "2026-09-14"))
        assertTrue(parsed.isEmpty())
    }

    @Test
    fun aRecoveryWhoseCycleIsUnknownIsDroppedRatherThanGuessed() {
        // The record carries no date of its own — only `cycle_id`. Filing it by `created_at` would put a
        // recovery computed at 07:00 on the day it was CALCULATED, not the day it describes.
        val body = """{"records":[{"cycle_id":99,"score_state":"SCORED","score":{"recovery_score":70}}]}"""
        assertTrue(WhoopCloudApi.parseRecovery(body, mapOf("7" to "2026-09-14")).isEmpty())
    }

    // --- day bucketing ---

    @Test
    fun aCycleIsFiledInItsOwnOffsetNotThePhonesZone() {
        // 23:40 UTC on the 14th is 01:40 on the 15th in +02:00. The record's own offset decides, so a
        // wearer who flies home does not have a week of history silently shift by one.
        assertEquals("2026-09-15", WhoopCloudApi.localDay("2026-09-14T23:40:00.000Z", "+02:00"))
        assertEquals("2026-09-14", WhoopCloudApi.localDay("2026-09-14T23:40:00.000Z", "+00:00"))
        assertEquals("2026-09-14", WhoopCloudApi.localDay("2026-09-14T23:40:00.000Z", "-05:00"))
    }

    @Test
    fun anUnparseableInstantIsDroppedNotDefaulted() {
        assertNull(WhoopCloudApi.localDay("not-a-date", "+02:00"))
    }

    // --- sleep ---

    @Test
    fun aNapIsNotFoldedIntoTheNight() {
        // Adding a nap to the night's totals inflates the duration and wrecks the stage breakdown.
        val body = """{"records":[{"nap":true,"end":"2026-09-15T14:00:00.000Z","timezone_offset":"+02:00",
            "score_state":"SCORED","score":{"sleep_performance_percentage":80}}]}""".trimIndent()
        assertTrue(WhoopCloudApi.parseSleep(body).isEmpty())
    }

    @Test
    fun theNightIsCreditedToTheDayItEndsOn() {
        // A sleep that starts at 23:40 on Tuesday is Wednesday's row EVERYWHERE else in this app, and a
        // cloud import that disagreed with the rest of it would just look broken.
        val body = """{"records":[{"nap":false,"end":"2026-09-15T05:30:00.000Z","timezone_offset":"+02:00",
            "score_state":"SCORED","score":{"sleep_performance_percentage":88,
            "sleep_efficiency_percentage":94,"respiratory_rate":14.2,
            "stage_summary":{"total_slow_wave_sleep_time_milli":5400000,
            "total_rem_sleep_time_milli":7200000,"total_light_sleep_time_milli":10800000}}}]}""".trimIndent()
        val night = WhoopCloudApi.parseSleep(body).values.single()
        assertEquals("2026-09-15", night.day)
        assertEquals(90.0, night.deepMin!!, 1e-6)
        assertEquals(120.0, night.remMin!!, 1e-6)
        assertEquals(180.0, night.lightMin!!, 1e-6)
        // The total is the three ASLEEP stages. Awake time is reported separately, and adding it would
        // turn "you slept" into "you lay there" — a different figure with the same name.
        assertEquals(390.0, night.totalSleepMin!!, 1e-6)
    }

    // --- the HRV unit ---

    @Test
    fun hrvSurvivesEitherUnitTheFieldArrivesIn() {
        // `hrv_rmssd_milli` is documented as milliseconds and has been observed arriving as seconds.
        // Picking one and hoping is wrong by three orders of magnitude while still looking like a
        // reading, so the value decides: nothing alive has a resting RMSSD under 1 ms.
        assertEquals(65.4, WhoopCloudApi.hrvMilliseconds(0.0654)!!, 1e-6)
        assertEquals(65.4, WhoopCloudApi.hrvMilliseconds(65.4)!!, 1e-6)
        assertNull(WhoopCloudApi.hrvMilliseconds(0.0))
        assertNull(WhoopCloudApi.hrvMilliseconds(Double.NaN))
    }

    // --- merging ---

    @Test
    fun mergingFillsGapsAndNeverBlanksAMeasuredField() {
        val a = mapOf("2026-09-15" to WhoopCloudApi.CloudDay(day = "2026-09-15", strain = 12.0))
        val b = mapOf("2026-09-15" to WhoopCloudApi.CloudDay(day = "2026-09-15", recovery = 71.0))
        val merged = WhoopCloudApi.merge(a, b).single()
        assertEquals(12.0, merged.strain!!, 1e-9)
        assertEquals(71.0, merged.recovery!!, 1e-9)
    }

    @Test
    fun mergedDaysComeBackInOrder() {
        val a = mapOf("2026-09-15" to WhoopCloudApi.CloudDay(day = "2026-09-15"))
        val b = mapOf("2026-09-13" to WhoopCloudApi.CloudDay(day = "2026-09-13"))
        assertEquals(listOf("2026-09-13", "2026-09-15"), WhoopCloudApi.merge(a, b).map { it.day })
    }

    // --- tolerance ---

    @Test
    fun aMalformedBodyYieldsNothingRatherThanThrowing() {
        // This runs over another server's output. A bad response must cost the sync, not the app.
        listOf("", "{", "null", """{"records":"not-an-array"}""").forEach { junk ->
            assertTrue(WhoopCloudApi.parseCycles(junk).first.isEmpty())
            assertTrue(WhoopCloudApi.parseSleep(junk).isEmpty())
            assertTrue(WhoopCloudApi.parseRecovery(junk, emptyMap()).isEmpty())
            assertNull(WhoopCloudApi.nextToken(junk))
        }
    }

    @Test
    fun theNextTokenIsReadWhenThereIsOneAndNullWhenThereIsNot() {
        assertEquals("abc", WhoopCloudApi.nextToken("""{"records":[],"next_token":"abc"}"""))
        assertNull(WhoopCloudApi.nextToken("""{"records":[]}"""))
    }
}
