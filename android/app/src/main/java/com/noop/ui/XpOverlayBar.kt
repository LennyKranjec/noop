package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.gamify.AccountLevel

// MARK: - The XP bar that rides above every screen
//
// One thin strip under the status bar, present on every destination: the current level on the left,
// the next one on the right, and the track between them showing how far through. It is deliberately
// NOT a card — it belongs to the shell, not to a screen, and anything taller would be a permanent
// tax on the content of every tab.
//
// Colour comes from the gold ramp the bar and selection chrome already use, so the strip reads as
// app chrome rather than as another metric competing with the screen's own.

/** The strip's own height, without the status-bar inset it sits under. */
internal val XpBarHeight = 22.dp

@Composable
internal fun XpOverlayBar(modifier: Modifier = Modifier) {
    val level = AccountLevel.level()
    val progress = AccountLevel.progress()
    val remaining = AccountLevel.xpToNextLevel()

    Box(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceBase)
            .statusBarsPadding()
            .height(XpBarHeight)
            .padding(horizontal = Metrics.space16),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        ) {
            Text(
                uiString(R.string.xp_bar_level, level),
                style = NoopType.overline,
                color = Palette.textSecondary,
            )
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(6.dp)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.surfaceInset),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(progress)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(
                            if (Palette.isLight) {
                                Brush.horizontalGradient(listOf(Palette.accent, Palette.accent))
                            } else {
                                Brush.horizontalGradient(*Palette.goldGradient.toTypedArray())
                            },
                        ),
                )
            }
            // What the bar is FOR: not "how full", but how much more and what it buys.
            Text(
                uiString(R.string.xp_bar_to_next, remaining, level + 1),
                style = NoopType.overline,
                color = Palette.textTertiary,
            )
        }
    }
}
