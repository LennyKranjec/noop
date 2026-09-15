package com.noop.ai

// MARK: - Carrying the thread across a reload
//
// The engine holds its conversation in the model's own context, and the only way to clear or fix
// that context is to reload the model (see LocalCoachEngine). So every reload — a new chat, a
// cancelled turn, a model switch — costs the model its memory of what was said, while the wearer is
// still looking at the whole transcript on screen. Asking a follow-up and getting "what mortgage?"
// is the gap this closes.
//
// The system prompt is the one thing the engine accepts at load time, so the prior turns ride in
// there, condensed. Condensed rather than verbatim because prompt processing is the slow half of an
// answer on this hardware: a full transcript would be paid for, in seconds, at every reload.
//
// NOT A MODEL SUMMARY. Running a second inference pass to summarise the first would double the wait
// for a feature whose whole purpose is to keep things responsive. This is a deterministic squeeze —
// recent turns win, each one clipped — which is predictable, instant, and good enough for "remember
// roughly what we were talking about".

object ConversationDigest {

    /** How many trailing turns are carried. Older ones are dropped whole rather than clipped harder. */
    const val MAX_TURNS = 8

    /** How much of one turn survives. Enough for a question and the shape of its answer. */
    const val MAX_CHARS_PER_TURN = 240

    /**
     * A compact record of [history] for the system prompt, or null when there is nothing worth
     * carrying (an empty transcript, or one holding only the question being asked right now).
     *
     * [history] is oldest-first and INCLUDES the question about to be sent; that last turn is left
     * out, because it is delivered as the user prompt immediately afterwards and would otherwise
     * arrive twice.
     */
    fun of(history: List<ChatMsg>): String? {
        val prior = history.dropLast(1).filter { it.text.isNotBlank() }
        if (prior.isEmpty()) return null

        val kept = prior.takeLast(MAX_TURNS)
        val dropped = prior.size - kept.size
        return buildString {
            append("EARLIER IN THIS CONVERSATION")
            if (dropped > 0) append(" (the $dropped turn(s) before these are not included)")
            append(":\n")
            kept.forEach { msg ->
                val who = if (msg.role == "user") "They asked" else "You answered"
                append("- ").append(who).append(": ").append(clip(msg.text)).append('\n')
            }
            append(
                "Continue from this. Do not re-introduce yourself and do not repeat advice you " +
                    "already gave unless they ask again.",
            )
        }
    }

    /** One turn, squeezed to [MAX_CHARS_PER_TURN], cut at a word so it does not end mid-token. */
    private fun clip(text: String): String {
        val flat = text.replace(Regex("\\s+"), " ").trim()
        if (flat.length <= MAX_CHARS_PER_TURN) return flat
        val cut = flat.take(MAX_CHARS_PER_TURN)
        val lastSpace = cut.lastIndexOf(' ')
        return (if (lastSpace > MAX_CHARS_PER_TURN / 2) cut.take(lastSpace) else cut).trimEnd() + "…"
    }
}
