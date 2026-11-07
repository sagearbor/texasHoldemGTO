package com.sagearbor.feltnotes.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.sagearbor.feltnotes.pulse.PulseProtocol
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

/**
 * Pulse mode, phone side of the Wear OS link (docs/PULSE.md):
 * `EventChannel("feltnotes/pulse/events")` forwards the watch's `/hr` and
 * `/state` messages as maps while Dart listens; `MethodChannel
 * ("feltnotes/pulse/ctl")` answers status / start / stop / openWatchStore.
 * The JSON parser is shared with the watch app
 * (watch/wear/protocol, added as a source dir in build.gradle).
 */
class PulseChannel(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler, MessageClient.OnMessageReceivedListener {
    private val ctx = context.applicationContext
    private val ctl = MethodChannel(messenger, "feltnotes/pulse/ctl")
    private val events = EventChannel(messenger, "feltnotes/pulse/events")
    private val main = Handler(Looper.getMainLooper())
    // Blocking Play-services calls (Tasks.await) run here, never on main.
    private val io = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    private var listening = false

    init {
        ctl.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    // ---- events ----

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (!listening) {
            try {
                Wearable.getMessageClient(ctx).addListener(this)
                listening = true
            } catch (e: Exception) {
                Log.w(TAG, "addListener: $e")
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        removeListener()
    }

    override fun onMessageReceived(event: MessageEvent) {
        val msg = PulseProtocol.parse(event.path, String(event.data, Charsets.UTF_8)) ?: return
        if (msg is PulseProtocol.Message.Ctl) return // phone -> watch only
        val map = PulseProtocol.toChannelMap(msg)
        main.post { sink?.success(map) }
    }

    private fun removeListener() {
        if (!listening) return
        listening = false
        try {
            Wearable.getMessageClient(ctx).removeListener(this)
        } catch (e: Exception) {
            Log.w(TAG, "removeListener: $e")
        }
    }

    /** Engine going away (MainActivity.cleanUpFlutterEngine). */
    fun dispose() {
        sink = null
        removeListener()
        ctl.setMethodCallHandler(null)
        events.setStreamHandler(null)
        io.shutdown()
    }

    // ---- methods ----

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val work: () -> Any? = when (call.method) {
            "status" -> ::status
            "start" -> { { sendCtl(PulseProtocol.CMD_START) } }
            "stop" -> { { sendCtl(PulseProtocol.CMD_STOP) } }
            "openWatchStore" -> ::openWatchStore
            else -> return result.notImplemented()
        }
        try {
            io.execute {
                val value = try {
                    work()
                } catch (e: Exception) {
                    Log.w(TAG, "${call.method}: $e")
                    if (call.method == "status") notSupported() else false
                }
                main.post { result.success(value) }
            }
        } catch (e: Exception) {
            result.success(if (call.method == "status") notSupported() else false)
        }
    }

    private fun notSupported() =
        mapOf("supported" to false, "paired" to false, "appInstalled" to false, "reachable" to false)

    private fun <T> await(task: Task<T>): T = Tasks.await(task, TIMEOUT_S, TimeUnit.SECONDS)

    /** Wear APIs usable: Play services present and the Wear OS app installed
     * (without it the Wearable API reports API_UNAVAILABLE). */
    private fun wearApiAvailable(): Boolean {
        if (GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(ctx) != ConnectionResult.SUCCESS) {
            return false
        }
        return try {
            await(Wearable.getNodeClient(ctx).connectedNodes)
            true
        } catch (e: ExecutionException) {
            (e.cause as? ApiException)?.statusCode != API_UNAVAILABLE
        } catch (e: TimeoutException) {
            true // slow, not missing
        }
    }

    private fun watchNodes(filter: Int): Set<String> =
        await(Wearable.getCapabilityClient(ctx).getCapability(PulseProtocol.CAPABILITY_WATCH, filter))
            .nodes.map { it.id }.toSet()

    private fun status(): Map<String, Boolean> {
        if (!wearApiAvailable()) return notSupported()
        val connected = await(Wearable.getNodeClient(ctx).connectedNodes)
        val installed = watchNodes(CapabilityClient.FILTER_ALL)
        val reachable = watchNodes(CapabilityClient.FILTER_REACHABLE)
        // "Paired": a watch is connected now, or one that ever advertised a
        // capability is known to the Data Layer (paired but out of range).
        val known = connected.isNotEmpty() || installed.isNotEmpty() ||
            await(Wearable.getCapabilityClient(ctx).getAllCapabilities(CapabilityClient.FILTER_ALL))
                .values.any { it.nodes.isNotEmpty() }
        return mapOf(
            "supported" to true,
            "paired" to known,
            "appInstalled" to installed.isNotEmpty(),
            "reachable" to reachable.isNotEmpty(),
        )
    }

    /** Sends `/ctl` to every reachable watch with Felt Notes Pulse; true if one got it. */
    private fun sendCtl(cmd: String): Boolean {
        if (!wearApiAvailable()) return false
        val bytes = PulseProtocol.encodeCtl(cmd).toByteArray(Charsets.UTF_8)
        var ok = false
        for (node in watchNodes(CapabilityClient.FILTER_REACHABLE)) {
            try {
                await(Wearable.getMessageClient(ctx).sendMessage(node, PulseProtocol.PATH_CTL, bytes))
                ok = true
            } catch (e: Exception) {
                Log.w(TAG, "ctl $cmd to $node: $e")
            }
        }
        return ok
    }

    /** Opens the Play Store page for the watch app on the connected watch(es)
     * that don't have it yet (all connected watches if every one has it). */
    private fun openWatchStore(): Boolean {
        if (!wearApiAvailable()) return false
        val connected = await(Wearable.getNodeClient(ctx).connectedNodes).map { it.id }
        if (connected.isEmpty()) return false
        val installed = watchNodes(CapabilityClient.FILTER_ALL)
        val targets = connected.filter { it !in installed }.ifEmpty { connected }
        val intent = Intent(Intent.ACTION_VIEW)
            .addCategory(Intent.CATEGORY_BROWSABLE)
            .setData(Uri.parse("market://details?id=$APP_ID"))
        // Its own executor: we block on the result from `io`.
        val exec = Executors.newSingleThreadExecutor()
        try {
            val helper = RemoteActivityHelper(ctx, exec)
            var ok = false
            for (node in targets) {
                try {
                    helper.startRemoteActivity(intent, node).get(TIMEOUT_S, TimeUnit.SECONDS)
                    ok = true
                } catch (e: Exception) {
                    Log.w(TAG, "openWatchStore on $node: $e")
                }
            }
            return ok
        } finally {
            exec.shutdown()
        }
    }

    private companion object {
        const val TAG = "FeltPulse"
        const val APP_ID = "com.sagearbor.feltnotes.app"
        const val TIMEOUT_S = 8L
        // ConnectionResult.API_UNAVAILABLE: the Wearable API without the Wear OS app.
        const val API_UNAVAILABLE = ConnectionResult.API_UNAVAILABLE
    }
}
