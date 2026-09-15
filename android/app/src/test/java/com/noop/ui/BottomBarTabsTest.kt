package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bottom bar's tab set, and the one rule about it that nothing enforced (#2218).
 *
 * Promoting Coach to a tab was a four-part change, and the part that nearly shipped wrong was leaving
 * it in the More sheet as well, so one destination would have appeared in two places at once. That is
 * not a thing a reader spots: the two lists sit four hundred lines apart and neither mentions the
 * other. It is exactly a thing a test spots.
 *
 * Pure data, so this runs in the plain-JVM suite. There is no Compose-capable harness in this repo, so
 * nothing here can assert what the bar RENDERS; what it can assert is the rule the rendering depends on.
 */
class BottomBarTabsTest {

    private val barTabs = barLeadingTabs + barTrailingTabs

    /** The bar and the More sheet must be disjoint, which is the invariant the drawer's own note claims. */
    @Test
    fun noBarTabIsAlsoListedInTheMoreSheet() {
        val inDrawer = drawerGroups.flatMap { it.items }.toSet()
        val both = barTabs.map { it.dest }.filter { it in inDrawer }
        assertTrue("a bar tab must not also appear in the More sheet, found $both", both.isEmpty())
    }

    /**
     * The tab set, in slot order, with More appended by the bar itself.
     *
     * This DELIBERATELY no longer matches iOS. The bar follows the OpenStrap tab shape now — Today,
     * Health (the Trends route wearing the Health label), Mindfulness, Coach — and Sleep gave up its
     * slot, which is why it is now allowed in the More sheet that
     * [noBarTabIsAlsoListedInTheMoreSheet] guards. Nutrition briefly held a slot too and gave it
     * back: its water and macro tiles are Today sections now, reading real stores rather than
     * fronting a preview. The CLAUDE.md parity contract binds analytics and stored values, not tab
     * order; neither moved here.
     */
    @Test
    fun theBarCarriesTheNamedTabsInSlotOrder() {
        assertEquals(
            listOf(
                Destination.Today,
                Destination.Trends,
                Destination.Mindfulness,
                Destination.Coach,
            ),
            barTabs.map { it.dest },
        )
    }

    /** Sleep left the bar, so the Health tab and the More sheet are the two ways left to reach it. */
    @Test
    fun sleepIsStillReachableFromTheMoreSheet() {
        assertTrue(drawerGroups.flatMap { it.items }.contains(Destination.Sleep))
    }

    /** A destination cannot occupy two slots; the More slot's selected state derives from this list. */
    @Test
    fun theBarHasNoDuplicateDestinations() {
        assertEquals(barTabs.map { it.dest }.distinct().size, barTabs.size)
    }

    /** Every tab carries a label, so no slot can render an empty word or an empty a11y description. */
    @Test
    fun everyTabHasALabelResource() {
        assertTrue(barTabs.all { it.labelRes != 0 })
    }
}
