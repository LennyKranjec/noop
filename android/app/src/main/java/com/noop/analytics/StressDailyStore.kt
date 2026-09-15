package com.noop.analytics

import com.noop.data.MetricSeriesRow
import com.noop.data.WhoopRepository

// MARK: - Banking the day's non-activity high-stress minutes
//
// [DaytimeStress] costs a whole day of heart rate and R-R to compute — three windowed reads and a
// scoring pass. That is affordable once, for today, on a screen that is showing it. It is not
// affordable a year of times inside a card that has to paint in a frame, which is what a streak over
// the same figure would need.
//
// SO THE DAY'S RESULT IS WRITTEN DOWN when it is computed anyway, on the same generic metric-series
// seam hydration and meditation use, and the streak reads the series instead of recomputing it.
//
// A DAY BEFORE THIS EXISTED HAS NO ROW, and that is the honest state: it is unmeasured, not zero. The
// streak spans unmeasured days without counting them, so the figure simply starts accumulating from
// the first day the app saw — rather than awarding a streak for a year nobody measured.
//
// NON-ACTIVITY IS BY CONSTRUCTION. [DaytimeStress] masks ambulatory hours as exertion and leaves them
// unscored, so `highStressMinutes` only ever counts hours the wearer was still through. Nothing is
// subtracted here; there is nothing to subtract.

object StressDailyStore {

    /** The generic metric-series key the day's high-stress minutes are banked under. */
    const val KEY: String = "stress_high_min"

    /** Its own local-only source: this is a COMPUTED figure, not one any device reported. */
    const val SOURCE_ID: String = "stress-daily"

    /**
     * Write [minutes] for [day], replacing whatever was there.
     *
     * REPLACES rather than accumulates: the figure is a recomputation of the whole day, so a second
     * pass later in the afternoon is a better answer to the same question, not more of it. Best-effort
     * — a failed write costs this day's row and nothing else, and the streak treats it as unmeasured.
     */
    suspend fun write(repo: WhoopRepository, day: String, minutes: Int) {
        runCatching {
            repo.upsertDevice(SOURCE_ID, name = "Stress (computed)")
            repo.upsertMetricSeries(
                listOf(
                    MetricSeriesRow(
                        deviceId = SOURCE_ID,
                        day = day,
                        key = KEY,
                        value = minutes.toDouble(),
                    ),
                ),
            )
        }
    }

    /** Every banked day in the range, keyed by local day. Empty when nothing has been banked. */
    suspend fun range(repo: WhoopRepository, from: String, to: String): Map<String, Double> =
        runCatching {
            repo.metricSeries(SOURCE_ID, KEY, from, to).associate { it.day to it.value }
        }.getOrDefault(emptyMap())
}
