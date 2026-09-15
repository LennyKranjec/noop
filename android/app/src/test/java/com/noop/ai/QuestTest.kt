package com.noop.ai

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Quests: the clock, the storage round trip, and — the part that matters most — the line between what
 * the DATA decides and what the MODEL decides.
 *
 * A language model handed a day of metrics will happily invent both a reason to nag and a number to
 * nag about. The triggers exist so it never gets the chance: it names the quest, it does not raise one.
 */
class QuestTest {

    private fun quest(xp: Int = 40, expiresInMs: Long = 3_600_000) = Quest(
        kind = QuestKind.SIDE,
        title = "Proof of Life",
        taunt = "The step counter checked twice.",
        target = "8000 steps",
        rewards = listOf(QuestReward.HEART),
        xp = xp,
        expiresAtMs = System.currentTimeMillis() + expiresInMs,
    )

    @Test
    fun theCountdownIsZeroPaddedAndCountsDownTheClock() {
        assertEquals("00:00:00", Quest.formatRemaining(0))
        assertEquals("00:00:09", Quest.formatRemaining(9_000))
        assertEquals("01:02:03", Quest.formatRemaining(3_723_000))
        assertEquals("23:59:59", Quest.formatRemaining(86_399_000))
    }

    @Test
    fun aNegativeRemainderReadsAsZeroRatherThanAsNegativeTime() {
        // The window closed while the screen was off. "-00:04:12" is not a thing a countdown may show.
        val past = quest(expiresInMs = -60_000)
        assertEquals(0L, past.remainingMs())
        assertTrue(past.isExpired())
        assertEquals("00:00:00", Quest.formatRemaining(past.remainingMs()))
    }

    @Test
    fun everyQuestHasADeadlineEvenWhenNobodySetOne() {
        // A directive with no clock is a suggestion, so the default is a real window and not "never".
        val q = Quest(
            kind = QuestKind.DAILY,
            title = "t", taunt = "x", target = "y",
            rewards = emptyList(), xp = 10,
        )
        assertTrue(q.expiresAtMs > System.currentTimeMillis())
        assertTrue(q.remainingMs() <= Quest.DEFAULT_WINDOW_MS)
    }

    @Test
    fun storageIsARoundTripIncludingTheDeadline() {
        val q = quest()
        val back = QuestStore.decode(QuestStore.encode(listOf(q))).single()
        assertEquals(q.id, back.id)
        assertEquals(q.target, back.target)
        assertEquals(q.rewards, back.rewards)
        assertEquals(q.xp, back.xp)
        assertEquals(q.expiresAtMs, back.expiresAtMs)
    }

    @Test
    fun aRecordFromBeforeDeadlinesExistedGetsOneRatherThanExpiringAtOnce() {
        val created = System.currentTimeMillis()
        val raw = """[{"id":"a","kind":"SIDE","title":"t","taunt":"x","target":"y","xp":20,
            "state":"ACTIVE","day":"2026-09-15","createdAt":$created}]"""
        val back = QuestStore.decode(raw).single()
        assertTrue(!back.isExpired())
        assertEquals(created + Quest.DEFAULT_WINDOW_MS, back.expiresAtMs)
    }

    @Test
    fun anXpFigureFromAModelIsClampedOnTheWayIn() {
        val raw = """[{"id":"a","kind":"SIDE","title":"t","taunt":"x","target":"y","xp":99999}]"""
        assertEquals(QuestStore.MAX_XP, QuestStore.decode(raw).single().xp)
    }

    // --- Triggers: what the DATA is allowed to decide -------------------------------------------

    private fun day(
        steps: Int? = null,
        strain: Double? = null,
        recovery: Double? = null,
        sleepMin: Double? = null,
        hrv: Double? = null,
        dayKey: String = "2026-09-15",
    ) = DailyMetric(
        deviceId = "d", day = dayKey, steps = steps, strain = strain,
        recovery = recovery, totalSleepMin = sleepMin, avgHrv = hrv,
    )

    @Test
    fun nothingIsRaisedWithoutData() {
        // A phone with nothing synced has no grounds to nag, and inventing one would be the whole
        // failure mode this design exists to prevent.
        assertTrue(QuestTriggers.evaluate(null, emptyList()).isEmpty())
        assertTrue(QuestTriggers.evaluate(day(), emptyList()).isEmpty())
    }

    @Test
    fun aSedentaryDayRaisesAStepQuestWithTheTargetInIt() {
        val fired = QuestTriggers.evaluate(day(steps = 900), emptyList())
        val sedentary = fired.single { it.id == "sedentary" }
        assertTrue(sedentary.target.contains(QuestTriggers.STEPS_TARGET.toString()))
        assertTrue(sedentary.rewards.contains(QuestReward.HEART))
    }

    @Test
    fun aMissingStepCountIsNotAStillDay() {
        // Null is a sensor that is not reporting. Treating it as zero would nag people whose phone
        // simply does not count steps, every single day.
        assertTrue(QuestTriggers.evaluate(day(steps = null), emptyList()).none { it.id == "sedentary" })
    }

    @Test
    fun hardTrainingOnNoRecoveryIsTheMostUrgentThing() {
        val fired = QuestTriggers.evaluate(day(strain = 16.0, recovery = 20.0, steps = 500), emptyList())
        assertEquals("overreach", fired.first().id)
    }

    @Test
    fun lowHrvIsJudgedAgainstTheirOwnBaselineNotAnAbsoluteNumber() {
        // 40ms is unremarkable for one person and alarming for another; only the deviation means
        // anything, so an absolute threshold would be a fabricated standard.
        val steady = (1..8).map { day(hrv = 100.0, dayKey = "2026-09-0$it") }
        assertTrue(QuestTriggers.evaluate(day(hrv = 40.0), steady).any { it.id == "hrv-dip" })
        assertTrue(QuestTriggers.evaluate(day(hrv = 95.0), steady).none { it.id == "hrv-dip" })
    }

    @Test
    fun aBaselineTooShortToMeanAnythingRaisesNothing() {
        val thin = (1..3).map { day(hrv = 100.0, dayKey = "2026-09-0$it") }
        assertTrue(QuestTriggers.evaluate(day(hrv = 40.0), thin).none { it.id == "hrv-dip" })
    }

    @Test
    fun theSameConditionCannotRaiseTwoQuestsInADay() {
        val trigger = QuestTriggers.evaluate(day(steps = 100), emptyList()).single { it.id == "sedentary" }
        val already = listOf(quest().copy(target = trigger.target))
        assertTrue(!QuestGenerator.mayRaise(already, trigger) { it.target })
    }

    @Test
    fun theDailySideQuestBudgetIsAHardStop() {
        val trigger = QuestTriggers.evaluate(day(steps = 100), emptyList()).single { it.id == "sedentary" }
        val full = List(QuestGenerator.MAX_SIDE_PER_DAY) { quest().copy(target = "other $it") }
        assertTrue(!QuestGenerator.mayRaise(full, trigger) { it.target })
    }

    // --- Naming: what the MODEL is allowed to decide ---------------------------------------------

    @Test
    fun theTwoLineNamingIsRead() {
        val w = QuestGenerator.parse("TITLE: The Horizontal Hours\nTAUNT: Eleven hundred steps.")!!
        assertEquals("The Horizontal Hours", w.title)
        assertEquals("Eleven hundred steps.", w.taunt)
    }

    @Test
    fun markdownAndQuotesAroundTheNameAreStripped() {
        val w = QuestGenerator.parse("**TITLE:** “Cold Start”\n**TAUNT:** Four days.")!!
        assertEquals("Cold Start", w.title)
    }

    @Test
    fun anAnswerWithNoTitleIsNotANaming() {
        // The caller falls back to a written name. A stray sentence used as a quest title would be
        // worse than a stock one.
        assertNull(QuestGenerator.parse("Sure! Here is a quest for you."))
    }

    @Test
    fun aRamblingTitleIsBounded() {
        val long = "TITLE: " + "word ".repeat(50)
        assertTrue(QuestGenerator.parse(long)!!.title.length <= QuestGenerator.MAX_TITLE_CHARS)
    }

    @Test
    fun rewardsAreReadOffTheDirectiveRatherThanAskedFor() {
        assertTrue(QuestGenerator.rewardsForText("Bed by 22:30").contains(QuestReward.SLEEP))
        assertTrue(QuestGenerator.rewardsForText("10 minutes of breathing").contains(QuestReward.BRAIN))
        assertTrue(QuestGenerator.rewardsForText("8000 steps").contains(QuestReward.HEART))
        // A directive that matches nothing still improves something: an empty row reads as a bug.
        assertTrue(QuestGenerator.rewardsForText("do the thing").isNotEmpty())
    }

    @Test
    fun germanDirectivesMatchToo() {
        // The directive is written in the wearer's own language, so the stems have to cover it.
        assertTrue(QuestGenerator.rewardsForText("Schlafenszeit um 22:00").contains(QuestReward.SLEEP))
        assertTrue(QuestGenerator.rewardsForText("10 Minuten Atemübung").contains(QuestReward.STRESS))
        assertTrue(QuestGenerator.rewardsForText("Beine dehnen").contains(QuestReward.MUSCLE))
    }

    @Test
    fun theRewardOrderIsFixedSoBothPlatformsDrawTheSameRow() {
        // PARITY PIN. The Swift twin `QuestNamingTests` asserts this exact sequence; a different order
        // on either side puts the icons on the card in a different order on that platform.
        assertEquals(
            listOf(
                QuestReward.SLEEP, QuestReward.BRAIN, QuestReward.STRESS,
                QuestReward.HEART, QuestReward.LUNGS, QuestReward.MUSCLE,
            ),
            QuestGenerator.rewardsForText("Walk, then stretch, then bed early, and breathe"),
        )
    }
}
