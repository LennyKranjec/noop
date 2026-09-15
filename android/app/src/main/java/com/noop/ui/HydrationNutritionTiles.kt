package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Grain
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SetMeal
import androidx.compose.material.icons.filled.WaterDrop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.HydrationStore
import com.noop.ingest.HealthConnectImporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

// MARK: - Hydration + Nutrition, the two Today tiles
//
// Both read what this app already stores and neither invents a figure:
//
//   · HYDRATION is [HydrationStore] — the same day total the Hydration screen writes, so logging a
//     glass here and opening that screen show one number. The − / + buttons write through the store.
//
//   · NUTRITION is the nutrition-CSV lane's `metricSeries` keys (`calories_in`, `protein_g`,
//     `carbs_g`, `fat_g`) on the "nutrition-csv" source. Nothing on a strap measures a macro, so
//     with no import the tile reads "–" per macro rather than zero: "you ate no protein" and "no
//     log was imported" are different statements and only one of them is true here.

/** A day's water, drawn as a filled vessel with a live surface — the tile's whole point. */
private val WATER_TILE_HEIGHT = 132.dp

/** One tap of the + / − buttons. 250 ml is a glass, which is what the buttons are for. */
private const val GLASS_ML = 250

@Composable
internal fun HydrationTile(
    viewModel: AppViewModel,
    goalMl: Int,
    onOpen: () -> Unit,
) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    // READS ITS OWN TOTAL, deliberately. Today's `hydrationTotalMl` is gated on the hydration-tracking
    // preference, which is OFF by default — so on a fresh install that value is a hard 0.0 and the
    // water could never rise however many glasses were logged. The store's own mutationSeq re-reads
    // the row the moment a write lands, which is also what makes the buttons below feel immediate.
    val seq by HydrationStore.mutationSeq.collectAsStateWithLifecycle()
    var storedMl by remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(seq) {
        storedMl = withContext(Dispatchers.IO) {
            runCatching { HydrationStore.total(viewModel.repo) }.getOrDefault(0.0)
        }
    }
    // An optimistic overlay so the water moves on the tap rather than after the round trip; cleared
    // whenever a fresh store read lands.
    var optimisticMl by remember(storedMl) { mutableDoubleStateOf(storedMl) }
    val shownMl = optimisticMl
    val frac = if (goalMl > 0) (shownMl / goalMl).coerceIn(0.0, 1.0) else 0.0

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(WATER_TILE_HEIGHT)
            .clip(RoundedCornerShape(Metrics.cardRadius))
            .background(Palette.surfaceRaised)
            .clickable(onClick = onOpen),
    ) {
        WaterFill(fraction = frac.toFloat())

        // The volume read-out, top right — the reference tile's "48/64" line.
        Text(
            text = uiString(
                R.string.hydration_tile_amount,
                formatMl(shownMl),
                formatMl(goalMl.toDouble()),
            ),
            style = NoopType.bodyNumber,
            color = Palette.textSecondary,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(Metrics.space12),
        )

        // The buttons take the place the reference tile gives its caption.
        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = Metrics.space12),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            WaterButton(Icons.Filled.Remove, uiString(R.string.hydration_tile_remove)) {
                optimisticMl = (shownMl - GLASS_ML).coerceAtLeast(0.0)
                scope.launch { HydrationStore.remove(viewModel.repo, GLASS_ML) }
            }
            WaterButton(Icons.Filled.Add, uiString(R.string.hydration_tile_add)) {
                optimisticMl = shownMl + GLASS_ML
                // Logging a glass IS the opt-in: hydration tracking ships off, and without this the
                // rest of the app (the Your-cards tile, the goal ring) would keep reading zero for
                // water this tile had already banked. Only ever turned ON, and only by a tap.
                if (!NoopPrefs.hydrationTracking(context)) {
                    NoopPrefs.setHydrationTracking(context, true)
                }
                scope.launch { HydrationStore.log(viewModel.repo, GLASS_ML) }
            }
        }
    }
}

@Composable
private fun WaterButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(Metrics.iconButton)
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceBase.copy(alpha = 0.55f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Palette.textPrimary, modifier = Modifier.size(Metrics.iconSmall))
    }
}

/**
 * The water itself: a filled body with a live sine surface, plus the dashed reference lines.
 *
 * Two waves of different wavelength and speed are summed so the surface never reads as one
 * repeating sine. Motion is gated through [rememberPoseStill] like every other liquid surface in
 * this app — reduce motion / power save / quiet motion pose it flat instead of running a clock.
 */
@Composable
private fun WaterFill(fraction: Float) {
    val still = rememberPoseStill()
    var seconds by remember { mutableDoubleStateOf(0.0) }
    if (!still) {
        LaunchedEffect(Unit) {
            var last = 0L
            while (true) {
                withFrameNanos { frame ->
                    if (last != 0L) seconds += (frame - last) / 1_000_000_000.0
                    last = frame
                }
            }
        }
    }

    val dash = PathEffect.dashPathEffect(floatArrayOf(10f, 10f), 0f)
    val lineColor = Palette.hairlineStrong

    Canvas(modifier = Modifier.fillMaxSize()) {
        val surfaceY = size.height * (1f - fraction.coerceIn(0f, 1f))
        val t = seconds.toFloat()
        val amplitude = if (still) 0f else size.height * 0.03f

        /**
         * One wave sheet.
         *
         * THE MOVEMENT IS THE POINT, and a single sine is what made the old version read as a
         * cardboard cut-out sliding back and forth. Each sheet here sums FOUR components at
         * unrelated wavelengths and speeds, so no two crests ever line up the same way twice and the
         * surface never visibly repeats. On top of that the whole sheet BREATHES: [swell] moves its
         * resting height slowly, which is the part that reads as a body of liquid rather than a
         * painted edge.
         *
         * Layers are drawn back to front, each one deeper, slower, darker and calmer than the one in
         * front — a far surface moves less across your field of view than a near one, and that
         * difference is what the eye reads as depth.
         */
        fun wave(depth: Float, speed: Float, offset: Float, shade: Color, wobble: Float) {
            val swell = amplitude * 0.45f * sin(t * 0.23f * speed + offset)
            val baseY = surfaceY + depth + swell
            val path = Path().apply {
                moveTo(0f, baseY)
                val steps = 72
                for (i in 0..steps) {
                    val x = size.width * i / steps
                    val phase = x / size.width * 2f * PI.toFloat()
                    val y = baseY + amplitude * wobble * (
                        0.60f * sin(phase * 1.0f + t * 0.90f * speed + offset) +
                            0.28f * sin(phase * 2.3f - t * 1.40f * speed + offset * 1.7f) +
                            0.14f * sin(phase * 3.7f + t * 2.10f * speed) +
                            0.08f * sin(phase * 6.1f - t * 3.10f * speed)
                        )
                    lineTo(x, y)
                }
                lineTo(size.width, size.height)
                lineTo(0f, size.height)
                close()
            }
            drawPath(path, color = shade)
        }

        // A deep-sea blue reading up to a bright surface blue. Fixed rather than taken from the
        // palette accent: this is water, and the accent is chrome — tying them made the tile change
        // colour with the theme's selection colour, which is not what a glass of water does.
        val abyss = Color(0xFF07294A)
        val deep = Color(0xFF0B3C6B)
        val mid = Color(0xFF1668B3)
        val bright = Color(0xFF2E9BE8)
        val foam = Color(0xFF7FC9F5)

        wave(depth = size.height * 0.085f, speed = 0.42f, offset = 3.1f, shade = abyss.copy(alpha = 0.96f), wobble = 0.45f)
        wave(depth = size.height * 0.058f, speed = 0.61f, offset = 1.9f, shade = deep.copy(alpha = 0.94f), wobble = 0.65f)
        wave(depth = size.height * 0.030f, speed = 0.88f, offset = 0.9f, shade = mid.copy(alpha = 0.92f), wobble = 0.85f)
        wave(depth = 0f, speed = 1.18f, offset = 0f, shade = bright.copy(alpha = 0.90f), wobble = 1f)

        // The crest itself, as a thin bright line rather than another filled sheet: it catches the
        // eye where water actually catches light, and it is what sells the front sheet as a SURFACE
        // instead of the top edge of a coloured block.
        if (!still) {
            val crest = Path()
            val steps = 72
            for (i in 0..steps) {
                val x = size.width * i / steps
                val phase = x / size.width * 2f * PI.toFloat()
                val y = surfaceY + amplitude * 0.45f * sin(t * 0.23f * 1.18f) + amplitude * (
                    0.60f * sin(phase * 1.0f + t * 0.90f * 1.18f) +
                        0.28f * sin(phase * 2.3f - t * 1.40f * 1.18f) +
                        0.14f * sin(phase * 3.7f + t * 2.10f * 1.18f) +
                        0.08f * sin(phase * 6.1f - t * 3.10f * 1.18f)
                    )
                if (i == 0) crest.moveTo(x, y) else crest.lineTo(x, y)
            }
            drawPath(
                crest,
                color = foam.copy(alpha = 0.55f),
                style = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round),
            )
        }

        // Reference lines: the goal line at the top and the halfway mark, dashed, over the water.
        listOf(0.25f, 0.5f, 0.75f).forEach { at ->
            val y = size.height * (1f - at)
            drawLine(
                color = lineColor,
                start = Offset(0f, y),
                end = Offset(size.width, y),
                strokeWidth = 1.dp.toPx(),
                pathEffect = dash,
            )
        }
    }
}

/** ml as the tile shows it: litres past a litre, plain millilitres below. */
private fun formatMl(ml: Double): String =
    if (ml >= 1000) String.format(Locale.US, "%.1f L", ml / 1000.0)
    else "${ml.toInt()} ml"

// MARK: - Nutrition tile

/** One day's macros, all four independently absent-able. */
private data class MacrosToday(
    val kcal: Double?,
    val proteinG: Double?,
    val carbsG: Double?,
    val fatG: Double?,
)

@Composable
internal fun NutritionTile(viewModel: AppViewModel) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var macros by remember { mutableStateOf<MacrosToday?>(null) }
    LaunchedEffect(Unit) {
        macros = withContext(Dispatchers.IO) {
            // A food diary is filled in across the day, so a figure banked at import time is wrong by
            // lunchtime. Top today up from the health store BEFORE reading — best-effort, because a
            // store that is unavailable or ungranted should leave the tile showing what is stored
            // rather than showing nothing.
            runCatching { HealthConnectImporter.refreshTodayMacros(context, viewModel.repo) }
            runCatching { readMacros(viewModel) }.getOrNull()
        }
    }
    val m = macros

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            // Centred title between two hairlines, as the reference tile heads its card.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(modifier = Modifier.weight(1f).height(Metrics.divider).background(Palette.hairline))
                Text(
                    uiString(R.string.nav_nutrition),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.padding(horizontal = Metrics.space12),
                )
                Box(modifier = Modifier.weight(1f).height(Metrics.divider).background(Palette.hairline))
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                EnergyDial(kcal = m?.kcal, diameter = 108.dp)
                Spacer(Modifier.width(Metrics.space12))
                Row(
                    modifier = Modifier.weight(1f),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    // Icons mirror the reference tile's three glyphs: an oil drop for fat, a grain
                    // ear for carbohydrate, a fish for protein.
                    MacroRing(uiString(R.string.macro_fat), m?.fatG, Palette.metricCyan, Icons.Filled.WaterDrop)
                    MacroRing(uiString(R.string.macro_carbs), m?.carbsG, Palette.metricAmber, Icons.Filled.Grain)
                    MacroRing(uiString(R.string.macro_protein), m?.proteinG, Palette.metricRose, Icons.Filled.SetMeal)
                }
            }

            if (m != null && m.kcal == null && m.proteinG == null) {
                Text(
                    uiString(R.string.nutrition_tile_no_import),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}

/** The tick dial from the stress card, reading kcal — one instrument language across Today. */
@Composable
private fun EnergyDial(kcal: Double?, diameter: Dp) {
    val ticks = 36
    val startDeg = 140f
    val spanDeg = 260f
    val litColor = Palette.metricAmber
    val unlit = Palette.textTertiary.copy(alpha = 0.25f)
    // No calorie TARGET exists in this app, so the dial cannot show progress toward one. It draws its
    // scale and carries the figure; lighting an arbitrary share of it would invent the goal.
    Box(modifier = Modifier.size(diameter), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val radius = min(size.width, size.height) / 2f
            val outer = radius * 0.96f
            val inner = radius * 0.74f
            repeat(ticks) { i ->
                val t = i / (ticks - 1).toFloat()
                val angle = Math.toRadians((startDeg + spanDeg * t).toDouble())
                drawLine(
                    color = if (kcal == null) unlit else litColor.copy(alpha = 0.85f),
                    start = Offset(center.x + cos(angle).toFloat() * inner, center.y + sin(angle).toFloat() * inner),
                    end = Offset(center.x + cos(angle).toFloat() * outer, center.y + sin(angle).toFloat() * outer),
                    strokeWidth = maxOf(1.5f, radius * 0.05f),
                    cap = StrokeCap.Round,
                )
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                kcal?.let { String.format(Locale.US, "%,d", Math.round(it)) } ?: "–",
                style = NoopType.number(20f),
                color = if (kcal == null) Palette.textTertiary else Palette.textPrimary,
                textAlign = TextAlign.Center,
            )
            Text(uiString(R.string.nutrition_kcal), style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

@Composable
private fun MacroRing(
    label: String,
    grams: Double?,
    tint: Color,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
        val ringColor = if (grams == null) Palette.textTertiary.copy(alpha = 0.4f) else tint
        Box(modifier = Modifier.size(44.dp), contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawCircle(
                    color = ringColor,
                    radius = size.minDimension / 2f - 2.dp.toPx(),
                    style = Stroke(width = 2.dp.toPx()),
                )
            }
            Icon(
                icon,
                contentDescription = null,
                tint = ringColor,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
        Text(label, style = NoopType.footnote, color = if (grams == null) Palette.textTertiary else tint)
        Text(
            grams?.let { "${Math.round(it)} g" } ?: "–",
            style = NoopType.captionNumber,
            color = if (grams == null) Palette.textTertiary else Palette.textPrimary,
        )
    }
}

/**
 * Today's macros: the live health-store sync first, the imported CSV second.
 *
 * ONE LOG ON SCREEN, NOT A BLEND. Whichever source has today's day is taken whole; falling back per
 * FIELD would let the protein come from the phone's food diary and the carbohydrate from a CSV exported
 * last week, and put a meal on the tile that nobody ate.
 *
 * The live sync wins when it has anything, because it is today's diary as it stands right now — a CSV
 * was true whenever it was exported.
 */
private suspend fun readMacros(viewModel: AppViewModel): MacrosToday {
    val day = LocalDate.now().toString()
    suspend fun read(source: String, key: String): Double? =
        viewModel.repo.metricSeries(source, key, day, day).lastOrNull()?.value
    suspend fun from(source: String) = MacrosToday(
        kcal = read(source, "calories_in"),
        proteinG = read(source, "protein_g"),
        carbsG = read(source, "carbs_g"),
        fatG = read(source, "fat_g"),
    )
    val live = from(HealthConnectImporter.NUTRITION_SOURCE)
    val hasLive = live.kcal != null || live.proteinG != null || live.carbsG != null || live.fatG != null
    return if (hasLive) live else from(NUTRITION_SOURCE)
}

/** The nutrition importer's source id — the same one NutritionCsvImporter writes under. */
private const val NUTRITION_SOURCE = "nutrition-csv"
