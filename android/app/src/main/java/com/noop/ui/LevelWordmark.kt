package com.noop.ui

import android.content.Context
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.gamify.AccountLevel
import java.time.LocalDate
import kotlin.math.roundToInt

// MARK: - The level badge in Today's header
//
// This took the wordmark's slot. It counts UP to the level once per day, out of focus and settling
// into focus as it lands — the reference behaviour, and the reason it is once per day rather than
// every visit: an animation that replays on every glance at the screen stops being an arrival and
// becomes a stutter you wait out.
//
// The count is gated on NOOP's motion policy like every other animation here: with reduce motion,
// power saving or quiet motion on, the number is simply there, already sharp. The blur is a no-op
// below Android 12 (`Modifier.blur` needs API 31), so on an older phone the count still runs — it
// just runs sharp, which is a degradation nobody has to be told about.

private const val PREFS = "noop_level_badge"
private const val KEY_LAST_PLAYED = "last_count_up_day"

/** True at most once per calendar day; records the day as it answers. */
private fun shouldPlayToday(context: Context): Boolean {
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    val today = LocalDate.now().toString()
    if (prefs.getString(KEY_LAST_PLAYED, null) == today) return false
    prefs.edit().putString(KEY_LAST_PLAYED, today).apply()
    return true
}

@Composable
internal fun LevelWordmark() {
    val context = LocalContext.current
    val level = AccountLevel.level()
    val still = rememberPoseStill()

    // Decided ONCE per composition entry: the pref write happens inside, so reading it in a
    // recomposition-sensitive place would consume the day's single play on a stray recomposition.
    val plays = remember { !still && shouldPlayToday(context) }
    var target by remember { mutableStateOf(if (plays) 0f else 1f) }
    LaunchedEffect(Unit) { if (plays) target = 1f }

    val t by animateFloatAsState(
        targetValue = target,
        animationSpec = tween(durationMillis = 1400, easing = LinearOutSlowInEasing),
        label = "level-count-up",
    )

    val shown = (level * t).roundToInt().coerceIn(0, level)
    // Out of focus at the start, sharp as it settles — the blur trails the count so the last digits
    // land readable rather than resolving after the number has stopped.
    val blurRadius = (1f - t) * 10f

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(
            uiString(R.string.level_badge_prefix),
            style = NoopType.overline,
            color = Palette.textTertiary,
        )
        Spacer(Modifier.width(Metrics.space6))
        Text(
            shown.toString(),
            style = NoopType.number(22f),
            color = Palette.textPrimary,
            modifier = if (blurRadius > 0.1f) Modifier.blur(blurRadius.dp) else Modifier,
        )
    }
}
