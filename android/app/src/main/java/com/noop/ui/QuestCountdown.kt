package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import com.noop.ai.Quest
import kotlinx.coroutines.delay

// MARK: - The clock on a quest
//
// A directive with no deadline is a suggestion. The countdown is most of what makes the difference:
// "8,000 steps" is advice; "8,000 steps in 14:22:07" is a quest.
//
// IT TICKS FROM THE WALL CLOCK, not from a counter it increments. A composable that counts its own
// seconds drifts whenever the phone sleeps or the frame budget slips, and this is the one number on the
// screen the wearer can check against their own clock.
//
// The digits are monospaced-by-construction: [Quest.formatRemaining] zero-pads every field, so the row
// keeps its width as the numbers change rather than jittering once a second.

/** Under this much left, the clock turns to the warning colour. An hour is enough to still act. */
private const val URGENT_MS = 60L * 60 * 1000

@Composable
internal fun QuestCountdown(
    quest: Quest,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = 18.sp,
    showIcon: Boolean = true,
) {
    var remaining by remember(quest.id) { mutableLongStateOf(quest.remainingMs()) }

    LaunchedEffect(quest.id) {
        while (remaining > 0L) {
            // Re-read the clock rather than subtracting 1000: a doze, a long frame or a backgrounded
            // app would otherwise leave the countdown telling a comfortable lie.
            remaining = quest.remainingMs()
            delay(1000)
        }
        remaining = 0L
    }

    val expired = remaining <= 0L
    val tint = when {
        expired -> Palette.statusCritical
        remaining <= URGENT_MS -> Palette.statusWarning
        else -> Palette.accent
    }

    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
    ) {
        if (showIcon) {
            Icon(
                Icons.Filled.Timer,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(Metrics.iconSmall),
            )
        }
        Text(
            Quest.formatRemaining(remaining),
            style = NoopType.captionNumber.copy(fontSize = fontSize),
            color = tint,
            textAlign = TextAlign.Center,
        )
    }
}
