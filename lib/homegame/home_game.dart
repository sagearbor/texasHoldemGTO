/// Home-game logging for one phone: you record your own hole cards and,
/// optionally, your preflop action. Seats are fixed, so your position is
/// derived from the dealer button, which moves one seat per hand.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';

enum PreAction { fold, call, raise }

enum Facing { unopened, raised }

const preActionLabels = {
  PreAction.fold: 'Fold',
  PreAction.call: 'Call / limp',
  PreAction.raise: 'Raise',
};

class LoggedHand {
  final int number;
  final List<int>? cards;
  final String position;
  final PreAction? action;
  final Facing? facing;
  final int ts;

  LoggedHand({
    required this.number,
    required this.cards,
    required this.position,
    this.action,
    this.facing,
    required this.ts,
  });

  HandClass? get hand =>
      cards == null ? null : HandClass.fromCards(cards![0], cards![1]);

  Map<String, dynamic> toJson() => {
        'n': number,
        'c': cards,
        'p': position,
        'a': action?.index,
        'f': facing?.index,
        't': ts,
      };

  static LoggedHand fromJson(Map<String, dynamic> j) => LoggedHand(
        number: j['n'] as int,
        cards: (j['c'] as List?)?.cast<int>(),
        position: j['p'] as String,
        action: j['a'] == null ? null : PreAction.values[j['a'] as int],
        facing: j['f'] == null ? null : Facing.values[j['f'] as int],
        ts: j['t'] as int,
      );
}

class HomeSession {
  final String id;
  final String name;
  final int started;
  final List<String> players;
  final int heroSeat;
  final int firstButtonSeat;
  final List<LoggedHand> hands;
  bool closed;

  HomeSession({
    required this.id,
    required this.name,
    required this.started,
    required this.players,
    required this.heroSeat,
    required this.firstButtonSeat,
    List<LoggedHand>? hands,
    this.closed = false,
  }) : hands = hands ?? [];

  int get tableSize => players.length;

  /// Button seat for hand number [n] (1-based).
  int buttonFor(int n) => (firstButtonSeat + n - 1) % tableSize;

  String positionFor(int n) =>
      positionName(tableSize, (heroSeat - buttonFor(n)) % tableSize);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'started': started,
        'players': players,
        'hero': heroSeat,
        'btn': firstButtonSeat,
        'hands': [for (final h in hands) h.toJson()],
        'closed': closed,
      };

  static HomeSession fromJson(Map<String, dynamic> j) => HomeSession(
        id: j['id'] as String,
        name: j['name'] as String,
        started: j['started'] as int,
        players: (j['players'] as List).cast<String>(),
        heroSeat: j['hero'] as int,
        firstButtonSeat: j['btn'] as int,
        hands: [
          for (final h in j['hands'] as List)
            LoggedHand.fromJson(h as Map<String, dynamic>)
        ],
        closed: j['closed'] as bool? ?? false,
      );
}

/// Position name for a seat [offset] seats clockwise of the button at a
/// table of [n] players. Heads-up the button is also the small blind.
String positionName(int n, int offset) {
  if (n == 2) return offset == 0 ? 'BTN/SB' : 'BB';
  if (offset == 0) return 'BTN';
  if (offset == 1) return 'SB';
  if (offset == 2) return 'BB';
  // First seat after the big blind is always UTG; the rest count back from
  // the button (CO, HJ, LJ), with UTG+k filling the middle at full ring.
  final utg = offset - 3;
  if (utg == 0) return 'UTG';
  final fromButton = n - offset;
  if (fromButton == 1) return 'CO';
  if (fromButton == 2) return 'HJ';
  if (fromButton == 3) return 'LJ';
  return 'UTG+$utg';
}

/// Maps any full-ring position onto the 6-max chart we have for it.
String chartPosition(String pos) => switch (pos) {
      'CO' || 'HJ' || 'BTN' || 'SB' || 'BB' => pos,
      _ => 'UTG',
    };

class SessionStats {
  final int dealt;
  final int recorded;
  final int vpip;
  final int pfr;
  final int premiums;
  final double avgStrength;
  final int graded;
  final double gtoScore;
  final List<(LoggedHand, Spot, double)> misses;

  SessionStats({
    required this.dealt,
    required this.recorded,
    required this.vpip,
    required this.pfr,
    required this.premiums,
    required this.avgStrength,
    required this.graded,
    required this.gtoScore,
    required this.misses,
  });

  double get vpipPct => recorded == 0 ? 0 : vpip / recorded;
  double get pfrPct => recorded == 0 ? 0 : pfr / recorded;

  /// Expected share of JJ+/AK: (4 pairs × 6 + 16) / 1326.
  static const premiumRate = 40 / 1326;

  String get style {
    if (recorded < 10) return 'Too early to tell';
    final v = vpipPct, p = pfrPct;
    if (v >= 0.45) return p >= 0.25 ? 'Maniac' : 'Calling Station';
    if (v >= 0.28) return p >= v * 0.6 ? 'Loose-Aggressive' : 'Loose-Passive';
    if (v >= 0.15) return p >= v * 0.6 ? 'Tight-Aggressive' : 'Tight-Passive';
    return 'Rock';
  }
}

SessionStats computeStats(Iterable<LoggedHand> hands, SpotLibrary lib) {
  var dealt = 0, recorded = 0, vpip = 0, pfr = 0, premiums = 0, graded = 0;
  var strength = 0.0, strengthN = 0, gto = 0.0;
  final misses = <(LoggedHand, Spot, double)>[];
  for (final h in hands) {
    final hc = h.hand;
    if (hc == null) continue;
    dealt++;
    if (lib.vsRandom.isNotEmpty) {
      strength += lib.vsRandom[hc.index];
      strengthN++;
    }
    final n = hc.name;
    if (const {'AA', 'KK', 'QQ', 'JJ', 'AKs', 'AKo'}.contains(n)) premiums++;
    final a = h.action;
    if (a == null) continue;
    // A BB check after limps isn't voluntary; we only count what was tapped.
    recorded++;
    if (a != PreAction.fold) vpip++;
    if (a == PreAction.raise) pfr++;
    if (h.facing == Facing.unopened && h.position != 'BB' && h.position != 'BTN/SB') {
      final spot = lib.byId('cash-rfi-${chartPosition(h.position)}');
      final f = spot.freqs(hc);
      // Limping isn't in the raise-or-fold charts: it scores 0.
      final freq = switch (a) {
        PreAction.raise => f[0],
        PreAction.fold => f[1],
        PreAction.call => 0.0,
      };
      graded++;
      gto += freq >= 0.25 ? 1 : 0;
      if (freq < 0.25) misses.add((h, spot, freq));
    }
  }
  return SessionStats(
    dealt: dealt,
    recorded: recorded,
    vpip: vpip,
    pfr: pfr,
    premiums: premiums,
    avgStrength: strengthN == 0 ? 0 : strength / strengthN,
    graded: graded,
    gtoScore: graded == 0 ? 0 : gto / graded,
    misses: misses,
  );
}

/// Action index in an RFI spot for a logged action, for coaching panels.
int rfiActionIndex(PreAction a) => a == PreAction.raise ? 0 : 1;

String describeGrade(double freq) => gradeLabels[gradeFor(freq)]!;

class HomeGameModel extends ChangeNotifier {
  static const _key = 'home_sessions_v1';
  final SpotLibrary library;
  final List<HomeSession> sessions = [];

  HomeGameModel(this.library);

  HomeSession? get active {
    for (final s in sessions.reversed) {
      if (!s.closed) return s;
    }
    return null;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        sessions.addAll([
          for (final j in jsonDecode(raw) as List)
            HomeSession.fromJson(j as Map<String, dynamic>)
        ]);
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _key, jsonEncode([for (final s in sessions) s.toJson()]));
    } catch (_) {}
  }

  void start({
    required String name,
    required List<String> players,
    required int heroSeat,
    required int buttonSeat,
  }) {
    for (final s in sessions) {
      s.closed = true;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    sessions.add(HomeSession(
      id: '$now',
      name: name,
      started: now,
      players: players,
      heroSeat: heroSeat,
      firstButtonSeat: buttonSeat,
    ));
    _save();
    notifyListeners();
  }

  void logHand({List<int>? cards, PreAction? action, Facing? facing}) {
    final s = active!;
    final n = s.hands.length + 1;
    s.hands.add(LoggedHand(
      number: n,
      cards: cards,
      position: s.positionFor(n),
      action: action,
      facing: facing,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    _save();
    notifyListeners();
  }

  void undo() {
    final s = active;
    if (s == null || s.hands.isEmpty) return;
    s.hands.removeLast();
    _save();
    notifyListeners();
  }

  /// The button moved more or less than once (misdeal, seat change): shift
  /// the remaining hands by [delta] seats.
  void nudgeButton(int delta) {
    final s = active;
    if (s == null) return;
    final idx = sessions.indexOf(s);
    sessions[idx] = HomeSession(
      id: s.id,
      name: s.name,
      started: s.started,
      players: s.players,
      heroSeat: s.heroSeat,
      firstButtonSeat: (s.firstButtonSeat + delta) % s.tableSize,
      hands: s.hands,
    );
    _save();
    notifyListeners();
  }

  void end() {
    active?.closed = true;
    _save();
    notifyListeners();
  }

  void delete(HomeSession s) {
    sessions.remove(s);
    _save();
    notifyListeners();
  }
}
