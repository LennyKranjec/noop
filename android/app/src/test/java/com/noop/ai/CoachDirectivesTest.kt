package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bracket syntax the coach uses to create and delete reminders.
 *
 * What these pin is the boundary between "the model asked for something sensible" and "the model
 * produced bracket-shaped noise". Everything on the wrong side of it must come back as [Unparsed] and
 * be reported, never silently applied and never silently dropped — a coach that says it set a reminder
 * when it did not is the failure this whole design is arranged to avoid.
 */
class CoachDirectivesTest {

    @Test
    fun aReplyWithoutDirectivesIsUntouched() {
        val parsed = CoachDirectives.parse("Sleep more. That is the whole tip.")
        assertEquals("Sleep more. That is the whole tip.", parsed.text)
        assertTrue(parsed.requests.isEmpty())
    }

    @Test
    fun anAddCarriesTimeRepeatAndReason() {
        val parsed = CoachDirectives.parse(
            "Done.\n[[reminder add 22:00 daily Bedtime, they want eight hours]]",
        )
        val add = parsed.requests.single() as CoachDirectives.Request.Add
        assertEquals(22 * 60, add.minuteOfDay)
        assertEquals(ReminderRepeat.DAILY, add.repeat)
        assertEquals("Bedtime, they want eight hours", add.context)
    }

    @Test
    fun theDirectiveNeverReachesTheWearer() {
        val parsed = CoachDirectives.parse(
            "Right.\n\n[[reminder add 07:30 weekdays Morning walk]]\n\nSee you at half seven.",
        )
        assertTrue(!parsed.text.contains("[["))
        assertTrue(!parsed.text.contains("reminder add"))
        // And it leaves no hole where it was.
        assertEquals("Right.\n\nSee you at half seven.", parsed.text)
    }

    @Test
    fun aMissingRepeatKeywordMeansDailyAndTheRestIsReason() {
        val add = CoachDirectives.request("reminder add 06:00 Get up") as CoachDirectives.Request.Add
        assertEquals(ReminderRepeat.DAILY, add.repeat)
        assertEquals("Get up", add.context)
    }

    @Test
    fun aTimeOffTheClockIsRefusedRatherThanClamped() {
        // 25:00 is a model error, not a preference. Clamping it to 23:59 would schedule a reminder the
        // wearer never asked for at a time the coach never meant.
        assertTrue(CoachDirectives.request("reminder add 25:00 daily Nope") is CoachDirectives.Request.Unparsed)
        assertTrue(CoachDirectives.request("reminder add 10pm daily Nope") is CoachDirectives.Request.Unparsed)
    }

    @Test
    fun anAddWithNoReasonIsRefused() {
        // The reason is what the notification gets written from; without it there is nothing to say.
        assertTrue(CoachDirectives.request("reminder add 22:00 daily") is CoachDirectives.Request.Unparsed)
    }

    @Test
    fun aDeleteCarriesWhateverReferenceWasGiven() {
        val del = CoachDirectives.request("reminder del the bedtime one") as CoachDirectives.Request.Delete
        assertEquals("the bedtime one", del.reference)
    }

    @Test
    fun bracketsAroundSomethingElseAreNotAReminderRequest() {
        val parsed = CoachDirectives.parse("Your HRV [[whatever that means]] is fine.")
        assertTrue(parsed.requests.single() is CoachDirectives.Request.Unparsed)
    }

    @Test
    fun aRunawayReasonIsBounded() {
        val long = "word ".repeat(200)
        val add = CoachDirectives.request("reminder add 09:00 daily $long") as CoachDirectives.Request.Add
        assertTrue(add.context.length <= CoachDirectives.MAX_CONTEXT_CHARS)
    }
}
