// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Hilfsmethoden für Kontaktschlüssel-Zuordnungen.
abstract class ContactUtils {
  /// Prüft ob ein Kontaktname bereits einem anderen Chat zugeordnet ist.
  ///
  /// [contactName]: Der zu prüfende Name.
  /// [excludeChatId]: Die Chat-ID, die NICHT geprüft wird (leer = alle prüfen).
  ///
  /// Gibt den Namen des bereits belegten Chats zurück, oder null wenn frei.
  static Future<String?> findChatUsingContact(
    String contactName, {
    String excludeChatId = '',
  }) async {
    final trimmed = contactName.trim();
    if (trimmed.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    // chat_groups is stored as StringList, each entry is a JSON-encoded ChatGroup
    final groupsList = prefs.getStringList('chat_groups');
    if (groupsList == null) return null;
    for (final s in groupsList) {
      try {
        final map = jsonDecode(s) as Map<String, dynamic>;
        final id = (map['id'] as String?) ?? '';
        if (id.isEmpty || id == excludeChatId) continue;
        final assigned = (prefs.getString('chat_contact_$id') ?? '').trim();
        if (assigned.isNotEmpty &&
            assigned.toLowerCase() == trimmed.toLowerCase()) {
          return (map['name'] as String?) ?? id;
        }
      } catch (_) {}
    }
    return null;
  }
}
