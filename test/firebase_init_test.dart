// Build 42's root cause, with Firebase's own platform mocks: with only a
// NAMED Firebase app, cloud_firestore's instanceFor(app:) still asks for
// the [DEFAULT] app and throws "[core/no-app]", so no phone ever reached
// Firestore. FirestoreCloudLogs.start now uses the default app.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:felt_notes/sync/firebase_options.dart';
import 'package:felt_notes/sync/firestore_cloud_logs.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Like the phones: no google-services.json, so the native side starts
/// with no apps at all (Firebase's stock mock pretends there is a default).
class _NoNativeDefault implements TestFirebaseCoreHostApi {
  @override
  Future<List<PigeonInitializeResponse?>> initializeCore() async => [];

  @override
  Future<PigeonInitializeResponse> initializeApp(String appName, PigeonFirebaseOptions o) async =>
      PigeonInitializeResponse(name: appName, options: o, pluginConstants: {});

  @override
  Future<PigeonFirebaseOptions> optionsFromResource() async => throw StateError('no google-services.json');

  static void setup() => TestFirebaseCoreHostApi.setup(_NoNativeDefault());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _NoNativeDefault.setup();

  test('a named app alone: Firestore throws [core/no-app] (what every phone hit)', () async {
    final app = await Firebase.initializeApp(name: 'feltnotes-sync', options: feltFirebaseOptions());
    final db = FirebaseFirestore.instanceFor(app: app);
    // The first use (build 42 set the cache settings first) throws.
    expect(
      () => db.settings = const Settings(persistenceEnabled: false),
      throwsA(isA<FirebaseException>().having((e) => e.code, 'code', 'no-app')),
    );
  });

  test('the cloud starts on the default app, and twice is fine', () async {
    final a = await FirestoreCloudLogs.start(options: feltFirebaseOptions());
    expect(a.db.app.name, defaultFirebaseAppName);
    expect(a.auth.app.name, defaultFirebaseAppName);
    final b = await FirestoreCloudLogs.start(options: feltFirebaseOptions());
    expect(b.db.app.name, defaultFirebaseAppName);
  });
}
