/// A Pulse player's profile: a name, an optional selfie (a small circle on
/// the TV chart so strangers know which line is whose) and an optional
/// favourite song (Apple's free 30-second preview, played on the TV while
/// they lead). No account: it lives on the phone and goes to a night only
/// when the player turns Pulse on there.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

/// The selfie as stored and sent: a [faceSize] px square JPEG, a few KB.
const faceSize = 96;

/// firestore.rules caps the base64 selfie at this many characters.
const faceMaxChars = 16000;

/// A song from the iTunes Search API. Only URLs on Apple's own hosts are
/// kept ([PulseSong.fromJson] checks), so the TV never plays anything else.
class PulseSong {
  final int trackId;
  final String title;
  final String artist;
  final String previewUrl;
  final String artworkUrl;

  /// The song on Apple Music ("Listen on Apple Music").
  final String trackViewUrl;

  const PulseSong({
    required this.trackId,
    required this.title,
    required this.artist,
    required this.previewUrl,
    required this.artworkUrl,
    required this.trackViewUrl,
  });

  Map<String, Object?> toJson() => {
        'trackId': trackId,
        'title': title,
        'artist': artist,
        'previewUrl': previewUrl,
        'artworkUrl': artworkUrl,
        'trackViewUrl': trackViewUrl,
      };

  static String _cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

  /// Null unless every field is there and every URL is on an Apple host.
  static PulseSong? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['trackId'], t = j['title'], a = j['artist'];
    final p = j['previewUrl'], w = j['artworkUrl'], v = j['trackViewUrl'];
    if (id is! int || t is! String || a is! String || p is! String || w is! String || v is! String) return null;
    if (!applePreviewUrl(p) || !appleArtworkUrl(w) || !appleMusicUrl(v)) return null;
    return PulseSong(
        trackId: id, title: _cut(t, 80), artist: _cut(a, 80), previewUrl: p, artworkUrl: w, trackViewUrl: v);
  }

  /// One result of the iTunes Search API.
  static PulseSong? fromItunes(Object? r) {
    if (r is! Map) return null;
    final art = r['artworkUrl100'] ?? r['artworkUrl60'];
    return fromJson({
      'trackId': r['trackId'],
      'title': r['trackName'],
      'artist': r['artistName'],
      'previewUrl': r['previewUrl'],
      'artworkUrl': art is String ? art.replaceFirst('100x100bb', '200x200bb') : art,
      'trackViewUrl': r['trackViewUrl'],
    });
  }

  @override
  bool operator ==(Object other) => other is PulseSong && other.trackId == trackId && other.previewUrl == previewUrl;
  @override
  int get hashCode => Object.hash(trackId, previewUrl);
}

// Keep these in step with firestore.rules (song()).
final _applePreview = RegExp(r'^https://[a-z0-9.-]+\.apple\.com/');
final _appleArt = RegExp(r'^https://[a-z0-9.-]+\.mzstatic\.com/');
bool _short(String u) => u.length <= 400;
bool applePreviewUrl(String u) => _short(u) && _applePreview.hasMatch(u);
bool appleArtworkUrl(String u) => _short(u) && _appleArt.hasMatch(u);
bool appleMusicUrl(String u) => _short(u) && _applePreview.hasMatch(u);

class PulseProfile {
  final String name;

  /// [faceSize] px square JPEG, or null (coloured initials instead).
  final Uint8List? face;
  final PulseSong? song;

  const PulseProfile({required this.name, this.face, this.song});

  PulseProfile copyWith({String? name, Uint8List? Function()? face, PulseSong? Function()? song}) => PulseProfile(
      name: name ?? this.name, face: face == null ? this.face : face(), song: song == null ? this.song : song());

  String? get faceB64 => face == null ? null : base64Encode(face!);

  Map<String, Object?> toJson() => {
        'name': name,
        if (face != null) 'face': faceB64,
        if (song != null) 'song': song!.toJson(),
      };

  static PulseProfile? fromJson(Object? j) {
    if (j is! Map || j['name'] is! String) return null;
    Uint8List? face;
    final f = j['face'];
    if (f is String && f.length <= faceMaxChars) {
      try {
        face = base64Decode(f);
      } catch (_) {}
    }
    return PulseProfile(name: j['name'] as String, face: face, song: PulseSong.fromJson(j['song']));
  }
}

/// "Sage Arbor" -> "SA", "sage" -> "S".
String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
}

/// A photo (any size, any orientation) -> the centre square, [size] px,
/// JPEG. Null when it cannot be decoded.
Uint8List? squareFace(Uint8List photo, {int size = faceSize, int quality = 70}) {
  try {
    final decoded = img.decodeImage(photo);
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    final square = img.copyResizeCropSquare(upright, size: size, interpolation: img.Interpolation.average);
    var q = quality;
    var out = img.encodeJpg(square, quality: q);
    // A noisy photo can come out big: step the quality down until it fits.
    while (base64Encode(out).length > faceMaxChars && q > 20) {
      q -= 15;
      out = img.encodeJpg(square, quality: q);
    }
    return base64Encode(out).length > faceMaxChars ? null : out;
  } catch (_) {
    return null;
  }
}

/// The profile on this phone (shared_preferences), once loaded.
class PulseProfileStore {
  PulseProfileStore._();

  static const key = 'pulse.profile.v1';

  /// Null until the player made one.
  static final profile = ValueNotifier<PulseProfile?>(null);
  static bool _loaded = false;

  static Future<PulseProfile?> load() async {
    if (_loaded) return profile.value;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      profile.value = raw == null ? null : PulseProfile.fromJson(jsonDecode(raw));
    } catch (_) {}
    _loaded = true;
    return profile.value;
  }

  static Future<void> save(PulseProfile p) async {
    profile.value = p;
    _loaded = true;
    try {
      await (await SharedPreferences.getInstance()).setString(key, jsonEncode(p.toJson()));
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    profile.value = null;
    _loaded = false;
  }
}

// ------------------------------------------------------------ song search

/// The iTunes Search API (free, no key): songs only, 10 results.
Uri itunesSearchUri(String term) =>
    Uri.https('itunes.apple.com', '/search', {'term': term.trim(), 'entity': 'song', 'limit': '10'});

/// Results that have a preview (some songs have none).
List<PulseSong> parseItunes(String body) {
  try {
    final d = jsonDecode(body);
    final r = d is Map ? d['results'] : null;
    if (r is! List) return const [];
    return [for (final x in r) if (PulseSong.fromItunes(x) case final s?) s];
  } catch (_) {
    return const [];
  }
}

/// Throws on a network failure (the picker says so).
Future<List<PulseSong>> searchSongs(String term, {http.Client? client}) async {
  if (term.trim().isEmpty) return const [];
  final c = client ?? http.Client();
  try {
    final r = await c.get(itunesSearchUri(term)).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw StateError('search failed (${r.statusCode})');
    return parseItunes(r.body);
  } finally {
    if (client == null) c.close();
  }
}
