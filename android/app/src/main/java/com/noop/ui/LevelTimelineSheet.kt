package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.LevelPoint
import com.noop.analytics.LevelRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - Where the level has been
//
// The panel the radar opens, hanging directly under it. One line, the same [LineChart] every other
// graph in the app uses, with the same range control — so a wearer who has learned to read the Trends
// charts already knows how to read this one.
//
// THE LINE IS RE-COMPUTED, NOT STORED. Each day is the formula run over the data as it stood that day,
// against the ONE frozen scale. A cached level would have been measured against whatever scale existed
// on the day it was written, and the curve would then show the yardstick moving as though the body had.
//
// THE Y-AXIS IS PINNED TO 0–100, which is the level's real domain. Auto-scaling would redraw a steady
// month as a mountain range, and the whole point of this panel is to answer "am I actually moving".

/** The ranges offered, matching the app's other daily charts. */
private enum class LevelSpan(val days: Int, val labelRes: Int) {
    WEEK(7, R.string.level_span_week),
    MONTH(30, R.string.level_span_month),
    QUARTER(90, R.string.level_span_quarter),
    YEAR(365, R.string.level_span_year),

    /**
     * Everything stored.
     *
     * A ceiling rather than a true "all": ten years is past any history this app can hold, and
     * [LevelRepository.history] clamps the span to the earliest day that actually exists — so this asks
     * for more than there is and gets exactly what there is.
     */
    ALL(3650, R.string.level_span_all),
}

@Composable
internal fun LevelTimelineSheet(
    viewModel: AppViewModel,
    /** Today's breakdown, for the system's own line at the head of the panel. */
    breakdown: com.noop.analytics.LevelBreakdown?,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var span by remember { mutableStateOf(LevelSpan.MONTH) }
    var points by remember { mutableStateOf<List<LevelPoint>?>(null) }

    // THE SYSTEM'S READING OF THE WEIGHTING, at the head of the panel. Keyed on the breakdown so it is
    // rewritten when the level moves and at most once a day — see [LevelCoachNote].
    var note by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(breakdown?.level) {
        val b = breakdown ?: return@LaunchedEffect
        val key = com.noop.ai.LevelCoachNote.fingerprint(b)
        // The stored line first, so an unchanged level paints at once; only a changed one reaches the
        // model, and that happens off the main thread.
        note = com.noop.ai.LevelCoachNote.stored(context, key)
        if (note == null) {
            note = withContext(Dispatchers.IO) {
                runCatching { com.noop.ai.LevelCoachNote.forBreakdown(context, b) }.getOrNull()
            }
        }
    }

    LaunchedEffect(span, viewModel.activeStrapId) {
        points = null
        points = withContext(Dispatchers.IO) {
            runCatching {
                LevelRepository.history(context, viewModel.repo, viewModel.activeStrapId, span.days)
            }.getOrDefault(emptyList())
        }
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space12),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                // SHADOW FIRST, then clip: `shadow` carries the shape itself, and a panel that hangs
                // over whatever screen is beneath it needs the lift or it reads as a hole cut in the
                // content rather than as something laid on top of it.
                .shadow(PANEL_ELEVATION, RoundedCornerShape(Metrics.cardRadius))
                .clip(RoundedCornerShape(Metrics.cardRadius))
                .background(Palette.surfaceRaised)
                .padding(Metrics.space12),
            verticalArrangement = Arrangement.spacedBy(Metrics.space8),
        ) {
            // THE HEAD OF THE PANEL IS THE SYSTEM TALKING, not a label. "Level over time" said only what
            // the chart underneath already shows; a line naming which parts are carrying the level and
            // which is costing it says the thing the radar cannot. The plain heading is kept as the
            // fallback for when there is no model, no consent, or no line yet.
            Row(verticalAlignment = Alignment.Top) {
                Icon(
                    Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier
                        .padding(top = 2.dp, end = Metrics.space8)
                        .size(Metrics.iconTiny),
                )
                Box(modifier = Modifier.weight(1f)) {
                    note?.let { CoachMarkdown(text = it, color = Palette.textSecondary) }
                        ?: Text(
                            uiString(R.string.level_timeline_title),
                            style = NoopType.footnote,
                            color = Palette.textSecondary,
                        )
                }
                NoopButton(
                    text = uiString(R.string.level_timeline_close),
                    kind = NoopButtonKind.Tertiary,
                    onClick = onDismiss,
                )
            }

            SegmentedPillControl(
                items = LevelSpan.entries.toList(),
                selection = span,
                label = { uiString(it.labelRes) },
                onSelect = { span = it },
                adaptsToAvailableWidth = true,
                modifier = Modifier.fillMaxWidth(),
            )

            val data = points
            when {
                data == null -> Box(
                    modifier = Modifier.fillMaxWidth().height(CHART_HEIGHT),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        uiString(R.string.level_timeline_loading),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
                // Two points is the fewest that can be a line. One is a dot, and drawing it as a flat
                // line across the panel would say the level had been steady all month.
                data.size < 2 -> Box(
                    modifier = Modifier.fillMaxWidth().height(CHART_HEIGHT),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        uiString(R.string.level_timeline_thin),
                        style = NoopType.caption,
                        color = Palette.textTertiary,
                    )
                }
                else -> {
                    // THE AXIS IS THE POINT OF A FIXED DOMAIN. Pinning the chart to 0–100 stops a steady
                    // month being redrawn as a mountain range, but without labelled rules the reader still
                    // cannot say whether the line is sitting at 40 or at 80 — they can only see its shape.
                    // The gridlines are what turn the fixed scale into a readable one.
                    Box(modifier = Modifier.fillMaxWidth().height(CHART_HEIGHT)) {
                        LevelGrid()
                        LineChart(
                            values = data.map { it.level },
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(start = AXIS_GUTTER),
                            color = Palette.accent,
                            selectionEnabled = true,
                            selectionLabels = data.map { dayLabel(it.day) + " · " + it.level.roundToInt() },
                            yDomain = 0.0..100.0,
                        )
                    }
                    // THE X AXIS. Three dates, not thirty: the line is evenly spaced across the span, so
                    // the ends and the middle are enough to place any point on it by eye, and a label per
                    // day would be unreadable at 90d and redundant at 7d.
                    //
                    // Inset by the same gutter the chart is, so the first label starts where the first
                    // reading is drawn and the last ends where the last one does.
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(start = AXIS_GUTTER),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        listOf(
                            data.first().day,
                            data[data.size / 2].day,
                            data.last().day,
                        ).forEach { day ->
                            Text(
                                text = dayLabel(day),
                                style = NoopType.overline,
                                color = Palette.textTertiary,
                                maxLines = 1,
                            )
                        }
                    }
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        FootNumber(
                            uiString(R.string.level_timeline_low),
                            data.minOf { it.level }.roundToInt(),
                        )
                        FootNumber(
                            uiString(R.string.level_timeline_mean),
                            data.map { it.level }.average().roundToInt(),
                        )
                        FootNumber(
                            uiString(R.string.level_timeline_high),
                            data.maxOf { it.level }.roundToInt(),
                        )
                    }
                }
            }
        }
    }
}

/**
 * The y axis: a labelled dotted rule at every quarter of the level's own 0–100 range.
 *
 * DRAWN ON THE CHART'S OWN SCALE, through the same inset [LineChart] uses ([LINE_CHART_V_PAD]) and the
 * same [yForValue] helper the reference rules go through. A gridline computed against its own idea of
 * the plot's height would sit a few pixels off and quietly mislabel the line it is there to explain —
 * which is exactly the failure a shared helper exists to prevent.
 *
 * The labels sit in their own gutter rather than over the plot: laid on top they collide with the line
 * at precisely the values the reader is trying to check.
 */
@Composable
private fun LevelGrid() {
    // NOT `Palette.hairline`, and not a one-PIXEL stroke. The first cut used both, and between them the
    // axis was invisible: hairline is #21304A, a dark navy meant to divide rows on the near-black base
    // surface, and this panel is drawn on surfaceRaised (#25292C) — the two are almost the same colour.
    // A single physical pixel of it on a 440dpi screen is sub-hairline on top of that. The rule is now a
    // dimmed text colour at a real dp width, which reads on both themes.
    val ruleColor = Palette.textTertiary.copy(alpha = 0.40f)
    val labelColor = Palette.textSecondary
    val density = LocalDensity.current
    val labelPaint = remember(labelColor, density) {
        android.graphics.Paint().apply {
            isAntiAlias = true
            textSize = with(density) { 10.sp.toPx() }
            color = labelColor.toArgb()
            textAlign = android.graphics.Paint.Align.RIGHT
        }
    }
    val dash = remember(density) {
        // Dashes in dp, not raw pixels: a 5px gap is a different-looking dash on every screen density.
        with(density) { PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx()), 0f) }
    }

    Canvas(modifier = Modifier.fillMaxSize()) {
        val gutter = AXIS_GUTTER.toPx()
        // Two points, because that is what the chart itself needs before it will plot anything, and the
        // axis has to agree with the chart about where 0 and 100 are.
        val domainProbe = listOf(0.0, 100.0)
        AXIS_TICKS.forEach { tick ->
            val y = yForValue(
                value = tick.toDouble(),
                values = domainProbe,
                height = size.height,
                topPad = LINE_CHART_V_PAD,
                bottomPad = LINE_CHART_V_PAD,
                yDomain = 0.0..100.0,
            ) ?: return@forEach
            drawLine(
                color = ruleColor,
                start = Offset(gutter, y),
                end = Offset(size.width, y),
                strokeWidth = RULE_WIDTH.toPx(),
                pathEffect = dash,
            )
            drawContext.canvas.nativeCanvas.drawText(
                tick.toString(),
                gutter - LABEL_GAP.toPx(),
                // Nudged onto the rule's own line: drawText puts the BASELINE at y, so the glyphs would
                // otherwise sit entirely above the rule they belong to.
                y + labelPaint.textSize / 3f,
                labelPaint,
            )
        }
    }
}

/** Where the rules are drawn. Quarters of the level's range — five lines is an axis, nine is graph paper. */
private val AXIS_TICKS = listOf(0, 25, 50, 75, 100)

/** The strip reserved for the labels, so they never overlap the line they are there to explain. */
private val AXIS_GUTTER = 26.dp

/** Breathing room between a label and the rule it names. */
private val LABEL_GAP = 4.dp

/** In DP. A raw `1f` here is one physical pixel, which is invisible on a dense screen. */
private val RULE_WIDTH = 1.dp

@Composable
private fun FootNumber(label: String, value: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value.toString(), style = NoopType.captionNumber, color = Palette.textPrimary, fontWeight = FontWeight.Bold)
        Text(label, style = NoopType.overline, color = Palette.textTertiary)
    }
}

private val CHART_HEIGHT = 128.dp

/** How far the panel lifts off the screen behind it. Matches the radar plate that opens it. */
private val PANEL_ELEVATION = 10.dp

private fun dayLabel(day: String): String = runCatching {
    LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
}.getOrDefault(day)
