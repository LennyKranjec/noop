package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * The reminder model: when one fires, how it survives a round trip through storage, and how a loose
 * reference from the coach resolves.
 *
 * The resolve cases are the ones that matter. The coach is asked to "delete the bedtime one" and has to
 * turn that into exactly one reminder or nothing — an ambiguous match that guesses would delete
 * something the wearer set up, which is the one outcome worse than failing to delete anything.
 */
class ReminderTest {

    private fun at(time: String, repeat: ReminderRepeat = ReminderRepeat.DAILY, ctx: String = "x") =
        Reminder(
            context = ctx,
            minuteOfDay = time.substringBefore(':').toInt() * 60 + time.substringAfter(':').toInt(),
            repeat = repeat,
        )

    // 2026-09-14 is a Monday, 2026-09-19 a Saturday.
    private val monday = LocalDate.of(2026, 9, 14)
    private val saturday = LocalDate.of(2026, 9, 19)

    @Test
    fun timeIsZeroPaddedRegardlessOfLocale() {
        assertEquals("07:05", at("7:5").timeLabel)
        assertEquals("22:00", at("22:0").timeLabel)
    }

    @Test
    fun repeatRulesDecideTheDay() {
        assertTrue(at("22:00", ReminderRepeat.DAILY).firesOn(saturday))
        assertTrue(at("22:00", ReminderRepeat.WEEKDAYS).firesOn(monday))
        assertTrue(!at("22:00", ReminderRepeat.WEEKDAYS).firesOn(saturday))
        assertTrue(at("22:00", ReminderRepeat.WEEKENDS).firesOn(saturday))
        assertTrue(!at("22:00", ReminderRepeat.WEEKENDS).firesOn(monday))
    }

    @Test
    fun weeklyFiresOnItsOwnWeekday() {
        val weekly = at("22:00", ReminderRepeat.WEEKLY).copy(weekday = monday.dayOfWeek.value)
        assertTrue(weekly.firesOn(monday))
        assertTrue(!weekly.firesOn(saturday))
    }

    @Test
    fun aDisabledReminderNeverFires() {
        assertTrue(!at("22:00").copy(enabled = false).firesOn(monday))
    }

    @Test
    fun storageIsARoundTrip() {
        val list = listOf(
            at("22:00", ReminderRepeat.DAILY, "Bedtime"),
            at("07:30", ReminderRepeat.WEEKDAYS, "Walk"),
        )
        val back = ReminderStore.decode(ReminderStore.encode(list))
        assertEquals(list.map { it.timeLabel }, back.map { it.timeLabel })
        assertEquals(list.map { it.context }, back.map { it.context })
        assertEquals(list.map { it.repeat }, back.map { it.repeat })
    }

    @Test
    fun storedNonsenseIsClampedNotTrusted() {
        // This JSON is also written from a directive a language model produced, so a minute of 9999
        // has to become a schedulable time rather than a job that never fires.
        val back = ReminderStore.decode("""[{"id":"a","context":"x","minute":9999,"repeat":"nope"}]""")
        assertEquals(1, back.size)
        assertTrue(back.single().minuteOfDay in 0..(24 * 60 - 1))
        assertEquals(ReminderRepeat.DAILY, back.single().repeat)
    }

    @Test
    fun anEntryWithNoContextIsDroppedRatherThanShownEmpty() {
        assertTrue(ReminderStore.decode("""[{"id":"a","minute":60}]""").isEmpty())
    }

    @Test
    fun aReferenceResolvesByText() {
        val list = listOf(at("22:00", ctx = "Bedtime, eight hours"), at("07:30", ctx = "Morning walk"))
        assertEquals("Bedtime, eight hours", ReminderStore.resolve(list, "bedtime")?.context)
    }

    @Test
    fun aReferenceResolvesByTime() {
        val list = listOf(at("22:00", ctx = "Bedtime"), at("07:30", ctx = "Walk"))
        assertEquals("Walk", ReminderStore.resolve(list, "07:30")?.context)
    }

    @Test
    fun anAmbiguousReferenceResolvesToNothing() {
        // Two reminders mention walking. Picking one would delete something they did not name.
        val list = listOf(at("07:30", ctx = "Morning walk"), at("18:00", ctx = "Evening walk"))
        assertNull(ReminderStore.resolve(list, "walk"))
    }

    @Test
    fun anEmptyReferenceResolvesToNothing() {
        assertNull(ReminderStore.resolve(listOf(at("22:00")), "   "))
    }
}
