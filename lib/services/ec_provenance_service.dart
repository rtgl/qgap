// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:shared_preferences/shared_preferences.dart';

/// Verfolgt die Herkunft (Provenance) von .qgap_ec Schlüsseldateien.
///
/// Sicher gilt **ausschließlich** der direkte Import von einem USB-Datenträger.
/// Wird die Datei aus dem internen Speicher geladen oder über digitale Kanäle
/// (Share/Cloud/Mail) empfangen, ist sie potenziell kompromittiert.
class EcProvenanceService {
  static const String _prefix = 'ec_provenance_';

  /// Markiert eine .qgap_ec Datei als „USB-verifiziert" (sicherer Import).
  static Future<void> markUsbImport(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$fileName', 'usb');
  }

  /// Markiert eine .qgap_ec Datei als „digital empfangen" (unsicher).
  static Future<void> markDigitalImport(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$fileName', 'digital');
  }

  /// Liefert true wenn die Datei nachweislich von USB importiert wurde.
  static Future<bool> isUsbVerified(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$fileName') == 'usb';
  }

  /// Liefert die rohe Provenance-Markierung ('usb' / 'digital' / null).
  static Future<String?> getProvenance(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$fileName');
  }

  /// Prüft heuristisch ob ein Dateipfad auf einen USB-Datenträger verweist.
  /// Android: /storage/<UUID>/ oder /mnt/media_rw/. Andere Plattformen: false.
  static bool isUsbPath(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('/mnt/media_rw/')) return true;
    // /storage/XXXX-XXXX/ (USB) – aber NICHT /storage/emulated/ (interner Speicher)
    if (lower.startsWith('/storage/')
        && !lower.startsWith('/storage/emulated/')
        && !lower.startsWith('/storage/self/')) {
      return true;
    }
    return false;
  }
}
