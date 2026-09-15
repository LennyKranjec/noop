package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.analytics.LevelBreakdown
import com.noop.analytics.LevelComponent
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
// THREE THINGS, IN THE ORDER THEY ARE READ. The LEVEL sits in the middle because it is the thing; the
// TREND sits left of it because "68, and up 4 since Monday" is the sentence; the LEVERS sit right
// because they are what to do about it. A row this thin cannot hold labels, so each half is a glyph and
// a number, and every one of them has a content description for the same information spoken.
//
// THE LEVERS ARE RANKED BY WHAT THEY ARE WORTH, not by which score is lowest — see
// [LevelBreakdown.levers]. A lungs score of 20 looks worse than a sleep score of 60 and is worth a
// third as much level, and pointing at it would send the wearer after the wrong thing.

/** The strip's own height, without the status-bar inset it sits under. */
internal val LevelBarHeight = 26.dp

/** How many levers fit. Two: a third glyph makes the row a toolbar and nobody acts on three. */
private const val LEVER_COUNT = 2

@Composable
internal fun LevelOverlayBar(viewModel: AppViewModel, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var trend by remember { mutableStateOf<LevelTrend?>(null) }

    // Recomputed when the strap changes, and otherwise once per composition of the shell: the level
    // moves on the day's data, not on the second's, so there is nothing to poll.
    LaunchedEffect(viewModel.activeStrapId) {
        trend = withContext(Dispatchers.IO) {
            runCatching { LevelRepository.trend(context, viewModel.repo, viewModel.activeStrapId) }.getOrNull()
        }
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceBase)
            .statusBarsPadding()
            .height(LevelBarHeight)
            .padding(horizontal = Metrics.space16),
        contentAlignment = Alignment.Center,
    ) {
        val breakdown = trend?.now
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TrendCluster(trend, modifier = Modifier.weight(1f, fill = true))
            LevelNumber(breakdown)
            LeverCluster(breakdown, modifier = Modifier.weight(1f, fill = true))
        }
    }
}

/** The level itself: the one figure the strip exists for, so it is the only bold thing on it. */
@Composable
private fun LevelNumber(breakdown: LevelBreakdown?) {
    val level = breakdown?.level
    Text(
        text = level?.roundToInt()?.toString() ?: "–",
        style = NoopType.headline,
        color = if (level == null) Palette.textTertiary else Palette.textPrimary,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.5.sp,
        modifier = Modifier.padding(horizontal = Metrics.space12),
    )
}

/**
 * Where the level has come from: three days, then a month.
 *
 * Both, because they answer different questions — three days is "did last night help", a month is "am
 * I actually getting anywhere". A single figure would hide whichever one the wearer needed.
 */
@Composable
private fun TrendCluster(trend: LevelTrend?, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DeltaChip(trend?.deltaThreeDays, uiString(R.string.level_span_3d))
        DeltaChip(trend?.deltaMonth, uiString(R.string.level_span_1mo))
    }
}

@Composable
private fun DeltaChip(delta: Double?, span: String) {
    // A change under half a point is noise on a 0–100 scale; showing it as an arrow would have the
    // wearer reading meaning into rounding.
    val flat = delta != null && abs(delta) < 0.5
    val tint = when {
        delta == null -> Palette.textTertiary
        flat -> Palette.textTertiary
        delta > 0 -> Palette.statusPositive
        else -> Palette.statusCritical
    }
    val arrow: ImageVector = when {
        delta == null || flat -> Icons.Filled.Remove
        delta > 0 -> Icons.Filled.ArrowUpward
        else -> Icons.Filled.ArrowDownward
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            arrow,
            contentDescription = uiString(
                R.string.level_trend_a11y,
                span,
                delta?.roundToInt() ?: 0,
            ),
            tint = tint,
            modifier = Modifier.size(Metrics.iconTiny),
        )
        Text(
            text = span,
            style = NoopType.overline,
            color = tint,
            modifier = Modifier.padding(start = 2.dp),
        )
    }
}

/**
 * What would move the level most, as icons.
 *
 * Sized by relative impact rather than drawn identically: the first lever is usually worth several
 * times the second, and two equal glyphs would say they are equal choices.
 */
@Composable
private fun LeverCluster(breakdown: LevelBreakdown?, modifier: Modifier = Modifier) {
    val levers = breakdown?.levers()?.take(LEVER_COUNT).orEmpty()
    val top = levers.firstOrNull()?.headroom ?: 0.0
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        levers.forEach { lever ->
            val share = if (top > 0) (lever.headroom / top).toFloat() else 0f
            LeverGlyph(lever, share)
        }
    }
}

@Composable
private fun LeverGlyph(lever: LevelComponent, share: Float) {
    // Opacity carries the relative impact. Size would too, but a row this short cannot afford the
    // layout shift when the ranking changes between renders.
    val alpha = 0.45f + 0.55f * share.coerceIn(0f, 1f)
    Icon(
        partIcon(lever.part),
        contentDescription = uiString(
            R.string.level_lever_a11y,
            partLabel(lever.part),
            lever.headroom.roundToInt(),
        ),
        tint = partTint(lever.part).copy(alpha = alpha),
        modifier = Modifier.size(Metrics.iconTiny),
    )
}

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
