package com.sagearbor.feltnotes.wear

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import com.sagearbor.feltnotes.pulse.PulseProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Owns the heart-rate session. v1 has NO foreground service: Pulse runs while
 * [MainActivity] is on screen (kept on, dimming to ambient), and stops when
 * the activity leaves the screen. Sends batched samples to the phone about
 * every 2 s and `/state` on every change. All calls on the main thread.
 *
 * The screen-off version (a "health" foreground service, PulseService.kt) is
 * in git history at commit 6d9cc73; it needs Play's FOREGROUND_SERVICE_HEALTH
 * declaration before it can ship.
 */
object PulseController {
    private const val TAG = "FeltPulse"
    private const val CHANNEL_ID = "pulse"
    private const val TAP_NOTIF_ID = 2
    private const val FLUSH_MS = 2_000L
    const val EXTRA_AUTOSTART = "autostart"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var session: HeartRateSession? = null
    private var flushJob: Job? = null
    private val pending = ArrayList<PulseProtocol.Sample>()
    private var lastFlushAt = 0L
    private var lastT = Long.MIN_VALUE

    /** True while MainActivity is started (on screen, ambient included). */
    var activityVisible = false

    val running: Boolean get() = session != null

    fun publishState(ctx: Context, running: Boolean, err: String?) {
        PulseBus.update { it.copy(running = running, err = err) }
        PhoneLink.send(ctx, PulseProtocol.Message.State(running, err))
    }

    /** Start from the screen (permission already asked by the activity). */
    fun start(ctx: Context) {
        val app = ctx.applicationContext
        if (session != null) {
            publishState(app, running = true, err = null) // reply to a repeated start
            return
        }
        if (!HrPermission.granted(app)) {
            publishState(app, running = false, err = PulseErr.NO_PERMISSION)
            return
        }
        val s = HeartRateSession(app, onSample = { onSample(app, it) }, onLost = {
            scope.launch { stop(app, PulseErr.SENSOR_ERROR) }
        })
        session = s
        pending.clear()
        lastT = Long.MIN_VALUE
        scope.launch {
            val err = s.start()
            if (session !== s) { // stopped while starting
                s.stop()
                return@launch
            }
            if (err != null) {
                stop(app, err)
                return@launch
            }
            publishState(app, running = true, err = null)
            lastFlushAt = SystemClock.elapsedRealtime()
            flushJob = scope.launch {
                while (isActive) {
                    delay(FLUSH_MS)
                    flush(app)
                }
            }
        }
    }

    /** Stop and tell the phone. */
    fun stop(ctx: Context, err: String? = null) {
        val app = ctx.applicationContext
        flushJob?.cancel()
        flushJob = null
        flush(app)
        val s = session
        session = null
        if (s != null) scope.launch { s.stop() }
        PulseBus.update { it.copy(bpm = null) }
        publishState(app, running = false, err = err)
    }

    /** `/ctl` from the phone. Without the app on screen we can't measure, so
     * the watch shows a "Tap to start" notification that opens the app. */
    fun onCtl(ctx: Context, cmd: String) {
        when (cmd) {
            PulseProtocol.CMD_STOP -> stop(ctx)
            PulseProtocol.CMD_START -> when {
                !HrPermission.granted(ctx) -> {
                    publishState(ctx, running = false, err = PulseErr.NO_PERMISSION)
                    if (!activityVisible) postTapToStart(ctx)
                }
                activityVisible -> start(ctx)
                else -> {
                    publishState(ctx, running = false, err = PulseErr.NEEDS_TAP)
                    postTapToStart(ctx)
                }
            }
        }
    }

    private fun onSample(ctx: Context, s: PulseProtocol.Sample) {
        if (s.tMs <= lastT) return
        lastT = s.tMs
        pending.add(s)
        PulseBus.update { it.copy(bpm = s.bpm) }
        // Ambient mode may throttle the timer; flush on arrival when due.
        if (SystemClock.elapsedRealtime() - lastFlushAt >= FLUSH_MS) flush(ctx)
    }

    private fun flush(ctx: Context) {
        lastFlushAt = SystemClock.elapsedRealtime()
        if (pending.isEmpty()) return
        val batch = pending.toList()
        pending.clear()
        PhoneLink.send(ctx, PulseProtocol.Message.Hr(batch))
    }

    private fun postTapToStart(ctx: Context) {
        try {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, ctx.getString(R.string.channel_name), NotificationManager.IMPORTANCE_HIGH),
                )
            }
            val open = PendingIntent.getActivity(
                ctx, 2,
                Intent(ctx, MainActivity::class.java)
                    .putExtra(EXTRA_AUTOSTART, true)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            val n = Notification.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_pulse)
                .setContentTitle(ctx.getString(R.string.app_name))
                .setContentText(ctx.getString(R.string.notif_tap_to_start))
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
            nm.notify(TAP_NOTIF_ID, n)
        } catch (e: Exception) {
            Log.w(TAG, "tap-to-start notification: $e")
        }
    }

    fun clearTapToStart(ctx: Context) {
        ctx.getSystemService(NotificationManager::class.java).cancel(TAP_NOTIF_ID)
    }
}
