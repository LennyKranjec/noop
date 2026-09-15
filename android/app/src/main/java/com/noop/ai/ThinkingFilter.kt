package com.noop.ai

// MARK: - Dropping a reasoning model's thinking block from the visible answer
//
// Qwen3.5 is a reasoning model: it writes its working inside `<think> … </think>` before the answer
// it means to give. Streamed straight through, the wearer watches a wall of deliberation arrive,
// then the actual reply, with the tags themselves in the middle of it.
//
// This is a STREAMING filter because the tags do not arrive whole: a tag can be split across two
// tokens ("<th" then "ink>"), so a stateless replace on each delta would let the halves through. It
// holds back any trailing text that could still turn into a tag and releases it once it cannot.
//
// WHAT IT DOES NOT DO: hide anything the model actually said to the user. Only the span between the
// tags is dropped.
//
// AN UNTERMINATED `<think>` IS KEPT, NOT BINNED. A small model given a long system prompt can spend
// its whole token budget deliberating and never reach an answer; dropping that left the wearer with
// "(no reply)" after a minute of waiting, which reads as a broken app rather than a model that ran
// out of room. The reasoning is held in [strandedReasoning] so the caller can show it — labelled as
// the working it is — instead of a blank.

class ThinkingFilter(
    private val openTag: String = "<think>",
    private val closeTag: String = "</think>",
) {
    private var inside = false

    /** Text held back because it is a possible partial tag, and must be re-examined next delta. */
    private var pending = StringBuilder()

    /** The span being dropped right now. Emptied into [closedSpans] whenever one closes. */
    private val reasoning = StringBuilder()

    /** Each span that was dropped AND properly closed, in the order they arrived. */
    private val closedSpans = mutableListOf<String>()

    /**
     * The completed dropped spans.
     *
     * The chat uses a second instance of this filter with `[[` / `]]` to keep the coach's reminder
     * directives off the screen (see [CoachDirectives]); those spans are not noise to be discarded
     * like reasoning, they are instructions to be carried out, so they are handed back here.
     */
    fun captured(): List<String> = closedSpans.toList()

    /**
     * Feed one streamed chunk; returns the part of it that belongs in the visible answer.
     *
     * The return is often empty — while inside a thinking block, or while holding a few characters
     * that might be the start of a tag.
     */
    fun push(delta: String): String {
        pending.append(delta)
        val out = StringBuilder()

        while (true) {
            val text = pending.toString()
            if (!inside) {
                val open = text.indexOf(openTag)
                if (open >= 0) {
                    out.append(text, 0, open)
                    pending = StringBuilder(text.substring(open + openTag.length))
                    inside = true
                    continue
                }
                // No complete open tag. Emit everything that cannot be the start of one, and keep
                // the tail that still could be.
                val keep = partialTagSuffix(text, openTag)
                out.append(text, 0, text.length - keep)
                pending = StringBuilder(text.substring(text.length - keep))
                return out.toString()
            } else {
                val close = text.indexOf(closeTag)
                if (close >= 0) {
                    // The span is complete: bank it whole, before `reasoning` accumulates the next one.
                    closedSpans.add(reasoning.toString() + text.substring(0, close))
                    reasoning.clear()
                    pending = StringBuilder(text.substring(close + closeTag.length))
                    inside = false
                    continue
                }
                // Still thinking: drop everything except a possible partial closing tag.
                val keep = partialTagSuffix(text, closeTag)
                reasoning.append(text, 0, text.length - keep)
                pending = StringBuilder(text.substring(text.length - keep))
                return out.toString()
            }
        }
    }

    /**
     * Whatever is left once the stream ends.
     *
     * Inside a thinking block this is empty: the model never reached its answer, and printing its
     * half-finished reasoning HERE would be presenting working as conclusion. [strandedReasoning]
     * is the deliberate, labelled way to show it instead.
     */
    fun flush(): String = if (inside) "" else pending.toString().also { pending = StringBuilder() }

    /**
     * The reasoning of a model that ran out of budget before it closed its thinking block — empty
     * whenever the model did reach its answer, so a caller can treat "not empty" as "there is no
     * answer, only working".
     */
    fun strandedReasoning(): String = if (inside) (reasoning.toString() + pending).trim() else ""

    /** How many trailing characters of [text] could still grow into [tag]. */
    private fun partialTagSuffix(text: String, tag: String): Int {
        val max = minOf(tag.length - 1, text.length)
        for (n in max downTo 1) {
            if (tag.startsWith(text.substring(text.length - n))) return n
        }
        return 0
    }
}
