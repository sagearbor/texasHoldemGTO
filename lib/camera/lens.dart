/// Camera lens, for every camera feature (Watch my cards, Record the table,
/// Snap my cards): the Settings → Camera lens choice and the pure parts of
/// picking a lens. The camera itself is opened in lens_camera.dart.
///
/// Device-only (not in backups: it describes this phone's cameras).
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings → Camera lens. [auto] keeps each feature's own default (Record
/// the table: widest; Watch and Snap: normal).
enum LensChoice { auto, normal, widest }

const lensChoiceLabels = {
  LensChoice.auto: 'Automatic (recommended)',
  LensChoice.normal: 'Normal',
  LensChoice.widest: 'Widest',
};

/// Whether a camera feature asks for the ultra-wide lens: the setting when
/// it is Normal or Widest, else the feature's own default.
bool useWidest(LensChoice choice, {required bool featureDefault}) => switch (choice) {
      LensChoice.auto => featureDefault,
      LensChoice.normal => false,
      LensChoice.widest => true,
    };

/// Android zoom ratio to ask for: on the one logical back camera a ratio
/// under 1.0 makes CameraX switch to the ultra-wide sensor, where there is
/// one (then [minZoom] < 1).
double androidZoomFor({required bool widest, required double minZoom}) =>
    widest && minZoom < 1.0 ? minZoom : 1.0;

/// Which lens a camera feature used, as the camera reported it.
class LensInfo {
  /// `ultra_wide`, `wide` (the normal back lens) or `front`.
  final String kind;
  final String cameraName;

  /// Zoom asked for (Android: below 1.0 switches the logical camera to the
  /// ultra-wide) and the camera's minimum; null where not used.
  final double? zoom;
  final double? minZoom;
  const LensInfo(this.kind, this.cameraName, {this.zoom, this.minZoom});

  Map<String, Object?> toJson() => {
        'kind': kind,
        'camera': cameraName,
        if (zoom != null) 'zoom': zoom,
        if (minZoom != null) 'min_zoom': minZoom,
      };
}

/// "ultra-wide", "front" or "normal", for the small "Lens: ..." label.
String lensKindLabel(String kind) => switch (kind) {
      'ultra_wide' => 'ultra-wide',
      'front' => 'front',
      _ => 'normal',
    };

/// The "Lens: ..." line every camera screen shows, so testers can tell.
/// [widest]: the ultra-wide was asked for (adds a note when the phone has
/// none).
String lensLine(LensInfo lens, {required bool widest}) =>
    'Lens: ${lensKindLabel(lens.kind)}'
    '${lens.zoom != null ? ' (zoom ${lens.zoom!.toStringAsFixed(2)})' : ''}'
    '${widest && lens.kind == 'wide' ? ' · this phone has no wider lens' : ''}';

/// The saved Settings → Camera lens choice.
class CameraLens {
  CameraLens._();

  static const key = 'camera_lens_v1';

  static final choice = ValueNotifier<LensChoice>(LensChoice.auto);

  static LensChoice? parse(Object? name) {
    for (final c in LensChoice.values) {
      if (c.name == name) return c;
    }
    return null;
  }

  static Future<void> load() async {
    choice.value = LensChoice.auto;
    try {
      final p = await SharedPreferences.getInstance();
      choice.value = parse(p.getString(key)) ?? LensChoice.auto;
    } catch (_) {}
  }

  static Future<void> set(LensChoice c) async {
    choice.value = c;
    try {
      await (await SharedPreferences.getInstance()).setString(key, c.name);
    } catch (_) {}
  }
}

/// Snap my cards takes its photo in the phone's own camera app, which picks
/// the lens; this says so, and how to go wider when Widest is chosen.
String snapLensLine(LensChoice choice) => useWidest(choice, featureDefault: false)
    ? 'Lens: set in your camera app. For ultra-wide, zoom out to 0.5× there'
    : 'Lens: normal (your camera app)';
