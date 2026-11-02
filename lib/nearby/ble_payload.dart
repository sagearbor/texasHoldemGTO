/// Nearby games over Bluetooth LE: what a phone advertises, packed into one
/// 128-bit service UUID. iOS lets an app advertise only service UUIDs and a
/// local name (no service or manufacturer data), and a legacy advertisement
/// has room for one 128-bit UUID, so the UUID itself carries the payload:
///
///   bytes 0..3   magic "FNT1"
///   byte  4      kind (high nibble) | flags (low nibble)
///   game (kind 1, the host):     5..9 night id, 10..14 join secret, 15 zero
///   presence (kind 2, a player): 5..12 install id, 13..15 night tag
///
/// Codes are 5 bits a character (night_events.dart's 32-letter alphabet):
/// 8 characters fit in 5 bytes, a 12-character install id in 8. The night
/// tag is the first 24 bits of the night id, enough to group phones by
/// game. Anyone nearby can read a game advert and join, exactly like anyone
/// who sees the QR on the table.
///
/// The host's display name rides separately: Android hosts put it in the
/// scan response as manufacturer data under the test company id 0xFFFF
/// ("FN" + UTF-8), iOS hosts as the local name. Pure Dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../sync/night_events.dart';

const _magic = [0x46, 0x4E, 0x54, 0x31]; // "FNT1"

/// Lowercase hex prefix of every Felt Notes advert UUID.
const advertUuidPrefix = '464e5431';

/// Bluetooth SIG "reserved for testing" company id, for the name payload.
const nameCompanyId = 0xFFFF;

const flagUwb = 0x1; // iPhone with Nearby Interaction (UWB) ranging
const flagIos = 0x2;
const flagCamera = 0x4; // a Record-the-table phone: a fixed anchor, not a seat

sealed class BleAdvert {
  final int flags;
  const BleAdvert(this.flags);
  bool get uwb => flags & flagUwb != 0;
  bool get ios => flags & flagIos != 0;
  bool get camera => flags & flagCamera != 0;

  /// Stable key for logs: `H:<night id>` for a host, `D:<install id>` for
  /// a player phone.
  String get peerKey;
}

class GameAdvert extends BleAdvert {
  final String nightId;
  final String secret;
  const GameAdvert(this.nightId, this.secret, {int flags = 0}) : super(flags);
  @override
  String get peerKey => 'H:$nightId';
}

class PresenceAdvert extends BleAdvert {
  final String deviceId;
  final int nightTag;
  const PresenceAdvert(this.deviceId, this.nightTag, {int flags = 0}) : super(flags);
  @override
  String get peerKey => 'D:$deviceId';
}

/// The first 24 bits of a night id's packed form.
int nightTagOf(String nightId) {
  final b = _pack(nightId, 5);
  return (b[0] << 16) | (b[1] << 8) | b[2];
}

/// [code] (characters of [codeAlphabet]) as [bytes] big-endian bytes, 5
/// bits a character, right-aligned.
Uint8List _pack(String code, int bytes) {
  var v = BigInt.zero;
  for (final c in code.codeUnits) {
    final i = codeAlphabet.codeUnits.indexOf(c);
    if (i < 0) throw ArgumentError('not a code: $code');
    v = (v << 5) | BigInt.from(i);
  }
  final out = Uint8List(bytes);
  for (var k = bytes - 1; k >= 0; k--) {
    out[k] = (v & BigInt.from(0xFF)).toInt();
    v >>= 8;
  }
  if (v != BigInt.zero) throw ArgumentError('code too long: $code');
  return out;
}

String _unpack(List<int> bytes, int chars) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  final out = List.filled(chars, 0);
  for (var k = chars - 1; k >= 0; k--) {
    out[k] = codeAlphabet.codeUnitAt((v & BigInt.from(31)).toInt());
    v >>= 5;
  }
  return String.fromCharCodes(out);
}

String _uuidString(Uint8List b) {
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// The service UUID to advertise for [a].
String advertUuid(BleAdvert a) {
  final b = Uint8List(16);
  b.setAll(0, _magic);
  switch (a) {
    case GameAdvert():
      b[4] = 0x10 | (a.flags & 0xF);
      b.setAll(5, _pack(a.nightId, 5));
      b.setAll(10, _pack(a.secret, 5));
    case PresenceAdvert():
      b[4] = 0x20 | (a.flags & 0xF);
      b.setAll(5, _pack(a.deviceId, 8));
      b[13] = (a.nightTag >> 16) & 0xFF;
      b[14] = (a.nightTag >> 8) & 0xFF;
      b[15] = a.nightTag & 0xFF;
  }
  return _uuidString(b);
}

/// The advert in a service UUID, or null for anything else (other apps'
/// devices are never logged).
BleAdvert? parseAdvertUuid(String uuid) {
  final h = uuid.replaceAll('-', '').toLowerCase();
  if (h.length != 32 || !h.startsWith(advertUuidPrefix)) return null;
  final b = [for (var i = 0; i < 32; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
  final kind = b[4] >> 4, flags = b[4] & 0xF;
  try {
    switch (kind) {
      case 1:
        final night = _unpack(b.sublist(5, 10), nightIdLength), secret = _unpack(b.sublist(10, 15), secretLength);
        return GameAdvert(night, secret, flags: flags);
      case 2:
        if (b[5] >> 4 != 0) return null; // 60 bits in 64: the top nibble is 0
        return PresenceAdvert(_unpack(b.sublist(5, 13), deviceIdLength), (b[13] << 16) | (b[14] << 8) | b[15],
            flags: flags);
    }
  } catch (_) {}
  return null;
}

/// Host name payload: "FN" + UTF-8, cut to [maxBytes] on a character
/// boundary (a legacy scan response has room for about 25 bytes).
Uint8List nameData(String name, {int maxBytes = 20}) {
  var n = name.trim();
  var bytes = utf8.encode(n);
  while (bytes.length > maxBytes && n.isNotEmpty) {
    n = String.fromCharCodes(n.runes.toList()..removeLast());
    bytes = utf8.encode(n);
  }
  return Uint8List.fromList([0x46, 0x4E, ...bytes]);
}

/// The name in a manufacturer-data payload (company id already stripped),
/// or null.
String? parseNameData(List<int>? data) {
  if (data == null || data.length < 2 || data[0] != 0x46 || data[1] != 0x4E) return null;
  try {
    final s = utf8.decode(data.sublist(2)).trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// iOS hosts: the local name, which we set to the host's name (cut short:
/// what does not fit is dropped by iOS).
String localNameFor(String name) => name.trim().length > 12 ? name.trim().substring(0, 12) : name.trim();

// ------------------------------------------------------------- sightings

/// One advertisement heard by this phone's scanner.
class BleSighting {
  final List<String> uuids;
  final int rssi;

  /// Advertised transmit power in dBm (Android adverts carry it; iOS
  /// adverts do not).
  final int? txPower;
  final String? localName;

  /// Manufacturer data for [nameCompanyId], company id stripped.
  final List<int>? nameBytes;

  /// This phone's wall clock when heard.
  final int ms;
  const BleSighting({
    required this.uuids,
    required this.rssi,
    required this.ms,
    this.txPower,
    this.localName,
    this.nameBytes,
  });

  /// The first Felt Notes advert among [uuids].
  BleAdvert? get advert {
    for (final u in uuids) {
      final a = parseAdvertUuid(u);
      if (a != null) return a;
    }
    return null;
  }

  String? get hostName => parseNameData(nameBytes) ?? localName;

  static BleSighting? fromMap(Map<Object?, Object?> m) {
    final u = m['u'];
    final r = m['r'];
    if (u is! List || r is! int) return null;
    final mfg = m['m'];
    return BleSighting(
      uuids: [for (final x in u) '$x'],
      rssi: r,
      ms: (m['t'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      txPower: (m['tx'] as num?)?.toInt(),
      localName: m['n'] as String?,
      nameBytes: mfg is List ? mfg.cast<int>() : null,
    );
  }
}

/// A game heard nearby.
class NearbyGame {
  final GameAdvert advert;
  final String? hostName;
  final int rssi;
  final int lastSeenMs;
  const NearbyGame(this.advert, this.hostName, this.rssi, this.lastSeenMs);

  JoinTicket get ticket => JoinTicket(nightId: advert.nightId, secret: advert.secret, organizerName: hostName ?? '');

  /// "Sage's game", or "a game nearby" without a name.
  String get label => hostName == null || hostName!.isEmpty ? 'a game nearby' : "$hostName's game";
}

/// Games among [sightings] (newest name and strongest signal per game),
/// strongest first. Games last heard before [sinceMs] are dropped.
List<NearbyGame> gamesIn(Iterable<BleSighting> sightings, {int sinceMs = 0}) {
  final by = <String, NearbyGame>{};
  for (final s in sightings) {
    if (s.ms < sinceMs) continue;
    final a = s.advert;
    if (a is! GameAdvert) continue;
    final old = by[a.nightId];
    by[a.nightId] = NearbyGame(
      a,
      s.hostName ?? old?.hostName,
      old == null || s.rssi > old.rssi ? s.rssi : old.rssi,
      old == null || s.ms > old.lastSeenMs ? s.ms : old.lastSeenMs,
    );
  }
  return by.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
}
