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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ai.LocalCoachEngine
import com.noop.ai.LocalModel
import com.noop.ai.LocalModelStore

// MARK: - The coach's header controls and its model switch
//
// Two things the chat screen needed once the API lane went away:
//
//   · A MENU, so consent, the editable instructions and the morning brief stop being three
//     full-width cards between the wearer and the conversation.
//   · A NEW-CHAT button under it, because "clear conversation" was buried in a long-press and a
//     fresh thread is the most common thing to want after an answer lands.
//
// Plus the model switch, which lives beside the composer rather than up here: it changes what the
// next answer costs in time and memory, so it belongs where the question is typed.

/** How big the hawk / owl sits on the switch. Big enough to read as a bird, small enough for a pill. */
private val BIRD_GLYPH = 20.dp

/** The two stacked header buttons: menu, then new chat. Fed into ScreenScaffold's trailing slot. */
@Composable
internal fun CoachHeaderActions(onMenu: () -> Unit, onNewChat: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(Metrics.space8),
    ) {
        HeaderDisc(Icons.Filled.MoreHoriz, uiString(R.string.coach_menu), onMenu)
        HeaderDisc(Icons.Filled.Add, uiString(R.string.coach_new_chat), onNewChat)
    }
}

@Composable
private fun HeaderDisc(icon: ImageVector, label: String, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(Metrics.iconButton)
            .clip(RoundedCornerShape(Metrics.cornerPill))
            .background(Palette.surfaceRaised)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, tint = Palette.textSecondary, modifier = Modifier.size(Metrics.iconSmall))
    }
}

/**
 * Hawk or owl, on a pill: which of the two local models answers the next question.
 *
 * Only ever offers a model that is actually installed: switching to one that is not would fail at
 * the next question with a download prompt, which is a worse place to learn it than here. A model
 * that is not installed is drawn dimmed, and tapping it does nothing — the download lives on the setup
 * card, which is one screen away and where the progress bar already is.
 */
@Composable
internal fun LocalModelSwitch() {
    val context = LocalContext.current
    if (!LocalCoachEngine.isSupported) return

    var selected by remember { mutableStateOf(LocalModelStore.selected(context)) }

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(Metrics.cornerPill))
                .background(Palette.surfaceInset)
                .padding(Metrics.space4),
            horizontalArrangement = Arrangement.spacedBy(Metrics.space4),
        ) {
            LocalModel.entries.forEach { model ->
                val installed = LocalModelStore.isInstalled(context, model)
                val isOn = selected == model
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(Metrics.cornerPill))
                        .background(if (isOn) Palette.accent.copy(alpha = 0.22f) else Palette.surfaceInset)
                        .clickable(enabled = installed) {
                            selected = model
                            LocalModelStore.setSelected(context, model)
                            // The resident model is stale the moment the choice changes; the next
                            // question loads the new one rather than answering from the old.
                            LocalCoachEngine.unload()
                        }
                        .padding(horizontal = Metrics.space12, vertical = Metrics.space6),
                ) {
                    val tint = when {
                        !installed -> Palette.textTertiary.copy(alpha = 0.5f)
                        isOn -> Palette.textPrimary
                        else -> Palette.textSecondary
                    }
                    // THE BIRDS CARRY THE MEANING. "Fast" and "Deep" needed reading and then needed
                    // knowing what they referred to; a stooping hawk and a sitting owl say speed and
                    // deliberation without a word. The model's real name is still on the setup card,
                    // where a wearer goes to choose or download one — this switch only has to say which
                    // of the two is answering. The name stays as the accessibility label.
                    //
                    // Silhouettes on transparent ground, so `Icon`'s tint carries them into whichever of
                    // the three states this segment is in: selected, selectable, or not installed.
                    Icon(
                        painter = painterResource(
                            when (model) {
                                LocalModel.FAST -> R.drawable.coach_model_hawk
                                LocalModel.DEEP -> R.drawable.coach_model_owl
                            },
                        ),
                        contentDescription = shortName(model),
                        tint = tint,
                        modifier = Modifier.size(BIRD_GLYPH),
                    )
                }
            }
        }
    }
}

/** Not composable, so it can be read where a composable call is not allowed. */
private fun shortName(model: LocalModel): String = uiString(
    when (model) {
        LocalModel.FAST -> R.string.coach_model_fast
        LocalModel.DEEP -> R.string.coach_model_deep
    },
)
