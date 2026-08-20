// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:qgap/services/app_storage.dart';

/// Verwaltung des Zufalls-Codes, der an `.qgap_ec`-Dateinamen angehängt wird.
///
/// Aufbau eines Dateinamens:  `<freier-text>_<code>.qgap_ec`
/// Der `<code>` besteht aus exakt [codeLength] Zeichen aus `[a-z0-9]` und
/// wird beim Erstellen der Datei zufällig generiert. Über den Code kann der
/// Empfänger eine OTP-Nachricht der lokalen `.qgap_ec`-Datei zuordnen, ohne
/// dass der freie (möglicherweise personenbezogene) Dateiname über Firestore
/// übertragen werden muss.
class EcKeyfileService {
  static const String _prefsCodeLengthKey = 'ec_code_length';

  /// Default-Länge des Codes (Mittelwert zwischen Min und Max).
  static const int kDefaultCodeLength = 12;

  /// Minimale Länge des Codes.
  static const int kMinCodeLength = 5;

  /// Maximale Länge des Codes.
  static const int kMaxCodeLength = 20;

  /// Erlaubte Zeichen für den Code – nur Kleinbuchstaben und Ziffern,
  /// damit der Dateiname auf jedem Dateisystem gültig bleibt.
  static const String _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// Lädt die gespeicherte Code-Länge (gerätelokal).
  static Future<int> getCodeLength() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getInt(_prefsCodeLengthKey) ?? kDefaultCodeLength;
    return raw.clamp(kMinCodeLength, kMaxCodeLength);
  }

  /// Setzt und persistiert die Code-Länge.
  static Future<void> setCodeLength(int length) async {
    final clamped = length.clamp(kMinCodeLength, kMaxCodeLength);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsCodeLengthKey, clamped);
  }

  /// Generiert einen neuen zufälligen Code mit [length] Zeichen oder der
  /// gespeicherten Länge, falls [length] = `null`.
  static Future<String> generateCode([int? length]) async {
    final n = length ?? await getCodeLength();
    final clamped = n.clamp(kMinCodeLength, kMaxCodeLength);
    final rnd = Random.secure();
    final buffer = StringBuffer();
    for (int i = 0; i < clamped; i++) {
      buffer.write(_alphabet[rnd.nextInt(_alphabet.length)]);
    }
    return buffer.toString();
  }

  /// Hängt einen frisch generierten Code an [freeText] an und liefert den
  /// vollständigen Dateinamen (inkl. `.qgap_ec`-Endung).
  ///
  /// Beispiel: `appendCodeToFilename("meinkey", 10)` →
  /// `"meinkey_fgjekertz4.qgap_ec"`
  static Future<String> appendCodeToFilename(String freeText,
      [int? length]) async {
    final code = await generateCode(length);
    final cleanFree = freeText.trim().replaceAll(RegExp(r'\.qgap_ec$'), '');
    return '${cleanFree}_$code.qgap_ec';
  }

  /// Extrahiert den Code aus einem `.qgap_ec`-Dateinamen.
  ///
  /// Sucht ab dem Suffix `.qgap_ec` rückwärts bis zum nächsten `_` und prüft,
  /// ob der gefundene Block im erlaubten Längen- und Zeichenraum liegt. Liefert
  /// `null` für Legacy-Dateien ohne erkennbaren Code.
  static String? extractCodeFromFilename(String fileName) {
    final lower = fileName.toLowerCase();
    if (!lower.endsWith('.qgap_ec')) return null;
    final stem = lower.substring(0, lower.length - '.qgap_ec'.length);
    final lastUnderscore = stem.lastIndexOf('_');
    if (lastUnderscore < 0) return null;
    final candidate = stem.substring(lastUnderscore + 1);
    if (candidate.length < kMinCodeLength ||
        candidate.length > kMaxCodeLength) {
      return null;
    }
    if (!RegExp(r'^[a-z0-9]+$').hasMatch(candidate)) return null;
    return candidate;
  }

  /// Prüft, ob [fileName] einen gültigen, extrahierbaren Code enthält.
  static bool hasValidCode(String fileName) =>
      extractCodeFromFilename(fileName) != null;

  /// Sucht im lokalen Schlüsselordner nach einer `.qgap_ec`-Datei, deren
  /// Code mit [code] übereinstimmt. Rückgabe ist der reine Dateiname (ohne
  /// Pfad), oder `null` wenn keine passende Datei existiert.
  static Future<String?> findEcFileByCode(String code,
          {String? dirPath}) async =>
      findEcFileByCodeSync(code, dirPath: dirPath);

  /// Synchrone Variante von [findEcFileByCode] — für Aufrufer ohne async
  /// (z. B. Anzeige-Pfad der Nachrichtenliste).
  static String? findEcFileByCodeSync(String code, {String? dirPath}) {
    final dir = Directory(dirPath ?? AppStorage.schluesselDir);
    if (!dir.existsSync()) return null;
    try {
      for (final entry in dir.listSync(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.last;
        if (!name.toLowerCase().endsWith('.qgap_ec')) continue;
        if (extractCodeFromFilename(name) == code) {
          return name;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}
