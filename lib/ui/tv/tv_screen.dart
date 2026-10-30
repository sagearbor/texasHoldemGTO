// The table TV: a read-only, big-type, dark page that follows a table
// night live. On the web app at /#/tv?c=CODE (a laptop, tablet or smart-TV
// browser, or a Chrome tab cast to the TV); in the app from "Show a table
// night on this screen". What it may show, and when: lib/sync/tv_board.dart.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../gto/coach.dart';
import '../../homegame/blind_clock.dart';
import '../../homegame/home_game.dart';
import '../../poker/cards.dart';
import '../../sync/event_log.dart';
import '../../sync/night_events.dart';
import '../../sync/night_merge.dart' show clockLabel;
import '../../sync/tv_board.dart';
import '../theme.dart';
import 'tv_controller.dart';

const _bg = Color(0xFF07110C);
const _panel = Color(0xFF10221A);
const _dim = Color(0xFF9FB3A8);

/// The web entry point (/#/tv): the code comes from the URL, else the last
/// one this browser showed, else it asks.
class TvApp extends StatelessWidget {
  final String? code;
  const TvApp({super.key, this.code});

  @override
  Widget build(BuildContext context) {
    // Every screen is a named route `/tv?c=CODE`, so the browser's address
    // keeps the code and a reload lands back on the same table.
    return MaterialApp(
      title: 'Felt Notes TV',
      debugShowCheckedModeBanner: false,
      theme: Felt.dark(),
      initialRoute: code == null ? '/tv' : '/tv?c=$code',
      onGenerateRoute: (settings) {
        final name = settings.name ?? '/tv';
        final q = name.indexOf('?');
        final c = q < 0 ? null : Uri.splitQueryString(name.substring(q + 1))['c'];
        return PageRouteBuilder<void>(
          settings: RouteSettings(name: c == null ? '/tv' : '/tv?c=$c'),
          pageBuilder: (_, __, ___) => _TvEntry(code: c),
        );
      },
      // A deep link is one route, not '/' then '/tv'.
      onGenerateInitialRoutes: (name) => [
        PageRouteBuilder<void>(
          settings: RouteSettings(name: name),
          pageBuilder: (_, __, ___) {
            final q = name.indexOf('?');
            return _TvEntry(code: q < 0 ? null : Uri.splitQueryString(name.substring(q + 1))['c']);
          },
        )
      ],
    );
  }
}

class _TvEntry extends StatefulWidget {
  final String? code;
  const _TvEntry({this.code});
  @override
  State<_TvEntry> createState() => _TvEntryState();
}

class _TvEntryState extends State<_TvEntry> {
  JoinTicket? _ticket;
  bool _loading = true;
  final _input = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    var t = widget.code == null ? null : ticketFromTvInput(widget.code!);
    if (t == null) {
      try {
        final store = await SharedPrefsStore.open();
        final last = store.get(lastTvCodeKey);
        if (last != null) t = JoinTicket.parse(last);
      } catch (_) {}
    }
    if (!mounted) return;
    if (t != null && widget.code == null) {
      // Remembered code: show it in the address too.
      Navigator.of(context).pushReplacementNamed('/tv?c=${t.code}');
      return;
    }
    setState(() {
      _ticket = t;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(backgroundColor: _bg, body: Center(child: CircularProgressIndicator()));
    final t = _ticket;
    if (t != null) {
      return TvScreen(ticket: t, onChangeCode: () => Navigator.of(context).pushReplacementNamed('/tv'));
    }
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Felt Notes TV',
                  style: TextStyle(color: Felt.gold, fontSize: 32, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text("Type tonight's table code. It is under the QR on the organizer's phone.",
                  style: TextStyle(color: _dim, fontSize: 16)),
              const SizedBox(height: 16),
              TextField(
                controller: _input,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                style: const TextStyle(fontSize: 22, color: Colors.white),
                decoration: const InputDecoration(hintText: 'ABCD2345-WXYZ6789'),
                onSubmitted: (_) => _go(),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _go, child: const Text('Show the table')),
              if (_error != null) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Felt.bad)),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _go() {
    final t = ticketFromTvInput(_input.text);
    if (t == null) return setState(() => _error = 'That is not a table code.');
    Navigator.of(context).pushReplacementNamed('/tv?c=${t.code}');
  }
}

class TvScreen extends StatefulWidget {
  final JoinTicket ticket;
  final VoidCallback? onChangeCode;

  /// Tests pass their own controller (fake cloud).
  final TvController? controller;
  const TvScreen({super.key, required this.ticket, this.onChangeCode, this.controller});

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> {
  late final TvController c = widget.controller ?? TvController(widget.ticket);
  Timer? _second;

  @override
  void initState() {
    super.initState();
    c.start();
    // The clock and "updated 12 s ago" tick every second.
    _second = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _second?.cancel();
    if (widget.controller == null) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Felt.darkOnly(Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 900;
            final s = wide ? (box.maxWidth / 1280).clamp(0.85, 2.2) : 1.0;
            return _TvBody(c: c, scale: s, wide: wide, onChangeCode: widget.onChangeCode);
          }),
        ),
      ),
    ));
  }
}

class _TvBody extends StatelessWidget {
  final TvController c;
  final double scale;
  final bool wide;
  final VoidCallback? onChangeCode;
  const _TvBody({required this.c, required this.scale, required this.wide, this.onChangeCode});

  TextStyle _t(double size, {Color color = Colors.white, FontWeight w = FontWeight.w500}) => TextStyle(
      color: color, fontSize: size * scale, fontWeight: w, fontFeatures: const [FontFeature.tabularFigures()]);

  @override
  Widget build(BuildContext context) {
    final b = c.board;
    final now = c.now();
    final organizer = c.ticket.organizerName.isNotEmpty ? c.ticket.organizerName : (b?.organizerName ?? '');
    final header = Wrap(
      spacing: 16 * scale,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(organizer.isEmpty ? 'Table night' : "$organizer's table", style: _t(30, color: Felt.gold, w: FontWeight.w800)),
        if (b != null)
          Text(
              b.ended
                  ? 'Night over · ${b.finished} hands'
                  : b.handNow == null
                      ? 'Waiting for the first hand'
                      : 'Hand ${b.handNow} · ${b.finished} played',
              style: _t(24, w: FontWeight.w700)),
        _StatusPill(c: c, scale: scale),
      ],
    );
    final clock = b?.clock == null ? null : _Clock(json: b!.clock!, now: now, scale: scale);
    final players = _Players(rows: b?.rows ?? const [], scale: scale);
    final hands = _Hands(board: b, now: now, scale: scale, delayMs: c.opts.cardDelayMs);
    final footer = Text(
      'Stats count finished hands. Cards show ${c.opts.cardDelayMs ~/ 60000} min after a hand ends. '
      'Sharing off = "private": nothing of theirs leaves their phone.',
      style: _t(13, color: _dim),
    );
    if (b == null) {
      return Padding(
        padding: EdgeInsets.all(24 * scale),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          header,
          const Spacer(),
          Center(child: Text(c.error == null ? 'Connecting…' : 'Waiting for the connection…', style: _t(24))),
          const Spacer(),
          if (onChangeCode != null) TextButton(onPressed: onChangeCode, child: const Text('Other table code')),
        ]),
      );
    }
    if (!wide) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        header,
        const SizedBox(height: 12),
        if (clock != null) ...[clock, const SizedBox(height: 12)],
        players,
        const SizedBox(height: 12),
        hands,
        const SizedBox(height: 12),
        footer,
      ]);
    }
    return Padding(
      padding: EdgeInsets.all(20 * scale),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: header),
          if (clock != null) SizedBox(width: 420 * scale, child: clock),
        ]),
        SizedBox(height: 16 * scale),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 11, child: SingleChildScrollView(child: players)),
            SizedBox(width: 20 * scale),
            Expanded(flex: 9, child: SingleChildScrollView(child: hands)),
          ]),
        ),
        SizedBox(height: 8 * scale),
        footer,
      ]),
    );
  }
}

/// Green "live · updated 12 s ago"; amber when the organizer's phone has
/// gone quiet (the TV keeps the last state); red when the TV lost the
/// connection.
class _StatusPill extends StatelessWidget {
  final TvController c;
  final double scale;
  const _StatusPill({required this.c, required this.scale});

  @override
  Widget build(BuildContext context) {
    final now = c.now();
    final b = c.board;
    final up = b?.latestUploadMs;
    final ago = up == null ? null : _ago(now - up);
    final (Color color, String text) = switch (c.link) {
      TvLink.connecting => (_dim, 'connecting…'),
      TvLink.failed => (Felt.bad, c.error ?? 'no cloud'),
      TvLink.offline => (Felt.bad, 'TV offline, retrying · showing the last update${ago == null ? '' : ' ($ago)'}'),
      TvLink.live when b != null && b.hasOrganizer && b.staleAt(now, opts: c.opts) =>
        (Felt.mixed, "organizer's phone quiet · last update ${ago ?? '–'}"),
      TvLink.live when b != null && !b.hasOrganizer => (Felt.mixed, "waiting for the organizer's phone"),
      TvLink.live => (Felt.good, 'live · updated ${ago ?? '–'}'),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 6 * scale),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 12 * scale, color: color),
        SizedBox(width: 8 * scale),
        Flexible(child: Text(text, style: TextStyle(color: color, fontSize: 16 * scale, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

String _ago(int ms) {
  final s = (ms / 1000).round();
  if (s < 5) return 'just now';
  if (s < 60) return '$s s ago';
  if (s < 3600) return '${s ~/ 60} min ago';
  return '${s ~/ 3600} h ago';
}

class _Clock extends StatelessWidget {
  final Map<String, Object?> json;
  final int now;
  final double scale;
  const _Clock({required this.json, required this.now, required this.scale});

  @override
  Widget build(BuildContext context) {
    BlindClock clock;
    try {
      clock = BlindClock.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (!clock.started && clock.mode == ClockMode.tournament) return const SizedBox.shrink();
    final p = clock.positionAt(now);
    final lvl = clock.schedule[p.index];
    final cash = clock.mode == ClockMode.cash;
    final next = clock.upcomingAt(now);
    return Container(
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        color: lvl.isBreak ? const Color(0xFF3A2F12) : _panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(lvl.isBreak ? 'Break' : (cash ? 'Blinds' : 'Level ${clock.levelNumber(p.index)}'),
                style: TextStyle(color: _dim, fontSize: 16 * scale)),
            Text(lvl.isBreak ? 'Break' : lvl.label,
                style: TextStyle(color: Colors.white, fontSize: 30 * scale, fontWeight: FontWeight.w800)),
            if (!cash && next != null)
              Text('Next: ${next.label}', style: TextStyle(color: _dim, fontSize: 15 * scale)),
          ]),
        ),
        if (!cash)
          Text(
            clock.paused ? 'Paused' : formatClock(p.remainingMs),
            style: TextStyle(
                color: clock.paused ? Felt.mixed : Felt.gold,
                fontSize: 44 * scale,
                fontWeight: FontWeight.w800,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
      ]),
    );
  }
}

class _Players extends StatelessWidget {
  final List<TvRow> rows;
  final double scale;
  const _Players({required this.rows, required this.scale});

  @override
  Widget build(BuildContext context) {
    TextStyle st(double s, {Color c = Colors.white, FontWeight w = FontWeight.w500}) =>
        TextStyle(color: c, fontSize: s * scale, fontWeight: w, fontFeatures: const [FontFeature.tabularFigures()]);
    if (rows.isEmpty) {
      return Text('No players yet. Phones appear once they have uploaded.', style: st(18, c: _dim));
    }
    Widget num(String v, String label) => SizedBox(
          width: 86 * scale,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(v, style: st(24, w: FontWeight.w700)),
            Text(label, style: st(12, c: _dim)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in rows)
        Container(
          margin: EdgeInsets.only(bottom: 8 * scale),
          padding: EdgeInsets.symmetric(horizontal: 14 * scale, vertical: 10 * scale),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(r.name, style: st(24, w: FontWeight.w700), overflow: TextOverflow.ellipsis),
                Text(
                  switch (r.status) {
                    TvStatus.private => 'private · sharing off',
                    TvStatus.noPhone => 'no phone at the table',
                    TvStatus.left => 'left · ${r.style}',
                    TvStatus.sharing => r.recent.isEmpty ? r.style : '${r.style} · ${r.recent.join(', ')}',
                  },
                  style: st(15, c: r.status == TvStatus.private ? Felt.mixed : _dim),
                  overflow: TextOverflow.ellipsis,
                ),
              ]),
            ),
            if (r.status == TvStatus.private)
              Icon(Icons.lock_outline, color: Felt.mixed, size: 28 * scale)
            else if (r.hasStats) ...[
              num('${r.hands}', 'hands'),
              num(r.hands == 0 ? '–' : pct(r.vpipPct), 'VPIP'),
              num(r.hands == 0 ? '–' : pct(r.pfrPct), 'PFR'),
            ],
          ]),
        ),
    ]);
  }
}

class _Hands extends StatelessWidget {
  final TvBoard? board;
  final int now;
  final double scale;
  final int delayMs;
  const _Hands({required this.board, required this.now, required this.scale, required this.delayMs});

  @override
  Widget build(BuildContext context) {
    TextStyle st(double s, {Color c = Colors.white, FontWeight w = FontWeight.w500}) =>
        TextStyle(color: c, fontSize: s * scale, fontWeight: w);
    final b = board;
    if (b == null) return const SizedBox.shrink();
    String act(PreAction a) => a == PreAction.raise ? 'raised' : 'called';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (b.drama.isNotEmpty) ...[
        Text('Big hands', style: st(20, c: Felt.gold, w: FontWeight.w800)),
        SizedBox(height: 6 * scale),
        for (final d in b.drama.take(4))
          Container(
            margin: EdgeInsets.only(bottom: 6 * scale),
            padding: EdgeInsets.all(10 * scale),
            decoration: BoxDecoration(
                color: const Color(0xFF3A2F12), borderRadius: BorderRadius.circular(10)),
            child: Text(d.text, style: st(19, w: FontWeight.w700)),
          ),
        SizedBox(height: 12 * scale),
      ],
      Text('Recent hands', style: st(20, c: Felt.gold, w: FontWeight.w800)),
      SizedBox(height: 6 * scale),
      if (b.recent.isEmpty) Text('None finished yet.', style: st(16, c: _dim)),
      for (final h in b.recent)
        Container(
          margin: EdgeInsets.only(bottom: 6 * scale),
          padding: EdgeInsets.all(10 * scale),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('#${h.n} · ${clockLabel(h.startMs)}${h.dealer == null ? '' : ' · dealer ${h.dealer}'}',
                style: st(14, c: _dim)),
            Text(
              h.plays.isEmpty
                  ? 'Folded to the blinds (or nobody tapped)'
                  : h.plays
                      .map((p) => '${p.name} ${act(p.action)}${p.cards == null ? '' : ' ${prettyCards(p.cards!)}'}')
                      .join(' · '),
              style: st(18, w: FontWeight.w600),
            ),
            if (h.board != null && h.board!.length >= 3)
              Text('Board ${prettyCards(h.board!)}', style: st(15, c: _dim)),
            if (!h.cardsOpen && h.plays.isNotEmpty)
              Text('Cards (if shared) show a few minutes after the hand.', style: st(13, c: _dim)),
          ]),
        ),
    ]);
  }
}
