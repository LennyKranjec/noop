package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Icon
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.LevelBreakdown
import com.noop.analytics.LevelComponent
import com.noop.analytics.LevelDriver
import com.noop.analytics.LevelPart
import com.noop.analytics.LevelRepository
import com.noop.analytics.LevelTrend
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt

// MARK: - The level, above every screen
//
// One strip under the status bar, on every destination. It replaced the XP bar, which measured nothing
// — the level here is computed from the wearer's own metrics against a frozen scale, so the number
// moves only when the body does.
//
// THREE THINGS, IN THE ORDER THEY ARE READ. The RADAR sits in the middle because the level is the
// thing and its five parts are why it is what it is; the TREND sits left because "68, and up 4 since
// Monday" is the sentence; the LEVERS sit right because they are what to do about it.
//
// THE TREND SAYS HOW MANY POINTS. An arrow alone answers "better or worse" and leaves "by how much"
// to the imagination, and on a 0–100 scale the difference between +1 and +9 is the difference between
// noise and a week that worked.
//
// A LEVER NAMES ITS METRIC, not its part. A heart glyph could be asking for sleep, for caffeine or for
// an easier week; "rhr" under it says which figure is actually short. See [LevelDrivers].
//
// THE RADAR HANGS BELOW THE STRIP. Two thirds of it sit inside the bar and a third overhangs the screen
// under it, as its own always-on layer — which is why this is drawn by the SHELL as an overlay rather
// than returned from `topBar`: a Scaffold slot cannot paint outside itself, and content composed after
// it would draw over the overhang.

/** The strip's own height, without the status-bar inset it sits under. */
internal val LevelBarHeight = 52.dp

/** The radar's full diameter. Two thirds of it live in the bar; the rest overhangs. */
internal val LevelRadarDiameter = 86.dp

/**
 * How far the radar sits below the top of the strip.
 *
 * Clearance for the cut-out. Anchored flush to the top, the plate's own upper corner runs into the
 * notch on a phone that has one — and the level in its middle is the thing most worth not hiding.
 */
internal val LevelRadarDrop = 8.dp

/** How much of the radar hangs below the strip, and therefore how far content must clear it. */
internal val LevelRadarOverhang = LevelRadarDiameter / 3 + LevelRadarDrop

/** How many levers fit. Two: a third glyph makes the row a toolbar and nobody acts on three. */
private const val LEVER_COUNT = 2

/**
 * The strip and its radar, drawn as one always-on layer.
 *
 * [countUpKey] is flipped once per app open by the shell; changing it re-runs the count-up. It is a
 * parameter rather than something read here so that a recomposition — a tab change, a theme flip —
 * cannot restart the animation, which would make the header twitch every time the wearer navigated.
 */
@Composable
internal fun LevelOverlayBar(
    viewModel: AppViewModel,
    countUpKey: Any? = Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var trend by remember { mutableStateOf<LevelTrend?>(null) }
    var showTimeline by remember { mutableStateOf(false) }

    // Recomputed when the strap changes, and otherwise once per composition of the shell: the level
    // moves on the day's data, not on the second's, so there is nothing to poll.
    LaunchedEffect(viewModel.activeStrapId) {
        trend = withContext(Dispatchers.IO) {
            runCatching { LevelRepository.trend(context, viewModel.repo, viewModel.activeStrapId) }.getOrNull()
        }
    }

    val breakdown = trend?.now

    Column(modifier = modifier.fillMaxWidth()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Palette.surfaceBase)
                .statusBarsPadding()
                .height(LevelBarHeight)
                .padding(horizontal = Metrics.space16),
            contentAlignment = Alignment.Center,
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TrendCluster(trend, modifier = Modifier.weight(1f, fill = true))
                // Only the radar's WIDTH is reserved here, so the two clusters never slide under it. Its
                // height is not this Row's business: it is drawn below, where it can overhang.
                Box(modifier = Modifier.width(LevelRadarDiameter))
                LeverCluster(
                    breakdown = breakdown,
                    drivers = trend?.drivers.orEmpty(),
                    modifier = Modifier.weight(1f, fill = true),
                )
            }

            // THE OVERHANG, and `requiredSize` is what makes it possible.
            //
            // A plain `size()` is CLAMPED to the incoming constraints, and the bar is 52dp tall — so a
            // 78dp radar asked for politely was measured at 52, and the count-up and the pentagon both
            // vanished into a box too small to hold them. `requiredSize` ignores the parent's maximum,
            // which is exactly the escape hatch a deliberate overhang needs.
            //
            // Anchored at the bar's TOP rather than its centre: at the top, the bar's own 52dp holds the
            // first two thirds and the remaining 26dp falls past the bottom edge, which is the split the
            // wearer asked for. Nothing between here and the window root clips.
            Box(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .offset(y = LevelRadarDrop)
                    .requiredSize(LevelRadarDiameter),
            ) {
                LevelRadar(
                    breakdown = breakdown,
                    diameter = LevelRadarDiameter,
                    countUpKey = countUpKey,
                    modifier = Modifier.clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                        enabled = breakdown != null,
                    ) {
                        SystemHaptics.play(context, SystemHaptics.Cue.TAP)
                        showTimeline = !showTimeline
                    },
                )
            }
        }

        if (showTimeline) {
            LevelTimelineSheet(
                viewModel = viewModel,
                breakdown = breakdown,
                onDismiss = { showTimeline = false },
                modifier = Modifier.padding(top = LevelRadarOverhang),
            )
        }
    }
}

/**
 * Where the level has come from: three days, then a month.
 *
 * Both, because they answer different questions — three days is "did last night help", a month is "am
 * I actually getting anywhere". A single figure would hide whichever one the wearer needed.
 */
@Composable
private fun TrendCluster(trend: LevelTrend?, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        DeltaChip(trend?.deltaThreeDays, uiString(R.string.level_span_3d))
        DeltaChip(trend?.deltaMonth, uiString(R.string.level_span_1mo))
    }
}

/**
 * One arrow, the points behind it, and the span it covers.
 *
 * THE NUMBER IS THE POINT. "Up since Monday" is a mood; "+4 since Monday" is a measurement, and it is
 * the measurement the wearer can act on — a +1 week and a +9 week look identical without it.
 *
 * THE SLOT STAYS, THE "0" GOES. A chip that disappears entirely when nothing moved leaves the wearer
 * unable to tell "unchanged" from "not computed" — the row simply has one fewer line, which reads as
 * something failing rather than as a steady week. So an unmoved span keeps its place and says "–": the
 * span is still named, and the absence of a number is the statement.
 */
@Composable
private fun DeltaChip(delta: Double?, span: String) {
    // A change under half a point is noise on a 0–100 scale, and so is one that rounds away to nothing;
    // both are shown as flat rather than as a number the wearer would read meaning into.
    val points = delta?.roundToInt() ?: 0
    val flat = delta == null || abs(delta) < 0.5 || points == 0

    val tint = when {
        flat -> Palette.textTertiary
        delta!! > 0 -> Palette.statusPositive
        else -> Palette.statusCritical
    }
    val arrow: ImageVector = when {
        flat -> Icons.Filled.Remove
        delta!! > 0 -> Icons.Filled.ArrowUpward
        else -> Icons.Filled.ArrowDownward
    }
    // SIGNED when there is one, because an unsigned "4" beside a down arrow reads as two statements of
    // the same thing and invites the reader to check which one is right.
    val label = when {
        flat -> "–"
        points > 0 -> "+$points"
        else -> "$points"
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        // NO ARROW WHEN THERE IS NOTHING TO POINT AT. The flat glyph is a dash and the flat label is a
        // dash, and the two of them side by side read as a rendering fault rather than as "unchanged".
        // The dash alone says it once.
        if (!flat) {
            Icon(
                arrow,
                contentDescription = uiString(R.string.level_trend_a11y, span, points),
                tint = tint,
                modifier = Modifier.size(Metrics.iconTiny),
            )
        }
        Text(
            text = label,
            style = NoopType.captionNumber,
            color = tint,
            modifier = Modifier.padding(start = 2.dp),
            maxLines = 1,
        )
        Text(
            text = span,
            style = NoopType.overline,
            color = Palette.textTertiary,
            modifier = Modifier.padding(start = 3.dp),
            maxLines = 1,
        )
    }
}

/**
 * What would move the level most: the glyph, and the metric's own short name.
 *
 * Ranked by what they are WORTH, not by which score is lowest — see [LevelBreakdown.levers]. A lungs
 * score of 20 looks worse than a sleep score of 60 and is worth a third as much level, and pointing at
 * it would send the wearer after the wrong thing.
 */
@Composable
private fun LeverCluster(
    breakdown: LevelBreakdown?,
    drivers: Map<LevelPart, LevelDriver>,
    modifier: Modifier = Modifier,
) {
    val levers = breakdown?.levers()?.take(LEVER_COUNT).orEmpty()
    val top = levers.firstOrNull()?.headroom ?: 0.0
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        levers.forEach { lever ->
            val share = if (top > 0) (lever.headroom / top).toFloat() else 0f
            LeverRow(lever, drivers[lever.part], share)
        }
    }
}

@Composable
private fun LeverRow(lever: LevelComponent, driver: LevelDriver?, share: Float) {
    // Opacity carries the relative impact. Size would too, but a row this short cannot afford the
    // layout shift when the ranking changes between renders.
    val alpha = 0.45f + 0.55f * share.coerceIn(0f, 1f)
    val tint = partTint(lever.part).copy(alpha = alpha)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            partIcon(lever.part),
            contentDescription = uiString(
                R.string.level_lever_a11y,
                partLabel(lever.part),
                lever.headroom.roundToInt(),
            ),
            tint = tint,
            modifier = Modifier.size(Metrics.iconTiny),
        )
        Text(
            // The glyph carries the part, so the word only has to carry the metric — which is what lets
            // "consistency" stand next to a moon without also saying "sleep".
            text = driver?.let { driverLabel(it) } ?: partLabel(lever.part).lowercase(),
            style = NoopType.overline,
            color = tint,
            modifier = Modifier.padding(start = 3.dp),
            maxLines = 1,
        )
    }
}

@Composable
internal fun driverLabel(driver: LevelDriver): String = uiString(
    when (driver) {
        LevelDriver.SLEEP_SCORE -> R.string.level_driver_sleep_score
        LevelDriver.SLEEP_CONSISTENCY -> R.string.level_driver_consistency
        LevelDriver.HRV -> R.string.level_driver_hrv
        LevelDriver.RHR -> R.string.level_driver_rhr
        LevelDriver.VO2MAX -> R.string.level_driver_vo2max
        LevelDriver.RESP_RATE -> R.string.level_driver_resp_rate
        LevelDriver.MUSCLE_VOLUME -> R.string.level_driver_volume
        LevelDriver.STRESS -> R.string.level_driver_stress
        LevelDriver.MEDITATION -> R.string.level_driver_meditation
    },
)

internal fun partIcon(part: LevelPart): ImageVector = when (part) {
    LevelPart.SLEEP -> Icons.Filled.Bedtime
    LevelPart.HEART -> Icons.Filled.FavoriteBorder
    LevelPart.LUNGS -> Icons.Filled.Air
    LevelPart.MUSCLE -> Icons.Filled.FitnessCenter
    LevelPart.FOCUS -> Icons.Filled.Bolt
}

internal fun partTint(part: LevelPart): Color = when (part) {
    LevelPart.SLEEP -> Palette.restBright
    LevelPart.HEART -> Palette.statusCritical
    LevelPart.LUNGS -> Palette.metricCyan
    LevelPart.MUSCLE -> Palette.statusWarning
    LevelPart.FOCUS -> Palette.accent
}

@Composable
internal fun partLabel(part: LevelPart): String = uiString(
    when (part) {
        LevelPart.SLEEP -> R.string.level_part_sleep
        LevelPart.HEART -> R.string.level_part_heart
        LevelPart.LUNGS -> R.string.level_part_lungs
        LevelPart.MUSCLE -> R.string.level_part_muscle
        LevelPart.FOCUS -> R.string.level_part_focus
    },
)
