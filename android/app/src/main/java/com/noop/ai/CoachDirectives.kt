package com.noop.ai

// MARK: - Letting the coach act, not just talk
//
// The coach can create and delete reminders. It does that by writing a directive into its reply, which
// this strips out before the wearer sees it:
//
//     [[reminder add 22:00 daily Bedtime — you said you wanted eight hours]]
//     [[reminder del bedtime]]
//
// WHY A TEXT DIRECTIVE AND NOT TOOL-CALLING. Proper function calling needs the model to emit
// well-formed JSON inside a tool block, and needs the runtime to feed the result back as a tool
// message. The engine here has no tool channel at all, and a 0.8B model asked for JSON produces
// something JSON-shaped about as often as not. A single bracketed line is the largest instruction this
// model follows reliably, and a malformed one degrades to "nothing happened" rather than to a crash.
//
// WHAT THIS DELIBERATELY DOES NOT DO: act on anything it is not certain about. A directive that does
// not parse is dropped and REPORTED as dropped, so the wearer is never told a reminder exists because
// the model said the words. The store is what decides whether something was created; this only asks.

object CoachDirectives {

    /** `[[ … ]]` anywhere in the reply, across lines, greedy-free so two on one line both match. */
    private val BLOCK = Regex("""\[\[(.+?)]]""", RegexOption.DOT_MATCHES_ALL)

    /** `HH:mm` or `H:mm`, 24-hour. A coach writing "10pm" is asking for a reminder that never fires. */
    private val TIME = Regex("""^(\d{1,2}):(\d{2})$""")

    /** One request the model made. [Add] and [Delete] are applied; [Unparsed] is reported, not applied. */
    sealed interface Request {
        data class Add(val minuteOfDay: Int, val repeat: ReminderRepeat, val context: String) : Request
        data class Delete(val reference: String) : Request
        data class Unparsed(val raw: String) : Request
    }

    /** The reply with every directive removed, plus what those directives asked for. */
    data class Parsed(val text: String, val requests: List<Request>)

    /**
     * Pull the directives out of [reply].
     *
     * The returned text is what the wearer reads: directives gone, and the whitespace they leave
     * behind collapsed so a reminder created mid-sentence does not leave a gap or a stranded blank
     * line. Everything else is untouched — this must never rewrite the coach's actual words.
     */
    fun parse(reply: String): Parsed {
        val requests = mutableListOf<Request>()
        val stripped = BLOCK.replace(reply) { match ->
            requests.add(request(match.groupValues[1].trim()))
            ""
        }
        return Parsed(text = tidy(stripped), requests = requests)
    }

    /**
     * One directive's body — what was between the brackets, without them.
     *
     * Public because the streaming path never has the whole reply in one string: the chat hides
     * directives with a streaming filter as the tokens arrive and hands the captured bodies here.
     */
    fun request(body: String): Request {
        val words = body.split(Regex("""\s+"""))
        if (!words.first().equals("reminder", ignoreCase = true) || words.size < 3) {
            return Request.Unparsed(body)
        }
        return when (words[1].lowercase()) {
            "add", "new", "create" -> parseAdd(words.drop(2), body)
            "del", "delete", "remove" -> Request.Delete(words.drop(2).joinToString(" "))
            else -> Request.Unparsed(body)
        }
    }

    private fun parseAdd(rest: List<String>, raw: String): Request {
        val time = TIME.matchEntire(rest.firstOrNull().orEmpty()) ?: return Request.Unparsed(raw)
        val hour = time.groupValues[1].toInt()
        val minute = time.groupValues[2].toInt()
        // A time outside the clock is a model error, not a reminder: 25:00 would schedule nothing.
        if (hour > 23 || minute > 59) return Request.Unparsed(raw)

        val repeatWord = rest.getOrNull(1)
        val repeat = ReminderRepeat.entries.firstOrNull { it.name.equals(repeatWord, ignoreCase = true) }
        // The repeat keyword is optional; without one the rest is all context and the rule is daily.
        val contextWords = if (repeat == null) rest.drop(1) else rest.drop(2)
        val context = contextWords.joinToString(" ").trim().trim('—', '-', ':').trim()
        if (context.isEmpty()) return Request.Unparsed(raw)

        return Request.Add(
            minuteOfDay = hour * 60 + minute,
            repeat = repeat ?: ReminderRepeat.DAILY,
            context = context.take(MAX_CONTEXT_CHARS),
        )
    }

    /** Context is what the notification is written from, not an essay. Bounded so the prompt stays small. */
    const val MAX_CONTEXT_CHARS = 160

    /**
     * Close the hole a removed directive leaves: trailing spaces on a line, and runs of blank lines
     * collapsed to one. Leading/trailing whitespace of the whole reply goes too.
     */
    private fun tidy(text: String): String = text
        .lines()
        .joinToString("\n") { it.trimEnd() }
        .replace(Regex("""\n{3,}"""), "\n\n")
        .trim()

    /**
     * The instruction block that teaches the model the syntax, appended to the system prompt.
     *
     * Kept to the two operations that exist, with one example each and an explicit "say it in words
     * too" — the wearer has to be able to read what happened without knowing the syntax, and a model
     * that emits only a directive would leave them staring at an empty reply.
     */
    fun systemPromptSection(existing: List<Reminder>): String = buildString {
        append("REMINDERS. You can create and delete the user's reminders by writing ONE line exactly ")
        append("like these, and then saying in plain words what you did:\n")
        append("[[reminder add 22:00 daily Bedtime, they want eight hours]]\n")
        append("[[reminder del bedtime]]\n")
        append("Repeat must be daily, weekdays, weekends or weekly. Time must be 24-hour HH:MM. ")
        append("The text after it is the reason, which is what the notification will be written from, ")
        append("so make it specific. Only ever do this when they ask for a reminder — never as a ")
        append("suggestion, and never more than one per reply.\n")
        if (existing.isEmpty()) {
            append("They have no reminders set.")
        } else {
            append("Their current reminders:\n")
            existing.forEach { r ->
                append("- ").append(r.timeLabel).append(' ')
                append(r.repeat.name.lowercase()).append(": ").append(r.context).append('\n')
            }
        }
    }
}
