/// Opens a camera on the lens asked for (see lens.dart), for Watch my cards
/// and Record the table. Android: one logical back camera, a zoom ratio
/// under 1.0 switches it to the ultra-wide. iOS: the plugin lists each lens
/// and the ultra-wide is picked by its id (record_native.dart).
library;

import 'dart:io';

import 'package:camera/camera.dart';

import '../record/record_native.dart' show ultraWideCameraName;
import 'lens.dart';

/// The camera to open for [direction] and its lens kind: the iOS
/// ultra-wide ([ultraWideName]) when [widest] and it is listed, else the
/// first camera facing [direction]. With none facing that way: the first
/// camera when [fallbackToAny], else null.
(CameraDescription, String)? pickCamera(
  List<CameraDescription> cams, {
  required CameraLensDirection direction,
  required bool widest,
  String? ultraWideName,
  bool fallbackToAny = false,
}) {
  final facing = [for (final c in cams) if (c.lensDirection == direction) c];
  if (facing.isEmpty) {
    if (!fallbackToAny || cams.isEmpty) return null;
    final c = cams.first;
    return (c, c.lensDirection == CameraLensDirection.front ? 'front' : 'wide');
  }
  if (direction == CameraLensDirection.front) return (facing.first, 'front');
  if (widest && ultraWideName != null) {
    for (final c in facing) {
      if (c.name == ultraWideName) return (c, 'ultra_wide');
    }
  }
  return (facing.first, 'wide');
}

/// Opens and initializes a camera on the lens asked for and reports which
/// lens it got. Only the back camera has an ultra-wide; [widest] is ignored
/// for the front one. Throws [StateError] when there is no camera to open.
Future<(CameraController, LensInfo)> openCameraWithLens({
  required CameraLensDirection direction,
  required bool widest,
  required ResolutionPreset preset,
  int? fps,
  ImageFormatGroup? imageFormatGroup,
  bool fallbackToAny = false,
}) async {
  final cams = await availableCameras();
  final back = direction == CameraLensDirection.back;
  final uw = widest && back && Platform.isIOS ? await ultraWideCameraName() : null;
  final pick = pickCamera(cams,
      direction: direction, widest: widest, ultraWideName: uw, fallbackToAny: fallbackToAny);
  if (pick == null) throw StateError('no ${direction.name} camera');
  var (cam, kind) = pick;
  final c = CameraController(cam, preset, enableAudio: false, fps: fps, imageFormatGroup: imageFormatGroup);
  await c.initialize();
  double? zoom, minZoom;
  if (Platform.isAndroid && kind == 'wide') {
    try {
      minZoom = await c.getMinZoomLevel();
      zoom = androidZoomFor(widest: widest, minZoom: minZoom);
      // 1.0 is the default: only touch the zoom to go wider.
      if (zoom < 1.0) {
        await c.setZoomLevel(zoom);
        kind = 'ultra_wide';
      }
    } catch (_) {}
  }
  return (c, LensInfo(kind, cam.name, zoom: zoom, minZoom: minZoom));
}
