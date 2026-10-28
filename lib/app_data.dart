/// App-wide models and the "Reset all data" action.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/backup.dart';
import 'homegame/blind_clock_controller.dart';
import 'homegame/home_game.dart';
import 'trainer/trainer_model.dart';
import 'ui/app_settings.dart';
import 'ui/chart_prefs.dart';

/// Makes the loaded models reachable from any route (it sits above the
/// Navigator via MaterialApp.builder), e.g. for the About screen's reset.
class AppScope extends InheritedWidget {
  /// Both null while the app is still loading.
  final TrainerModel? trainer;
  final HomeGameModel? home;

  const AppScope({
    super.key,
    this.trainer,
    this.home,
    required super.child,
  });

  static AppScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>();

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      trainer != oldWidget.trainer || home != oldWidget.home;
}

/// Wipes everything Felt Notes stores on this device (trainer history,
/// home-game nights, settings, the seen-welcome flag) and resets the
/// in-memory models so the app looks freshly installed.
Future<void> resetAllData({TrainerModel? trainer, HomeGameModel? home}) async {
  home?.clearAll();
  await trainer?.resetAll();
  AppSettings.resetMemory();
  ChartPrefs.colorBlind.value = false;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  } catch (_) {
    // Storage unavailable (private window etc.): nothing was stored anyway.
  }
}

/// Writes a backup into storage (see [importAll]) and reloads every
/// in-memory model from it. Throws [BackupFormatException] on a bad backup,
/// before anything is changed.
Future<BackupSummary> restoreBackup(
  Map<String, dynamic> backup, {
  bool merge = false,
  TrainerModel? trainer,
  HomeGameModel? home,
  BlindClockController? clock,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final summary = await importAll(backup, prefs, merge: merge);
  await Future.wait([
    if (trainer != null) trainer.reload(),
    if (home != null) home.reload(),
    (clock ?? BlindClockController.shared).reload(),
    ChartPrefs.load(),
    AppSettings.load(),
  ]);
  return summary;
}

/// Lets a pushed route (e.g. the leak test's "Drill my leaks") ask the
/// bottom-nav shell to switch tabs after it pops.
class TabRequests extends ChangeNotifier {
  int tab = 0;
  void go(int t) {
    tab = t;
    notifyListeners();
  }
}

final shellTabs = TabRequests();
