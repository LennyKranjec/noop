package com.noop.analytics

import android.content.Context
import org.json.JSONObject

// MARK: - Keeping the yardstick still
//
// The baselines are derived once and then persisted verbatim. Every later read returns exactly what
// was written, so the level means the same thing in December as it did in March.
//
// WRITTEN ONCE, DELIBERATELY. [resolve] derives only when nothing is stored; it never re-derives, even
// when far more history is now available. A caller that wants a fresh scale has to say so through
// [refreeze], which is a visible, explicit act — the wearer should know their yardstick moved, because
// every level they remember was measured against the old one.
//
// STORED AS NUMBERS, NOT AS A SNAPSHOT DATE. What matters is the scale itself; when it was taken is
// recorded alongside only so the app can tell the wearer how thin the history behind it was.

object LevelBaselineStore {

    private const val KEY = "level.baselines"
    private const val KEY_FROZEN_AT = "level.baselinesFrozenAt"

    /**
     * The frozen baselines, deriving and storing them on the first call.
     *
     * [history] is only consulted when there is nothing stored, so the (potentially expensive) read of
     * a whole metric history can be a lambda the caller never pays for on a warm start.
     */
    fun resolve(
        context: Context,
        history: () -> Map<LevelMetric, List<Double>>,
    ): Map<LevelMetric, Baseline> {
        read(context)?.let { return it }
        val derived = LevelBaselines.deriveAll(history())
        write(context, derived)
        return derived
    }

    /** The stored set, or null when the scale has never been frozen. */
    fun read(context: Context): Map<LevelMetric, Baseline>? {
        val raw = prefs(context).getString(KEY, null) ?: return null
        return runCatching { decode(raw) }.getOrNull()?.takeIf { it.size == LevelMetric.entries.size }
    }

    /** When the scale was frozen, as epoch milliseconds, or null when it never was. */
    fun frozenAtMs(context: Context): Long? =
        prefs(context).getLong(KEY_FROZEN_AT, 0L).takeIf { it > 0L }

    /**
     * Derive the scale again from current history, replacing what was stored.
     *
     * The ONLY way the yardstick moves. Every level the wearer has seen was measured against the old
     * scale, so a caller must treat this as a visible change and not as maintenance.
     */
    fun refreeze(
        context: Context,
        history: Map<LevelMetric, List<Double>>,
    ): Map<LevelMetric, Baseline> {
        val derived = LevelBaselines.deriveAll(history)
        write(context, derived)
        return derived
    }

    private fun write(context: Context, baselines: Map<LevelMetric, Baseline>) {
        prefs(context).edit()
            .putString(KEY, encode(baselines))
            .putLong(KEY_FROZEN_AT, System.currentTimeMillis())
            .apply()
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", Context.MODE_PRIVATE)

    internal fun encode(baselines: Map<LevelMetric, Baseline>): String {
        val root = JSONObject()
        baselines.forEach { (metric, b) ->
            root.put(
                metric.name,
                JSONObject()
                    .put("mean", b.mean)
                    .put("sd", b.sd)
                    .put("min", b.min)
                    .put("max", b.max),
            )
        }
        return root.toString()
    }

    /**
     * Read a stored set back.
     *
     * A metric missing from the JSON falls back to the table rather than being dropped — a set with a
     * hole in it would silently stop scoring that component, and the wearer would see their level move
     * for no reason they could observe.
     */
    internal fun decode(raw: String): Map<LevelMetric, Baseline> {
        val root = JSONObject(raw)
        return LevelMetric.entries.associateWith { metric ->
            val o = root.optJSONObject(metric.name) ?: return@associateWith LevelBaselines.DEFAULT.getValue(metric)
            val mean = o.optDouble("mean", Double.NaN)
            val sd = o.optDouble("sd", Double.NaN)
            if (!mean.isFinite() || !sd.isFinite()) return@associateWith LevelBaselines.DEFAULT.getValue(metric)
            Baseline(
                mean = mean,
                sd = sd,
                min = o.optDouble("min", mean - 2 * sd),
                max = o.optDouble("max", mean + 2 * sd),
            )
        }
    }
}
