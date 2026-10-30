/// Watch my cards: spoken confirmation, with a speaker-leak guard.
///
/// The cards are spoken with the OS speech engine (flutter_tts: offline,
/// free), quietly, and ONLY when the audio output is private (earbuds,
/// headphones, hearing aids). If the earbuds drop, the phone would play the
/// speech on its speaker and the whole table would hear your cards, so the
/// route is checked right before every utterance, through a small method
/// channel ("felt_notes/audio_route", MainActivity.kt / AppDelegate.swift):
///  * iOS: AVAudioSession.currentRoute outputs.
///  * Android 13+: AudioManager.getAudioDevicesForAttributes(media), the
///    actual route. Older Android: every connected output (that list always
///    includes the speaker; media follows a connected headset).
/// Anything unknown, or an error, means silence.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Output kinds (as the native side names them) that only the player hears.
/// Not "ble_broadcast" (Auracast: anyone nearby can tune in), not speakers.
const privateOutputs = {
  'headphones',
  'headset',
  'bluetooth_a2dp',
  'bluetooth_sco',
  'ble_headset',
  'usb_headset',
  'hearing_aid',
};

/// The leak-guard decision. [isCurrentRoute]: [outputs] is where audio
/// plays right now (every one must be private), rather than every connected
/// output (Android < 13: one private output is enough, the built-in speaker
/// is always listed).
bool voiceAllowed(Iterable<String> outputs, {required bool isCurrentRoute}) {
  final outs = outputs.toList();
  if (outs.isEmpty) return false;
  return isCurrentRoute ? outs.every(privateOutputs.contains) : outs.any(privateOutputs.contains);
}

enum VoiceState { off, ready, paused }

class WatchVoice {
  static const _route = MethodChannel('felt_notes/audio_route');
  final FlutterTts _tts = FlutterTts();
  bool _init = false;

  /// Quiet by default (0..1 of the media volume).
  double volume = 0.6;

  /// Last route check: [VoiceState.paused] while earbuds are missing.
  final ValueNotifier<VoiceState> state = ValueNotifier(VoiceState.ready);

  Future<void> _ensureInit() async {
    if (_init) return;
    _init = true;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Playback (not ambient) so the silent switch does not mute the
      // earbuds; mix + duck so the player's music keeps going.
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
        IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        IosTextToSpeechAudioCategoryOptions.duckOthers,
      ]);
    }
    await _tts.setSpeechRate(0.5);
  }

  /// True when the current route is private. Never throws.
  Future<bool> routeIsPrivate() async {
    try {
      // iOS: set the speech audio category first; the route depends on it.
      await _ensureInit();
    } catch (e) {
      debugPrint('tts init failed: $e');
    }
    try {
      final r = await _route.invokeMapMethod<String, Object?>('outputs');
      if (r == null) return false;
      final outs = (r['outputs'] as List? ?? const []).cast<String>();
      return voiceAllowed(outs, isCurrentRoute: r['route'] == true);
    } catch (e) {
      debugPrint('audio route check failed: $e');
      return false;
    }
  }

  /// Speaks [text] if the route is private right now; returns whether it
  /// spoke. [state] follows the result.
  Future<bool> say(String text) async {
    final ok = await routeIsPrivate();
    state.value = ok ? VoiceState.ready : VoiceState.paused;
    if (!ok) return false;
    try {
      await _tts.setVolume(volume);
      await _tts.speak(text);
      return true;
    } catch (e) {
      debugPrint('tts failed: $e');
      return false;
    }
  }

  Future<void> refresh() async {
    state.value = await routeIsPrivate() ? VoiceState.ready : VoiceState.paused;
  }

  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
    state.dispose();
  }
}
