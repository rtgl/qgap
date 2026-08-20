// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/services.dart';

/// Zugriff auf USB-OTG-Volumes über das Android Storage Access Framework (SAF).
///
/// Auf Android 11+ ist der direkte Pfad-Zugriff (z. B. `/mnt/media_rw/6636-3164`)
/// für Apps verboten, selbst mit `MANAGE_EXTERNAL_STORAGE`. Stattdessen muss der
/// User per `ACTION_OPEN_DOCUMENT_TREE` einmalig den USB-Stick auswählen; die
/// daraus resultierende Tree-Uri wird mit `takePersistableUriPermission`
/// dauerhaft persistiert.
class UsbSafService {
  static const MethodChannel _ch = MethodChannel('de.paulporg.QGap/usbsaf');

  /// Öffnet den System-Picker.  Liefert die gewählte Tree-Uri oder `null`,
  /// wenn der Nutzer abgebrochen hat.
  static Future<String?> pickUsbTreeUri() async {
    return await _ch.invokeMethod<String?>('pickUsbTreeUri');
  }

  /// Bereits gespeicherte Tree-Uri (oder `null`).
  static Future<String?> getPersistedUsbTreeUri() async {
    return await _ch.invokeMethod<String?>('getPersistedUsbTreeUri');
  }

  /// Registriert eine extern erhaltene Tree-Uri (z. B. von FilePicker) als
  /// persistente USB-SAF-Uri. Sichert Zugriffsrechte auf nativem Seite.
  static Future<String?> registerTreeUri(String uri) async {
    return await _ch.invokeMethod<String?>('registerTreeUri', uri);
  }

  /// true falls bereits ein USB-Stick gekoppelt wurde.
  static Future<bool> hasTreeUri() async {
    final uri = await getPersistedUsbTreeUri();
    return uri != null && uri.isNotEmpty;
  }

  /// Entfernt die gespeicherte Tree-Uri.
  static Future<void> clearUsbTreeUri() async {
    await _ch.invokeMethod<bool>('clearUsbTreeUri');
  }

  /// Listet Unterordner in `subPath` (relativ zur Tree-Uri).
  /// Wird vom SAF-Ordner-Browser verwendet – kein FilePicker nötig.
  static Future<List<String>> listSubDirs({String? subPath}) async {
    final List<dynamic>? raw = await _ch.invokeMethod<List<dynamic>>(
      'listSubDirs',
      <String, dynamic>{
        if (subPath != null) 'subPath': subPath,
      },
    );
    if (raw == null) return const [];
    return raw.whereType<String>().toList();
  }

  /// Listet Dateien (keine Ordner) in `subPath` (relativ zur Tree-Uri).
  /// Optional kann nach `suffix` gefiltert werden (z. B. `.qgap_ec`).
  static Future<List<UsbSafFile>> listUsbDir({
    String? subPath,
    String? suffix,
  }) async {
    final List<dynamic>? raw = await _ch.invokeMethod<List<dynamic>>(
      'listUsbDir',
      <String, dynamic>{
        if (subPath != null) 'subPath': subPath,
        if (suffix != null) 'suffix': suffix,
      },
    );
    if (raw == null) return const [];
    return raw
        .whereType<Map>()
        .map((m) => UsbSafFile.fromMap(m.cast<String, dynamic>()))
        .toList();
  }

  /// Liest eine SAF-Datei (per content-URI) als Bytes.
  static Future<Uint8List?> readUsbFile(String uri) async {
    final bytes = await _ch.invokeMethod<Uint8List>('readUsbFile', uri);
    return bytes;
  }

  /// Schreibt Bytes in `<USB>/<subPath>/<fileName>` (Verzeichnisse werden
  /// rekursiv angelegt). Gibt die content-URI der neuen Datei zurück.
  static Future<UsbSafFile> writeUsbFile({
    required String subPath,
    required String fileName,
    required Uint8List bytes,
    String mime = 'application/octet-stream',
  }) async {
    final Map<dynamic, dynamic>? result =
        await _ch.invokeMethod<Map<dynamic, dynamic>>(
      'writeUsbFile',
      <String, dynamic>{
        'subPath': subPath,
        'fileName': fileName,
        'bytes': bytes,
        'mime': mime,
      },
    );
    if (result == null) {
      throw PlatformException(
        code: 'WRITE_FAILED',
        message: 'writeUsbFile lieferte null',
      );
    }
    return UsbSafFile.fromMap(result.cast<String, dynamic>());
  }

  /// Löscht eine SAF-Datei per content-URI.
  static Future<bool> deleteUsbFile(String uri) async {
    final ok = await _ch.invokeMethod<bool>('deleteUsbFile', uri);
    return ok ?? false;
  }
}

/// Metadaten einer SAF-Datei.
class UsbSafFile {
  final String name;
  final String uri;
  final int size;
  final int lastModified;

  const UsbSafFile({
    required this.name,
    required this.uri,
    required this.size,
    required this.lastModified,
  });

  factory UsbSafFile.fromMap(Map<String, dynamic> m) => UsbSafFile(
        name: (m['name'] ?? '') as String,
        uri: (m['uri'] ?? '') as String,
        size: (m['size'] as num?)?.toInt() ?? 0,
        lastModified: (m['lastModified'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() => 'UsbSafFile($name, $size B, $uri)';
}
