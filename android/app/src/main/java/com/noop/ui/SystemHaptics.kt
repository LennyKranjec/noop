package com.noop.ui

import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

// MARK: - The app you can feel
//
// The wearer asked for the whole app to be haptic, so the bond between human and system is something
// the hand notices and not just the eye. That is a real design goal and also a real hazard: a phone
// that buzzes at everything becomes a phone people silence, and then the ONE buzz that mattered — a
// quest arriving — is gone with the rest.
//
// So this is a small, deliberate vocabulary rather than a vibrate() call scattered through the UI:
//
//   · TICK      — a letter landing as the system types. Barely there, and there are hundreds of them.
//   · TAP       — a control answered. The everyday one.
//   · SELECT    — a choice changed: a tab, a segment, a model.
//   · CONFIRM   — something committed: a quest accepted, XP claimed.
//   · SUMMON    — the system wants attention. Reserved for a quest arriving, and nothing else.
//
// AMPLITUDE IS THE POINT, not duration. A 10 ms buzz at full strength is a jolt; the same 10 ms at a
// quarter is a tick you feel in the fingertip and not in the room. Devices without amplitude control
// fall back to duration alone, which is coarser but never silent.
//
// Every call is best-effort and swallows its failures: haptics are a garnish, and a missing vibrator,
// a revoked permission or a manufacturer quirk must never be able to take down the screen using it.

object SystemHaptics {

    /** One of the five gestures above. Named for what it MEANS, not for how long it buzzes. */
    enum class Cue(val millis: Long, val amplitude: Int) {
        /** Per-letter typewriter tick. Must be cheap: a 200-character line fires this 200 times. */
        TICK(7L, 40),
        TAP(12L, 90),
        SELECT(16L, 130),
        CONFIRM(28L, 200),
        SUMMON(0L, 0),
    }

    /**
     * The summon pattern: three rising pulses, because a quest arriving should not feel like a
     * notification. Expressed as a waveform rather than a Cue duration, which is why [Cue.SUMMON]
     * carries zeroes — it is handled separately below.
     */
    private val SUMMON_TIMINGS = longArrayOf(0, 40, 60, 40, 60, 90)
    private val SUMMON_AMPLITUDES = intArrayOf(0, 110, 0, 170, 0, 255)

    private const val PREF_KEY = "haptics.appWide"

    /**
     * Whether the app-wide haptics fire. DEFAULT ON — the wearer asked for a phone they can feel — but
     * switchable, because this is exactly the kind of thing that is delightful for a week and then
     * is not.
     */
    fun enabled(context: Context): Boolean =
        prefs(context).getBoolean(PREF_KEY, true)

    fun setEnabled(context: Context, value: Boolean) {
        prefs(context).edit().putBoolean(PREF_KEY, value).apply()
    }

    /** Fire [cue]. Silent no-op when haptics are off, unsupported, or the device refuses. */
    fun play(context: Context, cue: Cue) {
        if (!enabled(context)) return
        val vibrator = vibrator(context) ?: return
        runCatching {
            if (cue == Cue.SUMMON) {
                vibrator.vibrate(effectFor(vibrator, SUMMON_TIMINGS, SUMMON_AMPLITUDES))
            } else {
                vibrator.vibrate(oneShot(vibrator, cue))
            }
        }
    }

    /**
     * A tick that does NOT re-read preferences.
     *
     * The typewriter fires one per letter at roughly 25 Hz, and a SharedPreferences read per letter is
     * both wasteful and — on a slow device — enough to make the animation stutter. The caller reads the
     * preference once, holds the [Vibrator], and calls this.
     */
    fun tick(vibrator: Vibrator?) {
        val v = vibrator ?: return
        runCatching { v.vibrate(oneShot(v, Cue.TICK)) }
    }

    /** The system vibrator, or null where there is none. Cached by the platform, cheap to re-fetch. */
    fun vibrator(context: Context): Vibrator? = runCatching {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }.getOrNull()?.takeIf { it.hasVibrator() }

    private fun oneShot(vibrator: Vibrator, cue: Cue): VibrationEffect =
        if (vibrator.hasAmplitudeControl()) {
            VibrationEffect.createOneShot(cue.millis, cue.amplitude)
        } else {
            // No amplitude control: the only knob left is time, and a 7 ms tick is imperceptible on
            // these. Scaling by the intended strength keeps the five cues distinguishable.
            VibrationEffect.createOneShot(
                (cue.millis * (1 + cue.amplitude / 128)).coerceAtLeast(10L),
                VibrationEffect.DEFAULT_AMPLITUDE,
            )
        }

    private fun effectFor(vibrator: Vibrator, timings: LongArray, amplitudes: IntArray): VibrationEffect =
        if (vibrator.hasAmplitudeControl()) {
            VibrationEffect.createWaveform(timings, amplitudes, -1)
        } else {
            VibrationEffect.createWaveform(timings, -1)
        }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences("noop_haptics_prefs", Context.MODE_PRIVATE)
}
