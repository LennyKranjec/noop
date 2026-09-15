package com.noop.ai

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The streaming `<think>` filter.
 *
 * The cases that matter are the SPLIT ones: a reasoning model's tags arrive in pieces, and a naive
 * per-chunk replace passes the halves straight through to the wearer. Each test below feeds the
 * stream the way the engine does — one delta at a time — and asserts on what the UI would show.
 */
class ThinkingFilterTest {

    private fun run(vararg deltas: String): String {
        val f = ThinkingFilter()
        val sb = StringBuilder()
        deltas.forEach { sb.append(f.push(it)) }
        sb.append(f.flush())
        return sb.toString()
    }

    @Test
    fun textWithoutAnyThinkingPassesThroughUnchanged() {
        assertEquals("Sleep more tonight.", run("Sleep ", "more ", "tonight."))
    }

    @Test
    fun aWholeThinkingBlockIsDropped() {
        assertEquals(
            "Go easy today.",
            run("<think>", "charge is 34, so hold back", "</think>", "Go easy today."),
        )
    }

    @Test
    fun tagsSplitAcrossDeltasAreStillRecognised() {
        // The naive implementation fails exactly here: neither chunk contains a whole tag.
        assertEquals(
            "Answer.",
            run("<th", "ink>", "reasoning...", "</thi", "nk>", "Answer."),
        )
    }

    @Test
    fun textBeforeAndAfterTheBlockSurvives() {
        assertEquals(
            "Before. After.",
            run("Before. ", "<think>hidden</think>", "After."),
        )
    }

    @Test
    fun anUnterminatedThinkingBlockYieldsNothingRatherThanRawReasoning() {
        // A generation cut short mid-thought: the caller renders its own "no reply", which is
        // honest. Dumping the working would present deliberation as an answer.
        assertEquals("", run("<think>", "half a thought and then the stream died"))
    }

    @Test
    fun aLoneAngleBracketIsNotSwallowed() {
        assertEquals("HRV < 40 is low.", run("HRV < 40 ", "is low."))
    }

    @Test
    fun twoBlocksInOneStreamAreBothDropped() {
        assertEquals(
            "A B",
            run("<think>x</think>", "A ", "<think>y</think>", "B"),
        )
    }

    @Test
    fun theWorkingOfAnAnswerThatNeverArrivedIsKeptForTheCaller() {
        // The 0.8B model's failure mode: it spends the whole budget deliberating, so there is no
        // answer to show. The caller needs the working to explain that, rather than a blank bubble.
        val f = ThinkingFilter()
        f.push("<think>the numbers say ")
        f.push("she is fried, so")
        assertEquals("", f.flush())
        assertEquals("the numbers say she is fried, so", f.strandedReasoning())
    }

    @Test
    fun nothingIsStrandedWhenTheModelDidReachItsAnswer() {
        // "Not empty" must mean "there is no answer", or the caller would show working alongside one.
        val f = ThinkingFilter()
        f.push("<think>working</think>Sleep more.")
        assertEquals("", f.strandedReasoning())
    }
}
