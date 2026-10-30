/// Firebase client config for the `felt-notes-poker` project (Spark plan,
/// no billing account). Written by hand from `firebase apps:sdkconfig`
/// (the same shape flutterfire would generate). These are public client
/// identifiers, not secrets: access is controlled by firestore.rules and
/// anonymous sign-in.
library;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

const feltProjectId = 'felt-notes-poker';

/// Options for the platform this build runs on.
FirebaseOptions feltFirebaseOptions() {
  if (kIsWeb) return _web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.macOS => _ios,
    _ => _android,
  };
}

const _android = FirebaseOptions(
  apiKey: 'AIzaSyAHf5M8US0US7GchTf_x9ULyn2enHsTYO0',
  appId: '1:822888648332:android:7638d579c5bd49df4cf5a9',
  messagingSenderId: '822888648332',
  projectId: feltProjectId,
  storageBucket: 'felt-notes-poker.firebasestorage.app',
);

const _ios = FirebaseOptions(
  apiKey: 'AIzaSyC-p5eIdNSy7j1KXPWwpKwceAnpz6QJ82A',
  appId: '1:822888648332:ios:b114ae258493111e4cf5a9',
  messagingSenderId: '822888648332',
  projectId: feltProjectId,
  storageBucket: 'felt-notes-poker.firebasestorage.app',
  iosBundleId: 'com.sagearbor.feltnotes.app',
);

const _web = FirebaseOptions(
  apiKey: 'AIzaSyDNBvjDiJW_2hf7KoftFMOCl75b07QDsdY',
  appId: '1:822888648332:web:4a6369940e28c9ce4cf5a9',
  messagingSenderId: '822888648332',
  projectId: feltProjectId,
  authDomain: 'felt-notes-poker.firebaseapp.com',
  storageBucket: 'felt-notes-poker.firebasestorage.app',
);
