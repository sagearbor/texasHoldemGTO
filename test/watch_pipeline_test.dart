
import 'package:felt_notes/camera/glyph_reader.dart';
import 'package:felt_notes/camera/watch_diagnostics.dart';
import 'package:felt_notes/camera/watch_frame.dart';
import 'package:felt_notes/camera/watch_log_store.dart';
import 'package:felt_notes/camera/watch_pipeline.dart';
import 'package:felt_notes/camera/watch_tracker.dart';
import 'package:felt_notes/camera/watch_voice.dart';
import 'package:felt_notes/poker/cards.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const w = 320, h = 180;

/// A dull "table" NV12 frame, optionally with a white "card" rectangle.
WatchFrame frame({bool card = false, int base = 70, int x0 = 120, int y0 = 60}) {
  final y = Uint8List(w * h)..fillRange(0, w * h, base);
  if (card) {
    for (var r = y0; r < y0 + 50; r++) {
      for (var c = x0; c < x0 + 36; c++) {
        y[r * w + c] = 220;
      }
    }
  }
  final uv = Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128);
  return WatchFrame(w, h, WatchPixelFormat.yuv420, [WatchPlane(y, w, 1), WatchPlane(uv, w, 2)]);
}

/// BGRA frame of one colour.
WatchFrame bgra(int b, int g, int r) {
  final px = Uint8List(4 * 4 * 4);
  for (var i = 0; i < 16; i++) {
    px.setAll(i * 4, [b, g, r, 255]);
  }
  return WatchFrame(4, 4, WatchPixelFormat.bgra8888, [WatchPlane(px, 16, 4)]);
}

GlyphReadResult read(String cards, {double score = 0.9}) => GlyphReadResult(
      hero: [for (final c in parseCards(cards)) GlyphCard(c, score, 1, confident: score >= glyphCnnConfidentScore)],
      reads: const [],
      boardCount: 0,
    );

void main() {
  group('WatchFrame', () {
    test('NV12 grey converts to grey RGBA, video range expanded', () {
      final f = frame(base: 126);
      final (rgba, cw, ch) = f.cropRgba(const PixRect(0, 0, 10, 10));
      expect((cw, ch), (10, 10));
      expect(rgba.sublist(0, 4), [126, 126, 126, 255]);
      final v = WatchFrame(w, h, WatchPixelFormat.yuv420, f.planes, videoRange: true);
      expect(v.cropRgba(const PixRect(0, 0, 2, 2)).$1[0], closeTo(128, 2));
      expect(v.lumaGrid(4, 4)[0], closeTo(128, 2));
    });

    test('3-plane Android layout with pixel stride 2', () {
      final y = Uint8List(4 * 4)..fillRange(0, 16, 100);
      // Interleaved VU memory seen through two planes, stride 2: red-ish.
      final u = Uint8List.fromList([90, 0, 90, 0, 90, 0, 90]);
      final v = Uint8List.fromList([200, 0, 200, 0, 200, 0, 200]);
      final f = WatchFrame(4, 4, WatchPixelFormat.yuv420, [WatchPlane(y, 4, 1), WatchPlane(u, 4, 2), WatchPlane(v, 4, 2)]);
      final px = f.cropRgba(const PixRect(0, 0, 4, 4)).$1;
      expect(px[0], greaterThan(px[2])); // R > B
    });

    test('BGRA order and luma', () {
      final f = bgra(10, 20, 200);
      expect(f.cropRgba(const PixRect(0, 0, 4, 4)).$1.sublist(0, 4), [200, 20, 10, 255]);
      expect(f.lumaGrid(2, 2)[0], closeTo(0.299 * 200 + 0.587 * 20 + 0.114 * 10, 3));
    });

    test('crop is shrunk to maxShort by an integer step', () {
      final (_, cw, ch) = frame().cropRgba(const PixRect(0, 0, 320, 180), maxShort: 90);
      expect((cw, ch), (160, 90));
    });
  });

  group('ChangeGate', () {
    test('static scene: nothing; a white card appearing: a crop around it', () {
      final g = ChangeGate(const WatchConfig(minCropFrac: 0.3));
      expect(g.update(frame(), 0).card, isNull); // learns the background
      expect(g.update(frame(), 200).card, isNull);
      final r = g.update(frame(card: true), 400);
      expect(r.card, isNotNull);
      final c = r.card!;
      expect(c.x0 <= 120 && c.x1 >= 156 && c.y0 <= 60 && c.y1 >= 110, isTrue, reason: '$c');
    });

    test('a darker object (a hand, a sleeve) changes but is not card-like', () {
      final g = ChangeGate(const WatchConfig());
      g.update(frame(base: 120), 0);
      final y = frame(base: 120);
      for (var r = 40; r < 120; r++) {
        y.planes[0].bytes.fillRange(r * w + 60, r * w + 140, 40);
      }
      final res = g.update(y, 200);
      expect(res.changed, greaterThan(0));
      expect(res.card, isNull);
    });

    test('auto-exposure (whole frame brighter) is not a change', () {
      final g = ChangeGate(const WatchConfig());
      g.update(frame(base: 70), 0);
      final r = g.update(frame(base: 100), 200);
      expect(r.changed, 0);
      expect(r.card, isNull);
    });

    test('the lights change / the phone moves: background re-learnt', () {
      final g = ChangeGate(const WatchConfig());
      g.update(frame(base: 70), 0);
      final f = frame(base: 70);
      // Half the frame much brighter, half much darker.
      for (var i = 0; i < w * h; i++) {
        f.planes[0].bytes[i] = (i ~/ w) < h ~/ 2 ? 200 : 10;
      }
      expect(g.update(f, 200).global, isTrue);
      expect(g.update(f, 400).changed, 0);
    });

    test('something that stays is absorbed into the background', () {
      final g = ChangeGate(const WatchConfig(absorbMs: 3000));
      g.update(frame(), 0);
      var t = 0;
      GateResult r = GateResult.none;
      for (; t <= 5000; t += 200) {
        r = g.update(frame(card: true), t);
      }
      expect(r.card, isNull);
    });
  });

  group('WatchPipeline', () {
    test('a short peek: burst, two agreeing reads, one decision, diagnostics', () {
      final p = WatchPipeline(const WatchConfig(minCropFrac: 0.3));
      final tracker = WatchHandTracker();
      final decisions = <WatchDecision>[];
      var t = 0;
      void step(bool card, {String reads = 'As Kd'}) {
        final job = p.onFrame(frame(card: card), t);
        if (job != null) {
          final pair = p.onRead(job, card ? read(reads) : read(''));
          if (pair != null) {
            final d = tracker.onRead(pair, t);
            p.noteDecision(d);
            decisions.add(d);
          }
        }
        t += 66; // 15 fps
      }

      for (var i = 0; i < 30; i++) {
        step(false);
      }
      expect(p.counts.gated, lessThan(p.counts.seen), reason: 'idle rate drops frames');
      // ~0.6 s peek.
      for (var i = 0; i < 9; i++) {
        step(true);
      }
      for (var i = 0; i < 40; i++) {
        step(false);
      }
      p.flush(t);
      expect(decisions.map((d) => d.toString()), ['fill A♠ K♦']);
      expect(p.peeks, hasLength(1));
      final pk = p.peeks.single;
      expect(pk.hit, isTrue);
      expect(pk.outcome, PeekOutcome.logged);
      expect(pk.agree, greaterThanOrEqualTo(2));
      expect(pk.msToConfident, lessThan(400));
      // After the agreed pair the reader rests for the rest of the peek.
      expect(pk.framesRead, lessThan(pk.framesCandidate));
      final s = WatchSessionSummary(t, p.counts, p.peeks);
      expect(s.hits, 1);
      expect(s.toJson()['framesPerMin'], isA<Map<String, Object?>>());
      expect(s.describe(), contains('hits 1, near-misses 0'));
    });

    test('a peek too short for two reads is a near-miss, nothing logged', () {
      final p = WatchPipeline(const WatchConfig(minCropFrac: 0.3));
      var t = 0;
      var pairs = 0;
      ReadJob? pending;
      for (var i = 0; i < 60; i++) {
        final card = i >= 20 && i < 23; // 0.2 s
        final job = p.onFrame(frame(card: card), t);
        // The reader is slow: each answer arrives one frame later, and only
        // the frames it was free for are read.
        if (pending != null) {
          if (p.onRead(pending, read('As Kd')) != null) pairs++;
          pending = null;
        }
        pending = job;
        t += 66;
      }
      p.flush(t);
      expect(pairs, 0);
      expect(p.peeks.single.nearMiss, isTrue);
      expect(p.peeks.single.agree, lessThan(2));
      expect(WatchSessionSummary(t, p.counts, p.peeks).nearMisses, 1);
    });

    test('unconfident reads never log', () {
      final p = WatchPipeline(const WatchConfig(minCropFrac: 0.3));
      var t = 0, pairs = 0;
      for (var i = 0; i < 40; i++) {
        final job = p.onFrame(frame(card: i >= 10 && i < 30), t);
        if (job != null && p.onRead(job, read('As Kd', score: 0.3)) != null) pairs++;
        t += 66;
      }
      p.flush(t);
      expect(pairs, 0);
      expect(p.peeks.single.miss, isTrue);
    });

    test('hands stay in view; cards going down splits hands (5 s apart)', () {
      final p = WatchPipeline(const WatchConfig(minCropFrac: 0.3, absorbMs: 60000));
      final tracker = WatchHandTracker();
      final log = <String>[];
      var t = 0;
      // The hand (a white blob) never leaves; what the reader sees changes.
      void run(int ms, String cards) {
        for (final end = t + ms; t < end; t += 33) {
          final job = p.onFrame(frame(card: true, x0: 120 + (t ~/ 33) % 3), t);
          if (job == null) continue;
          final pair = p.onRead(job, read(cards));
          if (pair == null) continue;
          final d = tracker.onRead(pair, t, episode: p.cardEpisode);
          p.noteDecision(d);
          if (d.action == WatchAction.newHand) p.resetVotes();
          if (d.action != WatchAction.confirm) log.add('$d');
        }
      }

      for (var i = 0; i < 10; i++) {
        p.onFrame(frame(), t);
        t += 33;
      }
      run(1500, '7c 2d');
      run(2000, ''); // put down, hand still there
      run(1500, 'Jh 6c');
      run(2000, ''); // (a resting hand is re-read every 1.5 s)
      run(1500, 'Jh 6c'); // re-peek, same cards: silent
      expect(log, ['fill 7♣ 2♦', 'newHand J♥ 6♣']);
      expect(p.cardEpisode, 3);
    });

    test('a white object with no cards: the reader backs off', () {
      final p = WatchPipeline(const WatchConfig(minCropFrac: 0.3, absorbMs: 60000));
      var t = 0;
      for (var i = 0; i < 100; i++) {
        final job = p.onFrame(frame(card: i >= 5), t);
        if (job != null) p.onRead(job, GlyphReadResult.empty);
        t += 66;
      }
      // ~6.3 s of card-like change at 15 fps = ~95 gated frames.
      expect(p.counts.candidate, greaterThan(80));
      expect(p.counts.read, lessThan(15));
    });
  });

  group('voice leak guard', () {
    test('current route (iOS, Android 13+): every output must be private', () {
      expect(voiceAllowed(['bluetooth_a2dp'], isCurrentRoute: true), isTrue);
      expect(voiceAllowed(['ble_headset'], isCurrentRoute: true), isTrue);
      expect(voiceAllowed(['headphones'], isCurrentRoute: true), isTrue);
      expect(voiceAllowed(['speaker'], isCurrentRoute: true), isFalse);
      expect(voiceAllowed(['earpiece'], isCurrentRoute: true), isFalse);
      expect(voiceAllowed(['other:AirPlay'], isCurrentRoute: true), isFalse);
      expect(voiceAllowed(['ble_broadcast'], isCurrentRoute: true), isFalse);
      expect(voiceAllowed(['ble_speaker'], isCurrentRoute: true), isFalse);
      // Earbuds plus the speaker (e.g. a duplicated route): would leak.
      expect(voiceAllowed(['bluetooth_a2dp', 'speaker'], isCurrentRoute: true), isFalse);
      // Earbuds dropped: nothing / speaker only.
      expect(voiceAllowed([], isCurrentRoute: true), isFalse);
    });

    test('Android < 13 device list: the speaker is always listed; a headset decides', () {
      expect(voiceAllowed(['speaker', 'earpiece'], isCurrentRoute: false), isFalse);
      expect(voiceAllowed(['speaker', 'earpiece', 'bluetooth_a2dp'], isCurrentRoute: false), isTrue);
      expect(voiceAllowed(['speaker', 'other:13'], isCurrentRoute: false), isFalse);
      expect(voiceAllowed([], isCurrentRoute: false), isFalse);
    });

    test('the route is asked before every utterance; silence on errors', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const ch = MethodChannel('felt_notes/audio_route');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      Object? reply = {'route': true, 'outputs': ['bluetooth_a2dp']};
      messenger.setMockMethodCallHandler(ch, (call) async {
        calls++;
        if (reply is Exception) throw reply;
        return reply;
      });
      final v = WatchVoice();
      expect(await v.routeIsPrivate(), isTrue);
      reply = {'route': true, 'outputs': ['speaker']};
      // say() checks again: the earbuds just dropped, so it stays silent.
      expect(await v.say('Ace of spades, king of diamonds'), isFalse);
      expect(v.state.value, VoiceState.paused);
      expect(calls, 2);
      reply = PlatformException(code: 'x');
      expect(await v.routeIsPrivate(), isFalse);
      messenger.setMockMethodCallHandler(ch, null);
    });
  });

  group('diagnostics log', () {
    String session(int i) => '{"type":"session","n":$i}';
    test('keeps the last N sessions', () {
      final lines = [
        for (var i = 0; i < 8; i++) ...[session(i), '{"type":"peek"}', '{"type":"summary"}']
      ];
      final kept = pruneWatchLog(lines, keep: 3);
      expect(kept.first, session(5));
      expect(kept, hasLength(9));
    });

    test('drops whole old sessions when too big', () {
      final big = 'x' * 1000;
      final lines = [
        for (var i = 0; i < 4; i++) ...[session(i), for (var k = 0; k < 10; k++) big]
      ];
      final kept = pruneWatchLog(lines, keep: 10, maxBytes: 25000);
      expect(kept.first, session(2));
    });

    test('a peek record is numbers and own cards only', () {
      final r = PeekRecord(1000, 800)
        ..confidentMs = 1300
        ..cards = parseCards('As Kd')
        ..outcome = PeekOutcome.logged;
      final j = r.toJson();
      expect(j['confidentMs'], 300);
      expect(j['detectLagMaxMs'], 200);
      expect(j['cards'], 'As Kd');
      expect(j.keys, isNot(contains('image')));
    });
  });
}
