package com.sagearbor.feltnotes.wear

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import com.sagearbor.feltnotes.pulse.PulseProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Foreground service (type "health") that owns the heart-rate session while
 * Pulse is running, so it keeps going with the screen off. Sends batched
 * samples to the phone about every 2 s and `/state` on every change.
 */
class PulseService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var session: HeartRateSession? = null
    private var flushJob: Job? = null
    private val pending = ArrayList<PulseProtocol.Sample>() // main thread only
    private var lastFlushAt = 0L
    private var lastT = Long.MIN_VALUE

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        alive = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> scope.launch { stopPulse(err = null) }
            else -> startPulse()
        }
        return START_NOT_STICKY
    }

    private fun startPulse() {
        if (!goForeground()) return
        if (session != null) {
            // Already running: answer the ctl with the current state.
            publishState(this, running = true, err = null)
            return
        }
        if (!HrPermission.granted(this)) {
            scope.launch { stopPulse(PulseErr.NO_PERMISSION) }
            return
        }
        val s = HeartRateSession(this, onSample = ::onSample, onLost = {
            scope.launch { stopPulse(PulseErr.SENSOR_ERROR) }
        })
        session = s
        pending.clear()
        lastT = Long.MIN_VALUE
        scope.launch {
            val err = s.start()
            if (err != null) {
                stopPulse(err)
                return@launch
            }
            publishState(this@PulseService, running = true, err = null)
            lastFlushAt = SystemClock.elapsedRealtime()
            flushJob = scope.launch {
                while (isActive) {
                    delay(FLUSH_MS)
                    flush()
                }
            }
        }
    }

    /** startForeground with type health; false (and state sent) if Android refuses,
     * e.g. a phone ctl arrived while the app was in the background. */
    private fun goForeground(): Boolean = try {
        val n = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
        } else {
            startForeground(NOTIF_ID, n)
        }
        true
    } catch (e: Exception) {
        Log.w(TAG, "startForeground refused: $e")
        val err = if (HrPermission.granted(this)) PulseErr.NEEDS_TAP else PulseErr.NO_PERMISSION
        publishState(this, running = false, err = err)
        postTapToStart(this)
        stopSelf()
        false
    }

    private fun onSample(s: PulseProtocol.Sample) {
        if (s.tMs <= lastT) return
        lastT = s.tMs
        pending.add(s)
        PulseBus.update { it.copy(bpm = s.bpm) }
        // Screen-off deliveries come in batches; flush right away if due so
        // we don't rely on the timer while the CPU sleeps.
        if (SystemClock.elapsedRealtime() - lastFlushAt >= FLUSH_MS) flush()
    }

    private fun flush() {
        lastFlushAt = SystemClock.elapsedRealtime()
        if (pending.isEmpty()) return
        val batch = pending.toList()
        pending.clear()
        PhoneLink.send(this, PulseProtocol.Message.Hr(batch))
    }

    private suspend fun stopPulse(err: String?) {
        flushJob?.cancel()
        flushJob = null
        flush()
        val s = session
        session = null
        s?.stop()
        publishState(this, running = false, err = err)
        PulseBus.update { it.copy(bpm = null) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        val s = session
        session = null
        if (s != null) {
            // Killed without a stop: still end the exercise and tell the phone.
            CoroutineScope(Dispatchers.Main).launch { s.stop() }
            publishState(this, running = false, err = null)
        }
        scope.cancel()
        alive = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        ensureChannel(this)
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, PulseService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_pulse)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(getString(R.string.notif_running))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_WORKOUT)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .build()
    }

    companion object {
        private const val TAG = "FeltPulse"
        private const val CHANNEL_ID = "pulse"
        private const val NOTIF_ID = 1
        private const val TAP_NOTIF_ID = 2
        private const val FLUSH_MS = 2_000L
        const val ACTION_START = "com.sagearbor.feltnotes.wear.START"
        const val ACTION_STOP = "com.sagearbor.feltnotes.wear.STOP"
        const val EXTRA_AUTOSTART = "autostart"

        /** Last state sent, so a ctl for the current state still gets a reply. */
        @Volatile var running = false
            private set
        @Volatile private var alive = false

        fun publishState(ctx: Context, running: Boolean, err: String?) {
            this.running = running
            PulseBus.update { it.copy(running = running, err = err) }
            PhoneLink.send(ctx, PulseProtocol.Message.State(running, err))
        }

        /** From the screen or a phone ctl. */
        fun start(ctx: Context) {
            val intent = Intent(ctx, PulseService::class.java).setAction(ACTION_START)
            try {
                ctx.startForegroundService(intent)
            } catch (e: Exception) {
                // Background start not allowed (Android 12+), e.g. a phone ctl.
                Log.w(TAG, "startForegroundService refused: $e")
                val err = if (HrPermission.granted(ctx)) PulseErr.NEEDS_TAP else PulseErr.NO_PERMISSION
                publishState(ctx, running = false, err = err)
                postTapToStart(ctx)
            }
        }

        fun stop(ctx: Context) {
            if (!alive) {
                publishState(ctx, running = false, err = null)
                return
            }
            try {
                ctx.startService(Intent(ctx, PulseService::class.java).setAction(ACTION_STOP))
            } catch (e: Exception) {
                // Background start of a non-running service: just stop it.
                ctx.stopService(Intent(ctx, PulseService::class.java))
                publishState(ctx, running = false, err = null)
            }
        }

        private fun ensureChannel(ctx: Context) {
            val nm = ctx.getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, ctx.getString(R.string.channel_name), NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
        }

        /** The phone asked to start but Android needs the user: one tap opens the app and starts. */
        fun postTapToStart(ctx: Context) {
            try {
                ensureChannel(ctx)
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
                ctx.getSystemService(NotificationManager::class.java).notify(TAP_NOTIF_ID, n)
            } catch (e: Exception) {
                Log.w(TAG, "tap-to-start notification: $e")
            }
        }

        fun clearTapToStart(ctx: Context) {
            ctx.getSystemService(NotificationManager::class.java).cancel(TAP_NOTIF_ID)
        }
    }
}
