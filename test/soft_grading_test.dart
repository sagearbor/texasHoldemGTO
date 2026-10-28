import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/daily.dart';
import 'package:felt_notes/trainer/mistakes.dart';
import 'package:felt_notes/trainer/progress.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:felt_notes/ui/screens/review_sheet.dart';
import 'package:felt_notes/ui/theme.dart';
import 'package:felt_notes/ui/widgets/share_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hand-authored (non-solver) spots: borderline hands are softened into
/// mixes, never graded "Mistake", and never scored.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpotLibrary lib;
  final now = DateTime(2026, 10, 27, 20);

  setUpAll(() async {
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots());
  });

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<TrainerModel> make() async {
    final m = TrainerModel(lib, clock: () => now);
    await m.load();
    return m;
  }

  HandClass hc(String n) => HandClass.parse(n);

  test('the 15 hand-authored spots are exactly the limper and 3-bet groups',
      () {
    final authored = lib.all.where((s) => s.handAuthored).toList();
    expect(authored, hasLength(15));
    for (final s in lib.all) {
      expect(s.handAuthored,
          s.group == limperGroup || s.group == threeBetGroup, reason: s.id);
      expect(s.authoredStrategy != null, s.handAuthored, reason: s.id);
    }
  });

  test('86s SB vs one limper: folding is not a Mistake', () {
    final s = lib.byId('cash-limp1-SB');
    final h = hc('86s');
    // As authored: Complete 100%. Shown and graded: Complete 75%, Fold 25%.
    expect(s.authoredStrategy![h.index], [0, 1, 0]);
    expect(isClearCutAuthored(s.authoredStrategy!, h), isFalse);
    expect(s.freqs(h), [0, 0.75, 0.25]);
    final fold = s.passiveIndex;
    expect(gradeFor(s.freqs(h)[fold]), Grade.mixed);
    expect(gradeChoice(s, s.freqs(h)[fold]), Grade.mixed);
    expect(gradeChoice(s, s.freqs(h)[fold], beginner: true), Grade.mixed);
    expect(strategyLine(s, h), 'Complete 75% · Fold 25%');
  });

  test('86s SB vs limper: trainer records it as a non-miss', () async {
    final m = await make();
    final s = lib.byId('cash-limp1-SB');
    final a = m.record(s, hc('86s'), s.passiveIndex);
    expect(a.isMiss, isFalse);
    expect(m.gradeOf(a), isNot(Grade.mistake));
    await m.setDifficulty(Difficulty.beginner);
    expect(m.gradeOf(a), Grade.mixed);
  });

  test('SB vs limper coaching mentions the BB behind and position', () {
    for (final id in ['cash-limp1-SB', 'cash-limp2-SB']) {
      final s = lib.byId(id);
      for (final n in ['86s', 'K9o', '22', 'AA', '72o']) {
        for (var c = 0; c < s.actions.length; c++) {
          final text = coachNotes(s, hc(n), c).join(' ');
          expect(text, isNot(contains('always play')), reason: '$id $n');
        }
      }
      final text = coachNotes(s, hc('86s'), 1).join(' ');
      expect(text, contains('big blind still acts behind you and can raise'));
      expect(text, contains('out of position'));
      expect(coachNotes(s, hc('AA'), 0).join(' '), contains('out of position'));
    }
  });

  test('AA facing a limp is still graded right / wrong', () {
    for (final s in lib.cash.where((s) => s.group == limperGroup)) {
      final aa = hc('AA');
      expect(isClearCutAuthored(s.authoredStrategy!, aa), isTrue, reason: s.id);
      expect(s.freqs(aa)[0], 1, reason: s.id);
      expect(gradeChoice(s, s.freqs(aa)[0]), Grade.correct, reason: s.id);
      expect(gradeChoice(s, s.freqs(aa)[s.passiveIndex]), Grade.mistake,
          reason: s.id);
      expect(gradeChoice(s, s.freqs(aa)[s.passiveIndex], beginner: true),
          Grade.mistake,
          reason: s.id);
    }
    // Trash still folds and is still a mistake to play.
    final co = lib.byId('cash-limp1-CO');
    expect(co.freqs(hc('72o')), [0, 0, 1]);
    expect(gradeChoice(co, co.freqs(hc('72o'))[0]), Grade.mistake);
    expect(isClearCutAuthored(co.authoredStrategy!, hc('32o')), isTrue);
  });

  test('rule: clear-cut rows kept, every other row at most 75/25', () {
    for (final s in lib.all.where((s) => s.handAuthored)) {
      for (final h in allHandClasses) {
        if ((s.reach?[h.index] ?? 1) == 0) continue;
        final raw = s.authoredStrategy![h.index], f = s.freqs(h);
        expect(f.fold<double>(0, (a, b) => a + b), closeTo(1, 1e-9));
        if (isClearCutAuthored(s.authoredStrategy!, h)) {
          expect(f, raw, reason: '${s.id} ${h.name}');
          continue;
        }
        final sorted = [...f]..sort();
        expect(sorted.last, lessThanOrEqualTo(0.75 + 1e-9),
            reason: '${s.id} ${h.name}');
        // The runner-up is a "mixed" (fine) choice, never a mistake.
        expect(gradeFor(sorted[sorted.length - 2]), Grade.mixed,
            reason: '${s.id} ${h.name}');
      }
    }
    // Solver-backed spots are untouched.
    for (final s in lib.all.where((s) => !s.handAuthored)) {
      expect(s.authoredStrategy, isNull);
    }
  });

  test('hand-authored spots are excluded from every score', () async {
    final m = await make();
    final limp = lib.byId('cash-limp1-CO');
    final rfi = lib.byId('cash-rfi-UTG');
    // Two misses in a hand-authored spot (AA folded), one right RFI answer.
    m.record(limp, hc('AA'), limp.passiveIndex);
    m.record(limp, hc('AA'), limp.passiveIndex);
    m.record(rfi, hc('AA'), 0);
    expect(m.history, hasLength(3));
    expect(m.scoredHistory.map((a) => a.spotId), [rfi.id]);
    expect(m.accuracy(m.scoredHistory), 1);
    // Report card / GTO grade.
    final r = TrainerReport.from(m, now: now);
    expect(r.drilled, 3);
    expect(r.accuracy, 1);
    expect(r.last7, 1);
    // Progress chart.
    final b = bucketAnswers(m.scoredHistory, now, byDay: true);
    expect(b.last.count, 1);
    expect(b.last.accuracy, 1);
    // Stats by hand / spot and the teachable list.
    expect(m.byHand()[hc('AA').index], (1, 0));
    expect(m.bySpot().keys, [rfi.id]);
    expect(m.teachable(), isEmpty);
    // Mistake heatmap leak bands.
    final ms = now.millisecondsSinceEpoch;
    expect(cellScores(m.scoredHistory, {limp.id}, ms), isEmpty);
    expect(weakTargets(m.scoredHistory, {limp.id}, ms), isEmpty);
    // Still drillable: the spaced-repetition deck keeps the miss.
    expect(m.deck.cards.containsKey('${limp.id}:${hc('AA').index}'), isTrue);
  });

  test('Daily 10 unchanged (golden) and free of hand-authored spots', () {
    String sig(DateTime d) => [
          for (final x in dailySet(lib, d)) '${x.spot.id}/${x.cards.join(',')}'
        ].join(' ');
    expect(
        sig(DateTime(2026, 10, 27)),
        'cash-rfi-SB/29,17 cash-BB-vs-CO/20,18 cash-BB-vs-HJ/11,4 '
        'cash-CO-vs-HJ/28,25 pf-sb-15/38,14 pf-bb-19/29,30 '
        'cash-SB-vs-BTN/17,1 pf-sb-8/47,5 pf-sb-16/17,18 '
        'cash-BTN-vs-CO/18,14');
    for (var d = 0; d < 60; d++) {
      for (final x in dailySet(lib, DateTime(2026, 11, 1 + d))) {
        expect(x.spot.handAuthored, isFalse);
      }
    }
  });

  Widget wrap(Widget w) => MaterialApp(
      theme: Felt.dark(), home: Scaffold(body: SingleChildScrollView(child: w)));

  testWidgets('coach sheet: approximate chip and no Mistake for 86s fold',
      (tester) async {
    final s = lib.byId('cash-limp1-SB');
    await tester.pumpWidget(wrap(CoachPanel(
        spot: s, hand: hc('86s'), chosen: s.passiveIndex, showGrid: false)));
    expect(find.byKey(const Key('approximate-chip')), findsOneWidget);
    expect(find.text(approximateLabel), findsOneWidget);
    expect(find.textContaining('Fine: mixed spot'), findsOneWidget);
    expect(find.textContaining('Mistake'), findsNothing);

    await tester.pumpWidget(wrap(CoachPanel(
        spot: lib.byId('cash-rfi-UTG'),
        hand: hc('AA'),
        chosen: 0,
        showGrid: false)));
    expect(find.byKey(const Key('approximate-chip')), findsNothing);
  });
}
