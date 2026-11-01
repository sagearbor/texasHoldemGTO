/// Record the table: the small native helpers (MainActivity.kt and
/// AppDelegate.swift, channel `felt_notes/record`). Every call degrades to
/// null on a platform without them (web, tests, an older native build), so
/// the screen shows "unknown" instead of failing.
library;

import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _ch = MethodChannel('felt_notes/record');

Future<T?> _call<T>(String method, [Object? args]) async {
  if (kIsWeb) return null;
  try {
    return await _ch.invokeMethod<T>(method, args);
  } on MissingPluginException {
    return null;
  } on PlatformException catch (e) {
    debugPrint('record native $method: ${e.code} ${e.message}');
    return null;
  }
}

/// iOS: the camera plugin's name (AVCaptureDevice uniqueID) of the back
/// ultra-wide lens, when the phone has one.
Future<String?> ultraWideCameraName() => _call<String>('ultraWideCamera');

/// Encodes one stream frame to a JPEG at [path], on a native background
/// thread. [rotation] (0/90/180/270) goes into the EXIF orientation tag
/// (Android frames come in sensor orientation; iOS frames are upright).
/// Returns the file size in bytes, or null on failure.
Future<int?> encodeJpeg(CameraImage img, String path, {int quality = 85, int rotation = 0}) async {
  final r = await _call<Map>('encodeJpeg', {
    'path': path,
    'width': img.width,
    'height': img.height,
    'format': img.format.group == ImageFormatGroup.bgra8888 ? 'bgra' : 'yuv420',
    'planes': [for (final p in img.planes) p.bytes],
    'rowStrides': [for (final p in img.planes) p.bytesPerRow],
    'pixelStrides': [for (final p in img.planes) p.bytesPerPixel ?? 1],
    'quality': quality,
    'rotation': rotation,
  });
  return r?['bytes'] as int?;
}

/// `nominal`, `fair`, `serious`, `critical` (iOS ProcessInfo.thermalState;
/// Android PowerManager thermal status mapped onto the same four), or
/// `unknown`.
Future<String> thermalState() async => await _call<String>('thermal') ?? 'unknown';

/// Free bytes on the volume holding [dir].
Future<int?> freeBytes(Directory dir) async {
  final r = await _call<Map>('storage', {'path': dir.path});
  return (r?['free'] as num?)?.toInt();
}

/// `{model, manufacturer, os, sdk?}` from the OS; null if unknown.
Future<Map<String, Object?>?> deviceInfo() async {
  final r = await _call<Map>('device');
  return r?.cast<String, Object?>();
}

/// The phone's coarse location once: the last known fix is fine (a
/// basement has no GPS). With [ask] the OS prompt may show first. Null when
/// not permitted or unknown. `{lat, lon, acc_m, age_s}`.
Future<Map<String, Object?>?> coarseLocation({bool ask = false}) async {
  final r = await _call<Map>('location', {'ask': ask});
  if (r == null || r['lat'] == null) return null;
  return r.cast<String, Object?>();
}

/// Android runtime permissions by manifest name; true when all granted.
/// iOS asks per feature (no-op here, returns true).
Future<bool> requestAndroidPermissions(List<String> names) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  return await _call<bool>('permissions', {'names': names}) ?? false;
}

/// Whether the Android permissions are already granted (no prompt).
Future<bool> hasAndroidPermissions(List<String> names) async {
  if (kIsWeb || !Platform.isAndroid) return true;
  return await _call<bool>('hasPermissions', {'names': names}) ?? false;
}
