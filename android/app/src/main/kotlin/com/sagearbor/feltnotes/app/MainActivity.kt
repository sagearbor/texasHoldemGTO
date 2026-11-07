package com.sagearbor.feltnotes.app

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var record: RecordChannel? = null
    private var ble: BleChannel? = null
    // Pulse mode: heart rate from the Felt Notes Pulse Wear OS app.
    private var pulse: PulseChannel? = null
    // Cast to a TV: mDNS discovery of Chromecasts needs multicast delivered.
    private var castLock: WifiManager.MulticastLock? = null

    // Runtime permission prompts for the native channels (record mode's
    // location, Bluetooth for nearby games): one callback per request code.
    private val permWaiters = mutableMapOf<Int, (Boolean) -> Unit>()
    private var nextPermCode = 4100

    fun hasPerms(names: List<String>): Boolean =
        names.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    fun requestPerms(names: List<String>, done: (Boolean) -> Unit) {
        if (hasPerms(names)) return done(true)
        val code = nextPermCode++
        permWaiters[code] = done
        requestPermissions(names.toTypedArray(), code)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        val done = permWaiters.remove(requestCode) ?: return
        done(grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED })
    }

    // Watch my cards speaker-leak guard (lib/camera/watch_voice.dart): where
    // would speech play right now? Android 13+: the actual route for media;
    // older: every connected output (the speaker is always among them).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        record = RecordChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        ble = BleChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        pulse = PulseChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        // "Show on the TV" (lib/ui/tv/show_on_tv.dart): the TV link in the
        // browser, or the system screen-cast settings. false = not possible.
        // multicastLock: held while Cast to a TV looks for Chromecasts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "felt_notes/tv_cast")
            .setMethodCallHandler { call, result ->
                if (call.method == "multicastLock") {
                    result.success(setCastLock(call.argument<Boolean>("on") == true))
                    return@setMethodCallHandler
                }
                val intent = when (call.method) {
                    "openUrl" -> Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))
                    "castSettings" -> Intent(Settings.ACTION_CAST_SETTINGS)
                    else -> null
                }
                if (intent == null) {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "felt_notes/audio_route")
            .setMethodCallHandler { call, result ->
                if (call.method != "outputs") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                try {
                    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                    val route = Build.VERSION.SDK_INT >= 33
                    val devices: List<AudioDeviceInfo> = if (route) {
                        val attrs = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                        am.getAudioDevicesForAttributes(attrs)
                    } else {
                        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).toList()
                    }
                    result.success(mapOf("route" to route, "outputs" to devices.map { kind(it.type) }))
                } catch (e: Exception) {
                    result.error("audio_route", e.toString(), null)
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pulse?.dispose()
        pulse = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun setCastLock(on: Boolean): Boolean = try {
        if (on) {
            val lock = castLock ?: (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createMulticastLock("felt_notes_cast").also {
                    it.setReferenceCounted(false)
                    castLock = it
                }
            if (!lock.isHeld) lock.acquire()
        } else {
            castLock?.let { if (it.isHeld) it.release() }
        }
        true
    } catch (e: Exception) {
        false
    }

    override fun onDestroy() {
        setCastLock(false)
        super.onDestroy()
    }

    private fun kind(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "headphones"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headset"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth_a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth_sco"
        22 -> "usb_headset" // TYPE_USB_HEADSET
        23 -> "hearing_aid" // TYPE_HEARING_AID
        26 -> "ble_headset" // TYPE_BLE_HEADSET (LE Audio earbuds)
        27 -> "ble_speaker" // TYPE_BLE_SPEAKER
        30 -> "ble_broadcast" // TYPE_BLE_BROADCAST: anyone can listen
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, 24 -> "speaker" // 24: BUILTIN_SPEAKER_SAFE
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        else -> "other:$type"
    }
}
