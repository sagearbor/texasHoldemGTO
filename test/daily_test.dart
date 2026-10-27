import 'dart:convert';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/daily_screen.dart';
import 'package:felt_notes/ui/screens/stats_screen.dart';
import 'package:felt_notes/ui/screens/train_screen.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotLibrary lib;
  late DateTime now;
  DateTime clock() => now;

  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
  });

  setUp(() {
    now = DateTime(2026, 10, 27, 20);
    SharedPreferences.setMockInitialValues({});
  });

  String sig(List<DailyDrill> s) =>
      [for (final d in s) '${d.spot.id}/${d.cards.join(',')}'].join(' ');

  test('DailyRng matches a fixed sequence (guards cross-platform drift)', () {
    final r = DailyRng(20261027);
    final a = [for (var i = 0; i < 5; i++) r.nextDouble()];
    final r2 = DailyRng(20261027);
    expect([for (var i = 0; i < 5; i++) r2.nextDouble()], a);
    expect(a.every((x) => x >= 0 && x < 1), isTrue);
    // mulberry32(1) first output, as computed by the reference JS version.
    expect(DailyRng(1).nextDouble(), closeTo(0.6270739405881613, 1e-12));
  });

  test('same set for the same date, different for the next date', () {
    final a = dailySet(lib, DateTime(2026, 10, 27, 8));
    final b = dailySet(lib, DateTime(2026, 10, 27, 23, 59));
    final c = dailySet(lib, DateTime(2026, 10, 28, 8));
    expect(a, hasLength(10));
    expect(sig(a), sig(b));
    expect(sig(a) == sig(c), isFalse);
    expect(a.map((d) => d.spot.id).toSet(), hasLength(10), reason: 'distinct');
    expect(a.where((d) => d.spot.format == SpotFormat.cash100), hasLength(6));
  });

  test('daily sets favour borderline hands', () {
    var edgy = 0, total = 0;
    for (var d = 0; d < 30; d++) {
      for (final x in dailySet(lib, DateTime(2026, 11, 1 + d))) {
        total++;
        if (edginess(x.spot, x.hand) >= 0.7) edgy++;
      }
    }
    expect(edgy / total, greaterThan(0.6));
  });

  test('day number and keys', () {
    expect(dayNumber(DateTime(2026, 10, 27, 1)), 1);
    expect(dayNumber(DateTime(2026, 11, 7, 23)), 12); // across DST change
    expect(dayKey(DateTime(2026, 3, 5)), 20260305);
  });

  test('share text is Wordle-style with the web URL', () {
    final t = shareText(DateTime(2026, 11, 7), 'GGYRGGGYGG');
    expect(
        t,
        'Felt Notes Daily #12 · 8/10 🟩🟩🟨🟥🟩🟩🟩🟨🟩🟩\n'
        'https://sagearbor.github.io/texasHoldemGTO/');
    expect(shareText(DateTime(2026, 10, 27), 'GGGGGGGGGY'),
        startsWith('Felt Notes Daily #1 · 9.5/10 '));
    expect(markFor(1), 'G');
    expect(markFor(0.5), 'Y');
    expect(markFor(0.1), 'R');
  });

  Future<DailyModel> make() async {
    final d = DailyModel(lib, clock: clock);
    await d.load();
    return d;
  }

  /// Plays today's ten, always taking the most frequent GTO action.
  void playAll(DailyModel d) {
    while (!d.done) {
      final x = d.currentDrill!;
      final f = x.spot.freqs(x.hand);
      var best = 0;
      for (var i = 1; i < f.length; i++) {
        if (f[i] > f[best]) best = i;
      }
      d.answer(best);
    }
  }

  test('one attempt per day; progress persists mid-challenge', () async {
    final d = await make();
    expect(d.started, isFalse);
    d.answer(0);
    d.answer(0);
    expect(d.answered, 2);
    await Future<void>.delayed(Duration.zero);
    final d2 = await make();
    expect(d2.answered, 2, reason: 'resumes, does not restart');
    playAll(d2);
    expect(d2.done, isTrue);
    expect(() => d2.answer(0), throwsStateError);
  });

  test('streak continues across consecutive days and breaks on a gap',
      () async {
    final d = await make();
    playAll(d);
    expect(d.streak, 1);
    now = now.add(const Duration(days: 1));
    expect(d.streak, 1, reason: 'still alive until today is missed');
    playAll(d);
    expect(d.streak, 2);
    now = now.add(const Duration(days: 1));
    playAll(d);
    expect((d.streak, d.bestStreak), (3, 3));

    now = now.add(const Duration(days: 2)); // skipped a day
    expect(d.streak, 0);
    playAll(d);
    expect((d.streak, d.bestStreak), (1, 3));

    // An unfinished day doesn't count.
    now = now.add(const Duration(days: 1));
    d.answer(0);
    expect(d.streak, 1);

    await Future<void>.delayed(Duration.zero);
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString('daily_v1')!) as Map;
    expect(saved['best'], 3);
    final d2 = await make();
    expect((d2.streak, d2.bestStreak, d2.answered), (1, 3, 1));
  });

  test('trainer model owns a daily sharing its clock', () async {
    final m = TrainerModel(lib, clock: clock);
    await m.load();
    expect(m.daily.number, 1);
    now = DateTime(2026, 11, 7, 12);
    expect(m.daily.number, 12);
  });

  testWidgets('Daily screen plays through to a copyable result',
      (tester) async {
    tester.view.physicalSize = const Size(1260, 2700);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final m = TrainerModel(lib, clock: clock);
    await tester.runAsync(m.load);
    await tester.pumpWidget(MaterialApp(
        theme: Felt.dark(), home: TrainScreen(model: m)));
    expect(find.text('Daily 10 · #1'), findsOneWidget);
    await tester.tap(find.text('Daily 10 · #1'));
    await tester.pumpAndSettle();
    for (var i = 0; i < dailyLength; i++) {
      final x = m.daily.currentDrill!;
      final btn = find.widgetWithText(FilledButton, x.spot.actions.last);
      await tester.ensureVisible(btn);
      await tester.pumpAndSettle();
      await tester.tap(btn);
      await tester.pumpAndSettle();
      final next =
          find.byIcon(i == dailyLength - 1 ? Icons.flag : Icons.arrow_forward);
      await tester.ensureVisible(next);
      await tester.pumpAndSettle();
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(m.daily.done, isTrue);
    expect(find.text('Copy result'), findsOneWidget);
    expect(m.history, hasLength(dailyLength));

    // New key: otherwise the old Navigator (with DailyScreen pushed) stays.
    await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        theme: Felt.light(),
        home: StatsScreen(model: m, onDrill: (_) {})));
    await tester.pumpAndSettle();
    expect(find.byType(DailyCalendar), findsOneWidget);
    expect(find.text('Due for review'), findsOneWidget);
  });
}
