// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Ein Relay-Mapping verbindet einen lokalen Chat (chatGroupId) auf dem
/// Relay-Phone mit:
///  - dem EC-Code des zugehörigen One-Time-Pad-Schlüssels (ecCode)
///  - der Firebase-UID des Online-Empfängers (destUid, gesetzt nach ACK)
///
/// Das Relay-Phone speichert diese Mappings dauerhaft in SharedPreferences
/// unter dem Schlüssel `relay_map_<chatGroupId>`.
///
/// Workflow:
///  1. Air-Gap A zeigt Pairing-Request-QR → Relay A speichert Mapping ohne destUid
///  2. Relay A sendet Einladung an Online B
///  3. Online B sendet ACK via Firestore → Relay A setzt destUid
///  4. Relay A zeigt Config-QR für Air-Gap A
class RelayMapping {
  final String chatGroupId;
  final String ecCode;
  final String? destUid;          // Firebase-UID von Online B (null bis ACK)
  final String? firestoreChatId;  // Firestore-Chat-ID (erstellt von Relay A)
  final bool pairingComplete;
  final int createdAtMs;

  const RelayMapping({
    required this.chatGroupId,
    required this.ecCode,
    this.destUid,
    this.firestoreChatId,
    this.pairingComplete = false,
    required this.createdAtMs,
  });

  RelayMapping copyWith({
    String? destUid,
    String? firestoreChatId,
    bool? pairingComplete,
  }) {
    return RelayMapping(
      chatGroupId: chatGroupId,
      ecCode: ecCode,
      destUid: destUid ?? this.destUid,
      firestoreChatId: firestoreChatId ?? this.firestoreChatId,
      pairingComplete: pairingComplete ?? this.pairingComplete,
      createdAtMs: createdAtMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'chatGroupId': chatGroupId,
        'ecCode': ecCode,
        if (destUid != null) 'destUid': destUid,
        if (firestoreChatId != null) 'firestoreChatId': firestoreChatId,
        'pairingComplete': pairingComplete,
        'createdAtMs': createdAtMs,
      };

  factory RelayMapping.fromJson(Map<String, dynamic> json) => RelayMapping(
        chatGroupId: json['chatGroupId'] as String,
        ecCode: (json['ecCode'] as String?) ?? '',
        destUid: json['destUid'] as String?,
        firestoreChatId: json['firestoreChatId'] as String?,
        pairingComplete: json['pairingComplete'] as bool? ?? false,
        createdAtMs: json['createdAtMs'] as int? ?? 0,
      );
}

class RelayMappingService {
  static const String _prefix = 'relay_map_';

  /// Speichert oder überschreibt ein Relay-Mapping.
  static Future<void> save(RelayMapping mapping) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_prefix${mapping.chatGroupId}',
      jsonEncode(mapping.toJson()),
    );
  }

  /// Lädt ein Mapping für [chatGroupId]. Gibt null zurück wenn keines existiert.
  static Future<RelayMapping?> load(String chatGroupId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$chatGroupId');
    if (raw == null) return null;
    try {
      return RelayMapping.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Gibt alle gespeicherten Relay-Mappings zurück.
  static Future<List<RelayMapping>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final result = <RelayMapping>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      final raw = prefs.getString(key);
      if (raw == null) continue;
      try {
        result.add(RelayMapping.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {}
    }
    return result;
  }

  /// Löscht das Mapping für [chatGroupId].
  static Future<void> delete(String chatGroupId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$chatGroupId');
  }

  /// Löscht alle Mappings für [chatGroupIds] die nicht in [existingIds] sind.
  static Future<int> cleanupOrphaned(Set<String> existingIds) async {
    final prefs = await SharedPreferences.getInstance();
    int removed = 0;
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith(_prefix)) continue;
      final id = key.substring(_prefix.length);
      if (!existingIds.contains(id)) {
        await prefs.remove(key);
        removed++;
      }
    }
    return removed;
  }

  /// Setzt [destUid] und markiert [pairingComplete] = true für [chatGroupId].
  /// Tut nichts wenn kein Mapping existiert.
  static Future<RelayMapping?> confirmAck({
    required String chatGroupId,
    required String destUid,
  }) async {
    final existing = await load(chatGroupId);
    if (existing == null) return null;
    final updated = existing.copyWith(destUid: destUid, pairingComplete: true);
    await save(updated);
    return updated;
  }
}
