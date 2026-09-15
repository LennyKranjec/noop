package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Bolt
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.noop.R
import com.noop.data.DailyMetric
import com.noop.widget.StressPoint
import com.noop.widget.StressWidgetProducer
import com.noop.widget.WidgetSnapshotStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// MARK: - Stress & Energy — Today's stress read, and what is left of the day's charge
//
// Two rows, both fed from data this app already computes; neither invents a number.
//
//   · THE STRESS CARD reads the SAME intraday curve the stress widget publishes
//     ([StressWidgetProducer]), so this card, the widget and the Stress screen cannot
//     disagree about the day. Highest / Lowest / Average are taken across the SCORED hours
//     only; an hour the motion gate masked or that had too little signal carries a null
//     level and is skipped rather than counted as calm. With nothing scored yet every
//     figure reads "–" and the dial shows its bare scale — the honest state, not a zero.
//
//   · THE ENERGY BAR is charge minus effort, drawn over the charge it started from:
//
//        backing (lighter grey) = today's charge           (recovery, 0–100)
//        fill    (yellow)       = charge − effort, floored at 0
//
//     so at zero effort the yellow reaches the full charge, and once effort has matched the
//     charge the yellow is gone. THE OPTIMUM IS THE DAY'S OWN CHARGE, which is the only
//     figure in this app that can play that part without a new number being invented for it:
//     both scales are already 0–100 ([StrainScorer.maxStrain]), and a charge of 62 spent by
//     an effort of 62 is exactly the day this bar is meant to describe. It is a READ-OUT of
//     two existing scores, not a training recommendation, and nothing downstream consumes it.

/** Stress is scored 0–3 ([DaytimeStress]); the dial and the ramp both work in that domain. */
private const val STRESS_MAX = 3.0

private val stressUpdatedFmt: DateTimeFormatter =
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
        .withLocale(Locale.getDefault()).withZone(ZoneId.systemDefault())

/** What the card renders, reduced from the curve so the drawing has no arithmetic left in it. */
internal data class StressToday(
    val highest: Double?,
    val lowest: Double?,
    val average: Double?,
    /** The most recent SCORED hour — the dial's value and the "last updated" stamp. */
    val latest: Double?,
    val latestTs: Long?,
) {
    val hasAny: Boolean get() = average != null

    companion object {
        val EMPTY = StressToday(null, null, null, null, null)

        /** Scored hours only: a null level is "not read", which is not a low reading. */
        fun from(points: List<StressPoint>): StressToday {
            val scored = points.filter { it.level != null }
            if (scored.isEmpty()) return EMPTY
            val levels = scored.mapNotNull { it.level }
            val last = scored.maxByOrNull { it.ts }
            return StressToday(
                highest = levels.max(),
                lowest = levels.min(),
                average = levels.average(),
                latest = last?.level,
                latestTs = last?.ts,
            )
        }
    }
}

/**
 * The Today "Stress & Energy" block.
 *
 * [day] is the day Today is showing, so scrolling back a day moves the energy bar with it. The
 * stress curve is TODAY's by contract (the producer scores the current local day and the snapshot
 * is day-guarded on load), so on a past day the card renders its empty state rather than pinning
 * yesterday's stress to a day it did not belong to.
 */
@Composable
internal fun StressEnergySection(
    viewModel: AppViewModel,
    day: DailyMetric?,
    isToday: Boolean,
    onOpenStress: () -> Unit,
) {
    val context = LocalContext.current
    var curve by remember { mutableStateOf<List<StressPoint>>(emptyList()) }

    // Seeded from the curve already on disk so a cold start does not show "–" for a day this app has
    // already scored. Same read, and the same reason, as the hosted stress card in TodayScreen.
    LaunchedEffect(Unit) {
        if (curve.isNotEmpty()) return@LaunchedEffect
        val banked = withContext(Dispatchers.IO) {
            runCatching { WidgetSnapshotStore.load(context).stressSeries }.getOrDefault(emptyList())
        }
        if (banked.isNotEmpty() && curve.isEmpty()) curve = banked
    }

    // Re-scored on the producer's own cadence, gated on STARTED: a LaunchedEffect outlives the
    // screen going background, and the connection service is already scoring on this interval there.
    // The producer memoises by fingerprint, so an unchanged day costs one indexed count, not a rescan.
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(isToday, viewModel.activeStrapId, lifecycleOwner) {
        if (!isToday) {
            curve = emptyList()
            return@LaunchedEffect
        }
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            while (true) {
                // Null is the producer's "nothing to say right now" — keep what we had rather than
                // blanking a card somebody is looking at.
                StressWidgetProducer.todayCurve(viewModel.repo, viewModel.activeStrapId)
                    ?.let { curve = it.points }
                delay(StressWidgetProducer.RESCORE_INTERVAL_MS)
            }
        }
    }

    val stress = remember(curve) { StressToday.from(curve) }

    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        TodayStressCard(stress = stress, onOpen = onOpenStress)
        EnergyBalanceBar(charge = day?.recovery, effort = day?.strain)
    }
}

// MARK: - The stress card

@Composable
private fun TodayStressCard(stress: StressToday, onOpen: () -> Unit) {
    NoopCard(modifier = Modifier.clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(Metrics.space4),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(Metrics.space8)
                            .clip(RoundedCornerShape(Metrics.cornerPill))
                            .background(
                                if (stress.hasAny) StressRamp.color(stress.latest ?: 0.0)
                                else Palette.textTertiary,
                            ),
                    )
                    Spacer(Modifier.width(Metrics.space8))
                    Text(
                        uiString(R.string.today_stress_title),
                        style = NoopType.headline,
                        color = Palette.textPrimary,
                    )
                }
                Text(
                    stress.latestTs?.let {
                        uiString(
                            R.string.today_stress_last_updated,
                            stressUpdatedFmt.format(Instant.ofEpochSecond(it)),
                        )
                    } ?: uiString(R.string.today_stress_no_reading),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
                Spacer(Modifier.height(Metrics.space10))
                Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    StressStat(uiString(R.string.today_stress_highest), stress.highest, Modifier.weight(1f))
                    StatDivider()
                    StressStat(uiString(R.string.today_stress_lowest), stress.lowest, Modifier.weight(1f))
                    StatDivider()
                    StressStat(uiString(R.string.today_stress_average), stress.average, Modifier.weight(1f))
                }
            }
            Spacer(Modifier.width(Metrics.space12))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowForward,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                StressTickDial(level = stress.latest, diameter = 96.dp)
            }
        }
    }
}

@Composable
private fun StressStat(label: String, value: Double?, modifier: Modifier = Modifier) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
        Text(
            value?.let { String.format(Locale.US, "%.1f", it) } ?: EM_DASH,
            style = NoopType.bodyNumber,
            color = if (value == null) Palette.textTertiary else Palette.textPrimary,
        )
        Text(label, style = NoopType.footnote, color = Palette.textTertiary, maxLines = 1)
    }
}

@Composable
private fun StatDivider() {
    Box(
        modifier = Modifier
            .padding(horizontal = Metrics.space8)
            .width(Metrics.divider)
            .height(Metrics.space24)
            .background(Palette.hairline),
    )
}

/**
 * The radial tick dial: the stress scale drawn as spokes around an open gauge, lit up to [level].
 *
 * Every tick carries its OWN place on the ramp, so the instrument shows the scale it is reading
 * against even before it has a reading — which is the state a fresh day is in. Unlit ticks keep
 * that colour at a low alpha rather than going grey, so the dial reads as one instrument dimmed,
 * not two different gauges.
 */
@Composable
private fun StressTickDial(level: Double?, diameter: Dp) {
    val ticks = 40
    val startDeg = 150f
    val spanDeg = 240f
    val lit = level?.let { (it / STRESS_MAX).coerceIn(0.0, 1.0) } ?: 0.0
    val tickColors = List(ticks) { i ->
        StressRamp.color(STRESS_MAX * i / (ticks - 1).toDouble())
    }
    val inkPrimary = Palette.textPrimary
    val inkTertiary = Palette.textTertiary

    Box(modifier = Modifier.size(diameter), contentAlignment = Alignment.Center) {
        Canvas(modifier = Modifier.fillMaxWidth().fillMaxHeight()) {
            val radius = min(size.width, size.height) / 2f
            val outer = radius * 0.96f
            val inner = radius * 0.72f
            val stroke = max(1.5f, radius * 0.055f)
            repeat(ticks) { i ->
                val t = i / (ticks - 1).toFloat()
                val angle = Math.toRadians((startDeg + spanDeg * t).toDouble())
                val cosA = cos(angle).toFloat()
                val sinA = sin(angle).toFloat()
                val isLit = t <= lit.toFloat()
                drawLine(
                    color = tickColors[i].copy(alpha = if (isLit) 1f else 0.22f),
                    start = Offset(center.x + cosA * inner, center.y + sinA * inner),
                    end = Offset(center.x + cosA * outer, center.y + sinA * outer),
                    strokeWidth = stroke,
                    cap = StrokeCap.Round,
                )
            }
        }
        Text(
            level?.let { String.format(Locale.US, "%.1f", it) } ?: EM_DASH,
            style = NoopType.number(if (level == null) 18f else 22f),
            color = if (level == null) inkTertiary else inkPrimary,
            textAlign = TextAlign.Center,
        )
    }
}

// MARK: - The energy bar

/**
 * Charge minus effort, over the charge it started from. See the file header for the model.
 *
 * Both inputs are optional and are treated as unknown rather than zero: with no charge scored there
 * is no budget to draw, so the bar renders its empty track and says "–" instead of claiming 0 %.
 */
@Composable
private fun EnergyBalanceBar(charge: Double?, effort: Double?) {
    val chargeFrac = charge?.let { (it / 100.0).coerceIn(0.0, 1.0) }
    // Effort is only ever subtractive here, and only down to zero: a day that spent more than its
    // charge is an empty bar, never a negative one.
    val remaining = if (charge == null) null else (charge - (effort ?: 0.0)).coerceIn(0.0, charge)
    val remainingFrac = remaining?.let { (it / 100.0).coerceIn(0.0, 1.0) }

    NoopCard(padding = Metrics.space12) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.Bolt,
                contentDescription = null,
                tint = Palette.signalYellow,
                modifier = Modifier.size(Metrics.iconSmall),
            )
            Spacer(Modifier.width(Metrics.space10))
            EnergyTicks(
                backing = chargeFrac?.toFloat() ?: 0f,
                fill = remainingFrac?.toFloat() ?: 0f,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(Metrics.space10))
            Text(
                remaining?.let { "${it.toInt()}%" } ?: EM_DASH,
                style = NoopType.bodyNumber,
                color = if (remaining == null) Palette.textTertiary else Palette.textPrimary,
            )
        }
    }
}

/**
 * The three-state tick bar: yellow to [fill], the lighter "charge you started with" grey on to
 * [backing], the empty track beyond it. Drawn as discrete ticks (not one solid rail) so the two
 * greys stay legible against each other at a glance.
 */
@Composable
private fun EnergyTicks(backing: Float, fill: Float, modifier: Modifier = Modifier) {
    val ticks = 34
    val yellow = Palette.signalYellow
    val chargeGrey = Palette.textSecondary.copy(alpha = 0.55f)
    val emptyGrey = Palette.hairlineStrong

    Canvas(modifier = modifier.height(18.dp)) {
        val gap = size.width / (ticks * 2f - 1f)
        val barWidth = gap
        repeat(ticks) { i ->
            val t = (i + 1) / ticks.toFloat()
            val color = when {
                t <= fill -> yellow
                t <= backing -> chargeGrey
                else -> emptyGrey
            }
            val x = i * (barWidth + gap) + barWidth / 2f
            drawLine(
                color = color,
                start = Offset(x, 0f),
                end = Offset(x, size.height),
                strokeWidth = barWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}

private const val EM_DASH = "–"
