import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../homegame/board_speech.dart';
import '../../homegame/home_game.dart';
import '../../poker/cards.dart';
import '../theme.dart';
import 'playing_card.dart';

/// Push-to-talk needs the phone's own speech engine: Android and iOS only.
/// (On the web, Chrome sends audio to a server, so the mic is hidden there.)
bool get boardMicSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The board caller's row under the current hand: the five board slots, a
/// hold-to-talk mic, "type it", a manual picker and undo. The board belongs
/// to the hand being played now and is saved with it when the hand is
/// logged.
class BoardRow extends StatefulWidget {
  final HomeGameModel model;
  final HomeSession session;

  /// Cards that can't be on the board (your hole cards, if entered).
  final List<int> dead;
  const BoardRow({super.key, required this.model, required this.session, this.dead = const []});

  @override
  State<BoardRow> createState() => _BoardRowState();
}

enum _MicState { idle, starting, listening, unavailable }

class _BoardRowState extends State<BoardRow> {
  final SpeechToText _speech = SpeechToText();
  bool _ready = false;
  bool _pressed = false;
  bool _applied = false;
  _MicState _mic = _MicState.idle;
  String _heard = '';

  /// Last outcome shown under the row ("Heard … → K♥ 7♠ 4♣", or why not).
  String? _message;
  bool _messageIsProblem = false;

  List<int> get board => widget.session.currentBoard;

  @override
  void dispose() {
    _speech.cancel();
    super.dispose();
  }

  void _apply(String text, {required bool spoken}) {
    final r = parseBoardSpeech(text, board: board, dead: widget.dead);
    setState(() {
      if (r.ok) {
        widget.model.setCurrentBoard(r.board);
        final unsure = r.confidence < 0.75 || r.remainder.isNotEmpty;
        _message = '${spoken ? 'Heard' : 'Read'} "$text" → '
            '${streetNames[r.street] ?? 'Board'} ${boardLabel(r.cards)}'
            '${unsure ? '  (check it: tap ✎ to fix)' : ''}';
        _messageIsProblem = unsure;
      } else {
        _message = '${r.problem}${text.isEmpty ? '' : ' (heard "$text")'}';
        _messageIsProblem = true;
      }
    });
  }

  Future<void> _down() async {
    _pressed = true;
    _applied = false;
    _heard = '';
    if (!_ready) {
      setState(() => _mic = _MicState.starting);
      try {
        _ready = await _speech.initialize(
          onError: (e) {
            if (!mounted) return;
            setState(() {
              _mic = _MicState.idle;
              if (!e.permanent) return;
              _message = e.errorMsg == 'error_language_not_supported'
                  ? 'This phone cannot recognise speech offline: type the board instead'
                  : (e.errorMsg == 'error_no_match' || e.errorMsg == 'error_speech_timeout')
                      ? 'Didn\'t catch that: hold the mic and say e.g. "flop king of hearts…"'
                      : 'Speech error (${e.errorMsg}): type the board instead';
              _messageIsProblem = true;
            });
          },
          onStatus: (s) {
            if (!mounted) return;
            if (s == SpeechToText.doneStatus || s == SpeechToText.notListeningStatus) {
              setState(() => _mic = _ready ? _MicState.idle : _MicState.unavailable);
              if (!_pressed) _finish();
            }
          },
        );
      } catch (_) {
        _ready = false;
      }
      if (!mounted) return;
      if (!_ready) {
        setState(() {
          _mic = _MicState.unavailable;
          _message = 'Speech recognition is off or not allowed: type the board instead';
          _messageIsProblem = true;
        });
        return;
      }
      // The permission prompt may have eaten the press: ask for a new one.
      if (!_pressed) {
        setState(() {
          _mic = _MicState.idle;
          _message = 'Ready: hold the mic while you call the cards';
          _messageIsProblem = false;
        });
        return;
      }
    }
    setState(() {
      _mic = _MicState.listening;
      _message = null;
    });
    await _speech.listen(
      onResult: (r) {
        if (!mounted) return;
        setState(() => _heard = r.recognizedWords);
        if (r.finalResult) _finish();
      },
      listenOptions: SpeechListenOptions(
        // iOS: on-device only (never Apple's servers). Android: prefer the
        // offline engine (EXTRA_PREFER_OFFLINE).
        onDevice: true,
        partialResults: true,
        cancelOnError: true,
        listenMode: ListenMode.dictation,
      ),
      listenFor: const Duration(seconds: 20),
      pauseFor: const Duration(seconds: 6),
    );
  }

  Future<void> _up() async {
    _pressed = false;
    if (_mic != _MicState.listening) return;
    await _speech.stop();
    // Final result normally follows stop(); fall back to the last partial.
    Timer(const Duration(milliseconds: 900), _finish);
  }

  void _finish() {
    if (_applied || !mounted || _pressed) return;
    _applied = true;
    final text = _heard.trim();
    setState(() => _mic = _MicState.idle);
    if (text.isEmpty) {
      setState(() {
        _message = 'Didn\'t catch that: hold the mic while you speak';
        _messageIsProblem = true;
      });
      return;
    }
    _apply(text, spoken: true);
  }

  Future<void> _type() async {
    final c = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Type the board'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
            hintText: board.isEmpty ? 'Kh 7s 4c  or  flop king hearts…' : 'Jd  or  turn jack of diamonds',
          ),
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Add')),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) _apply(text.trim(), spoken: false);
  }

  Future<void> _pick() async {
    final picked = await pickBoard(context, board, widget.dead);
    if (picked != null) {
      widget.model.setCurrentBoard(picked);
      setState(() => _message = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final listening = _mic == _MicState.listening;
    final next = board.length >= 5 ? null : streetForLength(board.length);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Text('Board', style: t.titleSmall),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                board.isEmpty
                    ? 'optional · call it for everyone'
                    : next == null
                        ? 'complete'
                        : 'next: ${streetNames[next]!.toLowerCase()}',
                style: t.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: 'Type the board',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.keyboard_outlined),
              onPressed: _type,
            ),
            IconButton(
              tooltip: 'Pick board cards',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_outlined),
              onPressed: _pick,
            ),
            IconButton(
              tooltip: 'Remove last board card',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.undo),
              onPressed: board.isEmpty
                  ? null
                  : () {
                      widget.model.undoBoardCard();
                      setState(() => _message = null);
                    },
            ),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(children: [
                  for (var i = 0; i < 5; i++) ...[
                    if (i == 3 || i == 4) const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: PlayingCard(
                        card: i < board.length ? board[i] : null,
                        width: 36,
                        onTap: _pick,
                      ),
                    ),
                  ],
                ]),
              ),
            ),
            if (boardMicSupported && _mic != _MicState.unavailable) ...[
              const SizedBox(width: 8),
              Column(mainAxisSize: MainAxisSize.min, children: [
                Listener(
                  onPointerDown: (_) => _down(),
                  onPointerUp: (_) => _up(),
                  onPointerCancel: (_) => _up(),
                  child: Semantics(
                    button: true,
                    label: 'Hold to call the board',
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: listening ? 64 : 56,
                      height: listening ? 64 : 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: listening ? Felt.gold : scheme.primaryContainer,
                        boxShadow: listening
                            ? [BoxShadow(color: Felt.gold.withOpacity(0.5), blurRadius: 14)]
                            : null,
                      ),
                      child: _mic == _MicState.starting
                          ? const Padding(
                              padding: EdgeInsets.all(18),
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : Icon(listening ? Icons.mic : Icons.mic_none,
                              color: listening ? Colors.black87 : scheme.onPrimaryContainer),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(listening ? 'Listening…' : 'Hold to talk', style: t.labelSmall),
              ]),
            ],
          ]),
          if (listening && _heard.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('"$_heard"', style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_message!,
                  style: t.bodySmall?.copyWith(color: _messageIsProblem ? Felt.mixed : null)),
            ),
          if (boardMicSupported && _mic != _MicState.unavailable)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Uses your phone\'s speech recognition · Felt Notes records nothing',
                  style: t.labelSmall?.copyWith(color: scheme.outline)),
            ),
        ]),
      ),
    );
  }
}

/// Manual board picker: tap up to five cards in board order. Starts from
/// [start]; [dead] cards (your hand) can't be picked.
Future<List<int>?> pickBoard(BuildContext context, List<int> start, List<int> dead) {
  return showModalBottomSheet<List<int>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final chosen = List<int>.of(start);
      return StatefulBuilder(builder: (ctx, setSheet) {
        final next = chosen.length >= 5 ? null : streetForLength(chosen.length);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(
                  next == null
                      ? 'Board complete'
                      : 'Tap the ${streetNames[next]!.toLowerCase()} card${next == Street.flop ? 's' : ''}',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 6),
              SizedBox(
                height: 50,
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < 5; i++)
                    Padding(
                      padding: EdgeInsets.only(left: i == 3 || i == 4 ? 8 : 2, right: 2),
                      child: PlayingCard(card: i < chosen.length ? chosen[i] : null, width: 32),
                    ),
                ]),
              ),
              const SizedBox(height: 8),
              for (var s = 3; s >= 0; s--)
                Row(children: [
                  for (var r = 12; r >= 0; r--)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(1.5),
                        child: _BoardPickCell(
                          card: makeCard(r, s),
                          selected: chosen.contains(makeCard(r, s)),
                          disabled: dead.contains(makeCard(r, s)),
                          onTap: () {
                            final c = makeCard(r, s);
                            setSheet(() {
                              if (chosen.contains(c)) {
                                chosen.remove(c);
                              } else if (chosen.length < 5) {
                                chosen.add(c);
                              }
                            });
                          },
                        ),
                      ),
                    ),
                ]),
              const SizedBox(height: 8),
              Row(children: [
                TextButton(
                  onPressed: chosen.isEmpty ? null : () => setSheet(chosen.clear),
                  child: const Text('Clear'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, chosen),
                  child: const Text('Done'),
                ),
              ]),
            ]),
          ),
        );
      });
    },
  );
}

class _BoardPickCell extends StatelessWidget {
  final int card;
  final bool selected, disabled;
  final VoidCallback onTap;
  const _BoardPickCell(
      {required this.card, required this.selected, required this.disabled, required this.onTap});

  static const _colors = [
    Color(0xFF1F7A3F),
    Color(0xFF2563EB),
    Color(0xFFD62839),
    Color(0xFF1B1B1B),
  ];

  @override
  Widget build(BuildContext context) {
    final color = disabled ? Colors.black26 : _colors[cardSuit(card)];
    return InkWell(
      onTap: disabled ? null : onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: selected ? Felt.gold : (disabled ? Colors.white54 : Colors.white),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text(rankChars[cardRank(card)],
              style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 14)),
          Text(suitSymbols[cardSuit(card)], style: TextStyle(color: color, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// "That was hand…": attach the cards (and optional action) you are
/// entering now to an earlier hand, picked by its board. Returns true when
/// something was attached.
Future<bool> showAttachSheet(
  BuildContext context,
  HomeGameModel model, {
  required List<int>? cards,
  required Facing facing,
}) async {
  final hands = model.handsWithBoards();
  final picked = await showModalBottomSheet<(int, PreAction?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      PreAction? action;
      return StatefulBuilder(builder: (ctx, setSheet) {
        final t = Theme.of(ctx).textTheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('That was hand…', style: t.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                    cards == null
                        ? 'Pick the hand by its board. Adds what you did to it.'
                        : 'Pick the hand by its board. Your ${boardLabel(cards)} go on that hand, '
                            'not the one being played now.',
                    style: t.bodySmall),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Wrap(spacing: 6, children: [
                  for (final a in PreAction.values)
                    ChoiceChip(
                      label: Text(preActionLabels[a]!),
                      selected: action == a,
                      visualDensity: VisualDensity.compact,
                      onSelected: (on) => setSheet(() => action = on ? a : null),
                    ),
                ]),
              ),
              Flexible(
                child: ListView(shrinkWrap: true, children: [
                  for (final h in hands)
                    ListTile(
                      dense: true,
                      title: Text('Hand ${h.number} · ${boardLabel(h.board!)}'),
                      subtitle: Text([
                        if (h.dealer != null) 'dealer ${h.dealer}',
                        if (h.cards != null) 'has ${boardLabel(h.cards!)}',
                        if (h.action != null) preActionLabels[h.action]!,
                      ].join(' · ')),
                      onTap: () => Navigator.pop(ctx, (h.number, action)),
                    ),
                ]),
              ),
            ]),
          ),
        );
      });
    },
  );
  if (picked == null) return false;
  final (number, action) = picked;
  if (cards == null && action == null) return false;
  return model.attachToHand(number, cards: cards, action: action, facing: facing);
}
