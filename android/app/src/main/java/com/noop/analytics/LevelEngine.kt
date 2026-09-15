package com.noop.analytics

import kotlin.math.exp
import kotlin.math.sqrt

// MARK: - The level
//
// One number, 0–100, for how the wearer is doing. It replaces the XP system entirely: XP was a
// placeholder that measured nothing, and a level derived from the body's own metrics is the thing that
// was always meant to be there.
//
// EVERY INPUT IS MEASURED. Nothing here is awarded for using the app, and nothing is invented when a
// metric is missing — a component with no data is EXCLUDED and its weight redistributed over the ones
// that do, so a wearer with no VO2max reading is scored on what was actually recorded rather than
// against a guess. [LevelBreakdown.coverage] says how much of the weight was real.
//
// NORMALISED AGAINST THE WEARER, AND THEN FROZEN. Each raw metric becomes a z-score against that
// wearer's own mean and spread — an HRV of 65 ms is excellent for one person and unremarkable for
// another, and a fixed table would be scoring them against a stranger. But the scale is derived ONCE
// and never moves: a rolling baseline makes you run to stand still, because improving raises your own
// mean and hands the gain straight back. See [LevelBaselines] for the full argument and its cost.
//
// WHAT THE SPEC SAID AND WHAT THIS DOES. The specification carried a worked example that its own code
// does not reproduce — five of nine figures disagree, `focus` in the example omits the meditation
// bonus the formula applies, and the prose's `100 − 30 × stress` goes negative for any stress above
// 3.4 on a 0–100 scale. The executable half is implemented here; the example is not a test oracle,
// because it is not what the formula produces.
//
// STEPS ARE A PENALTY, NOT A COMPONENT. As specified: at or above [STEPS_FLOOR] they add nothing, and
// below it they scale the whole score down. An earlier draft also scored them, which put a 72-point
// cliff between 5,999 and 6,000 steps; there is no score curve here, so there is no cliff.

/**
 * Everything the level is computed from, already extracted from the stores.
 *
 * Three-day figures are lists so the engine can average them itself and report how many days it
 * actually had — a "3-day mean" over one day is not the same claim, and the UI says so.
 */
data class LevelInputs(
    /** Sleep score 0–100, newest last, up to 3 entries. */
    val sleepScores: List<Double> = emptyList(),
    /** Sleep consistency 0–100, newest last, up to 3 entries. */
    val consistencyScores: List<Double> = emptyList(),
    val hrv: Double? = null,
    val rhr: Double? = null,
    val vo2max: Double? = null,
    val respRate: Double? = null,
    /** Recent training sessions as (raw volume load, days ago). Only the last 3 are read. */
    val muscleSessions: List<Pair<Double, Int>> = emptyList(),
    /** Stress 0–100, newest last, up to 3 entries. */
    val stressScores: List<Double> = emptyList(),
    /** Days with a logged meditation in the last three, 0–3. */
    val meditationDays: Int = 0,
    /** Today's step count. Null when steps are not being recorded at all — see [LevelEngine]. */
    val stepsToday: Int? = null,
)

/** One weighted part of the level, and how much room it has left. */
data class LevelComponent(
    val part: LevelPart,
    /** 0–100, or null when there was no data for it. */
    val score: Double?,
    /** The weight it carried in THIS calculation, after redistribution. Zero when it had no data. */
    val effectiveWeight: Double,
) {
    /** Points of final level that would be gained by taking this component to 100. */
    val headroom: Double get() = score?.let { (100.0 - it) * effectiveWeight } ?: 0.0

    /** Points of final level this component currently contributes. */
    val contribution: Double get() = (score ?: 0.0) * effectiveWeight
}

/** The five weighted parts. Steps is deliberately absent: it penalises, it does not score. */
enum class LevelPart(val weight: Double) {
    SLEEP(0.30),
    HEART(0.23),
    LUNGS(0.07),
    MUSCLE(0.24),
    FOCUS(0.16),
}

/** A computed level, with everything needed to explain it. */
data class LevelBreakdown(
    val components: List<LevelComponent>,
    /** Before the step penalty. */
    val raw: Double,
    /** The multiplier steps applied, 1.0 when they were at or above the floor or not recorded. */
    val stepPenalty: Double,
    /** The level itself, 0–100. */
    val level: Double,
    /** How much of the total weight had data behind it, 0–1. */
    val coverage: Double,
) {
    /**
     * The components most worth improving, best first.
     *
     * Ranked by HEADROOM — weight times the distance to 100 — not by how low the score is. A lungs
     * score of 20 is a worse number than a sleep score of 60, but at a weight of 0.07 against 0.30
     * fixing sleep is worth more than twice as much level. Ranking by the low score would keep
     * pointing at the metric that matters least.
     */
    fun levers(): List<LevelComponent> =
        components.filter { it.score != null && it.effectiveWeight > 0 }
            .sortedByDescending { it.headroom }
}

object LevelEngine {

    /** Steps at or above this add nothing; below it they scale the whole score down. */
    const val STEPS_FLOOR = 6000

    /** The most the step penalty can take away, at zero steps. */
    const val STEPS_MAX_PENALTY = 0.15

    /** z is clipped to this many SDs before scaling, so one freak reading cannot dominate. */
    const val Z_CLIP = 3.0

    /** How fast an older training session stops counting, per day. */
    const val MUSCLE_DECAY = 0.3

    /** Meditation's share of the focus score: 0.5 with none, 1.01 with three days. */
    const val MEDITATION_BONUS_PER_DAY = 0.17

    fun z(value: Double, baseline: Baseline): Double =
        ((value - baseline.mean) / baseline.safeSd).coerceIn(-Z_CLIP, Z_CLIP)

    fun toScale(z: Double): Double = (50.0 + 25.0 * z).coerceIn(0.0, 100.0)

    /**
     * Sleep: mostly the score itself, with consistency as a modifier.
     *
     * Both are already 0–100 and are used RAW, not z-scored — the spec normalises the metrics that
     * have no natural scale, and a sleep score already is one.
     */
    fun sleep(scores: List<Double>, consistency: List<Double>): Double? {
        val s = scores.takeLast(3).takeIf { it.isNotEmpty() } ?: return null
        val c = consistency.takeLast(3)
        val sMean = s.average()
        // Consistency missing is not consistency zero: with no reading, sleep is scored on its score
        // alone rather than being marked down for a measurement that was never taken.
        if (c.isEmpty()) return sMean
        return 0.8 * sMean + 0.2 * c.average()
    }

    /** Heart: HRV above baseline and RHR below it, as one figure. */
    fun heart(hrv: Double?, rhr: Double?, baselines: Map<LevelMetric, Baseline>): Double? {
        if (hrv == null || rhr == null) return null
        val zHrv = z(hrv, baselines.getValue(LevelMetric.HRV))
        val zRhr = z(rhr, baselines.getValue(LevelMetric.RHR))
        return toScale(zHrv - zRhr)
    }

    /** Lungs: VO2max, plus a slow respiratory rate. */
    fun lungs(vo2max: Double?, respRate: Double?, baselines: Map<LevelMetric, Baseline>): Double? {
        if (vo2max == null && respRate == null) return null
        val sVo2 = vo2max?.let { toScale(z(it, baselines.getValue(LevelMetric.VO2MAX))) }
        // Inverted: a HIGH respiratory rate is the bad direction, so its scale is flipped.
        val sRr = respRate?.let { 100.0 - toScale(z(it, baselines.getValue(LevelMetric.RESP_RATE))) }
        return when {
            sVo2 != null && sRr != null -> 0.6 * sVo2 + 0.4 * sRr
            sVo2 != null -> sVo2
            else -> sRr
        }
    }

    /**
     * Muscle: the last three sessions, weighted so today's counts most.
     *
     * Exponential decay rather than a flat mean, because a hard session four days ago is not the same
     * evidence of current training load as one this morning.
     *
     * STANDARDISED BY RANGE, NOT BY DEVIATION. The other metrics are z-scored against a mean, which
     * asks "how unusual is this for you". Volume load has no meaningful centre to deviate from — a zero
     * is a rest day, not an abnormal reading, and half the distribution sits at or near it. The frozen
     * [Baseline.min] and [Baseline.max] answer the question that does apply: where does this session
     * sit between the lightest and heaviest the wearer actually does. Sessions arrive in their raw unit
     * (kilograms of volume load) and are placed on that range here, so callers never have to know the
     * scale.
     */
    fun muscle(sessions: List<Pair<Double, Int>>, baseline: Baseline): Double? {
        val recent = sessions.takeLast(3).takeIf { it.isNotEmpty() } ?: return null
        var num = 0.0
        var den = 0.0
        recent.forEach { (load, daysAgo) ->
            val w = exp(-MUSCLE_DECAY * daysAgo.toDouble())
            num += baseline.position(load) * w
            den += w
        }
        return if (den > 0) num / den else null
    }

    /**
     * Focus: low stress, lifted by having meditated.
     *
     * The prose form of this was `100 − 30 × stress`, which is negative for any stress above 3.4 on a
     * 0–100 scale; the executable form is used instead. The bonus runs 0.5 to 1.01, so three days of
     * meditation roughly doubles the score a calm day earns.
     */
    fun focus(stressScores: List<Double>, meditationDays: Int): Double? {
        val s = stressScores.takeLast(3).takeIf { it.isNotEmpty() } ?: return null
        val bonus = 0.5 + MEDITATION_BONUS_PER_DAY * meditationDays.coerceIn(0, 3)
        return ((100.0 - s.average()) * bonus).coerceIn(0.0, 100.0)
    }

    /**
     * What steps do to the score.
     *
     * A multiplier, never a component. Null steps means steps are not being recorded, which must not
     * be punished as a still day — the wearer cannot fix a sensor they do not have.
     */
    fun stepPenalty(steps: Int?): Double {
        if (steps == null || steps >= STEPS_FLOOR) return 1.0
        val shortfall = (STEPS_FLOOR - steps).toDouble() / STEPS_FLOOR
        return (1.0 - STEPS_MAX_PENALTY * shortfall).coerceAtLeast(1.0 - STEPS_MAX_PENALTY)
    }

    /**
     * The level.
     *
     * Weights are redistributed over the components that have data, so a missing VO2max does not drag
     * the level down as if lungs scored zero. With NOTHING measured the level is null rather than 0: a
     * zero would read as "you are in terrible shape" when it means "nothing was recorded".
     */
    fun compute(
        inputs: LevelInputs,
        baselines: Map<LevelMetric, Baseline> = LevelBaselines.DEFAULT,
    ): LevelBreakdown? {
        val scores = mapOf(
            LevelPart.SLEEP to sleep(inputs.sleepScores, inputs.consistencyScores),
            LevelPart.HEART to heart(inputs.hrv, inputs.rhr, baselines),
            LevelPart.LUNGS to lungs(inputs.vo2max, inputs.respRate, baselines),
            LevelPart.MUSCLE to muscle(inputs.muscleSessions, baselines.getValue(LevelMetric.MUSCLE_LOAD)),
            LevelPart.FOCUS to focus(inputs.stressScores, inputs.meditationDays),
        )
        val presentWeight = scores.entries.sumOf { (part, score) -> if (score != null) part.weight else 0.0 }
        if (presentWeight <= 0.0) return null

        val components = LevelPart.entries.map { part ->
            val score = scores[part]
            LevelComponent(
                part = part,
                score = score,
                effectiveWeight = if (score != null) part.weight / presentWeight else 0.0,
            )
        }
        val raw = components.sumOf { it.contribution }
        val penalty = stepPenalty(inputs.stepsToday)
        return LevelBreakdown(
            components = components,
            raw = raw,
            stepPenalty = penalty,
            level = (raw * penalty).coerceIn(0.0, 100.0),
            coverage = presentWeight,
        )
    }
}
