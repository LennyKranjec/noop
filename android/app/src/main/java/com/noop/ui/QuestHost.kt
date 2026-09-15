package com.noop.ui

import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import com.noop.ai.DailyMissionStore
import com.noop.ai.Quest
import com.noop.ai.QuestGenerator
import com.noop.ai.QuestKind
import com.noop.ai.QuestState
import com.noop.ai.QuestStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate

// MARK: - Deciding when the system speaks
//
// The pop-up is loud on purpose, so what raises it has to be conservative. Three rules hold it back:
//
//   · ONE OFFER AT A TIME. [QuestStore.offered] returns at most one; the rest wait their turn.
//   · TWO SIDE QUESTS A DAY, at most, and one per condition — see QuestGenerator.MAX_SIDE_PER_DAY.
//     A system that can interrupt five times before lunch is uninstalled by lunch.
//   · NOTHING WITHOUT DATA. Every trigger reads a measured figure; a phone with nothing synced raises
//     nothing rather than inventing a reason to nag.
//
// The check runs when the app comes to the foreground, not on a timer: a quest that appears while the
// phone is in a pocket is a quest whose pop-up is missed and whose buzz is mysterious.

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun QuestHost(viewModel: AppViewModel, content: @Composable () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var offered by remember { mutableStateOf<Quest?>(null) }
    var active by remember { mutableStateOf(QuestStore.active(context)) }
    var reviewing by remember { mutableStateOf<Quest?>(null) }

    fun refresh() {
        offered = QuestStore.offered(context)
        active = QuestStore.active(context)
    }

    // On entry: promote today's mission into the daily quest if it has not been already, then look for
    // a side-quest trigger. Both are cheap reads except the model call, which is off the main thread.
    LaunchedEffect(Unit) {
        refresh()
        withContext(Dispatchers.IO) { runCatching { QuestCoordinator.sweep(context, viewModel) } }
        refresh()
    }

    Box(modifier = Modifier.fillMaxSize()) {
        content()

        offered?.let { quest ->
            QuestPopup(
                quest = quest,
                onAccept = {
                    QuestStore.setState(context, quest.id, QuestState.ACTIVE)
                    refresh()
                },
                onDismiss = {
                    QuestStore.setState(context, quest.id, QuestState.DECLINED)
                    refresh()
                },
                // The strap is summoned through the ViewModel, which is the only thing that holds a
                // BLE handle. A no-op when nothing is connected.
                onSummonStrap = { runCatching { viewModel.buzzStrapOnce() } },
            )
        }
    }

    reviewing?.let { quest ->
        ModalBottomSheet(
            onDismissRequest = { reviewing = null },
            containerColor = Palette.surfaceRaised,
            contentColor = Palette.textPrimary,
        ) {
            QuestReviewCard(
                quest = quest,
                onComplete = {
                    // Finishing records the state and nothing else. There is no payout: the level is
                    // measured from the body, so a quest that worked shows up in tomorrow's metrics.
                    QuestStore.setState(context, quest.id, QuestState.COMPLETED)
                    reviewing = null
                    refresh()
                },
                onAbandon = {
                    QuestStore.setState(context, quest.id, QuestState.DECLINED)
                    reviewing = null
                    refresh()
                },
            )
        }
    }

    // Published so the shell can render the strip under the XP bar without owning any of this state.
    ActiveQuests.publish(active) { quest ->
        scope.launch { reviewing = quest }
    }
}

/**
 * The bridge between [QuestHost], which owns the state, and the shell's top bar, which draws the strip.
 *
 * A tiny holder rather than a parameter threaded through the scaffold: the XP bar is built inside
 * `AppRoot`'s `topBar` slot, several composables away from anything that knows about quests, and
 * plumbing a list and a callback through every layer between them would touch a dozen signatures to
 * carry two values.
 */
internal object ActiveQuests {
    // SNAPSHOT STATE, not a plain field. Today reads this during composition, so a plain `var` would be
    // invisible to the recomposer: accepting a quest would update the list and the strip would keep
    // showing the old one until something else on the screen happened to redraw.
    private var quests by mutableStateOf<List<Quest>>(emptyList())
    private var onOpen: (Quest) -> Unit = {}

    fun publish(list: List<Quest>, open: (Quest) -> Unit) {
        quests = list
        onOpen = open
    }

    fun current(): List<Quest> = quests

    fun open(quest: Quest) = onOpen(quest)
}

/**
 * The sweep: everything that might raise a quest, run once when the app comes forward.
 *
 * Off the main thread — it reads the metric store and may run the model to name a quest.
 */
internal object QuestCoordinator {

    suspend fun sweep(context: Context, viewModel: AppViewModel) {
        val today = LocalDate.now()
        val existing = QuestStore.forDay(context, today)

        // 1. The daily quest, promoted from the mission the 06:45 job wrote. Only when a mission for
        // TODAY exists: promoting yesterday's would put a stale directive behind an ACCEPT button.
        if (existing.none { it.kind == QuestKind.DAILY }) {
            DailyMissionStore.today(context, today)?.let { mission ->
                val quest = QuestGenerator.fromMission(context, mission)
                QuestStore.upsert(context, quest)
                return  // One offer at a time: the side-quest check gets the next sweep.
            }
        }

        // 2. A side quest, if the numbers raise one and the day's budget has room.
        val days = runCatching { viewModel.repo.daysMerged(viewModel.activeStrapId) }
            .getOrDefault(emptyList())
        val trigger = QuestGenerator.nextTrigger(
            today = days.lastOrNull(),
            recent = days.takeLast(14),
            existingToday = existing,
        ) ?: return
        val quest = QuestGenerator.fromTrigger(context, trigger)
        QuestStore.upsert(context, quest)
    }
}
