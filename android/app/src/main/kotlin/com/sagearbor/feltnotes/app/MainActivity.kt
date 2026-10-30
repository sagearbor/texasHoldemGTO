package com.sagearbor.feltnotes.app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    // Watch my cards speaker-leak guard (lib/camera/watch_voice.dart): where
    // would speech play right now? Android 13+: the actual route for media;
    // older: every connected output (the speaker is always among them).
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
