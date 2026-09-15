package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Where the level timeline's labelled gridlines sit.
 *
 * THE FAILURE THIS GUARDS IS A CONFIDENT LIE. A rule drawn at its own idea of the plot's height sits a
 * few pixels off and mislabels the very line it exists to explain — the picture looks right, the reader
 * takes a number off it, and nothing anywhere contradicts them. The rules therefore go through the SAME
 * [yForValue] helper, with the SAME inset, as the series itself; this pins that they agree.
 */
class LevelAxisGridTest {

    /** The level's fixed domain, as the sheet passes it. */
    private val domain = 0.0..100.0

    /** Two points is the minimum the chart will plot, and what the axis probes the scale with. */
    private val probe = listOf(0.0, 100.0)

    private fun y(value: Double, height: Float = 400f): Float? = yForValue(
        value = value,
        values = probe,
        height = height,
        topPad = LINE_CHART_V_PAD,
        bottomPad = LINE_CHART_V_PAD,
        yDomain = domain,
    )

    @Test
    fun theEndsOfTheAxisSitOnTheChartsOwnInsetNotOnItsEdges() {
        // The plot is inset by the stroke width so a 2.5px line is not clipped in half at the boundary.
        // A rule drawn at y = 0 and y = height would be OUTSIDE the series' own range and would label
        // the wrong place by exactly that inset.
        assertEquals(LINE_CHART_V_PAD, y(100.0)!!, 1e-4f)
        assertEquals(400f - LINE_CHART_V_PAD, y(0.0)!!, 1e-4f)
    }

    @Test
    fun theMidpointIsHalfwayBetweenThem() {
        val top = y(100.0)!!
        val bottom = y(0.0)!!
        assertEquals((top + bottom) / 2f, y(50.0)!!, 1e-4f)
    }

    @Test
    fun theQuartersAreEvenlySpaced() {
        // Uneven spacing would mean the axis is not linear, and every reading taken off it between the
        // labels would be wrong by a different amount.
        val ys = listOf(0, 25, 50, 75, 100).map { y(it.toDouble())!! }
        val gaps = ys.zipWithNext { a, b -> a - b }
        gaps.forEach { assertEquals(gaps.first(), it, 1e-3f) }
        assertTrue("the axis must run upward: 100 above 0", ys.last() < ys.first())
    }

    @Test
    fun aHigherLevelIsDrawnHigherUpTheChart() {
        // Screen y grows downward, so a bigger level must produce a SMALLER y. Getting this backwards
        // draws a perfectly plausible upside-down chart.
        assertTrue(y(80.0)!! < y(20.0)!!)
    }

    @Test
    fun everyTickTheSheetDrawsIsInsideTheDomain() {
        // A tick outside the domain returns null and silently draws nothing — an axis with a missing
        // label reads as a rendering glitch rather than as a deliberate omission.
        listOf(0, 25, 50, 75, 100).forEach { assertNotNull("tick $it", y(it.toDouble())) }
    }

    @Test
    fun aValueOffTheScaleIsRefusedRatherThanClamped() {
        // The helper's own rule, and the axis inherits it: a rule pinned to the top edge would claim the
        // chart's ceiling is a value the chart does not actually reach.
        assertNull(y(140.0))
        assertNull(y(-1.0))
    }

    @Test
    fun theInsetIsTheOneTheChartActuallyUses() {
        // Shared constants, not two copies: the whole point is that the axis cannot drift from the line.
        assertEquals(2.5f, LINE_CHART_STROKE_PX, 1e-6f)
        assertEquals(LINE_CHART_STROKE_PX + 4f, LINE_CHART_V_PAD, 1e-6f)
    }
}
