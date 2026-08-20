// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:qgap/services/ini_settings_store.dart';

/// Plattformübergreifende Basis-Pfade für alle QGap-Dateien.
///
/// Android:  /storage/emulated/0/Daten/QGap   (wie bisher, unverändert)
/// Windows:  <Dokumente>\QGap                  (z. B. C:\Users\xy\Documents\QGap)
/// iOS/macOS: App-Documents-Ordner/QGap        (in Dateien-App sichtbar,
///            wenn UIFileSharingEnabled in Info.plist gesetzt ist)
///
/// WICHTIG: [init] muss einmalig in main() vor runApp() aufgerufen werden.
/// Danach sind alle Getter synchron nutzbar.
class AppStorage {
  AppStorage._();

  static const String _androidRoot = '/storage/emulated/0/Daten/QGap';
  static const String _prefKeyCustomRoot = 'app_storage_custom_root';

  static String? _root;
  static String? _defaultRoot;
  static IniSettingsStore? _iniStore;

  /// Windows: Zeiger-Datei neben der EXE — enthält NUR den Pfad zum
  /// QGap-Datenordner. Alle weiteren Einstellungen liegen in der INI-Datei
  /// im Datenordner selbst (keine Registry, kein AppData).
  static File get _pointerFile => File(
      '${File(Platform.resolvedExecutable).parent.path}/QGap.ini');

  /// Alter Name der Zeiger-Datei (vor der Umbenennung auf QGap) — nur für
  /// die einmalige Migration bestehender Installationen gelesen.
  static File get _legacyPointerFile => File(
      '${File(Platform.resolvedExecutable).parent.path}/QGAP_root.txt');

  static String get _iniPath => '$root/QGap_settings.ini';

  /// Alter Name der Einstellungs-Datei (vor der Umbenennung auf QGap) —
  /// nur für die einmalige Migration bestehender Installationen gelesen.
  static String get _legacyIniPath => '$root/obmc_settings.ini';

  /// Alter Android-Datenordner (vor der Umbenennung auf QGap) — nur für
  /// die einmalige Migration bestehender Installationen gelesen.
  static const String _legacyAndroidRoot = '/storage/emulated/0/Daten/obmc';

  /// Ermittelt den plattformspezifischen Basisordner. Einmalig in main().
  /// Ein in den Einstellungen gewählter Ordner (USB, Netzlaufwerk, andere
  /// Partition …) hat Vorrang vor dem Standard.
  static Future<void> init() async {
    if (_root != null) return;
    String? legacyDefaultRoot;
    if (Platform.isAndroid) {
      _defaultRoot = _androidRoot;
      legacyDefaultRoot = _legacyAndroidRoot;
    } else {
      final docs = await getApplicationDocumentsDirectory();
      final docsPath = docs.path.replaceAll('\\', '/');
      _defaultRoot = '$docsPath/QGap';
      legacyDefaultRoot = '$docsPath/obmc';
    }
    // Einmalige Migration: alter „obmc“-Datenordner → neuer „QGap“-Ordner
    // (nur wenn der neue Ordner noch nicht existiert, alter Ordner aber schon).
    await _migrateLegacyDataFolder(legacyDefaultRoot, _defaultRoot!);

    if (Platform.isWindows) {
      // Benutzerdefinierten Ordner aus der Zeiger-Datei lesen
      String? custom;
      try {
        if (_pointerFile.existsSync()) {
          custom = _pointerFile.readAsStringSync().trim();
        } else if (_legacyPointerFile.existsSync()) {
          // Einmalige Migration: alte QGAP_root.txt → QGap.ini
          custom = _legacyPointerFile.readAsStringSync().trim();
          if (custom.isNotEmpty) {
            try {
              _pointerFile.writeAsStringSync(custom);
            } catch (_) {}
          }
        }
      } catch (_) {}
      _root = (custom != null && custom.isNotEmpty) ? custom : _defaultRoot;
      // Alle Einstellungen ab jetzt in <Datenordner>/QGap_settings.ini
      final iniFile = File(_iniPath);
      final firstRun = !iniFile.existsSync();
      // Einmalige Migration: alte obmc_settings.ini im (ggf. migrierten)
      // Datenordner in die neue QGap_settings.ini übernehmen.
      if (firstRun) {
        try {
          final legacyIni = File(_legacyIniPath);
          if (legacyIni.existsSync()) legacyIni.copySync(_iniPath);
        } catch (_) {}
      }
      _iniStore = IniSettingsStore(iniFile);
      SharedPreferencesStorePlatform.instance = _iniStore!;
      // Einmalige Migration: alte Einstellungen aus AppData übernehmen
      if (firstRun) await _migrateLegacyWindowsPrefs();
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getString(_prefKeyCustomRoot);
      if (custom != null && custom.isNotEmpty) {
        _root = custom;
        return;
      }
    } catch (_) {}
    _root = _defaultRoot;
  }

  /// Basisordner (…/QGap). Vor [init] wird der Android-Pfad geliefert.
  static String get root => _root ?? _androidRoot;

  /// Plattform-Standardordner (ohne Benutzer-Einstellung).
  static String get defaultRoot => _defaultRoot ?? _androidRoot;

  /// true wenn ein benutzerdefinierter Speicherort aktiv ist.
  static bool get isCustomRoot => _root != null && _root != _defaultRoot;

  /// Übernimmt beim ersten Start die alten Einstellungen aus
  /// AppData (shared_preferences.json) in die neue INI-Datei.
  static Future<void> _migrateLegacyWindowsPrefs() async {
    try {
      final support = await getApplicationSupportDirectory();
      final legacy = File('${support.path}/shared_preferences.json');
      if (!legacy.existsSync()) return;
      final map = jsonDecode(legacy.readAsStringSync());
      if (map is! Map<String, dynamic>) return;
      final values = <String, Object>{};
      map.forEach((k, v) {
        if (v == null) return;
        values[k] = v is List ? v.cast<String>() : v as Object;
      });
      _iniStore?.importAll(values);
    } catch (_) {}
  }

  /// Einmalige Migration: existiert der alte „obmc“-Datenordner, aber noch
  /// kein neuer „QGap“-Ordner, wird er umbenannt (Rename statt Kopie —
  /// funktioniert nur auf demselben Volume, was hier immer der Fall ist:
  /// gleicher Docs-Ordner bzw. gleicher Android-Datenpfad). Schlägt das
  /// Umbenennen fehl (z. B. anderes Volume), wird stattdessen kopiert
  /// (Original bleibt dabei erhalten).
  static Future<void> _migrateLegacyDataFolder(
      String legacyRoot, String newRoot) async {
    try {
      if (legacyRoot == newRoot) return;
      final legacyDir = Directory(legacyRoot);
      final newDir = Directory(newRoot);
      if (await newDir.exists() || !await legacyDir.exists()) return;
      try {
        await legacyDir.rename(newRoot);
      } catch (_) {
        await copyContents(legacyRoot, newRoot);
      }
    } catch (_) {}
  }

  /// Setzt einen benutzerdefinierten Basisordner und persistiert ihn.
  /// [path] = null oder leer → zurück zum Plattform-Standard.
  /// Windows: Zeiger-Datei neben der EXE aktualisieren + INI mitnehmen.
  static Future<void> setCustomRoot(String? path) async {
    final normalized =
        (path == null || path.isEmpty) ? null : path.replaceAll('\\', '/');

    if (Platform.isWindows) {
      if (normalized == null) {
        try {
          if (_pointerFile.existsSync()) _pointerFile.deleteSync();
        } catch (_) {}
        _root = _defaultRoot;
      } else {
        await Directory(normalized).create(recursive: true);
        _pointerFile.writeAsStringSync(normalized, flush: true);
        _root = normalized;
      }
      // Einstellungen (INI) an den neuen Ort mitnehmen
      _iniStore?.moveTo(File(_iniPath));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    if (normalized == null) {
      await prefs.remove(_prefKeyCustomRoot);
      _root = _defaultRoot;
    } else {
      await Directory(normalized).create(recursive: true);
      await prefs.setString(_prefKeyCustomRoot, normalized);
      _root = normalized;
    }
  }

  /// Kopiert alle Dateien rekursiv von [fromRoot] nach [toRoot]
  /// („Dateien mitnehmen“ beim Speicherort-Wechsel).
  /// Bereits vorhandene Ziel-Dateien werden NICHT überschrieben.
  /// Rückgabe: (kopiert, übersprungen/fehlgeschlagen).
  static Future<(int, int)> copyContents(String fromRoot, String toRoot) async {
    final srcRoot = fromRoot.replaceAll('\\', '/');
    final dstRoot = toRoot.replaceAll('\\', '/');
    int copied = 0;
    int skipped = 0;
    final src = Directory(srcRoot);
    if (!await src.exists() || srcRoot == dstRoot) return (0, 0);
    await for (final entity
        in src.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      try {
        final rel = entity.path.replaceAll('\\', '/').substring(srcRoot.length);
        final target = File('$dstRoot$rel');
        if (await target.exists()) {
          skipped++;
          continue;
        }
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
        copied++;
      } catch (_) {
        skipped++;
      }
    }
    return (copied, skipped);
  }

  /// Ordner für OTP-/EC-Schlüsseldateien.
  static String get schluesselDir => '$root/schluessel';

  /// Ordner für empfangene Dateien (Anhänge, Sprachnachrichten …).
  static String get empfangenDir => '$root/empfangen';

  /// Ordner für geparkte empfangene Dateien.
  static String get empfangenGeparktDir => '$root/empfangen_geparkt';

  /// Ordner für gesendete Dateien.
  static String get gesendeteDir => '$root/gesendete';

  /// Ordner für die Pickup-Queue (Relay-Zwischenspeicher).
  static String get pickupQueueDir => '$root/pickup_queue';

  /// Vollständiger Pfad einer Datei im Schlüssel-Ordner.
  static String keyFilePath(String fileName) => '$schluesselDir/$fileName';

  /// Extrahiert den reinen Dateinamen aus einem Pfad.
  /// Windows liefert '\' als Trenner, Android/iOS '/' — beide werden erkannt.
  static String fileNameOf(String path) =>
      path.split(RegExp(r'[/\\]')).last;
}
