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
     * Every per-day series the level needs, read ONCE over a whole span.
     *
     * WHY THIS EXISTS. [inputs] reads four things from the database per day it scores: the stress
     * series, the newest VO2max, the meditation window, and the muscle volume of THIRTEEN groups. That
     * is about sixteen queries a day, which is nothing for the three days [trend] scores and is nearly
     * six thousand for a year of timeline. Prefetching turns the whole span into the same sixteen.
     *
     * Everything here is keyed by local day, so a lookup is a map read and the arithmetic is unchanged:
     * the scores this produces are identical to the per-day reads, just not paid for N times.
     */
    data class LevelSeries(
        /** Stress 0-100 by day. */
        val stress: Map<String, Double>,
        /** VO2max estimates by day, newest-at-or-before wins at read time. */
        val vo2max: List<Pair<String, Double>>,
        /** Total muscle volume load by day, summed across groups. */
        val muscleByDay: Map<String, Double>,
        /** Minutes meditated by day. */
        val meditation: Map<String, Double>,
    ) {
        /** The newest VO2max at or before [day], or null when none was recorded by then. */
        fun vo2maxAsOf(day: String): Double? =
            vo2max.lastOrNull { it.first <= day }?.second

        /** Muscle sessions in the window ending [asOf], as (volume, days ago). */
        fun muscleSessions(asOf: LocalDate): List<Pair<Double, Int>> {
            val from = asOf.minusDays(MUSCLE_WINDOW_DAYS)
            return muscleByDay.entries
                .mapNotNull { (day, load) ->
                    val d = runCatching { LocalDate.parse(day) }.getOrNull() ?: return@mapNotNull null
                    if (d.isAfter(asOf) || d.isBefore(from)) return@mapNotNull null
                    load to java.time.temporal.ChronoUnit.DAYS.between(d, asOf).toInt()
                }
                .sortedByDescending { it.second }
        }

        /** Days with a meditation in the three ending [asOf]. */
        fun meditationDays(asOf: LocalDate): Int =
            (0 until MeditationStore.WINDOW_DAYS).count { back ->
                (meditation[asOf.minusDays(back.toLong()).toString()] ?: 0.0) > 0.0
            }

        /** The three stress readings ending [asOf], oldest first. */
        fun stressWindow(asOf: LocalDate): List<Double> =
            (2 downTo 0).mapNotNull { back -> stress[asOf.minusDays(back.toLong()).toString()] }
    }

    /** Read every series the level needs across [from]..[to], in one pass per series. */
    suspend fun series(
        repo: WhoopRepository,
        deviceId: String,
        from: String,
        to: String,
    ): LevelSeries {
        val stress = runCatching {
            repo.metricSeries("my-whoop", "stress", from, to)
                .associate { it.day to (it.value / STRESS_SERIES_MAX * 100.0).coerceIn(0.0, 100.0) }
        }.getOrDefault(emptyMap())

        val vo2 = runCatching {
            // Reaches back past `from`: a VO2max estimate is sparse and the newest one BEFORE the span
            // is still the current reading on its first day.
            repo.metricSeries("$deviceId-noop", "vo2max_est", "0000-01-01", to)
                .sortedBy { it.day }
                .map { it.day to it.value }
        }.getOrDefault(emptyList())

        val muscle = HashMap<String, Double>()
        MuscleGroup.entries.forEach { group ->
            runCatching {
                repo.metricSeries(
                    LiftingImporter.SOURCE_ID,
                    LiftingImporter.muscleVolumeKey(group),
                    // Back by the window, so the first day of the span still sees the sessions behind it.
                    LocalDate.parse(from).minusDays(MUSCLE_WINDOW_DAYS).toString(),
                    to,
                )
            }.getOrNull()?.forEach { row -> muscle[row.day] = (muscle[row.day] ?: 0.0) + row.value }
        }

        val meditation = runCatching {
            repo.metricSeries(
                MeditationStore.SOURCE_ID,
                MeditationStore.KEY,
                LocalDate.parse(from).minusDays(MeditationStore.WINDOW_DAYS.toLong()).toString(),
                to,
            ).associate { it.day to it.value }
        }.getOrDefault(emptyMap())

        return LevelSeries(stress = stress, vo2max = vo2, muscleByDay = muscle, meditation = meditation)
    }

    /**
     * The same inputs as [inputs], built from prefetched series rather than from the database.
     *
     * Identical arithmetic; the only difference is where the four per-day figures come from.
     */
    fun inputs(
        days: List<DailyMetric>,
        asOf: LocalDate,
        series: LevelSeries,
    ): LevelInputs {
        val upTo = days.filter { it.day <= asOf.toString() }
        val window = upTo.takeLast(3)
        val consistency = window.mapNotNull { day ->
            val idx = upTo.indexOf(day)
            val nights = upTo.subList(maxOf(0, idx - 27), idx + 1).mapNotNull { it.totalSleepMin?.div(60.0) }
            VitalityEngine.sleepConsistency(nights)?.times(100.0)
        }
        val today = upTo.lastOrNull()
        return LevelInputs(
            sleepScores = window.mapNotNull { RestScorer.restFromDaily(it) },
            consistencyScores = consistency,
            hrv = today?.avgHrv,
            rhr = today?.restingHr?.toDouble(),
            vo2max = series.vo2maxAsOf(asOf.toString()),
            respRate = today?.respRateBpm,
            muscleSessions = series.muscleSessions(asOf),
            stressScores = series.stressWindow(asOf),
            meditationDays = series.meditationDays(asOf),
            stepsToday = today?.steps,
        )
    }

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
            // The Focus screen's own log, read AS OF the day being scored so a level from three days ago
            // is scored against the meditations that had happened by then. Never inferred from a
            // breathing session — a pacer someone opened to look at is not a meditation they sat.
            meditationDays = runCatching { MeditationStore.daysInWindow(repo, asOf) }.getOrDefault(0),
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

        val nowInputs = inputs(repo, deviceId, days, today)
        return LevelTrend(
            now = at(today),
            threeDaysAgo = at(today.minusDays(3)),
            monthAgo = at(today.minusDays(30)),
            drivers = LevelPart.entries.mapNotNull { part ->
                LevelDrivers.driver(part, nowInputs, baselines)?.let { part to it }
            }.toMap(),
        )
    }

    /**
     * The level on each of the last [days] days, oldest first.
     *
     * RE-RUN PER DAY, against the one frozen scale — the same rule [trend] follows, and the only way a
     * line means anything: a stored level would have been computed against whatever scale existed that
     * day, and the curve would then show the yardstick moving as if the body had.
     *
     * A day that cannot be scored is ABSENT rather than zero. The chart draws a gap there, because "we
     * could not score you" and "you scored nothing" are different statements and only one is ever true.
     */
    suspend fun history(
        context: Context,
        repo: WhoopRepository,
        deviceId: String,
        days: Int,
    ): List<LevelPoint> {
        val merged = runCatching { repo.daysMerged(deviceId) }.getOrDefault(emptyList())
        val baselines = LevelBaselineStore.resolve(context) {
            kotlinx.coroutines.runBlocking { baselineHistory(repo, deviceId, merged) }
        }
        val today = LocalDate.now()
        // The span is capped at the data that actually exists: asking for a year when the store holds
        // three months would run the formula over nine months of certain nulls.
        val earliest = merged.firstOrNull()?.day?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
        val requested = today.minusDays((days - 1).toLong())
        val start = if (earliest != null && earliest.isAfter(requested)) earliest else requested

        // ONE READ PER SERIES for the whole span, not per day - see [LevelSeries]. At sixteen queries a
        // day, a year of timeline was nearly six thousand of them.
        val prefetched = series(repo, deviceId, start.toString(), today.toString())

        val out = ArrayList<LevelPoint>()
        var cursor = start
        while (!cursor.isAfter(today)) {
            LevelEngine.compute(inputs(merged, cursor, prefetched), baselines)?.let {
                out.add(LevelPoint(day = cursor.toString(), level = it.level))
            }
            cursor = cursor.plusDays(1)
        }
        return out
    }
}

/** One day's level, for the header's timeline. */
data class LevelPoint(val day: String, val level: Double)

/** The level now and at two earlier points, for the header's trend arrows. */
data class LevelTrend(
    val now: LevelBreakdown?,
    val threeDaysAgo: LevelBreakdown?,
    val monthAgo: LevelBreakdown?,
    /** Which metric is behind each part today, so a lever can name itself. Empty when unscored. */
    val drivers: Map<LevelPart, LevelDriver> = emptyMap(),
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
