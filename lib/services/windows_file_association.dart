// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:io';

/// Registriert die Windows-Dateiverknüpfungen für .qgap / .qgap_ch / .qgap_ec
/// unter HKCU (keine Adminrechte nötig). Doppelklick im Explorer öffnet
/// die Datei dann direkt mit pp_QGap.exe.
class WindowsFileAssociation {
  WindowsFileAssociation._();

  static const String _progId = 'QGap.File';

  static Future<void> register() async {
    if (!Platform.isWindows) return;
    final exe = Platform.resolvedExecutable;

    Future<void> reg(String key, String value) => Process.run(
        'reg', ['add', key, '/ve', '/t', 'REG_SZ', '/d', value, '/f']);

    try {
      // Neue UND alte Endungen auf denselben ProgId registrieren, damit
      // bereits vorhandene .obmc*-Dateien (vor der Umbenennung) weiterhin
      // per Doppelklick geöffnet werden können.
      for (final ext in [
        '.qgap', '.qgap_ch', '.qgap_ec',
        '.obmc', '.obmc_ch', '.obmc_ec',
      ]) {
        await reg('HKCU\\Software\\Classes\\$ext', _progId);
      }
      await reg('HKCU\\Software\\Classes\\$_progId', 'QGap Datei');
      await reg('HKCU\\Software\\Classes\\$_progId\\DefaultIcon', '"$exe",0');
      await reg('HKCU\\Software\\Classes\\$_progId\\shell\\open\\command',
          '"$exe" "%1"');
    } catch (_) {/* Registry nicht verfügbar → still ignorieren */}
  }
}
