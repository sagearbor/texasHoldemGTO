/// Whether this build talks to the cloud for table nights. ON by default:
/// the Firebase project `felt-notes-poker` (Spark plan, free, no billing
/// account) with the public client config in firebase_options.dart.
/// Firebase is only started the first time a table night needs it (joining
/// one, starting one with phones/TV on, or opening the TV page), never at
/// app launch, so solo use never touches the network.
///
///   --dart-define=FELT_CLOUD=false        local-only build (no Firebase)
///   --dart-define=FELT_FB_EMULATOR=10.0.2.2:8012 --dart-define=FELT_FB_PROJECT=demo-feltnotes
///                                         a local emulator only
library;

import 'package:firebase_core/firebase_core.dart';

import 'cloud_logs.dart';
import 'firebase_options.dart';
import 'firestore_cloud_logs.dart';

const cloudSyncEnabled = bool.fromEnvironment('FELT_CLOUD', defaultValue: true);

/// Override project (emulator runs use a `demo-` id that cannot reach a
/// real project).
const fbProject = String.fromEnvironment('FELT_FB_PROJECT');

/// host:port of a local Firestore emulator (the auth emulator is expected
/// on the same host at port 9099 unless FELT_FB_AUTH_EMULATOR says).
const fbEmulator = String.fromEnvironment('FELT_FB_EMULATOR');
const fbAuthEmulator = String.fromEnvironment('FELT_FB_AUTH_EMULATOR');

CloudLogs? _cloud;

/// Why the cloud did not start (shown instead of a bare "no cloud").
String? cloudError;
Future<CloudLogs?>? _opening;

/// The cloud backend, or null for local-only. Never throws: any failure to
/// start (no network is NOT one: Firebase starts offline) means local-only
/// for this run, and the night still works from the phone's own log.
Future<CloudLogs?> openCloud() {
  if (!cloudSyncEnabled) return Future.value(null);
  return _opening ??= _open();
}

Future<CloudLogs?> _open() async {
  try {
    final base = feltFirebaseOptions();
    final options = fbProject.isEmpty
        ? base
        : FirebaseOptions(
            apiKey: base.apiKey,
            appId: base.appId,
            messagingSenderId: base.messagingSenderId,
            projectId: fbProject,
          );
    _cloud = await FirestoreCloudLogs.start(
      options: options,
      emulator: fbEmulator.isEmpty ? null : fbEmulator,
      authEmulator: fbAuthEmulator.isEmpty ? null : fbAuthEmulator,
    );
  } catch (e) {
    cloudError = '$e';
    _cloud = null;
  }
  return _cloud;
}
