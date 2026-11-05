import 'package:felt_notes/camera/watch_screen.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/homegame/home_game.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:felt_notes/ui/dev_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Host implements WatchHost {
  @override
  final WatchHandTracker watchTracker = WatchHandTracker();
  @override
  int get watchHandNumber => 1;
  @override
  void watchSetCards(List<int> cards) {}
  @override
  bool watchNewHand(List<int> cards, {int? episode, int? scene}) => true;
  @override
  void watchNextHand() {}
  @override
  Future<void> watchFixCards(BuildContext context) async {}
  @override
  PreAction? watchPendingAction;
  @override
  void watchSetAction(PreAction? a) => watchPendingAction = a;
}

/// The logger's side of WatchHost, on a real game night (what the
/// logger's own pad does: setPending with no facing; Next hand closes the
/// hand with the cards in the slots).
class _ModelHost extends _Host {
  final HomeGameModel model;
  List<int>? cards;
  _ModelHost(this.model);
  @override
  PreAction? get watchPendingAction => model.active?.pendingAction;
  @override
  set watchPendingAction(PreAction? a) {}
  @override
  void watchSetAction(PreAction? a) => model.setPending(a);
  @override
  void watchSetCards(List<int> c) => cards = c;
  @override
  void watchNextHand() {
    model.nextHand(cards: cards);
    cards = null;
  }
}

void main() {
  late SpotLibrary lib;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    lib = SpotLibrary(buildCashSpots(), await loadPushFoldSpots(), await loadVsRandom());
  });

  testWidgets('setup screen: instructions, voice on by default, no camera in tests', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await WatchSettings.load();
    await tester.pumpWidget(MaterialApp(home: WatchScreen(host: _Host())));
    // The camera lookup fails (no plugin in tests); let it finish.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.text('Watch my cards'), findsOneWidget);
    expect(find.textContaining('Prop the phone up'), findsOneWidget);
    expect(find.textContaining('Camera unavailable'), findsOneWidget);
    expect(WatchSettings.voice.value, isTrue);
    await tester.scrollUntilVisible(find.text('Start watching'), 200);
    // No camera: Start stays disabled.
    final start = tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text('Start watching'), matching: find.bySubtype<ButtonStyleButton>()));
    expect(start.onPressed, isNull);
  });

  testWidgets('Camera entry: "Just one photo" returns to the logger for Snap', (tester) async {
    SharedPreferences.setMockInitialValues({});
    bool? got;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => got = await openWatchMode(context, _Host(), offerOnePhoto: true),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Watch my cards'), findsOneWidget);
    await tester.tap(find.byKey(const Key('watch-one-photo')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(got, isTrue);
    expect(find.text('Watch my cards'), findsNothing);
  });

  testWidgets('no "Just one photo" unless offered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await WatchSettings.load();
    await tester.pumpWidget(MaterialApp(home: WatchScreen(host: _Host())));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(find.byKey(const Key('watch-one-photo')), findsNothing);
  });

  testWidgets('setup: record switch off by default (developer mode off), wide shots under it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await DevMode.load();
    await WatchSettings.load();
    expect(WatchSettings.record.value, isFalse);
    expect(WatchSettings.wide.value, isTrue);
    await tester.pumpWidget(MaterialApp(home: WatchScreen(host: _Host())));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.scrollUntilVisible(find.byKey(const Key('watch-record')), 200);
    expect(find.byKey(const Key('watch-wide')), findsNothing);
    await tester.tap(find.byKey(const Key('watch-record')));
    await tester.pump();
    expect(WatchSettings.record.value, isTrue);
    expect(find.byKey(const Key('watch-wide')), findsOneWidget);
    expect(find.byKey(const Key('watch-recordings')), findsOneWidget);
  });

  testWidgets('record defaults on in developer mode', (tester) async {
    SharedPreferences.setMockInitialValues({DevMode.key: true});
    await DevMode.load();
    await WatchSettings.load();
    expect(WatchSettings.record.value, isTrue);
    SharedPreferences.setMockInitialValues({DevMode.key: true, WatchSettings.recordKey: false});
    await WatchSettings.load();
    expect(WatchSettings.record.value, isFalse);
    await DevMode.set(false);
  });

  testWidgets('black-screen action pad: call / raise / undo on the hand being played, no cards shown',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final m = HomeGameModel(lib);
    await tester.runAsync(m.load);
    m.start(name: 'x', players: ['me', 'b', 'c', 'd', 'e', 'f'], heroSeat: 0, buttonSeat: 0);
    final host = _ModelHost(m);
    // Watch read the cards of this hand.
    host.watchSetCards([parseCard('As'), parseCard('Kd')]);
    final actions = <PreAction?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: StatefulBuilder(
          builder: (context, setState) => Align(
            alignment: Alignment.bottomCenter,
            child: WatchActionArea(
              host: host,
              onAction: (a) => setState(() {
                actions.add(a);
                host.watchSetAction(a);
              }),
              onNext: () => setState(host.watchNextHand),
            ),
          ),
        ),
      ),
    ));
    final pad = find.byKey(const Key('watch-action-pad'));
    expect(find.text('NOT RECORDED'), findsOneWidget, reason: 'Watch: no tap is not a fold');
    expect(find.textContaining('hold = fold'), findsOneWidget);
    // Never the cards.
    expect(find.textContaining('A♠'), findsNothing);
    expect(find.textContaining('As'), findsNothing);

    await tester.tap(pad);
    await tester.pump();
    expect(m.active!.pendingAction, PreAction.call);
    expect(find.text('CALL / LIMP'), findsOneWidget);

    await tester.drag(pad, const Offset(0, -120));
    await tester.pump();
    expect(m.active!.pendingAction, PreAction.raise);

    await tester.drag(pad, const Offset(0, 120));
    await tester.pump();
    expect(m.active!.pendingAction, isNull);
    expect(find.text('NOT RECORDED'), findsOneWidget);

    await tester.longPress(pad);
    await tester.pump();
    expect(m.active!.pendingAction, PreAction.fold, reason: 'hold = explicit fold');
    await tester.drag(pad, const Offset(0, 120));
    await tester.pump();

    await tester.drag(pad, const Offset(0, -120));
    await tester.pump();
    expect(actions, [PreAction.call, PreAction.raise, null, PreAction.fold, null, PreAction.raise]);

    // Sideways: next hand. The raise lands on the hand with the read cards.
    await tester.drag(pad, const Offset(-150, 0));
    await tester.pump();
    final h = m.active!.hands.last;
    expect(h.action, PreAction.raise);
    expect(h.cards, [parseCard('As'), parseCard('Kd')]);
    expect(m.active!.pendingAction, isNull);
    expect(find.text('NOT RECORDED'), findsOneWidget);
  });
}
