package com.noop.ingest

import android.content.Context
import android.net.Uri
import com.noop.data.ImportSummary
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// MARK: - Alphaprog CSV
//
// Alphaprog exports a training log as a semicolon-separated file that is not really a table: it is a
// printed workout, with a header line per session, a title line per exercise, and a tiny three-column
// grid of sets between them. A generic CSV reader makes nonsense of it, so this is a small state
// machine that reads it the way a person would.
//
// THE SHAPE, in the order it appears:
//
//   "Upper B (Do) · Tag 2 · Woche 32 · Upper";"2026-09-14 13:44 Uhr";"53 Min."
//   "1. Rudern mit Brustauflage eng · Maschine · 10 Wdh"
//   #;KG;WDH
//   1;30;10
//   2;27,5;7
//   3;-;-
//
// GERMAN NUMBERS AND A GERMAN CLOCK. Weights use a comma decimal separator, and a dash marks a set
// that was planned and not done. Both are parsed here rather than pushed onto the shared lifting
// parser, because they are this exporter's conventions and not lifting's.
//
// A SESSION HEADER HAS THREE DURATION FORMS AND A ONE- OR TWO-DIGIT CLOCK. "53 Min.", "1:19 Std."
// and "45 s" all appear, and a session that started at "5:18 Uhr" writes one digit. The first cut of
// this parser accepted only `HH:MM` and `N Min.` — so it matched 26 of the file's 96 sessions, and the
// other 70 sessions' exercises were appended to whichever session HAD matched. The result was a single
// fabricated 190-exercise day holding most of a year's training, which is exactly the kind of failure
// that looks like data rather than like a bug: the totals were plausible, the days were not. Every form
// the export actually writes is matched here, and a test asserts the session COUNT against the real file.
//
// THE SET GRID COMES IN THREE FLAVOURS, and only one of them is volume load:
//
//   #;KG;WDH   weight × repetitions  → volume load, the figure the muscle view reads
//   #;KG;SEK   weight × seconds      → a loaded hold; the second column is TIME, not reps
//   #;MIN.     minutes               → a timed effort with no external load at all
//
// Only the first contributes kilograms. Multiplying 30 kg by 45 SECONDS would produce "1,350 kg" of
// volume from a 45-second hold, which is not a smaller or larger number than the truth — it is a
// different quantity wearing the same unit. The other two are counted as sets that happened and
// contribute no volume, which is the honest reading of what the file says.
//
// AN UNPERFORMED SET IS NOT A ZERO. "3;-;-" is a row the app printed and the wearer left empty; it
// contributes no volume and is not counted as a set. Treating it as 0 kg × 0 reps would be the same
// arithmetic and a different claim — it would say they did a set of nothing.

object AlphaprogImporter {

    /** Shown to the wearer, and the label on the import result. */
    const val SOURCE_LABEL = "Alphaprog"

    /**
     * Stored under the SAME source as every other lifting import.
     *
     * Alphaprog is a different exporter, not a different kind of training: keeping it here means the
     * muscle view, the workouts list and the level's muscle term all read one series rather than
     * needing to know which app the wearer happened to log in.
     */
    const val SOURCE_ID = LiftingImporter.SOURCE_ID

    /** Big enough for years of logging; small enough that a wrong file cannot exhaust memory. */
    private const val MAX_BYTES = 32 * 1024 * 1024

    /**
     * The session header: title, date, clock, duration.
     *
     * The duration is captured whole and read by [durationMinutes] rather than pattern-matched here —
     * there are three forms of it, and a regex that tries to hold them all is a regex nobody can check
     * against the file.
     */
    private val SESSION =
        Regex("""^"([^"]*)";"(\d{4}-\d{2}-\d{2}) (\d{1,2}:\d{2})[^"]*";"([^"]*)"""")

    /** An exercise title line: `"3. Brustpresse · Maschine · 10 Wdh"`. */
    private val EXERCISE = Regex("""^"\d+\.\s*(.+?)"$""")

    /** `1:19 Std.` — hours and minutes. */
    private val DURATION_HM = Regex("""^(\d+):(\d{2})\s*Std""")

    /** `53 Min.` */
    private val DURATION_MIN = Regex("""^(\d+)\s*Min""")

    /** `45 s` — a session so short the exporter gives it in seconds. */
    private val DURATION_SEC = Regex("""^(\d+)\s*s\b""")

    /**
     * Which grid the rows below a header belong to.
     *
     * Carried as state through the parse because a row `1;30;45` is identical in every grid; only the
     * header two lines above says whether the 45 is repetitions or seconds.
     */
    private enum class Grid { REPS, SECONDS, MINUTES, UNKNOWN }

    /** The set grid's own header, which carries no data but names the grid. */
    private fun gridOf(line: String): Grid? = when (line) {
        "#;KG;WDH" -> Grid.REPS
        "#;KG;SEK" -> Grid.SECONDS
        "#;MIN." -> Grid.MINUTES
        else -> if (line.startsWith("#;")) Grid.UNKNOWN else null
    }

    /** One performed set: index, weight, reps. */
    private val SET = Regex("""^(\d+);([^;]*);([^;]*)$""")

    /** A two-column row, used by the minutes grid: index, minutes. */
    private val SET_2COL = Regex("""^(\d+);([^;]*)$""")

    /** One exercise inside a session, with only the sets that were actually done. */
    data class Exercise(val name: String, val sets: List<Set>)

    /**
     * One performed set.
     *
     * [reps] is repetitions and nothing else. A loaded hold's seconds and a timed effort's minutes are
     * real work and are recorded as [holdSeconds] / [minutes], but they never become reps: the whole
     * point of the distinction is that `weight × seconds` is not a mass, and calling it one would put a
     * fabricated figure into the muscle view under the same unit as a real one.
     */
    data class Set(
        val weightKg: Double,
        val reps: Int,
        val holdSeconds: Int = 0,
        val minutes: Double = 0.0,
    ) {
        /** Kilograms of volume load. Zero for anything that was not weight × repetitions. */
        val volumeKg: Double get() = if (reps > 0) weightKg * reps else 0.0
    }

    /** One parsed session, before it is turned into the shared [LiftingImporter.Session]. */
    data class Workout(
        val title: String,
        val startTs: Long,
        val endTs: Long,
        val exercises: List<Exercise>,
    ) {
        val volumeLoadKg: Double get() = exercises.sumOf { ex -> ex.sets.sumOf { it.volumeKg } }
        val setCount: Int get() = exercises.sumOf { it.sets.size }
        val totalReps: Int get() = exercises.sumOf { ex -> ex.sets.sumOf { it.reps } }
        val topSetKg: Double? get() = exercises.flatMap { it.sets }.maxOfOrNull { it.weightKg }

        /**
         * Volume split by the muscles that moved it.
         *
         * Same rule as the shared importer: an exercise with two primary movers counts its FULL volume
         * toward each, so this sums to more than [volumeLoadKg] on a multi-mover day. It is a
         * per-muscle exposure figure, never a partition of the session.
         */
        fun muscleVolumeKg(): Map<MuscleGroup, Double> {
            val out = HashMap<MuscleGroup, Double>()
            exercises.forEach { ex ->
                val groups = MuscleAttribution.muscles(ex.name)
                if (groups.isEmpty()) return@forEach
                val volume = ex.sets.sumOf { it.volumeKg }
                if (volume <= 0.0) return@forEach
                groups.forEach { g -> out[g] = (out[g] ?: 0.0) + volume }
            }
            return out
        }
    }

    /** What a parse produced, including what it could not place. */
    data class Parsed(
        val workouts: List<Workout>,
        /** Exercise names the attribution table has no muscles for, so the wearer can see the gap. */
        val unattributed: kotlin.collections.Set<String>,
    )

    /**
     * Parse the whole export.
     *
     * Never throws on a malformed line: a log the wearer spent months filling in should import the
     * sessions it can read rather than fail on one of them. Lines that match nothing are skipped in
     * silence — the format has blank lines, a BOM and section spacing that carry no data.
     */
    fun parse(text: String, zone: ZoneId = ZoneId.systemDefault()): Parsed {
        val workouts = ArrayList<Workout>()
        val unattributed = LinkedHashSet<String>()

        var title: String? = null
        var start: Long = 0
        var end: Long = 0
        var exercises = ArrayList<Exercise>()
        var exerciseName: String? = null
        var sets = ArrayList<Set>()
        // Defaults to REPS: every grid in the file but two is weight × repetitions, and a row arriving
        // before any header at all is far likelier to be a stray than an isometric.
        var grid = Grid.REPS

        fun closeExercise() {
            val name = exerciseName ?: return
            exercises.add(Exercise(name, sets.toList()))
            if (MuscleAttribution.muscles(name).isEmpty()) unattributed.add(name)
            exerciseName = null
            sets = ArrayList()
        }

        fun closeWorkout() {
            closeExercise()
            val t = title ?: return
            if (exercises.isNotEmpty()) workouts.add(Workout(t, start, end, exercises.toList()))
            title = null
            exercises = ArrayList()
        }

        text.lineSequence().forEach { raw ->
            val line = raw.trim().removePrefix("﻿")
            if (line.isEmpty()) return@forEach

            SESSION.find(line)?.let { m ->
                closeWorkout()
                title = m.groupValues[1].trim()
                val begin = parseStart(m.groupValues[2], m.groupValues[3], zone)
                start = begin
                end = begin + durationMinutes(m.groupValues[4]) * 60L
                grid = Grid.REPS
                return@forEach
            }
            EXERCISE.find(line)?.let { m ->
                closeExercise()
                // The title carries equipment and a rep target after separators; only the name matters
                // for attribution, and keeping the rest would make every variant its own exercise.
                exerciseName = m.groupValues[1].substringBefore('·').trim()
                return@forEach
            }
            gridOf(line)?.let { grid = it; return@forEach }

            when (grid) {
                Grid.REPS -> SET.find(line)?.let { m ->
                    val weight = germanNumber(m.groupValues[2])
                    val reps = m.groupValues[3].trim().toIntOrNull()
                    // A dash in either column is a set that was printed and not done.
                    if (weight != null && reps != null && reps > 0) sets.add(Set(weight, reps))
                }
                // A loaded hold. The weight is real and the seconds are real; their PRODUCT is not a
                // mass, so it is kept out of volume rather than converted into one.
                Grid.SECONDS -> SET.find(line)?.let { m ->
                    val weight = germanNumber(m.groupValues[2])
                    val seconds = m.groupValues[3].trim().toIntOrNull()
                    if (weight != null && seconds != null && seconds > 0) {
                        sets.add(Set(weightKg = weight, reps = 0, holdSeconds = seconds))
                    }
                }
                Grid.MINUTES -> SET_2COL.find(line)?.let { m ->
                    germanNumber(m.groupValues[2])?.takeIf { it > 0.0 }?.let {
                        sets.add(Set(weightKg = 0.0, reps = 0, minutes = it))
                    }
                }
                // A grid this parser has never seen. Its rows are skipped rather than guessed at, and
                // the exercise is still recorded — "they did this, with no figure I can read" is true,
                // where reading its second column as reps would be a number I invented.
                Grid.UNKNOWN -> Unit
            }
        }
        closeWorkout()

        return Parsed(workouts.sortedBy { it.startTs }, unattributed)
    }

    /** `1.234,5` or `27,5` or `30` — comma decimal, optional thousands dot. A dash is not a number. */
    internal fun germanNumber(raw: String): Double? {
        val t = raw.trim()
        if (t.isEmpty() || t == "-" || t == "–") return null
        return t.replace(".", "").replace(',', '.').toDoubleOrNull()
    }

    /**
     * `53 Min.`, `1:19 Std.` or `45 s`, in whole minutes.
     *
     * Zero for a form this does not recognise, which makes the session a zero-length one rather than
     * dropping it: the exercises are the data, and a session with an unreadable duration still happened.
     */
    internal fun durationMinutes(raw: String): Long {
        val t = raw.trim()
        DURATION_HM.find(t)?.let { m ->
            return m.groupValues[1].toLong() * 60L + m.groupValues[2].toLong()
        }
        DURATION_MIN.find(t)?.let { return it.groupValues[1].toLong() }
        // Rounded DOWN to the minute, so a 45-second session is a zero-length one rather than being
        // rounded up into a minute it did not last.
        DURATION_SEC.find(t)?.let { return it.groupValues[1].toLong() / 60L }
        return 0L
    }

    /** `HH:mm` or `H:mm` — the exporter writes a single-digit hour before ten. */
    private fun parseStart(date: String, time: String, zone: ZoneId): Long =
        runCatching {
            LocalDateTime.parse(
                "$date ${time.padStart(5, '0')}",
                DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm", Locale.US),
            ).atZone(zone).toEpochSecond()
        }.getOrDefault(0L)

    /** Turn parsed workouts into the shared session shape the rest of the app already stores. */
    fun toSessions(parsed: Parsed): List<LiftingImporter.Session> =
        parsed.workouts.filter { it.startTs > 0 }.map { w ->
            LiftingImporter.Session(
                startTs = w.startTs,
                endTs = w.endTs,
                volumeLoadKg = w.volumeLoadKg,
                setCount = w.setCount,
                exerciseCount = w.exercises.size,
                totalReps = w.totalReps,
                topSetKg = w.topSetKg,
                title = w.title,
                muscleVolumeKg = w.muscleVolumeKg(),
            )
        }

    // MARK: - Import

    /**
     * Read the picked file, parse it, and store one workout per session plus the per-muscle volume.
     *
     * Never throws: every failure becomes a summary the wearer can read. Picking the wrong file is the
     * most likely thing to happen here, and "No sessions found — point at an Alphaprog CSV export" is a
     * more useful outcome than a crash.
     */
    suspend fun importExport(
        context: Context,
        uri: Uri,
        repo: WhoopRepository,
        deviceId: String = SOURCE_ID,
    ): ImportSummary {
        val text = try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                stream.readBytes().let { bytes ->
                    if (bytes.size > MAX_BYTES) {
                        return ImportSummary.failure(SOURCE_LABEL, "That file is too large to read.")
                    }
                    // UTF-8 with a BOM is what the exporter writes; the parser strips it per line too.
                    String(bytes, Charsets.UTF_8)
                }
            } ?: return ImportSummary.failure(SOURCE_LABEL, "Could not open the selected file.")
        } catch (e: Exception) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "Could not read the file: ${e.message ?: "unknown error"}",
            )
        }

        val parsed = parse(text)
        val sessions = toSessions(parsed)
        if (sessions.isEmpty()) {
            return ImportSummary.failure(
                SOURCE_LABEL,
                "No sessions found — point at an Alphaprog CSV export.",
            )
        }

        val rows = sessions.map { s ->
            WorkoutRow(
                deviceId = deviceId,
                startTs = s.startTs,
                endTs = s.endTs,
                sport = LiftingImporter.SPORT,
                source = SOURCE_ID,
                durationS = s.durationS,
                energyKcal = null,
                avgHr = null,
                maxHr = null,
                // Never a fabricated cardiovascular strain: this is a volume figure, and the workout
                // row carrying no strain is what keeps it out of Effort.
                strain = null,
                distanceM = null,
                zonesJSON = null,
                notes = s.volumeLoadNote(),
            )
        }

        repo.upsertDevice(deviceId, name = "Lifting log")
        repo.upsertWorkouts(rows)
        repo.upsertMetricSeries(LiftingImporter.muscleSeriesRows(sessions, deviceId))

        val days = sessions.map { dayOf(it.startTs) }.sorted()
        val volume = sessions.sumOf { it.volumeLoadKg }
        return ImportSummary(
            source = SOURCE_LABEL,
            counts = linkedMapOf("workouts" to rows.size),
            firstDay = days.firstOrNull(),
            lastDay = days.lastOrNull(),
            message = buildString {
                append("Imported ${rows.size} session")
                if (rows.size != 1) append("s")
                if (volume > 0) append(" (${volume.toLong()} kg total volume)")
                days.firstOrNull()?.let { first ->
                    days.lastOrNull()?.let { last -> if (first != last) append(" from $first to $last") }
                }
                append(".")
                // Said out loud rather than swallowed: an exercise the table cannot place contributes
                // no volume at all, and the body view simply stays dark for it. The wearer should know
                // which one, so it can be reported rather than silently lost.
                if (parsed.unattributed.isNotEmpty()) {
                    append(" Not attributed to a muscle: ")
                    append(parsed.unattributed.joinToString(", "))
                    append(".")
                }
            },
        )
    }

    private fun dayOf(ts: Long): String =
        // API-26-safe: LocalDate.ofInstant is an API 34 overload, and this app has no desugaring —
        // it threw NoSuchMethodError AFTER the import had already written every row, so the wearer saw
        // a failure over a completed import.
        Instant.ofEpochSecond(ts).atZone(ZoneId.systemDefault()).toLocalDate().toString()
}