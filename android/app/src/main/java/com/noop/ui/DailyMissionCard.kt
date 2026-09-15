package com.noop.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.noop.R
import com.noop.ai.DailyMission
import com.noop.ai.DailyMissionStore
import com.noop.gamify.XpLedger
import kotlinx.coroutines.launch

// MARK: - Today's mission
//
// The 06:45 generation, surfaced. One thing to do, what it is worth, and a button that banks it.
//
// WHAT IT DOES NOT DO: verify. Claiming is the wearer's word that they did it — there is no sensor for
// "went to bed before 22:30 without doomscrolling", and inventing a proxy would have meant either
// refusing XP someone earned or awarding it to someone who did not. The XP is a commitment device, and
// a commitment device only has to be honest about what it is.
//
// The card is absent rather than empty when there is no mission (before 06:45 on a fresh install, or
// without data consent): a card that says "no mission today" is a card that takes up the same room as
// one with a mission in it and gives nothing back.

@Composable
internal fun DailyMissionCard() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var mission by remember { mutableStateOf<DailyMission?>(null) }
    var claimed by remember { mutableStateOf(false) }
    var writing by remember { mutableStateOf(false) }

    // Read on every entry to Today, not once: the 06:45 job may have written one while the app sat in
    // the background, and the process outlives a night.
    LaunchedEffect(Unit) {
        mission = DailyMissionStore.today(context)
        claimed = mission?.let { XpLedger.isClaimed(context, it.claimKey) } ?: false
    }

    val current = mission ?: return

    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.space12)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SectionHeader(
                    uiString(R.string.mission_title),
                    modifier = Modifier.weight(1f),
                )
                StatePill(
                    title = uiString(R.string.mission_xp, current.xp),
                    tone = if (claimed) StrandTone.Neutral else StrandTone.Accent,
                    showsDot = false,
                )
            }
            Text(
                current.text,
                style = NoopType.subhead,
                color = Palette.textPrimary,
            )
            if (claimed) {
                Text(
                    uiString(R.string.mission_claimed),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                )
            } else {
                NoopButton(
                    text = uiString(R.string.mission_claim),
                    fullWidth = true,
                    enabled = !writing,
                    onClick = {
                        // The ledger decides, not the button: a second tap after a recomposition adds
                        // nothing because the claim key is already recorded.
                        if (XpLedger.award(context, current.claimKey, current.xp)) {
                            claimed = true
                        }
                    },
                )
            }
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
