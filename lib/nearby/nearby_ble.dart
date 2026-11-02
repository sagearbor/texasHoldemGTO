/// Nearby games: the native Bluetooth LE side (BleChannel.kt,
/// NearbyChannel.swift), channel `felt_notes/ble` and event channel
/// `felt_notes/ble_events`. Advertise one Felt Notes UUID
/// (ble_payload.dart), scan for a few seconds, and on iPhones exchange
/// Nearby Interaction tokens with other iPhones over a short GATT
/// connection for UWB distances. Every call degrades to "not available"
/// where the native side is missing (web, tests).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../record/record_native.dart' show requestAndroidPermissions, hasAndroidPermissions;
import 'ble_payload.dart';

const _ch = MethodChannel('felt_notes/ble');
const _events = EventChannel('felt_notes/ble_events');

bool get bleSupported =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

Future<T?> _call<T>(String method, [Object? args]) async {
  if (!bleSupported) return null;
  try {
    return await _ch.invokeMethod<T>(method, args);
  } on MissingPluginException {
    return null;
  } on PlatformException catch (e) {
    debugPrint('ble $method: ${e.code} ${e.message}');
    return null;
  }
}

/// Android 12+ asks for "Nearby devices" (scan, advertise, connect: scan
/// is flagged neverForLocation); Android 11 and older can only scan with
/// location permission.
Future<List<String>> _androidPerms() async {
  final sdk = await _call<int>('sdk') ?? 31;
  return sdk >= 31
      ? const [
          'android.permission.BLUETOOTH_SCAN',
          'android.permission.BLUETOOTH_ADVERTISE',
          'android.permission.BLUETOOTH_CONNECT',
        ]
      : const ['android.permission.ACCESS_FINE_LOCATION'];
}

/// Allowed already (no prompt shown). iOS: Bluetooth authorization is
/// "allowed always" or the app never asked yet counts as false.
Future<bool> bleAllowed() async {
  if (!bleSupported) return false;
  if (Platform.isAndroid) return hasAndroidPermissions(await _androidPerms());
  return await _call<String>('authorization') == 'allowed';
}

/// Shows the OS prompt if needed; true when Bluetooth can be used.
Future<bool> bleRequest() async {
  if (!bleSupported) return false;
  if (Platform.isAndroid) {
    if (!await requestAndroidPermissions(await _androidPerms())) return false;
    return true;
  }
  // iOS: the prompt appears when the native side first creates its
  // Bluetooth managers.
  return await _call<String>('requestAuthorization') == 'allowed';
}

/// Bluetooth radio on (false: off, or no BLE advertiser on this phone).
Future<bool> blePoweredOn() async => await _call<bool>('poweredOn') ?? false;

/// Advertise [uuid] (one at a time; a new call replaces the old one).
/// [name]: the host's display name (Android: scan response; iOS: local
/// name). Returns false when the phone cannot advertise.
/// [power]: Android advert power, `high` (the default, and always in a
/// game), `medium` or `low` (the distance test alternates high and low).
/// iOS has no such setting.
Future<bool> bleAdvertise(String uuid, {String? name, String power = 'high', bool connectable = false}) async =>
    await _call<bool>('advertise', {
      'uuid': uuid,
      'power': power,
      // Android UWB pairing needs a GATT connection.
      'connectable': connectable,
      if (name != null) 'name': localNameFor(name),
      if (name != null) 'nameData': nameData(name),
      'company': nameCompanyId,
    }) ??
    false;

Future<void> bleStopAdvertising() async => _call<void>('stopAdvertising');

/// Scans for [ms] and returns the Felt Notes adverts heard (the native
/// side drops everything else).
Future<List<BleSighting>> bleScan(int ms) async {
  final raw = await _call<List>('scan', {'ms': ms, 'prefix': advertUuidPrefix});
  if (raw == null) return const [];
  return [for (final m in raw) if (m is Map) BleSighting.fromMap(m)].whereType<BleSighting>().toList();
}

/// Screen on (Android: interactive; iOS: true while in the foreground,
/// null when unknown).
Future<bool?> screenOn() => _call<bool>('screenOn');

// ------------------------------------------------------------------ UWB

/// iPhone with a U1/U2 chip and Nearby Interaction.
Future<bool> uwbSupported() async => await _call<bool>('uwbSupported') ?? false;

/// Starts offering this phone's Nearby Interaction tokens to other
/// iPhones (a GATT service) as install id [deviceId].
Future<void> uwbStart(String deviceId) => _call<void>('uwbStart', {'deviceId': deviceId});

Future<void> uwbStop() => _call<void>('uwbStop');

/// Exchanges tokens with the iPhone advertising [uuid] (heard in the last
/// scan) and starts ranging with it. Fire and forget: readings arrive on
/// [bleEvents].
Future<void> uwbRange(String uuid) => _call<void>('uwbRange', {'uuid': uuid});

/// Peers with a running ranging session (install ids).
Future<List<String>> uwbPeers() async => [for (final p in await _call<List>('uwbPeers') ?? const []) '$p'];

/// Native events: `{type: 'uwb', peer, m, dir?, t}`,
/// `{type: 'uwbState', peer, state, why?}`, `{type: 'bt', on}`.
Stream<Map<String, Object?>> bleEvents() {
  if (!bleSupported) return const Stream.empty();
  return _events.receiveBroadcastStream().where((e) => e is Map).map((e) => (e as Map).cast<String, Object?>());
}

/// Bluetooth distance test: scan without stopping (low latency, every
/// advert, duplicates kept); each Felt Notes advert arrives on [bleEvents]
/// as `{type: 'adv', u, r, tx?, n?, m?, t}` until [bleScanStop].
Future<bool> bleScanStart() async => await _call<bool>('scanStart', {'prefix': advertUuidPrefix}) ?? false;

Future<void> bleScanStop() => _call<void>('scanStop');

/// Distance test diagnostics: the native side's current picture
/// (`interactive, adapter, scan, advert, heard_all, heard_felt`, last scan
/// failure and advert result with times, scan restarts). Null when there
/// is no native side.
Future<Map<String, Object?>?> bleStatus() async => (await _call<Map>('bleStatus'))?.cast<String, Object?>();
