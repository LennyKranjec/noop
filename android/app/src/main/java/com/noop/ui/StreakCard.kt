package com.noop.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalFireDepartment
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.text.style.TextAlign
import com.noop.R
import com.noop.analytics.Streak
import com.noop.analytics.StreakKind
import com.noop.analytics.Streaks
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId

// MARK: - Streaks, with flames
//
// Three numbers, each a flame. The flame is the whole point: a digit is information, a lit flame is
// something you do not want to put out, and that difference is why streaks work at all.
//
// THE FLAME SAYS WHETHER TODAY IS BANKED. Lit and breathing = today already counts. Dim and still =
// the streak is running but today is not secured yet, which is a nudge that costs no words. Cold grey =
// nothing running. A streak UI that looks identical whether or not today is done is a streak UI that
// cannot tell you the one thing you open it for.

@Composable
internal fun StreakCard(viewModel: AppViewModel) {
    var streaks by remember { mutableStateOf<List<Streak>>(emptyList()) }

    LaunchedEffect(viewModel.activeStrapId) {
        streaks = withContext(Dispatchers.IO) {
            runCatching { readStreaks(viewModel) }.getOrDefault(emptyList())
        }
    }

    if (streaks.isEmpty()) return

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            SectionHeader(uiString(R.string.streak_title))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                streaks.forEach { streak -> StreakFlame(streak) }
            }
        }
    }
}

@Composable
private fun StreakFlame(streak: Streak) {
    val lit = streak.days > 0
    // Only a SECURED flame breathes. An animation on an at-risk streak would read as "all is well",
    // which is the opposite of what an unsecured day means.
    val transition = rememberInfiniteTransition(label = "flame")
    val flicker by transition.animateFloat(
        initialValue = 0.92f,
        targetValue = 1.06f,
        animationSpec = infiniteRepeatable(
            animation = tween(1400),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "flameScale",
    )
    // The app-wide motion gate, not just Reduce Motion: battery saver and quiet-motion have to be
    // able to still an animation that would otherwise run for as long as the card is on screen.
    val still = rememberPoseStill()
    val scale = if (streak.todaySecured && !still) flicker else 1f

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                Icons.Filled.LocalFireDepartment,
                contentDescription = null,
                tint = when {
                    streak.todaySecured -> Palette.statusWarning
                    lit -> Palette.statusWarning.copy(alpha = 0.45f)
                    else -> Palette.textTertiary.copy(alpha = 0.35f)
                },
                modifier = Modifier
                    .size(Metrics.iconButton)
                    .scale(scale)
                    .alpha(if (lit) 1f else 0.6f),
            )
        }
        Text(
            if (lit) uiString(R.string.streak_days, streak.days) else "–",
            style = NoopType.headline,
            color = if (lit) Palette.textPrimary else Palette.textTertiary,
        )
        Text(
            streakLabel(streak.kind),
            style = NoopType.footnote,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun streakLabel(kind: StreakKind): String = uiString(
    when (kind) {
        StreakKind.SLEEP_REGULARITY -> R.string.streak_sleep_regularity
        StreakKind.SLEEP_DURATION -> R.string.streak_sleep_duration
        StreakKind.MOVEMENT -> R.string.streak_movement
    },
)

/**
 * Read the days and the sleep onsets, and evaluate.
 *
 * The onsets are the reason this is not a one-liner: [com.noop.data.DailyMetric] stores sleep DURATION
 * and not when it began, so the regularity streak needs the sleep sessions as well. Mapped to the local
 * day the night is credited to, which is the day the session ENDS on — a night that starts at 23:40 on
 * Tuesday belongs to Wednesday's row everywhere else in the app, and a streak that disagreed with the
 * rest of the app would just look broken.
 */
private suspend fun readStreaks(viewModel: AppViewModel): List<Streak> {
    val id = viewModel.activeStrapId
    val days = viewModel.repo.daysMerged(id)
    if (days.isEmpty()) return emptyList()

    val now = System.currentTimeMillis() / 1000L
    val from = now - 45L * 86_400L
    val sessions = runCatching { viewModel.repo.sleepSessionsMerged(id, from, now) }.getOrDefault(emptyList())
    val zone = ZoneId.systemDefault()
    val onsetByDay = sessions.associate { session ->
        val start = Instant.ofEpochSecond(session.startTs).atZone(zone)
        val creditedDay = Instant.ofEpochSecond(session.endTs).atZone(zone).toLocalDate()
        creditedDay.toString() to (start.hour * 60 + start.minute)
    }
    return Streaks.evaluate(days = days, onsetByDay = onsetByDay)
}
