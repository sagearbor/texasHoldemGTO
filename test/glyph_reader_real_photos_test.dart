// Evaluates the pure-Dart glyph reader on the owner's real table photos.
//
// The photos are private and gitignored, so this test is skipped when the
// folder is absent (CI). Locally it prints a per-photo table vs labels.json
// and the runtime per photo in the Dart VM (JIT, flutter test).
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = '/Users/sagearbor/projects/githubs/texasHoldemGTO/camera_data/cards-2deals_TH';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final present = File('$_dir/labels.json').existsSync();

  test('glyph reader on real photos (>= 10/14 hero cards)', () async {
    final labels = jsonDecode(File('$_dir/labels.json').readAsStringSync()) as Map<String, dynamic>;
    final templates = GlyphTemplates.parse(File('assets/data/glyph_templates.bin').readAsBytesSync());
    final names = labels.keys.where((k) => k.endsWith('.jpg')).toList()..sort();
    var heroOk = 0, boardOk = 0, bothOk = 0;
    final rows = <String>[
      '| photo | pose | hero truth | hero read (score) | ok | board truth | board count | ms decode | ms read (resize/board/hero) |',
      '|---|---|---|---|---|---|---|---|---|',
    ];
    for (final name in names) {
      final lab = labels[name] as Map<String, dynamic>;
      final sw = Stopwatch()..start();
      final codec = await ui.instantiateImageCodec(File('$_dir/$name').readAsBytesSync());
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = frame.image.width, h = frame.image.height;
      frame.image.dispose();
      final tDecode = sw.elapsedMilliseconds;
      final r = readGlyphs(bd!.buffer.asUint8List(), w, h, templates);
      final truth = (lab['hero'] as List).cast<String>();
      final got = r.hero.map((c) => cardToString(c.card)).toList();
      final ok = truth.where(got.contains).length;
      heroOk += ok;
      if (ok == 2) bothOk++;
      final bt = lab['board_count'] as int;
      if (r.boardCount == bt) boardOk++;
      final t = r.timingMs;
      rows.add('| ${name.substring(13, 22)} | ${lab['hero_pose']} | ${truth.join(' ')} | '
          '${r.hero.isEmpty ? '-' : r.hero.join(', ')} | $ok/2 | $bt | ${r.boardCount} | $tDecode | '
          '${t['total']} (${t['resize']}/${t['board']}/${t['hero']}) |');
    }
    rows.add('');
    rows.add('hero cards right: $heroOk/14, photos with both right: $bothOk/7, '
        'board count exact: $boardOk/7');
    // ignore: avoid_print
    print(rows.join('\n'));
    expect(heroOk, greaterThanOrEqualTo(10));
  }, skip: present ? false : 'real photos not present ($_dir)', timeout: const Timeout(Duration(minutes: 5)));
}
