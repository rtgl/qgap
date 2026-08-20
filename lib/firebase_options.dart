// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

// ignore_for_file: lines_longer_than_80_chars, avoid_classes_with_only_static_members
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Standard Firebase-Optionen für alle Plattformen.
///
/// iOS wurde per FlutterFire CLI registriert:
///   flutterfire configure --project=obmc-1856d --platforms=ios --ios-bundle-id=de.paulporg.QGap
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.windows:
        return windows;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not configured for platform: '
          '$defaultTargetPlatform',
        );
    }
  }

  // ── Android (aus google-services.json) ──────────────────────────────────
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBfAoGRKs1aNiZ0U0UVDZX599UkrPzuYXA',
    appId: '1:347828391849:android:274bf771f25467a5a83eb8',
    messagingSenderId: '347828391849',
    projectId: 'obmc-1856d',
    storageBucket: 'obmc-1856d.firebasestorage.app',
  );

  // ── iOS (via FlutterFire CLI registriert) ─────────────────────────────────

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBB0mwcVhqVgHJzyTnvOrn7yltdkrLAOt4',
    appId: '1:347828391849:ios:d3b3d266e2d884bfa83eb8',
    messagingSenderId: '347828391849',
    projectId: 'obmc-1856d',
    storageBucket: 'obmc-1856d.firebasestorage.app',
    iosBundleId: 'de.paulporg.QGap',
  );
  // ── Windows ──────────────────────────────────────────────────────────────
  static const FirebaseOptions windows = FirebaseOptions(
    apiKey: 'AIzaSyBfAoGRKs1aNiZ0U0UVDZX599UkrPzuYXA',
    appId: '1:347828391849:web:c8af010f7c898e52a83eb8', // aus Console eingetragen!
    messagingSenderId: '347828391849',
    projectId: 'obmc-1856d',
    storageBucket: 'obmc-1856d.firebasestorage.app',
    authDomain: 'obmc-1856d.firebaseapp.com',
  );

  // ── Web ───────────────────────────────────────────────────────────────────
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBfAoGRKs1aNiZ0U0UVDZX599UkrPzuYXA',
    appId: '1:347828391849:web:c8af010f7c898e52a83eb8',
    messagingSenderId: '347828391849',
    projectId: 'obmc-1856d',
    storageBucket: 'obmc-1856d.firebasestorage.app',
    authDomain: 'obmc-1856d.firebaseapp.com',
  );

  // ── macOS ─────────────────────────────────────────────────────────────────
  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyBfAoGRKs1aNiZ0U0UVDZX599UkrPzuYXA',
    appId: '1:347828391849:web:c8af010f7c898e52a83eb8',
    messagingSenderId: '347828391849',
    projectId: 'obmc-1856d',
    storageBucket: 'obmc-1856d.firebasestorage.app',
    authDomain: 'obmc-1856d.firebaseapp.com',
  );
}
