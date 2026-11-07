package com.sagearbor.feltnotes.wear

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import com.sagearbor.feltnotes.pulse.PulseProtocol

/** `/feltnotes/pulse/v1/ctl` from the phone: start or stop Pulse. Works with
 * the watch app closed (Play services binds this service on demand). */
class PulseListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        val json = String(event.data, Charsets.UTF_8)
        val msg = PulseProtocol.parse(event.path, json) as? PulseProtocol.Message.Ctl
        if (msg == null) {
            Log.w("FeltPulse", "ignored ${event.path}: $json")
            return
        }
        // Service starts belong on the main thread; this callback is not.
        Handler(Looper.getMainLooper()).post {
            when (msg.cmd) {
                PulseProtocol.CMD_START -> PulseService.start(applicationContext)
                PulseProtocol.CMD_STOP -> PulseService.stop(applicationContext)
            }
        }
    }
}
