/// Multi-phone table night: the event model every phone writes.
///
/// Venue assumption (owner, 2026-10-27): a basement with no cell service and
/// flaky wifi. So nothing at the table needs a network. Each phone appends
/// what it knows to its own local log ([NightEvent]s with conflict-free ids
/// `deviceId_seq`), and uploads that log whenever it next gets a connection.
/// The organizer's log is the hand timeline (seats, "next hand" taps with
/// ms timestamps, dealer); a player's log is their own taps. The merge
/// (night_merge.dart) lines them up afterwards by clock.
///
/// Design, data layout and cost: docs/MULTIPHONE.md.
library;

import 'dart:convert';
import 'dart:math';

// ------------------------------------------------------------------ ids

/// No 0/O, 1/I: a join code may be read aloud or typed from a screen.
const codeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

String randomCode(Random rng, int length) => String.fromCharCodes([
      for (var i = 0; i < length; i++) codeAlphabet.codeUnitAt(rng.nextInt(codeAlphabet.length))
    ]);

/// Table ids and join secrets are 8 characters each (32^8, about 10^12).
const nightIdLength = 8;
const secretLength = 8;

/// Device ids are 12 characters; generated once per install.
const deviceIdLength = 12;

bool isCode(String s, int length) => RegExp('^[A-HJ-NP-Z2-9]{$length}\$').hasMatch(s);

// --------------------------------------------------------------- events

enum EventKind {
  // ---- any phone (player side)
  /// Joined tonight's table by scanning the organizer's QR.
  /// `{name, claim?, offset?}`: [claim] is the organizer's roster id the
  /// player picked ("I'm John"); [offset] = organizer clock - this clock, ms.
  join,

  /// Left for the night `{}`. Hands after this are not counted as folds.
  leave,

  /// One tap for a hand you played `{e, a, f?}`: entry number, action
  /// (call | raise | fold), facing (unopened | raised).
  play,

  /// Your own hole cards `{e, c?}`. [c] is present only while sharing is
  /// on at upload time; the cloud copy otherwise keeps just "had cards".
  cards,

  /// Withdraw an entry `{e}` (mis-tap).
  undo,

  /// Card sharing on or off for the night `{on}`.
  share,

  /// The board as this phone's camera read it, one event per street
  /// `{c, q, u}`: card tokens left to right as seen from this seat ("7d",
  /// "Fr" = a red face card, "9?" = a nine of unknown suit; see
  /// lib/sync/board_consensus.dart), rank confidences, suit confidences
  /// (0..1 each). Filed under a hand by time at merge; phones vote.
  boardRead,

  /// One tap to confirm or fix the board of hand [n] `{n, c}` (3 to 5
  /// cards). Any phone; beats the cameras, loses to the organizer's
  /// `board` call.
  boardFix,

  // ---- organizer only (the dealer bookkeeping)
  /// The table in clockwise seat order `{seats: [[pid, name], ...]}`. Applies
  /// to the hands started after it. Add / remove a player = a new seats event.
  seats,

  /// Hand [n] starts now `{n, d}`: hand number and dealer pid. The ms of the
  /// event is the hand boundary.
  hand,

  /// The "next hand" tap for hand [n] was a mistake `{n}`.
  unhand,

  /// Community cards for hand [n] `{n, c}` (3 to 5 cards), if anyone called
  /// them. Optional.
  board,

  /// Night over `{}`. Closes the last hand.
  end,
}

EventKind? eventKindFromName(Object? n) {
  for (final k in EventKind.values) {
    if (k.name == n) return k;
  }
  return null;
}

/// One fact one phone knows. Only [deviceId] ever writes events with its
/// id, and [seq] counts up from 1 on that phone, so `deviceId_seq` is unique
/// without any coordination and a re-upload is harmless.
class NightEvent {
  final String deviceId;
  final int seq;
  final EventKind kind;

  /// This phone's clock (ms since epoch) when it happened.
  final int ms;
  final Map<String, Object?> data;

  const NightEvent({
    required this.deviceId,
    required this.seq,
    required this.kind,
    required this.ms,
    this.data = const {},
  });

  String get id => '${deviceId}_$seq';

  /// Compact form for the local log and the cloud copy. The device id is
  /// implied by the log it sits in.
  Map<String, Object?> toJson() => {'s': seq, 'k': kind.name, 't': ms, if (data.isNotEmpty) 'x': data};

  String encode() => jsonEncode(toJson());

  /// Null for an event from a newer app version (unknown kind).
  static NightEvent? fromJson(String deviceId, Map<String, Object?> j) {
    final k = eventKindFromName(j['k']);
    if (k == null) return null;
    return NightEvent(
      deviceId: deviceId,
      seq: j['s'] as int,
      kind: k,
      ms: j['t'] as int,
      data: ((j['x'] as Map?) ?? const {}).cast<String, Object?>(),
    );
  }

  static NightEvent? decode(String deviceId, String s) {
    try {
      return fromJson(deviceId, (jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  NightEvent withData(Map<String, Object?> d) =>
      NightEvent(deviceId: deviceId, seq: seq, kind: kind, ms: ms, data: d);

  @override
  String toString() => 'NightEvent($id ${kind.name} @$ms $data)';
}

/// A seat on the organizer's roster: a stable id the organizer's app made
/// up (players without the app get one too) and a display name.
class Seat {
  final String pid;
  final String name;
  const Seat(this.pid, this.name);

  List<String> toJson() => [pid, name];
  static Seat fromJson(Object? j) {
    final l = (j as List).cast<String>();
    return Seat(l[0], l[1]);
  }

  @override
  bool operator ==(Object other) => other is Seat && other.pid == pid && other.name == name;
  @override
  int get hashCode => Object.hash(pid, name);
  @override
  String toString() => '$pid:$name';
}

// ----------------------------------------------------------- join ticket

/// What the organizer's QR encodes. Shown at the START of the night; each
/// player scans it once. Re-rendered every second so [organizerMs] is
/// fresh: the scanning phone stores `organizerMs - its own clock` as its
/// clock offset, accurate to about a second (plenty: hands take minutes).
class JoinTicket {
  final String nightId;
  final String secret;
  final String organizerName;

  /// The organizer's clock when the QR was drawn; null when the code was
  /// typed (no clock reading, the merge falls back to server time).
  final int? organizerMs;

  /// The organizer's roster if one exists yet, so the player can say
  /// which seat is theirs. Optional; the merge also links by name.
  final List<Seat> roster;

  const JoinTicket({
    required this.nightId,
    required this.secret,
    required this.organizerName,
    this.organizerMs,
    this.roster = const [],
  });

  /// The short code to type or paste (no clock): `ABCD2345-WXYZ6789`.
  String get code => '$nightId-$secret';

  /// QR payload: `feltnotes:join?t=..&s=..&n=..&c=<ms base36>&r=pid~name,..`
  String encode() {
    final q = <String, String>{
      't': nightId,
      's': secret,
      'n': organizerName,
      if (organizerMs != null) 'c': organizerMs!.toRadixString(36),
      if (roster.isNotEmpty)
        'r': [for (final s in roster) '${_esc(s.pid)}~${_esc(s.name)}'].join(','),
    };
    return 'feltnotes:join?${q.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}';
  }

  JoinTicket withClock(int ms) => JoinTicket(
      nightId: nightId, secret: secret, organizerName: organizerName, organizerMs: ms, roster: roster);

  static String _esc(String s) => s.replaceAll('~', '-').replaceAll(',', ' ');

  /// Accepts a scanned QR payload or a typed/pasted code
  /// ("abcd 2345 - wxyz 6789"). Null when it is neither.
  static JoinTicket? parse(String raw) {
    final s = raw.trim();
    if (s.startsWith('feltnotes:join?')) {
      final Map<String, String> q;
      try {
        q = Uri.splitQueryString(s.substring('feltnotes:join?'.length));
      } catch (_) {
        return null;
      }
      final t = q['t'] ?? '', sec = q['s'] ?? '';
      if (!isCode(t, nightIdLength) || !isCode(sec, secretLength)) return null;
      final c = q['c'] == null ? null : int.tryParse(q['c']!, radix: 36);
      final roster = <Seat>[
        for (final p in (q['r'] ?? '').split(','))
          if (p.contains('~')) Seat(p.substring(0, p.indexOf('~')), p.substring(p.indexOf('~') + 1)),
      ];
      return JoinTicket(
        nightId: t,
        secret: sec,
        organizerName: (q['n'] ?? '').trim(),
        organizerMs: c,
        roster: roster,
      );
    }
    final flat = s.toUpperCase().replaceAll(RegExp(r'[\s\-_.]'), '');
    if (flat.length != nightIdLength + secretLength) return null;
    final t = flat.substring(0, nightIdLength), sec = flat.substring(nightIdLength);
    if (!isCode(t, nightIdLength) || !isCode(sec, secretLength)) return null;
    return JoinTicket(nightId: t, secret: sec, organizerName: '');
  }
}

/// The organizer clock minus this phone's clock, from a freshly scanned
/// ticket. Null for a typed code.
int? clockOffsetFrom(JoinTicket t, int localMsAtScan) =>
    t.organizerMs == null ? null : t.organizerMs! - localMsAtScan;
