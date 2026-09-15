package com.noop.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.noop.ai.DailyMission
import com.noop.ai.DailyMissionStore

// MARK: - Today's mission, as one running line
//
// The mission used to be a card of its own under the hero. It is one sentence, and a sentence does not
// need a heading, a surface and a section slot — that card cost more of the screen than anything else
// on Today per word it carried. It now runs above the three scores as a single line.
//
// IT SCROLLS BECAUSE IT HAS TO. A mission is two or three sentences and the strip is one line high, so
// the choice is between an ellipsis and movement. An ellipsis hides the half that says what to do.
//
// SPEED IS PER CHARACTER, not a fixed duration: a fixed one makes a short mission crawl and a long one
// bolt past unreadably. This holds the reading speed constant and lets the duration follow the length.
//
// A LINE THAT FITS DOES NOT MOVE. Motion with nothing to reveal is decoration, and the app's own motion
// gate ([rememberPoseStill] — Reduce Motion, battery saver, quiet hours) stills it regardless, in which
// case it truncates rather than scrolls. Truncated-and-still beats moving-when-asked-not-to.

@Composable
internal fun MissionMarquee(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var mission by remember { mutableStateOf<DailyMission?>(null) }

    // Read on every entry to Today, not once: the 06:45 job may have written one while the app sat in
    // the background, and the process outlives a night.
    LaunchedEffect(Unit) {
        mission = DailyMissionStore.today(context)
    }

    val text = mission?.text?.takeIf { it.isNotBlank() } ?: return
    val still = rememberPoseStill()

    var viewportPx by remember { mutableIntStateOf(0) }

    // MEASURED UNCONSTRAINED, with a text measurer, rather than read back off the laid-out Text.
    //
    // The first cut took the width from `onSizeChanged` on the static branch — but that Text is laid out
    // with `fillMaxWidth`, so its measured width IS the viewport, always. `textPx > viewportPx` could
    // therefore never be true and the line never scrolled: it just sat there truncated, which looked
    // exactly like a marquee that had been asked not to move.
    val style = NoopType.footnote.copy(fontWeight = FontWeight.Medium)
    val measurer = rememberTextMeasurer()
    val textPx = remember(text, style, measurer) {
        measurer.measure(text = AnnotatedString(text), style = style, softWrap = false).size.width
    }
    val overflows = textPx > viewportPx && viewportPx > 0

    Box(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space4)
            .clipToBounds()
            .onSizeChanged { viewportPx = it.width },
        contentAlignment = Alignment.CenterStart,
    ) {
        if (!overflows || still) {
            Text(
                text = text,
                style = style,
                color = Palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
        } else {
            val density = LocalDensity.current
            val travelPx = textPx + viewportPx
            val millis = with(density) { (travelPx / density.density) }
                .let { dp -> (dp / SCROLL_DP_PER_SECOND * 1000f).toInt() }
                .coerceIn(MIN_MILLIS, MAX_MILLIS)
            val transition = rememberInfiniteTransition(label = "missionMarquee")
            val progress by transition.animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(
                    // LINEAR and RESTART: an eased loop slows at both ends, which on a line of text
                    // reads as the app stuttering rather than as a considered motion.
                    animation = tween(durationMillis = millis, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart,
                ),
                label = "missionOffset",
            )
            // Enters from the right edge and leaves past the left, so the loop has no visible seam.
            val offsetPx = (viewportPx - progress * travelPx).toInt()
            Text(
                text = text,
                style = style,
                color = Palette.textSecondary,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.offsetPx(offsetPx),
            )
        }
    }
}

/** A whole-pixel horizontal offset that leaves the text's own measurement alone. */
private fun Modifier.offsetPx(x: Int): Modifier = layout { measurable, constraints ->
    // Measured UNBOUNDED, so the line's true width is known even when it is wider than the strip —
    // measured against the viewport it would wrap or clip and there would be nothing to scroll.
    val placeable = measurable.measure(constraints.copy(maxWidth = Int.MAX_VALUE))
    layout(constraints.maxWidth, placeable.height) { placeable.place(x, 0) }
}

/** Reading speed, in dp of travel per second. Slow enough to read a sentence at arm's length. */
private const val SCROLL_DP_PER_SECOND = 42f

private const val MIN_MILLIS = 6_000
private const val MAX_MILLIS = 40_000
