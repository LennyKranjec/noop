package com.noop.ingest

import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

// MARK: - The WHOOP developer API, parsed
//
// Three endpoints carry the three scores this app shows at the top of Today:
//
//   /developer/v1/recovery        → recovery score, resting HR, HRV
//   /developer/v1/cycle           → day strain
//   /developer/v1/activity/sleep  → sleep performance, the stage breakdown, respiratory rate
//
// PARSING ONLY, and pure, so the shape can be pinned by tests that need no network and no account —
// the same split [HevyApi] uses. The client and the token handling live in [WhoopCloudAuth]; what
// lands in Room is decided by [WhoopCloudSync].
//
// A RECORD WITHOUT A SCORE IS SKIPPED, NOT ZEROED. WHOOP returns `score_state` as one of SCORED,
// PENDING_SCORE or UNSCORABLE, and only the first carries a `score` object at all. A pending night is
// a night WHOOP has not finished with — writing a zero for it would put a terrible recovery on a day
// that simply has not been graded yet, and it would then be overwritten hours later, so the wearer
// would watch their history change under them.
//
// THE DAY A RECORD BELONGS TO COMES FROM ITS OWN OFFSET. Every record carries `timezone_offset` as
// "+01:00", and a cycle that began at 23:40 belongs to the day it began ON, in the wearer's zone at
// the time — not in the phone's current zone. Bucketing by the phone's zone puts a flight's worth of
// days one off, which looks exactly like missing data.

object WhoopCloudApi {

    /**
     * The API roots, newest first.
     *
     * TRIED IN ORDER, PER ENDPOINT, because which one answers is not something this app can know in
     * advance: WHOOP runs both, an app registration is bound to one of them, and the first cut hard-coded
     * v1 and got a 404 on recovery and on sleep while cycles answered perfectly. Guessing the other way
     * would simply have moved which two endpoints were dead.
     *
     * The version that answered is reported in the sync note, so the next person reading this does not
     * have to repeat the experiment.
     */
    val BASES = listOf(
        "https://api.prod.whoop.com/developer/v2",
        "https://api.prod.whoop.com/developer/v1",
    )

    /** One day's worth of what the cloud knows, already reduced to the fields this app stores. */
    data class CloudDay(
        val day: String,
        val recovery: Double? = null,
        val restingHr: Int? = null,
        val hrv: Double? = null,
        val strain: Double? = null,
        val sleepPerformance: Double? = null,
        val totalSleepMin: Double? = null,
        val deepMin: Double? = null,
        val remMin: Double? = null,
        val lightMin: Double? = null,
        val efficiency: Double? = null,
        val respRateBpm: Double? = null,
    )

    /** WHOOP's own scoring state. Only [SCORED] carries a `score` object. */
    private const val SCORED = "SCORED"

    /**
     * `GET /recovery` — the recovery score and the two markers under it.
     *
     * Keyed by the CYCLE's day, which the caller supplies from the cycle response: a recovery record
     * carries `cycle_id` but not the cycle's own start, so keying it by `created_at` would file a
     * recovery computed at 07:00 on the day it was calculated rather than the day it describes.
     */
    fun parseRecovery(body: String, cycleDayById: Map<String, String>): Map<String, CloudDay> {
        val out = LinkedHashMap<String, CloudDay>()
        records(body).forEach { rec ->
            if (rec.optString("score_state") != SCORED) return@forEach
            // KEYED AS A STRING, deliberately. v1 numbers its cycles and v2 moved several ids to UUIDs;
            // reading this as a Long means every recovery whose id is not numeric silently fails to
            // place and the whole endpoint looks empty. A string key is correct for both.
            val day = cycleDayById[rec.optString("cycle_id").takeIf { it.isNotBlank() }] ?: return@forEach
            val score = rec.optJSONObject("score") ?: return@forEach
            // `user_calibrating` means WHOOP itself says the figure is not yet meaningful. Storing it
            // would show a number the source does not stand behind.
            if (score.optBoolean("user_calibrating", false)) return@forEach
            out[day] = CloudDay(
                day = day,
                recovery = score.optDoubleOrNull("recovery_score"),
                restingHr = score.optDoubleOrNull("resting_heart_rate")?.toInt(),
                hrv = score.optDoubleOrNull("hrv_rmssd_milli")?.let { hrvMilliseconds(it) },
            )
        }
        return out
    }

    /**
     * `GET /cycle` — day strain, and the day key every other endpoint is filed against.
     *
     * Returns the day per cycle id as well, because the recovery endpoint can only be placed through
     * it. A cycle spans a wake period rather than a calendar day, so the day it belongs to is the day
     * its START falls on, in the offset the record itself carries.
     */
    fun parseCycles(body: String): Pair<Map<String, CloudDay>, Map<String, String>> {
        val byDay = LinkedHashMap<String, CloudDay>()
        val dayById = LinkedHashMap<String, String>()
        records(body).forEach { rec ->
            val id = rec.optString("id").takeIf { it.isNotBlank() } ?: return@forEach
            val day = localDay(rec.optString("start"), rec.optString("timezone_offset")) ?: return@forEach
            dayById[id] = day
            if (rec.optString("score_state") != SCORED) return@forEach
            val score = rec.optJSONObject("score") ?: return@forEach
            byDay[day] = CloudDay(day = day, strain = score.optDoubleOrNull("strain"))
        }
        return byDay to dayById
    }

    /**
     * `GET /activity/sleep` — the night, filed against the day it is credited to.
     *
     * NAPS ARE SKIPPED. WHOOP flags them, and folding a nap into the night's totals would inflate the
     * duration and wreck the stage breakdown. The day a night belongs to is the day it ENDS on, which
     * is what the rest of this app means by a night — a sleep that starts at 23:40 on Tuesday is
     * Wednesday's row everywhere else, and a cloud import that disagreed would just look broken.
     */
    fun parseSleep(body: String): Map<String, CloudDay> {
        val out = LinkedHashMap<String, CloudDay>()
        records(body).forEach { rec ->
            if (rec.optBoolean("nap", false)) return@forEach
            if (rec.optString("score_state") != SCORED) return@forEach
            val day = localDay(rec.optString("end"), rec.optString("timezone_offset")) ?: return@forEach
            val score = rec.optJSONObject("score") ?: return@forEach
            val stages = score.optJSONObject("stage_summary")
            val deep = stages?.optDoubleOrNull("total_slow_wave_sleep_time_milli")?.msToMin()
            val rem = stages?.optDoubleOrNull("total_rem_sleep_time_milli")?.msToMin()
            val light = stages?.optDoubleOrNull("total_light_sleep_time_milli")?.msToMin()
            // The total is the three ASLEEP stages, not in-bed time: awake time is reported separately
            // and adding it would turn "you slept" into "you lay there", which is a different figure.
            val total = listOfNotNull(deep, rem, light).takeIf { it.isNotEmpty() }?.sum()
            out[day] = CloudDay(
                day = day,
                sleepPerformance = score.optDoubleOrNull("sleep_performance_percentage"),
                totalSleepMin = total,
                deepMin = deep,
                remMin = rem,
                lightMin = light,
                efficiency = score.optDoubleOrNull("sleep_efficiency_percentage"),
                respRateBpm = score.optDoubleOrNull("respiratory_rate"),
            )
        }
        return out
    }

    /**
     * Fold the three reads into one row per day.
     *
     * Later sources fill only the gaps the earlier ones left, so no endpoint can blank a field another
     * one measured — the three carry disjoint fields in practice, and this keeps that true if WHOOP
     * ever starts returning one of them in two places.
     */
    fun merge(vararg parts: Map<String, CloudDay>): List<CloudDay> {
        val out = LinkedHashMap<String, CloudDay>()
        parts.forEach { part ->
            part.forEach { (day, d) ->
                val cur = out[day]
                out[day] = if (cur == null) {
                    d
                } else {
                    cur.copy(
                        recovery = cur.recovery ?: d.recovery,
                        restingHr = cur.restingHr ?: d.restingHr,
                        hrv = cur.hrv ?: d.hrv,
                        strain = cur.strain ?: d.strain,
                        sleepPerformance = cur.sleepPerformance ?: d.sleepPerformance,
                        totalSleepMin = cur.totalSleepMin ?: d.totalSleepMin,
                        deepMin = cur.deepMin ?: d.deepMin,
                        remMin = cur.remMin ?: d.remMin,
                        lightMin = cur.lightMin ?: d.lightMin,
                        efficiency = cur.efficiency ?: d.efficiency,
                        respRateBpm = cur.respRateBpm ?: d.respRateBpm,
                    )
                }
            }
        }
        return out.values.sortedBy { it.day }
    }

    /** How many records a page carried, whatever they turned out to be. */
    fun recordCount(body: String): Int = records(body).size

    /** The `next_token` for a paged response, or null on the last page. */
    fun nextToken(body: String): String? =
        runCatching { JSONObject(body).optString("next_token", "").takeIf { it.isNotEmpty() } }
            .getOrNull()

    /** RFC 3339, which is what the range parameters take. */
    fun rfc3339(instant: Instant): String =
        DateTimeFormatter.ISO_INSTANT.format(instant.atZone(ZoneOffset.UTC))

    private fun records(body: String): List<JSONObject> = runCatching {
        val array = JSONObject(body).optJSONArray("records") ?: return emptyList()
        (0 until array.length()).mapNotNull { array.optJSONObject(it) }
    }.getOrDefault(emptyList())

    /**
     * The local calendar day of an RFC-3339 instant, in the offset the RECORD carries.
     *
     * Not the phone's current zone: a cycle recorded in Tokyo belongs to the Tokyo day it happened on,
     * and re-bucketing it when the wearer flies home would silently shift a week of history by one.
     */
    internal fun localDay(instant: String, offset: String): String? = runCatching {
        val zone = runCatching { ZoneOffset.of(offset) }.getOrElse { ZoneId.systemDefault() }
        Instant.parse(instant).atZone(zone).toLocalDate().toString()
    }.getOrNull()

    /**
     * `hrv_rmssd_milli`, in milliseconds, whichever unit it actually arrives in.
     *
     * THE FIELD NAME IS NOT RELIABLE. WHOOP documents it as milliseconds, and it has been observed
     * arriving as SECONDS (0.0654 for a 65 ms RMSSD). Picking one and hoping would either divide this
     * app's HRV by a thousand or multiply it by one — both of which produce a number that is wrong by
     * three orders of magnitude while still looking like a reading.
     *
     * So the value decides. A resting RMSSD below 1 ms is not something a living person produces; a
     * value under that threshold is therefore seconds, and is converted. Everything at or above it is
     * taken as the milliseconds it says it is. The rule is crude, but it is checkable against a real
     * response and it cannot silently mangle a plausible figure into another plausible figure.
     */
    internal fun hrvMilliseconds(raw: Double): Double? {
        if (!raw.isFinite() || raw <= 0.0) return null
        return if (raw < 1.0) raw * 1000.0 else raw
    }

    private fun JSONObject.optDoubleOrNull(key: String): Double? {
        if (!has(key) || isNull(key)) return null
        return optDouble(key, Double.NaN).takeIf { it.isFinite() }
    }

    private fun Double.msToMin(): Double = this / 60_000.0
}
