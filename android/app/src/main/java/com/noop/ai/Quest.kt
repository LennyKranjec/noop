package com.noop.ai

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.util.UUID

// MARK: - Quests
//
// The system issues quests. A DAILY one every morning, and SIDE quests whenever the numbers say
// something is wrong in a way the wearer can fix today — no steps at all, a week of hammering with no
// recovery, a night that undid the last three.
//
// WHAT MAKES IT A QUEST AND NOT A NOTIFICATION: it is concrete, it is bounded, it has a price on it,
// and it has to be ACCEPTED. A push that says "consider stretching" is ignorable in a way that a card
// demanding an answer is not, and accepting is the wearer choosing, which is the only reason any of
// this works.
//
// THE TITLE AND THE TAUNT ARE GENERATED; THE TRIGGER AND THE TARGET ARE NOT. A model writes the name
// and the one-line insult because those are the parts that should never repeat. It does NOT decide
// that today deserves a mobility quest, and it does not invent the number: those come from the
// wearer's own metrics through [QuestTrigger], because a language model asked to read a day's data and
// set a target will cheerfully invent both. See QuestGenerator.

/** Where a quest came from. Decides its weight, its XP band and whether it interrupts. */
enum class QuestKind {
    /** The 06:45 mission, promoted. One a day, always issued. */
    DAILY,

    /** Raised by a condition in the data. Zero or several a day. */
    SIDE,
}

/**
 * What finishing a quest is supposed to improve — shown as an icon on the card.
 *
 * Deliberately coarse and honest: these are the systems a directive plausibly touches, not a claim
 * about a measured effect. "Meditation improves your stress" is a reasonable thing to say on a card;
 * "meditation will lower your RHR by 2 bpm" would be a fabricated number, which this app does not do.
 */
enum class QuestReward {
    HEART,
    LUNGS,
    BRAIN,
    MUSCLE,
    SLEEP,
    STRESS,
}

/** Where a quest is in its life. */
enum class QuestState {
    /** Issued, shown as a pop-up, waiting for the wearer to accept it. */
    OFFERED,

    /** Accepted. Visible under the XP bar until it is finished or the day ends. */
    ACTIVE,

    /** The wearer says it is done. XP claimed once, through [com.noop.gamify.XpLedger]. */
    COMPLETED,

    /** Offered and turned down, or expired unfinished. Kept briefly so it is not re-issued at once. */
    DECLINED,
}

/**
 * One quest.
 *
 * [target] is the thing to actually do, in plain words with the number in it ("8,000 steps",
 * "10 minutes of mobility"). [taunt] is the sarcastic line the card types out. [title] is the name the
 * model gave it. All three are shown; only the first is a commitment.
 */
data class Quest(
    val id: String = UUID.randomUUID().toString(),
    val kind: QuestKind,
    val title: String,
    val taunt: String,
    val target: String,
    val rewards: List<QuestReward>,
    val xp: Int,
    val state: QuestState = QuestState.OFFERED,
    val dayKey: String = LocalDate.now().toString(),
    val createdAtMs: Long = System.currentTimeMillis(),
    /**
     * When it stops counting, as epoch milliseconds.
     *
     * EVERY QUEST HAS ONE. A directive with no deadline is a suggestion, and the countdown is most of
     * what separates the two: "8,000 steps" is advice, "8,000 steps in 14:22:07" is a quest. Defaults
     * to [DEFAULT_WINDOW_MS] from issue, which lands the daily quest on roughly the next morning.
     */
    val expiresAtMs: Long = System.currentTimeMillis() + DEFAULT_WINDOW_MS,
) {
    /** The ledger key, so one quest pays out exactly once however many times the button is tapped. */
    val claimKey: String get() = "quest-$id"

    /** Milliseconds left, floored at zero. */
    fun remainingMs(nowMs: Long = System.currentTimeMillis()): Long =
        (expiresAtMs - nowMs).coerceAtLeast(0L)

    /** Whether the window has closed. An expired quest cannot be completed for XP. */
    fun isExpired(nowMs: Long = System.currentTimeMillis()): Boolean = nowMs >= expiresAtMs

    companion object {
        /** A day, which is what "before this is over" means for everything the triggers ask for. */
        const val DEFAULT_WINDOW_MS = 24L * 60 * 60 * 1000

        /**
         * `HH:MM:SS` of what is left.
         *
         * Zero-padded and locale-independent: this is a countdown, not a formatted duration, and it has
         * to be the same width on every tick or the whole row jitters as the digits change.
         */
        fun formatRemaining(ms: Long): String {
            val total = (ms / 1000).coerceAtLeast(0)
            return "%02d:%02d:%02d".format(total / 3600, (total % 3600) / 60, total % 60)
        }
    }
}

object QuestStore {

    private const val KEY = "system.quests"

    /** How many are kept. Enough for a week of history; the list is read on every Today render. */
    const val MAX_KEPT = 40

    /** The XP a quest may be worth, whatever a model suggests. */
    const val MIN_XP = 10
    const val MAX_XP = 150

    fun all(context: Context): List<Quest> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return runCatching { decode(raw) }.getOrDefault(emptyList())
    }

    /**
     * The quest waiting to be answered, if any.
     *
     * ONE AT A TIME. Two pop-ups stacked on top of each other is a dialog fight, and a wearer who is
     * shown three quests at once accepts none of them. The rest keep their turn.
     */
    fun offered(context: Context): Quest? =
        all(context).firstOrNull { it.state == QuestState.OFFERED }

    /** What the wearer has taken on and not yet finished, newest first. */
    fun active(context: Context): List<Quest> =
        all(context).filter { it.state == QuestState.ACTIVE }.sortedByDescending { it.createdAtMs }

    /** Today's quests in every state, for deciding whether a trigger has already fired. */
    fun forDay(context: Context, day: LocalDate = LocalDate.now()): List<Quest> =
        all(context).filter { it.dayKey == day.toString() }

    fun upsert(context: Context, quest: Quest): List<Quest> {
        val current = all(context)
        val next = if (current.any { it.id == quest.id }) {
            current.map { if (it.id == quest.id) quest else it }
        } else {
            current + quest
        }
        // Oldest fall off the end. A quest from three weeks ago is history nobody reads, and this list
        // is parsed on every Today render.
        return write(context, next.sortedBy { it.createdAtMs }.takeLast(MAX_KEPT))
    }

    fun setState(context: Context, id: String, state: QuestState): Quest? {
        val quest = all(context).firstOrNull { it.id == id } ?: return null
        val updated = quest.copy(state = state)
        upsert(context, updated)
        return updated
    }

    private fun write(context: Context, list: List<Quest>): List<Quest> {
        prefs(context).edit().putString(KEY, encode(list)).apply()
        return list
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)

    internal fun encode(list: List<Quest>): String {
        val arr = JSONArray()
        list.forEach { q ->
            arr.put(
                JSONObject()
                    .put("id", q.id)
                    .put("kind", q.kind.name)
                    .put("title", q.title)
                    .put("taunt", q.taunt)
                    .put("target", q.target)
                    .put("rewards", JSONArray(q.rewards.map { it.name }))
                    .put("xp", q.xp)
                    .put("state", q.state.name)
                    .put("day", q.dayKey)
                    .put("createdAt", q.createdAtMs)
                    .put("expiresAt", q.expiresAtMs),
            )
        }
        return arr.toString()
    }

    internal fun decode(raw: String): List<Quest> {
        val arr = JSONArray(raw)
        val out = ArrayList<Quest>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val target = o.optString("target").takeIf { it.isNotBlank() } ?: continue
            val rewardsJson = o.optJSONArray("rewards")
            val rewards = buildList {
                for (j in 0 until (rewardsJson?.length() ?: 0)) {
                    val name = rewardsJson?.optString(j) ?: continue
                    QuestReward.entries.firstOrNull { it.name == name }?.let(::add)
                }
            }
            out.add(
                Quest(
                    id = o.optString("id").takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString(),
                    kind = QuestKind.entries.firstOrNull { it.name == o.optString("kind") } ?: QuestKind.SIDE,
                    title = o.optString("title").ifBlank { target },
                    taunt = o.optString("taunt"),
                    target = target,
                    rewards = rewards,
                    // Clamped, not trusted: part of this record came from a language model.
                    xp = o.optInt("xp", MIN_XP).coerceIn(MIN_XP, MAX_XP),
                    state = QuestState.entries.firstOrNull { it.name == o.optString("state") }
                        ?: QuestState.OFFERED,
                    dayKey = o.optString("day").ifBlank { LocalDate.now().toString() },
                    createdAtMs = o.optLong("createdAt", 0L),
                    // A record written before quests had deadlines gets one measured from when it was
                    // created, so an old quest does not read as already expired or as never expiring.
                    expiresAtMs = o.optLong("expiresAt", 0L).takeIf { it > 0L }
                        ?: (o.optLong("createdAt", System.currentTimeMillis()) + Quest.DEFAULT_WINDOW_MS),
                ),
            )
        }
        return out
    }
}
