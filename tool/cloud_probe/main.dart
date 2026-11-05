// On-device cloud probe: the app's own cloud path (openCloud, organize,
// Uploader) on a phone or emulator, printing every step to logcat and the
// screen. Run it to tell "the phone cannot reach Firestore" from "the app
// never tries":
//
//   flutter run --release -t tool/cloud_probe/main.dart -d <device>
//   adb logcat -s flutter
//
// Leaves one test night (organizer "Probe") in felt-notes-poker; delete it
// with the firebase CLI (the rules let nobody delete a night).

import 'dart:async';

import 'package:felt_notes/sync/cloud_config.dart';
import 'package:felt_notes/sync/cloud_logs.dart';
import 'package:felt_notes/sync/event_log.dart';
import 'package:felt_notes/sync/table_sync.dart';
import 'package:flutter/material.dart';

final _lines = ValueNotifier<List<String>>([]);

void say(String s) {
  // ignore: avoid_print
  print('PROBE $s');
  _lines.value = [..._lines.value, s];
}

void main() {
  runApp(MaterialApp(
    home: Scaffold(
      body: SafeArea(
        child: ValueListenableBuilder<List<String>>(
          valueListenable: _lines,
          builder: (_, l, __) => ListView(children: [for (final s in l) Text(s)]),
        ),
      ),
    ),
  ));
  unawaited(_probe());
}

Future<void> _probe() async {
  final t0 = DateTime.now().millisecondsSinceEpoch;
  String at() => '+${DateTime.now().millisecondsSinceEpoch - t0} ms';
  say('cloudSyncEnabled=$cloudSyncEnabled');
  final cloud = await openCloud().timeout(const Duration(seconds: 60), onTimeout: () {
    say('openCloud TIMED OUT ${at()}');
    return null;
  });
  say('openCloud -> ${cloud.runtimeType} error=$cloudError ${at()}');
  if (cloud == null) return;
  final s = await LocalTableSync.organize(MemoryStore(), organizerName: 'Probe', selfPid: 'Probe', cloud: cloud);
  say('night ${s.nightId} device ${s.deviceId}');
  final up = Uploader(log: s.log, cloud: cloud, ticket: s.ticket, name: 'Probe');
  for (var i = 0; i < 3; i++) {
    final r = await up.drainOnce();
    say('drain $i -> $r lastError=${up.lastError} ${at()}');
    if (r != UploadResult.failed) break;
  }
  try {
    final logs = await cloud.fetch(s.nightId);
    say('fetch -> ${logs.length} device logs, ${logs.fold(0, (n, l) => n + l.events.length)} events ${at()}');
  } catch (e) {
    say('fetch FAILED $e ${at()}');
  }
  say('DONE');
}
