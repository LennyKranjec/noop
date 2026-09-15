package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.res.painterResource
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
//
// THE FIGURE IS A DRAWING, NOT GEOMETRY. `body_front` / `body_back` are anatomical line art, prepared
// as WHITE-ON-TRANSPARENT so the card can tint them to the palette instead of being stuck with the
// source's grey — which is what lets the same asset sit on a dark card without a pale rectangle round
// it. An earlier cut built the body out of tapered paths in code; the artwork carries contours no
// reasonable amount of path-fiddling was going to reach.
//
// EACH GROUP IS ITS OWN MASK, cut from that same drawing, so the colour lands on the muscle's real
// outline rather than on an ellipse approximating it. The masks arrived as tight crops with no offsets;
// they were located by segmenting the drawing into its own closed regions and matching each crop to a
// region by SHAPE — see the note in the asset pipeline. Two independent checks agreed on the result:
// the file numbering (stated to run top to bottom) correlates with the recovered heights at 0.99, and
// each crop overlaps its matched region at an IoU of 0.98.

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
                    val groups = masksFor(side).map { it.first }
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
 * The drawable holding one muscle group's own shape, on this side of the body.
 *
 * Each is an alpha mask cut from the same drawing the figure comes from — the real outline of the real
 * muscle, not an ellipse approximating where it sits. A group is ONE mask even when it is several
 * bellies (a quadriceps is four), because the card colours groups and the runtime has no reason to
 * know how many muscles make one up.
 *
 * Front and back carry different sets: a lat cannot be seen from the front, a pec cannot be seen from
 * the back, and offering a group on a side that does not show it would paint nothing and read as a bug.
 */
private fun masksFor(side: BodySide): List<Pair<MuscleGroup, Int>> = when (side) {
    BodySide.Front -> listOf(
        MuscleGroup.SHOULDERS to R.drawable.muscle_front_shoulders,
        MuscleGroup.CHEST to R.drawable.muscle_front_chest,
        MuscleGroup.UPPER_BACK to R.drawable.muscle_front_upper_back,
        MuscleGroup.BICEPS to R.drawable.muscle_front_biceps,
        MuscleGroup.TRICEPS to R.drawable.muscle_front_triceps,
        MuscleGroup.FOREARMS to R.drawable.muscle_front_forearms,
        MuscleGroup.ABS to R.drawable.muscle_front_abs,
        MuscleGroup.QUADRICEPS to R.drawable.muscle_front_quadriceps,
        MuscleGroup.CALVES to R.drawable.muscle_front_calves,
    )
    BodySide.Back -> listOf(
        MuscleGroup.SHOULDERS to R.drawable.muscle_back_shoulders,
        MuscleGroup.UPPER_BACK to R.drawable.muscle_back_upper_back,
        MuscleGroup.LATS to R.drawable.muscle_back_lats,
        MuscleGroup.TRICEPS to R.drawable.muscle_back_triceps,
        MuscleGroup.FOREARMS to R.drawable.muscle_back_forearms,
        MuscleGroup.LOWER_BACK to R.drawable.muscle_back_lower_back,
        MuscleGroup.GLUTES to R.drawable.muscle_back_glutes,
        MuscleGroup.HAMSTRINGS to R.drawable.muscle_back_hamstrings,
        MuscleGroup.CALVES to R.drawable.muscle_back_calves,
    )
}

/**
 * The shared canvas the figures and every mask are drawn on.
 *
 * ONE ASPECT FOR BOTH SIDES. The two source drawings are the same height but different widths, so
 * scaling each to a fixed width made the broader back figure shorter — the card showed the same person
 * at two sizes depending on which way he was facing. Both are now scaled by one factor and padded to
 * this canvas, which is also what lets a mask be composited over the figure with no offsets at all:
 * every asset is the same size, so they simply stack.
 */
private const val BODY_ASPECT = 695f / 2100f

@Composable
private fun BodyCanvas(side: BodySide, loads: Map<MuscleGroup, Double>, peak: Double) {
    val masks = masksFor(side)
    // Resolved OUTSIDE the draw pass: `loadColorFor` is composable (it reads the palette).
    val fills = masks.map { loadColorFor(loads[it.first], peak, litAlpha = 0.88f, unlitAlpha = 0f) }
    val bodyTint = Palette.textSecondary.copy(alpha = 0.55f)

    Box(
        modifier = Modifier.fillMaxWidth().aspectRatio(BODY_ASPECT),
        contentAlignment = Alignment.Center,
    ) {
        // THE LOAD GOES UNDER THE LINE ART. Painted on top, the colour swallows the very contours it is
        // meant to be highlighting and the figure turns into flat blobs; underneath, the drawing's own
        // shading reads through it and a loaded muscle looks lit rather than stickered.
        masks.forEachIndexed { i, (_, drawable) ->
            if (fills[i].alpha <= 0f) return@forEachIndexed
            Image(
                painter = painterResource(drawable),
                contentDescription = null,
                colorFilter = ColorFilter.tint(fills[i]),
                modifier = Modifier.fillMaxSize(),
            )
        }
        Image(
            painter = painterResource(
                when (side) {
                    BodySide.Front -> R.drawable.body_front
                    BodySide.Back -> R.drawable.body_back
                },
            ),
            contentDescription = null,
            colorFilter = ColorFilter.tint(bodyTint),
            modifier = Modifier.fillMaxSize(),
        )
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
