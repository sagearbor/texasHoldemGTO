package com.sagearbor.feltnotes.app

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.uwb.RangingParameters
import androidx.core.uwb.RangingResult
import androidx.core.uwb.UwbAddress
import androidx.core.uwb.UwbClientSessionScope
import androidx.core.uwb.UwbComplexChannel
import androidx.core.uwb.UwbDevice
import androidx.core.uwb.UwbManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID

/**
 * Android-Android UWB ranging (Jetpack androidx.core.uwb), for the
 * seating experiment only; never iPhone-Android. Everything is gated:
 * FEATURE_UWB, Android 12+, the library present, the UWB_RANGING
 * permission, UwbManager.isAvailable. Without any of them every call is a
 * no-op and [capability] says why.
 *
 * Pairing: the phone whose advert key sorts first is the controller and
 * initiates. Over a short BLE GATT connection it writes (in chunks of
 * [index, count, bytes]) a JSON {id, addr, ch, pre, sid, key}: its UWB
 * address, the complex channel, a session id and an 8-byte static STS key;
 * then it reads back the controlee's {id, addr}. Both run a unicast DS-TWR
 * session; it is closed after [rotateMs] so other pairs get their turn.
 * Every stage is sent to Dart as a `uwb_android` event (telemetry), and
 * readings as `uwb` events like the iPhone ones.
 */
@SuppressLint("MissingPermission") // gated by hasPerms() before any Bluetooth / UWB call
class UwbChannel(
    private val activity: MainActivity,
    private val emit: (Map<String, Any?>) -> Unit,
    private val deviceFor: (String) -> BluetoothDevice?,
) {
    companion object {
        val SERVICE: UUID = UUID.fromString("464e5431-0000-4000-8000-0000000000b0")
        val CHAR: UUID = UUID.fromString("464e5431-0000-4000-8000-0000000000b1")
        const val PERM = "android.permission.UWB_RANGING"
        const val MAX_SESSIONS = 2
        const val ROTATE_MS = 60_000L
    }

    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val rng = SecureRandom()
    private var manager: UwbManager? = null
    private var myId: String? = null
    private var server: BluetoothGattServer? = null

    /** peer install id -> its running session. */
    private val sessions = mutableMapOf<String, Job>()

    /** Peripheral side: chunks per connecting device, then the answer. */
    private val inbox = mutableMapOf<String, MutableMap<Int, ByteArray>>()
    private val answers = mutableMapOf<String, ByteArray>()

    private fun now() = System.currentTimeMillis()

    private fun stage(stage: String, extra: Map<String, Any?> = emptyMap()) =
        emit(mapOf("type" to "uwb_android", "stage" to stage, "t" to now()) + extra)

    private fun err(e: Throwable) = mapOf("error" to e.javaClass.simpleName, "message" to (e.message ?: "").take(160))

    // ------------------------------------------------------- capability

    fun feature(): Boolean = activity.packageManager.hasSystemFeature("android.hardware.uwb")

    private fun library(): Boolean = try {
        Class.forName("androidx.core.uwb.UwbManager")
        true
    } catch (_: Throwable) {
        false
    }

    fun permitted(): Boolean = Build.VERSION.SDK_INT >= 31 && activity.hasPerms(listOf(PERM))

    /** The capability check, as one map; isAvailable only when the rest holds. */
    fun capability(done: (Map<String, Any?>) -> Unit) {
        val feature = feature()
        val sdk = Build.VERSION.SDK_INT
        val lib = library()
        val perm = permitted()
        val base = mapOf("feature" to feature, "sdk" to sdk, "lib" to lib, "permission" to perm)
        if (!feature || sdk < 31 || !lib || !perm) return done(base + ("available" to null))
        scope.launch {
            val available = try {
                val m = manager ?: UwbManager.createInstance(activity).also { manager = it }
                withTimeout(5000) { m.isAvailable() }
            } catch (e: Throwable) {
                stage("capability_error", err(e))
                false
            }
            done(base + ("available" to available))
        }
    }

    fun requestPermission(done: (Boolean) -> Unit) {
        if (Build.VERSION.SDK_INT < 31 || !feature()) return done(false)
        activity.requestPerms(listOf(PERM)) { ok ->
            stage("permission_result", mapOf("granted" to ok))
            done(ok)
        }
    }

    private fun ready(): Boolean = feature() && Build.VERSION.SDK_INT >= 31 && library() && permitted() &&
        activity.hasPerms(listOf("android.permission.BLUETOOTH_CONNECT"))

    // ------------------------------------------------------ start / stop

    fun start(deviceId: String) {
        myId = deviceId
        if (!ready()) return stage("start_skipped", mapOf("why" to "not ready"))
        try {
            manager = manager ?: UwbManager.createInstance(activity)
            if (server == null) openServer()
            stage("started")
        } catch (e: Throwable) {
            stage("start_error", err(e))
        }
    }

    fun stop() {
        for ((peer, j) in sessions) {
            j.cancel()
            stage("session_closed", mapOf("peer" to peer, "reason" to "stop"))
        }
        sessions.clear()
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        inbox.clear()
        answers.clear()
    }

    fun peers(): List<String> = sessions.keys.toList()

    fun dispose() {
        stop()
        scope.cancel()
    }

    // ----------------------------------------------------- GATT server

    private fun openServer() {
        val bm = activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val s = bm.openGattServer(activity, serverCallback) ?: throw IllegalStateException("no GATT server")
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(
            BluetoothGattCharacteristic(
                CHAR,
                BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
                BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE,
            )
        )
        s.addService(svc)
        server = s
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic, prepared: Boolean,
            responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            try {
                if (value != null && value.size >= 2) {
                    val box = inbox.getOrPut(device.address) { mutableMapOf() }
                    box[value[0].toInt() and 0xFF] = value.copyOfRange(2, value.size)
                    val count = value[1].toInt() and 0xFF
                    if (box.size == count) {
                        inbox.remove(device.address)
                        val all = (0 until count).fold(ByteArray(0)) { acc, i -> acc + (box[i] ?: ByteArray(0)) }
                        main.post { asControlee(device.address, all) }
                    }
                }
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            } catch (e: Throwable) {
                stage("server_error", err(e))
            }
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, ch: BluetoothGattCharacteristic) {
            try {
                val a = answers[device.address]
                if (a == null) {
                    // Not ready yet: the controller reads again shortly.
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null)
                } else {
                    val from = offset.coerceAtMost(a.size)
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, a.copyOfRange(from, a.size))
                }
            } catch (e: Throwable) {
                stage("server_error", err(e))
            }
        }
    }

    // ----------------------------------------------------- controlee

    private fun asControlee(address: String, payload: ByteArray) {
        val j = try {
            JSONObject(String(payload, Charsets.UTF_8))
        } catch (e: Throwable) {
            return stage("exchange_failed", mapOf("side" to "controlee", "why" to "bad payload") + err(e))
        }
        val peer = j.optString("id")
        stage("exchange_received", mapOf("peer" to peer))
        if (sessions.size >= MAX_SESSIONS && !sessions.containsKey(peer)) {
            answers[address] = JSONObject().put("id", myId).put("busy", true).toString().toByteArray()
            return stage("exchange_failed", mapOf("side" to "controlee", "peer" to peer, "why" to "busy"))
        }
        scope.launch {
            try {
                val m = manager ?: throw IllegalStateException("no UwbManager")
                val s = m.controleeSessionScope()
                answers[address] = JSONObject()
                    .put("id", myId)
                    .put("addr", hex(s.localAddress.address))
                    .toString().toByteArray()
                stage("exchange_ok", mapOf("side" to "controlee", "peer" to peer))
                val params = RangingParameters(
                    RangingParameters.CONFIG_UNICAST_DS_TWR,
                    j.getInt("sid"),
                    0,
                    unhex(j.getString("key")),
                    null,
                    UwbComplexChannel(j.getInt("ch"), j.getInt("pre")),
                    listOf(UwbDevice(UwbAddress(unhex(j.getString("addr"))))),
                    RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
                )
                range(peer, s, params, "controlee")
            } catch (e: Throwable) {
                stage("exchange_failed", mapOf("side" to "controlee", "peer" to peer) + err(e))
            }
        }
    }

    // ----------------------------------------------------- controller

    /** Controller side: [uuid] is the peer's advert, heard in the last scan. */
    fun rangeWith(uuid: String, peerKey: String) {
        if (!ready()) return stage("range_skipped", mapOf("peer" to peerKey, "why" to "not ready"))
        if (sessions.size >= MAX_SESSIONS) return stage("range_skipped", mapOf("peer" to peerKey, "why" to "busy"))
        val dev = deviceFor(uuid) ?: return stage("exchange_failed", mapOf("peer" to peerKey, "why" to "not seen"))
        stage("exchange_start", mapOf("peer" to peerKey))
        scope.launch {
            try {
                val m = manager ?: throw IllegalStateException("no UwbManager")
                val s = m.controllerSessionScope()
                val sid = rng.nextInt(Int.MAX_VALUE - 1) + 1
                val key = ByteArray(8).also { rng.nextBytes(it) }
                val ch = s.uwbComplexChannel
                val out = JSONObject()
                    .put("v", 1)
                    .put("id", myId)
                    .put("addr", hex(s.localAddress.address))
                    .put("ch", ch.channel)
                    .put("pre", ch.preambleIndex)
                    .put("sid", sid)
                    .put("key", hex(key))
                    .toString().toByteArray()
                val back = withTimeout(20_000) { gattExchange(dev, out) }
                val a = JSONObject(String(back, Charsets.UTF_8))
                val peer = a.optString("id", peerKey)
                if (a.optBoolean("busy")) return@launch stage("exchange_failed", mapOf("peer" to peer, "why" to "peer busy"))
                stage("exchange_ok", mapOf("side" to "controller", "peer" to peer))
                val params = RangingParameters(
                    RangingParameters.CONFIG_UNICAST_DS_TWR, sid, 0, key, null, ch,
                    listOf(UwbDevice(UwbAddress(unhex(a.getString("addr"))))),
                    RangingParameters.RANGING_UPDATE_RATE_AUTOMATIC,
                )
                range(peer, s, params, "controller", uuid)
            } catch (e: Throwable) {
                stage("exchange_failed", mapOf("side" to "controller", "peer" to peerKey) + err(e))
                emit(mapOf("type" to "uwbState", "uuid" to uuid, "state" to "failed", "why" to e.javaClass.simpleName))
            }
        }
    }

    /** Write [payload] in chunks, then read the answer (retrying while the
     * peer prepares it). */
    private suspend fun gattExchange(dev: BluetoothDevice, payload: ByteArray): ByteArray {
        val done = kotlinx.coroutines.CompletableDeferred<ByteArray>()
        var gatt: BluetoothGatt? = null
        var chunks = listOf<ByteArray>()
        var next = 0
        var reads = 0
        var ch: BluetoothGattCharacteristic? = null
        fun writeNext(g: BluetoothGatt) {
            val c = ch ?: return
            if (next < chunks.size) {
                @Suppress("DEPRECATION")
                c.value = chunks[next++]
                c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                @Suppress("DEPRECATION")
                if (!g.writeCharacteristic(c)) done.completeExceptionally(IllegalStateException("write refused"))
            } else {
                if (!g.readCharacteristic(c)) done.completeExceptionally(IllegalStateException("read refused"))
            }
        }
        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, state: Int) {
                if (state == BluetoothProfile.STATE_CONNECTED) {
                    g.requestMtu(247)
                } else if (state == BluetoothProfile.STATE_DISCONNECTED && !done.isCompleted) {
                    done.completeExceptionally(IllegalStateException("disconnected (status $status)"))
                }
            }

            override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
                val size = (mtu - 3 - 2).coerceAtLeast(18)
                chunks = payload.toList().chunked(size).mapIndexed { i, c ->
                    byteArrayOf(i.toByte(), ((payload.size + size - 1) / size).toByte()) + c.toByteArray()
                }
                if (!g.discoverServices()) done.completeExceptionally(IllegalStateException("discover refused"))
            }

            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                ch = g.getService(SERVICE)?.getCharacteristic(CHAR)
                if (ch == null) {
                    done.completeExceptionally(IllegalStateException("no Felt Notes UWB service"))
                    return
                }
                writeNext(g)
            }

            override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    done.completeExceptionally(IllegalStateException("write status $status"))
                    return
                }
                writeNext(g)
            }

            @Deprecated("Deprecated in Java")
            override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
                @Suppress("DEPRECATION")
                val v = c.value
                if (status == BluetoothGatt.GATT_SUCCESS && v != null && v.isNotEmpty()) {
                    done.complete(v)
                } else if (reads++ < 10) {
                    main.postDelayed({ if (!done.isCompleted) g.readCharacteristic(c) }, 500)
                } else {
                    done.completeExceptionally(IllegalStateException("read status $status"))
                }
            }
        }
        try {
            gatt = dev.connectGatt(activity, false, cb, BluetoothDevice.TRANSPORT_LE)
            return done.await()
        } finally {
            try {
                gatt?.disconnect()
                gatt?.close()
            } catch (_: Throwable) {
            }
        }
    }

    // ---------------------------------------------------------- ranging

    private fun range(peer: String, s: UwbClientSessionScope, params: RangingParameters, side: String, uuid: String? = null) {
        sessions[peer]?.cancel()
        val opened = now()
        var first = true
        var count = 0
        val job = scope.launch {
            try {
                stage("session_open", mapOf("peer" to peer, "side" to side))
                emit(mapOf("type" to "uwbState", "peer" to peer, "uuid" to uuid, "state" to "ranging", "side" to side))
                s.prepareSession(params).collect { r ->
                    when (r) {
                        is RangingResult.RangingResultPosition -> {
                            val d = r.position.distance?.value ?: return@collect
                            if (first) {
                                first = false
                                stage("first_result", mapOf("peer" to peer, "latency_ms" to (now() - opened)))
                            }
                            count++
                            emit(
                                mapOf(
                                    "type" to "uwb", "peer" to peer, "m" to d.toDouble(), "t" to now(),
                                    "az" to r.position.azimuth?.value?.toDouble(),
                                    "el" to r.position.elevation?.value?.toDouble(),
                                    "android" to true,
                                )
                            )
                        }
                        is RangingResult.RangingResultPeerDisconnected ->
                            stage("peer_disconnected", mapOf("peer" to peer, "reason" to r.reason))
                        is RangingResult.RangingResultFailure ->
                            stage("ranging_failure", mapOf("peer" to peer, "reason" to r.reason))
                        else -> stage("ranging_event", mapOf("peer" to peer, "kind" to r.javaClass.simpleName))
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                stage("session_error", mapOf("peer" to peer) + err(e))
            }
        }
        sessions[peer] = job
        // Rotate: give other pairs their turn.
        scope.launch {
            delay(ROTATE_MS)
            if (sessions[peer] === job) {
                job.cancel()
                sessions.remove(peer)
                stage("session_closed", mapOf("peer" to peer, "reason" to "rotate", "results" to count))
                emit(mapOf("type" to "uwbState", "peer" to peer, "uuid" to uuid, "state" to "ended", "why" to "rotate"))
            }
        }
        job.invokeOnCompletion { c ->
            if (sessions[peer] === job) {
                sessions.remove(peer)
                main.post {
                    stage("session_closed", mapOf("peer" to peer, "reason" to (c?.javaClass?.simpleName ?: "flow ended"), "results" to count))
                    emit(mapOf("type" to "uwbState", "peer" to peer, "uuid" to uuid, "state" to "ended"))
                }
            }
        }
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun unhex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
}
