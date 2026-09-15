package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ingest.LiftingImporter
import com.noop.ingest.MuscleGroup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale

// MARK: - Muscle model — where the lifting volume went, by muscle group
//
// WHAT IT READS. The lifting importer attributes every counted set's volume load (weight × reps) to
// the muscles that moved it and banks a daily per-muscle total under `muscle_volume_<group>` on the
// "lifting" source. This card sums that over a trailing window. NOTHING here derives a number from
// heart rate: a strap cannot see which muscle did the work, so with no lifting log imported the
// whole body sits unlit and the card says so rather than shading it from strain.
//
// WHAT THE COLOUR MEANS. Each group is shaded by its share of the HEAVIEST-loaded group in the same
// window, so the body reads as "where the work went, relative to itself". It is deliberately NOT an
// absolute scale: there is no per-muscle norm in this app to be "100 %" of, and inventing one would
// dress a ranking up as a recommendation. The kg figure beside each group is the real quantity; the
// colour is only the ranking made visible.
//
// A MUSCLE WITH TWO MOVERS IS COUNTED IN BOTH (see LiftingImporter.Session.muscleVolumeKg), so the
// column does not sum to the session's volume load and must never be presented as a split of it.

/** How far back the card totals. A week is the usual training cycle and the Trends tab's own unit. */
private const val WINDOW_DAYS = 7L

/** The body view being shown. The back carries the muscles the front cannot (lats, glutes, hams). */
private enum class BodySide { Front, Back }

@Composable
internal fun MuscleModelCard(viewModel: AppViewModel) {
    var side by remember { mutableStateOf(BodySide.Front) }
    var loads by remember { mutableStateOf<Map<MuscleGroup, Double>?>(null) }

    LaunchedEffect(viewModel.activeStrapId) {
        loads = withContext(Dispatchers.IO) { runCatching { readMuscleLoads(viewModel) }.getOrNull() }
    }

    val data = loads
    val peak = data?.values?.maxOrNull() ?: 0.0

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        uiString(R.string.muscle_model_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                    Text(
                        uiString(R.string.muscle_model_subtitle),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                SegmentedPillControl(
                    items = BodySide.entries.toList(),
                    selection = side,
                    label = {
                        when (it) {
                            BodySide.Front -> uiString(R.string.muscle_model_front)
                            BodySide.Back -> uiString(R.string.muscle_model_back)
                        }
                    },
                    onSelect = { side = it },
                )
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .aspectRatio(0.46f),
                    contentAlignment = Alignment.Center,
                ) {
                    BodyCanvas(side = side, loads = data.orEmpty(), peak = peak)
                }
                Spacer(Modifier.width(Metrics.space12))
                Column(
                    modifier = Modifier.weight(1.1f),
                    verticalArrangement = Arrangement.spacedBy(Metrics.space4),
                ) {
                    val groups = regionsFor(side).map { it.group }.distinct()
                    groups.forEach { group ->
                        MuscleLegendRow(group = group, kg = data?.get(group), peak = peak)
                    }
                }
            }

            if (data != null && data.isEmpty()) {
                Text(
                    uiString(R.string.muscle_model_no_lifting),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

@Composable
private fun MuscleLegendRow(group: MuscleGroup, kg: Double?, peak: Double) {
    // Resolved here, not inside the draw scope: `loadColorFor` reads the palette and is composable.
    val dot = loadColorFor(kg, peak, litAlpha = 1f, unlitAlpha = 0.35f)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .padding(end = Metrics.space8)
                .width(Metrics.space8),
        ) {
            Canvas(modifier = Modifier.fillMaxWidth().aspectRatio(1f)) {
                drawCircle(color = dot)
            }
        }
        Text(
            muscleLabel(group),
            style = NoopType.footnote,
            color = Palette.textSecondary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
        )
        Text(
            kg?.let { "${String.format(Locale.US, "%,d", Math.round(it))} kg" } ?: "–",
            style = NoopType.captionNumber,
            color = if (kg == null) Palette.textTertiary else Palette.textPrimary,
        )
    }
}

@Composable
private fun muscleLabel(group: MuscleGroup): String = uiString(
    when (group) {
        MuscleGroup.CHEST -> R.string.muscle_chest
        MuscleGroup.UPPER_BACK -> R.string.muscle_upper_back
        MuscleGroup.LATS -> R.string.muscle_lats
        MuscleGroup.SHOULDERS -> R.string.muscle_shoulders
        MuscleGroup.BICEPS -> R.string.muscle_biceps
        MuscleGroup.TRICEPS -> R.string.muscle_triceps
        MuscleGroup.FOREARMS -> R.string.muscle_forearms
        MuscleGroup.ABS -> R.string.muscle_abs
        MuscleGroup.LOWER_BACK -> R.string.muscle_lower_back
        MuscleGroup.GLUTES -> R.string.muscle_glutes
        MuscleGroup.QUADRICEPS -> R.string.muscle_quadriceps
        MuscleGroup.HAMSTRINGS -> R.string.muscle_hamstrings
        MuscleGroup.CALVES -> R.string.muscle_calves
    },
)

/** Shade for a group's load as a share of the window's heaviest group. Null load = unlit. */
@Composable
private fun loadColorFor(kg: Double?, peak: Double, litAlpha: Float, unlitAlpha: Float): Color {
    if (kg == null || kg <= 0 || peak <= 0) {
        return Palette.textTertiary.copy(alpha = unlitAlpha)
    }
    return Palette.sample(Palette.strainStops, (kg / peak).toFloat()).copy(alpha = litAlpha)
}

// MARK: - The body

/**
 * One muscle patch, as a TAPERED shape rather than a rectangle.
 *
 * Every real muscle is wider at one end than the other, and that single fact is most of what makes a
 * body read as a body: a pec narrows toward the sternum, a quad swells above the knee and pinches at
 * it, a calf is an egg. The old version was rounded rectangles of uniform width, which is why it
 * looked like a robot — anatomically it said nothing except "there is something here".
 *
 * Coordinates are NORMALISED (0–1, x right, y down) so one geometry scales to any card width.
 * [topW]/[bottomW] are the widths at the two ends, [tilt] shifts the bottom sideways so limbs can
 * splay, and [round] is how much the corners are pulled in. Still stylised: the attribution table
 * knows 13 coarse groups, and a lifelike figure would promise a precision it does not have.
 */
private data class MuscleShape(
    val group: MuscleGroup,
    val cx: Float,
    val cy: Float,
    val topW: Float,
    val bottomW: Float,
    val h: Float,
    val tilt: Float = 0f,
    val round: Float = 0.35f,
)

private fun regionsFor(side: BodySide): List<MuscleShape> = when (side) {
    BodySide.Front -> listOf(
        // Deltoids: round caps sitting proud of the torso, wider at the top than where they meet the arm.
        MuscleShape(MuscleGroup.SHOULDERS, 0.250f, 0.200f, 0.150f, 0.105f, 0.080f, tilt = -0.012f, round = 0.6f),
        MuscleShape(MuscleGroup.SHOULDERS, 0.750f, 0.200f, 0.150f, 0.105f, 0.080f, tilt = 0.012f, round = 0.6f),
        // Pectorals: broad at the shoulder, narrowing toward the sternum.
        MuscleShape(MuscleGroup.CHEST, 0.412f, 0.238f, 0.175f, 0.130f, 0.085f, tilt = 0.010f, round = 0.45f),
        MuscleShape(MuscleGroup.CHEST, 0.588f, 0.238f, 0.175f, 0.130f, 0.085f, tilt = -0.010f, round = 0.45f),
        // Biceps: the classic belly — thin at the shoulder, full mid-arm, thin at the elbow.
        MuscleShape(MuscleGroup.BICEPS, 0.196f, 0.312f, 0.088f, 0.070f, 0.105f, tilt = -0.020f, round = 0.65f),
        MuscleShape(MuscleGroup.BICEPS, 0.804f, 0.312f, 0.088f, 0.070f, 0.105f, tilt = 0.020f, round = 0.65f),
        // Abdomen: the V — ribcage down to a narrow waist.
        MuscleShape(MuscleGroup.ABS, 0.500f, 0.350f, 0.200f, 0.150f, 0.150f, round = 0.30f),
        // Forearms: taper hard into the wrist.
        MuscleShape(MuscleGroup.FOREARMS, 0.160f, 0.428f, 0.080f, 0.048f, 0.115f, tilt = -0.022f, round = 0.6f),
        MuscleShape(MuscleGroup.FOREARMS, 0.840f, 0.428f, 0.080f, 0.048f, 0.115f, tilt = 0.022f, round = 0.6f),
        // Quadriceps: heavy at the hip, pinched at the knee.
        MuscleShape(MuscleGroup.QUADRICEPS, 0.418f, 0.610f, 0.165f, 0.105f, 0.205f, tilt = 0.012f, round = 0.40f),
        MuscleShape(MuscleGroup.QUADRICEPS, 0.582f, 0.610f, 0.165f, 0.105f, 0.205f, tilt = -0.012f, round = 0.40f),
        // Calves: an egg above a thin ankle.
        MuscleShape(MuscleGroup.CALVES, 0.432f, 0.830f, 0.110f, 0.058f, 0.145f, tilt = 0.006f, round = 0.62f),
        MuscleShape(MuscleGroup.CALVES, 0.568f, 0.830f, 0.110f, 0.058f, 0.145f, tilt = -0.006f, round = 0.62f),
    )
    BodySide.Back -> listOf(
        MuscleShape(MuscleGroup.SHOULDERS, 0.250f, 0.200f, 0.150f, 0.105f, 0.080f, tilt = -0.012f, round = 0.6f),
        MuscleShape(MuscleGroup.SHOULDERS, 0.750f, 0.200f, 0.150f, 0.105f, 0.080f, tilt = 0.012f, round = 0.6f),
        // Traps: a wedge from the neck out to the shoulders, so it is wider at the BOTTOM.
        MuscleShape(MuscleGroup.UPPER_BACK, 0.500f, 0.212f, 0.140f, 0.300f, 0.090f, round = 0.30f),
        // Lats: the taper that makes a back a V — wide under the arm, narrow at the waist.
        MuscleShape(MuscleGroup.LATS, 0.404f, 0.320f, 0.170f, 0.085f, 0.135f, tilt = 0.028f, round = 0.35f),
        MuscleShape(MuscleGroup.LATS, 0.596f, 0.320f, 0.170f, 0.085f, 0.135f, tilt = -0.028f, round = 0.35f),
        MuscleShape(MuscleGroup.TRICEPS, 0.196f, 0.312f, 0.090f, 0.068f, 0.108f, tilt = -0.020f, round = 0.65f),
        MuscleShape(MuscleGroup.TRICEPS, 0.804f, 0.312f, 0.090f, 0.068f, 0.108f, tilt = 0.020f, round = 0.65f),
        MuscleShape(MuscleGroup.LOWER_BACK, 0.500f, 0.425f, 0.150f, 0.185f, 0.085f, round = 0.30f),
        MuscleShape(MuscleGroup.FOREARMS, 0.160f, 0.428f, 0.080f, 0.048f, 0.115f, tilt = -0.022f, round = 0.6f),
        MuscleShape(MuscleGroup.FOREARMS, 0.840f, 0.428f, 0.080f, 0.048f, 0.115f, tilt = 0.022f, round = 0.6f),
        // Glutes: round, and the widest point of the back view.
        MuscleShape(MuscleGroup.GLUTES, 0.434f, 0.520f, 0.150f, 0.140f, 0.105f, round = 0.7f),
        MuscleShape(MuscleGroup.GLUTES, 0.566f, 0.520f, 0.150f, 0.140f, 0.105f, round = 0.7f),
        // Hamstrings: full under the glute, tapering to the back of the knee.
        MuscleShape(MuscleGroup.HAMSTRINGS, 0.420f, 0.650f, 0.155f, 0.100f, 0.180f, tilt = 0.010f, round = 0.45f),
        MuscleShape(MuscleGroup.HAMSTRINGS, 0.580f, 0.650f, 0.155f, 0.100f, 0.180f, tilt = -0.010f, round = 0.45f),
        MuscleShape(MuscleGroup.CALVES, 0.432f, 0.830f, 0.110f, 0.058f, 0.145f, tilt = 0.006f, round = 0.62f),
        MuscleShape(MuscleGroup.CALVES, 0.568f, 0.830f, 0.110f, 0.058f, 0.145f, tilt = -0.006f, round = 0.62f),
    )
}

/**
 * The figure the patches sit on: head, neck, a V-tapered torso, tapering limbs.
 *
 * Drawn as the same tapered primitive, so the silhouette and the muscles agree about where the body
 * narrows. The ABS group on each row is a placeholder — the silhouette is never tinted by load, it
 * is only ever the faint body underneath.
 */
private val silhouette: List<MuscleShape> = listOf(
    MuscleShape(MuscleGroup.ABS, 0.500f, 0.058f, 0.115f, 0.100f, 0.085f, round = 0.85f),  // head
    MuscleShape(MuscleGroup.ABS, 0.500f, 0.128f, 0.070f, 0.090f, 0.055f, round = 0.3f),   // neck
    MuscleShape(MuscleGroup.ABS, 0.500f, 0.235f, 0.330f, 0.300f, 0.105f, round = 0.35f),  // chest shelf
    MuscleShape(MuscleGroup.ABS, 0.500f, 0.360f, 0.300f, 0.225f, 0.160f, round = 0.35f),  // waist taper
    MuscleShape(MuscleGroup.ABS, 0.500f, 0.485f, 0.235f, 0.300f, 0.110f, round = 0.35f),  // hips flare
    MuscleShape(MuscleGroup.ABS, 0.196f, 0.312f, 0.100f, 0.082f, 0.115f, tilt = -0.022f, round = 0.6f),  // upper arms
    MuscleShape(MuscleGroup.ABS, 0.804f, 0.312f, 0.100f, 0.082f, 0.115f, tilt = 0.022f, round = 0.6f),
    MuscleShape(MuscleGroup.ABS, 0.158f, 0.430f, 0.090f, 0.055f, 0.125f, tilt = -0.024f, round = 0.6f),  // forearms
    MuscleShape(MuscleGroup.ABS, 0.842f, 0.430f, 0.090f, 0.055f, 0.125f, tilt = 0.024f, round = 0.6f),
    MuscleShape(MuscleGroup.ABS, 0.132f, 0.505f, 0.058f, 0.050f, 0.050f, round = 0.8f),   // hands
    MuscleShape(MuscleGroup.ABS, 0.868f, 0.505f, 0.058f, 0.050f, 0.050f, round = 0.8f),
    MuscleShape(MuscleGroup.ABS, 0.418f, 0.610f, 0.180f, 0.115f, 0.215f, tilt = 0.012f, round = 0.4f),   // thighs
    MuscleShape(MuscleGroup.ABS, 0.582f, 0.610f, 0.180f, 0.115f, 0.215f, tilt = -0.012f, round = 0.4f),
    MuscleShape(MuscleGroup.ABS, 0.432f, 0.830f, 0.120f, 0.062f, 0.160f, tilt = 0.006f, round = 0.6f),   // lower legs
    MuscleShape(MuscleGroup.ABS, 0.568f, 0.830f, 0.120f, 0.062f, 0.160f, tilt = -0.006f, round = 0.6f),
    MuscleShape(MuscleGroup.ABS, 0.425f, 0.930f, 0.070f, 0.085f, 0.040f, round = 0.5f),   // feet
    MuscleShape(MuscleGroup.ABS, 0.575f, 0.930f, 0.070f, 0.085f, 0.040f, round = 0.5f),
)

@Composable
private fun BodyCanvas(side: BodySide, loads: Map<MuscleGroup, Double>, peak: Double) {
    val bodyFill = Palette.textSecondary.copy(alpha = 0.16f)
    val bodyEdge = Palette.textSecondary.copy(alpha = 0.30f)
    val regions = regionsFor(side)
    // Resolved OUTSIDE the draw scope: `loadColorFor` is composable (it reads the palette), and a
    // DrawScope cannot call one.
    val fills = regions.map { loadColorFor(loads[it.group], peak, litAlpha = 0.85f, unlitAlpha = 0.16f) }
    // The glow a heavily-loaded group gets. Same hue, no alpha, drawn wide and soft underneath — which
    // is what stops the hottest muscle reading as a flat sticker on a grey body.
    val glows = regions.map { loadColorFor(loads[it.group], peak, litAlpha = 0.22f, unlitAlpha = 0f) }
    val shares = regions.map { region ->
        val kg = loads[region.group]
        if (kg == null || kg <= 0 || peak <= 0) 0f else (kg / peak).toFloat().coerceIn(0f, 1f)
    }

    Canvas(modifier = Modifier.fillMaxWidth().aspectRatio(0.46f)) {
        // THREE PASSES, and the order is the whole difference between this reading as a body and as a
        // diagram. The silhouette first, as a filled shape under a slightly brighter outline, so the
        // figure has an edge instead of dissolving into the card. Then the glow of whatever is loaded,
        // wide and soft. Then the muscles themselves on top, sharp.
        silhouette.forEach { drawShape(it, bodyFill) }
        silhouette.forEach { drawShape(it, bodyEdge, stroke = size.width * 0.004f) }

        regions.forEachIndexed { i, shape ->
            if (shares[i] > 0f) {
                // Scaled up by a few percent and drawn behind: a halo the width of the muscle itself
                // would just look like a thicker muscle.
                drawShape(shape.inflated(1f + 0.10f * shares[i]), glows[i])
            }
        }
        regions.forEachIndexed { i, shape -> drawShape(shape, fills[i]) }

        // A hairline down the sternum and the spine. One line, and the front stops reading as a single
        // slab: it is what the eye uses to find the middle of a torso.
        drawCentreSeam(bodyEdge)
    }
}

/** This patch, grown about its own centre. Used for the load glow behind a lit muscle. */
private fun MuscleShape.inflated(factor: Float): MuscleShape = copy(
    topW = topW * factor,
    bottomW = bottomW * factor,
    h = h * factor,
)

/**
 * The line down the middle of the torso.
 *
 * Drawn rather than built into the silhouette because it has to sit ON TOP of the muscle patches — a
 * seam under the pecs is a seam nobody sees. Stops short of both ends: it is a suggestion of a sternum,
 * not a zip.
 */
private fun DrawScope.drawCentreSeam(color: Color) {
    val x = size.width * 0.5f
    drawLine(
        color = color,
        start = androidx.compose.ui.geometry.Offset(x, size.height * 0.20f),
        end = androidx.compose.ui.geometry.Offset(x, size.height * 0.46f),
        strokeWidth = size.width * 0.004f,
    )
}

/**
 * A patch, drawn as a tapered shape with a slight belly on each side.
 *
 * The two ends have different widths, the sides bow outward between them, and the corners are pulled
 * in by [MuscleShape.round]. That is the whole trick: straight parallel sides read as machinery, a
 * width that changes along the length reads as flesh.
 */
private fun DrawScope.drawShape(shape: MuscleShape, color: Color, stroke: Float = 0f) {
    val cx = size.width * shape.cx
    val cy = size.height * shape.cy
    val h = size.height * shape.h
    val topHalf = size.width * shape.topW / 2f
    val botHalf = size.width * shape.bottomW / 2f
    val lean = size.width * shape.tilt
    val top = cy - h / 2f
    val bottom = cy + h / 2f
    val topCx = cx - lean
    val botCx = cx + lean

    // Capped against BOTH the width and the height, so a short wide patch cannot round itself away.
    val rTop = minOf(topHalf, h / 2f) * shape.round
    val rBot = minOf(botHalf, h / 2f) * shape.round
    // How far the sides bow out mid-length. Proportional to the patch, so every muscle swells alike.
    val belly = (topHalf + botHalf) * 0.07f

    val path = Path().apply {
        moveTo(topCx - topHalf + rTop, top)
        lineTo(topCx + topHalf - rTop, top)
        quadraticBezierTo(topCx + topHalf, top, topCx + topHalf, top + rTop)
        cubicTo(
            topCx + topHalf + belly, top + h * 0.35f,
            botCx + botHalf + belly, top + h * 0.68f,
            botCx + botHalf, bottom - rBot,
        )
        quadraticBezierTo(botCx + botHalf, bottom, botCx + botHalf - rBot, bottom)
        lineTo(botCx - botHalf + rBot, bottom)
        quadraticBezierTo(botCx - botHalf, bottom, botCx - botHalf, bottom - rBot)
        cubicTo(
            botCx - botHalf - belly, top + h * 0.68f,
            topCx - topHalf - belly, top + h * 0.35f,
            topCx - topHalf, top + rTop,
        )
        quadraticBezierTo(topCx - topHalf, top, topCx - topHalf + rTop, top)
        close()
    }
    if (stroke > 0f) {
        drawPath(path, color, style = androidx.compose.ui.graphics.drawscope.Stroke(width = stroke))
    } else {
        drawPath(path, color)
    }
}

// MARK: - Reading the banked per-muscle totals

/**
 * Sum each group's `muscle_volume_<group>` rows over the trailing [WINDOW_DAYS].
 *
 * A group with no rows in the window is ABSENT from the map, not zero: "you did not train it" and
 * "you have no lifting log at all" are the same blank here, and the card says which by whether the
 * whole map came back empty.
 */
private suspend fun readMuscleLoads(viewModel: AppViewModel): Map<MuscleGroup, Double> {
    val today = LocalDate.now()
    val from = today.minusDays(WINDOW_DAYS - 1).toString()
    val to = today.toString()
    val out = LinkedHashMap<MuscleGroup, Double>()
    for (group in MuscleGroup.entries) {
        val rows = viewModel.repo.metricSeries(
            LiftingImporter.SOURCE_ID,
            LiftingImporter.muscleVolumeKey(group),
            from,
            to,
        )
        val total = rows.sumOf { it.value }
        if (total > 0) out[group] = total
    }
    return out
}
