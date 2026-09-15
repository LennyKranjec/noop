package com.noop.analytics

import com.noop.ingest.MuscleGroup
import kotlin.math.sqrt

// MARK: - What a colour on the body means
//
// The figure used to be shaded by each group's share of the HEAVIEST group that week. That is a
// ranking, and a ranking re-scales itself every time you look at it: train nothing but chest and the
// chest is scarlet; train everything hard and the chest is the same scarlet. The colour could not tell
// you whether a week was heavy — only which muscle got the most of it.
//
// IT IS NOW A Z-SCORE AGAINST THE GROUP'S OWN FROZEN NORMAL. Every group carries a mean and a spread,
// derived once from the wearer's own training history and then never moved — the same discipline, and
// the same reason, as [LevelBaselines]. Green is "a normal week for this muscle"; the top of the scale
// is two standard deviations above it. So a light week now LOOKS light, and next March's scarlet means
// exactly what this March's did.
//
// THE MAPPING IS A CONSTANT. [Z_FLOOR] and [Z_CEILING] never change and are not per-wearer: they are
// what makes one colour comparable to another colour, on another muscle, in another month. Without a
// fixed pair of ends the z-score would just be a ranking again, wearing statistics.
//
// EACH GROUP FREEZES ON ITS OWN, the first time it has enough history. Freezing a group that has never
// been trained would hand it a mean of zero and no spread, and the first set it ever saw would light it
// to the top of the scale. A group with no baseline yet is simply not z-scored (see [MuscleBaselines
// .derive] returning null) and the card keeps the old relative shading until the scale exists.

/**
 * One muscle group's frozen normal, in kilograms of trailing-7-day volume load.
 *
 * The unit is the SAME figure the card puts on screen beside the group — a rolling weekly sum — so the
 * colour and the number are two views of one quantity rather than two different measurements.
 */
data class MuscleBaseline(val mean: Double, val sd: Double) {

    /**
     * Guards a degenerate spread.
     *
     * Half the mean rather than a literal 1.0: the scale here is kilograms, and a 1 kg standard
     * deviation on a 4,000 kg week would make every reading read as ±4000 SD. A wearer whose weekly
     * volume genuinely never moves is being told "half a typical week is one SD", which is a coarse
     * claim but a true-to-scale one.
     */
    val safeSd: Double get() = when {
        sd > 1e-6 -> sd
        mean > 1e-6 -> mean * 0.5
        else -> 1.0
    }

    /** How unusual [kg] is for this group. 0 = a normal week, +2 = twice its usual swing above. */
    fun z(kg: Double): Double = (kg - mean) / safeSd
}

object MuscleBaselines {

    /**
     * The ends of the colour scale, in standard deviations. CONSTANT, by design.
     *
     * Two SD either side covers ~95 % of a normal spread, so the scale spends its resolution on weeks
     * that actually happen instead of on the tails. A week beyond either end is clipped rather than
     * given a colour of its own: there is no shade past "as heavy as this muscle gets".
     */
    const val Z_FLOOR = -2.0
    const val Z_CEILING = 2.0

    /**
     * How many rolling windows a group needs before its scale is frozen.
     *
     * Four weeks of days. Fewer, and the spread is estimated from one training block — and since the
     * result is permanent, a thin estimate here is a permanently wrong yardstick.
     */
    const val MIN_WINDOWS = 28

    /**
     * Where [kg] lands on the 0–1 colour scale for this group.
     *
     * The only mapping from a z-score to a shade, so both the body and the legend dot read the same
     * scale — they used to compute their own and could disagree at the edges.
     */
    fun fraction(baseline: MuscleBaseline, kg: Double): Double =
        ((baseline.z(kg) - Z_FLOOR) / (Z_CEILING - Z_FLOOR)).coerceIn(0.0, 1.0)

    /**
     * Freeze one group's scale from its rolling-window history, or return null when there is not
     * enough of it.
     *
     * [windows] is one trailing-7-day sum PER DAY, including the days that sum to zero: the card shows
     * a trailing week on whatever day you open it, so the distribution the colour is judged against has
     * to be the distribution of that same figure — rest days and all. Dropping the zeros would ask
     * "how heavy is this week compared with the weeks you trained", and answer a question nobody asked.
     *
     * Population SD (divide by n), matching [LevelBaselines.derive] and the Swift lane.
     */
    fun derive(windows: List<Double>): MuscleBaseline? {
        val xs = windows.filter { it.isFinite() }
        if (xs.size < MIN_WINDOWS) return null
        val mean = xs.sum() / xs.size
        // A group that has never been trained has nothing to be a deviation FROM. Freezing it would set
        // mean 0 with no spread, and the first set the wearer ever did for it would paint it at the top
        // of the scale forever after.
        if (mean <= 0.0) return null
        val variance = xs.sumOf { (it - mean) * (it - mean) } / xs.size
        return MuscleBaseline(mean = mean, sd = sqrt(variance))
    }

    /** Freeze whichever groups have the history for it. Groups that do not are simply absent. */
    fun deriveAll(history: Map<MuscleGroup, List<Double>>): Map<MuscleGroup, MuscleBaseline> =
        history.mapNotNull { (group, windows) -> derive(windows)?.let { group to it } }.toMap()

    /**
     * Turn a day-keyed series of daily volume into one trailing-[days]-day sum per day.
     *
     * Runs over the CALENDAR days between the first and last entry, not over the entries: a day the
     * wearer did not lift has no row at all, and skipping it would compress a fortnight of rest into no
     * time passing and leave the spread looking far tighter than it is.
     */
    fun rollingWindows(daily: Map<String, Double>, days: Int = 7): List<Double> {
        if (daily.isEmpty()) return emptyList()
        val sorted = daily.keys.sorted()
        val first = java.time.LocalDate.parse(sorted.first())
        val last = java.time.LocalDate.parse(sorted.last())
        val out = ArrayList<Double>()
        var day = first
        while (!day.isAfter(last)) {
            var sum = 0.0
            for (back in 0 until days) {
                sum += daily[day.minusDays(back.toLong()).toString()] ?: 0.0
            }
            out.add(sum)
            day = day.plusDays(1)
        }
        return out
    }
}
