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
import androidx.work.workDataOf
import com.noop.R
import com.noop.ai.CoachGoals
import com.noop.ai.LocalModel
import com.noop.ai.LocalOneShot
import com.noop.ai.Reminder
import com.noop.ai.ReminderStore
import java.time.LocalDate
import java.util.Calendar
import java.util.concurrent.TimeUnit

// MARK: - Reminders that are written, not templated
//
// Every reminder gets its own daily WorkManager job. When one fires, the FAST model writes the
// notification text from that reminder's context — so "Bedtime, they want eight hours" becomes a
// different sentence each night, about their reason, in the coach's voice. A reminder that said the
// same fifteen words every day is a reminder people turn off in a week.
//
// WHY A DAILY JOB FOR EVERY REPEAT RULE. WorkManager can only repeat on a fixed period, and weekdays
// are not a fixed period. So every reminder runs daily and the WORKER decides whether today counts
// ([Reminder.firesOn]). One code path, no arithmetic that drifts across a DST boundary, and a rule
// change needs no rescheduling.
//
// WHY WORKMANAGER AND NOT AN EXACT ALARM. Same reasoning as [CoachBriefScheduler]: a nudge arriving a
// few minutes into a maintenance window is fine, and it must survive a reboot without asking the
// wearer for the exact-alarm permission. A reminder is not an alarm clock — [SmartAlarm] is, and that
// one does use exact alarms.
//
// IF THE MODEL CANNOT BE REACHED (not installed, or the wearer is mid-conversation and holding the
// engine — see LocalCoachEngine.tryInLane) the notification still goes out, carrying the reminder's own
// context as its text. Late and generic beats absent: the wearer asked to be reminded, not to be
// reminded eloquently.

object ReminderScheduler {

    private const val WORK_PREFIX = "noop_reminder_"
    private const val KEY_ID = "reminderId"

    private const val CHANNEL_ID = "noop_coach_reminders"

    /** Unique work name for one reminder, so rescheduling addresses the same job. */
    private fun workName(id: String) = WORK_PREFIX + id

    /**
     * (Re)schedule every stored reminder and cancel the jobs of any that are gone.
     *
     * Called on app start (so the schedule self-heals after a reboot) and after any change. Cheap:
     * WorkManager keeps an existing job's anchor rather than resetting it on every launch.
     */
    fun rescheduleAll(context: Context) {
        val ctx = context.applicationContext
        ReminderStore.all(ctx).forEach { schedule(ctx, it) }
    }

    /** Arm one reminder, or cancel its job when it is disabled. */
    fun schedule(context: Context, reminder: Reminder) {
        val wm = WorkManager.getInstance(context.applicationContext)
        if (!reminder.enabled) {
            wm.cancelUniqueWork(workName(reminder.id))
            return
        }
        val request = PeriodicWorkRequestBuilder<ReminderWorker>(1, TimeUnit.DAYS)
            .setInitialDelay(delayToNextOccurrenceMs(reminder.minuteOfDay), TimeUnit.MILLISECONDS)
            .setInputData(workDataOf(KEY_ID to reminder.id))
            .build()
        // REPLACE, not KEEP: the time may have just changed, and the anchor is the whole point of the
        // job. [CoachBriefScheduler] can use KEEP because its time change has a separate entry point;
        // here every call is a change.
        wm.enqueueUniquePeriodicWork(workName(reminder.id), ExistingPeriodicWorkPolicy.REPLACE, request)
    }

    fun cancel(context: Context, id: String) {
        WorkManager.getInstance(context.applicationContext).cancelUniqueWork(workName(id))
    }

    /**
     * Milliseconds until the next wall-clock occurrence of [minuteOfDay]. Pure + injectable so the
     * arithmetic has a test. Same shape as [CoachBriefScheduler.delayToNextOccurrenceMs].
     */
    fun delayToNextOccurrenceMs(minuteOfDay: Int, nowMs: Long = System.currentTimeMillis()): Long {
        val next = Calendar.getInstance().apply {
            timeInMillis = nowMs
            set(Calendar.HOUR_OF_DAY, minuteOfDay / 60)
            set(Calendar.MINUTE, minuteOfDay % 60)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowMs) add(Calendar.DAY_OF_YEAR, 1)
        }
        return next.timeInMillis - nowMs
    }

    /**
     * The framing the Fast model writes a notification under.
     *
     * Short and hard-edged on length, because this lands in a notification banner and a model told
     * "be brief" without a number writes a paragraph. The goals ride along so the nudge can connect
     * the reminder to what it is FOR, which is the difference between "go to bed" and "go to bed if
     * you still want that sub-20 5k".
     */
    internal fun notificationPrompt(context: Context): String = buildString {
        append("You write one push notification. ONE sentence, at most 20 words, no greeting, no ")
        append("emoji, no quotation marks. Motivating and dryly funny — tease the excuse, never the ")
        append("person. Write it as if speaking to them directly. Output the sentence and nothing else.")
        CoachGoals.promptSection(context)?.let { append("\n\n").append(it) }
    }

    /** What the notification says when the model was unavailable: the wearer's own words, unchanged. */
    internal fun fallbackText(reminder: Reminder): String = reminder.context

    @SuppressLint("MissingPermission") // guarded by areNotificationsEnabled() + runCatching
    internal fun post(context: Context, reminder: Reminder, body: String) {
        runCatching {
            if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
            ensureChannel(context)
            val n = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(context.getString(R.string.reminder_notification_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setContentIntent(
                    android.app.PendingIntent.getActivity(
                        context,
                        // Distinct per reminder, so two firing in the same minute do not overwrite
                        // each other's intent.
                        reminder.id.hashCode(),
                        appLaunchIntent(context),
                        android.app.PendingIntent.FLAG_IMMUTABLE or
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT,
                    ),
                )
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_REMINDER)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
            // Per-reminder id for the same reason: each is its own notification, not a replacement.
            NotificationManagerCompat.from(context).notify(reminder.id.hashCode(), n)
        }
    }

    private fun ensureChannel(context: Context) {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
        runCatching {
            val mgr = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            mgr.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    context.getString(R.string.reminder_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply { description = context.getString(R.string.reminder_channel_desc) },
            )
        }
    }

    /**
     * The daily job for one reminder.
     *
     * Returns success in every branch, including the ones that post nothing: a reminder that is not due
     * today, or has been deleted, is not a failure, and letting WorkManager retry it would post the
     * same nudge again on a backoff.
     */
    class ReminderWorker(appContext: Context, params: WorkerParameters) :
        CoroutineWorker(appContext, params) {

        override suspend fun doWork(): Result {
            val ctx = applicationContext
            val id = inputData.getString(KEY_ID) ?: return Result.success()
            // Read fresh rather than trusting the input data: the context and time may have been
            // edited since the job was armed, and the reminder may be gone entirely.
            val reminder = ReminderStore.find(ctx, id) ?: run {
                cancel(ctx, id)
                return Result.success()
            }
            if (!reminder.firesOn(LocalDate.now())) return Result.success()

            val written = runCatching {
                LocalOneShot.generate(
                    context = ctx,
                    // ALWAYS the fast model, never the deep one: this runs unattended on a phone that
                    // may be asleep in someone's pocket, and the 2B spends minutes on a sentence.
                    model = LocalModel.FAST,
                    systemPrompt = notificationPrompt(ctx),
                    question = "Remind them: ${reminder.context}",
                    maxChars = 180,
                )
            }.getOrNull()

            post(ctx, reminder, written ?: fallbackText(reminder))
            return Result.success()
        }
    }
}
