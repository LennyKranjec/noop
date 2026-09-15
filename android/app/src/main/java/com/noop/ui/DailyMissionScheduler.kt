package com.noop.ui

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.noop.R
import com.noop.ai.AiCoach
import com.noop.ai.DailyMission
import com.noop.ai.DailyMissionStore
import com.noop.ai.DailyMissionWriter
import com.noop.ai.LocalModel
import com.noop.ai.LocalModelStore
import com.noop.ai.LocalOneShot
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import java.time.LocalDate
import java.util.concurrent.TimeUnit

// MARK: - The 06:45 mission
//
// Once a day, before the wearer is properly awake, the deep model reads the night and writes one thing
// to do. See [DailyMissionWriter] for what it is asked and why the deep model gets this job.
//
// THE TIME IS FIXED. Quarter to seven is early enough that the mission is waiting when they pick the
// phone up and late enough that the night's sleep data has landed. A setting would have been one more
// thing to configure for a feature whose whole promise is that it is already there.
//
// CONSENT-GATED, like every other coach surface: a mission is generated from their metrics, so without
// "let the coach use my data" there is nothing to generate one from and the job does nothing rather
// than writing something generic and calling it personal.

object DailyMissionScheduler {

    private const val WORK_NAME = "noop_daily_mission"
    private const val CHANNEL_ID = "noop_daily_mission"
    private const val NOTIF_ID = 4215

    /** 06:45 local, as minutes past midnight. */
    const val MISSION_MINUTE_OF_DAY = 6 * 60 + 45

    /**
     * Arm the daily job. Safe to call on every app start — KEEP leaves an existing job's anchor alone.
     */
    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<DailyMissionWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(
                ReminderScheduler.delayToNextOccurrenceMs(MISSION_MINUTE_OF_DAY),
                TimeUnit.MILLISECONDS,
            )
            .build()
        WorkManager.getInstance(context.applicationContext)
            .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    fun cancel(context: Context) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(WORK_NAME)
    }

    /**
     * Generate today's mission now and store it. Returns it, or null when it could not be written.
     *
     * Shared by the scheduled job and the "write it now" action on the mission card, so a wearer who
     * installs at noon is not told to come back tomorrow. [force] skips the once-a-day guard.
     */
    suspend fun generateNow(context: Context, force: Boolean = false): DailyMission? {
        val ctx = context.applicationContext
        val today = LocalDate.now()
        if (!force) DailyMissionStore.today(ctx, today)?.let { return it }
        // The same consent gate the chat honours: a mission is written FROM their metrics, and without
        // access there is nothing to write one from. Generic encouragement dressed as a personal
        // mission would be the dishonest option.
        if (!com.noop.ai.AiKeyStore.readConsent(ctx)) return null

        // The deep model is the point of this feature; the fast one is what keeps it working on a phone
        // that only has the small model installed.
        val model = if (LocalModelStore.isInstalled(ctx, LocalModel.DEEP)) LocalModel.DEEP else LocalModel.FAST

        val aiCoach = AiCoach(
            WhoopRepository(WhoopDatabase.get(ctx)),
            activeStrapId = {
                (ctx as? com.noop.NoopApplication)?.activeDeviceId ?: WhoopRepository.WHOOP_SOURCE
            },
        )
        val grounding = runCatching { aiCoach.localGroundingNow(ctx) }.getOrNull() ?: return null

        val answer = LocalOneShot.generate(
            context = ctx,
            model = model,
            systemPrompt = DailyMissionWriter.systemPrompt(ctx, grounding),
            question = DailyMissionWriter.QUESTION,
            maxChars = 500,
        ) ?: return null

        val mission = DailyMissionWriter.parse(answer, today.toString()) ?: return null
        DailyMissionStore.write(ctx, mission)
        return mission
    }

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    private fun post(context: Context, mission: DailyMission) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val body = CoachBriefScheduler.oneLineSummary(mission.text)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.mission_notification_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(mission.text))
                .setContentIntent(
                    android.app.PendingIntent.getActivity(
                        context, 7, appLaunchIntent(context),
                        android.app.PendingIntent.FLAG_IMMUTABLE or
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            NotificationManagerCompat.from(context).notify(NOTIF_ID, n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.mission_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = context.getString(R.string.mission_channel_desc) },
            )
        }
    }

    /**
     * The job. Success even when nothing was written: no consent, no model, or the wearer happened to
     * be mid-conversation — none of those are retryable, and a backoff would land the mission at a
     * random hour of the afternoon, which is not what a morning mission is.
     */
    class DailyMissionWorker(appContext: Context, params: WorkerParameters) :
        CoroutineWorker(appContext, params) {

        override suspend fun doWork(): Result {
            val mission = runCatching { generateNow(applicationContext) }.getOrNull()
            if (mission != null) post(applicationContext, mission)
            return Result.success()
        }
    }
}
