import 'dart:math';

import 'package:felt_notes/gto/spots.dart';
import 'package:felt_notes/trainer/trainer_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('All-spots drills are balanced across formats', () async {
    SharedPreferences.setMockInitialValues({});
    final lib = await SpotLibrary.load();
    final m = TrainerModel(lib, rng: Random(7));
    await m.load();
    final counts = <SpotFormat, int>{};
    for (var i = 0; i < 2000; i++) {
      m.next();
      final f = m.current!.spot.format;
      counts[f] = (counts[f] ?? 0) + 1;
    }
    expect(counts[SpotFormat.cash100]! / 2000, closeTo(0.5, 0.05));
    expect(counts[SpotFormat.pushFold]! / 2000, closeTo(0.25, 0.05));
    expect(counts[SpotFormat.pushFold3]! / 2000, closeTo(0.25, 0.05));
  });
}
