// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

class Message {
  final String text; // Verschlüsselter Text
  final String originalText; // Ursprünglicher, unverschlüsselter Text
  final bool isMe;
  final DateTime timestamp;
  final String id;
  final String? keyFileName; // Name der verwendeten .qgap Datei
  final int? byteOffset; // Byte-Offset beim Verschlüsseln
  final EncryptionType encryptionType; // Art der Verschlüsselung
  final String? signature; // RSA-Signatur (falls vorhanden)
  final bool isSignatureValid; // Status der Signatur-Verifikation
  final MessageType messageType; // Text- oder Datei-Nachricht
  final String? attachmentFileName; // Originaldateiname (z.B. "foto.jpg")
  final String? attachmentLocalPath; // Lokaler Speicherpfad (Empfänger)
  final int? attachmentSize; // Dateigröße in Bytes
  final MessageDeliveryStatus deliveryStatus; // WhatsApp-artige Status-Häkchen

  Message({
    required this.text,
    required this.originalText,
    required this.timestamp,
    required this.isMe, 
    required this.id,
    this.keyFileName,
    this.byteOffset,
    this.encryptionType = EncryptionType.oneTimePad,
    this.signature,
    this.isSignatureValid = false,
    this.messageType = MessageType.text,
    this.attachmentFileName,
    this.attachmentLocalPath,
    this.attachmentSize,
    this.deliveryStatus = MessageDeliveryStatus.sent,
  });

  /// Factory-Konstruktor für JSON-Deserialisierung
  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      text: json['text'] ?? '',
      originalText: json['originalText'] ?? '',
      isMe: json['isMe'] ?? false,
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] ?? 0),
      id: json['id'] ?? '',
      keyFileName: json['keyFileName'],
      byteOffset: json['byteOffset'],
      encryptionType: EncryptionType.values.firstWhere(
        (e) => e.toString() == json['encryptionType'],
        orElse: () => EncryptionType.oneTimePad,
      ),
      signature: json['signature'],
      isSignatureValid: json['isSignatureValid'] ?? false,
      messageType: MessageType.values.firstWhere(
        (e) => e.toString() == json['messageType'],
        orElse: () => MessageType.text,
      ),
      attachmentFileName: json['attachmentFileName'],
      attachmentLocalPath: json['attachmentLocalPath'],
      attachmentSize: json['attachmentSize'],
      deliveryStatus: MessageDeliveryStatus.values.firstWhere(
        (e) => e.toString() == json['deliveryStatus'],
        orElse: () => MessageDeliveryStatus.sent,
      ),
    );
  }

  /// Konvertiert Message zu JSON
  Map<String, dynamic> toJson() {
    return {
      'text': text,
      'originalText': originalText,
      'isMe': isMe,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'id': id,
      'keyFileName': keyFileName,
      'byteOffset': byteOffset,
      'encryptionType': encryptionType.toString(),
      'signature': signature,
      'isSignatureValid': isSignatureValid,
      'messageType': messageType.toString(),
      'attachmentFileName': attachmentFileName,
      'attachmentLocalPath': attachmentLocalPath,
      'attachmentSize': attachmentSize,
      'deliveryStatus': deliveryStatus.toString(),
    };
  }

  /// Erstellt eine Kopie mit geänderten Eigenschaften
  Message copyWith({
    String? text,
    String? originalText,
    bool? isMe,
    DateTime? timestamp,
    String? id,
    String? keyFileName,
    int? byteOffset,
    EncryptionType? encryptionType,
    String? signature,
    bool? isSignatureValid,
    MessageType? messageType,
    String? attachmentFileName,
    String? attachmentLocalPath,
    int? attachmentSize,
    MessageDeliveryStatus? deliveryStatus,
  }) {
    return Message(
      text: text ?? this.text,
      originalText: originalText ?? this.originalText,
      isMe: isMe ?? this.isMe,
      timestamp: timestamp ?? this.timestamp,
      id: id ?? this.id,
      keyFileName: keyFileName ?? this.keyFileName,
      byteOffset: byteOffset ?? this.byteOffset,
      encryptionType: encryptionType ?? this.encryptionType,
      signature: signature ?? this.signature,
      isSignatureValid: isSignatureValid ?? this.isSignatureValid,
      messageType: messageType ?? this.messageType,
      attachmentFileName: attachmentFileName ?? this.attachmentFileName,
      attachmentLocalPath: attachmentLocalPath ?? this.attachmentLocalPath,
      attachmentSize: attachmentSize ?? this.attachmentSize,
      deliveryStatus: deliveryStatus ?? this.deliveryStatus,
    );
  }
}

/// Nachrichtentyp: Text, Dateianhang oder Sprachnachricht
enum MessageType { text, file, voice }

/// Zustellstatus einer eigenen Nachricht (WhatsApp-artige Häkchen).
/// - [sending]   = wird gerade verschickt (Uhr-Symbol)
/// - [sent]      = lokal erstellt / per QR generiert (1 graues Häkchen)
/// - [delivered] = bei Online-Chats: in Firestore angekommen (2 graue Häkchen)
/// - [read]      = Empfänger hat die Nachricht im Chat gesehen (2 blaue Häkchen)
enum MessageDeliveryStatus { sending, sent, delivered, read }

/// Verschiedene Verschlüsselungsarten
enum EncryptionType {
  oneTimePad,    // One-Time-Pad (QGap-Dateien)
  rsa,           // RSA-Verschlüsselung
  hybrid,        // Hybrid: RSA + AES
  relayForward,  // Relay-Weiterleitung: keine eigene Entschlüsselung (Relay-Phone)
}