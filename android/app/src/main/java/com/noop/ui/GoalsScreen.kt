package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ai.CoachGoals

// MARK: - Goals
//
// One free-text field. See [CoachGoals] for why it is prose and not a schema: what people actually
// want are sentences, and fields would have lost the point of them.
//
// SAVED ON EVERY KEYSTROKE, not behind a button. There is nothing to validate and nothing to confirm,
// and a goal typed but not saved — then read as missing by the 06:45 mission — is a silent failure for
// the sake of a button nobody wanted to press.

@Composable
internal fun GoalsScreen() {
    val context = LocalContext.current
    var text by remember { mutableStateOf(CoachGoals.read(context)) }

    ScreenScaffold(
        title = uiString(R.string.goals_title),
        subtitle = uiString(R.string.goals_subtitle),
    ) {
        NoopCard {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
                Text(
                    uiString(R.string.goals_explainer),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = text,
                    onValueChange = {
                        text = it.take(CoachGoals.MAX_CHARS)
                        CoachGoals.write(context, text)
                    },
                    placeholder = { Text(uiString(R.string.goals_hint)) },
                    colors = coachFieldColors(),
                    minLines = 4,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 140.dp),
                )
                Text(
                    uiString(R.string.goals_counter, text.length, CoachGoals.MAX_CHARS),
                    style = NoopType.caption,
                    color = Palette.textTertiary,
                )
            }
        }
    }
}
