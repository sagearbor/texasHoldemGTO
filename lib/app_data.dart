/// App-wide models and the "Reset all data" action.
library;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'homegame/home_game.dart';
import 'trainer/trainer_model.dart';

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
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  } catch (_) {
    // Storage unavailable (private window etc.): nothing was stored anyway.
  }
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
