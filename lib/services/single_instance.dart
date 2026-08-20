// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';

import 'package:qgap/services/launch_args.dart';

/// Single-Instance-Schutz (Windows/Desktop) über einen Localhost-Port.
///
/// Die erste Instanz belegt den Port und lauscht auf Dateipfade.
/// Jede weitere Instanz reicht ihre Startdatei an die laufende Instanz
/// weiter und beendet sich sofort.
class SingleInstance {
  SingleInstance._();

  static const int _port = 47654;
  static ServerSocket? _server;

  /// true = wir sind die primäre Instanz.
  /// false = es läuft bereits eine Instanz (Datei wurde weitergereicht).
  static Future<bool> ensurePrimary() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
      _server!.listen((client) {
        final buffer = <int>[];
        client.listen(
          buffer.addAll,
          onDone: () {
            try {
              final path = utf8.decode(buffer).trim();
              if (path.isNotEmpty && File(path).existsSync()) {
                LaunchArgs.notifyFile(path);
              }
            } catch (_) {}
            client.destroy();
          },
          onError: (_) => client.destroy(),
        );
      });
      return true;
    } catch (_) {
      // Primäre Instanz läuft bereits → Datei-Pfad übergeben
      try {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          _port,
          timeout: const Duration(seconds: 2),
        );
        socket.add(utf8.encode(LaunchArgs.pendingFilePath ?? ''));
        await socket.flush();
        await socket.close();
      } catch (_) {}
      return false;
    }
  }
}
