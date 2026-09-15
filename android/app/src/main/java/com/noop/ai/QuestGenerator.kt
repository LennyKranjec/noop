package com.noop.ai

import android.content.Context
import com.noop.data.DailyMetric
import java.time.LocalDate

// MARK: - Naming a quest
//
// The trigger already decided there is a problem and what the directive is. This asks the model for
// the two parts that should never be the same twice: a TITLE and a TAUNT.
//
// WHY THOSE TWO AND NOTHING ELSE. A generated target is a fabricated number, and a generated trigger
// is a model inventing a reason to nag. Both are things this app does not do. A generated NAME costs
// nothing if it is silly and is the difference between "Step goal" and something the wearer actually
// looks at. The parse below is written so a model that ignores the format entirely still produces a
// usable quest: the target and the XP were never its to decide.

object QuestGenerator {

    /** Titles longer than this are a model rambling, not a name. */
    const val MAX_TITLE_CHARS = 42

    /** The taunt is typed out letter by letter with a haptic per letter, so length is felt, not read. */
    const val MAX_TAUNT_CHARS = 180

    /**
     * Turn [trigger] into a quest, naming it with the model on this phone.
     *
     * Never returns null: if the model is unavailable — not installed, busy with the wearer's own
     * conversation, out of budget — the quest is still issued under a written fallback name. A system
     * that stays silent because its writer was busy is a system that misses the day it was needed.
     */
    suspend fun fromTrigger(context: Context, trigger: QuestTrigger): Quest {
        val written = write(
            context,
            reason = trigger.observation,
            directive = trigger.target,
        )
        return Quest(
            kind = QuestKind.SIDE,
            title = written?.title ?: fallbackTitle(trigger.id),
            taunt = written?.taunt ?: fallbackTaunt(trigger.id),
            target = trigger.target,
            rewards = trigger.rewards,
        )
    }

    /**
     * The day's main quest, from the mission the 06:45 job already wrote.
     *
     * The mission IS the directive here — it was generated from the day's metrics and the wearer's
     * goals — so this only needs a name for it. Its own sarcastic text becomes the taunt.
     */
    suspend fun fromMission(context: Context, mission: DailyMission): Quest {
        val written = write(
            context,
            reason = "Today's directive for them is: ${mission.text}",
            directive = mission.text,
        )
        return Quest(
            kind = QuestKind.DAILY,
            title = written?.title ?: fallbackTitle("daily"),
            // The mission's own text is already the sarcastic line; a second one would be two jokes
            // about the same thing.
            taunt = mission.text.take(MAX_TAUNT_CHARS),
            target = mission.text,
            rewards = rewardsForText(mission.text),
            dayKey = mission.dayKey,
        )
    }

    /** What the model is asked, and how the two lines come back. */
    private suspend fun write(context: Context, reason: String, directive: String): Written? {
        val answer = LocalOneShot.generate(
            context = context,
            // The fast model, always: a quest can be raised at any hour on a phone in a pocket, and two
            // short lines are not worth the deep model's minutes.
            model = LocalModel.FAST,
            systemPrompt = systemPrompt(context),
            question = "Situation: $reason\nDirective: $directive\nName it.",
            maxChars = 260,
        ) ?: return null
        return parse(answer)
    }

    internal fun systemPrompt(context: Context): String = buildString {
        append("You are THE SYSTEM naming a quest for the Player. Cold, theatrical, savagely funny. ")
        append("You are given a situation and a directive. You do NOT change the directive and you do ")
        append("NOT invent numbers.\n\n")
        append("Answer in EXACTLY two lines and nothing else:\n")
        append("TITLE: <a quest name, 2-5 words, no quotation marks>\n")
        append("TAUNT: <one sentence, at most 25 words, mocking the SITUATION and never the person>\n\n")
        append("Example:\n")
        append("TITLE: The Horizontal Hours\n")
        append("TAUNT: Eleven hundred steps. Impressive — most furniture manages that only when moved.\n\n")
        append("Never mock their body or their weight. If the situation involves pain, injury or ")
        append("illness, drop the theatre and write both lines plainly.")
        CoachGoals.promptSection(context)?.let { append("\n\n").append(it) }
    }

    /** Internal, not private: [parse] is internal so the tests can pin it. */
    internal data class Written(val title: String, val taunt: String)

    /**
     * Read the two lines back.
     *
     * Tolerant on purpose. A missing TAUNT is survivable — the fallback covers it — but a missing
     * TITLE means the answer was not a naming at all, so the whole thing is discarded and the caller's
     * written fallback is used instead. Better a stock name than a stray sentence as a quest title.
     */
    internal fun parse(answer: String): Written? {
        val lines = answer.lines().map { it.trim() }.filter { it.isNotBlank() }
        val title = lines.firstNotNullOfOrNull { TITLE.find(it)?.groupValues?.get(1) }
            ?.trim()?.trim('"', '“', '”', '*')
            ?.takeIf { it.isNotBlank() }
            ?: return null
        val taunt = lines.firstNotNullOfOrNull { TAUNT.find(it)?.groupValues?.get(1) }
            ?.trim()?.trim('"', '“', '”', '*')
            .orEmpty()
        return Written(
            title = title.take(MAX_TITLE_CHARS),
            taunt = taunt.take(MAX_TAUNT_CHARS),
        )
    }

    // The asterisks may sit on EITHER side of the colon: a model told to write "TITLE:" and also told
    // to use Markdown produces `**TITLE:** x` about as often as `**TITLE**: x`, and a regex that only
    // allows one of the two silently loses half the answers.
    private val TITLE = Regex("""^\**\s*title\s*\**\s*:\s*\**\s*(.+?)\s*\**$""", RegexOption.IGNORE_CASE)
    private val TAUNT = Regex("""^\**\s*taunt\s*\**\s*:\s*\**\s*(.+?)\s*\**$""", RegexOption.IGNORE_CASE)

    /**
     * Which body systems a directive plausibly touches, read off the words in it.
     *
     * Only used for the DAILY quest, whose directive is free text from the mission writer; a side
     * quest's rewards come from its trigger, which knows exactly what it asked for. Coarse keyword
     * matching, and deliberately so — the alternative is asking the model, which would let it claim a
     * physiological effect, and this app does not do that.
     */
    internal fun rewardsForText(text: String): List<QuestReward> {
        val t = text.lowercase()
        val out = linkedSetOf<QuestReward>()
        if (listOf("sleep", "bed", "nap", "lights out", "schlaf").any(t::contains)) out.add(QuestReward.SLEEP)
        if (listOf("breath", "meditat", "calm", "mindful", "atem").any(t::contains)) {
            out.add(QuestReward.BRAIN)
            out.add(QuestReward.STRESS)
        }
        if (listOf("run", "walk", "steps", "zone 2", "cardio", "cycle", "swim", "row").any(t::contains)) {
            out.add(QuestReward.HEART)
            out.add(QuestReward.LUNGS)
        }
        if (listOf("lift", "strength", "squat", "press", "mobility", "stretch", "dehn").any(t::contains)) {
            out.add(QuestReward.MUSCLE)
        }
        // A directive that matches nothing still improves something, and an empty reward row reads as a
        // bug rather than as modesty.
        return out.toList().ifEmpty { listOf(QuestReward.HEART) }
    }

    private fun fallbackTitle(triggerId: String): String = when (triggerId) {
        "overreach" -> "Enforced Downtime"
        "short-sleep" -> "Debt Collection"
        "sedentary" -> "Proof of Life"
        "idle-streak" -> "Cold Start"
        "hrv-dip" -> "System Reset"
        "daily" -> "Today's Directive"
        else -> "Directive"
    }

    private fun fallbackTaunt(triggerId: String): String = when (triggerId) {
        "overreach" -> "You trained like the data was someone else's. It is not."
        "short-sleep" -> "The night was short. The consequences will not be."
        "sedentary" -> "The step counter checked twice. It stands by its findings."
        "idle-streak" -> "Four days. Your heart rate has forgotten what you look like."
        "hrv-dip" -> "Your nervous system filed a complaint. This is the response."
        else -> "The numbers spoke. This is what they said."
    }

    /**
     * Whether a side quest may be raised for [trigger] today.
     *
     * One per condition per day, and at most [MAX_SIDE_PER_DAY] in total. A system that can raise five
     * quests before lunch is a system the wearer turns off by lunch.
     */
    fun mayRaise(existingToday: List<Quest>, trigger: QuestTrigger, targetOf: (Quest) -> String): Boolean {
        val sideToday = existingToday.count { it.kind == QuestKind.SIDE }
        if (sideToday >= MAX_SIDE_PER_DAY) return false
        return existingToday.none { targetOf(it) == trigger.target }
    }

    const val MAX_SIDE_PER_DAY = 2

    /**
     * The trigger to raise now, given today's data and what has already been issued — or null.
     *
     * Only ONE, even when several fire: they are ordered by urgency in [QuestTriggers.evaluate], and
     * the wearer is shown the most urgent thing that is not already on their list.
     */
    fun nextTrigger(
        today: DailyMetric?,
        recent: List<DailyMetric>,
        existingToday: List<Quest>,
    ): QuestTrigger? {
        val fired = QuestTriggers.evaluate(today, recent)
        return fired.firstOrNull { mayRaise(existingToday, it) { quest -> quest.target } }
    }

    /** Today's date, so callers do not each reach for the clock. */
    fun today(): LocalDate = LocalDate.now()
}
