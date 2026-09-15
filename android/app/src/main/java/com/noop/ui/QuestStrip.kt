package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.ai.Quest
import com.noop.ai.QuestKind

// MARK: - The quests you are carrying
//
// A row of chips directly under the XP bar, on every screen: what has been accepted and not yet
// finished. Part of the shell rather than of Today, for the same reason the XP bar is — a commitment
// you made this morning should be visible from wherever you are, not only from the tab you happened to
// accept it on.
//
// ONE LINE, HORIZONTALLY SCROLLED. The strip is a reminder, not a list view: it costs every screen its
// vertical space, so it takes one row and no more, and it disappears entirely when nothing is active.
// Tapping a chip opens the review sheet, which is where a quest can actually be declared finished.

/** The strip's height when it has something to show. Zero when it does not. */
internal val QuestStripHeight = 30.dp

@Composable
internal fun QuestStrip(
    quests: List<Quest>,
    onOpen: (Quest) -> Unit,
    modifier: Modifier = Modifier,
) {
    if (quests.isEmpty()) return
    val context = LocalContext.current

    LazyRow(
        modifier = modifier
            .fillMaxWidth()
            .background(Palette.surfaceBase)
            .padding(horizontal = Metrics.space16, vertical = Metrics.space4),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        items(quests, key = { it.id }) { quest ->
            QuestChip(
                quest = quest,
                onClick = {
                    SystemHaptics.play(context, SystemHaptics.Cue.TAP)
                    onOpen(quest)
                },
            )
        }
    }
}

@Composable
private fun QuestChip(quest: Quest, onClick: () -> Unit) {
    // The daily quest is tinted; side quests are not. One accent on the strip keeps the eye on the
    // thing that is supposed to happen today, however many side quests are riding along.
    val tint = if (quest.kind == QuestKind.DAILY) Palette.accent else Palette.textSecondary
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceInset)
            .clickable(onClick = onClick)
            .padding(horizontal = Metrics.space10, vertical = Metrics.space4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.space6),
    ) {
        // The first reward icon stands for the quest: a chip has room for one mark, and the whole set
        // is on the review sheet a tap away.
        quest.rewards.firstOrNull()?.let { reward ->
            Icon(
                rewardIcon(reward),
                contentDescription = null,
                tint = rewardTint(reward),
                modifier = Modifier.size(Metrics.iconTiny),
            )
        }
        Text(
            quest.title,
            style = NoopType.overline,
            color = tint,
            maxLines = 1,
        )
        // The clock, at chip scale and without its icon — the row is already a row of small things, and
        // a second glyph per chip turns the strip into a toolbar.
        QuestCountdown(quest = quest, fontSize = 11.sp, showIcon = false)
    }
}

/**
 * The review sheet: the whole quest, and the button that finishes it.
 *
 * Finishing is the wearer's word — see [QuestPopup] on why there is no verification — so the button
 * says what it does plainly and the XP lands the moment it is pressed.
 */
@Composable
internal fun QuestReviewCard(
    quest: Quest,
    onComplete: () -> Unit,
    onAbandon: () -> Unit,
) {
    val context = LocalContext.current
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    quest.title.uppercase(),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                    modifier = Modifier.weight(1f),
                )
            }
            Text(quest.taunt, style = NoopType.subhead, color = Palette.textTertiary)
            Text(quest.target, style = NoopType.body, color = Palette.textPrimary)
            QuestCountdown(quest = quest)

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
            ) {
                quest.rewards.forEach { reward ->
                    Box(
                        modifier = Modifier
                            .size(Metrics.iconButton)
                            .clip(RoundedCornerShape(Metrics.cornerPill))
                            .background(Palette.surfaceInset),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            rewardIcon(reward),
                            contentDescription = rewardLabel(reward),
                            tint = rewardTint(reward),
                            modifier = Modifier.size(Metrics.iconSmall),
                        )
                    }
                }
            }

            NoopButton(
                text = uiString(R.string.quest_complete),
                fullWidth = true,
                onClick = {
                    SystemHaptics.play(context, SystemHaptics.Cue.CONFIRM)
                    onComplete()
                },
            )
            Text(
                uiString(R.string.quest_abandon),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable {
                        SystemHaptics.play(context, SystemHaptics.Cue.TAP)
                        onAbandon()
                    },
            )
        }
    }
}
