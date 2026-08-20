// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_service.dart';

/// Speichert lokale Anzeigenamen für Firebase-UIDs.
/// Niemals werden Klarnamen in die Cloud übertragen – sie bleiben rein lokal.
class LocalContactService {
  static const String _prefPrefix = 'contact_uid_';

  // ─── Name speichern / lesen ─────────────────────────────────────────────

  /// Speichert einen lokalen Anzeigenamen für eine Firebase-UID.
  static Future<void> saveLocalName(String uid, String displayName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefPrefix$uid', displayName);
  }

  /// Liest den lokalen Anzeigenamen für eine Firebase-UID.
  /// Gibt [fallback] zurück wenn kein Name gespeichert ist.
  static Future<String> getLocalName(String uid,
      {String fallback = 'Unbekannt'}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefPrefix$uid') ?? fallback;
  }

  /// Gibt alle gespeicherten UID→Name Paare zurück (für Backup).
  static Future<Map<String, String>> getAllContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_prefPrefix)) {
        final uid = key.substring(_prefPrefix.length);
        result[uid] = prefs.getString(key)!;
      }
    }
    return result;
  }

  /// Stellt alle Kontakte aus einem Map wieder her (nach Backup-Import).
  static Future<void> restoreContacts(Map<String, String> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    for (final entry in contacts.entries) {
      await prefs.setString('$_prefPrefix${entry.key}', entry.value);
    }
  }

  /// Löscht einen gespeicherten Kontaktnamen.
  static Future<void> removeLocalName(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefPrefix$uid');
  }

  // ─── Handshake-Verarbeitung ─────────────────────────────────────────────

  /// Filtert Handshake-Nachrichten aus einem Firestore-Snapshot heraus.
  /// Gibt die UIDs der Absender zurück, die noch keinen lokalen Namen haben.
  static Future<List<String>> processHandshakes(
      QuerySnapshot<Map<String, dynamic>> snapshot) async {
    final prefs = await SharedPreferences.getInstance();
    final newUids = <String>[];
    for (final doc in snapshot.docs) {
      final data = doc.data();
      final type = CloudMessageTypeExt.fromString(data['type'] ?? 'text');
      if (type != CloudMessageType.handshake) continue;
      final senderUid = data['senderId'] as String? ?? '';
      if (senderUid.isEmpty) continue;
      // Nur melden wenn noch kein Name vergeben wurde
      if (!prefs.containsKey('$_prefPrefix$senderUid')) {
        newUids.add(senderUid);
      }
    }
    return newUids;
  }

  /// Gibt true zurück wenn für die UID bereits ein lokaler Name existiert.
  static Future<bool> hasLocalName(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('$_prefPrefix$uid');
  }
}
