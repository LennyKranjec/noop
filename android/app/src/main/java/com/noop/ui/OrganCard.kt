package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Psychology
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
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.DailyMetric
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - The three organ tiles: heart, lungs, brain
//
// WHAT EACH ONE READS, and why that metric and not another:
//
//   · HEART — HRV (RMSSD) and resting heart rate. The two figures the strap measures most directly
//     overnight, and the pair every recovery read in this app is built from.
//   · LUNGS — VO₂max (`vo2max_est`, the app's own estimate) with respiratory rate beside it. VO₂max
//     is the respiratory-capacity number; respiration rate is what was actually counted last night.
//   · BRAIN — REM and deep sleep. Neither is a "brain score", and the tile does not pretend to one:
//     these are the two stages sleep research ties to memory consolidation and to clearance, they
//     are what this app can honestly measure about the night, and they are labelled as what they
//     are. The alternative — an invented "cognitive index" — would be a number with nothing behind
//     it, which is the one thing this codebase refuses to ship.
//
// COLOUR WORKS AS IT DOES ON THE MUSCLE MODEL: each organ is shaded by where its headline metric
// sits within the wearer's OWN trailing 30 days, not against a population norm. High in your own
// range reads bright; nothing measured reads unlit. There is no clinical claim in the colour.

private const val WINDOW_DAYS = 30

@Composable
internal fun OrganCards(days: List<DailyMetric>, viewModel: AppViewModel) {
    var vo2max by remember { mutableStateOf<Double?>(null) }
    LaunchedEffect(viewModel.activeStrapId) {
        vo2max = withContext(Dispatchers.IO) {
            runCatching {
                viewModel.repo.latestMetricComputedUnion(viewModel.activeStrapId, "vo2max_est")?.value
            }.getOrNull()
        }
    }

    val window = remember(days) { days.takeLast(WINDOW_DAYS) }
    val latest = window.lastOrNull()

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Column {
                Text(uiString(R.string.organs_title), style = NoopType.headline, color = Palette.textPrimary)
                Text(
                    uiString(R.string.organs_subtitle),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            }

            // HORIZONTAL: three organs side by side, each its own column. Vertically they read as
            // a list of settings; side by side they read as a body, which is what they are.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                OrganColumn(
                    icon = Icons.Filled.Favorite,
                    name = uiString(R.string.organ_heart),
                    // HIGHER HRV is the better end of your own range, so the ramp reads as-is.
                    standing = standing(latest?.avgHrv, window.mapNotNull { it.avgHrv }),
                    accent = Palette.metricRose,
                    metrics = listOf(
                        uiString(R.string.organ_metric_hrv) to latest?.avgHrv?.let { "${it.roundToInt()} ms" },
                        uiString(R.string.organ_metric_rhr) to latest?.restingHr?.let { "$it" },
                    ),
                    modifier = Modifier.weight(1f),
                )
                OrganColumn(
                    icon = Icons.Filled.Air,
                    name = uiString(R.string.organ_lungs),
                    // VO2max is a single latest estimate with no per-day column to rank within, so the
                    // shading comes from respiration rate — the figure this night actually counted.
                    standing = standing(latest?.respRateBpm, window.mapNotNull { it.respRateBpm }),
                    accent = Palette.metricCyan,
                    metrics = listOf(
                        uiString(R.string.organ_metric_vo2) to vo2max?.let {
                            String.format(Locale.US, "%.1f", it)
                        },
                        uiString(R.string.organ_metric_resp) to latest?.respRateBpm?.let {
                            String.format(Locale.US, "%.1f", it)
                        },
                    ),
                    modifier = Modifier.weight(1f),
                )
                OrganColumn(
                    icon = Icons.Filled.Psychology,
                    name = uiString(R.string.organ_brain),
                    standing = standing(latest?.remMin, window.mapNotNull { it.remMin }),
                    accent = Palette.metricPurple,
                    metrics = listOf(
                        uiString(R.string.organ_metric_rem) to latest?.remMin?.let { organMinutes(it) },
                        uiString(R.string.organ_metric_deep) to latest?.deepMin?.let { organMinutes(it) },
                    ),
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

/**
 * Where [value] sits within [history], 0–1, or null when there is nothing to place it against.
 *
 * A window whose values are all equal (or a single day) has no spread to rank within, so this
 * returns null rather than 0 or 1 — "we cannot place this yet" is not "this is the bottom".
 */
internal fun standing(value: Double?, history: List<Double>): Float? {
    if (value == null || history.size < 3) return null
    val min = history.min()
    val max = history.max()
    if (max - min <= 0.0) return null
    return ((value - min) / (max - min)).toFloat().coerceIn(0f, 1f)
}

@JvmName("standingInt")
internal fun standing(value: Int?, history: List<Int>): Float? =
    standing(value?.toDouble(), history.map { it.toDouble() })

private fun organMinutes(minutes: Double): String {
    val total = minutes.roundToInt()
    return if (total >= 60) "${total / 60}h ${total % 60}m" else "${total}m"
}

@Composable
private fun OrganColumn(
    icon: ImageVector,
    name: String,
    standing: Float?,
    accent: Color,
    metrics: List<Pair<String, String?>>,
    modifier: Modifier = Modifier,
) {
    // The same ring-around-a-glyph the macro tile uses, so the two cards on this screen speak one
    // language. It replaced tinted anatomical artwork: a drawing tinted as a whole reads as a
    // silhouette, and the gradient-plus-outline version that fixed that was a lot of machinery for a
    // 64 dp square. A glyph in its ring says "heart" just as well at this size.
    //
    // Unlit when nothing could be placed — the rule the muscle model uses for an unattributed group.
    val tint = if (standing == null) {
        Palette.textTertiary.copy(alpha = 0.5f)
    } else {
        accent.copy(alpha = 0.55f + 0.45f * standing)
    }

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(Palette.surfaceInset)
            .padding(vertical = Metrics.space12, horizontal = Metrics.space8),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space6),
    ) {
        Box(modifier = Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawCircle(
                    color = tint,
                    radius = size.minDimension / 2f - 2.dp.toPx(),
                    style = Stroke(width = 2.dp.toPx()),
                )
            }
            Icon(icon, contentDescription = name, tint = tint, modifier = Modifier.size(22.dp))
        }
        Text(name, style = NoopType.footnote, color = Palette.textSecondary, maxLines = 1)
        metrics.forEach { (label, value) ->
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    value ?: "–",
                    style = NoopType.captionNumber,
                    color = if (value == null) Palette.textTertiary else Palette.textPrimary,
                    maxLines = 1,
                )
                Text(label, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
            }
        }
    }
}
