/// Watch my cards: is the reading pipeline actually running? With the
/// screen black, a camera that stopped sending frames or a card reader
/// that fails on every crop looks exactly like "no peeks yet". Pure Dart,
/// unit-tested in test/watch_health_test.dart; watch_screen.dart turns a
/// problem into a buzz, a line on the black screen and a log record.
library;

class WatchHealth {
  /// No camera frame for this long while watching: the stream stalled.
  final int stallMs;

  /// This many reader failures in a row: the reader is broken.
  final int readerFailures;

  WatchHealth({this.stallMs = 5000, this.readerFailures = 3});

  int? _lastFrameMs;
  int _failures = 0;
  String? _problem;

  /// The current problem (short, for the black screen), or null.
  String? get problem => _problem;

  /// Watching (re)started at [tMs]: frames are due from now on.
  void start(int tMs) {
    _lastFrameMs = tMs;
    _failures = 0;
    _problem = null;
  }

  /// A camera frame arrived. Clears a stall.
  void onFrame(int tMs) {
    _lastFrameMs = tMs;
    if (_problem == stalled) _problem = null;
  }

  /// A read finished. Clears a reader problem.
  void onReadOk() {
    _failures = 0;
    if (_problem == readerBroken) _problem = null;
  }

  /// A read failed; returns the new problem when this one made it a problem.
  String? onReadError() {
    _failures++;
    if (_failures == readerFailures) return _raise(readerBroken);
    return null;
  }

  /// Something failed outright (the camera would not start, an error from
  /// the camera plugin); returns the problem when it is new.
  String? onFailure(String what) => _raise(what);

  /// Periodic check; returns the problem when it is new.
  String? check(int tMs) {
    final last = _lastFrameMs;
    if (last != null && tMs - last >= stallMs) return _raise(stalled);
    return null;
  }

  String? _raise(String p) {
    if (_problem == p) return null;
    _problem = p;
    return p;
  }

  static const stalled = 'Camera stopped: no frames';
  static const readerBroken = 'Card reader failing';
}
