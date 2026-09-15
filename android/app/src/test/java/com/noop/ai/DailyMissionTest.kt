package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Reading a mission out of what the model actually wrote.
 *
 * The model is told to answer in two parts and will sometimes do something else. The rule these pin:
 * the MISSION is the valuable half and survives almost anything; the XP is the disposable half and
 * falls back rather than taking the mission down with it.
 */
class DailyMissionTest {

    @Test
    fun theStatedShapeIsRead() {
        val mission = DailyMissionWriter.parse(
            "XP: 40\nBed by 22:30. Your HRV has been filing complaints.",
            "2026-09-15",
        )!!
        assertEquals(40, mission.xp)
        assertEquals("Bed by 22:30. Your HRV has been filing complaints.", mission.text)
        assertEquals("2026-09-15", mission.dayKey)
    }

    @Test
    fun aMissingXpLineStillYieldsTheMission() {
        val mission = DailyMissionWriter.parse("Walk for 30 minutes. Outside. Yes, really.", "2026-09-15")!!
        assertEquals(DailyMissionStore.DEFAULT_XP, mission.xp)
        assertTrue(mission.text.startsWith("Walk"))
    }

    @Test
    fun anAbsurdXpIsClampedNotObeyed() {
        // The figure comes from a language model, and 99999 XP would end the level system in one tap.
        val mission = DailyMissionWriter.parse("XP: 99999\nDo a thing.", "2026-09-15")!!
        assertEquals(DailyMissionStore.MAX_XP, mission.xp)
    }

    @Test
    fun theXpLineIsNotLeftInTheTextTheWearerReads() {
        val mission = DailyMissionWriter.parse("**XP: 55**\nSwim.", "2026-09-15")!!
        assertEquals(55, mission.xp)
        assertEquals("Swim.", mission.text)
    }

    @Test
    fun anAnswerWithNoProseIsNoMission() {
        // An XP line and nothing else is not a mission, and storing one would put an empty card on Today.
        assertNull(DailyMissionWriter.parse("XP: 40", "2026-09-15"))
        assertNull(DailyMissionWriter.parse("   \n  ", "2026-09-15"))
    }

    @Test
    fun theClaimKeyIsPerDaySoOneDayIsClaimedOnce() {
        assertEquals("mission-2026-09-15", DailyMission("2026-09-15", "x", 10).claimKey)
        assertTrue(
            DailyMission("2026-09-15", "x", 10).claimKey !=
                DailyMission("2026-09-16", "x", 10).claimKey,
        )
    }
}
