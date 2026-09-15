package com.noop.analytics

import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository
import java.time.LocalDate

// MARK: - The meditation log
//
// One row per local day holding the MINUTES meditated on it, on the same generic metric-series seam
// hydration uses — same table, same (deviceId, day, key) uniqueness, no schema change.
//
// MINUTES, NOT A TICK. The level only asks whether a day had a meditation, but the wearer asked to see
// the total they have ever sat for, and a boolean cannot be summed into one. Storing the duration gives
// both: the sum is the headline, and "was there one" is "is the figure above zero".
//
// A DAY ACCUMULATES. Two sessions on one day add up rather than the second replacing the first — the
// stopwatch logs what was actually sat, and someone who sits twice has meditated twice.
//
// THE THREE-DAY WINDOW IS A WINDOW, NOT A STREAK. [daysInWindow] counts the days in the last three that
// have any minutes at all, which is exactly the figure the level's focus term multiplies by. It slides:
// a day drops out when it falls past the third, which is what makes the three circles on screen fill and
// empty rather than fill and stay.

object MeditationStore {

    /** Bumped on every write, so a screen showing the total can re-read without polling. */
    val mutationSeq = kotlinx.coroutines.flow.MutableStateFlow(0)

    /** The generic metric-series key the day's minutes are banked under. */
    const val KEY: String = "meditation_min"

    /** Its own local-only source, so it is never confused with an imported or computed metric. */
    const val SOURCE_ID: String = "meditation"

    /** How many days the level's focus term looks back over. Three, matching every other window. */
    const val WINDOW_DAYS = 3

    /** A session shorter than this is not logged: a mis-tap should not light the day's circle. */
    const val MIN_SESSION_SECONDS = 30

    /** Today's local calendar day, as the rows are keyed. */
    fun today(): String = LocalDate.now().toString()

    /** What a [log] actually did, so the screen can say it rather than appear to do nothing. */
    enum class Outcome {
        /** Stored. The day's circle lights and the total moves. */
        LOGGED,

        /** Under [MIN_SESSION_SECONDS]. Deliberately not stored — and deliberately REPORTED. */
        TOO_SHORT,

        /** The write itself failed. Rare, and the one case the wearer can do nothing about. */
        FAILED,
    }

    /** The outcome, and the day's total after it. */
    data class LogResult(val outcome: Outcome, val dayMinutes: Double)

    /**
     * Add [seconds] of meditation to [day].
     *
     * A session under [MIN_SESSION_SECONDS] is dropped: starting and immediately stopping the timer is a
     * mis-tap, and letting it light the day's circle would put a meditation into the level that nobody
     * sat. It is dropped OUT LOUD, though — the first cut of this returned the unchanged total and said
     * nothing, so a short session looked exactly like a broken button, which is how it was reported.
     */
    suspend fun log(
        repo: WhoopRepository,
        seconds: Int,
        day: String = today(),
    ): LogResult {
        if (!isLoggable(seconds)) return LogResult(Outcome.TOO_SHORT, minutes(repo, day))
        val next = minutes(repo, day) + seconds / 60.0
        val ok = write(repo, day, next)
        return LogResult(if (ok) Outcome.LOGGED else Outcome.FAILED, minutes(repo, day))
    }

    /**
     * Throw away [day]'s meditation entirely.
     *
     * The wearer asked for this so a session can be sat again properly — they left the timer running, or
     * stopped it early. It clears the DAY rather than the last session, because the store holds a day's
     * total and subtracting a session it does not remember would be arithmetic on a guess.
     */
    suspend fun clear(repo: WhoopRepository, day: String = today()) {
        write(repo, day, 0.0)
    }

    /**
     * Whether a session of [seconds] is long enough to store.
     *
     * Pure, and separate from [log], so the threshold can be tested without a database behind it — this
     * is the decision that made the button look broken, and it is worth a test of its own.
     */
    fun isLoggable(seconds: Int): Boolean = seconds >= MIN_SESSION_SECONDS

    /** How many days in a window carried a meditation. Pure half of [daysInWindow]. */
    fun countDays(window: List<Double>): Int = window.count { it > 0.0 }

    /** Minutes meditated on [day]. Zero when nothing was logged — here that genuinely means none. */
    suspend fun minutes(repo: WhoopRepository, day: String = today()): Double =
        runCatching { repo.metricSeries(SOURCE_ID, KEY, day, day).lastOrNull()?.value }
            .getOrNull() ?: 0.0

    /** Every minute ever logged. The headline figure on the Focus screen. */
    suspend fun lifetimeMinutes(repo: WhoopRepository): Double =
        runCatching {
            repo.metricSeries(SOURCE_ID, KEY, "0000-01-01", "9999-12-31").sumOf { it.value }
        }.getOrDefault(0.0)

    /** Minutes per day for the [WINDOW_DAYS] ending today, oldest first. Always that many entries. */
    suspend fun window(repo: WhoopRepository, asOf: LocalDate = LocalDate.now()): List<Double> {
        val from = asOf.minusDays((WINDOW_DAYS - 1).toLong())
        val byDay = runCatching {
            repo.metricSeries(SOURCE_ID, KEY, from.toString(), asOf.toString())
                .associate { it.day to it.value }
        }.getOrDefault(emptyMap())
        return (WINDOW_DAYS - 1 downTo 0).map { back ->
            byDay[asOf.minusDays(back.toLong()).toString()] ?: 0.0
        }
    }

    /**
     * How many of the last [WINDOW_DAYS] days had a meditation, 0–3.
     *
     * The figure the level's focus term multiplies by — see [LevelEngine.focus]. It SLIDES: a day drops
     * out of the count when it falls past the third, which is the "they free up again after three days"
     * the wearer described, and is why the circles on screen empty as well as fill.
     */
    suspend fun daysInWindow(repo: WhoopRepository, asOf: LocalDate = LocalDate.now()): Int =
        countDays(window(repo, asOf))

    /**
     * Store [day]'s total. True when it landed.
     *
     * The result is RETURNED rather than swallowed. A `runCatching` whose failure goes nowhere turns a
     * broken write into a button that does nothing, and the wearer has no way to tell that apart from a
     * button that is not wired up — which is precisely the report this came back as.
     */
    private suspend fun write(repo: WhoopRepository, day: String, minutes: Double): Boolean =
        runCatching {
            repo.upsertDevice(SOURCE_ID, name = "Meditation")
            repo.upsertMetricSeries(
                listOf(MetricSeriesRow(deviceId = SOURCE_ID, day = day, key = KEY, value = minutes)),
            )
            mutationSeq.value += 1
            true
        }.getOrDefault(false)
}
