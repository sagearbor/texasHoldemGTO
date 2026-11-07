package com.sagearbor.feltnotes.wear

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update

/** What the watch screen shows; written by [PulseController] and [PhoneLink]. */
data class PulseUi(
    val running: Boolean = false,
    val bpm: Int? = null,
    val phoneConnected: Boolean = false,
    val err: String? = null,
)

object PulseBus {
    private val _ui = MutableStateFlow(PulseUi())
    val ui: StateFlow<PulseUi> = _ui

    fun update(f: (PulseUi) -> PulseUi) = _ui.update(f)
}

/** Error codes sent in `/state` `err` (documented in docs/PULSE.md). */
object PulseErr {
    /** Heart-rate permission not granted: open the watch app and allow it. */
    const val NO_PERMISSION = "no_permission"
    /** The phone asked to start while the watch app was not on screen; a
     * "Tap to start" notification is on the watch. */
    const val NEEDS_TAP = "needs_tap"
    /** This watch has no heart-rate sensor Health Services can use. */
    const val UNSUPPORTED = "unsupported"
    /** Health Services failed to start or stopped the exercise itself. */
    const val SENSOR_ERROR = "sensor_error"
    /** v1 (no foreground service): the watch app left the screen, Pulse stopped. */
    const val APP_CLOSED = "app_closed"
}

object HrPermission {
    /** Wear OS 6 (API 36) replaced BODY_SENSORS with granular health permissions. */
    val name: String
        get() = if (Build.VERSION.SDK_INT >= 36) "android.permission.health.READ_HEART_RATE"
                else Manifest.permission.BODY_SENSORS

    fun granted(ctx: Context): Boolean =
        ctx.checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED

    /** Asked together at Start: heart rate, plus notifications on API 33+
     * (the "Tap to start" notification; optional). */
    fun toRequest(): Array<String> =
        if (Build.VERSION.SDK_INT >= 33) arrayOf(name, Manifest.permission.POST_NOTIFICATIONS)
        else arrayOf(name)
}
