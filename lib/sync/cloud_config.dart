/// Whether this build talks to a cloud at all. OFF by default: the store
/// builds have no Firebase project, never call Firebase.initializeApp and
/// keep every table night on the phone (local-only, no crash).
///
/// Turn it on at build time once a Firebase project exists, e.g.
///
///   flutter run --dart-define=FELT_CLOUD=true \
///     --dart-define=FELT_FB_PROJECT=demo-feltnotes \
///     --dart-define=FELT_FB_EMULATOR=10.0.2.2:8012
///
/// With FELT_FB_EMULATOR set and a `demo-` project id it only ever talks to
/// the local emulator (no real project, no keys). For a real project add
/// FELT_FB_API_KEY, FELT_FB_APP_ID and FELT_FB_SENDER (those are public
/// client identifiers, not secrets, but none are committed here).
library;

import 'cloud_logs.dart';
import 'firestore_cloud_logs.dart';

const cloudSyncEnabled = bool.fromEnvironment('FELT_CLOUD');

const fbProject = String.fromEnvironment('FELT_FB_PROJECT');
const fbApiKey = String.fromEnvironment('FELT_FB_API_KEY');
const fbAppId = String.fromEnvironment('FELT_FB_APP_ID');
const fbSender = String.fromEnvironment('FELT_FB_SENDER');

/// host:port of a local Firestore emulator (the auth emulator is expected
/// on the same host at port 9099 unless FELT_FB_AUTH_EMULATOR says).
const fbEmulator = String.fromEnvironment('FELT_FB_EMULATOR');
const fbAuthEmulator = String.fromEnvironment('FELT_FB_AUTH_EMULATOR');

CloudLogs? _cloud;
bool _tried = false;

/// The cloud backend, or null for local-only. Never throws: any failure to
/// start (no project, no network, bad config) means local-only for this run.
Future<CloudLogs?> openCloud() async {
  if (!cloudSyncEnabled || fbProject.isEmpty) return null;
  if (_tried) return _cloud;
  _tried = true;
  try {
    _cloud = await FirestoreCloudLogs.start(
      projectId: fbProject,
      apiKey: fbApiKey.isEmpty ? 'emulator-only' : fbApiKey,
      appId: fbAppId.isEmpty ? '1:0:android:0' : fbAppId,
      senderId: fbSender.isEmpty ? '0' : fbSender,
      emulator: fbEmulator.isEmpty ? null : fbEmulator,
      authEmulator: fbAuthEmulator.isEmpty ? null : fbAuthEmulator,
    );
  } catch (_) {
    _cloud = null;
  }
  return _cloud;
}
