/// "Too dark to read cards": watches the mean brightness (luma, 0..255) of
/// the frames Watch gets and says so once per dark spell. Observes only:
/// the card reader is not touched.
///
/// [darkBelow] 40 is an estimate (a dim living room on a Pixel at 720p
/// gives a mean Y in the 20s to 30s; a lit table 70+), not yet calibrated
/// against the watch clips; the log's `warn: dark` lines carry the luma so
/// it can be tuned. Hysteresis: the spell ends above [darkBelow] + 12.
library;

enum DarkEvent { warn, clear }

class WatchDark {
  final double darkBelow;
  final int holdMs;
  WatchDark({this.darkBelow = 40, this.holdMs = 20000});

  int? _darkSince;
  bool warned = false;

  /// One brightness sample at [tMs]; returns an event when the warning
  /// starts (dark for [holdMs]) or ends (clearly brighter again).
  DarkEvent? sample(int tMs, double luma) {
    if (luma < darkBelow) {
      _darkSince ??= tMs;
      if (!warned && tMs - _darkSince! >= holdMs) {
        warned = true;
        return DarkEvent.warn;
      }
      return null;
    }
    if (luma >= darkBelow + 12) {
      _darkSince = null;
      if (warned) {
        warned = false;
        return DarkEvent.clear;
      }
    }
    return null;
  }

  void reset() {
    _darkSince = null;
    warned = false;
  }
}
