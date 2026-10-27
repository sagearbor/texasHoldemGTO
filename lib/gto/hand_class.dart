/// The 169 starting-hand classes (AA, AKs, AKo, ...) laid out on the
/// standard 13×13 grid: row/col 0 = ace. Above the diagonal is suited,
/// below is offsuit, the diagonal is pairs.
library;

import '../poker/cards.dart';

class HandClass {
  /// Grid row and column, 0 = ace .. 12 = deuce.
  final int row, col;
  const HandClass(this.row, this.col);

  static HandClass byIndex(int i) => HandClass(i ~/ 13, i % 13);

  int get index => row * 13 + col;

  /// Rank (0 = deuce .. 12 = ace) of the higher / lower card.
  int get highRank => 12 - (row < col ? row : col);
  int get lowRank => 12 - (row < col ? col : row);

  bool get isPair => row == col;
  bool get isSuited => row < col;

  String get name {
    final h = rankChars[highRank], l = rankChars[lowRank];
    if (isPair) return '$h$l';
    return '$h$l${isSuited ? 's' : 'o'}';
  }

  /// 6 for pairs, 4 suited, 12 offsuit.
  int get comboCount => isPair ? 6 : (isSuited ? 4 : 12);

  List<List<int>> combos() {
    final out = <List<int>>[];
    for (var s1 = 0; s1 < 4; s1++) {
      for (var s2 = 0; s2 < 4; s2++) {
        if (isPair) {
          if (s2 <= s1) continue;
        } else if (isSuited ? s1 != s2 : s1 == s2) {
          continue;
        }
        out.add([makeCard(highRank, s1), makeCard(lowRank, s2)]);
      }
    }
    return out;
  }

  static HandClass fromCards(int a, int b) {
    var hi = cardRank(a), lo = cardRank(b);
    if (lo > hi) {
      final t = hi;
      hi = lo;
      lo = t;
    }
    final suited = cardSuit(a) == cardSuit(b);
    final rHi = 12 - hi, rLo = 12 - lo;
    if (hi == lo) return HandClass(rHi, rHi);
    return suited ? HandClass(rHi, rLo) : HandClass(rLo, rHi);
  }

  static HandClass parse(String s) {
    final hi = rankChars.indexOf(s[0].toUpperCase());
    final lo = rankChars.indexOf(s[1].toUpperCase());
    if (hi < 0 || lo < 0) throw FormatException('Bad hand: $s');
    final rHi = 12 - (hi > lo ? hi : lo), rLo = 12 - (hi > lo ? lo : hi);
    if (hi == lo) return HandClass(rHi, rHi);
    final suited = s.length > 2 && s[2].toLowerCase() == 's';
    return suited ? HandClass(rHi, rLo) : HandClass(rLo, rHi);
  }

  @override
  bool operator ==(Object other) => other is HandClass && other.index == index;
  @override
  int get hashCode => index;
  @override
  String toString() => name;
}

final allHandClasses = List<HandClass>.generate(169, HandClass.byIndex);
