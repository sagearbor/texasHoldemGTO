/// EXPERIMENTAL "Snap my cards" (Beta).
///
/// Takes one still photo with the system camera (image_picker), runs Google
/// ML Kit on-device text recognition on it, and hands the OCR words plus the
/// decoded pixels to the pure-Dart [readCards]. Nothing leaves the phone and
/// nothing costs money. The user always confirms (or fixes) the result; the
/// manual picker is never blocked.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../poker/cards.dart';
import '../ui/theme.dart';
import '../ui/widgets/playing_card.dart';
import 'card_reader.dart';

/// Only Android and iOS have ML Kit; hide the feature everywhere else.
bool get snapCardsSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Opens the camera flow. Returns two cards (either may be null when the
/// user wants to fill that slot by hand), or null when cancelled.
Future<List<int?>?> snapCards(BuildContext context) async {
  final XFile? shot;
  try {
    shot = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 2000,
      maxHeight: 2000,
      requestFullMetadata: false,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Camera unavailable ($e). Tap the cards to pick them.')));
    }
    return null;
  }
  if (shot == null || !context.mounted) return null;
  return Navigator.of(context).push<List<int?>>(
    MaterialPageRoute(builder: (_) => _SnapResultScreen(path: shot!.path)),
  );
}

/// Decodes the photo (EXIF orientation applied by the engine), saves the
/// exact pixels as PNG so ML Kit sees the same frame we sample colours from,
/// runs OCR and the card reader.
Future<CardReadResult> _analyse(String path) async {
  final bytes = await File(path).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    if (raw == null || png == null) return const CardReadResult([], []);
    final pngPath = '$path.snap.png';
    await File(pngPath).writeAsBytes(png.buffer.asUint8List(), flush: true);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final RecognizedText text;
    try {
      text = await recognizer.processImage(InputImage.fromFilePath(pngPath));
    } finally {
      await recognizer.close();
      File(pngPath).delete().ignore();
    }
    final tokens = <OcrToken>[
      for (final b in text.blocks)
        for (final l in b.lines)
          for (final e in l.elements)
            if (e.cornerPoints.length == 4)
              OcrToken(
                e.text,
                [for (final p in e.cornerPoints) Pt(p.x.toDouble(), p.y.toDouble())],
                lineText: l.text,
              ),
    ];
    final px = RgbaImage(image.width, image.height, raw.buffer.asUint8List());
    return readCards(tokens, px);
  } finally {
    image.dispose();
  }
}

class _SnapResultScreen extends StatefulWidget {
  final String path;
  const _SnapResultScreen({required this.path});

  @override
  State<_SnapResultScreen> createState() => _SnapResultScreenState();
}

class _SnapResultScreenState extends State<_SnapResultScreen> {
  late final Future<CardReadResult> _future = _analyse(widget.path);

  /// Rank + suit per slot (null = unknown).
  final List<int?> _rank = [null, null];
  final List<int?> _suit = [null, null];
  final List<double> _conf = [0, 0];
  bool _seeded = false;

  void _seed(CardReadResult r) {
    if (_seeded) return;
    _seeded = true;
    for (var i = 0; i < r.cards.length && i < 2; i++) {
      _rank[i] = r.cards[i].rank;
      _suit[i] = r.cards[i].suit;
      _conf[i] = r.cards[i].suitConfidence;
    }
  }

  int? _card(int i) => _rank[i] == null || _suit[i] == null ? null : makeCard(_rank[i]!, _suit[i]!);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Text('Snap my cards'),
          SizedBox(width: 8),
          BetaBadge(),
        ]),
      ),
      body: FutureBuilder<CardReadResult>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Reading the corners on your phone...'),
              ]),
            );
          }
          if (snap.hasError) {
            return _Message(
              'Could not read the photo (${snap.error}).',
              onManual: () => Navigator.pop(context, <int?>[null, null]),
            );
          }
          final r = snap.data!;
          _seed(r);
          if (r.isEmpty) {
            return _Message(
              'No card corners found. Try again with the top-left corners of both '
              'cards (the rank and suit) big, sharp and well lit.',
              onManual: () => Navigator.pop(context, <int?>[null, null]),
            );
          }
          final dup = _card(0) != null && _card(0) == _card(1);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(File(widget.path), height: 180, fit: BoxFit.cover),
              ),
              const SizedBox(height: 12),
              Text(
                  'Check the suits. Camera reading is a beta guess; fix anything '
                  'wrong here or tap a card later to use the picker.',
                  style: t.bodySmall),
              const SizedBox(height: 12),
              for (var i = 0; i < 2; i++) _slot(i),
              if (dup)
                Text('Both slots are the same card: change one suit.',
                    style: t.bodySmall?.copyWith(color: Colors.redAccent)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: dup ? null : () => Navigator.pop(context, <int?>[_card(0), _card(1)]),
                child: const Text('Use these'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, <int?>[null, null]),
                child: const Text('Enter by hand instead'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _slot(int i) {
    final t = Theme.of(context).textTheme;
    final unsure = _rank[i] != null && _conf[i] < 0.6;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(children: [
        PlayingCard(card: _card(i), width: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              _rank[i] == null
                  ? 'Card ${i + 1}: not found (pick it by hand)'
                  : 'Card ${i + 1}: rank ${rankChars[_rank[i]!] == 'T' ? '10' : rankChars[_rank[i]!]}'
                      '${unsure ? ' - suit unsure, tap the right one' : ''}',
              style: t.labelMedium?.copyWith(color: unsure ? Felt.mixed : null),
            ),
            const SizedBox(height: 4),
            if (_rank[i] != null)
              Wrap(spacing: 6, children: [
                for (final s in const [3, 2, 1, 0])
                  ChoiceChip(
                    label: Text(suitSymbols[s],
                        style: TextStyle(
                            fontSize: 18,
                            color: s == 1 || s == 2 ? const Color(0xFFD62839) : null)),
                    selected: _suit[i] == s,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() {
                      _suit[i] = s;
                      _conf[i] = 1;
                    }),
                  ),
              ]),
          ]),
        ),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback onManual;
  const _Message(this.text, {required this.onManual});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton(onPressed: onManual, child: const Text('Enter by hand')),
      ]),
    );
  }
}

/// Small gold "BETA" pill.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Felt.gold, borderRadius: BorderRadius.circular(6)),
      child: const Text('BETA',
          style: TextStyle(
              color: Colors.black, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
    );
  }
}
