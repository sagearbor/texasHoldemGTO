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

    private val btState = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val s = i?.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1) ?: return
            sink?.success(mapOf("type" to "bt", "on" to (s == BluetoothAdapter.STATE_ON)))
        }
    }

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        activity.registerReceiver(btState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        try {
            activity.unregisterReceiver(btState)
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
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            // Medium: steady enough for RSSI between seats, not the
            // loudest the radio can do.
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
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
                if (!answered) {
                    answered = true
                    result.success(true)
                }
            }

            override fun onStartFailure(errorCode: Int) {
                advertiser = null
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
        try {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(cb)
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------ scan

    private fun scan(ms: Int, prefix: String, result: MethodChannel.Result) {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null || scanning) return result.success(emptyList<Any>())
        scanning = true
        val out = mutableListOf<Map<String, Any?>>()
        // Wall clock of a result: now minus how long ago it was heard.
        val wallMinusBoot = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, r: ScanResult) {
                val rec = r.scanRecord ?: return
                val uuids = rec.serviceUuids?.map { it.uuid.toString() } ?: return
                // Only Felt Notes adverts: nobody else's devices are logged.
                if (uuids.none { it.replace("-", "").lowercase().startsWith(prefix) }) return
                val tx = when {
                    Build.VERSION.SDK_INT >= 26 && r.txPower != ScanResult.TX_POWER_NOT_PRESENT -> r.txPower
                    rec.txPowerLevel != Int.MIN_VALUE -> rec.txPowerLevel
                    else -> null
                }
                out.add(
                    mapOf(
                        "u" to uuids,
                        "r" to r.rssi,
                        "tx" to tx,
                        "n" to rec.deviceName,
                        "m" to rec.getManufacturerSpecificData(0xFFFF)?.map { it.toInt() and 0xFF },
                        "t" to wallMinusBoot + r.timestampNanos / 1_000_000,
                    )
                )
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
