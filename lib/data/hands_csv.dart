/// CSV export of logged home-game hands, for spreadsheets.
library;

import '../homegame/home_game.dart';
import '../poker/cards.dart';

const handsCsvHeader = [
  'night',
  'night_date',
  'hand',
  'position',
  'dealer',
  'cards',
  'action',
  'facing',
  'board',
  'tag',
  'timestamp',
];

/// One row per logged hand, oldest night first. Times are local ISO-8601.
String homeHandsCsv(List<HomeSession> sessions) {
  final rows = <List<String>>[handsCsvHeader];
  for (final s in sessions) {
    final date = _date(DateTime.fromMillisecondsSinceEpoch(s.started));
    for (final h in s.hands) {
      rows.add([
        s.name,
        date,
        '${h.number}',
        h.position,
        h.dealer ?? '',
        h.cards == null ? '' : h.cards!.map(cardToString).join(' '),
        h.action == null ? '' : preActionLabels[h.action]!,
        switch (h.facing) {
          Facing.unopened => 'Unopened',
          Facing.raised => 'Raised',
          null => '',
        },
        h.board == null ? '' : h.board!.map(cardToString).join(' '),
        h.tag == null ? '' : storyTagLabels[h.tag]!,
        _iso(DateTime.fromMillisecondsSinceEpoch(h.ts)),
      ]);
    }
  }
  return '${rows.map((r) => r.map(csvField).join(',')).join('\r\n')}\r\n';
}

/// One RFC 4180 field: quoted when it holds a comma, quote or line break
/// (quotes doubled). Text a spreadsheet would run as a formula (=, +, -, @
/// at the start, e.g. a player named "=HYPERLINK(...)") gets a leading
/// apostrophe so it stays text.
String csvField(String v) {
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp('[",\r\n]'))) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

/// "felt-notes-hands-2026-10-27.csv".
String handsCsvFileName(DateTime d) =>
    'felt-notes-hands-${_date(d)}.csv';

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _iso(DateTime d) =>
    '${_date(d)}T${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
