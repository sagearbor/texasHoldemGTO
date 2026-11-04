package com.sagearbor.feltnotes.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
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
                "cameras" -> result.success(cameraInventory())
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

    // ------------------------------------------------- camera inventory

    /**
     * Every camera Camera2 reports, for planning lenses offline (crop-zoom
     * on the main sensor vs the telephoto): the listed ids and, for a
     * logical multi-camera, its physical ones. Read-only; opens nothing.
     */
    private fun cameraInventory(): Map<String, Any?> {
        val cm = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val listed = cm.cameraIdList.toList()
        val out = mutableListOf<Map<String, Any?>>()
        val seen = mutableSetOf<String>()
        fun add(id: String, logicalParent: String?) {
            if (!seen.add(id)) return
            val c = try {
                cm.getCameraCharacteristics(id)
            } catch (e: Exception) {
                out.add(mapOf("id" to id, "error" to e.toString()))
                return
            }
            out.add(describeCamera(id, c, logicalParent, id in listed))
            if (Build.VERSION.SDK_INT >= 28) {
                for (pid in c.physicalCameraIds) add(pid, id)
            }
        }
        for (id in listed) add(id, null)
        val concurrent: List<List<String>>? = if (Build.VERSION.SDK_INT >= 30) {
            try {
                cm.concurrentCameraIds.map { it.toList() }
            } catch (_: Exception) {
                null
            }
        } else null
        return mapOf("sdk" to Build.VERSION.SDK_INT, "cameras" to out, "concurrent_camera_ids" to concurrent)
    }

    private fun describeCamera(id: String, c: CameraCharacteristics, logicalParent: String?, listed: Boolean): Map<String, Any?> {
        val facing = when (c.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }
        val focals = c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)?.map { it.toDouble() }
        val phys = c.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val pixels = c.get(CameraCharacteristics.SENSOR_INFO_PIXEL_ARRAY_SIZE)
        val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val logical = Build.VERSION.SDK_INT >= 28 &&
            CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA in caps
        // Horizontal / vertical field of view of the sensor's long and short
        // sides at the shortest focal length.
        val f = focals?.minOrNull()
        fun fov(side: Float?): Double? =
            if (f == null || side == null || f <= 0.0) null else Math.toDegrees(2 * Math.atan(side / (2 * f)))
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        fun maxSize(fmt: Int): List<Int>? = try {
            map?.getOutputSizes(fmt)?.maxByOrNull { it.width.toLong() * it.height }?.let { listOf(it.width, it.height) }
        } catch (_: Exception) {
            null
        }
        val zoomRange: List<Double>? = if (Build.VERSION.SDK_INT >= 30) {
            c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.let { listOf(it.lower.toDouble(), it.upper.toDouble()) }
        } else null
        val sync: String? = if (logical && Build.VERSION.SDK_INT >= 28) {
            when (c.get(CameraCharacteristics.LOGICAL_MULTI_CAMERA_SENSOR_SYNC_TYPE)) {
                CameraCharacteristics.LOGICAL_MULTI_CAMERA_SENSOR_SYNC_TYPE_CALIBRATED -> "calibrated"
                CameraCharacteristics.LOGICAL_MULTI_CAMERA_SENSOR_SYNC_TYPE_APPROXIMATE -> "approximate"
                else -> null
            }
        } else null
        return mapOf(
            "id" to id,
            "listed" to listed,
            "physical_of" to logicalParent,
            "facing" to facing,
            "logical_multi_camera" to logical,
            "physical_ids" to if (Build.VERSION.SDK_INT >= 28) c.physicalCameraIds.toList() else null,
            // A logical multi-camera can stream its physical cameras at the
            // same time (OutputConfiguration.setPhysicalCameraId).
            "physical_streams" to logical,
            "sensor_sync" to sync,
            "focal_mm" to focals,
            "sensor_mm" to phys?.let { listOf(it.width.toDouble(), it.height.toDouble()) },
            "pixel_array" to pixels?.let { listOf(it.width, it.height) },
            "active_array" to active?.let { listOf(it.width(), it.height()) },
            "fov_deg" to listOf(fov(phys?.width), fov(phys?.height)),
            "max_jpeg" to maxSize(ImageFormat.JPEG),
            "max_yuv" to maxSize(ImageFormat.YUV_420_888),
            "zoom_ratio_range" to zoomRange,
            "max_digital_zoom" to c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)?.toDouble(),
            "hardware_level" to c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL),
            "ois" to c.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)?.toList(),
            "min_focus_diopters" to c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)?.toDouble(),
        )
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
