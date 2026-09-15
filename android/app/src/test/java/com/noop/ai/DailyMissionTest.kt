package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Reading a mission out of what the model actually wrote.
 *
 * The model is now asked for one thing — the mission itself. An earlier version also asked it to price
 * the mission in XP; the currency is gone, so most of what these pin is TOLERANCE: a model that saw
 * thousands of "XP: 40" lines in training still volunteers one occasionally, and it must not reach the
 * card just because nothing asks for it any more.
 */
class DailyMissionTest {

    private val day = "2026-09-15"

    @Test
    fun theMissionIsReadAsWritten() {
        val mission = DailyMissionWriter.parse(
            "Bed by 22:30. Your HRV has been filing complaints.",
            day,
        )!!
        assertEquals("Bed by 22:30. Your HRV has been filing complaints.", mission.text)
        assertEquals(day, mission.dayKey)
    }

    @Test
    fun aVolunteeredScoreLineIsStrippedRatherThanShown() {
        val answer = listOf("XP: 40", "Swim.").joinToString("\n")
        assertEquals("Swim.", DailyMissionWriter.parse(answer, day)!!.text)
    }

    @Test
    fun aMarkdownWrappedScoreLineIsStrippedToo() {
        val answer = listOf("**XP: 55**", "Swim.").joinToString("\n")
        assertEquals("Swim.", DailyMissionWriter.parse(answer, day)!!.text)
    }

    @Test
    fun aScoreMentionedMidSentenceIsLeftAlone() {
        // Only a line that IS the score is dropped. A sentence that happens to contain a number is
        // prose, and cutting it would take a mission's words out of its mouth.
        val answer = "Worth it: 40 minutes of walking."
        assertEquals(answer, DailyMissionWriter.parse(answer, day)!!.text)
    }

    @Test
    fun anAnswerWithNoProseIsNoMission() {
        // A score line and nothing else is not a mission, and storing one would put an empty card on
        // Today.
        assertNull(DailyMissionWriter.parse("XP: 40", day))
        assertNull(DailyMissionWriter.parse("   \n  ", day))
        assertNull(DailyMissionWriter.parse("", day))
    }

    @Test
    fun theMissionIsKeyedToItsDaySoYesterdaysIsNotShownAsTodays() {
        assertEquals(day, DailyMissionWriter.parse("Walk.", day)!!.dayKey)
    }
}
