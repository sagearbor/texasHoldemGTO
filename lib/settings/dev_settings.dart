/// Settings → Advanced / Developer: a password unlocks it once, and it
/// stays unlocked on this phone. Behind it, switches a normal player never
/// sees:
///   * [cloudCards]: send my hole cards to the cloud (off by default; with
///     it off, hole cards never leave the phone, see lib/sync/cloud_logs.dart).
///   * [devBoard]: read the community cards with the camera (experimental).
///
/// The password is checked against a SHA-256 hash, so the plain text is not
/// in the source. It is a soft gate (anyone with the app can patch it out),
/// not security: it keeps testing switches away from players.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DevSettings {
  DevSettings._();

  static const unlockedKey = 'dev_unlocked_v1';
  static const cloudCardsKey = 'dev_cloud_cards_v1';
  static const boardKey = 'dev_board_v1';

  static const _passwordSha256 = '595f310cc9e0d0d7a8a9b96f8131948b4dc769a67024a17cf548634386cbd5e4';

  /// The developer password was entered on this phone.
  static final unlocked = ValueNotifier<bool>(false);

  /// Send my hole cards to the cloud (the TV and the night's recap), after
  /// the 20-minute hold. Only while [unlocked].
  static final cloudCards = ValueNotifier<bool>(false);

  /// Read the community cards with the camera (experimental).
  static final devBoard = ValueNotifier<bool>(false);

  /// Hole cards may go to the cloud: unlocked and switched on.
  static bool get cardsToCloud => unlocked.value && cloudCards.value;

  /// Board reading is on: unlocked and switched on.
  static bool get boardOn => unlocked.value && devBoard.value;

  static bool checkPassword(String s) => sha256.convert(utf8.encode(s.trim())).toString() == _passwordSha256;

  static Future<void> load() async {
    unlocked.value = false;
    cloudCards.value = false;
    devBoard.value = false;
    try {
      final p = await SharedPreferences.getInstance();
      unlocked.value = p.getBool(unlockedKey) ?? false;
      cloudCards.value = p.getBool(cloudCardsKey) ?? false;
      devBoard.value = p.getBool(boardKey) ?? false;
    } catch (_) {}
  }

  /// Unlocks (and remembers it) when [password] is right.
  static Future<bool> unlock(String password) async {
    if (!checkPassword(password)) return false;
    await _set(unlocked, unlockedKey, true);
    return true;
  }

  static Future<void> setCloudCards(bool v) => _set(cloudCards, cloudCardsKey, v);
  static Future<void> setBoard(bool v) => _set(devBoard, boardKey, v);

  static Future<void> _set(ValueNotifier<bool> n, String key, bool v) async {
    n.value = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(key, v);
    } catch (_) {}
  }
}
