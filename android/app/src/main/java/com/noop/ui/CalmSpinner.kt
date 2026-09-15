package com.noop.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

// MARK: - A waiting ring that is not in a hurry
//
// Material's CircularProgressIndicator sweeps AND rotates on a ~1.3 s cycle. At 16 dp, next to the
// word "Thinking", that reads as agitation — and the thing it is reporting on is a model that takes
// tens of seconds, so a frantic ring actively misrepresents the pace of the work.
//
// This is one arc at a constant width, turning once every [PERIOD_MS]. No sweep animation, so there
// is only one thing moving instead of two.
//
// Gated on NOOP's motion policy like every other animation: with reduce motion, power saving or
// quiet motion on, the arc is drawn once and stays put. A still ring beside "Thinking" still reads
// as busy, because the word does that work.

private const val PERIOD_MS = 2800

@Composable
internal fun CalmSpinner(
    modifier: Modifier = Modifier,
    size: Dp = 16.dp,
    strokeWidth: Dp = 2.dp,
    color: Color = Palette.accent,
) {
    val still = rememberPoseStill()
    val angle: Float = if (still) {
        -90f
    } else {
        val transition = rememberInfiniteTransition(label = "calm-spinner")
        val v by transition.animateFloat(
            initialValue = 0f,
            targetValue = 360f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = PERIOD_MS, easing = LinearEasing),
                repeatMode = RepeatMode.Restart,
            ),
            label = "calm-spinner-angle",
        )
        v - 90f
    }

    Canvas(modifier = modifier.size(size)) {
        val stroke = strokeWidth.toPx()
        val inset = stroke / 2f
        drawArc(
            color = color.copy(alpha = 0.18f),
            startAngle = 0f,
            sweepAngle = 360f,
            useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
        drawArc(
            color = color,
            startAngle = angle,
            sweepAngle = 90f,
            useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke),
            style = Stroke(width = stroke, cap = StrokeCap.Round),
        )
    }
}
