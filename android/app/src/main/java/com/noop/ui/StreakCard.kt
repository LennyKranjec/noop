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
import androidx.compose.ui.unit.dp
import com.noop.analytics.StressDailyStore
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.text.font.FontWeight
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

    // NO SECTION HEADER, and the card is as short as three flames allow. A heading reading "Streaks"
    // over three flames labelled with their own rules is a label for a label, and it cost the strip
    // more height than the content it introduced.
    NoopCard(padding = STRIP_PADDING) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            streaks.forEach { streak -> StreakFlame(streak) }
        }
    }
}

/** The strip's own inset. Tight: the flames are the content, and the card is a frame around them. */
private val STRIP_PADDING = 10.dp

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
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        // The flame and the count sit on ONE line. Stacked they cost three rows of height for two
        // figures, and the strip is meant to be glanced at rather than read.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.LocalFireDepartment,
                contentDescription = null,
                tint = when {
                    streak.todaySecured -> Palette.statusWarning
                    lit -> Palette.statusWarning.copy(alpha = 0.45f)
                    else -> Palette.textTertiary.copy(alpha = 0.35f)
                },
                modifier = Modifier
                    .size(Metrics.iconSmall)
                    .scale(scale)
                    .alpha(if (lit) 1f else 0.6f),
            )
            Text(
                if (lit) uiString(R.string.streak_days, streak.days) else "-",
                style = NoopType.footnote,
                color = if (lit) Palette.textPrimary else Palette.textTertiary,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(start = 3.dp),
                maxLines = 1,
            )
        }
        // THE RULE, not the metric's name. "Sleep" says which number; "sleep consistency > 80%" says
        // what holds the flame lit, which is the only thing a streak label has to answer.
        Text(
            streakLabel(streak.kind),
            style = NoopType.overline,
            color = Palette.textTertiary,
            textAlign = TextAlign.Center,
            maxLines = 1,
        )
    }
}

@Composable
private fun streakLabel(kind: StreakKind): String = uiString(
    when (kind) {
        StreakKind.SLEEP_CONSISTENCY -> R.string.streak_sleep_consistency
        StreakKind.SLEEP_DEBT -> R.string.streak_sleep_debt
        StreakKind.STRESS_TIME -> R.string.streak_stress_time
    },
)

/**
 * Read the days and the banked stress minutes, and evaluate.
 *
 * The consistency and debt rules are derived from the daily rows themselves, so they need nothing
 * extra. The stress rule cannot be: its figure costs a whole day of heart rate and R-R to compute, so
 * it is read from what the stress screen banked rather than recomputed here. See [StressDailyStore].
 */
private suspend fun readStreaks(viewModel: AppViewModel): List<Streak> {
    val id = viewModel.activeStrapId
    val days = viewModel.repo.daysMerged(id)
    if (days.isEmpty()) return emptyList()

    val today = java.time.LocalDate.now()
    val stress = StressDailyStore.range(
        viewModel.repo,
        from = today.minusDays(400).toString(),
        to = today.toString(),
    )
    return Streaks.evaluate(days = days, stressMinutesByDay = stress)
}
