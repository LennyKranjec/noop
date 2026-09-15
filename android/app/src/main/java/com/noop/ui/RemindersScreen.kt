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
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.ai.Reminder
import com.noop.ai.ReminderRepeat
import com.noop.ai.ReminderStore

// MARK: - Reminders
//
// The list the coach writes into. Everything here is also doable by hand, on purpose: a feature whose
// only door is "ask the model nicely" is a feature that breaks when the model has a bad day, and the
// wearer needs to be able to see, disable and delete anything that was created on their behalf.
//
// The CONTEXT field is the important one and is labelled as such — it is not a title, it is what the
// notification gets written from, so "Bedtime, I want eight hours" produces a better nudge than
// "Sleep".

@Composable
internal fun RemindersScreen() {
    val context = LocalContext.current
    var reminders by remember { mutableStateOf(ReminderStore.all(context)) }
    var showAdd by remember { mutableStateOf(false) }

    ScreenScaffold(
        title = uiString(R.string.reminders_title),
        subtitle = uiString(R.string.reminders_subtitle),
        trailing = {
            Box(
                modifier = Modifier
                    .size(Metrics.iconButton)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .background(Palette.surfaceRaised)
                    .clickable { showAdd = !showAdd },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Add,
                    contentDescription = uiString(R.string.reminders_add),
                    tint = Palette.textSecondary,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
            }
        },
    ) {
        if (showAdd) {
            AddReminderCard(
                onAdd = { minuteOfDay, repeat, ctxText ->
                    val reminder = Reminder(
                        context = ctxText,
                        minuteOfDay = minuteOfDay,
                        repeat = repeat,
                    )
                    reminders = ReminderStore.upsert(context, reminder)
                    ReminderScheduler.schedule(context, reminder)
                    showAdd = false
                },
            )
        }

        if (reminders.isEmpty()) {
            NoopCard {
                Text(
                    uiString(R.string.reminders_empty),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
            }
        } else {
            reminders.forEach { reminder ->
                ReminderRow(
                    reminder = reminder,
                    onToggle = { enabled ->
                        val updated = reminder.copy(enabled = enabled)
                        reminders = ReminderStore.upsert(context, updated)
                        ReminderScheduler.schedule(context, updated)
                    },
                    onDelete = {
                        reminders = ReminderStore.delete(context, reminder.id)
                        ReminderScheduler.cancel(context, reminder.id)
                    },
                )
            }
        }
    }
}

@Composable
private fun ReminderRow(reminder: Reminder, onToggle: (Boolean) -> Unit, onDelete: () -> Unit) {
    NoopCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(modifier = Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        reminder.timeLabel,
                        style = NoopType.headline,
                        color = if (reminder.enabled) Palette.textPrimary else Palette.textTertiary,
                    )
                    Text(
                        "  " + repeatLabel(reminder.repeat),
                        style = NoopType.footnote,
                        color = Palette.textTertiary,
                    )
                }
                Text(
                    reminder.context,
                    style = NoopType.subhead,
                    color = if (reminder.enabled) Palette.textSecondary else Palette.textTertiary,
                )
            }
            Switch(checked = reminder.enabled, onCheckedChange = onToggle)
            Box(
                modifier = Modifier
                    .padding(start = Metrics.space8)
                    .size(Metrics.iconButton)
                    .clip(RoundedCornerShape(Metrics.cornerPill))
                    .clickable(onClick = onDelete),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.DeleteOutline,
                    contentDescription = uiString(R.string.reminders_delete),
                    tint = Palette.statusCritical,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
            }
        }
    }
}

@Composable
private fun AddReminderCard(onAdd: (Int, ReminderRepeat, String) -> Unit) {
    var hour by remember { mutableStateOf("22") }
    var minute by remember { mutableStateOf("00") }
    var repeat by remember { mutableStateOf(ReminderRepeat.DAILY) }
    var text by remember { mutableStateOf("") }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            SectionHeader(uiString(R.string.reminders_add))
            Row(
                horizontalArrangement = Arrangement.spacedBy(Metrics.space8),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                OutlinedTextField(
                    value = hour,
                    onValueChange = { hour = it.filter(Char::isDigit).take(2) },
                    label = { Text(uiString(R.string.reminders_hour)) },
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = KeyboardType.Number,
                    ),
                    colors = coachFieldColors(),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = minute,
                    onValueChange = { minute = it.filter(Char::isDigit).take(2) },
                    label = { Text(uiString(R.string.reminders_minute)) },
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = KeyboardType.Number,
                    ),
                    colors = coachFieldColors(),
                    modifier = Modifier.weight(1f),
                )
            }
            SegmentedPillControl(
                items = ReminderRepeat.entries.toList(),
                selection = repeat,
                label = { repeatLabel(it) },
                onSelect = { repeat = it },
            )
            OutlinedTextField(
                value = text,
                onValueChange = { text = it.take(160) },
                label = { Text(uiString(R.string.reminders_context_label)) },
                placeholder = { Text(uiString(R.string.reminders_context_hint)) },
                colors = coachFieldColors(),
                modifier = Modifier.fillMaxWidth(),
            )
            NoopButton(
                text = uiString(R.string.reminders_save),
                // A reminder with no context would produce a notification with nothing to say, so the
                // one field that cannot be empty is the one the model writes from.
                enabled = text.isNotBlank(),
                onClick = {
                    val h = hour.toIntOrNull()?.coerceIn(0, 23) ?: 0
                    val m = minute.toIntOrNull()?.coerceIn(0, 59) ?: 0
                    onAdd(h * 60 + m, repeat, text.trim())
                },
            )
        }
    }
}

/** Not composable on purpose: [SegmentedPillControl]'s `label` is a plain lambda, not a composable one. */
private fun repeatLabel(repeat: ReminderRepeat): String = uiString(
    when (repeat) {
        ReminderRepeat.DAILY -> R.string.reminders_repeat_daily
        ReminderRepeat.WEEKDAYS -> R.string.reminders_repeat_weekdays
        ReminderRepeat.WEEKENDS -> R.string.reminders_repeat_weekends
        ReminderRepeat.WEEKLY -> R.string.reminders_repeat_weekly
    },
)
