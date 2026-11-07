// The Pulse profile: name (fast, prefilled), a selfie (optional: coloured
// initials otherwise) and a favourite song (optional). Saved on this
// phone; it goes to a night only when Pulse is turned on there.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../pulse/pulse_profile.dart';
import '../../pulse/pulse_service.dart';
import '../app_settings.dart';
import 'pulse_widgets.dart';
import 'song_player.dart';

/// The front camera, then the centre square at 96x96. Null: cancelled.
Future<Uint8List?> takeSelfie() async {
  final x = await ImagePicker().pickImage(
      source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxWidth: 720, maxHeight: 720);
  if (x == null) return null;
  final bytes = await x.readAsBytes();
  return kIsWeb ? squareFace(bytes) : compute(squareFace, bytes);
}

class PulseProfileScreen extends StatefulWidget {
  /// First time (turning Pulse on): Save says "Join Pulse".
  final bool firstTime;

  /// Tests: instead of the camera / the iTunes search.
  final Future<Uint8List?> Function()? selfie;
  final Future<List<PulseSong>> Function(String term)? search;
  final SongPlayer? player;

  const PulseProfileScreen({super.key, this.firstTime = false, this.selfie, this.search, this.player});

  @override
  State<PulseProfileScreen> createState() => _PulseProfileScreenState();
}

class _PulseProfileScreenState extends State<PulseProfileScreen> {
  final _name = TextEditingController();
  Uint8List? _face;
  PulseSong? _song;
  bool _busy = false;
  String? _photoError;

  @override
  void initState() {
    super.initState();
    final p = PulseProfileStore.profile.value;
    // Prefill with the name the app already knows: the profile, the
    // player's name in Settings, or the name they joined the night with.
    _name.text = p?.name ??
        (AppSettings.playerName.value.trim().isNotEmpty
            ? AppSettings.playerName.value.trim()
            : (PulseService.instance.night?.myName ?? ''));
    _face = p?.face;
    _song = p?.song;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _photo() async {
    setState(() {
      _busy = true;
      _photoError = null;
    });
    try {
      final f = await (widget.selfie ?? takeSelfie)();
      if (f != null && mounted) setState(() => _face = f);
    } catch (e) {
      if (mounted) setState(() => _photoError = 'No photo: the camera did not open.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickSong() async {
    final s = await Navigator.of(context).push<PulseSong>(
        MaterialPageRoute(builder: (_) => SongPickerScreen(search: widget.search, player: widget.player)));
    if (s != null && mounted) setState(() => _song = s);
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    await PulseProfileStore.save(PulseProfile(name: name.length > 24 ? name.substring(0, 24) : name, face: _face, song: _song));
    PulseService.instance.profileChanged();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.firstTime ? 'Join Pulse' : 'My Pulse profile')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('The TV shows a line for your heart rate, ending in your face.', style: t.bodyMedium),
        const SizedBox(height: 16),
        TextField(
          key: const Key('pulse-name'),
          controller: _name,
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name on the TV'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Row(children: [
          FaceCircle(face: _face, name: _name.text, colour: const Color(0xFF3987E5), size: 72),
          const SizedBox(width: 16),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              OutlinedButton.icon(
                key: const Key('pulse-selfie'),
                onPressed: _busy ? null : _photo,
                icon: const Icon(Icons.camera_front_outlined),
                label: Text(_face == null ? 'Take a selfie' : 'Retake'),
              ),
              Text(_face == null ? 'Optional: without one you get your initials.' : 'A small circle, only for tonight\'s table.',
                  style: t.bodySmall),
              if (_photoError != null) Text(_photoError!, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ]),
          ),
        ]),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            key: const Key('pulse-song'),
            leading: _song == null
                ? const Icon(Icons.music_note_outlined)
                : ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(_song!.artworkUrl, width: 44, height: 44,
                        errorBuilder: (_, __, ___) => const Icon(Icons.music_note))),
            title: Text(_song == null ? 'Pick your song (optional)' : _song!.title),
            subtitle: Text(_song == null ? 'Plays on the TV while your heart rate leads.' : _song!.artist),
            trailing: _song == null
                ? const Icon(Icons.chevron_right)
                : IconButton(
                    tooltip: 'No song', icon: const Icon(Icons.close), onPressed: () => setState(() => _song = null)),
            onTap: _pickSong,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('pulse-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _name.text.trim().isEmpty ? null : _save,
          child: Text(widget.firstTime ? 'Join Pulse' : 'Save'),
        ),
        const SizedBox(height: 8),
        Text('Saved on this phone. Your face and song go to a table only when you share your heart rate there, '
            'and are deleted with that night.',
            style: t.bodySmall),
      ]),
    );
  }
}

/// Search Apple's catalogue, preview, pick. Returns the [PulseSong].
class SongPickerScreen extends StatefulWidget {
  final Future<List<PulseSong>> Function(String term)? search;
  final SongPlayer? player;
  const SongPickerScreen({super.key, this.search, this.player});

  @override
  State<SongPickerScreen> createState() => _SongPickerScreenState();
}

class _SongPickerScreenState extends State<SongPickerScreen> {
  final _q = TextEditingController();
  late final SongPlayer _player = widget.player ?? AudioSongPlayer();
  List<PulseSong> _results = const [];
  bool _loading = false;
  String? _error;
  int? _playing;

  @override
  void dispose() {
    _q.dispose();
    _player.stop();
    if (widget.player == null) _player.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final term = _q.text.trim();
    if (term.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await (widget.search ?? searchSongs)(term);
      if (!mounted) return;
      setState(() {
        _results = r;
        _error = r.isEmpty ? 'Nothing found with a preview. Try the artist too.' : null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Search needs an internet connection.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _preview(PulseSong s) async {
    if (_playing == s.trackId) {
      await _player.stop();
      setState(() => _playing = null);
      return;
    }
    final ok = await _player.play(s.previewUrl);
    if (mounted) setState(() => _playing = ok ? s.trackId : null);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Pick your song')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            key: const Key('song-search'),
            controller: _q,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Song or artist',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
            ),
            onSubmitted: (_) => _search(),
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null) Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: ListView(children: [
            for (final s in _results)
              ListTile(
                key: ValueKey('song-${s.trackId}'),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(s.artworkUrl,
                      width: 48, height: 48, errorBuilder: (_, __, ___) => const Icon(Icons.music_note)),
                ),
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: _playing == s.trackId ? 'Stop' : 'Listen (30 s)',
                    icon: Icon(_playing == s.trackId ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                    onPressed: () => _preview(s),
                  ),
                  FilledButton.tonal(
                    key: ValueKey('pick-${s.trackId}'),
                    onPressed: () => Navigator.of(context).pop(s),
                    child: const Text('Pick'),
                  ),
                ]),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('30-second previews from Apple Music. Nothing is uploaded but the link.',
              style: t.bodySmall, textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}
