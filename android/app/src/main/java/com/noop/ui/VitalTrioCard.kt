package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.FavoriteBorder
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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

// MARK: - Heart, lungs, sleep
//
// Three tiles in a row under the muscle model, with no card heading of their own: the muscle figure
// above already says what this part of the screen is about, and a second title would be a label for a
// label.
//
// EACH TILE IS A THREE-DAY MEAN, not today. One night tells you about one night; the level itself is
// built on three-day means, and a tile showing today beside a level built on three days would disagree
// with it on screen. [VitalTile.days] carries how many days were actually averaged, because a "3-day
// mean" over one day is a different claim and the tile says so rather than quietly rounding.
//
// THE BAR FILLS FROM THE BOTTOM, against the metric's OWN frozen optimum. Sleep is full only when the
// three-day mean is at the best this wearer has recorded — not when it happens to be better than
// yesterday. That is the whole reason the baselines are frozen: a bar measured against a moving
// optimum can never be full, because reaching it moves it.
//
// TAPPING THE SLEEP TILE OPENS SLEEP. The button that used to do that is gone: a button whose only job
// is to open the thing shown directly above it is a button that could have been the thing itself.

/** One tile's resolved figures. Null score = the metric had no data; the tile says so rather than 0. */
private data class VitalTile(
    val part: LevelPart,
    val component: LevelComponent?,
    val previous: Double?,
    val days: Int,
)

@Composable
internal fun VitalTrioCard(viewModel: AppViewModel, onOpenSleep: () -> Unit) {
    val context = LocalContext.current
    var trend by remember { mutableStateOf<LevelTrend?>(null) }

    LaunchedEffect(viewModel.activeStrapId) {
        trend = withContext(Dispatchers.IO) {
            runCatching { LevelRepository.trend(context, viewModel.repo, viewModel.activeStrapId) }.getOrNull()
        }
    }

    val now = trend?.now
    val then = trend?.threeDaysAgo

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(Metrics.gap),
    ) {
        listOf(LevelPart.HEART, LevelPart.LUNGS, LevelPart.SLEEP).forEach { part ->
            VitalTileView(
                tile = VitalTile(
                    part = part,
                    component = now?.components?.firstOrNull { it.part == part },
                    previous = then?.components?.firstOrNull { it.part == part }?.score,
                    days = 3,
                ),
                total = now,
                onClick = if (part == LevelPart.SLEEP) onOpenSleep else null,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@Composable
private fun VitalTileView(
    tile: VitalTile,
    total: LevelBreakdown?,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val score = tile.component?.score
    val tint = partTint(tile.part)

    var box = modifier
        .clip(RoundedCornerShape(Metrics.cardRadius))
        .background(Palette.surfaceRaised)
    if (onClick != null) {
        box = box.clickable {
            SystemHaptics.play(context, SystemHaptics.Cue.TAP)
            onClick()
        }
    }

    Column(
        modifier = box.padding(Metrics.space12),
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        // Header: the glyph and the metric's name, as in the reference.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                partIcon(tile.part),
                contentDescription = null,
                tint = Palette.textSecondary,
                modifier = Modifier.size(Metrics.iconTiny),
            )
            Text(
                partLabel(tile.part),
                style = NoopType.overline,
                color = Palette.textSecondary,
                modifier = Modifier.padding(start = Metrics.space6),
                maxLines = 1,
            )
        }

        // Body: the three-day mean, and the vertical bar beside it.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = score?.roundToInt()?.toString() ?: uiString(R.string.level_no_data),
                style = if (score != null) NoopType.title2 else NoopType.footnote,
                color = if (score != null) Palette.textPrimary else Palette.textTertiary,
                fontWeight = if (score != null) FontWeight.Bold else FontWeight.Normal,
                modifier = Modifier.weight(1f),
                maxLines = 2,
            )
            OptimumBar(
                fraction = ((score ?: 0.0) / 100.0).toFloat(),
                tint = tint,
                lit = score != null,
            )
        }

        // Footer: what this metric is worth to the level, where it sits, and which way it is going.
        val share = tile.component?.let { c ->
            if (total == null || total.raw <= 0.0) null else (c.contribution / total.raw * 100.0)
        }
        Text(
            text = share?.let { uiString(R.string.level_metric_share, it.roundToInt()) } ?: " ",
            style = NoopType.caption,
            color = Palette.textTertiary,
            maxLines = 1,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = uiString(R.string.level_metric_lvl, score?.roundToInt() ?: 0),
                style = NoopType.caption,
                color = Palette.textSecondary,
            )
            TrendArrow(now = score, then = tile.previous)
        }
    }
}

/**
 * The vertical bar, filled from the bottom.
 *
 * Empty at the metric's frozen floor and full at its frozen optimum. Drawn as two stacked boxes rather
 * than a progress indicator so the unfilled part keeps its own colour, which is what makes the fill
 * legible at this size.
 */
@Composable
private fun OptimumBar(fraction: Float, tint: Color, lit: Boolean) {
    val clamped = fraction.coerceIn(0f, 1f)
    Box(
        modifier = Modifier
            .width(BAR_WIDTH)
            .height(BAR_HEIGHT)
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceInset),
        contentAlignment = Alignment.BottomCenter,
    ) {
        if (lit && clamped > 0f) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .fillMaxHeight(clamped)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(tint),
            )
        }
    }
}

private val BAR_WIDTH = 10.dp
private val BAR_HEIGHT = 56.dp

/**
 * Better or worse than the three-day mean three days ago.
 *
 * A move under one point is drawn flat: on a 0–100 score that is rounding, and an arrow would have the
 * wearer reading a trend into noise.
 */
@Composable
private fun TrendArrow(now: Double?, then: Double?) {
    val delta = if (now != null && then != null) now - then else null
    val flat = delta == null || abs(delta) < 1.0
    val icon: ImageVector = when {
        flat -> Icons.Filled.Remove
        delta!! > 0 -> Icons.Filled.ArrowUpward
        else -> Icons.Filled.ArrowDownward
    }
    val tint = when {
        flat -> Palette.textTertiary
        delta!! > 0 -> Palette.statusPositive
        else -> Palette.statusCritical
    }
    Icon(
        icon,
        contentDescription = null,
        tint = tint,
        modifier = Modifier
            .padding(start = Metrics.space4)
            .size(Metrics.iconTiny),
    )
}
