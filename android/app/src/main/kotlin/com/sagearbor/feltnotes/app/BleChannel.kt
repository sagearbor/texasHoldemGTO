package com.sagearbor.feltnotes.app

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.PowerManager
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Nearby games (lib/nearby/nearby_ble.dart), channel `felt_notes/ble`:
 * advertise one Felt Notes service UUID (the payload is in the UUID, see
 * ble_payload.dart) with the host's name in the scan response, and scan
 * for a few seconds keeping only Felt Notes adverts. No UWB on this side
 * (the owner's phone has none; Android-iPhone UWB is not attempted).
 * Permissions are asked from Dart, just in time, through RecordChannel.
 */
@SuppressLint("MissingPermission") // every call is behind the Dart-side permission check
class BleChannel(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val channel = MethodChannel(messenger, "felt_notes/ble")
    private val events = EventChannel(messenger, "felt_notes/ble_events")
    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var advertiser: AdvertiseCallback? = null
    private var scanning = false

    private val adapter: BluetoothAdapter?
        get() = (activity.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?)?.adapter

    // ------------------------------------------------- diagnostics
    // Field data showed both phones going silent for minutes mid-run: every
    // state change is sent to Dart as it happens, and "bleStatus" gives the
    // current picture for the distance test's 5-second status lines.
    private var lastScanFailCode: Int? = null
    private var lastScanFailMs: Long? = null
    private var advertOk = false
    private var lastAdvertCode: Int? = null // null: success
    private var lastAdvertMs: Long? = null
    private var heardAll = 0L
    private var heardFelt = 0L
    private var lastResultMs: Long? = null
    private var restarts = 0
    private var lastRestartMs: Long? = null

    private fun now() = System.currentTimeMillis()

    private fun emit(m: Map<String, Any?>) {
        main.post { sink?.success(m + ("t" to now())) }
    }

    private val btState = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val s = i?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) ?: return
            if (s != BluetoothAdapter.STATE_ON) {
                // The stack drops every scan and advert when it goes down.
                advertOk = false
                stream = null
                main.removeCallbacks(restart)
            }
            emit(mapOf("type" to "bt", "on" to (s == BluetoothAdapter.STATE_ON), "state" to stateName(s)))
        }
    }

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            emit(mapOf("type" to "screen", "on" to (i?.action == Intent.ACTION_SCREEN_ON)))
        }
    }

    private fun stateName(s: Int) = when (s) {
        BluetoothAdapter.STATE_ON -> "on"
        BluetoothAdapter.STATE_OFF -> "off"
        BluetoothAdapter.STATE_TURNING_ON -> "turning_on"
        BluetoothAdapter.STATE_TURNING_OFF -> "turning_off"
        else -> "unknown:$s"
    }

    private fun status(): Map<String, Any?> = mapOf(
        "interactive" to (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive,
        "adapter" to (adapter?.state?.let { stateName(it) } ?: "none"),
        "scan" to (stream != null),
        "advert" to (advertiser != null && advertOk),
        "scan_fail_code" to lastScanFailCode,
        "scan_fail_ms" to lastScanFailMs,
        "advert_code" to lastAdvertCode,
        "advert_ok" to advertOk,
        "advert_ms" to lastAdvertMs,
        "heard_all" to heardAll,
        "heard_felt" to heardFelt,
        "last_result_ms" to lastResultMs,
        "restarts" to restarts,
        "last_restart_ms" to lastRestartMs,
    )

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        activity.registerReceiver(btState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        activity.registerReceiver(screen, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        })
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        try {
            activity.unregisterReceiver(btState)
            activity.unregisterReceiver(screen)
        } catch (_: Exception) {
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "sdk" -> result.success(Build.VERSION.SDK_INT)
                "poweredOn" -> result.success(adapter?.isEnabled == true && adapter?.bluetoothLeAdvertiser != null)
                "advertise" -> advertise(call, result)
                "stopAdvertising" -> {
                    stopAdvertising()
                    result.success(null)
                }
                "scan" -> scan(call.argument<Int>("ms") ?: 4000, call.argument<String>("prefix") ?: "", result)
                "scanStart" -> {
                    startStream(call.argument<String>("prefix") ?: "")
                    result.success(stream != null)
                }
                "scanStop" -> {
                    stopStream()
                    result.success(null)
                }
                "bleStatus" -> result.success(status())
                "screenOn" -> result.success((activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive)
                "uwbSupported" -> result.success(false)
                "uwbStart", "uwbStop", "uwbRange" -> result.success(null)
                "uwbPeers" -> result.success(emptyList<String>())
                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("ble_permission", e.toString(), null)
        } catch (e: Exception) {
            result.error("ble", e.toString(), null)
        }
    }

    // ------------------------------------------------------- advertise

    private fun advertise(call: MethodCall, result: MethodChannel.Result) {
        val adv = adapter?.bluetoothLeAdvertiser ?: return result.success(false)
        stopAdvertising()
        val uuid = UUID.fromString(call.argument<String>("uuid")!!)
        val nameData = call.argument<ByteArray>("nameData")
        val company = call.argument<Int>("company") ?: 0xFFFF
        // High in games; the distance test alternates high and low. The
        // advert carries the level (includeTxPowerLevel) so receivers log it.
        val power = when (call.argument<String>("power")) {
            "low" -> AdvertiseSettings.ADVERTISE_TX_POWER_LOW
            "medium" -> AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
            "ultra_low" -> AdvertiseSettings.ADVERTISE_TX_POWER_ULTRA_LOW
            else -> AdvertiseSettings.ADVERTISE_TX_POWER_HIGH
        }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(power)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        // 3 (flags) + 18 (128-bit UUID) + 3 (tx power) = 24 of 31 bytes.
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(uuid))
            .setIncludeTxPowerLevel(true)
            .setIncludeDeviceName(false)
            .build()
        val response = nameData?.let {
            AdvertiseData.Builder().addManufacturerData(company, it).setIncludeDeviceName(false).build()
        }
        var answered = false
        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                advertOk = true
                lastAdvertCode = null
                lastAdvertMs = now()
                emit(mapOf("type" to "advert", "ok" to true, "tx_dbm" to settingsInEffect?.txPowerLevel))
                if (!answered) {
                    answered = true
                    result.success(true)
                }
            }

            override fun onStartFailure(errorCode: Int) {
                advertiser = null
                advertOk = false
                lastAdvertCode = errorCode
                lastAdvertMs = now()
                emit(mapOf("type" to "advert", "ok" to false, "code" to errorCode))
                if (!answered) {
                    answered = true
                    result.success(false)
                }
            }
        }
        advertiser = cb
        if (response != null) adv.startAdvertising(settings, data, response, cb) else adv.startAdvertising(settings, data, cb)
    }

    private fun stopAdvertising() {
        val cb = advertiser ?: return
        advertiser = null
        advertOk = false
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(cb)
        } catch (_: Exception) {
        }
    }

    // ---------------------------------------------- continuous (test)

    /** Bluetooth distance test: every advert heard, as an event, until stopped. */
    private var stream: ScanCallback? = null
    private var streamPrefix = ""
    private val restart = Runnable { restartStream() }

    private fun startStream(prefix: String) {
        stopStream()
        val scanner = adapter?.bluetoothLeScanner ?: return
        streamPrefix = prefix
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                heardAll++
                lastResultMs = now()
                val m = sighting(r, streamPrefix) ?: return
                heardFelt++
                main.post { sink?.success(m + ("type" to "adv")) }
            }

            override fun onScanFailed(errorCode: Int) {
                // 1 already started, 2 app registration failed, 3 internal
                // error, 4 unsupported, 5 out of hardware, 6 scanning too
                // frequently.
                lastScanFailCode = errorCode
                lastScanFailMs = now()
                if (stream === this) stream = null
                emit(mapOf("type" to "scanFailed", "code" to errorCode))
            }
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        try {
            scanner.startScan(null, settings, cb)
            stream = cb
            // Android turns a scan running over 30 minutes into a slow
            // opportunistic one: start it again every 10.
            main.postDelayed(restart, 10 * 60 * 1000L)
        } catch (e: Exception) {
            stream = null
            emit(mapOf("type" to "scanFailed", "code" to -1, "error" to e.toString()))
        }
    }

    private fun restartStream() {
        if (stream == null) return
        restarts++
        lastRestartMs = now()
        emit(mapOf("type" to "scanRestart", "reason" to "every_10_min"))
        startStream(streamPrefix)
    }

    private fun stopStream() {
        main.removeCallbacks(restart)
        val cb = stream ?: return
        stream = null
        try {
            adapter?.bluetoothLeScanner?.stopScan(cb)
        } catch (_: Exception) {
        }
    }

    /** One result as the Dart map, or null when it is not a Felt Notes advert. */
    private fun sighting(r: ScanResult, prefix: String): Map<String, Any?>? {
        val rec = r.scanRecord ?: return null
        val uuids = rec.serviceUuids?.map { it.uuid.toString() } ?: return null
        if (uuids.none { it.replace("-", "").lowercase().startsWith(prefix) }) return null
        val tx = when {
            Build.VERSION.SDK_INT >= 26 && r.txPower != ScanResult.TX_POWER_NOT_PRESENT -> r.txPower
            rec.txPowerLevel != Int.MIN_VALUE -> rec.txPowerLevel
            else -> null
        }
        val wallMinusBoot = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        return mapOf(
            "u" to uuids,
            "r" to r.rssi,
            "tx" to tx,
            "n" to rec.deviceName,
            "m" to rec.getManufacturerSpecificData(0xFFFF)?.map { it.toInt() and 0xFF },
            "t" to wallMinusBoot + r.timestampNanos / 1_000_000,
        )
    }

    // ------------------------------------------------------------ scan

    private fun scan(ms: Int, prefix: String, result: MethodChannel.Result) {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null || scanning) return result.success(emptyList<Any>())
        scanning = true
        val out = mutableListOf<Map<String, Any?>>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                sighting(r, prefix)?.let { out.add(it) }
            }

            override fun onScanFailed(errorCode: Int) {
                // Too many scans started (Android allows 5 per 30 s) or
                // Bluetooth off: the next round tries again.
            }
        }
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
        try {
            // Unfiltered: our UUIDs differ per phone, and a filter cannot
            // match a prefix. (Android pauses unfiltered scans with the
            // screen off; the log records screen state.)
            scanner.startScan(null, settings, cb)
        } catch (e: Exception) {
            scanning = false
            return result.error("ble_scan", e.toString(), null)
        }
        main.postDelayed({
            try {
                scanner.stopScan(cb)
            } catch (_: Exception) {
            }
            scanning = false
            result.success(out)
        }, ms.toLong())
    }
}
