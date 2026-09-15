package com.noop.ai

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.LocalDate
import java.util.UUID

// MARK: - Coach reminders
//
// A reminder is a TIME, a REPEAT RULE and a SENTENCE OF CONTEXT — "22:00, daily, bedtime, you said you
// wanted eight hours". The context is the whole point: when the time comes, the Fast model writes the
// notification from it, so the nudge is about the wearer's actual reason rather than a stock string.
// The same reminder therefore reads differently each night, which is the difference between a nag and
// a coach.
//
// WHERE THEY LIVE. SharedPreferences, as JSON — not Room. These are device-local settings like every
// other NOOP automation (wake window, brief time, export schedule): they describe what this phone
// should do, they are not measurements, and nothing analyses them. A Room table would have bought a
// schema migration and a Swift twin for data that never leaves the device or feeds a chart.
//
// WHO CREATES THEM. The coach, by emitting a directive in its reply (see [CoachDirectives]), and the
// wearer, from the Reminders screen. Both go through this store, so neither can produce a reminder the
// other cannot see or delete.

/** How often a reminder fires. The rule is evaluated per day, so no schedule is ever "every 36h". */
enum class ReminderRepeat {
    DAILY,
    WEEKDAYS,
    WEEKENDS,
    WEEKLY;

    companion object {
        /** Parse a coach-written or stored keyword. Unknown values fall back to [DAILY], never throw. */
        fun parse(raw: String?): ReminderRepeat = entries.firstOrNull {
            it.name.equals(raw?.trim(), ignoreCase = true)
        } ?: DAILY
    }
}

/**
 * One reminder.
 *
 * [minuteOfDay] is local wall-clock, matching every other scheduled thing in the app. [weekday] is
 * only read when [repeat] is [ReminderRepeat.WEEKLY]; it is stored always so switching a weekly
 * reminder to daily and back does not lose the day it was on.
 */
data class Reminder(
    val id: String = UUID.randomUUID().toString(),
    val context: String,
    val minuteOfDay: Int,
    val repeat: ReminderRepeat = ReminderRepeat.DAILY,
    /** 1 = Monday … 7 = Sunday, matching [DayOfWeek.getValue]. */
    val weekday: Int = LocalDate.now().dayOfWeek.value,
    val enabled: Boolean = true,
    val createdAtMs: Long = System.currentTimeMillis(),
) {
    /** `HH:mm`, zero-padded, locale-independent — this is a clock time, not a formatted date. */
    val timeLabel: String
        get() = "%02d:%02d".format(minuteOfDay / 60, minuteOfDay % 60)

    /** Whether this reminder is due on [date] under its repeat rule. */
    fun firesOn(date: LocalDate): Boolean {
        if (!enabled) return false
        val isWeekend = date.dayOfWeek == DayOfWeek.SATURDAY || date.dayOfWeek == DayOfWeek.SUNDAY
        return when (repeat) {
            ReminderRepeat.DAILY -> true
            ReminderRepeat.WEEKDAYS -> !isWeekend
            ReminderRepeat.WEEKENDS -> isWeekend
            ReminderRepeat.WEEKLY -> date.dayOfWeek.value == weekday
        }
    }
}

object ReminderStore {

    private const val KEY = "coach.reminders"

    /** How many can exist at once. A coach that misreads a request must not be able to fill the tray. */
    const val MAX_REMINDERS = 20

    fun all(context: Context): List<Reminder> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        return runCatching { decode(raw) }.getOrDefault(emptyList())
    }

    fun find(context: Context, id: String): Reminder? = all(context).firstOrNull { it.id == id }

    /**
     * Add [reminder], or replace the one with the same id. Returns the stored list.
     *
     * At [MAX_REMINDERS] the add is DROPPED rather than evicting an existing one: the wearer set those
     * up, and a coach quietly deleting one to make room for its own is the worse failure.
     */
    fun upsert(context: Context, reminder: Reminder): List<Reminder> {
        val current = all(context)
        val replacing = current.any { it.id == reminder.id }
        if (!replacing && current.size >= MAX_REMINDERS) return current
        val next = if (replacing) {
            current.map { if (it.id == reminder.id) reminder else it }
        } else {
            current + reminder
        }
        return write(context, next)
    }

    fun delete(context: Context, id: String): List<Reminder> =
        write(context, all(context).filterNot { it.id == id })

    /**
     * The reminder a loose reference means, for a coach that was asked to delete "the bedtime one".
     *
     * Matched on the id first, then on the context text containing the phrase (or the phrase
     * containing the context), then on an `HH:mm` time. Returns null when nothing matches OR when
     * more than one does — a delete that guesses between two reminders is worse than one that asks.
     */
    fun resolve(reminders: List<Reminder>, reference: String): Reminder? {
        val ref = reference.trim()
        if (ref.isEmpty()) return null
        reminders.firstOrNull { it.id == ref }?.let { return it }

        val lower = ref.lowercase()
        val byText = reminders.filter {
            val c = it.context.lowercase()
            c.contains(lower) || lower.contains(c)
        }
        if (byText.size == 1) return byText.single()

        val byTime = reminders.filter { it.timeLabel == ref }
        return byTime.singleOrNull()
    }

    private fun write(context: Context, list: List<Reminder>): List<Reminder> {
        prefs(context).edit().putString(KEY, encode(list)).apply()
        return list
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)

    internal fun encode(list: List<Reminder>): String {
        val arr = JSONArray()
        list.forEach { r ->
            arr.put(
                JSONObject()
                    .put("id", r.id)
                    .put("context", r.context)
                    .put("minute", r.minuteOfDay)
                    .put("repeat", r.repeat.name)
                    .put("weekday", r.weekday)
                    .put("enabled", r.enabled)
                    .put("createdAt", r.createdAtMs),
            )
        }
        return arr.toString()
    }

    internal fun decode(raw: String): List<Reminder> {
        val arr = JSONArray(raw)
        val out = ArrayList<Reminder>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val ctx = o.optString("context").takeIf { it.isNotBlank() } ?: continue
            out.add(
                Reminder(
                    id = o.optString("id").takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString(),
                    context = ctx,
                    // Clamped, not trusted: this JSON is also written from a directive a language
                    // model produced, and a minute of 9999 would schedule a job that never fires.
                    minuteOfDay = o.optInt("minute", 0).coerceIn(0, 24 * 60 - 1),
                    repeat = ReminderRepeat.parse(o.optString("repeat")),
                    weekday = o.optInt("weekday", 1).coerceIn(1, 7),
                    enabled = o.optBoolean("enabled", true),
                    createdAtMs = o.optLong("createdAt", 0L),
                ),
            )
        }
        return out
    }
}
