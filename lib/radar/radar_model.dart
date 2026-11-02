/// Live seat radar: who sits where, from phone radio only. Players never
/// tap anything; the data is the one-time setup (table shape, player
/// count, where the camera is, the organizer's seat) plus what the phones
/// already upload in a table night: once a minute each phone's `sense`
/// event with the median RSSI of every Felt Notes phone it heard in its
/// two 4-second scans (lib/nearby/sense.dart; build 0.3.3+27 and later), its
/// `device` event (advert key, model, role) and iPhone-iPhone UWB distances.
///
/// Seats first: the table outline gets N seat slots evenly around it,
/// starting next to the camera (Record the table's phone, a fixed anchor,
/// never a seat). Each app phone's seat is a probability over the slots,
/// from the maximum joint likelihood of the readings under a log-distance
/// model that is steep up to about 4 ft and nearly flat beyond (Pixel
/// measurements), with a per-phone bias. Neighbours being louder than the
/// far side, and two quiet phones having a slot between them, fall out of
/// the geometry. A beam search over slot assignments (N <= 12) keeps the
/// best few thousand; their softmax is the posterior. Pure Dart.
library;

import 'dart:math' as math;

import '../sync/night_events.dart';
import '../sync/night_merge.dart' show DeviceLog;

// ------------------------------------------------------------ the table

enum TableShape { oval, rectangle }

/// Where the camera phone sits: the middle of a short end, or the middle of
/// a long side (Record the table's End / Side; Other counts as End).
enum CameraAt { end, side }

const feetToM = 0.3048;

/// The organizer's one-time setup, also published to the night's log
/// (`radar` event) so the TV draws the same table.
class RadarConfig {
  final TableShape shape;
  final double lengthFt, widthFt;
  final int seats;
  final CameraAt camera;

  /// Seats at each end of the table: 1 (in the middle) or 2 (at the
  /// corners). Left end = the camera's end when the camera is at an end.
  final int leftEndSeats, rightEndSeats;

  /// The organizer's own seat (0-based slot) if the organizer plays; that
  /// slot is theirs, not an app phone's, unless [organizerDevice] is set.
  final int? organizerSeat;

  /// The organizer's own phone if it is a player phone (hand-logger
  /// organizer) rather than the camera: pinned to [organizerSeat], it is a
  /// second anchor that settles left from right.
  final String? organizerDevice;

  const RadarConfig({
    this.shape = TableShape.oval,
    this.lengthFt = 8,
    this.widthFt = 4,
    this.seats = 6,
    this.camera = CameraAt.end,
    this.leftEndSeats = 1,
    this.rightEndSeats = 1,
    this.organizerSeat,
    this.organizerDevice,
  });

  RadarConfig copyWith({
    TableShape? shape,
    double? lengthFt,
    double? widthFt,
    int? seats,
    CameraAt? camera,
    int? leftEndSeats,
    int? rightEndSeats,
    int? Function()? organizerSeat,
    String? Function()? organizerDevice,
  }) =>
      RadarConfig(
        shape: shape ?? this.shape,
        lengthFt: lengthFt ?? this.lengthFt,
        widthFt: widthFt ?? this.widthFt,
        seats: seats ?? this.seats,
        camera: camera ?? this.camera,
        leftEndSeats: leftEndSeats ?? this.leftEndSeats,
        rightEndSeats: rightEndSeats ?? this.rightEndSeats,
        organizerSeat: organizerSeat == null ? this.organizerSeat : organizerSeat(),
        organizerDevice: organizerDevice == null ? this.organizerDevice : organizerDevice(),
      );

  Map<String, Object?> toJson() => {
        'shape': shape.name,
        'l': lengthFt,
        'w': widthFt,
        'n': seats,
        'cam': camera.name,
        'eL': leftEndSeats,
        'eR': rightEndSeats,
        if (organizerSeat != null) 'org': organizerSeat,
        if (organizerDevice != null) 'orgDev': organizerDevice,
      };

  static RadarConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    T? pick<T extends Enum>(List<T> vs, Object? n) => vs.where((v) => v.name == n).firstOrNull;
    final n = (j['n'] as num?)?.toInt();
    if (n == null || n < 2 || n > 12) return null;
    return RadarConfig(
      shape: pick(TableShape.values, j['shape']) ?? TableShape.oval,
      lengthFt: ((j['l'] as num?)?.toDouble() ?? 8).clamp(3, 20).toDouble(),
      widthFt: ((j['w'] as num?)?.toDouble() ?? 4).clamp(2, 10).toDouble(),
      seats: n,
      camera: pick(CameraAt.values, j['cam']) ?? CameraAt.end,
      leftEndSeats: j['eL'] == 2 ? 2 : 1,
      rightEndSeats: j['eR'] == 2 ? 2 : 1,
      organizerSeat: (j['org'] as num?)?.toInt(),
      organizerDevice: j['orgDev'] as String?,
    );
  }
}

/// A point in metres, table centre at the origin, long axis along x.
typedef Pt = (double, double);

double dist(Pt a, Pt b) => math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

/// Where people sit: this far out from the table edge.
const chairOffsetM = 0.35;

class TableLayout {
  final RadarConfig config;

  /// The table edge, for drawing (closed polygon, clockwise).
  final List<Pt> outline;

  /// The seat slots, clockwise from the camera.
  final List<Pt> slots;
  final Pt camera;
  const TableLayout(this.config, this.outline, this.slots, this.camera);
}

/// N slots evenly (by arc length) around the chair line, the first half a
/// step clockwise from the camera, so the camera sits between the last
/// slot and the first.
TableLayout layoutTable(RadarConfig c) {
  final l = c.lengthFt * feetToM, w = c.widthFt * feetToM;
  List<Pt> ring(double a, double b) {
    // Clockwise (y up): from the camera's point on the left end (or the
    // bottom of the long side) round the table.
    const steps = 720;
    final pts = <Pt>[];
    if (c.shape == TableShape.oval) {
      final start = c.camera == CameraAt.end ? math.pi : -math.pi / 2;
      for (var i = 0; i < steps; i++) {
        final t = start - 2 * math.pi * i / steps;
        pts.add((a * math.cos(t), b * math.sin(t)));
      }
    } else {
      final corners = <Pt>[(-a, b), (a, b), (a, -b), (-a, -b)];
      final Pt first = c.camera == CameraAt.end ? (-a, 0) : (0, -b);
      // Walk the rectangle clockwise from [first].
      final order = c.camera == CameraAt.end
          ? [first, corners[0], corners[1], corners[2], corners[3], first]
          : [first, corners[3], corners[0], corners[1], corners[2], first];
      for (var k = 0; k + 1 < order.length; k++) {
        final p = order[k], q = order[k + 1];
        final segSteps = math.max(2, (dist(p, q) / (4 * (a + b)) * steps).round());
        for (var i = 0; i < segSteps; i++) {
          final f = i / segSteps;
          pts.add((p.$1 + (q.$1 - p.$1) * f, p.$2 + (q.$2 - p.$2) * f));
        }
      }
    }
    return pts;
  }

  final edge = ring(l / 2, w / 2);
  final chairs = ring(l / 2 + chairOffsetM, w / 2 + chairOffsetM);
  // Arc length along the chair line.
  final cum = <double>[0];
  for (var i = 1; i <= chairs.length; i++) {
    cum.add(cum.last + dist(chairs[i - 1], chairs[i % chairs.length]));
  }
  final total = cum.last;
  Pt at(double s) {
    s = s % total;
    var i = 0;
    while (i + 1 < cum.length && cum[i + 1] < s) {
      i++;
    }
    final seg = cum[i + 1] - cum[i];
    final f = seg == 0 ? 0.0 : (s - cum[i]) / seg;
    final p = chairs[i], q = chairs[(i + 1) % chairs.length];
    return (p.$1 + (q.$1 - p.$1) * f, p.$2 + (q.$2 - p.$2) * f);
  }

  double arcOf(Pt target) {
    var best = 0, bd = double.infinity;
    for (var i = 0; i < chairs.length; i++) {
      final d = dist(chairs[i], target);
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return cum[best];
  }

  // The end seats where the setup says (1: the middle of the end, 2: its
  // corners), the rest evenly along the two long sides between them.
  final a = l / 2 + chairOffsetM, b = w / 2 + chairOffsetM;
  List<Pt> endSeats(int n, double sign) {
    if (n == 1) return [(sign * a, 0)];
    return c.shape == TableShape.oval
        ? [(sign * a * math.cos(0.56), b * math.sin(0.56)), (sign * a * math.cos(0.56), -b * math.sin(0.56))]
        : [(sign * a, b * 0.5), (sign * a, -b * 0.5)];
  }

  final ends = [...endSeats(c.leftEndSeats, -1), ...endSeats(c.rightEndSeats, 1)];
  List<double> arcs;
  if (c.seats < ends.length + 2) {
    // Too few players for that shape: evenly all round.
    arcs = [for (var k = 0; k < c.seats; k++) total * (k + 0.5) / c.seats];
  } else {
    final anchors = [for (final p in ends) arcOf(p)]..sort();
    // The gaps between consecutive end seats; the two longest are the
    // sides, sharing the other seats by their length.
    final gaps = [
      for (var i = 0; i < anchors.length; i++)
        (i, (anchors[(i + 1) % anchors.length] - anchors[i] + total) % total)
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    final rest = c.seats - anchors.length;
    final g1 = gaps[0], g2 = gaps[1];
    var n1 = (rest * g1.$2 / (g1.$2 + g2.$2)).round();
    n1 = n1.clamp(0, rest);
    arcs = [...anchors];
    for (final (g, n) in [(g1, n1), (g2, rest - n1)]) {
      final start = anchors[g.$1];
      for (var j = 1; j <= n; j++) {
        arcs.add((start + g.$2 * j / (n + 1)) % total);
      }
    }
  }
  // Clockwise from the camera; a seat right at the camera (one seat at the
  // camera's end) is slot 0, and the camera point moves out behind it.
  arcs = [for (final x in arcs) x % total]..sort();
  final slots = [for (final x in arcs) at(x)];
  var cam = chairs.first;
  if (slots.any((p) => dist(p, cam) < 0.1)) {
    final len = math.sqrt(cam.$1 * cam.$1 + cam.$2 * cam.$2);
    cam = (cam.$1 * (len + 0.3) / len, cam.$2 * (len + 0.3) / len);
  }
  return TableLayout(c, edge, slots, cam);
}

/// The organizer's latest `radar` event in a night's logs (how the TV
/// learns the table).
RadarConfig? radarConfigIn(Iterable<DeviceLog> logs, {String? organizerDevice}) {
  NightEvent? last;
  for (final l in logs) {
    if (organizerDevice != null && l.deviceId != organizerDevice) continue;
    for (final e in l.events) {
      if (e.kind == EventKind.radar && (last == null || e.ms > last.ms)) last = e;
    }
  }
  return last == null ? null : RadarConfig.fromJson(last.data);
}

// ------------------------------------------------------------- readings

/// One directed link: [from] heard [to] at median [rssi] dBm over [n]
/// readings.
class RadarLink {
  final String from, to;
  final double rssi;
  final int n;
  const RadarLink(this.from, this.to, this.rssi, this.n);
}

class RadarInput {
  /// Install id -> display name (from its join).
  final Map<String, String> names;

  /// Record-the-table phones: anchors, never seats.
  final Set<String> cameras;
  final List<RadarLink> links;

  /// Unordered pair "a|b" (sorted) -> UWB metres.
  final Map<String, double> uwb;

  /// Newest reading used (each phone's own clock), for "data age".
  final int? newestMs;

  /// Per phone: its newest minute that heard it or that it wrote.
  final Map<String, int> lastSeenMs;

  /// Heard 3 to 10 minutes ago only: shown faded, "left?".
  final Set<String> stale;

  /// Phones with at least one reading (heard or hearing).
  Set<String> get phones => {for (final l in links) ...[l.from, l.to]};

  const RadarInput({
    this.names = const {},
    this.cameras = const {},
    this.links = const [],
    this.uwb = const {},
    this.newestMs,
    this.lastSeenMs = const {},
    this.stale = const {},
  });

  /// Phones not heard for 10 minutes drop off; 3 to 10 minutes: [stale].
  /// A phone without a time (tests) stays.
  RadarInput live(int nowMs, {int staleMs = 3 * 60000, int goneMs = 10 * 60000}) {
    bool gone(String d) => lastSeenMs[d] != null && nowMs - lastSeenMs[d]! > goneMs;
    return RadarInput(
      names: names,
      cameras: cameras,
      links: [for (final l in links) if (!gone(l.from) && !gone(l.to)) l],
      uwb: {
        for (final e in uwb.entries)
          if (!e.key.split('|').any(gone)) e.key: e.value
      },
      newestMs: newestMs,
      lastSeenMs: lastSeenMs,
      stale: {
        for (final e in lastSeenMs.entries)
          if (nowMs - e.value > staleMs && nowMs - e.value <= goneMs) e.key
      },
    );
  }
}

String pairKey(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

/// The readings in a night's uploaded logs: each phone's last [windows]
/// `sense` minutes (its own clock, so no offsets needed), peers resolved
/// from their advert keys (`D:<install id>`, `H:<night>` for the host).
RadarInput radarInputFrom(Iterable<DeviceLog> logs, {int windows = 3}) {
  final names = <String, String>{};
  final cameras = <String>{};
  final keyToDev = <String, String>{};
  for (final l in logs) {
    keyToDev['D:${l.deviceId}'] = l.deviceId;
    for (final e in l.events) {
      if (e.kind == EventKind.join) {
        final n = e.data['name'];
        if (n is String && n.isNotEmpty) names[l.deviceId] = n;
        if (e.data['role'] == 'camera') cameras.add(l.deviceId);
      } else if (e.kind == EventKind.device) {
        final k = e.data['key'];
        if (k is String) keyToDev[k] = l.deviceId;
        if (e.data['role'] == 'camera') cameras.add(l.deviceId);
      }
    }
  }
  final acc = <String, (double, int)>{}; // "from>to" -> (sum rssi*n, n)
  final uwbAcc = <String, (double, int)>{};
  final seen = <String, int>{};
  void saw(String d, int ms) => seen[d] = math.max(seen[d] ?? ms, ms);
  int? newest;
  for (final l in logs) {
    final sense = [for (final e in l.events) if (e.kind == EventKind.sense) e]..sort((a, b) => a.ms.compareTo(b.ms));
    for (final e in sense.skip(math.max(0, sense.length - windows))) {
      newest = newest == null ? e.ms : math.max(newest, e.ms);
      saw(l.deviceId, e.ms);
      for (final p in (e.data['p'] as List?) ?? const []) {
        if (p is! List || p.length < 3) continue;
        final to = keyToDev['${p[0]}'] ?? ('${p[0]}'.startsWith('D:') ? '${p[0]}'.substring(2) : null);
        final r = (p[1] as num?)?.toDouble(), n = (p[2] as num?)?.toInt() ?? 1;
        if (to == null || r == null || to == l.deviceId) continue;
        saw(to, e.ms);
        final k = '${l.deviceId}>$to';
        final o = acc[k] ?? (0.0, 0);
        acc[k] = (o.$1 + r * n, o.$2 + n);
      }
      for (final u in (e.data['u'] as List?) ?? const []) {
        if (u is! List || u.length < 2) continue;
        final to = keyToDev['${u[0]}'] ?? ('${u[0]}'.startsWith('D:') ? '${u[0]}'.substring(2) : null);
        final cm = (u[1] as num?)?.toDouble();
        if (to == null || cm == null || to == l.deviceId) continue;
        final k = pairKey(l.deviceId, to);
        final o = uwbAcc[k] ?? (0.0, 0);
        uwbAcc[k] = (o.$1 + cm / 100, o.$2 + 1);
      }
    }
  }
  return RadarInput(
    names: names,
    cameras: cameras,
    links: [
      for (final e in acc.entries)
        RadarLink(e.key.split('>')[0], e.key.split('>')[1], e.value.$1 / e.value.$2, e.value.$2),
    ],
    uwb: {for (final e in uwbAcc.entries) e.key: e.value.$1 / e.value.$2},
    newestMs: newest,
    lastSeenMs: seen,
  );
}

// --------------------------------------------------------------- model

/// RSSI vs distance, from the Pixel distance tests: steep (path loss
/// exponent [nNear]) up to [kneeM] (about 4 ft), nearly flat beyond.
class RadioModel {
  final double nNear, nFar, kneeM;

  /// Robust spread (dB): a reading this far off costs about 1 nat; much
  /// further (phone face down, a body in the way: 6-11 dB) costs only
  /// logarithmically more (Cauchy loss).
  final double sigmaDb;
  final double uwbSigmaM;
  const RadioModel({this.nNear = 2.2, this.nFar = 0.8, this.kneeM = 1.2, this.sigmaDb = 5, this.uwbSigmaM = 0.15});

  /// Expected RSSI minus its 1 m level.
  double shape(double d) {
    final x = math.max(d, 0.3);
    if (x <= kneeM) return -10 * nNear * _log10(x);
    return -10 * nNear * _log10(kneeM) - 10 * nFar * _log10(x / kneeM);
  }

  double rssiCost(double residualDb) => math.log(1 + math.pow(residualDb / sigmaDb, 2));
  double uwbCost(double residualM) => 0.5 * math.pow(residualM / uwbSigmaM, 2).toDouble();
}

double _log10(double x) => math.log(x) / math.ln10;

class RadarEstimate {
  final TableLayout layout;

  /// App phone -> probability per slot (sums to 1).
  final Map<String, List<double>> probs;

  /// Slot taken by the organizer (not a phone), if any.
  final int? organizerSlot;

  /// Why there is no estimate yet ("not enough data yet"), or null.
  final String? notEnough;
  final int linksUsed;

  /// The single most likely seating (one phone per slot).
  final Map<String, int> joint;
  const RadarEstimate(this.layout, this.probs,
      {this.organizerSlot, this.notEnough, this.linksUsed = 0, this.joint = const {}});

  int? bestSlot(String phone) {
    final p = probs[phone];
    if (p == null) return null;
    var b = 0;
    for (var i = 1; i < p.length; i++) {
      if (p[i] > p[b]) b = i;
    }
    return b;
  }

  /// Total phone probability in [slot] (grey = no app).
  double occupancy(int slot) => probs.values.fold(0.0, (a, p) => a + p[slot]);
}

/// The seat estimate. [beam] bounds the search; [temperature] > 1 widens
/// the posterior to account for correlated errors (the same phone face
/// down affects all its links); 4 makes the top probability match how
/// often it is right on the synthetic tables (test/radar_test.dart).
RadarEstimate estimateSeats(
  RadarConfig cfg,
  RadarInput inp, {
  RadioModel model = const RadioModel(),
  int beam = 3000,
  double temperature = 4.0,
}) {
  final lay = layoutTable(cfg);
  final cams = inp.cameras;
  final pinned = <String, int>{};
  final org = cfg.organizerSeat;
  if (org != null && cfg.organizerDevice != null && !cams.contains(cfg.organizerDevice)) {
    pinned[cfg.organizerDevice!] = org;
  }
  final phones = (inp.phones.difference(cams).toList()..sort());
  final camera = cams.where(inp.phones.contains).firstOrNull;
  final freeSlots = [
    for (var k = 0; k < cfg.seats; k++)
      if (k != org || pinned.isNotEmpty) k
  ];
  if (phones.isEmpty) return RadarEstimate(lay, const {}, organizerSlot: pinned.isEmpty ? org : null, notEnough: 'No phone heard yet.');
  if (phones.length > freeSlots.length) {
    return RadarEstimate(lay, const {}, notEnough: 'More phones (${phones.length}) than seats: check the player count.');
  }
  final idx = {for (var i = 0; i < phones.length; i++) phones[i]: i};
  final links = [
    for (final l in inp.links)
      if ((idx.containsKey(l.from) || l.from == camera) && (idx.containsKey(l.to) || l.to == camera)) l
  ];
  if (links.length < phones.length) {
    return RadarEstimate(lay, const {}, notEnough: 'Not enough data yet (${links.length} links).');
  }

  // Positions: a phone's slot, or the fixed camera point.
  Pt posOf(String d, List<int?> slotOf) => d == camera ? lay.camera : lay.slots[slotOf[idx[d]!]!];

  // Level and per-phone biases, refitted from the best assignment.
  var level = -60.0;
  final bias = <String, double>{};
  double w(RadarLink l) {
    // Strong links say the most (short range is where RSSI moves).
    final strong = ((l.rssi + 85) / 25).clamp(0.2, 1.0);
    return math.sqrt(l.n.clamp(1, 30)) * strong;
  }

  double linkCost(RadarLink l, Pt a, Pt b) =>
      w(l) * model.rssiCost(l.rssi - level - (bias[l.from] ?? 0) - (bias[l.to] ?? 0) - model.shape(dist(a, b)));

  // Per phone: its links and UWB pairs, with the other end's index (-1:
  // the camera).
  final adj = {for (final p in phones) p: <(int, RadarLink)>[]};
  for (final l in links) {
    if (idx.containsKey(l.from)) adj[l.from]!.add((l.to == camera ? -1 : idx[l.to]!, l));
    if (idx.containsKey(l.to)) adj[l.to]!.add((l.from == camera ? -1 : idx[l.from]!, l));
  }
  final uadj = {for (final p in phones) p: <(int, double)>[]};
  for (final e in inp.uwb.entries) {
    final ab = e.key.split('|');
    for (final (me, other) in [(ab[0], ab[1]), (ab[1], ab[0])]) {
      if (!idx.containsKey(me)) continue;
      if (other == camera) {
        uadj[me]!.add((-1, e.value));
      } else if (idx.containsKey(other)) {
        uadj[me]!.add((idx[other]!, e.value));
      }
    }
  }

  List<(List<int>, double)> search() {
    // Phones with the most readings first: the beam settles them early.
    final order = [...phones]..sort((a, b) => adj[b]!.length - adj[a]!.length);
    var states = <(List<int?>, double)>[(List<int?>.filled(phones.length, null), 0.0)];
    for (final d in order) {
      final di = idx[d]!;
      final next = <(List<int?>, double)>[];
      for (final (slotOf, cost) in states) {
        final used = {for (final s in slotOf) if (s != null) s};
        final options = pinned.containsKey(d)
            ? [pinned[d]!]
            : [for (final s in freeSlots) if (!used.contains(s) && !pinned.values.contains(s)) s];
        for (final s in options) {
          var c = cost;
          final me = lay.slots[s];
          for (final (o, l) in adj[d]!) {
            if (o >= 0 && slotOf[o] == null) continue; // not placed yet
            c += linkCost(l, me, o < 0 ? lay.camera : lay.slots[slotOf[o]!]);
          }
          for (final (o, m) in uadj[d]!) {
            if (o >= 0 && slotOf[o] == null) continue;
            c += model.uwbCost(m - dist(me, o < 0 ? lay.camera : lay.slots[slotOf[o]!]));
          }
          next.add(([...slotOf]..[di] = s, c));
        }
      }
      next.sort((a, b) => a.$2.compareTo(b.$2));
      states = next.length > beam ? next.sublist(0, beam) : next;
    }
    return [for (final (so, c) in states) ([for (final s in so) s!], c)];
  }

  var result = search();
  // Two refits of the level and the biases (shrunk: a phone with few
  // links keeps a bias near 0), then the final search.
  for (var round = 0; round < 2 && result.isNotEmpty; round++) {
    final best = result.first.$1;
    final res = <String, List<double>>{};
    final all = <double>[];
    for (final l in links) {
      final r = l.rssi - (bias[l.from] ?? 0) - (bias[l.to] ?? 0) - model.shape(dist(posOf(l.from, best), posOf(l.to, best)));
      all.add(r);
    }
    all.sort();
    level = all[all.length ~/ 2];
    for (final l in links) {
      final r = l.rssi - level - model.shape(dist(posOf(l.from, best), posOf(l.to, best)));
      (res[l.from] ??= []).add(r / 2);
      (res[l.to] ??= []).add(r / 2);
    }
    for (final e in res.entries) {
      final k = e.value.length;
      final m = e.value.reduce((a, b) => a + b) / k;
      bias[e.key] = m * k / (k + 4);
    }
    result = search();
  }

  final probs = {for (final p in phones) p: List<double>.filled(cfg.seats, 0)};
  if (result.isNotEmpty) {
    final best = result.first.$2;
    var z = 0.0;
    final ws = [for (final (_, c) in result) math.exp(-(c - best) / temperature)];
    for (final x in ws) {
      z += x;
    }
    for (var i = 0; i < result.length; i++) {
      for (var k = 0; k < phones.length; k++) {
        probs[phones[k]]![result[i].$1[k]] += ws[i] / z;
      }
    }
  }
  return RadarEstimate(lay, probs,
      organizerSlot: pinned.isEmpty ? org : null,
      linksUsed: links.length,
      joint: result.isEmpty ? const {} : {for (var k = 0; k < phones.length; k++) phones[k]: result.first.$1[k]});
}

// ----------------------------------------------------- offline fallback

/// Organizer phone without the cloud: only what it heard itself. Distance
/// from this phone per peer (metres, inverted from [model] with level -60),
/// strongest first. Not seats: rings on the display.
List<(String, double, double)> distancesFromMe(Map<String, double> rssiByPeer,
    {RadioModel model = const RadioModel(), double level = -60}) {
  double inv(double rssi) {
    // shape() is monotonic: bisect.
    var lo = 0.3, hi = 12.0;
    for (var i = 0; i < 40; i++) {
      final mid = (lo + hi) / 2;
      if (level + model.shape(mid) > rssi) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  return [for (final e in rssiByPeer.entries) (e.key, e.value, inv(e.value))]..sort((a, b) => b.$2.compareTo(a.$2));
}
