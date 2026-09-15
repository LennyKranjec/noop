package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowForward
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Medication
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.Spa
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.noop.R

// MARK: - Mindfulness — LAYOUT PREVIEW
//
// The shape of the screen only: every figure below is a fixture, nothing reads the repository, and
// no control writes anything. Structure follows the OpenStrap wellness screen (Mind / Recovery /
// Habits / Medication / Cycle), rebuilt in NOOP's own design system.
//
// The small furniture at the foot of this file (PreviewNote, IconTile, AverageRow, SegmentBar) came
// across when the Nutrition preview screen was deleted — its tiles moved to Today as real,
// store-backed cards, and this is the last screen still standing over fixtures.

private enum class MindTab { Mind, Recovery, Habits, Medication, Cycle }

@Composable
fun MindfulnessScreen(onOpenBreathe: () -> Unit = {}) {
    var tab by remember { mutableStateOf(MindTab.Mind) }

    ScreenScaffold(
        title = uiString(R.string.nav_mindfulness),
        subtitle = uiString(R.string.mindfulness_subtitle),
    ) {
        SegmentedPillControl(
            items = MindTab.entries.toList(),
            selection = tab,
            label = {
                when (it) {
                    MindTab.Mind -> uiString(R.string.mindfulness_tab_mind)
                    MindTab.Recovery -> uiString(R.string.mindfulness_tab_recovery)
                    MindTab.Habits -> uiString(R.string.mindfulness_tab_habits)
                    MindTab.Medication -> uiString(R.string.mindfulness_tab_medication)
                    MindTab.Cycle -> uiString(R.string.mindfulness_tab_cycle)
                }
            },
            onSelect = { tab = it },
            adaptsToAvailableWidth = true,
        )
        PreviewNote(uiString(R.string.mindfulness_preview_note))
        when (tab) {
            MindTab.Mind -> MindTabContent(onOpenBreathe)
            MindTab.Recovery -> RecoveryTabContent()
            MindTab.Habits -> HabitsTabContent()
            MindTab.Medication -> MedicationTabContent()
            MindTab.Cycle -> CycleTabContent()
        }
    }
}

// MARK: - Mind

@Composable
private fun MindTabContent(onOpenBreathe: () -> Unit) {
    NoopCard(tint = Palette.metricPurple) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Overline(uiString(R.string.mindfulness_start_a_sitting))
            Row(verticalAlignment = Alignment.Bottom) {
                Text("3", style = NoopType.number(34f), color = Palette.textPrimary)
                Spacer(Modifier.width(Metrics.space6))
                Text(
                    uiString(R.string.mindfulness_exercises),
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                    modifier = Modifier.padding(bottom = Metrics.space4),
                )
            }
            Text(
                uiString(R.string.mindfulness_pick_one),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
            NoopButton(
                text = uiString(R.string.mindfulness_begin),
                leadingIcon = Icons.Filled.SelfImprovement,
                kind = NoopButtonKind.Secondary,
                onClick = onOpenBreathe,
            )
        }
    }

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Text(
                uiString(R.string.mindfulness_how_are_you),
                style = NoopType.headline,
                color = Palette.textPrimary,
            )
            Text(
                uiString(R.string.mindfulness_not_answered),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                MOOD_PREVIEW_FACES.forEach { (emoji, tint) ->
                    Box(
                        modifier = Modifier
                            .size(44.dp)
                            .clip(RoundedCornerShape(Metrics.cornerPill))
                            .background(tint.copy(alpha = 0.12f)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(emoji, style = NoopType.number(20f))
                    }
                }
            }
        }
    }

    ActionRowCard(
        icon = Icons.Filled.Spa,
        title = uiString(R.string.mindfulness_write_the_day),
        sub = uiString(R.string.mindfulness_write_the_day_sub),
        action = uiString(R.string.mindfulness_open),
        tint = Palette.metricCyan,
    )

    SectionHeader(uiString(R.string.mindfulness_stress_last_night))
    StatTile(
        label = uiString(R.string.mindfulness_autonomic_tension),
        value = "42",
        caption = uiString(R.string.mindfulness_level_normal),
        accent = Palette.metricPurple,
        delta = "/100",
    )
}

// MARK: - Recovery

@Composable
private fun RecoveryTabContent() {
    NoopCard(tint = Palette.accent) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Filled.Bedtime,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(Metrics.iconSmall),
                )
                Spacer(Modifier.width(Metrics.space8))
                Text(
                    uiString(R.string.mindfulness_turn_in_by),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
            }
            Text(
                uiString(R.string.mindfulness_turn_in_body),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            Text(
                uiString(R.string.mindfulness_see_what_cost),
                style = NoopType.footnote,
                color = Palette.accent,
            )
        }
    }

    SectionHeader(uiString(R.string.mindfulness_drivers))
    NoopCard(padding = Metrics.space8) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space4)) {
            Overline(
                uiString(R.string.mindfulness_what_helped),
                modifier = Modifier.padding(horizontal = Metrics.space8, vertical = Metrics.space6),
                color = Palette.statusPositive,
            )
            DriverRow(uiString(R.string.mindfulness_driver_consistency), "+8", Palette.statusPositive)
            DriverRow(uiString(R.string.mindfulness_driver_resting_hr), "+5", Palette.statusPositive)
            Overline(
                uiString(R.string.mindfulness_what_held_back),
                modifier = Modifier.padding(horizontal = Metrics.space8, vertical = Metrics.space6),
                color = Palette.statusWarning,
            )
            DriverRow(uiString(R.string.mindfulness_driver_sleep_debt), "−11", Palette.statusWarning)
            DriverRow(uiString(R.string.mindfulness_driver_late_strain), "−4", Palette.statusWarning)
        }
    }

    SectionHeader(uiString(R.string.mindfulness_sleep_need_tonight))
    NoopCard(padding = Metrics.space8) {
        Column {
            AverageRow(uiString(R.string.mindfulness_tonights_need), "7:45", "h")
            AverageRow(uiString(R.string.mindfulness_driver_sleep_debt), "1:20", "h")
            AverageRow(uiString(R.string.mindfulness_added_for_strain), "22", "min")
            AverageRow(uiString(R.string.mindfulness_credited_from_naps), "15", "min")
            AverageRow(uiString(R.string.mindfulness_target_bedtime), "22:45", "")
            AverageRow(uiString(R.string.mindfulness_target_wake), "06:30", "")
        }
    }
}

// MARK: - Habits

@Composable
private fun HabitsTabContent() {
    HabitCard(uiString(R.string.mindfulness_habit_meditate), filled = 9, total = 14, done = true)
    HabitCard(uiString(R.string.mindfulness_habit_no_screens), filled = 5, total = 14, done = false)
    NoopButton(
        text = uiString(R.string.mindfulness_add_a_habit),
        leadingIcon = Icons.Filled.Add,
        kind = NoopButtonKind.Secondary,
        fullWidth = true,
        onClick = {},
    )
    ActionRowCard(
        icon = Icons.Filled.Spa,
        title = uiString(R.string.mindfulness_what_you_log),
        sub = uiString(R.string.mindfulness_what_you_log_sub),
        action = uiString(R.string.mindfulness_open),
        tint = Palette.metricCyan,
    )
}

// MARK: - Medication

@Composable
private fun MedicationTabContent() {
    NoopCard(padding = Metrics.space8) {
        Column {
            MedRow(uiString(R.string.mindfulness_med_magnesium), uiString(R.string.mindfulness_med_magnesium_sub), true)
            MedRow(uiString(R.string.mindfulness_med_vitamin_d), uiString(R.string.mindfulness_med_vitamin_d_sub), false)
        }
    }

    SectionHeader(uiString(R.string.mindfulness_adherence))
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
            Text("18 of 21 doses", style = NoopType.number(26f), color = Palette.textPrimary)
            SegmentBar(filled = 18, total = 21, color = Palette.statusPositive)
            Text(
                uiString(R.string.mindfulness_adherence_label),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }

    NoopButton(
        text = uiString(R.string.mindfulness_add_a_medication),
        leadingIcon = Icons.Filled.Add,
        kind = NoopButtonKind.Secondary,
        fullWidth = true,
        onClick = {},
    )
}

// MARK: - Cycle

@Composable
private fun CycleTabContent() {
    DataPendingNote(
        title = uiString(R.string.mindfulness_cycle_title),
        body = uiString(R.string.mindfulness_cycle_body),
    )
}

// MARK: - Local furniture

@Composable
private fun PreviewNote(text: String) {
    Text(text, style = NoopType.footnote, color = Palette.textTertiary)
}

@Composable
private fun IconTile(icon: ImageVector, tint: Color) {
    Box(
        modifier = Modifier
            .size(36.dp)
            .clip(RoundedCornerShape(Metrics.cornerSm))
            .background(tint.copy(alpha = 0.14f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(Metrics.iconSmall))
    }
}

@Composable
private fun AverageRow(label: String, value: String, unit: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space8, vertical = Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = NoopType.body, color = Palette.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = NoopType.bodyNumber, color = Palette.textPrimary)
        if (unit.isNotEmpty()) {
            Spacer(Modifier.width(Metrics.space4))
            Text(unit, style = NoopType.footnote, color = Palette.textTertiary)
        }
    }
}

/** A filled-of-total bead bar — the "9 of 14 days" adherence shape, never a streak. */
@Composable
private fun SegmentBar(filled: Int, total: Int, color: Color) {
    Row(
        modifier = Modifier.fillMaxWidth().height(8.dp),
        horizontalArrangement = Arrangement.spacedBy(Metrics.space4),
    ) {
        repeat(total) { index ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .clip(RoundedCornerShape(Metrics.cornerXs))
                    .background(if (index < filled) color else Palette.surfaceInset),
            )
        }
    }
}

private val MOOD_PREVIEW_FACES: List<Pair<String, Color>>
    @Composable get() = listOf(
        "🙁" to Palette.statusCritical,
        "😕" to Palette.statusWarning,
        "😐" to Palette.textSecondary,
        "🙂" to Palette.metricCyan,
        "😄" to Palette.statusPositive,
    )

@Composable
private fun DriverRow(label: String, delta: String, tint: Color) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space8, vertical = Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        TrendChip(text = delta, color = tint)
    }
}

@Composable
private fun ActionRowCard(icon: ImageVector, title: String, sub: String, action: String, tint: Color) {
    NoopCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconTile(icon, tint)
            Spacer(Modifier.width(Metrics.space12))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = NoopType.body, color = Palette.textPrimary)
                Text(sub, style = NoopType.footnote, color = Palette.textTertiary)
            }
            Text(action, style = NoopType.footnote, color = Palette.accent)
            Spacer(Modifier.width(Metrics.space4))
            Icon(
                Icons.Filled.ArrowForward,
                contentDescription = null,
                tint = Palette.accent,
                modifier = Modifier.size(Metrics.iconTiny),
            )
        }
    }
}

@Composable
private fun HabitCard(name: String, filled: Int, total: Int, done: Boolean) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space10)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, style = NoopType.headline, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                Icon(
                    if (done) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (done) Palette.statusPositive else Palette.textTertiary,
                    modifier = Modifier.size(Metrics.iconButton - Metrics.space12),
                )
            }
            Text("$filled of $total days", style = NoopType.bodyNumber, color = Palette.textSecondary)
            SegmentBar(filled = filled, total = total, color = Palette.statusPositive)
            Text(
                uiString(R.string.mindfulness_days_you_did_it),
                style = NoopType.footnote,
                color = Palette.textTertiary,
            )
        }
    }
}

@Composable
private fun MedRow(name: String, sub: String, taken: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Metrics.space8, vertical = Metrics.space10),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconTile(Icons.Filled.Medication, if (taken) Palette.statusPositive else Palette.metricCyan)
        Spacer(Modifier.width(Metrics.space12))
        Column(modifier = Modifier.weight(1f)) {
            Text(name, style = NoopType.body, color = Palette.textPrimary)
            Text(sub, style = NoopType.footnote, color = Palette.textTertiary)
        }
        Icon(
            if (taken) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (taken) Palette.statusPositive else Palette.textTertiary,
            modifier = Modifier.size(Metrics.iconSmall),
        )
    }
}
