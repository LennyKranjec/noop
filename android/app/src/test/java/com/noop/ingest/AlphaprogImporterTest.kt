package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * The Alphaprog export, read against the wearer's REAL file.
 *
 * The fixture is their actual log — 26 sessions, 23 distinct exercises, a year of training. A
 * hand-written sample would have proved the parser reads what I imagined the format to be; this proves
 * it reads what the exporter writes, including the blank lines, the BOM, the German decimals and the
 * dashes for sets that were printed and never done.
 *
 * THE ATTRIBUTION COVERAGE TEST IS THE IMPORTANT ONE. An exercise the table cannot place contributes
 * nothing, silently — the body view simply stays dark for that muscle. Asserting that every exercise in
 * the file is either placed or deliberately listed as unplaceable is what stops a future rename from
 * quietly halving somebody's training volume.
 */
class AlphaprogImporterTest {

    private val zone: ZoneId = ZoneId.of("Europe/Berlin")

    private fun fixture(): String =
        javaClass.classLoader!!.getResourceAsStream("alphaprog_workouts.csv")!!
            .bufferedReader(Charsets.UTF_8).readText()

    private fun parsed() = AlphaprogImporter.parse(fixture(), zone)

    @Test
    fun everySessionInTheFileIsFound() {
        assertEquals(26, parsed().workouts.size)
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
        val sets = parsed().workouts.flatMap { it.exercises }.flatMap { it.sets }
        assertTrue("no set may have zero reps", sets.none { it.reps <= 0 })
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
        // Adductors are the one deliberate blank: the thirteen groups have no adductor, and the medial
        // thigh is not the quadriceps. Anything ELSE unplaced is a gap in the table.
        val unexpected = p.unattributed.filterNot { it.contains("Adduktoren", ignoreCase = true) }
        assertTrue(
            "these exercises attribute nothing and would silently lose their volume: $unexpected",
            unexpected.isEmpty(),
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
        assertEquals(26, sessions.size)
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
