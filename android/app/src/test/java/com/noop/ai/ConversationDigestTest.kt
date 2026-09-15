package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The digest that carries a conversation across a model reload.
 *
 * What these pin is the CONTRACT the caller depends on: the question being asked right now is never
 * in the digest (it arrives as the user prompt straight after), nothing is carried when there is
 * nothing to carry, and the size is bounded both ways — by turns and by characters — because every
 * character here is paid for in prompt-processing time on the phone.
 */
class ConversationDigestTest {

    private fun user(t: String) = ChatMsg(role = "user", text = t)
    private fun coach(t: String) = ChatMsg(role = "assistant", text = t)

    @Test
    fun anEmptyTranscriptCarriesNothing() {
        assertNull(ConversationDigest.of(emptyList()))
    }

    @Test
    fun theQuestionBeingAskedRightNowIsNotCarried() {
        // One entry = the pending question. It is sent as the user prompt, so a digest of it would
        // deliver the same sentence twice.
        assertNull(ConversationDigest.of(listOf(user("How did I sleep?"))))
    }

    @Test
    fun priorTurnsAreCarriedWithWhoSaidWhat() {
        val digest = ConversationDigest.of(
            listOf(user("How did I sleep?"), coach("Badly. 4h12m."), user("And now?")),
        )!!
        assertTrue(digest.contains("They asked: How did I sleep?"))
        assertTrue(digest.contains("You answered: Badly. 4h12m."))
        // The pending question stays out.
        assertTrue(!digest.contains("And now?"))
    }

    @Test
    fun onlyTheLastTurnsSurviveAndTheDropIsStated() {
        val many = (1..20).map { user("question $it") } + user("pending")
        val digest = ConversationDigest.of(many)!!
        assertTrue(digest.contains("question 20"))
        assertTrue(!digest.contains("question 1:"))
        // Honest about what is missing rather than silently presenting a partial history as whole.
        assertTrue(digest.contains("not included"))
    }

    @Test
    fun aLongTurnIsClippedAtAWordAndMarked() {
        val long = "word ".repeat(200)
        val digest = ConversationDigest.of(listOf(coach(long), user("next")))!!
        assertTrue(digest.contains("…"))
        // Bounded: the clip plus the framing, nowhere near the original.
        assertTrue(digest.length < long.length)
    }

    @Test
    fun blankTurnsAreIgnored() {
        // A cancelled turn can leave an empty assistant bubble; it carries nothing.
        assertNull(ConversationDigest.of(listOf(coach("   "), user("pending"))))
    }

    @Test
    fun newlinesAreFlattenedSoOneTurnStaysOneLine() {
        val digest = ConversationDigest.of(listOf(coach("a\n\nb\nc"), user("next")))!!
        assertTrue(digest.contains("You answered: a b c"))
        assertEquals(1, digest.lines().count { it.startsWith("- You answered") })
    }
}
