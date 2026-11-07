// Plays a 30-second Apple preview (the TV's leader song, or a preview in
// the song picker). Browsers block sound until someone taps the page:
// [SongPlayer.play] then returns false and the TV shows "Tap to enable
// sound".

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../pulse/pulse_profile.dart';
import '../tv/show_on_tv.dart' show openInBrowser;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

abstract class SongPlayer {
  /// Starts [url] (an Apple preview); false when the platform refused
  /// (a browser's autoplay block) or it failed.
  Future<bool> play(String url);
  Future<void> stop();
  void dispose();
}

class AudioSongPlayer implements SongPlayer {
  AudioPlayer? _p;

  @override
  Future<bool> play(String url) async {
    if (!applePreviewUrl(url)) return false;
    try {
      final p = _p ??= AudioPlayer();
      await p.stop();
      await p.play(UrlSource(url));
      return true;
    } catch (e) {
      debugPrint('song: $e');
      return false;
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _p?.stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _p?.dispose();
    _p = null;
  }
}

/// Opens "Listen on Apple Music": a new tab on the web TV, the browser on
/// a phone.
Future<bool> openSongLink(String url) async {
  if (!appleMusicUrl(url)) return false;
  if (!kIsWeb) return openInBrowser(url);
  try {
    return await UrlLauncherPlatform.instance.launchUrl(url, const LaunchOptions());
  } catch (_) {
    return false;
  }
}
