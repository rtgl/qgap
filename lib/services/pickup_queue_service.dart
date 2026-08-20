// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:qgap/services/app_storage.dart';

/// Verwaltet die "Offline-Pickup-Queue" des Online-Relays.
///
/// In diese Queue wandern eingehende Firestore-Transfers, die das Relay nicht
/// selbst entschlüsseln kann (z. B. `payloadType = QGAP_relay_preencrypted`,
/// oder allgemein jede Datei, deren Hybrid-/RSA-Entschlüsselung
/// fehlschlägt). Der Anwender kann diese Einträge im Transfer-Hub einsehen
/// und per QR-Code oder USB an das gepaarte Air-Gap-Gerät übergeben.
///
/// Speicherort der rohen Blobs:
/// `<AppStorage.pickupQueueDir>/<docId>.blob`
///
/// Metadaten werden zusätzlich in `SharedPreferences` unter dem Key
/// `pickup_queue_entries` als JSON-Array abgelegt, damit die Liste nach App-
/// Neustart erhalten bleibt.
class PickupQueueService {
  static const String _prefsKey = 'pickup_queue_entries';
  static String get _kDir => AppStorage.pickupQueueDir;

  /// Fügt einen neuen Eintrag in die Queue ein. [transferDocId] ist die
  /// Firestore-Dokument-ID; sie wird genutzt, um Duplikate zu erkennen
  /// (idempotent).
  static Future<void> enqueue({
    required String transferDocId,
    required String senderUid,
    required String fileName,
    required String encryptionType,
    required String payloadType,
    required Uint8List blob,
    String? firestoreChatId,
    String? reason,
  }) async {
    final entries = await loadEntries();
    if (entries.any((e) => e.transferDocId == transferDocId)) {
      // Bereits in der Queue – Blob aber neu schreiben (falls verloren).
      await _writeBlob(transferDocId, blob);
      return;
    }
    await _writeBlob(transferDocId, blob);
    entries.add(PickupQueueEntry(
      transferDocId: transferDocId,
      senderUid: senderUid,
      fileName: fileName,
      encryptionType: encryptionType,
      payloadType: payloadType,
      firestoreChatId: firestoreChatId,
      reason: reason ?? 'Nicht entschlüsselbar',
      enqueuedAtMs: DateTime.now().millisecondsSinceEpoch,
      sizeBytes: blob.length,
    ));
    await _saveEntries(entries);
  }

  static Future<List<PickupQueueEntry>> loadEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey) ?? const [];
    return raw
        .map((s) {
          try {
            return PickupQueueEntry.fromJson(
                jsonDecode(s) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<PickupQueueEntry>()
        .toList();
  }

  static Future<void> _saveEntries(List<PickupQueueEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      entries.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  static Future<Uint8List?> readBlob(String transferDocId) async {
    final f = File('$_kDir/$transferDocId.blob');
    if (!await f.exists()) return null;
    return f.readAsBytes();
  }

  /// Entfernt einen Eintrag (z. B. nach erfolgreicher Übergabe an das
  /// Air-Gap-Gerät) und löscht die Blob-Datei.
  static Future<void> remove(String transferDocId) async {
    final entries = await loadEntries();
    entries.removeWhere((e) => e.transferDocId == transferDocId);
    await _saveEntries(entries);
    try {
      final f = File('$_kDir/$transferDocId.blob');
      if (await f.exists()) await f.delete();
    } catch (_) {/* ignore */}
  }

  static Future<void> _writeBlob(String transferDocId, Uint8List blob) async {
    final dir = Directory(_kDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final f = File('$dir/$transferDocId.blob');
    await f.writeAsBytes(blob, flush: true);
  }

  static Future<int> count() async => (await loadEntries()).length;
}

/// Metadaten eines Eintrags in der Offline-Pickup-Queue.
class PickupQueueEntry {
  final String transferDocId;
  final String senderUid;
  final String fileName;
  final String encryptionType;
  final String payloadType;
  final String? firestoreChatId;
  final String reason;
  final int enqueuedAtMs;
  final int sizeBytes;

  const PickupQueueEntry({
    required this.transferDocId,
    required this.senderUid,
    required this.fileName,
    required this.encryptionType,
    required this.payloadType,
    required this.firestoreChatId,
    required this.reason,
    required this.enqueuedAtMs,
    required this.sizeBytes,
  });

  DateTime get enqueuedAt =>
      DateTime.fromMillisecondsSinceEpoch(enqueuedAtMs);

  Map<String, dynamic> toJson() => {
        'transferDocId': transferDocId,
        'senderUid': senderUid,
        'fileName': fileName,
        'encryptionType': encryptionType,
        'payloadType': payloadType,
        'firestoreChatId': firestoreChatId,
        'reason': reason,
        'enqueuedAtMs': enqueuedAtMs,
        'sizeBytes': sizeBytes,
      };

  factory PickupQueueEntry.fromJson(Map<String, dynamic> m) =>
      PickupQueueEntry(
        transferDocId: m['transferDocId'] as String,
        senderUid: (m['senderUid'] as String?) ?? '',
        fileName: (m['fileName'] as String?) ?? 'unbekannt',
        encryptionType:
            (m['encryptionType'] as String?) ?? 'unknown',
        payloadType: (m['payloadType'] as String?) ?? 'unknown',
        firestoreChatId: m['firestoreChatId'] as String?,
        reason: (m['reason'] as String?) ?? 'Nicht entschlüsselbar',
        enqueuedAtMs: (m['enqueuedAtMs'] as int?) ?? 0,
        sizeBytes: (m['sizeBytes'] as int?) ?? 0,
      );
}
