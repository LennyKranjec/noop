package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.noop.R
import com.noop.ai.DailyMission
import com.noop.ai.DailyMissionStore
import kotlinx.coroutines.launch

// MARK: - Today's mission
//
// The 06:45 generation, surfaced. One thing to do, and that is all it is.
//
// NOTHING IS CLAIMED HERE. An earlier cut had a button that banked XP for finishing it. XP is gone, and
// so is the button: the level is measured from the body, so whether the mission was done shows up on
// its own in tomorrow's numbers rather than in a tally the wearer types in themselves.
//
// The card is absent rather than empty when there is no mission (before 06:45 on a fresh install, or
// without data consent): a card that says "no mission today" is a card that takes up the same room as
// one with a mission in it and gives nothing back.

@Composable
internal fun DailyMissionCard() {
    val context = LocalContext.current
    var mission by remember { mutableStateOf<DailyMission?>(null) }

    // Read on every entry to Today, not once: the 06:45 job may have written one while the app sat in
    // the background, and the process outlives a night.
    LaunchedEffect(Unit) {
        mission = DailyMissionStore.today(context)
    }

    val current = mission ?: return

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            SectionHeader(uiString(R.string.mission_title))
            Text(
                current.text,
                style = NoopType.subhead,
                color = Palette.textPrimary,
            )
        }
    }
}

/**
 * The mission card, plus the "write one now" affordance for a wearer who installed after 06:45.
 *
 * Separate from [DailyMissionCard] because generating takes tens of seconds of model time and must be
 * something the wearer chooses, never something entering the Today tab kicks off.
 */
@Composable
internal fun DailyMissionCardWithGenerate() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var mission by remember { mutableStateOf<DailyMission?>(null) }
    var writing by remember { mutableStateOf(false) }
    var attempted by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { mission = DailyMissionStore.today(context) }

    if (mission != null) {
        DailyMissionCard()
        return
    }
    // Nothing yet, and nothing tried: offer to write one rather than explaining why there is none.
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            SectionHeader(uiString(R.string.mission_title))
            Text(
                uiString(if (attempted) R.string.mission_failed else R.string.mission_none_yet),
                style = NoopType.subhead,
                color = Palette.textSecondary,
            )
            NoopButton(
                text = uiString(if (writing) R.string.mission_writing else R.string.mission_write_now),
                enabled = !writing,
                onClick = {
                    writing = true
                    scope.launch {
                        val written = DailyMissionScheduler.generateNow(context, force = true)
                        mission = written
                        attempted = true
                        writing = false
                    }
                },
            )
        }
    }
}
