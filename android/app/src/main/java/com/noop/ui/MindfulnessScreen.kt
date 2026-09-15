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

// MARK: - Focus
//
// This file used to be the LAST screen in the app standing over fixtures: five sub-tabs of invented
// figures that read as features and were backed by nothing at all. It is now the Stress monitor with
// the meditation log on top, every number of which is read from the store.

/**
 * Focus — the Stress monitor, with the meditation log on top.
 *
 * WHAT WAS HERE BEFORE IS GONE. This tab was a LAYOUT PREVIEW: five sub-tabs of hand-written fixtures
 * that read as features and were backed by nothing. The wearer asked for it to become the stress tab
 * plus a meditation log, and a screen of invented numbers is exactly what this project refuses to ship,
 * so it was deleted rather than kept alongside.
 *
 * IT REUSES [StressScreen] rather than copying it. A literal clone would be 1,700 duplicated lines whose
 * two halves drift the first time either is touched — a fix landing on one tab and silently not the
 * other. The heading, the subtitle and the leading card are the entire difference.
 */
@Composable
fun MindfulnessScreen(vm: AppViewModel, onOpenBreathe: () -> Unit = {}) {
    StressScreen(
        vm = vm,
        onBreathe = onOpenBreathe,
        title = uiString(R.string.nav_mindfulness),
        subtitle = uiString(R.string.focus_subtitle),
        leading = { item { MeditationCard(vm) } },
    )
}

// MARK: - Mind
