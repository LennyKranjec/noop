package com.noop.ui

import android.content.Context
import com.noop.ingest.HealthConnectImporter
import com.noop.ingest.WhoopCloudSync
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// MARK: - One pull, every source
//
// The pull-to-refresh gesture on Today used to do ONE thing — ask the strap for an offload — and only
// when the strap happened to be connected, bonded and handshaken. Every other source in the app was
// refreshed by opening the screen that read it, or by a manual import, so "refresh" meant something
// different depending on what the wearer was looking at. That is the gesture doing a quarter of what it
// looks like it does.
//
// IT NOW RUNS EVERY SOURCE THAT CAN BE RUN, and the ones that cannot are skipped rather than blocking:
//
//   · THE STRAP — a BLE offload, still gated by the client's own preconditions. Requesting a sync from
//     a strap that is not there does nothing, so the gate stays where it was.
//   · WHOOP'S CLOUD — their own recovery, day strain and sleep performance, which are proprietary and
//     which nothing on this phone can reproduce from raw signal. Skipped silently when not connected.
//   · HEALTH CONNECT — the full import, which is where Apple Health data reaches this app on Android.
//     There is no Apple Health API here; Apple's own store is reachable only through whichever app
//     mirrors it into Health Connect, and on iOS the twin of this reads HealthKit directly.
//   · TODAY'S LIVE TOP-UPS — steps and macros, which keep climbing after an import has been taken and
//     are therefore stale within minutes of one.
//
// THE GESTURE IS ALWAYS AVAILABLE. It used to disappear when the strap was not ready, which is a
// control that vanishes exactly when somebody is trying to work out why their data has not arrived.
// There is always something to refresh now, so there is always a reason to offer it.
//
// EVERY STEP IS BEST-EFFORT AND INDEPENDENT. A Health Connect provider that is mid-update must not stop
// the strap sync, and a strap that is out of range must not stop the macros. Each failure costs its own
// source's refresh and nothing else's.

/** What one pull actually managed to do, so the caller can say so rather than guess. */
internal data class RefreshOutcome(
    val strapRequested: Boolean,
    /** Days pulled from WHOOP's cloud. Zero when not connected, which is the normal case. */
    val whoopCloudDays: Int = 0,
    val healthConnectImported: Boolean,
    val stepsToppedUp: Boolean,
    val macrosToppedUp: Boolean,
) {
    val didSomething: Boolean
        get() = strapRequested || whoopCloudDays > 0 || healthConnectImported ||
            stepsToppedUp || macrosToppedUp
}

/**
 * Refresh every source this device can reach, and return what happened.
 *
 * Suspends until the reads are done. The STRAP is the exception and deliberately so: a historical
 * offload runs for minutes and reports its own progress through the sync chip, so this asks for it and
 * moves on rather than holding the spinner for the length of a backfill.
 */
internal suspend fun refreshAllSources(
    context: Context,
    viewModel: AppViewModel,
    /** False when the strap's own preconditions are not met — see `todayPullToSyncEnabled`. */
    strapReady: Boolean,
): RefreshOutcome = withContext(Dispatchers.IO) {
    val strap = if (!strapReady) false else runCatching { viewModel.syncNow(); true }.getOrDefault(false)

    // WHOOP'S OWN SCORES, over the internet. Independent of the strap sync above: the cloud has the
    // recovery percentage and the day strain that nothing on this phone can reproduce, and the strap
    // has the raw signal the cloud never sends. Neither substitutes for the other.
    val whoopDays = runCatching {
        WhoopCloudSync.sync(context, viewModel.repo).days
    }.getOrDefault(0)

    // The full Health Connect import: everything the wearer granted, aggregated per local day. Returns a
    // summary rather than throwing, but the call itself can still fail on a provider that is updating.
    val hc = runCatching {
        HealthConnectImporter.import(context, viewModel.repo).counts.isNotEmpty()
    }.getOrDefault(false)

    // The two live top-ups, which an import alone leaves stale: both are figures that keep moving
    // through the day, and both are cheap single reads of today only.
    val steps = runCatching {
        HealthConnectImporter.refreshTodaySteps(context, viewModel.repo) != null
    }.getOrDefault(false)
    val macros = runCatching {
        HealthConnectImporter.refreshTodayMacros(context, viewModel.repo) != null
    }.getOrDefault(false)

    // Everything downstream reads Room, so one reload is what makes the refresh visible.
    runCatching { viewModel.loadWorkouts() }

    RefreshOutcome(
        strapRequested = strap,
        whoopCloudDays = whoopDays,
        healthConnectImported = hc,
        stepsToppedUp = steps,
        macrosToppedUp = macros,
    )
}
