/// EXPERIMENTAL "Snap my cards" (Beta).
///
/// Takes one still photo with the camera (or picks one from the gallery),
/// then reads the hole cards on the device:
///
///  1. the pure-Dart glyph reader ([readGlyphs]: classical corner-index
///     localiser + a tiny CNN, assets/data/glyph_cnn.bin) in a background
///     isolate. If it finds two confident cards, they are used.
///  2. otherwise, on Android / iOS, Google ML Kit text recognition on the
///     whole photo ([readCards]) fills in what the glyph reader missed.
///
/// The glyph reader also counts the face-up board cards; the street it
/// implies ("Board: flop") is shown as a hint only. Nothing leaves the
/// device and nothing costs money. The user always confirms (or fixes) the
/// result; the manual picker is never blocked.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../poker/cards.dart';
import '../ui/theme.dart';
import '../ui/widgets/playing_card.dart';
import 'card_reader.dart';
import 'glyph_reader.dart';

/// ML Kit exists only on Android and iOS.
bool get _mlKitSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// The glyph reader is pure Dart, so the feature also works on the web
/// (photo from the camera or a file via the browser's file picker).
bool get snapCardsSupported => kIsWeb || _mlKitSupported;

/// Opens the camera / photo flow. Returns two cards (either may be null when
/// the user wants to fill that slot by hand), or null when cancelled.
Future<List<int?>?> snapCards(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('Photograph your two cards: corners (rank and suit) big, sharp and well lit.'),
        ),
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Take a photo'),
          onTap: () => Navigator.pop(ctx, ImageSource.camera),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('Pick a photo'),
          onTap: () => Navigator.pop(ctx, ImageSource.gallery),
        ),
      ]),
    ),
  );
  if (source == null || !context.mounted) return null;
  final XFile? shot;
  try {
    shot = await ImagePicker().pickImage(
      source: source,
      // A 3000x4000 phone photo comes back as 1500x2000: the size the
      // glyph reader was tuned at.
      maxWidth: 2000,
      maxHeight: 2000,
      requestFullMetadata: false,
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Photo unavailable ($e). Tap the cards to pick them.')));
    }
    return null;
  }
  if (shot == null || !context.mounted) return null;
  final bytes = await shot.readAsBytes();
  if (!context.mounted) return null;
  return Navigator.of(context).push<List<int?>>(
    MaterialPageRoute(builder: (_) => _SnapResultScreen(path: shot!.path, bytes: bytes)),
  );
}

/// One proposed hole card for the review screen.
class _Seed {
  final int rank;
  final int? suit;
  final double conf;
  const _Seed(this.rank, this.suit, this.conf);
}

class _Outcome {
  final List<_Seed> cards;

  /// "flop" etc. from the board-card count, or null.
  final String? street;
  final int boardCount;

  /// Which reader produced the cards (shown small, for beta feedback).
  final String source;
  const _Outcome(this.cards, this.street, this.boardCount, this.source);
}

Uint8List? _cnnBytes;

Future<Uint8List> _loadCnn() async =>
    _cnnBytes ??= (await rootBundle.load('assets/data/glyph_cnn.bin')).buffer.asUint8List();

Future<_Outcome> _analyse(String path, Uint8List bytes) async {
  // Decode (EXIF orientation applied by the engine).
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return const _Outcome([], null, 0, 'none');
    final rgba = raw.buffer.asUint8List();
    GlyphReadResult glyph;
    try {
      final req = GlyphReadRequest(rgba, image.width, image.height, cnn: await _loadCnn());
      glyph = await compute(readGlyphsMessage, req);
    } catch (e) {
      debugPrint('glyph reader failed: $e');
      glyph = GlyphReadResult.empty;
    }
    final glyphSeeds = [
      for (final c in glyph.hero) _Seed(cardRank(c.card), cardSuit(c.card), c.confident ? 1.0 : 0.5)
    ];
    final street = glyph.street;
    if (glyph.confident || !_mlKitSupported) {
      return _Outcome(glyphSeeds, street, glyph.boardCount, 'glyph reader');
    }
    // Fallback: ML Kit OCR on the whole photo, merged with what the glyph
    // reader did find (its cards first).
    CardReadResult ocr;
    try {
      ocr = await _mlKit(path, image, rgba);
    } catch (e) {
      debugPrint('ML Kit failed: $e');
      ocr = const CardReadResult([], []);
    }
    final seeds = <_Seed>[...glyphSeeds.where((s) => s.conf >= 1.0)];
    for (final c in ocr.cards) {
      if (seeds.length >= 2) break;
      if (seeds.any((s) => s.rank == c.rank && s.suit == c.suit)) continue;
      seeds.add(_Seed(c.rank, c.suit, c.suitConfidence));
    }
    for (final s in glyphSeeds) {
      if (seeds.length >= 2) break;
      if (!seeds.contains(s)) seeds.add(s);
    }
    final src = seeds.isEmpty
        ? 'none'
        : (ocr.cards.isEmpty ? 'glyph reader' : (glyphSeeds.isEmpty ? 'ML Kit' : 'glyph reader + ML Kit'));
    return _Outcome(seeds, street, glyph.boardCount, src);
  } finally {
    image.dispose();
  }
}

/// Saves the decoded pixels as PNG so ML Kit sees the same frame we sample
/// colours from, runs OCR and the token-based card reader.
Future<CardReadResult> _mlKit(String path, ui.Image image, Uint8List rgba) async {
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) return const CardReadResult([], []);
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
  return readCards(tokens, RgbaImage(image.width, image.height, rgba));
}

class _SnapResultScreen extends StatefulWidget {
  final String path;
  final Uint8List bytes;
  const _SnapResultScreen({required this.path, required this.bytes});

  @override
  State<_SnapResultScreen> createState() => _SnapResultScreenState();
}

class _SnapResultScreenState extends State<_SnapResultScreen> {
  late final Future<_Outcome> _future = _analyse(widget.path, widget.bytes);

  /// Rank + suit per slot (null = unknown).
  final List<int?> _rank = [null, null];
  final List<int?> _suit = [null, null];
  final List<double> _conf = [0, 0];
  bool _seeded = false;

  void _seed(_Outcome r) {
    if (_seeded) return;
    _seeded = true;
    for (var i = 0; i < r.cards.length && i < 2; i++) {
      _rank[i] = r.cards[i].rank;
      _suit[i] = r.cards[i].suit;
      _conf[i] = r.cards[i].conf;
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
      body: FutureBuilder<_Outcome>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Reading the corners on your device...'),
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
          if (r.cards.isEmpty) {
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
                child: Image.memory(widget.bytes, height: 180, fit: BoxFit.cover),
              ),
              const SizedBox(height: 12),
              Text(
                  'Check the cards. Camera reading is a beta guess; fix any suit '
                  'here, or tap a card later to use the picker.',
                  style: t.bodySmall),
              if (r.street != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        'Board: ${r.street}${r.boardCount > 0 ? ' (${r.boardCount} cards seen)' : ''}. '
                        'Info only, nothing is logged from it.',
                        style: t.bodySmall),
                  ),
                ]),
              ],
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
              const SizedBox(height: 8),
              Text('Read by: ${r.source}', style: t.labelSmall, textAlign: TextAlign.center),
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
                      '${unsure ? ' - unsure, check it' : ''}',
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
