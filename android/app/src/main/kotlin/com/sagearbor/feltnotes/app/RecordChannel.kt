package com.sagearbor.feltnotes.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.location.Location
import android.location.LocationManager
import android.media.ExifInterface
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * Record the table (lib/record/record_native.dart), channel
 * `felt_notes/record`: JPEG encoding of camera stream frames off the main
 * thread, thermal state, free storage, device model, one coarse location
 * fix, and runtime permissions (shared with the Bluetooth channel).
 */
class RecordChannel(
    private val activity: MainActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "felt_notes/record")
    private val main = Handler(Looper.getMainLooper())

    // One encoder thread: frames are paced in Dart and never queue up.
    private val encoder = Executors.newSingleThreadExecutor()

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "encodeJpeg" -> encodeJpeg(call, result)
                "thermal" -> result.success(thermal())
                "storage" -> {
                    val st = StatFs(call.argument<String>("path") ?: activity.filesDir.path)
                    result.success(mapOf("free" to st.availableBytes, "total" to st.totalBytes))
                }
                "device" -> result.success(
                    mapOf(
                        "manufacturer" to Build.MANUFACTURER,
                        "model" to Build.MODEL,
                        "device" to Build.DEVICE,
                        "os" to "Android ${Build.VERSION.RELEASE}",
                        "sdk" to Build.VERSION.SDK_INT,
                    )
                )
                "location" -> location(call.argument<Boolean>("ask") == true, result)
                "permissions" -> {
                    val names = call.argument<List<String>>("names") ?: emptyList()
                    activity.requestPerms(names) { ok -> result.success(ok) }
                }
                "hasPermissions" -> {
                    val names = call.argument<List<String>>("names") ?: emptyList()
                    result.success(activity.hasPerms(names))
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("record", e.toString(), null)
        }
    }

    // ------------------------------------------------------------ JPEG

    private fun encodeJpeg(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val w = call.argument<Int>("width")!!
        val h = call.argument<Int>("height")!!
        @Suppress("UNCHECKED_CAST")
        val planes = call.argument<List<ByteArray>>("planes")!!
        val rows = call.argument<List<Int>>("rowStrides")!!
        val pix = call.argument<List<Int>>("pixelStrides")!!
        val quality = call.argument<Int>("quality") ?: 85
        val rotation = call.argument<Int>("rotation") ?: 0
        encoder.execute {
            try {
                val t0 = System.nanoTime()
                val nv21 = toNv21(w, h, planes, rows, pix)
                val tmp = File("$path.part")
                tmp.parentFile?.mkdirs()
                FileOutputStream(tmp).use { out ->
                    YuvImage(nv21, ImageFormat.NV21, w, h, null).compressToJpeg(Rect(0, 0, w, h), quality, out)
                }
                if (rotation != 0) {
                    val exif = ExifInterface(tmp.path)
                    exif.setAttribute(
                        ExifInterface.TAG_ORIENTATION,
                        when (rotation) {
                            90 -> ExifInterface.ORIENTATION_ROTATE_90
                            180 -> ExifInterface.ORIENTATION_ROTATE_180
                            270 -> ExifInterface.ORIENTATION_ROTATE_270
                            else -> ExifInterface.ORIENTATION_NORMAL
                        }.toString()
                    )
                    exif.saveAttributes()
                }
                // Only whole files get the final name.
                val dst = File(path)
                if (!tmp.renameTo(dst)) throw IllegalStateException("rename failed")
                val ms = (System.nanoTime() - t0) / 1_000_000
                val size = dst.length()
                main.post { result.success(mapOf("bytes" to size, "ms" to ms)) }
            } catch (e: Exception) {
                main.post { result.error("encode", e.toString(), null) }
            }
        }
    }

    /** YUV_420_888 planes (Y, U, V with any row / pixel strides) to NV21. */
    private fun toNv21(w: Int, h: Int, planes: List<ByteArray>, rows: List<Int>, pix: List<Int>): ByteArray {
        val out = ByteArray(w * h * 3 / 2)
        val y = planes[0]
        val yRow = rows[0]
        for (r in 0 until h) System.arraycopy(y, r * yRow, out, r * w, w)
        if (planes.size < 3) return out // grey is better than nothing
        val u = planes[1]
        val v = planes[2]
        val uRow = rows[1]
        val vRow = rows[2]
        val uPix = pix[1]
        val vPix = pix[2]
        var o = w * h
        for (r in 0 until h / 2) {
            val ur = r * uRow
            val vr = r * vRow
            for (c in 0 until w / 2) {
                val vi = vr + c * vPix
                val ui = ur + c * uPix
                out[o++] = if (vi < v.size) v[vi] else 128.toByte()
                out[o++] = if (ui < u.size) u[ui] else 128.toByte()
            }
        }
        return out
    }

    // --------------------------------------------------------- thermal

    private fun thermal(): String {
        if (Build.VERSION.SDK_INT < 29) return "unknown"
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
    }

    // -------------------------------------------------------- location

    private fun location(ask: Boolean, result: MethodChannel.Result) {
        val perm = listOf(Manifest.permission.ACCESS_COARSE_LOCATION)
        if (!activity.hasPerms(perm)) {
            if (!ask) return result.success(null)
            activity.requestPerms(perm) { ok -> if (ok) readLocation(result) else result.success(null) }
            return
        }
        readLocation(result)
    }

    private fun readLocation(result: MethodChannel.Result) {
        if (activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return result.success(null)
        }
        val lm = activity.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        var best: Location? = null
        for (p in lm.getProviders(true)) {
            try {
                val l = lm.getLastKnownLocation(p) ?: continue
                if (best == null || l.time > best.time) best = l
            } catch (_: SecurityException) {
            }
        }
        if (best != null || Build.VERSION.SDK_INT < 30) return result.success(best?.let { toMap(it) })
        // No last fix: one quick try on the network provider (Wi-Fi), then
        // give up; a basement may have neither.
        val provider = if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) LocationManager.NETWORK_PROVIDER
        else return result.success(null)
        val cancel = CancellationSignal()
        var done = false
        main.postDelayed({
            if (!done) {
                done = true
                cancel.cancel()
                result.success(null)
            }
        }, 5000)
        try {
            lm.getCurrentLocation(provider, cancel, activity.mainExecutor) { l ->
                if (!done) {
                    done = true
                    result.success(l?.let { toMap(it) })
                }
            }
        } catch (e: SecurityException) {
            if (!done) {
                done = true
                result.success(null)
            }
        }
    }

    private fun toMap(l: Location): Map<String, Any> = mapOf(
        "lat" to l.latitude,
        "lon" to l.longitude,
        "acc_m" to l.accuracy.toDouble(),
        "age_s" to ((System.currentTimeMillis() - l.time) / 1000),
        "provider" to (l.provider ?: ""),
    )
}
