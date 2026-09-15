package com.noop.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Air
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.WarningAmber
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.ai.Quest
import com.noop.ai.QuestReward
import kotlinx.coroutines.delay

// MARK: - The quest pop-up
//
// The system interrupting. A full-screen sheet with a hard border, the directive, what it is worth,
// and one button — the wearer has to answer it, which is the entire mechanism: a nudge that can be
// scrolled past is a nudge that is scrolled past.
//
// THE TAUNT TYPES ITSELF, one letter at a time, with a tick of haptic per letter. That is the moment
// the wearer asked for — the bond between them and the machine made physical — and it is also why the
// tick is the weakest cue in [SystemHaptics]: at 25 letters a second, anything stronger is a drill.
//
// SKIPPABLE. Tapping anywhere while it types finishes the line at once. A wearer who has read it
// already must never be made to sit through the animation, and an unskippable cutscene is the fastest
// way to make a feature hated.
//
// THE STRAP BUZZES TOO, when one is connected: the quest arrives on the wrist and on the screen, which
// is what makes it feel issued rather than displayed.

/** How long between letters. ~25/s: fast enough not to be a wait, slow enough to read as typing. */
private const val TYPE_INTERVAL_MS = 38L

/** Margins. The card is nearly the whole screen, as asked — a few dozen dp of breathing room. */
private val SCREEN_MARGIN = 20.dp

@Composable
internal fun QuestPopup(
    quest: Quest,
    onAccept: () -> Unit,
    onDismiss: () -> Unit,
    // Passed in rather than reached for: the strap lives behind the AppViewModel, and a pop-up that
    // owned a BLE handle would be a screen that cannot be previewed or tested.
    onSummonStrap: () -> Unit = {},
) {
    val context = LocalContext.current

    // Read ONCE, held for the whole animation: a preference lookup per letter would stutter the type.
    val vibrator = remember { if (SystemHaptics.enabled(context)) SystemHaptics.vibrator(context) else null }

    var typed by remember(quest.id) { mutableStateOf(0) }
    val full = quest.taunt
    val done = typed >= full.length

    // The summon: one waveform on the phone, one buzz on the strap. Fires once per quest, keyed on its
    // id so a recomposition cannot re-summon.
    LaunchedEffect(quest.id) {
        SystemHaptics.play(context, SystemHaptics.Cue.SUMMON)
        runCatching { onSummonStrap() }
    }

    LaunchedEffect(quest.id) {
        while (typed < full.length) {
            delay(TYPE_INTERVAL_MS)
            typed++
            // Spaces get no tick: the finger feels a gap between words, which is what a space is.
            if (full.getOrNull(typed - 1)?.isWhitespace() == false) SystemHaptics.tick(vibrator)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.surfaceBase.copy(alpha = 0.97f))
            // Tap anywhere to finish the typing early; once finished, taps do nothing (the button is
            // the only way out, because this is a decision and not a toast).
            .clickable(enabled = !done) { typed = full.length }
            .padding(SCREEN_MARGIN),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(Metrics.cardRadius))
                .border(
                    BorderStroke(1.dp, Palette.accent.copy(alpha = 0.55f)),
                    RoundedCornerShape(Metrics.cardRadius),
                )
                .background(
                    Brush.verticalGradient(
                        listOf(
                            Palette.surfaceRaised,
                            Palette.surfaceBase,
                        ),
                    ),
                )
                .padding(Metrics.space18),
            verticalArrangement = Arrangement.spacedBy(Metrics.space16),
        ) {
            QuestHeader()

            // The body panel: name, the typed taunt, and the directive.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .clip(RoundedCornerShape(Metrics.cornerSm))
                    .border(
                        BorderStroke(1.dp, Palette.hairline),
                        RoundedCornerShape(Metrics.cornerSm),
                    )
                    .padding(Metrics.space16),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    quest.title.uppercase(),
                    style = NoopType.title1,
                    color = Palette.textPrimary,
                    textAlign = TextAlign.Center,
                    letterSpacing = 2.sp,
                )
                Spacer(Modifier.size(Metrics.space16))
                TypedLine(text = full, shown = typed)
                Spacer(Modifier.size(Metrics.space18))
                Text(
                    quest.target,
                    style = NoopType.headline,
                    color = Palette.accent,
                    textAlign = TextAlign.Center,
                )
            }

            RewardRow(rewards = quest.rewards, xp = quest.xp)

            // THE CLOCK, and what runs out with it. The warning is plain rather than threatening: the
            // only thing that actually expires is the XP, and saying so is more honest than implying a
            // penalty the app has no way to impose.
            Column(
                modifier = Modifier.fillMaxWidth(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Metrics.space6),
            ) {
                Text(
                    uiString(R.string.quest_deadline_warning),
                    style = NoopType.footnote,
                    color = Palette.statusWarning,
                    textAlign = TextAlign.Center,
                )
                QuestCountdown(quest = quest, fontSize = 22.sp)
            }

            AcceptButton(
                // Until the line has finished typing there is nothing to accept yet — the wearer has
                // not been told what they are agreeing to.
                enabled = done,
                onAccept = {
                    SystemHaptics.play(context, SystemHaptics.Cue.CONFIRM)
                    onAccept()
                },
            )
            Text(
                uiString(R.string.quest_decline),
                style = NoopType.footnote,
                color = Palette.textTertiary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = done) {
                        SystemHaptics.play(context, SystemHaptics.Cue.TAP)
                        onDismiss()
                    },
            )
        }
    }
}

@Composable
private fun QuestHeader() {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Filled.WarningAmber,
            contentDescription = null,
            tint = Palette.textPrimary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
        Spacer(Modifier.size(Metrics.space12))
        Text(
            uiString(R.string.quest_header),
            style = NoopType.headline,
            color = Palette.textPrimary,
            fontWeight = FontWeight.Bold,
            letterSpacing = 3.sp,
        )
    }
}

/**
 * The taunt, mid-type.
 *
 * The full string is laid out invisibly underneath so the block does not change height as it fills —
 * text that reflows while it types is the thing that makes a typewriter effect feel cheap.
 */
@Composable
private fun TypedLine(text: String, shown: Int) {
    Box(contentAlignment = Alignment.Center) {
        Text(
            text,
            style = NoopType.subhead,
            color = Color.Transparent,
            textAlign = TextAlign.Center,
        )
        Text(
            text.take(shown),
            style = NoopType.subhead,
            color = Palette.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * What finishing it is worth: the systems it touches, then the XP.
 *
 * The icons are a claim about WHICH systems, never about how much — see [QuestReward]. The XP is the
 * only number here, and it is the one the app actually controls.
 */
@Composable
private fun RewardRow(rewards: List<QuestReward>, xp: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.space8)) {
        Overline(uiString(R.string.quest_rewards))
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.space12),
        ) {
            rewards.forEach { reward ->
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
            Spacer(Modifier.weight(1f))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Bolt,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Text(
                    uiString(R.string.mission_xp, xp),
                    style = NoopType.headline,
                    color = Palette.accent,
                )
            }
        }
    }
}

@Composable
private fun AcceptButton(enabled: Boolean, onAccept: () -> Unit) {
    // The glow fades in with the button becoming live, so "you may answer now" is visible from across
    // the room rather than only legible up close.
    val glow by animateFloatAsState(if (enabled) 1f else 0f, label = "questAcceptGlow")
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(
                if (enabled) Palette.accent else Palette.surfaceInset,
            )
            .alpha(0.55f + 0.45f * glow)
            .clickable(enabled = enabled, onClick = onAccept),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            uiString(R.string.quest_accept),
            style = NoopType.headline,
            color = if (enabled) Palette.surfaceBase else Palette.textTertiary,
            fontWeight = FontWeight.Bold,
            letterSpacing = 4.sp,
        )
    }
}

internal fun rewardIcon(reward: QuestReward): ImageVector = when (reward) {
    QuestReward.HEART -> Icons.Filled.FavoriteBorder
    QuestReward.LUNGS -> Icons.Filled.Air
    QuestReward.BRAIN -> Icons.Filled.Psychology
    QuestReward.MUSCLE -> Icons.Filled.FitnessCenter
    QuestReward.SLEEP -> Icons.Filled.Bedtime
    QuestReward.STRESS -> Icons.Filled.Bolt
}

@Composable
internal fun rewardLabel(reward: QuestReward): String = uiString(
    when (reward) {
        QuestReward.HEART -> R.string.quest_reward_heart
        QuestReward.LUNGS -> R.string.quest_reward_lungs
        QuestReward.BRAIN -> R.string.quest_reward_brain
        QuestReward.MUSCLE -> R.string.quest_reward_muscle
        QuestReward.SLEEP -> R.string.quest_reward_sleep
        QuestReward.STRESS -> R.string.quest_reward_stress
    },
)

internal fun rewardTint(reward: QuestReward): Color = when (reward) {
    QuestReward.HEART -> Palette.statusCritical
    QuestReward.LUNGS -> Palette.metricCyan
    QuestReward.BRAIN -> Palette.accent
    QuestReward.MUSCLE -> Palette.statusWarning
    QuestReward.SLEEP -> Palette.restBright
    QuestReward.STRESS -> Palette.statusWarning
}
