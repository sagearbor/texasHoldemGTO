package com.sagearbor.feltnotes.wear

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.Wearable
import com.sagearbor.feltnotes.pulse.PulseProtocol
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Watch -> phone messages over the Wearable Data Layer (Bluetooth via the
 * phone's Wear OS app). The watch itself never goes online.
 */
object PhoneLink {
    private const val TAG = "FeltPulse"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    // Keeps hr/state messages in the order they were produced.
    private val sendLock = Mutex()

    /** Phone nodes to talk to: those with Felt Notes (capability declared by
     * the phone app), else every nearby connected node (capability info can
     * lag right after install). */
    suspend fun phoneNodes(ctx: Context): List<String> = try {
        withTimeoutOrNull(5_000) {
            val withApp = Wearable.getCapabilityClient(ctx)
                .getCapability(PulseProtocol.CAPABILITY_PHONE, CapabilityClient.FILTER_REACHABLE)
                .await().nodes.map { it.id }
            withApp.ifEmpty {
                Wearable.getNodeClient(ctx).connectedNodes.await().filter { it.isNearby }.map { it.id }
            }
        } ?: emptyList()
    } catch (e: Exception) {
        Log.w(TAG, "phoneNodes: $e")
        emptyList()
    }

    /** Refreshes the "phone connected" line. */
    suspend fun refresh(ctx: Context) {
        val connected = phoneNodes(ctx).isNotEmpty()
        PulseBus.update { it.copy(phoneConnected = connected) }
    }

    /** Fire-and-forget send to every phone node. */
    fun send(ctx: Context, msg: PulseProtocol.Message) {
        val app = ctx.applicationContext
        scope.launch {
            sendLock.withLock { sendNow(app, msg) }
        }
    }

    private suspend fun sendNow(ctx: Context, msg: PulseProtocol.Message): Boolean {
        val (path, json) = PulseProtocol.encode(msg)
        val nodes = phoneNodes(ctx)
        var ok = false
        for (node in nodes) {
            try {
                withTimeoutOrNull(5_000) {
                    Wearable.getMessageClient(ctx).sendMessage(node, path, json.toByteArray(Charsets.UTF_8)).await()
                }?.let { ok = true }
            } catch (e: Exception) {
                Log.w(TAG, "send $path to $node: $e")
            }
        }
        PulseBus.update { it.copy(phoneConnected = ok) }
        return ok
    }
}
