package com.noop.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.MeditationStore
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

// MARK: - The meditation log, at the top of Focus
//
// Three things, in the order they answer: how long you have sat ALTOGETHER, whether you have sat on each
// of the last three days, and a way to sit now.
//
// THE THREE CIRCLES ARE THE LEVEL'S OWN WINDOW. They are not a streak — a streak breaks and shames, and
// this is a rolling three days: the oldest circle empties as it falls past the third, which is exactly
// the figure [LevelEngine.focus] multiplies the calm score by. What is on screen IS the input, so the
// wearer can see why their focus score moved rather than being told.
//
// THE TIMER MEASURES, IT DOES NOT COUNT DOWN. There is no target length here and inventing one would be
// a prescription nobody asked for: start it, sit, stop it, and what was actually sat is what is logged.
//
// THE BIN DELETES THE DAY, and it is the wearer's own request — they wanted to be able to throw away a
// session that went wrong and sit it again properly. It clears the day rather than the last session,
// because the store holds a day's total and subtracting a session it does not remember would be
// arithmetic on a guess. See [MeditationStore.clear].

@Composable
internal fun MeditationCard(viewModel: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val seq by MeditationStore.mutationSeq.collectAsStateWithLifecycle()

    var lifetime by remember { mutableStateOf(0.0) }
    var window by remember { mutableStateOf(List(MeditationStore.WINDOW_DAYS) { 0.0 }) }
    var runningSince by remember { mutableStateOf<Long?>(null) }
    var elapsed by remember { mutableIntStateOf(0) }
    // What the last stop did. Null until they have stopped one, and cleared the moment they start
    // another — a stale "too short" hanging over a session in progress would be the wrong news.
    var lastOutcome by remember { mutableStateOf<MeditationStore.Outcome?>(null) }

    LaunchedEffect(seq, viewModel.activeStrapId) {
        lifetime = MeditationStore.lifetimeMinutes(viewModel.repo)
        window = MeditationStore.window(viewModel.repo)
    }

    // The stopwatch. A wall-clock difference rather than an accumulated tick count, so a second the
    // phone spent asleep is still a second the wearer spent sitting.
    LaunchedEffect(runningSince) {
        val start = runningSince ?: run { elapsed = 0; return@LaunchedEffect }
        while (true) {
            elapsed = ((System.currentTimeMillis() - start) / 1000L).toInt()
            delay(250)
        }
    }

    val doneToday = window.lastOrNull()?.let { it > 0.0 } ?: false
    val running = runningSince != null

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            // 1 · The headline: everything ever sat.
            AnimatedMinutes(minutes = lifetime, running = running, elapsedSeconds = elapsed)

            // 2 · The window, and the controls that fill it.
            Row(verticalAlignment = Alignment.CenterVertically) {
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.space8)) {
                    window.forEachIndexed { i, minutes ->
                        DayCircle(
                            lit = minutes > 0.0,
                            // The last circle is today, and it is the one the buttons act on.
                            isToday = i == window.lastIndex,
                        )
                    }
                }
                Spacer(Modifier.weight(1f))

                // START / STOP. Disabled once the day is logged — the wearer asked for exactly one
                // meditation a day to count, and a button that runs a timer whose result is thrown away
                // would be a control that lies about what it does.
                RoundAction(
                    icon = if (running) Icons.Filled.Stop else Icons.Filled.PlayArrow,
                    tint = if (running) Palette.statusWarning else Palette.statusPositive,
                    enabled = running || !doneToday,
                    description = uiString(
                        if (running) R.string.meditation_stop else R.string.meditation_start,
                    ),
                ) {
                    val start = runningSince
                    if (start == null) {
                        SystemHaptics.play(context, SystemHaptics.Cue.TAP)
                        lastOutcome = null
                        runningSince = System.currentTimeMillis()
                    } else {
                        val seconds = ((System.currentTimeMillis() - start) / 1000L).toInt()
                        runningSince = null
                        SystemHaptics.play(context, SystemHaptics.Cue.CONFIRM)
                        scope.launch {
                            lastOutcome = MeditationStore.log(viewModel.repo, seconds).outcome
                            lifetime = MeditationStore.lifetimeMinutes(viewModel.repo)
                            window = MeditationStore.window(viewModel.repo)
                        }
                    }
                }

                Spacer(Modifier.width(Metrics.space8))

                // THE BIN. Only live when there is something to throw away, and never while the timer is
                // running — stopping is what the stop button is for.
                RoundAction(
                    icon = Icons.Filled.Delete,
                    tint = Palette.statusCritical,
                    enabled = doneToday && !running,
                    description = uiString(R.string.meditation_delete),
                ) {
                    SystemHaptics.play(context, SystemHaptics.Cue.SELECT)
                    scope.launch {
                        lastOutcome = null
                        MeditationStore.clear(viewModel.repo)
                        lifetime = MeditationStore.lifetimeMinutes(viewModel.repo)
                        window = MeditationStore.window(viewModel.repo)
                    }
                }
            }

            // The footer says what just happened, and the two FAILURE cases outrank the standing hints:
            // a session that was not stored has to say so, or the button reads as broken.
            val outcome = lastOutcome
            Text(
                text = when {
                    running -> uiString(R.string.meditation_running)
                    outcome == MeditationStore.Outcome.TOO_SHORT ->
                        uiString(R.string.meditation_too_short, MeditationStore.MIN_SESSION_SECONDS)
                    outcome == MeditationStore.Outcome.FAILED -> uiString(R.string.meditation_failed)
                    doneToday -> uiString(R.string.meditation_done_today)
                    else -> uiString(R.string.meditation_window_hint)
                },
                style = NoopType.caption,
                color = when (outcome) {
                    MeditationStore.Outcome.TOO_SHORT,
                    MeditationStore.Outcome.FAILED,
                    -> if (running) Palette.textTertiary else Palette.statusWarning
                    else -> Palette.textTertiary
                },
            )
        }
    }
}

/**
 * The lifetime total, which moves rather than jumps when a session lands.
 *
 * While the timer runs it shows the total PLUS the seconds so far, so the figure the wearer is watching
 * is the one the session is adding to. That is a live reading, not a stored one — nothing is written
 * until they stop.
 */
@Composable
private fun AnimatedMinutes(minutes: Double, running: Boolean, elapsedSeconds: Int) {
    val target = (minutes + if (running) elapsedSeconds / 60.0 else 0.0).toFloat()
    val shown by animateFloatAsState(
        targetValue = target,
        // Slow enough to read as counting, quick enough that it has settled before they look away.
        animationSpec = tween(durationMillis = if (running) 260 else 900),
        label = "meditationMinutes",
    )
    Column {
        Text(
            uiString(R.string.meditation_total_label),
            style = NoopType.overline,
            color = Palette.textSecondary,
        )
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = shown.roundToInt().toString(),
                style = NoopType.title1,
                color = Palette.textPrimary,
                fontWeight = FontWeight.Bold,
            )
            Text(
                text = uiString(R.string.meditation_minutes_unit),
                style = NoopType.footnote,
                color = Palette.textSecondary,
                modifier = Modifier.padding(start = Metrics.space4, bottom = 3.dp),
            )
            if (running) {
                Spacer(Modifier.weight(1f))
                Text(
                    text = clock(elapsedSeconds),
                    style = NoopType.title2,
                    color = Palette.statusPositive,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

/** One day of the window. Lit with a green dot when it carried a meditation. */
@Composable
private fun DayCircle(lit: Boolean, isToday: Boolean) {
    Box(
        modifier = Modifier
            .size(CIRCLE)
            .clip(CircleShape)
            .background(Palette.surfaceInset)
            .border(
                width = if (isToday) 1.5.dp else 1.dp,
                color = if (isToday) Palette.textSecondary else Palette.hairline,
                shape = CircleShape,
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (lit) {
            Box(
                modifier = Modifier
                    .size(DOT)
                    .clip(CircleShape)
                    .background(Palette.statusPositive),
            )
        }
    }
}

/** A circular icon button. Dim and inert when disabled rather than absent, so the control can be learnt. */
@Composable
private fun RoundAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    enabled: Boolean,
    description: String,
    onClick: () -> Unit,
) {
    val alpha = if (enabled) 1f else 0.28f
    Box(
        modifier = Modifier
            .size(BUTTON)
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f * alpha))
            .border(1.dp, tint.copy(alpha = 0.55f * alpha), CircleShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = description,
            tint = tint.copy(alpha = alpha),
            modifier = Modifier.size(Metrics.iconSmall),
        )
    }
}

private val CIRCLE = 26.dp
private val DOT = 12.dp
private val BUTTON = 40.dp

/** `m:ss`, or `h:mm:ss` once a session runs past the hour. */
private fun clock(seconds: Int): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    val s = seconds % 60
    return if (h > 0) {
        String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s)
    } else {
        String.format(java.util.Locale.US, "%d:%02d", m, s)
    }
}

