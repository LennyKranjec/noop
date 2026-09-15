package com.noop.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - The three scores, as rings
//
// Strain, Recovery and Sleep across the top of Today, each a ring with its figure in the middle, hairline
// dividers between them, and a footer strip carrying the day and where the numbers came from.
//
// WHAT THE ARC SHOWS IS THE VALUE, and that is a deliberate departure from the reference. The design this
// was drawn from puts a hatched band on the strain ring with white caps at its ends — a TARGET RANGE,
// which is a feature that app has and this one does not. Reproducing the band would have drawn a
// recommendation the app cannot make and has no number behind; the arc here is the reading itself, on the
// same geometry, in the same weight. Everything else — proportions, the inner disc, the type, the
// dividers, the footer — follows the reference.
//
// AN ABSENT SCORE IS DRAWN AS "–", with its ring left as bare track. Not zero: a day with no recovery
// reading and a day whose recovery was genuinely nil are different statements, and only the second one is
// a number.
//
// THE FOOTER'S RIGHT SIDE ANSWERS "ARE THESE CURRENT?". The reference puts a wordmark there, which is
// worth nothing to the wearer; three scores with no provenance invite exactly one question, so the source
// the day was resolved from is what sits in its place.

/** One ring's worth of input. [fraction] is 0–1 for the arc; [text] is what the middle reads. */
internal data class HeroScore(
    val labelRes: Int,
    val text: String,
    val fraction: Float?,
    val tint: Color,
    /**
     * An optional reference mark on the ring, 0-1 on the same scale as [fraction].
     *
     * The strain ring uses it for the day's OPTIMAL strain, so the arc can be read against the target
     * rather than against nothing: a 15.0 means something different on a 92 % recovery than on a 19 %,
     * and the number alone cannot say which. Null draws nothing — the other two rings have no target
     * this app can honestly name.
     */
    val mark: Float? = null,
)

@Composable
internal fun TodayTrioHero(
    scores: List<HeroScore>,
    dateLabel: String,
    /** Where the day's numbers were resolved from — "WHOOP", "Health Connect", and so on. */
    sourceLabel: String?,
    modifier: Modifier = Modifier,
    onTapScore: (Int) -> Unit = {},
) {
    // CLIPPED TO THE CARD'S OWN CURVE. The footer strip below is a plain filled row, and a fill does
    // not know about the rounded card it sits in — its square corners poked out past the curve at the
    // bottom, which is the ragged edge that showed up under the tile.
    //
    // The clip lives HERE rather than on the card, because clipping the card clipped its background out
    // of existence: that Box paints its own fill and border through `background(shape)` / `border(shape)`
    // and animates through `staggeredAppear`, and putting a layer in front of all three cost the fill.
    // Cutting the CHILD to the same radius fixes the corners and leaves the card's own painting alone.
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(HERO_CARD_RADIUS)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = Metrics.space16),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            scores.forEachIndexed { i, score ->
                if (i > 0) {
                    // The hairline between rings, inset top and bottom as in the reference so it reads as
                    // a divider rather than as a full-height column rule.
                    Box(
                        modifier = Modifier
                            .width(1.dp)
                            .height(DIVIDER_HEIGHT)
                            .background(Palette.hairline.copy(alpha = 0.7f)),
                    )
                }
                HeroRing(
                    score = score,
                    modifier = Modifier
                        .weight(1f)
                        .clickable { onTapScore(i) },
                )
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(1.dp)
                .background(Palette.hairline.copy(alpha = 0.7f)),
        )

        // The footer strip: a shade darker than the card, as in the reference.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Palette.surfaceBase.copy(alpha = 0.55f))
                .padding(horizontal = Metrics.space14, vertical = Metrics.space10),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.CalendarMonth,
                contentDescription = null,
                tint = Palette.textTertiary,
                modifier = Modifier.size(Metrics.iconTiny),
            )
            Text(
                text = dateLabel,
                style = NoopType.footnote,
                color = Palette.textTertiary,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = Metrics.space8),
                maxLines = 1,
            )
            Box(Modifier.weight(1f))
            if (sourceLabel != null) {
                Text(
                    text = sourceLabel,
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun HeroRing(score: HeroScore, modifier: Modifier = Modifier) {
    val lit = score.fraction != null
    val trackColor = Palette.surfaceInset
    val discColor = Palette.surfaceRaised.copy(alpha = 0.55f)
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(
            modifier = Modifier.size(RING_SIZE),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(modifier = Modifier.size(RING_SIZE)) {
                val stroke = RING_STROKE.toPx()
                val inset = stroke / 2f
                val d = min(size.width, size.height) - stroke
                val topLeft = Offset(inset, inset)
                val arcSize = Size(d, d)

                // The inner disc, which is what gives the reference its dial look — the figure sits ON
                // something rather than floating in a hole.
                drawCircle(color = discColor, radius = (d / 2f) - stroke * 0.55f)
                // The track, full circle.
                drawArc(
                    color = trackColor,
                    startAngle = 0f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = stroke, cap = StrokeCap.Butt),
                )
                // THE TARGET MARK, under the reading so a full arc never hides it. Drawn as a notch
                // across the track's own width rather than as a dot beside it: the mark has to be read
                // against the arc, and anything sitting outside the ring reads as decoration.
                score.mark?.takeIf { it > 0f }?.let { mark ->
                    val angle = Math.toRadians((START_ANGLE + 360f * mark.coerceIn(0f, 1f)).toDouble())
                    val r = d / 2f
                    val cx = size.width / 2f
                    val cy = size.height / 2f
                    val inner = r - stroke / 2f
                    val outer = r + stroke / 2f
                    drawLine(
                        color = Palette.textPrimary.copy(alpha = 0.85f),
                        start = Offset(
                            cx + (inner * kotlin.math.cos(angle)).toFloat(),
                            cy + (inner * kotlin.math.sin(angle)).toFloat(),
                        ),
                        end = Offset(
                            cx + (outer * kotlin.math.cos(angle)).toFloat(),
                            cy + (outer * kotlin.math.sin(angle)).toFloat(),
                        ),
                        strokeWidth = MARK_WIDTH.toPx(),
                        cap = StrokeCap.Round,
                    )
                }

                // The reading. Starts at twelve and runs clockwise, which is the direction a dial is read.
                score.fraction?.takeIf { it > 0f }?.let { frac ->
                    drawArc(
                        color = score.tint,
                        startAngle = START_ANGLE,
                        sweepAngle = 360f * frac.coerceIn(0f, 1f),
                        useCenter = false,
                        topLeft = topLeft,
                        size = arcSize,
                        style = Stroke(width = stroke, cap = StrokeCap.Round),
                    )
                }
            }
            Text(
                text = score.text,
                // Tabular figures, for the same reason the level has them: these count up, and
                // proportional digits make the number shuffle sideways as it does.
                style = NoopType.title2.copy(fontFeatureSettings = "tnum"),
                color = if (lit) Palette.textPrimary else Palette.textTertiary,
                fontWeight = FontWeight.Bold,
                fontSize = VALUE_SIZE,
            )
        }
        Text(
            text = uiString(score.labelRes),
            style = NoopType.body,
            color = Palette.textTertiary,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.padding(top = Metrics.space8),
            maxLines = 1,
        )
    }
}

/** Must equal the card's own `LIQUID_HERO_RADIUS`, or the footer cuts at a different curve than the card. */
private val HERO_CARD_RADIUS: Dp = 26.dp

/** Twelve o'clock. Compose measures arcs from three o'clock, so the origin is a quarter turn back. */
private const val START_ANGLE = -90f

private val RING_SIZE: Dp = 92.dp
private val RING_STROKE: Dp = 9.dp
private val DIVIDER_HEIGHT: Dp = 96.dp
private val VALUE_SIZE = 24.sp

/** The target notch. Thin enough to read as a mark, thick enough to survive a 92dp ring. */
private val MARK_WIDTH: Dp = 2.5.dp

/** WHOOP's strain ceiling. Their scale is 0-21, not 0-100, and the ring's arc is read against it. */
internal const val WHOOP_STRAIN_MAX = 21.0

/**
 * Day strain on WHOOP's own 0-21 scale.
 *
 * [cloud] is already on it and is used verbatim. [local] is this app's own effort figure, which lives
 * on whatever scale the wearer's preference puts it on, so it goes through the converter — the two must
 * not be mixed, or a fallback day would be drawn against a ceiling it was never measured against.
 */
internal fun heroStrain21(cloud: Double?, local: Double?): Double? =
    cloud ?: local?.let { UnitFormatter.effortValue(it, EffortScale.WHOOP).toDouble() }

/** A whole-number percentage, or "–" when the day has no reading. */
internal fun heroPercent(value: Double?): String =
    value?.let { "${it.roundToInt()}%" } ?: "–"

/** The 0–1 arc fraction for a 0–100 score. Null stays null, so the ring is left as bare track. */
internal fun heroFraction(value: Double?, max: Double = 100.0): Float? =
    value?.let { (it / max).coerceIn(0.0, 1.0).toFloat() }
