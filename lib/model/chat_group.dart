// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'message.dart';

/// Transport-Modus eines Chats:
/// - [online]: Synchronisiert über Firestore (benötigt Funkverbindung).
/// - [offline]: Nur lokal/per Datei-Transfer, aber Gerät darf online sein.
/// - [airGap]: Strikt offline – Gerät hat keine Funkverbindungen, Übertragung
///   ausschließlich über externe Datenträger (USB, QR-Code).
enum ChatTransport {
  online,
  offline,
  airGap,
}

extension ChatTransportExt on ChatTransport {
  String get value {
    switch (this) {
      case ChatTransport.online:  return 'online';
      case ChatTransport.offline: return 'offline';
      case ChatTransport.airGap:  return 'airGap';
    }
  }

  static ChatTransport fromString(String? s) {
    switch (s) {
      case 'online':  return ChatTransport.online;
      case 'airGap':  return ChatTransport.airGap;
      case 'offline': return ChatTransport.offline;
      default:        return ChatTransport.offline;
    }
  }
}

class ChatGroup {
  final String id;
  final String name;
  final String description;
  final DateTime createdAt;
  final String iconEmoji;
  final int messageCount;
  final EncryptionType defaultEncryptionType;
  // ── Transport ───────────────────────────────────────────────────────────
  /// Transport-Modus: online (Firestore), offline (lokal), airGap (strikt isoliert).
  final ChatTransport transport;
  /// Zufällige 20-Zeichen-ID für Firestore (null wenn nicht online).
  final String? firestoreChatId;

  /// Backward-Compat: `true` wenn der Chat über Firestore läuft.
  bool get isOnlineEnabled => transport == ChatTransport.online;

  ChatGroup({
    required this.id,
    required this.name,
    required this.description,
    required this.createdAt,
    this.iconEmoji = '💬',
    this.messageCount = 0,
    this.defaultEncryptionType = EncryptionType.oneTimePad,
    ChatTransport? transport,
    bool? isOnlineEnabled,
    this.firestoreChatId,
  }) : transport = transport
            ?? (isOnlineEnabled == true ? ChatTransport.online : ChatTransport.offline);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'createdAt': createdAt.toIso8601String(),
      'iconEmoji': iconEmoji,
      'messageCount': messageCount,
      'defaultEncryptionType': defaultEncryptionType.toString(),
      'transport': transport.value,
      // Beibehalten für ältere Build-Versionen, die das Feld noch lesen.
      'isOnlineEnabled': isOnlineEnabled,
      'firestoreChatId': firestoreChatId,
    };
  }

  factory ChatGroup.fromJson(Map<String, dynamic> json) {
    final transportStr = json['transport'] as String?;
    final ChatTransport t;
    if (transportStr != null) {
      t = ChatTransportExt.fromString(transportStr);
    } else {
      // Migration: alte Einträge nutzten nur isOnlineEnabled-Bool
      t = (json['isOnlineEnabled'] == true)
          ? ChatTransport.online
          : ChatTransport.offline;
    }
    return ChatGroup(
      id: json['id'],
      name: json['name'],
      description: json['description'],
      createdAt: DateTime.parse(json['createdAt']),
      iconEmoji: json['iconEmoji'] ?? '💬',
      messageCount: json['messageCount'] ?? 0,
      defaultEncryptionType: EncryptionType.values.firstWhere(
        (e) => e.toString() == json['defaultEncryptionType'],
        orElse: () => EncryptionType.oneTimePad,
      ),
      transport: t,
      firestoreChatId: json['firestoreChatId'],
    );
  }

  ChatGroup copyWith({
    String? id,
    String? name,
    String? description,
    DateTime? createdAt,
    String? iconEmoji,
    int? messageCount,
    EncryptionType? defaultEncryptionType,
    ChatTransport? transport,
    bool? isOnlineEnabled,
    String? firestoreChatId,
  }) {
    final ChatTransport newTransport = transport
        ?? (isOnlineEnabled == null
            ? this.transport
            : (isOnlineEnabled ? ChatTransport.online : ChatTransport.offline));
    return ChatGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      iconEmoji: iconEmoji ?? this.iconEmoji,
      messageCount: messageCount ?? this.messageCount,
      defaultEncryptionType: defaultEncryptionType ?? this.defaultEncryptionType,
      transport: newTransport,
      firestoreChatId: firestoreChatId ?? this.firestoreChatId,
    );
  }
}
