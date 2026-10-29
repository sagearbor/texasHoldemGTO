/// Watch my cards: spoken confirmation, with a speaker-leak guard.
///
/// The cards are spoken with the OS speech engine (flutter_tts: offline,
/// free), quietly, and ONLY when the audio output is private (earbuds,
/// headphones, hearing aids). If the earbuds drop, iOS would route speech to
/// the phone's speaker and the whole table would hear your cards, so the
/// route is checked right before every utterance:
///  * iOS: AVAudioSession.currentRoute outputs (via audio_session). Speak
///    only when every output is private.
///  * Android: AudioManager output devices (via audio_session). That list
///    always contains the built-in speaker, and media follows a connected
///    headset, so speak when any private output is present.
/// Anything unknown, or an error, means silence.
library;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

const privateOutputs = {
  AudioDeviceType.wiredHeadset,
  AudioDeviceType.wiredHeadphones,
  AudioDeviceType.bluetoothA2dp,
  AudioDeviceType.bluetoothSco,
  AudioDeviceType.bluetoothLe,
  AudioDeviceType.hearingAid,
};

/// The leak-guard decision. [isCurrentRoute]: [outputs] is the route audio
/// takes right now (iOS) rather than every connected output (Android).
bool voiceAllowed(Iterable<AudioDeviceType> outputs, {required bool isCurrentRoute}) {
  final outs = outputs.toList();
  if (outs.isEmpty) return false;
  return isCurrentRoute ? outs.every(privateOutputs.contains) : outs.any(privateOutputs.contains);
}

enum VoiceState { off, ready, paused }

class WatchVoice {
  final FlutterTts _tts = FlutterTts();
  AudioSession? _session;
  bool _init = false;

  /// Quiet by default (0..1 of the media volume).
  double volume = 0.6;

  /// Last route check: [VoiceState.paused] while earbuds are missing.
  final ValueNotifier<VoiceState> state = ValueNotifier(VoiceState.ready);

  Future<void> _ensureInit() async {
    if (_init) return;
    _init = true;
    _session = await AudioSession.instance;
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
    await _tts.awaitSpeakCompletion(true);
  }

  /// True when the current route is private. Never throws.
  Future<bool> routeIsPrivate() async {
    try {
      await _ensureInit();
      final devices = await _session!.getDevices(includeInputs: false);
      return voiceAllowed(devices.map((d) => d.type),
          isCurrentRoute: defaultTargetPlatform == TargetPlatform.iOS);
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
