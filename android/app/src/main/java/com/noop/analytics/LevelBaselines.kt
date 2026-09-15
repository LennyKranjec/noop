package com.noop.analytics

import kotlin.math.sqrt

// MARK: - The baselines, and why they are frozen
//
// Each metric's centre, spread and range, derived ONCE from whatever history the wearer had when the
// level first ran, and then never touched again.
//
// THIS IS THE WHOLE POINT. A rolling baseline makes you run to stand still: improve, and your own mean
// rises with you, your z-score falls back toward zero, and the level hands the gain straight back. Two
// people with identical bodies would also sit at different levels because they had different months
// behind them, and the same wearer's level 70 would mean one thing in March and another in December.
// Frozen, a level is a fixed yardstick — the number moves only when the body does.
//
// THE COST, STATED PLAINLY. A frozen scale drifts out of date. Someone who trains for two years will
// press against the top of a range set when they were unfit, and the level stops discriminating at the
// high end. That is the trade the wearer asked for, and it is the right one for a score meant to be
// compared with itself over time — but it is a real cost, not a free lunch, and [needsRefresh] exists
// so a deliberate, explicit re-derivation is possible without the scale silently sliding.
//
// OUTLIERS MATTER MORE HERE, NOT LESS. Because the range is permanent, one corrupt reading at freeze
// time would define the scale forever. The range therefore comes from percentiles rather than the
// literal smallest and largest samples — see [RANGE_LOW_PCT].

/**
 * One metric's frozen reference: where its middle is, how far it usually swings, and the ends of its
 * useful range.
 *
 * [mean] and [sd] drive the z-score path used by HRV, RHR, VO2max and respiratory rate. [min] and
 * [max] drive the range path used by muscle load, whose raw unit (kilograms of volume load) has no
 * meaningful centre to deviate from — a wearer's zero is a rest day, not a bad reading.
 */
data class Baseline(
    val mean: Double,
    val sd: Double,
    val min: Double,
    val max: Double,
) {
    /** Guards a degenerate spread: a wearer whose readings never move would otherwise divide by zero. */
    val safeSd: Double get() = if (sd > 1e-6) sd else 1.0

    /** Guards a degenerate range, for the same reason. */
    val safeSpan: Double get() = (max - min).let { if (it > 1e-6) it else 1.0 }

    /** Where [value] sits in the frozen range, 0–100. Clipped: the range is fixed, readings are not. */
    fun position(value: Double): Double =
        (((value - min) / safeSpan) * 100.0).coerceIn(0.0, 100.0)
}

/** Which metrics the level reads. Named so a missing one can be reported by name. */
enum class LevelMetric {
    SLEEP_SCORE,
    SLEEP_CONSISTENCY,
    HRV,
    RHR,
    VO2MAX,
    RESP_RATE,
    MUSCLE_LOAD,
    STRESS,
}

object LevelBaselines {

    /**
     * How many readings a metric needs before its own history is used instead of the table.
     *
     * Two weeks. Below that a mean is dominated by whichever fortnight happened to be sampled, and a
     * spread estimated from a handful of nights makes every reading look extreme — and since the
     * result is FROZEN, a bad estimate here is permanent.
     */
    const val MIN_SAMPLES = 14

    /**
     * The percentiles that define a metric's range.
     *
     * Not the literal min and max: the range is frozen forever, so one corrupt reading on the day it is
     * derived would set the scale for good. The 5th and 95th percentiles cut the tails while still
     * spanning what the wearer actually does.
     */
    const val RANGE_LOW_PCT = 5.0
    const val RANGE_HIGH_PCT = 95.0

    /**
     * The fallback table, from the specification. Used ONLY for a metric with too little history at
     * freeze time; its range is taken as ±2 SD, which is where the z-score path saturates anyway.
     */
    val DEFAULT: Map<LevelMetric, Baseline> = mapOf(
        LevelMetric.SLEEP_SCORE to table(75.0, 12.0),
        LevelMetric.SLEEP_CONSISTENCY to table(70.0, 15.0),
        LevelMetric.HRV to table(50.0, 15.0),
        LevelMetric.RHR to table(60.0, 10.0),
        LevelMetric.VO2MAX to table(45.0, 8.0),
        LevelMetric.RESP_RATE to table(16.0, 3.0),
        LevelMetric.MUSCLE_LOAD to table(50.0, 20.0),
        LevelMetric.STRESS to table(40.0, 15.0),
    )

    private fun table(mean: Double, sd: Double) =
        Baseline(mean = mean, sd = sd, min = mean - 2 * sd, max = mean + 2 * sd)

    /**
     * Derive one metric's baseline from the readings available at freeze time.
     *
     * The SD is the population form (divide by n), matching the spec's numpy default — the sample form
     * would put the two platforms a fraction apart on every score, which is exactly the drift the
     * parity contract exists to catch.
     */
    fun derive(metric: LevelMetric, history: List<Double>): Baseline {
        val xs = history.filter { it.isFinite() }.sorted()
        if (xs.size < MIN_SAMPLES) return DEFAULT.getValue(metric)
        val mean = xs.sum() / xs.size
        val variance = xs.sumOf { (it - mean) * (it - mean) } / xs.size
        return Baseline(
            mean = mean,
            sd = sqrt(variance),
            min = percentile(xs, RANGE_LOW_PCT),
            max = percentile(xs, RANGE_HIGH_PCT),
        )
    }

    /**
     * Derive every metric at once. What a caller does exactly once, and then stores.
     *
     * A metric absent from [history] keeps the table entry rather than being dropped: the set of
     * baselines has to be complete, or a component would silently stop scoring the day a sensor came
     * online.
     */
    fun deriveAll(history: Map<LevelMetric, List<Double>>): Map<LevelMetric, Baseline> =
        LevelMetric.entries.associateWith { derive(it, history[it].orEmpty()) }

    /**
     * Linear-interpolated percentile over an ALREADY SORTED list.
     *
     * Interpolated rather than nearest-rank so the two platforms cannot land on different samples at
     * the same percentile — with the result frozen, a one-sample disagreement would be permanent.
     */
    internal fun percentile(sorted: List<Double>, pct: Double): Double {
        if (sorted.isEmpty()) return 0.0
        if (sorted.size == 1) return sorted[0]
        val rank = (pct / 100.0) * (sorted.size - 1)
        val lo = rank.toInt()
        val hi = (lo + 1).coerceAtMost(sorted.size - 1)
        val frac = rank - lo
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    /**
     * Whether a frozen set is thin enough to be worth re-deriving.
     *
     * NOT automatic. A caller may offer the wearer a re-derivation — "your scale was set from two weeks
     * of data, reset it against the year you now have" — but nothing here does it on its own, because
     * a scale that moves by itself is the thing this whole file exists to prevent.
     */
    fun needsRefresh(frozen: Map<LevelMetric, Baseline>): Boolean =
        LevelMetric.entries.count { frozen[it] == DEFAULT[it] } >= LevelMetric.entries.size / 2
}
