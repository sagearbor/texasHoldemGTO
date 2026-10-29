/// A long-lived background isolate that runs the glyph reader for Watch my
/// cards. The CNN is parsed once (compute() would re-send and re-parse it
/// for every frame), and crops travel as TransferableTypedData (no copy).
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'glyph_cnn.dart';
import 'glyph_reader.dart';

class GlyphWorker {
  final ReceivePort _recv = ReceivePort();
  Isolate? _isolate;
  SendPort? _send;
  final _ready = Completer<void>();
  final _pending = <int, Completer<GlyphReadResult>>{};
  var _nextId = 0;

  GlyphWorker._();

  static Future<GlyphWorker> spawn(Uint8List cnnBytes) async {
    final w = GlyphWorker._();
    w._recv.listen(w._onMessage);
    w._isolate = await Isolate.spawn(_main, (w._recv.sendPort, TransferableTypedData.fromList([cnnBytes])));
    await w._ready.future;
    return w;
  }

  void _onMessage(dynamic m) {
    if (m is SendPort) {
      _send = m;
      if (!_ready.isCompleted) _ready.complete();
    } else if (m is (int, GlyphReadResult)) {
      _pending.remove(m.$1)?.complete(m.$2);
    } else if (m is (int, String)) {
      _pending.remove(m.$1)?.completeError(StateError(m.$2));
    }
  }

  Future<GlyphReadResult> read(Uint8List rgba, int width, int height, {bool tta = false, int? scaleShortSide, bool warmLight = true}) {
    final id = _nextId++;
    final c = Completer<GlyphReadResult>();
    _pending[id] = c;
    _send!.send((id, TransferableTypedData.fromList([rgba]), width, height, tta, scaleShortSide, warmLight));
    return c.future;
  }

  void dispose() {
    _recv.close();
    _isolate?.kill(priority: Isolate.immediate);
    for (final c in _pending.values) {
      c.completeError(StateError('worker stopped'));
    }
    _pending.clear();
  }

  static void _main((SendPort, TransferableTypedData) args) {
    final (out, cnnData) = args;
    final cnn = GlyphCnn.parse(cnnData.materialize().asUint8List());
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    inbox.listen((m) {
      final (id, data, w, h, tta, ref, warm) = m as (int, TransferableTypedData, int, int, bool, int?, bool);
      try {
        out.send((id, readGlyphs(data.materialize().asUint8List(), w, h, cnn: cnn, tta: tta, scaleShortSide: ref, warmLight: warm)));
      } catch (e) {
        out.send((id, '$e'));
      }
    });
  }
}
