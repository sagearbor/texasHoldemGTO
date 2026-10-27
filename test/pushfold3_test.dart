import 'package:felt_notes/gto/coach.dart';
import 'package:felt_notes/gto/hand_class.dart';
import 'package:felt_notes/gto/spots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Spot> spots;
  late List<Spot> hu;
  setUpAll(() async {
    spots = await loadPushFold3Spots();
    hu = await loadPushFoldSpots();
  });

  Spot byId(String node, int stack) =>
      spots.firstWhere((s) => s.id == pushFold3Id(node, stack));
  final stacks = [for (var s = 5; s <= 20; s++) s];

  test('pushfold3.json loads: 6 decision nodes per stack, 5..20bb', () {
    expect(spots.length, stacks.length * pushFold3Nodes.length);
    for (final s in stacks) {
      for (final n in pushFold3Nodes) {
        final spot = byId(n.key, s);
        expect(spot.format, SpotFormat.pushFold3);
        expect(spot.group, 'Push/fold 3-handed ${s}bb');
        expect(spot.situation, startsWith('3-handed, ${s}bb.'));
        expect(spot.edge, hasLength(169));
      }
    }
  });

  test('strategy rows sum to 1 and are valid frequencies', () {
    for (final s in spots) {
      expect(s.strategy, hasLength(169));
      for (final row in s.strategy) {
        expect(row, hasLength(2));
        expect(row[0] + row[1], closeTo(1, 1e-9), reason: s.id);
        expect(row.every((f) => f >= 0 && f <= 1), isTrue, reason: s.id);
      }
    }
  });

  test('BTN jams wider at shorter stacks and tighter than HU SB', () {
    double btn(int s) => byId('btnJam', s).playPercent;
    expect(btn(5), greaterThan(btn(10)));
    expect(btn(10), greaterThan(btn(15)));
    expect(btn(15), greaterThan(btn(20)));
    for (final s in stacks) {
      // Allow small solver/MC noise between neighbouring stacks.
      if (s < 20) expect(btn(s), greaterThan(btn(s + 1) - 0.015), reason: '${s}bb');
      final huSb = hu.firstWhere((x) => x.id == 'pf-sb-$s').playPercent;
      expect(btn(s), lessThan(huSb), reason: '${s}bb');
    }
  });

  test('BB overcall is the tightest range (from 7bb; at 5-6bb SB call is)', () {
    for (final s in stacks) {
      final over = byId('bbOvercall', s).playPercent;
      for (final n in pushFold3Nodes) {
        if (n.key == 'bbOvercall') continue;
        // At 5-6bb the BB's price is so good that the SB's cold call vs the
        // BTN (with the BB still behind) is the tighter range.
        if (s < 7 && n.key == 'sbCallVsBtn') continue;
        expect(over, lessThan(byId(n.key, s).playPercent), reason: '${n.key} ${s}bb');
      }
    }
  });

  test('AA always jams / calls; 72o never calls at 15bb', () {
    final aa = HandClass.parse('AA'), sevenTwo = HandClass.parse('72o');
    for (final s in spots) {
      expect(s.freqs(aa)[0], greaterThanOrEqualTo(0.99), reason: s.id);
      expect(s.edge![aa.index], greaterThan(0), reason: s.id);
    }
    for (final n in pushFold3Nodes.where((n) => n.action == 'Call')) {
      final spot = byId(n.key, 15);
      expect(spot.freqs(sevenTwo)[0], lessThanOrEqualTo(0.01), reason: n.key);
      expect(spot.edge![sevenTwo.index], lessThan(0), reason: n.key);
    }
  });

  test('library includes 3-handed spots and coach covers them', () async {
    final lib = SpotLibrary(buildCashSpots(), hu, const [], spots);
    expect(lib.all.where((s) => s.format == SpotFormat.pushFold3).length,
        spots.length);
    expect(lib.byId(pushFold3Id('bbOvercall', 10)).hero, 'BB');
    for (final s in [byId('btnJam', 10), byId('bbOvercall', 12)]) {
      for (final h in allHandClasses) {
        expect(coachNotes(s, h, 0), isNotEmpty);
        expect(coachNotes(s, h, 1), isNotEmpty);
      }
    }
  });
}
