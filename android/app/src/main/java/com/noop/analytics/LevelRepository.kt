package com.noop.analytics

import android.content.Context
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.ingest.LiftingImporter
import com.noop.ingest.MuscleGroup
import java.time.LocalDate

// MARK: - Assembling the level's inputs
//
// The engine is pure and knows nothing about where a figure came from. This is the half that reads the
// stores, converts each metric into the unit the formula expects, and can do it AS OF an earlier day so
// the trend arrows have something honest to compare against.
//
// AS-OF IS REAL, NOT A CACHED NUMBER. Asking for the level three days ago re-runs the formula over the
// data as it stood then, against the SAME frozen baselines. That is the only way a comparison means
// anything: a level from a cache would have been computed against whatever scale existed that day.
//
// A MISSING METRIC STAYS MISSING. Every read here returns null rather than a stand-in, because the
// engine redistributes weight around absent components and a zero would be scored as a bad reading.

object LevelRepository {

    /** The stress series is stored 0–3 (WHOOP's own scale); the formula wants 0–100. */
    private const val STRESS_SERIES_MAX = 3.0

    /** How far back a baseline derivation looks. Everything there is, in practice. */
    private const val HISTORY_DAYS = 3650L

    /** The window the muscle term reads sessions from. */
    private const val MUSCLE_WINDOW_DAYS = 7L

    /**
     * Build the engine's inputs as of [asOf].
     *
     * [days] is the merged daily history, oldest first, as `daysMerged` returns it. Passing it in
     * rather than reading it here lets one read serve today, three days ago and a month ago.
     */
    suspend fun inputs(
        repo: WhoopRepository,
        deviceId: String,
        days: List<DailyMetric>,
        asOf: LocalDate,
    ): LevelInputs {
        val upTo = days.filter { it.day <= asOf.toString() }
        val window = upTo.takeLast(3)

        // Sleep consistency needs a longer run than the three days it is averaged over: it IS the
        // spread of the last few weeks, so it is computed per day from the 28 nights before it.
        val consistency = window.mapNotNull { day ->
            val idx = upTo.indexOf(day)
            val nights = upTo.subList(maxOf(0, idx - 27), idx + 1).mapNotNull { it.totalSleepMin?.div(60.0) }
            VitalityEngine.sleepConsistency(nights)?.times(100.0)
        }
        val sleepScores = window.mapNotNull { RestScorer.restFromDaily(it) }

        val today = upTo.lastOrNull()
        val stress = runCatching { stressSeries(repo, asOf) }.getOrDefault(emptyList())

        return LevelInputs(
            sleepScores = sleepScores,
            consistencyScores = consistency,
            hrv = today?.avgHrv,
            rhr = today?.restingHr?.toDouble(),
            vo2max = runCatching { vo2max(repo, deviceId, asOf) }.getOrNull(),
            respRate = today?.respRateBpm,
            muscleSessions = runCatching { muscleSessions(repo, asOf) }.getOrDefault(emptyList()),
            stressScores = stress,
            // No meditation log exists yet, so this is honestly zero rather than guessed from a
            // breathing session that may have been a test of the pacer. When a log lands, read it here.
            meditationDays = 0,
            stepsToday = today?.steps,
        )
    }

    /**
     * The whole-history readings each baseline is derived from, ONCE.
     *
     * Only ever called when the scale has never been frozen — see [LevelBaselineStore]. Everything
     * available is used: the wider the history, the better the permanent yardstick.
     */
    suspend fun baselineHistory(
        repo: WhoopRepository,
        deviceId: String,
        days: List<DailyMetric>,
    ): Map<LevelMetric, List<Double>> {
        val today = LocalDate.now()
        val from = today.minusDays(HISTORY_DAYS).toString()
        val to = today.toString()

        val consistencyRun = days.indices.mapNotNull { i ->
            val run = days.subList(maxOf(0, i - 27), i + 1).mapNotNull { it.totalSleepMin?.div(60.0) }
            VitalityEngine.sleepConsistency(run)?.times(100.0)
        }

        return mapOf(
            LevelMetric.SLEEP_SCORE to days.mapNotNull { RestScorer.restFromDaily(it) },
            LevelMetric.SLEEP_CONSISTENCY to consistencyRun,
            LevelMetric.HRV to days.mapNotNull { it.avgHrv },
            LevelMetric.RHR to days.mapNotNull { it.restingHr?.toDouble() },
            LevelMetric.VO2MAX to runCatching {
                repo.metricSeries("$deviceId-noop", "vo2max_est", from, to).map { it.value }
            }.getOrDefault(emptyList()),
            LevelMetric.RESP_RATE to days.mapNotNull { it.respRateBpm },
            LevelMetric.MUSCLE_LOAD to runCatching { dailyMuscleLoads(repo, from, to) }.getOrDefault(emptyList()),
            LevelMetric.STRESS to runCatching {
                repo.metricSeries("my-whoop", "stress", from, to)
                    .map { (it.value / STRESS_SERIES_MAX * 100.0).coerceIn(0.0, 100.0) }
            }.getOrDefault(emptyList()),
        )
    }

    /** Stress for the three days ending at [asOf], converted from the stored 0–3 scale to 0–100. */
    private suspend fun stressSeries(repo: WhoopRepository, asOf: LocalDate): List<Double> =
        repo.metricSeries("my-whoop", "stress", asOf.minusDays(2).toString(), asOf.toString())
            .sortedBy { it.day }
            .map { (it.value / STRESS_SERIES_MAX * 100.0).coerceIn(0.0, 100.0) }

    /** The newest VO2max estimate at or before [asOf]. */
    private suspend fun vo2max(repo: WhoopRepository, deviceId: String, asOf: LocalDate): Double? =
        repo.metricSeries("$deviceId-noop", "vo2max_est", asOf.minusDays(90).toString(), asOf.toString())
            .maxByOrNull { it.day }?.value

    /**
     * Training sessions in the window, as (raw volume load, days ago).
     *
     * One entry per DAY that had lifting, summed across muscle groups — the formula weights by how long
     * ago a session was, and two exercises on the same morning are one session's worth of load, not two.
     */
    private suspend fun muscleSessions(repo: WhoopRepository, asOf: LocalDate): List<Pair<Double, Int>> {
        val from = asOf.minusDays(MUSCLE_WINDOW_DAYS).toString()
        val to = asOf.toString()
        val byDay = HashMap<String, Double>()
        MuscleGroup.entries.forEach { group ->
            repo.metricSeries(LiftingImporter.SOURCE_ID, LiftingImporter.muscleVolumeKey(group), from, to)
                .forEach { row -> byDay[row.day] = (byDay[row.day] ?: 0.0) + row.value }
        }
        return byDay.entries
            .sortedBy { it.key }
            .mapNotNull { (day, load) ->
                val ago = runCatching {
                    java.time.temporal.ChronoUnit.DAYS.between(LocalDate.parse(day), asOf).toInt()
                }.getOrNull() ?: return@mapNotNull null
                load to ago
            }
    }

    /** Every day's total volume load in the range, for deriving the frozen muscle range. */
    private suspend fun dailyMuscleLoads(repo: WhoopRepository, from: String, to: String): List<Double> {
        val byDay = HashMap<String, Double>()
        MuscleGroup.entries.forEach { group ->
            repo.metricSeries(LiftingImporter.SOURCE_ID, LiftingImporter.muscleVolumeKey(group), from, to)
                .forEach { row -> byDay[row.day] = (byDay[row.day] ?: 0.0) + row.value }
        }
        return byDay.values.toList()
    }

    /**
     * The level now, three days ago and a month ago, against one frozen scale.
     *
     * Null entries where there was not enough data to score that day, so the UI can say "no comparison"
     * rather than drawing an arrow from a number it made up.
     */
    suspend fun trend(
        context: Context,
        repo: WhoopRepository,
        deviceId: String,
    ): LevelTrend {
        val days = runCatching { repo.daysMerged(deviceId) }.getOrDefault(emptyList())
        val baselines = LevelBaselineStore.resolve(context) {
            kotlinx.coroutines.runBlocking { baselineHistory(repo, deviceId, days) }
        }
        val today = LocalDate.now()
        suspend fun at(date: LocalDate) =
            LevelEngine.compute(inputs(repo, deviceId, days, date), baselines)

        return LevelTrend(
            now = at(today),
            threeDaysAgo = at(today.minusDays(3)),
            monthAgo = at(today.minusDays(30)),
        )
    }
}

/** The level now and at two earlier points, for the header's trend arrows. */
data class LevelTrend(
    val now: LevelBreakdown?,
    val threeDaysAgo: LevelBreakdown?,
    val monthAgo: LevelBreakdown?,
) {
    /** Points gained or lost since three days ago, or null when that day cannot be scored. */
    val deltaThreeDays: Double? get() = delta(threeDaysAgo)

    /** Points gained or lost since a month ago, or null when that day cannot be scored. */
    val deltaMonth: Double? get() = delta(monthAgo)

    private fun delta(then: LevelBreakdown?): Double? {
        val a = now?.level ?: return null
        val b = then?.level ?: return null
        return a - b
    }
}
