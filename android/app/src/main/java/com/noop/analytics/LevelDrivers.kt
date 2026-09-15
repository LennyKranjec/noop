package com.noop.analytics

// MARK: - Naming the lever
//
// The header says which PART has the most room — sleep, heart, lungs, muscle, focus. A glyph alone
// leaves the wearer to guess what to do about it: a heart icon could be asking for more sleep, less
// caffeine or an easier week, and the answer is none of those if the figure actually dragging it down
// is a resting heart rate.
//
// SO THE LEVER NAMES THE METRIC, not the part. "rhr" under the heart, "consistency" under the moon —
// and the moon is what makes "consistency" unambiguous, which is why the word can stay this short.
//
// PICKED BY THE SAME RULE THE PARTS ARE. Within a part, the driver is the sub-metric with the most room
// to 100 AFTER its own share of the part — not the lowest number. Sleep score at 0.8 of the sleep term
// and consistency at 0.2 means a score of 70 is worth more to fix than a consistency of 40, and
// pointing at the smaller number would send them after the smaller prize.
//
// A PART WITH ONE INPUT HAS NO DRIVER TO CHOOSE. Muscle is volume load and nothing else, so it names
// itself; there is no second figure it could have been.

/** The named metric behind a part's score, as the header's lever labels it. */
enum class LevelDriver(val part: LevelPart) {
    SLEEP_SCORE(LevelPart.SLEEP),
    SLEEP_CONSISTENCY(LevelPart.SLEEP),
    HRV(LevelPart.HEART),
    RHR(LevelPart.HEART),
    VO2MAX(LevelPart.LUNGS),
    RESP_RATE(LevelPart.LUNGS),
    MUSCLE_VOLUME(LevelPart.MUSCLE),
    STRESS(LevelPart.FOCUS),
    MEDITATION(LevelPart.FOCUS),
}

object LevelDrivers {

    /** Sleep's own split, from [LevelEngine.sleep]. */
    private const val SLEEP_SCORE_SHARE = 0.8
    private const val SLEEP_CONSISTENCY_SHARE = 0.2

    /** Lungs' own split, from [LevelEngine.lungs]. */
    private const val VO2_SHARE = 0.6
    private const val RESP_SHARE = 0.4

    /**
     * Which metric inside [part] has the most room, or null when nothing measured it.
     *
     * Computed from the same inputs and the same frozen baselines the score itself came from, so the
     * label can never name a metric the score was not actually built on.
     */
    fun driver(
        part: LevelPart,
        inputs: LevelInputs,
        baselines: Map<LevelMetric, Baseline>,
    ): LevelDriver? = when (part) {
        LevelPart.SLEEP -> {
            val score = inputs.sleepScores.takeLast(3).takeIf { it.isNotEmpty() }?.average()
            val consistency = inputs.consistencyScores.takeLast(3).takeIf { it.isNotEmpty() }?.average()
            pick(
                LevelDriver.SLEEP_SCORE to score?.let { (100.0 - it) * SLEEP_SCORE_SHARE },
                LevelDriver.SLEEP_CONSISTENCY to consistency?.let { (100.0 - it) * SLEEP_CONSISTENCY_SHARE },
            )
        }
        LevelPart.HEART -> {
            // The two enter the heart term as `z(hrv) − z(rhr)`, in equal and opposite measure, so their
            // room is compared on the same 0–100 scale each z maps to.
            val hrv = inputs.hrv?.let { LevelEngine.toScale(LevelEngine.z(it, baselines.getValue(LevelMetric.HRV))) }
            val rhr = inputs.rhr?.let {
                100.0 - LevelEngine.toScale(LevelEngine.z(it, baselines.getValue(LevelMetric.RHR)))
            }
            pick(
                LevelDriver.HRV to hrv?.let { 100.0 - it },
                LevelDriver.RHR to rhr?.let { 100.0 - it },
            )
        }
        LevelPart.LUNGS -> {
            val vo2 = inputs.vo2max?.let {
                LevelEngine.toScale(LevelEngine.z(it, baselines.getValue(LevelMetric.VO2MAX)))
            }
            val resp = inputs.respRate?.let {
                100.0 - LevelEngine.toScale(LevelEngine.z(it, baselines.getValue(LevelMetric.RESP_RATE)))
            }
            pick(
                LevelDriver.VO2MAX to vo2?.let { (100.0 - it) * VO2_SHARE },
                LevelDriver.RESP_RATE to resp?.let { (100.0 - it) * RESP_SHARE },
            )
        }
        // One input, so there is nothing to choose between. Null when it has no sessions at all, because
        // a lever is only ever shown for a part that scored.
        LevelPart.MUSCLE -> LevelDriver.MUSCLE_VOLUME.takeIf { inputs.muscleSessions.isNotEmpty() }
        LevelPart.FOCUS -> {
            val stress = inputs.stressScores.takeLast(3).takeIf { it.isNotEmpty() }?.average()
            // Meditation is a MULTIPLIER on the calm score (0.5 with none, 1.01 with three days), so its
            // room is what the remaining days would add — not a distance to 100 like the others.
            val days = inputs.meditationDays.coerceIn(0, 3)
            val calm = stress?.let { 100.0 - it }
            val bonusNow = 0.5 + LevelEngine.MEDITATION_BONUS_PER_DAY * days
            val bonusFull = 0.5 + LevelEngine.MEDITATION_BONUS_PER_DAY * 3
            pick(
                LevelDriver.STRESS to calm?.let { (100.0 - it) * bonusNow },
                LevelDriver.MEDITATION to calm?.let { it * (bonusFull - bonusNow) },
            )
        }
    }

    /** The driver with the most room. Ties go to the first named, which is the larger share. */
    private fun pick(vararg options: Pair<LevelDriver, Double?>): LevelDriver? =
        options.filter { it.second != null }.maxByOrNull { it.second!! }?.first
}
