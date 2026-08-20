// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:io';

/// Beim App-Start übergebene Datei (Windows: Drag auf die EXE,
/// „Öffnen mit…" oder Dateiverknüpfung → Pfad steht in den Argumenten).
class LaunchArgs {
  LaunchArgs._();

  static String? pendingFilePath;
  /// Wird von home_screen gesetzt; empfängt Dateien zur Laufzeit
  /// (z. B. von einer zweiten Instanz weitergereicht).
  static void Function(String path)? onFile;

  static void notifyFile(String path) {
    final cb = onFile;
    if (cb != null) {
      cb(path);
    } else {
      pendingFilePath = path;
    }
  }
  static void init(List<String> args) {
    for (final a in args) {
      try {
        if (File(a).existsSync()) {
          pendingFilePath = a;
          return;
        }
      } catch (_) {}
    }
  }
}
