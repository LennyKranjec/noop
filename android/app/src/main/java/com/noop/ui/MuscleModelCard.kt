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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
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
// The patch coordinates below were read off a normalised grid laid over that artwork, so they belong
// to THESE two images. Replace the drawings and the coordinates have to be re-derived — they will not
// survive a figure with different proportions.

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
 * One muscle patch: an ellipse over the anatomical figure, in NORMALISED 0-1 coordinates.
 *
 * The figure itself is a drawing ([R.drawable.body_front] / [body_back]); these only say WHERE a group
 * sits on it, so the load can be painted over the right muscle. Ellipses rather than the hand-drawn
 * tapered outlines the card used to carry: the artwork already supplies every contour, and a second
 * set of shapes competing with it read as a diagram drawn twice.
 *
 * Every figure below was read off a normalised grid laid over the artwork — see the note in the file
 * header. They are not portable to a different drawing.
 */
private data class MusclePatch(
    val group: MuscleGroup,
    val cx: Float,
    val cy: Float,
    val w: Float,
    val h: Float,
)

/**
 * Where each group sits on the FRONT figure, and on the BACK one.
 *
 * Paired left/right on purpose: a single wide patch spanning both sides would bleed across the
 * sternum and the spine, which is exactly where the artwork's own centre line is.
 */
private fun regionsFor(side: BodySide): List<MusclePatch> = when (side) {
    BodySide.Front -> listOf(
        // Deltoid caps — the widest point of the upper body.
        MusclePatch(MuscleGroup.SHOULDERS, 0.175f, 0.196f, 0.150f, 0.062f),
        MusclePatch(MuscleGroup.SHOULDERS, 0.825f, 0.196f, 0.150f, 0.062f),
        // Pectorals, stopping short of the midline so the two do not merge into a band.
        MusclePatch(MuscleGroup.CHEST, 0.404f, 0.226f, 0.175f, 0.070f),
        MusclePatch(MuscleGroup.CHEST, 0.596f, 0.226f, 0.175f, 0.070f),
        // Biceps: upper arm, below the deltoid.
        MusclePatch(MuscleGroup.BICEPS, 0.190f, 0.278f, 0.104f, 0.088f),
        MusclePatch(MuscleGroup.BICEPS, 0.810f, 0.278f, 0.104f, 0.088f),
        // Abdomen, from the sternum to the waist.
        MusclePatch(MuscleGroup.ABS, 0.500f, 0.320f, 0.215f, 0.120f),
        // Forearms.
        MusclePatch(MuscleGroup.FOREARMS, 0.158f, 0.404f, 0.105f, 0.120f),
        MusclePatch(MuscleGroup.FOREARMS, 0.842f, 0.404f, 0.105f, 0.120f),
        // Quadriceps.
        MusclePatch(MuscleGroup.QUADRICEPS, 0.420f, 0.552f, 0.125f, 0.155f),
        MusclePatch(MuscleGroup.QUADRICEPS, 0.580f, 0.552f, 0.125f, 0.155f),
        // Calves.
        MusclePatch(MuscleGroup.CALVES, 0.428f, 0.738f, 0.098f, 0.118f),
        MusclePatch(MuscleGroup.CALVES, 0.572f, 0.738f, 0.098f, 0.118f),
    )
    BodySide.Back -> listOf(
        MusclePatch(MuscleGroup.SHOULDERS, 0.180f, 0.198f, 0.148f, 0.062f),
        MusclePatch(MuscleGroup.SHOULDERS, 0.820f, 0.198f, 0.148f, 0.062f),
        // Traps: the wedge from the neck out over both shoulders, so this one DOES span the midline.
        MusclePatch(MuscleGroup.UPPER_BACK, 0.500f, 0.196f, 0.300f, 0.072f),
        // Lats, narrowing to the waist.
        MusclePatch(MuscleGroup.LATS, 0.400f, 0.270f, 0.150f, 0.090f),
        MusclePatch(MuscleGroup.LATS, 0.600f, 0.270f, 0.150f, 0.090f),
        MusclePatch(MuscleGroup.TRICEPS, 0.185f, 0.280f, 0.104f, 0.088f),
        MusclePatch(MuscleGroup.TRICEPS, 0.815f, 0.280f, 0.104f, 0.088f),
        // Lower back, the band above the pelvis.
        MusclePatch(MuscleGroup.LOWER_BACK, 0.500f, 0.350f, 0.200f, 0.055f),
        MusclePatch(MuscleGroup.FOREARMS, 0.155f, 0.400f, 0.105f, 0.120f),
        MusclePatch(MuscleGroup.FOREARMS, 0.845f, 0.400f, 0.105f, 0.120f),
        // Glutes — the widest point of the back view.
        MusclePatch(MuscleGroup.GLUTES, 0.428f, 0.428f, 0.155f, 0.090f),
        MusclePatch(MuscleGroup.GLUTES, 0.572f, 0.428f, 0.155f, 0.090f),
        // Hamstrings.
        MusclePatch(MuscleGroup.HAMSTRINGS, 0.422f, 0.560f, 0.128f, 0.150f),
        MusclePatch(MuscleGroup.HAMSTRINGS, 0.578f, 0.560f, 0.128f, 0.150f),
        MusclePatch(MuscleGroup.CALVES, 0.428f, 0.740f, 0.100f, 0.120f),
        MusclePatch(MuscleGroup.CALVES, 0.572f, 0.740f, 0.100f, 0.120f),
    )
}

/** The artwork's own proportions. Front and back differ slightly, so each keeps its own. */
private fun aspectFor(side: BodySide): Float = when (side) {
    BodySide.Front -> 700f / 2207f
    BodySide.Back -> 700f / 2115f
}

@Composable
private fun BodyCanvas(side: BodySide, loads: Map<MuscleGroup, Double>, peak: Double) {
    val regions = regionsFor(side)
    // Resolved OUTSIDE the draw scope: `loadColorFor` is composable (it reads the palette), and a
    // DrawScope cannot call one.
    val fills = regions.map { loadColorFor(loads[it.group], peak, litAlpha = 0.80f, unlitAlpha = 0f) }
    val bodyTint = Palette.textSecondary.copy(alpha = 0.55f)
    val painter = painterResource(
        when (side) {
            BodySide.Front -> R.drawable.body_front
            BodySide.Back -> R.drawable.body_back
        },
    )

    Box(
        modifier = Modifier.fillMaxWidth().aspectRatio(aspectFor(side)),
        contentAlignment = Alignment.Center,
    ) {
        // THE LOAD GOES UNDER THE LINE ART, not over it. Painted on top, even at 80% the colour
        // swallows the muscle contours it is supposed to be highlighting and the figure turns into a
        // set of flat blobs; underneath, the drawing's own shading reads THROUGH the colour and the
        // result looks like a lit muscle rather than a sticker on one.
        Canvas(modifier = Modifier.fillMaxSize()) {
            regions.forEachIndexed { i, patch ->
                if (fills[i].alpha <= 0f) return@forEachIndexed
                drawOval(
                    brush = Brush.radialGradient(
                        colors = listOf(fills[i], fills[i].copy(alpha = 0f)),
                        center = Offset(size.width * patch.cx, size.height * patch.cy),
                        radius = maxOf(size.width * patch.w, size.height * patch.h) * 0.62f,
                    ),
                    topLeft = Offset(
                        size.width * (patch.cx - patch.w / 2f),
                        size.height * (patch.cy - patch.h / 2f),
                    ),
                    size = Size(size.width * patch.w, size.height * patch.h),
                )
            }
        }
        Image(
            painter = painter,
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
