package com.noop.analytics

import android.content.Context
import com.noop.ingest.MuscleGroup
import org.json.JSONObject

// MARK: - Keeping the body's yardstick still
//
// [LevelBaselineStore]'s rule, applied per muscle group: a group's mean and spread are written once and
// then returned verbatim forever. The colour on the figure therefore means the same thing in December
// as it did in March.
//
// A GROUP FREEZES WHEN IT CAN, NOT WHEN THE FIRST ONE DOES. Someone who has been importing chest work
// for a year and squatted for the first time yesterday has a scale for their chest and none for their
// quadriceps. [resolve] adds the groups that have become derivable and never touches the ones already
// stored — so a new group joining the scale can never move an old group's colour.

object MuscleBaselineStore {

    private const val KEY = "muscle.baselines"
    private const val KEY_FROZEN_AT = "muscle.baselinesFrozenAt"

    /**
     * The frozen per-group scales, freezing any group that has become derivable since the last call.
     *
     * [history] is one rolling-window series per group (see [MuscleBaselines.rollingWindows]). It is a
     * lambda because reading a wearer's whole lifting history is expensive and is only needed when some
     * group is still unfrozen — which, after the first month, is never.
     */
    fun resolve(
        context: Context,
        history: () -> Map<MuscleGroup, List<Double>>,
    ): Map<MuscleGroup, MuscleBaseline> {
        val stored = read(context)
        if (stored.size == MuscleGroup.entries.size) return stored
        val derived = MuscleBaselines.deriveAll(history())
        // Stored LAST so it wins: a group already frozen keeps the scale it was frozen with, whatever
        // the freshly derived numbers say. This is the whole contract in one line.
        val merged = derived + stored
        if (merged != stored) write(context, merged)
        return merged
    }

    /** What is stored today. Empty when nothing has ever been frozen. */
    fun read(context: Context): Map<MuscleGroup, MuscleBaseline> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyMap()
        return runCatching { decode(raw) }.getOrDefault(emptyMap())
    }

    /** When a group was last ADDED to the scale, epoch milliseconds, or null when none ever was. */
    fun frozenAtMs(context: Context): Long? =
        prefs(context).getLong(KEY_FROZEN_AT, 0L).takeIf { it > 0L }

    /**
     * Derive every group again from current history, replacing what was stored.
     *
     * The only way an existing group's scale moves. Every colour the wearer has seen was measured
     * against the old one, so a caller must treat this as a visible change and not as maintenance.
     */
    fun refreeze(
        context: Context,
        history: Map<MuscleGroup, List<Double>>,
    ): Map<MuscleGroup, MuscleBaseline> {
        val derived = MuscleBaselines.deriveAll(history)
        write(context, derived)
        return derived
    }

    private fun write(context: Context, baselines: Map<MuscleGroup, MuscleBaseline>) {
        prefs(context).edit()
            .putString(KEY, encode(baselines))
            .putLong(KEY_FROZEN_AT, System.currentTimeMillis())
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)

    internal fun encode(baselines: Map<MuscleGroup, MuscleBaseline>): String {
        val root = JSONObject()
        baselines.forEach { (group, b) ->
            root.put(group.name, JSONObject().put("mean", b.mean).put("sd", b.sd))
        }
        return root.toString()
    }

    /**
     * Read a stored set back.
     *
     * A group whose entry is missing or unreadable is ABSENT rather than defaulted: there is no sensible
     * table value for "kilograms of volume a shoulder normally does", and inventing one would be the
     * fabricated metric the design rules forbid.
     */
    internal fun decode(raw: String): Map<MuscleGroup, MuscleBaseline> {
        val root = JSONObject(raw)
        val out = LinkedHashMap<MuscleGroup, MuscleBaseline>()
        MuscleGroup.entries.forEach { group ->
            val o = root.optJSONObject(group.name) ?: return@forEach
            val mean = o.optDouble("mean", Double.NaN)
            val sd = o.optDouble("sd", Double.NaN)
            if (!mean.isFinite() || !sd.isFinite() || mean <= 0.0) return@forEach
            out[group] = MuscleBaseline(mean = mean, sd = sd)
        }
        return out
    }
}
