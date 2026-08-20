// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Silent Firebase Auth – der User sieht und weiß davon nichts.
/// Beim ersten Start wird eine zufällige Identität generiert und gespeichert.
/// Danach wird automatisch eingeloggt.
class AuthService {
  static const String _prefUsername = 'firebase_username';
  static const String _prefPassword = 'firebase_password';
  static const String _emailDomain  = '@QGap-app.de';

  /// Zeichensatz für Passwörter und Chat-IDs (voll, mit Sonderzeichen)
  static const String _charsetFull =
      'abcdefghkmnpqrstuvwxyzACDEFGHKMNPQRSTUVWXYZ2345679!&()=+#,.;:';

  /// Zeichensatz für E-Mail-Usernamen (nur Zeichen, die vor dem @ erlaubt sind)
  static const String _charsetEmail =
      'abcdefghkmnpqrstuvwxyzACDEFGHKMNPQRSTUVWXYZ2345679';

  /// Generiert einen kryptographisch sicheren Zufalls-String der Länge [length].
  /// [emailSafe]: wenn true, werden nur E-Mail-kompatible Zeichen verwendet.
  static String generateRandomString(int length, {bool emailSafe = false}) {
    final charset = emailSafe ? _charsetEmail : _charsetFull;
    final rng = Random.secure();
    return List.generate(length, (_) => charset[rng.nextInt(charset.length)])
        .join();
  }

  /// Stellt sicher, dass der User eingeloggt ist.
  /// Wird einmalig beim App-Start aufgerufen – kein UI nötig.
  static Future<void> ensureLoggedIn() async {
    // Bereits eingeloggt? Dann fertig.
    if (FirebaseAuth.instance.currentUser != null) return;

    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString(_prefUsername);
    final savedPassword = prefs.getString(_prefPassword);

    if (savedUsername != null && savedPassword != null) {
      // Gespeicherte Identität → Auto-Login
      await _signIn(savedUsername, savedPassword, prefs);
    } else {
      // Erster Start → neue Identität generieren und registrieren
      await _registerNewIdentity(prefs);
    }
  }

  /// Gibt die Firebase UID des eingeloggten Users zurück (oder null).
  static String? get currentUid => FirebaseAuth.instance.currentUser?.uid;

  /// Gibt den gespeicherten Zufalls-Username zurück (für Backup).
  static Future<String?> getStoredUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefUsername);
  }

  /// Gibt das gespeicherte Passwort zurück (für Backup – verschlüsselt exportieren!).
  static Future<String?> getStoredPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefPassword);
  }

  /// Loggt mit einer importierten Identität ein (nach Backup-Import).
  static Future<bool> loginWithCredentials(
      String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    return await _signIn(username, password, prefs);
  }

  // ─── Interne Methoden ────────────────────────────────────────────────────

  static Future<void> _registerNewIdentity(SharedPreferences prefs,
      {int attempt = 0}) async {
    if (attempt >= 5) {
      throw Exception(
          'Konnte keine freie Firebase-Identität generieren (5 Versuche).');
    }
    // Username: nur E-Mail-kompatible Zeichen (kein !, &, (, ) usw.)
    final username = generateRandomString(20, emailSafe: true);
    // Passwort: voller Charset mit Sonderzeichen
    final password = generateRandomString(20);
    final email = '$username$_emailDomain';

    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      // Erfolgreich registriert → lokal speichern
      await prefs.setString(_prefUsername, username);
      await prefs.setString(_prefPassword, password);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        // Sehr unwahrscheinlich bei 20 Zeichen aus 64 Symbolen, aber sicher abfangen
        await _registerNewIdentity(prefs, attempt: attempt + 1);
      } else {
        rethrow;
      }
    }
  }

  static Future<bool> _signIn(
      String username, String password, SharedPreferences prefs) async {
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: '$username$_emailDomain',
        password: password,
      );
      return true;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'user-not-found') {
        // Account wurde in Firebase gelöscht → neu registrieren
        await prefs.remove(_prefUsername);
        await prefs.remove(_prefPassword);
        await _registerNewIdentity(prefs);
        return true;
      }
      return false;
    }
  }
}
