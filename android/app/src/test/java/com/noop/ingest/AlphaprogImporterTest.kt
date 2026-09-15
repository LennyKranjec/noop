package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * The Alphaprog export, read against the wearer's REAL file.
 *
 * The fixture is their actual log — 96 sessions across nine months. A
 * hand-written sample would have proved the parser reads what I imagined the format to be; this proves
 * it reads what the exporter writes, including the blank lines, the BOM, the German decimals and the
 * dashes for sets that were printed and never done.
 *
 * TWO OF THESE ARE THE IMPORTANT ONES, and both guard failures that look like data rather than like
 * bugs. The SESSION COUNT: a header form the regex missed did not fail, it appended that session's
 * exercises to the previous one, and a quarter-matched file produced one fabricated 190-exercise day.
 * The ATTRIBUTION COVERAGE: an exercise the table cannot place contributes nothing, silently, and the
 * body view simply stays dark for that muscle.
 */
class AlphaprogImporterTest {

    private val zone: ZoneId = ZoneId.of("Europe/Berlin")

    private fun fixture(): String =
        javaClass.classLoader!!.getResourceAsStream("alphaprog_workouts.csv")!!
            .bufferedReader(Charsets.UTF_8).readText()

    private fun parsed() = AlphaprogImporter.parse(fixture(), zone)

    @Test
    fun everySessionInTheFileIsFound() {
        // 96, NOT the 26 the first cut of the parser found. The duration column has three forms and the
        // clock has one or two digits; a regex that accepted only `HH:MM` + `N Min.` matched a quarter of
        // the headers, and the other seventy sessions' exercises were silently appended to whichever
        // session HAD matched — producing one 190-exercise day holding most of a year. The count is
        // asserted rather than the shape, because that failure had a plausible shape.
        assertEquals(96, parsed().workouts.size)
    }

    @Test
    fun allThreeDurationFormsAreRead() {
        assertEquals(53L, AlphaprogImporter.durationMinutes("53 Min."))
        assertEquals(79L, AlphaprogImporter.durationMinutes("1:19 Std."))
        assertEquals(127L, AlphaprogImporter.durationMinutes("2:07 Std."))
        // Rounded DOWN: a 45-second session did not last a minute.
        assertEquals(0L, AlphaprogImporter.durationMinutes("45 s"))
        assertEquals(0L, AlphaprogImporter.durationMinutes("something else"))
    }

    @Test
    fun aSessionThatStartedBeforeTenIsStillFound() {
        // "2026-09-02 5:18 Uhr" — one digit. Every session on this day starts before ten.
        val early = parsed().workouts.filter {
            java.time.Instant.ofEpochSecond(it.startTs).atZone(zone).hour < 10
        }
        assertTrue("single-digit clock hours must parse", early.size >= 10)
        assertTrue("and must carry a real timestamp", early.all { it.startTs > 0 })
    }

    @Test
    fun aLoadedHoldIsNotWeightTimesReps() {
        // `#;KG;SEK` is weight x SECONDS. Reading the second column as reps would turn a 45-second hold
        // into 1,350 kg of volume load: not a wrong magnitude, a different quantity in the same unit.
        //
        // WRITTEN BY HAND, not read off the fixture, because the wearer's own file has exactly one such
        // grid and every row in it is a dash — the format is there, a PERFORMED hold is not. A test that
        // waited for one would have passed today by asserting nothing.
        val text = listOf(
            "\"Lower A (Di)\";\"2026-07-19 19:01 Uhr\";\"2 Min.\"",
            "\"1. Wallsit · Körpergewicht\"",
            "#;KG;SEK",
            "1;30;45",
        ).joinToString("\n")
        val set = AlphaprogImporter.parse(text, zone).workouts.single().exercises.single().sets.single()
        assertEquals(45, set.holdSeconds)
        assertEquals(0, set.reps)
        assertEquals(0.0, set.volumeKg, 1e-9)
        assertEquals(30.0, set.weightKg, 1e-9)
    }

    @Test
    fun theFixturesOwnUnperformedHoldContributesNothing() {
        // The real `#;KG;SEK` grid is "1;-;-" three times: printed, never done.
        val wallsit = parsed().workouts.flatMap { it.exercises }.filter { it.name == "Wallsit" }
        assertTrue("the fixture carries the Wallsit", wallsit.isNotEmpty())
        assertTrue(wallsit.all { ex -> ex.sets.isEmpty() })
    }

    @Test
    fun aTimedEffortCarriesMinutesAndNoLoad() {
        val timed = parsed().workouts.flatMap { it.exercises }.flatMap { it.sets }
            .filter { it.minutes > 0.0 }
        assertTrue("the fixture carries at least one timed effort", timed.isNotEmpty())
        assertTrue(timed.all { it.volumeKg == 0.0 && it.weightKg == 0.0 })
    }

    @Test
    fun theSessionsAreOrderedOldestFirst() {
        val starts = parsed().workouts.map { it.startTs }
        assertEquals(starts.sorted(), starts)
    }

    @Test
    fun aSessionCarriesItsDurationFromTheHeader() {
        // "…;"2026-09-14 13:44 Uhr";"53 Min."" — the end is the start plus those minutes.
        val newest = parsed().workouts.last()
        assertEquals(53 * 60L, newest.endTs - newest.startTs)
    }

    @Test
    fun germanDecimalsAreRead() {
        assertEquals(27.5, AlphaprogImporter.germanNumber("27,5")!!, 1e-9)
        assertEquals(30.0, AlphaprogImporter.germanNumber("30")!!, 1e-9)
        assertEquals(1234.5, AlphaprogImporter.germanNumber("1.234,5")!!, 1e-9)
    }

    @Test
    fun anUnperformedSetIsNotAZero() {
        // "4;-;-" is a row the app printed and the wearer left empty. Counting it as 0 kg x 0 reps is
        // the same arithmetic and a different claim: it would say they did a set of nothing.
        assertNull(AlphaprogImporter.germanNumber("-"))
        // Every set that carries REPETITIONS carries at least one. A set with zero reps is a timed one
        // (a plank's minutes, a hold's seconds) and must carry that figure instead of being empty.
        val sets = parsed().workouts.flatMap { it.exercises }.flatMap { it.sets }
        assertTrue(
            "a set is either reps, or seconds, or minutes — never nothing at all",
            sets.all { it.reps > 0 || it.holdSeconds > 0 || it.minutes > 0.0 },
        )
    }

    @Test
    fun theFirstSessionMatchesTheFileByHand() {
        // Read off the top of the fixture: rows 30x10, 27.5x7, 27.5x7 with the fourth set left blank.
        val newest = parsed().workouts.last()
        val rows = newest.exercises.first()
        assertEquals("Rudern mit Brustauflage eng", rows.name)
        assertEquals(3, rows.sets.size)
        assertEquals(30.0 * 10 + 27.5 * 7 + 27.5 * 7, rows.sets.sumOf { it.volumeKg }, 1e-9)
    }

    @Test
    fun everyExerciseInTheFileIsEitherPlacedOrKnowinglyUnplaceable() {
        val p = parsed()
        val names = p.workouts.flatMap { it.exercises }.map { it.name }.toSet()
        // NOTHING in this file is allowed to go unplaced any more. Adductors used to be the one
        // deliberate blank; they are the medial thigh, which the hamstrings' own hip-extension group is
        // the honest home for, and leaving them blank lost thirty sessions of leg work off the figure.
        assertTrue(
            "these exercises attribute nothing and would silently lose their volume: ${p.unattributed}",
            p.unattributed.isEmpty(),
        )
        assertTrue("the fixture should carry the wearer's whole vocabulary", names.size >= 20)
    }

    @Test
    fun aReverseButterflyIsNotAChestExercise() {
        // "Butterfly Reverse" contains "butterfly". Order in the rule table is the only thing keeping
        // it off the pecs.
        assertEquals(
            listOf(MuscleGroup.UPPER_BACK, MuscleGroup.SHOULDERS),
            MuscleAttribution.muscles("Butterfly Reverse weit"),
        )
        assertEquals(listOf(MuscleGroup.CHEST), MuscleAttribution.muscles("Butterfly weit"))
    }

    @Test
    fun theTwoSidesOfTheHipAreDifferentMuscles() {
        // Abduction takes the leg away from the midline (glutes); adduction pulls it back (medial
        // thigh, whose magnus is a hip extensor and belongs with the hamstrings). Filing both on the
        // same group would say the two machines train the same thing, which is the opposite of true.
        assertEquals(listOf(MuscleGroup.HAMSTRINGS), MuscleAttribution.muscles("Adduktoren"))
        assertEquals(listOf(MuscleGroup.GLUTES), MuscleAttribution.muscles("Abduktoren"))
        assertEquals(listOf(MuscleGroup.HAMSTRINGS), MuscleAttribution.muscles("Hip Adduction (Machine)"))
        assertEquals(listOf(MuscleGroup.GLUTES), MuscleAttribution.muscles("Hip Abduction (Machine)"))
        // And neither is the quadriceps, which take no part in either movement.
        assertTrue(
            MuscleGroup.QUADRICEPS !in MuscleAttribution.muscles("Adduktoren") &&
                MuscleGroup.QUADRICEPS !in MuscleAttribution.muscles("Abduktoren"),
        )
    }

    @Test
    fun calfRaisesOnTheLegPressAreCalvesNotQuadriceps() {
        // "Wadenheben an der Beinpresse" contains "beinpresse".
        assertEquals(
            listOf(MuscleGroup.CALVES),
            MuscleAttribution.muscles("Wadenheben an der Beinpresse"),
        )
    }

    @Test
    fun umlautsSurviveNormalisationSoTheRulesMustCarryThem() {
        // `normalise` keeps letters as they are, so an ASCII-only rule never matches the word the
        // exporter actually writes.
        assertEquals(listOf(MuscleGroup.TRICEPS), MuscleAttribution.muscles("Trizepsdrücken mit dem Seil"))
        assertEquals(listOf(MuscleGroup.LOWER_BACK), MuscleAttribution.muscles("Rückenstrecken"))
    }

    @Test
    fun volumeIsSplitAcrossEveryMoverWithoutBeingDivided() {
        // A row moves lats AND upper back; each gets the FULL set volume, because nothing in a set of
        // rows says the lats took half. The per-muscle total therefore EXCEEDS the session's own.
        val session = parsed().workouts.last()
        val perMuscle = session.muscleVolumeKg().values.sum()
        assertTrue(perMuscle > session.volumeLoadKg)
    }

    @Test
    fun theWholeFileConvertsToStorableSessions() {
        val sessions = AlphaprogImporter.toSessions(parsed())
        assertEquals(96, sessions.size)
        assertTrue(sessions.all { it.startTs > 0 })
        assertTrue(sessions.all { it.volumeLoadKg >= 0 })
        assertTrue("at least one session must attribute muscle volume",
            sessions.any { it.muscleVolumeKg.isNotEmpty() })
    }

    @Test
    fun aMalformedFileYieldsNothingRatherThanThrowing() {
        // A log somebody spent months filling in should import what it can, not fail on one bad line.
        assertTrue(AlphaprogImporter.parse("", zone).workouts.isEmpty())
        assertTrue(AlphaprogImporter.parse("garbage;;;\n\n;;", zone).workouts.isEmpty())
    }
}
