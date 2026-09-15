package com.noop.ingest

import android.content.Context
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit

// MARK: - Pulling the three scores from WHOOP's cloud
//
// The strap gives this app raw signal over Bluetooth and the app scores it itself. The cloud gives
// WHOOP'S OWN scores — the recovery percentage, the day strain and the sleep performance the wearer
// sees in WHOOP's app. Those are the figures the Today rings are meant to show, and nothing on the
// phone can reproduce them: they are proprietary.
//
// SO THEY GET THEIR OWN SOURCE. [SOURCE_ID] is distinct from the strap's own "my-whoop", and from the
// computed "-noop" lane, so a cloud recovery of 71 % never silently overwrites a locally derived
// figure and the app can always say which of the two a number came from. The day resolver picks a
// winner per day exactly as it does for every other source.
//
// PAGED, AND BOUNDED. WHOOP returns a `next_token` per page; this follows it up to [MAX_PAGES], which
// at 25 records a page covers well over a year. An unbounded follow would let a server decide how long
// this runs for.
//
// FAILURE IS A COUNT, NOT AN EXCEPTION. Every step returns what it managed; a dead network syncs
// nothing and leaves everything that was already stored exactly as it was.

object WhoopCloudSync {

    /** The device/source id everything from the cloud is written under. */
    const val SOURCE_ID = "whoop-cloud"

    /** WHOOP's own sleep-performance percentage, banked per day on the generic series seam. */
    const val KEY_SLEEP_PERFORMANCE = "sleep_performance"

    /** WHOOP's sleep score for [day], or null when that night was never scored. */
    suspend fun sleepScore(repo: WhoopRepository, day: String): Double? = runCatching {
        repo.metricSeries(SOURCE_ID, KEY_SLEEP_PERFORMANCE, day, day).lastOrNull()?.value
    }.getOrNull()

    /**
     * How far back a full sync reaches.
     *
     * A YEAR, not a month. The level timeline offers 1y and All, and the muscle and streak surfaces
     * read whatever history exists — a thirty-day sync silently capped every one of them at thirty
     * days while looking like a complete account. Paging is what makes this affordable: the window is
     * walked in pages, and a wearer with three months of data pays for three months.
     */
    const val DEFAULT_DAYS = 365L

    /**
     * Page ceiling per endpoint, so a paging bug cannot run forever.
     *
     * At 25 records a page this covers three years of daily records, which is past anything the app
     * asks for. It is a runaway guard, not a history limit.
     */
    private const val MAX_PAGES = 60

    /**
     * The two spellings of the paging parameter, tried in order.
     *
     * WHOOP returns `next_token` in the body and documents `nextToken` on the request. One of them is
     * what their v2 accepts and the other is a 400; rather than guess, the walk tries the documented
     * one and falls back once.
     */
    private val TOKEN_PARAMS = listOf("nextToken", "next_token")

    private val http: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /** What one sync managed, and what each endpoint actually said. */
    data class Result(
        val days: Int,
        val connected: Boolean,
        /**
         * One short line per endpoint: the HTTP status and how many records it returned.
         *
         * THIS EXISTS BECAUSE SILENCE WAS INDISTINGUISHABLE FROM EMPTINESS. The first cut swallowed a
         * failed request and returned no records, so a 403 from a scope the wearer had not granted
         * looked exactly like an account with no data — and the only thing on screen was three dashes.
         * A sync that cannot get something has to be able to say which thing and why.
         */
        val note: String = "",
    )

    /** Preference key holding [Result.note] from the last attempt, for the Data Sources card. */
    private const val KEY_LAST_NOTE = "whoop.cloud.lastNote"

    /** How long a cloud sync stays fresh. WHOOP scores a cycle once; polling it harder buys nothing. */
    private const val STALE_AFTER_MS = 30L * 60L * 1000L

    private const val KEY_LAST_AT = "whoop.cloud.lastSyncAt"

    /**
     * Sync only if the last one is older than [STALE_AFTER_MS].
     *
     * WHAT THIS IS FOR. Nothing else called the sync except a manual pull, so a wearer who connected
     * their account and then opened the app saw nothing and had no way to know whether the connection
     * had worked. This makes opening Today enough.
     *
     * The guard is a STORED timestamp rather than a process flag, so backgrounding and reopening the app
     * ten times in a minute does not make ten round trips to WHOOP.
     */
    suspend fun syncIfStale(context: Context, repo: WhoopRepository): Result? {
        if (!WhoopCloudAuth.isConfigured || !WhoopCloudAuth.isConnected(context)) return null
        val last = prefs(context).getLong(KEY_LAST_AT, 0L)
        val now = System.currentTimeMillis()
        if (now - last < STALE_AFTER_MS) return null
        prefs(context).edit().putLong(KEY_LAST_AT, now).apply()
        return sync(context, repo)
    }

    /** What the last sync reported, or null when one has never run. */
    fun lastNote(context: Context): String? =
        prefs(context).getString(KEY_LAST_NOTE, null)?.takeIf { it.isNotBlank() }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_prefs", android.content.Context.MODE_PRIVATE)

    /**
     * Pull the last [days] days and store them.
     *
     * Returns `connected = false` when the wearer has never signed in or the token could not be
     * refreshed — the caller shows the sign-in rather than an error, because that is the fix.
     */
    suspend fun sync(
        context: Context,
        repo: WhoopRepository,
        days: Long = DEFAULT_DAYS,
    ): Result = withContext(Dispatchers.IO) {
        if (!WhoopCloudAuth.isConfigured) {
            return@withContext Result(0, connected = false, note = "no credentials in this build")
        }
        val token = WhoopCloudAuth.accessToken(context)
            ?: return@withContext Result(0, connected = false, note = "not signed in")

        val end = Instant.now()
        val start = end.minus(days, ChronoUnit.DAYS)

        // CYCLES FIRST, and not only for strain: a recovery record identifies its day only through
        // `cycle_id`, so without the cycle map built from every page, a recovery whose cycle landed on
        // a later page would be unplaceable and silently dropped.
        val cycleDaysPerPage = ArrayList<Map<String, WhoopCloudApi.CloudDay>>()
        val dayByCycleId = HashMap<String, String>()
        val cyclesFetched = fetchAll(token, "cycle", start, end)
        cyclesFetched.pages.forEach { page ->
            val (days, ids) = WhoopCloudApi.parseCycles(page)
            cycleDaysPerPage.add(days)
            dayByCycleId.putAll(ids)
        }

        val recoveryFetched = fetchAll(token, "recovery", start, end)
        val recovery = recoveryFetched.pages.map { WhoopCloudApi.parseRecovery(it, dayByCycleId) }
        val sleepFetched = fetchAll(token, "activity/sleep", start, end)
        val sleep = sleepFetched.pages.map { WhoopCloudApi.parseSleep(it) }

        // Records READ versus days STORED are different numbers, and the gap is the interesting part: a
        // hundred records that all come back PENDING_SCORE store nothing, and without both figures that
        // is indistinguishable from a request that failed.
        val note = listOf(cyclesFetched.note, recoveryFetched.note, sleepFetched.note)
            .joinToString(" · ")
        prefs(context).edit().putString(KEY_LAST_NOTE, note).apply()

        val all = WhoopCloudApi.merge(*(cycleDaysPerPage + recovery + sleep).toTypedArray())
        if (all.isEmpty()) return@withContext Result(0, connected = true, note = note)

        val rows = all.map { d ->
            DailyMetric(
                deviceId = SOURCE_ID,
                day = d.day,
                totalSleepMin = d.totalSleepMin,
                efficiency = d.efficiency,
                deepMin = d.deepMin,
                remMin = d.remMin,
                lightMin = d.lightMin,
                restingHr = d.restingHr,
                avgHrv = d.hrv,
                recovery = d.recovery,
                strain = d.strain,
                respRateBpm = d.respRateBpm,
            )
        }
        // WHOOP'S OWN SLEEP SCORE, on the generic series seam.
        //
        // `DailyMetric` has no column for it, and the first cut therefore re-scored the night with this
        // app's own RestScorer — which produces a different number from the one the wearer sees in
        // WHOOP's app, for a ring that is explicitly labelled as WHOOP's. Two definitions of "sleep
        // score" on one tile is exactly the kind of quiet disagreement this project treats as a bug, so
        // the real figure is banked here rather than approximated.
        val sleepScoreRows = all.mapNotNull { d ->
            d.sleepPerformance?.let {
                com.noop.data.MetricSeriesRow(
                    deviceId = SOURCE_ID,
                    day = d.day,
                    key = KEY_SLEEP_PERFORMANCE,
                    value = it,
                )
            }
        }

        val stored = runCatching {
            repo.upsertDevice(SOURCE_ID, name = "WHOOP (cloud)")
            repo.upsertDailyMetrics(rows)
            if (sleepScoreRows.isNotEmpty()) repo.upsertMetricSeries(sleepScoreRows)
            true
        }.getOrDefault(false)
        // A failed write is reported as zero days rather than as the count it TRIED to store — the
        // caller's message goes on screen, and "synced 30 days" over an empty table is the worst of
        // both.
        Result(days = if (stored) rows.size else 0, connected = true, note = note)
    }

    /**
     * Every page of one endpoint, as raw bodies.
     *
     * Bodies rather than parsed maps because each endpoint parses differently, and the caller already
     * knows which parser it wants — this half only has to know how to follow a `next_token`.
     */
    /** Pages, plus a one-line account of what the endpoint did. */
    private data class Fetched(val pages: List<String>, val note: String)

    private fun fetchAll(
        token: String,
        path: String,
        start: Instant,
        end: Instant,
    ): Fetched {
        // Each base is tried until one ANSWERS. A 404 means this version does not serve this endpoint,
        // which is information, not a failure — so it moves on rather than giving up. Anything else (a
        // 401, a 429, a dead socket) is the endpoint's real answer and is reported as it stands.
        var last = Fetched(emptyList(), "$path: no response")
        for (base in WhoopCloudApi.BASES) {
            val attempt = fetchFrom(token, base, path, start, end)
            if (attempt.pages.isNotEmpty() || !attempt.note.contains("HTTP 404")) return attempt
            last = attempt
        }
        return last
    }

    private fun fetchFrom(
        token: String,
        base: String,
        path: String,
        start: Instant,
        end: Instant,
    ): Fetched {
        val out = ArrayList<String>()
        var status = 0
        var pagingStatus = 0
        var pagingBody: String? = null
        var stalled = false
        var failure: String? = null
        var next: String? = null
        var page = 0
        var tokenParam = TOKEN_PARAMS.first()
        var triedBothParams = false
        while (page++ < MAX_PAGES) {
            val url = buildString {
                append(base).append('/').append(path)
                append("?start=").append(encode(WhoopCloudApi.rfc3339(start)))
                append("&end=").append(encode(WhoopCloudApi.rfc3339(end)))
                append("&limit=25")
                // ENCODED. A `next_token` is base64-ish and carries `=` and `+`; appended raw it makes
                // a malformed query. Encoding alone did not fix the 400, so the PARAMETER NAME is tried
                // both ways — WHOOP's response field is `next_token` and its documented request
                // parameter is `nextToken`, and only the server knows which its v2 actually accepts.
                // Whichever works is remembered for the rest of the walk.
                next?.let { append("&").append(tokenParam).append("=").append(encode(it)) }
            }
            val body = runCatching {
                val request = Request.Builder()
                    .url(url)
                    .header("Authorization", "Bearer $token")
                    .get()
                    .build()
                http.newCall(request).execute().use { response ->
                    // Recorded separately: a failed page AFTER good ones is a paging problem, not the
                    // endpoint's verdict. Letting it overwrite `status` reported "HTTP 400" for a call
                    // that had in fact returned twenty-nine records, which reads as total failure.
                    if (response.isSuccessful) {
                        status = response.code
                        response.body?.string()
                    } else {
                        pagingStatus = response.code
                        // THE SERVER'S OWN WORDS. Two rounds of guessing at this 400 from the status
                        // code alone got nowhere; WHOOP returns a JSON error that names the offending
                        // parameter, and reading it is the difference between fixing this and guessing
                        // again. Truncated because it goes in a preference and onto a card.
                        if (pagingBody == null) {
                            pagingBody = response.body?.string()?.take(180)?.replace("\"", "'")
                        }
                        null
                    }
                }
            }.onFailure { failure = it.javaClass.simpleName }.getOrNull()

            if (body == null) {
                // A rejected PAGE is retried once under the other parameter name before giving up. The
                // first page never takes this path (it sends no token), so this cannot mask a real
                // authorisation or availability failure.
                if (next != null && !triedBothParams) {
                    triedBothParams = true
                    tokenParam = TOKEN_PARAMS.last { it != tokenParam }
                    pagingStatus = 0
                    page--
                    continue
                }
                break
            }
            out.add(body)
            val advanced = WhoopCloudApi.nextToken(body)
            // A TOKEN THAT DOES NOT MOVE IS NOT A PAGE. Sending a parameter the server ignores gets a
            // 200 and the SAME page back, forever — which is what produced 1,488 "records" for a year
            // that holds a few hundred, and then a 429 for hammering the endpoint sixty times. Stopping
            // on a repeat turns a silent infinite loop into a clean, reportable end of data.
            if (advanced == null || advanced == next) {
                if (advanced != null) stalled = true
                break
            }
            next = advanced
        }
        val version = base.substringAfterLast('/')
        val records = out.sumOf { WhoopCloudApi.recordCount(it) }
        val what = failure ?: if (status == 0) "HTTP $pagingStatus" else "HTTP $status"
        // The paging note is appended rather than substituted, so a partial read says so plainly
        // instead of presenting itself as a complete one.
        val partial = when {
            stalled -> " (paging stalled: token did not advance)"
            out.isNotEmpty() && pagingStatus != 0 ->
                " (paging stopped at HTTP $pagingStatus: ${pagingBody ?: "no body"})"
            else -> ""
        }
        return Fetched(out, "$path($version): $what, $records records$partial")
    }

    /** Percent-encoding for a query VALUE. `+` is a space in a query string, so it must not survive. */
    private fun encode(raw: String): String =
        java.net.URLEncoder.encode(raw, "UTF-8").replace("+", "%20")
}
