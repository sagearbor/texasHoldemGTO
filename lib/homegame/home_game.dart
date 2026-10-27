/// Home-game logging for one phone: you record your own hole cards and,
/// optionally, your preflop action. The app tracks the dealer button (one
/// seat per logged hand) so it can predict your position; you can correct
/// the position or dealer on any hand, and add/remove players mid-game.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../gto/coach.dart';
import '../gto/hand_class.dart';
import '../gto/spots.dart';
import 'milestones.dart';

enum PreAction { fold, call, raise }

enum Facing { unopened, raised }

const preActionLabels = {
  PreAction.fold: 'Fold',
  PreAction.call: 'Call / limp',
  PreAction.raise: 'Raise',
};

/// Optional one-tap label for a memorable hand, added after it is logged.
enum StoryTag { badBeat, cooler, bluff, suckout, heroFold, bigPot }

const storyTagLabels = {
  StoryTag.badBeat: 'Bad beat',
  StoryTag.cooler: 'Cooler',
  StoryTag.bluff: 'Bluff got through',
  StoryTag.suckout: 'Suckout',
  StoryTag.heroFold: 'Hero fold',
  StoryTag.bigPot: 'Big pot',
};

/// Stored by name so reordering the enum never relabels old hands;
/// unknown names (from a newer app version) read as no tag.
StoryTag? storyTagFromName(Object? name) {
  for (final t in StoryTag.values) {
    if (t.name == name) return t;
  }
  return null;
}

class LoggedHand {
  final int number;
  final List<int>? cards;
  final String position;
  final String? dealer;
  final PreAction? action;
  final Facing? facing;
  final int ts;

  /// Story tag, set (or cleared) after the hand is logged.
  StoryTag? tag;

  LoggedHand({
    required this.number,
    required this.cards,
    required this.position,
    this.dealer,
    this.action,
    this.facing,
    required this.ts,
    this.tag,
  });

  HandClass? get hand =>
      cards == null ? null : HandClass.fromCards(cards![0], cards![1]);

  /// A hand where nothing was recorded at all.
  bool get skipped => cards == null && action == null;

  Map<String, dynamic> toJson() => {
        'n': number,
        'c': cards,
        'p': position,
        'd': dealer,
        'a': action?.index,
        'f': facing?.index,
        't': ts,
        if (tag != null) 'g': tag!.name,
      };

  static LoggedHand fromJson(Map<String, dynamic> j) => LoggedHand(
        number: j['n'] as int,
        cards: (j['c'] as List?)?.cast<int>(),
        position: j['p'] as String,
        dealer: j['d'] as String?,
        action: j['a'] == null ? null : PreAction.values[j['a'] as int],
        facing: j['f'] == null ? null : Facing.values[j['f'] as int],
        ts: j['t'] as int,
        tag: storyTagFromName(j['g']),
      );
}

class HomeSession {
  final String id;
  final String name;
  final int started;

  /// Current players in seat order, clockwise. Changes when people join/leave.
  final List<String> players;
  int heroSeat;

  /// Seat holding the dealer button for the next hand to be logged.
  int buttonSeat;
  final List<LoggedHand> hands;
  bool closed;

  /// Your own money for the night, if you chose to enter it. Nobody
  /// else's money is ever recorded.
  double? buyIn, cashOut;

  /// Net result when both numbers are in.
  double? get net => buyIn == null || cashOut == null ? null : cashOut! - buyIn!;

  HomeSession({
    required this.id,
    required this.name,
    required this.started,
    required this.players,
    required this.heroSeat,
    required this.buttonSeat,
    List<LoggedHand>? hands,
    this.closed = false,
    this.buyIn,
    this.cashOut,
  }) : hands = hands ?? [];

  int get tableSize => players.length;

  int get heroOffset => (heroSeat - buttonSeat) % tableSize;

  /// Your position for the next hand.
  String get position => positionName(tableSize, heroOffset);

  /// Every position at this table size, in acting order (UTG first, BB last).
  List<String> get positionsInOrder => [
        for (var o = 3; o < tableSize; o++) positionName(tableSize, o),
        if (tableSize > 2) ...[
          positionName(tableSize, 0),
          positionName(tableSize, 1),
        ] else
          positionName(tableSize, 0),
        positionName(tableSize, tableSize == 2 ? 1 : 2),
      ];

  /// Moves the button so that you are in [pos] this hand.
  void setPosition(String pos) {
    for (var o = 0; o < tableSize; o++) {
      if (positionName(tableSize, o) == pos) {
        buttonSeat = (heroSeat - o) % tableSize;
        return;
      }
    }
  }

  void addPlayer(String name, int atSeat) {
    final i = atSeat.clamp(0, tableSize);
    players.insert(i, name);
    if (i <= heroSeat) heroSeat++;
    if (i <= buttonSeat) buttonSeat++;
    buttonSeat %= tableSize;
  }

  /// Removes a player (never you). If they had the button, it passes to the
  /// next seat.
  void removePlayer(int seat) {
    if (seat == heroSeat || tableSize <= 2) return;
    players.removeAt(seat);
    if (seat < heroSeat) heroSeat--;
    if (seat < buttonSeat) buttonSeat--;
    buttonSeat %= tableSize;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'started': started,
        'players': players,
        'hero': heroSeat,
        'btnNext': buttonSeat,
        'hands': [for (final h in hands) h.toJson()],
        'closed': closed,
        if (buyIn != null) 'buyIn': buyIn,
        if (cashOut != null) 'cashOut': cashOut,
      };

  static HomeSession fromJson(Map<String, dynamic> j) {
    final players = (j['players'] as List).cast<String>();
    final hands = [
      for (final h in j['hands'] as List) LoggedHand.fromJson(h as Map<String, dynamic>)
    ];
    // v0.1.0 stored the first hand's button and derived the rest.
    final btn = j['btnNext'] as int? ??
        ((j['btn'] as int) + hands.length) % players.length;
    return HomeSession(
      id: j['id'] as String,
      name: j['name'] as String,
      started: j['started'] as int,
      players: List.of(players),
      heroSeat: j['hero'] as int,
      buttonSeat: btn,
      hands: hands,
      closed: j['closed'] as bool? ?? false,
      buyIn: (j['buyIn'] as num?)?.toDouble(),
      cashOut: (j['cashOut'] as num?)?.toDouble(),
    );
  }
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
  /// Hands logged in any way (including skips).
  final int logged;

  /// Hands with your cards entered.
  final int dealt;

  /// Hands with a preflop action recorded (VPIP/PFR denominator).
  final int recorded;
  final int vpip;
  final int pfr;
  final int premiums;
  final double avgStrength;
  final int graded;
  final double gtoScore;
  final List<(LoggedHand, Spot, double)> misses;

  SessionStats({
    required this.logged,
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

  /// Share of logged hands that have an action: below ~70% VPIP/PFR are
  /// biased towards the hands you chose to record.
  double get coverage => logged == 0 ? 0 : recorded / logged;

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
  var logged = 0, dealt = 0, recorded = 0, vpip = 0, pfr = 0, premiums = 0, graded = 0;
  var strength = 0.0, strengthN = 0, gto = 0.0;
  final misses = <(LoggedHand, Spot, double)>[];
  for (final h in hands) {
    logged++;
    final a = h.action;
    if (a != null) {
      recorded++;
      if (a != PreAction.fold) vpip++;
      if (a == PreAction.raise) pfr++;
    }
    final hc = h.hand;
    if (hc == null) continue;
    dealt++;
    if (lib.vsRandom.isNotEmpty) {
      strength += lib.vsRandom[hc.index];
      strengthN++;
    }
    if (const {'AA', 'KK', 'QQ', 'JJ', 'AKs', 'AKo'}.contains(hc.name)) premiums++;
    if (a != null &&
        h.facing == Facing.unopened &&
        h.position != 'BB' &&
        h.position != 'BTN/SB') {
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
    logged: logged,
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

/// Dashboard delay choices, in minutes (0 = instant).
const dashboardDelays = [0, 5, 15, 30, 60];

class HomeGameModel extends ChangeNotifier {
  static const _key = 'home_sessions_v1';
  static const _delayKey = 'dashboard_delay_min';
  static const _badgesKey = 'home_badges_seen';
  final SpotLibrary library;
  final List<HomeSession> sessions = [];

  /// Milestone ids already announced, so each "Badge unlocked" shows once.
  final Set<String> _seenBadges = {};

  /// The TV dashboard only shows hands logged at least this long ago, so
  /// nobody can read the hand that just finished off the screen.
  int dashboardDelayMinutes = 15;

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
      dashboardDelayMinutes = prefs.getInt(_delayKey) ?? 15;
      final seen = prefs.getStringList(_badgesKey);
      if (seen != null) {
        _seenBadges.addAll(seen);
      } else if (sessions.isNotEmpty) {
        // Upgrading with history: don't announce badges earned long ago.
        _seenBadges.addAll([
          for (final m in milestones(sessions, library))
            if (m.unlocked) m.id.name
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
      await prefs.setInt(_delayKey, dashboardDelayMinutes);
      await prefs.setStringList(_badgesKey, _seenBadges.toList());
    } catch (_) {}
  }

  void _changed() {
    _save();
    notifyListeners();
  }

  void setDelay(int minutes) {
    dashboardDelayMinutes = minutes;
    _changed();
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
      buttonSeat: buttonSeat,
    ));
    _changed();
  }

  /// Records the current hand, then passes the button one seat clockwise.
  void logHand({List<int>? cards, PreAction? action, Facing? facing}) {
    final s = active!;
    s.hands.add(LoggedHand(
      number: s.hands.length + 1,
      cards: cards,
      position: s.position,
      dealer: s.players[s.buttonSeat],
      action: action,
      facing: action == null ? null : facing,
      ts: DateTime.now().millisecondsSinceEpoch,
    ));
    s.buttonSeat = (s.buttonSeat + 1) % s.tableSize;
    _changed();
  }

  /// Removes the last hand and gives the button back to its dealer.
  void undo() {
    final s = active;
    if (s == null || s.hands.isEmpty) return;
    final last = s.hands.removeLast();
    final seat = last.dealer == null ? -1 : s.players.indexOf(last.dealer!);
    s.buttonSeat = seat >= 0 ? seat : (s.buttonSeat - 1) % s.tableSize;
    _changed();
  }

  void setPosition(String pos) {
    active?.setPosition(pos);
    _changed();
  }

  void setDealer(int seat) {
    active?.buttonSeat = seat;
    _changed();
  }

  void addPlayer(String name, int atSeat) {
    active?.addPlayer(name, atSeat);
    _changed();
  }

  void removePlayer(int seat) {
    active?.removePlayer(seat);
    _changed();
  }

  /// Milestones unlocked since the last call (each is returned only once).
  List<Milestone> claimNewBadges() {
    final fresh = [
      for (final m in milestones(sessions, library))
        if (m.unlocked && !_seenBadges.contains(m.id.name)) m
    ];
    if (fresh.isNotEmpty) {
      _seenBadges.addAll(fresh.map((m) => m.id.name));
      _save();
    }
    return fresh;
  }

  /// Sets or clears the story tag on a logged hand.
  void setTag(LoggedHand h, StoryTag? tag) {
    h.tag = tag;
    _changed();
  }

  /// Your own buy-in and cash-out for a night (null clears).
  void setResult(HomeSession s, {double? buyIn, double? cashOut}) {
    s.buyIn = buyIn;
    s.cashOut = cashOut;
    _changed();
  }

  void end() {
    active?.closed = true;
    _changed();
  }

  /// Forgets every game night and setting in memory (storage is wiped by
  /// resetAllData).
  void clearAll() {
    sessions.clear();
    dashboardDelayMinutes = 15;
    notifyListeners();
  }

  void delete(HomeSession s) {
    sessions.remove(s);
    _changed();
  }
}
