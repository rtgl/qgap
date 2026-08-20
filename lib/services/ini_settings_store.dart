// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// SharedPreferences-Backend, das alle Einstellungen in einer INI-Datei
/// im QGap-Datenordner speichert (Windows) — statt in AppData/Registry.
///
/// Format: `[QGap]`-Sektion, pro Zeile `schlüssel=<JSON-Wert>`.
/// Alle bestehenden `SharedPreferences`-Aufrufe der App laufen unverändert
/// über dieses Backend, sobald es in `AppStorage.init()` registriert wurde.
class IniSettingsStore extends SharedPreferencesStorePlatform {
  IniSettingsStore(this._file) {
    _load();
  }

  File _file;
  final Map<String, Object> _cache = {};

  /// Pfad der aktuell verwendeten INI-Datei.
  String get filePath => _file.path;

  void _load() {
    try {
      if (!_file.existsSync()) return;
      for (final line in _file.readAsLinesSync()) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#') || t.startsWith('[')) continue;
        final idx = t.indexOf('=');
        if (idx <= 0) continue;
        final key = t.substring(0, idx);
        try {
          final val = jsonDecode(t.substring(idx + 1));
          if (val is List) {
            _cache[key] = val.cast<String>();
          } else if (val != null) {
            _cache[key] = val as Object;
          }
        } catch (_) {/* defekte Zeile überspringen */}
      }
    } catch (_) {}
  }

  void _save() {
    try {
      final sb = StringBuffer()
        ..writeln('# QGap Einstellungen — nicht von Hand editieren')
        ..writeln('[QGap]');
      final keys = _cache.keys.toList()..sort();
      for (final k in keys) {
        sb.writeln('$k=${jsonEncode(_cache[k])}');
      }
      _file.createSync(recursive: true);
      _file.writeAsStringSync(sb.toString(), flush: true);
    } catch (_) {}
  }

  /// Verlagert die INI-Datei (nach Speicherort-Wechsel) und schreibt den
  /// aktuellen Stand dorthin.
  void moveTo(File newFile) {
    _file = newFile;
    _save();
  }

  /// Einmaliger Massen-Import (Migration alter Einstellungen).
  void importAll(Map<String, Object> values) {
    _cache.addAll(values);
    _save();
  }

  @override
  Future<bool> clear() async {
    _cache.clear();
    _save();
    return true;
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final f = parameters.filter;
    _cache.removeWhere((k, _) =>
        k.startsWith(f.prefix) &&
        (f.allowList == null || f.allowList!.contains(k)));
    _save();
    return true;
  }

  @override
  Future<Map<String, Object>> getAll() async =>
      Map<String, Object>.from(_cache);

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    final f = parameters.filter;
    final out = <String, Object>{};
    _cache.forEach((k, v) {
      if (!k.startsWith(f.prefix)) return;
      if (f.allowList != null && !f.allowList!.contains(k)) return;
      out[k] = v;
    });
    return out;
  }

  @override
  Future<bool> remove(String key) async {
    _cache.remove(key);
    _save();
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _cache[key] = value;
    _save();
    return true;
  }
}
