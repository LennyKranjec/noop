package com.noop.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.draw.shadow
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.analytics.LevelBreakdown
import com.noop.analytics.LevelPart
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

// MARK: - The level, drawn as its own five parts
//
// A pentagon, one vertex per weighted part, each pulled out from the centre by that part's score. The
// level itself sits in the middle, because the number IS the area: a shape that leans to one side is a
// body that is carrying one thing and neglecting another, and that is readable at a glance in a way a
// single figure never is.
//
// THE AXES ARE NOT WEIGHTED. Each vertex runs 0–100 on the part's own score, so the shape says where
// the wearer stands on each; the WEIGHTS are what turn those into the number in the middle. Scaling the
// axes by weight too would have drawn lungs as permanently stunted at 0.07 and read as a deficiency
// rather than as a small term.
//
// A PART WITH NO DATA IS DRAWN AT THE CENTRE AND ITS GLYPH IS DIMMED. Not at some middle default: an
// unmeasured part is a hole in the shape, and filling it in would draw a body we did not measure.

/** One pentagon, the level in its middle. */
@Composable
internal fun LevelRadar(
    breakdown: LevelBreakdown?,
    diameter: Dp,
    /** Runs the count-up from zero when it changes. The shell flips it once per app open. */
    countUpKey: Any?,
    modifier: Modifier = Modifier,
) {
    val level = breakdown?.level
    val gridColor = Palette.textTertiary.copy(alpha = 0.30f)
    val webColor = Palette.accent.copy(alpha = 0.16f)
    val webEdge = Palette.accent.copy(alpha = 0.75f)

    // The shape grows in as the number counts up, so the two read as one gesture rather than a static
    // pentagon with a spinning number inside it.
    val reveal by animateFloatAsState(
        targetValue = if (level == null) 0f else 1f,
        animationSpec = tween(durationMillis = SLOT_MILLIS, easing = LinearEasing),
        label = "levelRadarReveal",
    )

    // `requiredSize`, not `size`, all the way down: this is drawn deliberately larger than the bar that
    // holds it, and a clamped size measured the whole thing at the bar's height and drew nothing.
    //
    // THE PLATE IS A PENTAGON, not a circle or a card. It echoes the shape it carries, so the thing
    // reads as one object rather than as a chart sitting on a coaster — and its own five corners point
    // at the same five parts the axes do. The shadow is what separates it from the screen below, which
    // it now genuinely hangs over: without one, the lower third looked like a hole cut in the content.
    Box(
        modifier = modifier
            .requiredSize(diameter)
            .shadow(PLATE_ELEVATION, PentagonShape, clip = false)
            .background(Palette.surfaceRaised, PentagonShape),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.requiredSize(diameter)) {
            val cx = size.width / 2f
            val cy = size.height / 2f
            // Room for the glyphs, which sit just outside the outer ring.
            val radius = minOf(cx, cy) * 0.66f

            // Two rings, at a half and at full. More would be graph paper at this size; none at all
            // would leave the shape floating with nothing to be big or small against.
            listOf(0.5f, 1f).forEach { ring ->
                drawPath(
                    path = pentagon(cx, cy, radius * ring),
                    color = gridColor,
                    style = Stroke(width = 1f),
                )
            }
            // The spokes, so a vertex reads as a measured axis rather than a corner of a blob.
            for (i in 0 until PARTS.size) {
                val (x, y) = vertex(cx, cy, radius, i)
                drawLine(gridColor, Offset(cx, cy), Offset(x, y), strokeWidth = 1f)
            }

            val scores = PARTS.map { part ->
                breakdown?.components?.firstOrNull { it.part == part }?.score
            }
            if (scores.any { it != null }) {
                val web = Path()
                PARTS.indices.forEach { i ->
                    val frac = ((scores[i] ?: 0.0) / 100.0).toFloat() * reveal
                    val (x, y) = vertex(cx, cy, radius * frac.coerceIn(0f, 1f), i)
                    if (i == 0) web.moveTo(x, y) else web.lineTo(x, y)
                }
                web.close()
                drawPath(web, color = webColor)
                drawPath(web, color = webEdge, style = Stroke(width = 1.5f))
            }
        }

        // The glyphs, one per axis, laid out on the same geometry the canvas used.
        PARTS.forEachIndexed { i, part ->
            val measured = breakdown?.components?.firstOrNull { it.part == part }?.score != null
            Box(
                modifier = Modifier
                    .requiredSize(diameter)
                    .radarVertex(i, GLYPH_RADIUS_FRACTION),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    partIcon(part),
                    contentDescription = null,
                    tint = partTint(part).copy(alpha = if (measured) 0.95f else 0.30f),
                    modifier = Modifier.size(Metrics.iconTiny),
                )
            }
        }

        SlotLevelNumber(level = level, countUpKey = countUpKey)
    }
}

/**
 * The figure, counting up from zero on every open.
 *
 * A slot machine, as asked for, and it earns its place: the level moves by a point or two a day, so a
 * number that simply appears looks the same whether it changed or not. Spinning up to it makes the
 * wearer READ it every time instead of glancing past it.
 *
 * It counts to the REAL value and stops there — the intermediate figures are a wipe, not a claim, which
 * is why they run fast enough to blur and the landing is what holds.
 */
@Composable
private fun SlotLevelNumber(level: Double?, countUpKey: Any?) {
    val target = level?.roundToInt()
    var shown by remember { mutableIntStateOf(0) }

    LaunchedEffect(target, countUpKey) {
        if (target == null) {
            shown = 0
            return@LaunchedEffect
        }
        val steps = SLOT_STEPS.coerceAtMost(maxOf(target, 1) * 4)
        val frame = (SLOT_MILLIS / steps).toLong().coerceAtLeast(8L)
        for (i in 1..steps) {
            // Eased so it sprints through the middle and creeps onto the last few points, which is what
            // makes it read as landing rather than as stopping.
            val t = i.toFloat() / steps
            shown = (target * (1f - (1f - t) * (1f - t))).roundToInt()
            delay(frame)
        }
        shown = target
    }

    Text(
        text = if (target == null) "–" else shown.toString(),
        // TABULAR FIGURES, which is not decoration here. Proportional digits are different widths — a 1
        // is narrow, a 4 is wide — so a number counting 0…80 through every digit in between jitters
        // sideways the whole way up and lands somewhere other than where it started. `tnum` gives every
        // digit the same advance, so the count-up rises in place. The design system already asks for it
        // on every other number style (see NoopType.bodyNumber / captionNumber); this one had missed it.
        style = NoopType.title1.copy(
            fontFamily = NoopType.display1,
            fontFeatureSettings = "tnum",
        ),
        color = if (target == null) Palette.textTertiary else Palette.textPrimary,
        fontWeight = FontWeight.Black,
        fontSize = LEVEL_FONT_SIZE,
        letterSpacing = (-0.5).sp,
    )
}

/** The five axes, in the order they are drawn: clockwise from the top. */
private val PARTS = listOf(
    LevelPart.SLEEP,
    LevelPart.HEART,
    LevelPart.LUNGS,
    LevelPart.MUSCLE,
    LevelPart.FOCUS,
)

/** How long the count-up and the web reveal take. Long enough to read, short enough not to wait on. */
private const val SLOT_MILLIS = 900

/** Frames in the count-up. Enough to blur, few enough not to burn a frame per point on a level of 90. */
private const val SLOT_STEPS = 34

/** Where the glyphs sit, as a fraction of the box — just outside the outer ring. */
private const val GLYPH_RADIUS_FRACTION = 0.37f

/** The level's own size. Deliberately the largest thing in the header. */
private val LEVEL_FONT_SIZE = 30.sp

private fun pentagon(cx: Float, cy: Float, radius: Float): Path {
    val p = Path()
    for (i in PARTS.indices) {
        val (x, y) = vertex(cx, cy, radius, i)
        if (i == 0) p.moveTo(x, y) else p.lineTo(x, y)
    }
    p.close()
    return p
}

/**
 * The plate behind the radar — the same pentagon, at the size of the whole box.
 *
 * Built from the SAME [vertex] maths the axes use, so the plate's corners and the chart's corners point
 * the same way. Two independent pentagons would drift apart the first time either was adjusted, and a
 * plate rotated a few degrees off the shape it carries looks like a mistake nobody can name.
 */
internal val PentagonShape: Shape = object : Shape {
    override fun createOutline(
        size: Size,
        layoutDirection: LayoutDirection,
        density: Density,
    ): Outline {
        val cx = size.width / 2f
        val cy = size.height / 2f
        return Outline.Generic(pentagon(cx, cy, minOf(cx, cy)))
    }
}

/** How far the plate lifts off the screen behind it. Enough to read as floating, not as a card. */
private val PLATE_ELEVATION = 10.dp

/** Vertex [i] of five, starting at the top and going clockwise. */
private fun vertex(cx: Float, cy: Float, radius: Float, i: Int): Pair<Float, Float> {
    val angle = -PI / 2.0 + 2.0 * PI * i / PARTS.size
    return (cx + radius * cos(angle)).toFloat() to (cy + radius * sin(angle)).toFloat()
}

/** Places a composable on vertex [i], as a fraction of the parent box's smaller side. */
private fun Modifier.radarVertex(i: Int, radiusFraction: Float): Modifier = layout { measurable, c ->
    val placeable = measurable.measure(c.copy(minWidth = 0, minHeight = 0))
    layout(c.maxWidth, c.maxHeight) {
        val cx = c.maxWidth / 2f
        val cy = c.maxHeight / 2f
        val r = minOf(cx, cy) * 2f * radiusFraction
        val angle = -PI / 2.0 + 2.0 * PI * i / PARTS.size
        placeable.place(
            (cx + r * cos(angle) - placeable.width / 2f).roundToInt(),
            (cy + r * sin(angle) - placeable.height / 2f).roundToInt(),
        )
    }
}

/** Shared with the bar so the web, the glyphs and the strip agree on one accent. */
internal val LevelRadarWebColor: Color get() = Palette.accent
