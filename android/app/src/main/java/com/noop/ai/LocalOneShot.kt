package com.noop.ai

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// MARK: - One question, one answer, nobody watching
//
// The chat is not the only thing that needs the model: a reminder firing at 22:00 needs a sentence
// written, and the daily mission needs one at 06:45. Neither has a screen open, neither streams, and
// both run in a WorkManager job that Android may kill — so they want a different shape from
// [AiCoach.chatStreamLocal]: load, ask once, collect the whole answer, done.
//
// THE ENGINE IS ONE RESOURCE AND THIS TAKES ITS TURN. A background generation that started while the
// wearer was mid-conversation would reload the model out from under them — the same "Cannot load model
// in ModelReady" class of bug that cost a day. [LocalCoachEngine.lane] serialises the two, and a
// one-shot that cannot get the lane gives up rather than queueing: a notification that arrives ten
// minutes late because it waited for a chat to finish is worse than one that falls back to a plain
// string.

object LocalOneShot {

    /** How long a generated notification or mission may be. Past this the model is rambling. */
    const val MAX_CHARS = 400

    /**
     * Ask [model] one question with [systemPrompt] as its framing, and return the whole answer.
     *
     * Returns null — never throws — when the model is not installed, the device cannot run it, the
     * engine is busy with the wearer's own conversation, or the answer came back empty. Every caller
     * here is a scheduled job whose job is to post SOMETHING useful, so each has a written fallback
     * and none of them should die because inference was unavailable.
     */
    suspend fun generate(
        context: Context,
        model: LocalModel,
        systemPrompt: String,
        question: String,
        maxChars: Int = MAX_CHARS,
    ): String? = withContext(Dispatchers.IO) {
        if (!LocalCoachEngine.isSupported) return@withContext null
        if (!LocalModelStore.isInstalled(context, model)) return@withContext null

        val answer = LocalCoachEngine.tryInLane {
            LocalCoachEngine.ensureLoaded(context, model)
            LocalCoachEngine.setSystemPrompt(systemPrompt)
            val thinking = ThinkingFilter()
            val sb = StringBuilder()
            LocalCoachEngine.ask(question).collect { delta ->
                sb.append(thinking.push(delta))
            }
            sb.append(thinking.flush())
            // A headless caller cannot show working, so a model that only deliberated has produced
            // nothing usable and the caller's fallback is the honest outcome.
            sb.toString().trim()
        } ?: return@withContext null

        // The next chat turn must not inherit this turn's context: the wearer never saw it, and a
        // reply that continues from a notification they did not read is baffling.
        LocalCoachEngine.resetConversation()

        answer.takeIf { it.isNotEmpty() }?.let { clip(it, maxChars) }
    }

    /** Cut at a sentence end if there is one in range, otherwise at a word. Never mid-word. */
    internal fun clip(text: String, maxChars: Int): String {
        val flat = text.replace(Regex("\\s+"), " ").trim()
        if (flat.length <= maxChars) return flat
        val cut = flat.take(maxChars)
        val lastStop = cut.lastIndexOfAny(charArrayOf('.', '!', '?'))
        if (lastStop > maxChars / 2) return cut.take(lastStop + 1)
        val lastSpace = cut.lastIndexOf(' ')
        return (if (lastSpace > maxChars / 2) cut.take(lastSpace) else cut).trimEnd() + "…"
    }
}
