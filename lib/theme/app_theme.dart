// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/material.dart';

/// Zentrale Icon-Definitionen für konsistente Symbole in der gesamten App.
/// Verwendung: QgapIcons.qrScan, QgapIcons.fileOpen, ...
abstract class QgapIcons {
  // ── Kommunikation ─────────────────────────────────────────────────────────
  static const IconData qrScan    = Icons.qr_code_scanner;
  static const IconData send      = Icons.send;
  static const IconData mic       = Icons.mic;
  static const IconData camera    = Icons.photo_camera;

  // ── Dateien & Übertragung ─────────────────────────────────────────────────
  static const IconData fileOpen   = Icons.folder_open;
  static const IconData fileAttach = Icons.attach_file;
  static const IconData fileImport = Icons.download;
  static const IconData fileShare  = Icons.share;
  static const IconData fileSend   = Icons.upload_file;

  // ── Schlüssel & Sicherheit ────────────────────────────────────────────────
  static const IconData key        = Icons.key;
  static const IconData keyContact = Icons.vpn_key;
  static const IconData lock       = Icons.lock;
  static const IconData lockOpen   = Icons.lock_open;

  // ── Status ────────────────────────────────────────────────────────────────
  static const IconData success = Icons.check_circle;
  static const IconData warning = Icons.warning_amber;
  static const IconData error   = Icons.error;
  static const IconData info    = Icons.info_outline;
}

/// Zentrale Farb-Definitionen für konsistente Farben in der gesamten App.
/// Verwendung: QgapColors.qrScan, QgapColors.warning, ...
abstract class QgapColors {
  // ── Button / Icon Farben ──────────────────────────────────────────────────
  static const Color qrScan     = Colors.blue;
  static const Color fileOpen   = Colors.green;
  static const Color fileAttach = Colors.blueGrey;
  static const Color camera     = Colors.teal;
  static const Color mic        = Color(0xFFEF5350); // red.shade400
  static const Color send       = Colors.blue;
  static const Color fileShare  = Colors.blue;
  static const Color fileSend   = Colors.teal; 
  static const Color fileImport = Colors.indigo;
  static const Color keyContact = Color(0xFF8E24AA); // purple.shade600

  // ── Status Farben ─────────────────────────────────────────────────────────
  static const Color success = Color(0xFF388E3C); // green.shade700
  static const Color warning = Color(0xFFF57C00); // orange.shade700
  static const Color error   = Color(0xFFD32F2F); // red.shade700
  static const Color info    = Color(0xFF1976D2); // blue.shade700

  // ── Hintergrund Farben ────────────────────────────────────────────────────
  static const Color successBg = Color(0xFFE8F5E9); // green.shade50
  static const Color warningBg = Color(0xFFFFF3E0); // orange.shade50
  static const Color errorBg   = Color(0xFFFFEBEE); // red.shade50
  static const Color infoBg    = Color(0xFFE3F2FD); // blue.shade50
}

/// Zeigt eine SnackBar mit 5-Sekunden-Timeout und OK-Button zum schnellen Schließen.
/// Ersetzt [ScaffoldMessenger.of(context).showSnackBar] überall in der App.
void showQgapSnackBar(BuildContext context, SnackBar bar) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: bar.content,
    backgroundColor: bar.backgroundColor,
    duration: const Duration(seconds: 5),
    action: bar.action ??
        SnackBarAction(label: 'OK', onPressed: () {}),
  ));
}
