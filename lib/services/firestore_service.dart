// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:pointycastle/export.dart' as pc;
import 'auth_service.dart';
import 'rsa_encryption.dart';

/// Cloud-Chat-Nachrichten-Typen
enum CloudMessageType {
  text,
  handshake,
  file,
  voice,
  offlineRelay,
  offlineRelayBtoA, // B→A: Relay B leitet Air-Gap-B-Nachricht an Relay A weiter
}

extension CloudMessageTypeExt on CloudMessageType {
  String get value {
    switch (this) {
      case CloudMessageType.text:         return 'text';
      case CloudMessageType.handshake:    return 'handshake';
      case CloudMessageType.file:         return 'file';
      case CloudMessageType.voice:        return 'voice';
      case CloudMessageType.offlineRelay:    return 'offline_relay';
      case CloudMessageType.offlineRelayBtoA: return 'offline_relay_btoa';
    }
  }

  static CloudMessageType fromString(String s) {
    switch (s) {
      case 'handshake':    return CloudMessageType.handshake;
      case 'file':         return CloudMessageType.file;
      case 'voice':        return CloudMessageType.voice;
      case 'offline_relay':      return CloudMessageType.offlineRelay;
      case 'offline_relay_btoa': return CloudMessageType.offlineRelayBtoA;
      default:                   return CloudMessageType.text;
    }
  }
}

/// Greift auf Firestore zu. Alle Methoden prüfen vorab ob der User eingeloggt ist.
/// Niemals werden Klarnamen in Firestore gespeichert – nur UIDs.
class FirestoreService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ─── Chat-Verwaltung ────────────────────────────────────────────────────

  /// Legt einen neuen Cloud-Chat an und trägt die eigene UID als Member ein.
  Future<void> createChat(String firestoreChatId) async {
    final uid = _requireUid();
    await _db.collection('chats').doc(firestoreChatId).set({
      'members': [uid],
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Tritt einem bestehenden Cloud-Chat bei (fügt eigene UID hinzu).
  Future<void> joinChat(String firestoreChatId) async {
    final uid = _requireUid();
    await _db.collection('chats').doc(firestoreChatId).update({
      'members': FieldValue.arrayUnion([uid]),
    });
  }

  /// Prüft ob ein Cloud-Chat existiert und die eigene UID darin ist.
  Future<bool> isMemberOf(String firestoreChatId) async {
    final uid = _requireUid();
    final doc = await _db.collection('chats').doc(firestoreChatId).get();
    if (!doc.exists) return false;
    final members = List<String>.from(doc.data()?['members'] ?? []);
    return members.contains(uid);
  }

  // ─── Nachrichten senden ─────────────────────────────────────────────────

  /// Sendet eine verschlüsselte Textnachricht (bereits verschlüsselt als Base64).
  Future<String?> sendMessage(
    String firestoreChatId,
    String encryptedText, {
    CloudMessageType type = CloudMessageType.text,
    String? attachmentName,
  }) async {
    final uid = _requireUid();
    final data = <String, dynamic>{
      'senderId': uid,
      'text': encryptedText,
      'type': type.value,
      'timestamp': FieldValue.serverTimestamp(),
    };
    if (attachmentName != null) {
      data['attachmentName'] = attachmentName;
    }
    final ref = await _db
        .collection('chats')
        .doc(firestoreChatId)
        .collection('messages')
        .add(data);
    return ref.id;
  }

  /// Sendet einen Handshake (eigene UID → Gegenstelle kann lokal einen Namen vergeben).
  Future<void> sendHandshake(String firestoreChatId) async {
    await sendMessage(
      firestoreChatId,
      '',
      type: CloudMessageType.handshake,
    );
  }

  /// Sendet den eigenen Public Key als Handshake-Nachricht zurück an den Einladenden.
  Future<void> sendPublicKeyHandshake(String firestoreChatId, String publicKeyJson) async {
    await sendMessage(
      firestoreChatId,
      publicKeyJson,
      type: CloudMessageType.handshake,
    );
  }

  /// Löscht eine einzelne Nachricht aus dem Chat (z. B. nach verarbeitetem Handshake).
  Future<void> deleteMessage(String firestoreChatId, String docId) async {
    await _db
        .collection('chats')
        .doc(firestoreChatId)
        .collection('messages')
        .doc(docId)
        .delete();
  }

  /// Markiert eine Nachricht als beim aktuellen User gelesen, indem die eigene
  /// UID im Feld `readBy` (Array) per `arrayUnion` ergänzt wird. Sender beobachten
  /// dieses Feld in ihrem `messagesStream` und stellen den Status auf "gelesen"
  /// (blaue Doppel-Häkchen).
  Future<void> markMessageRead(String firestoreChatId, String docId) async {
    final uid = _requireUid();
    try {
      await _db
          .collection('chats')
          .doc(firestoreChatId)
          .collection('messages')
          .doc(docId)
          .update({'readBy': FieldValue.arrayUnion([uid])});
    } catch (_) {
      // Stillschweigend ignorieren – Lese-Quittung ist Best-Effort.
    }
  }

  /// Sendet eine Nachricht als Offline-Relay (z. B. über Transfer Hub).
  Future<void> sendOfflineRelay(
      String firestoreChatId, String encryptedText, CloudMessageType type) async {
    await sendMessage(
      firestoreChatId,
      encryptedText,
      type: CloudMessageType.offlineRelay,
      attachmentName: type.value,
    );
  }

  // ─── Nachrichten empfangen ──────────────────────────────────────────────

  /// Stream der letzten [pageSize] Nachrichten, optional ab einem Cursor-Snapshot.
  Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(
    String firestoreChatId, {
    DocumentSnapshot? startAfter,
    int pageSize = 20,
  }) {
    var query = _db
        .collection('chats')
        .doc(firestoreChatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .limitToLast(pageSize);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    return query.snapshots();
  }

  /// Lädt ältere Seiten (Pagination rückwärts in der Zeit).
  Future<QuerySnapshot<Map<String, dynamic>>> loadOlderMessages(
    String firestoreChatId,
    DocumentSnapshot beforeDoc, {
    int pageSize = 20,
  }) {
    return _db
        .collection('chats')
        .doc(firestoreChatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .endBeforeDocument(beforeDoc)
        .limitToLast(pageSize)
        .get();
  }

  // ─── Connectivity ────────────────────────────────────────────────────────

  /// Gibt true zurück wenn eine Netzwerkverbindung besteht.
  Future<bool> isReachable() async {
    final result = await Connectivity().checkConnectivity();
    return !result.contains(ConnectivityResult.none);
  }

  // ─── Hilfsmethoden ──────────────────────────────────────────────────────

  String _requireUid() {
    final uid = AuthService.currentUid;
    if (uid == null) throw StateError('Nicht eingeloggt – AuthService.ensureLoggedIn() zuerst aufrufen.');
    return uid;
  }

  // ─── User-Transfer (E2E-verschlüsselt über `transfers/`) ────────────────

  /// Maximale Größe einer Transfer-Payload (Klartext-Bytes, vor Verschlüsselung).
  static const int kMaxTransferBytes = 300 * 1024; // 300 KB

  /// `payloadType`-Konstante für Blobs, die bereits Ende-zu-Ende verschlüsselt
  /// sind (z. B. EC-OTP vom Air-Gap-Gerät). Der Online-Relay schickt diesen
  /// Blob roh ohne zusätzliche Hybrid-Schicht durch. Der Empfänger erkennt
  /// am `payloadType`, dass er den Klartext erst nach Pickup durch sein
  /// eigenes Air-Gap-Gerät entschlüsseln kann.
  static const String kPayloadTypeRelayPreencrypted = 'qgap_relay_preencrypted';

  /// `payloadType`-Konstante für Relay-Pairing-ACKs (Online B → Relay A).
  /// Payload ist ein UTF-8-JSON `{"chatGroupId": ..., "senderUid": ...}`.
  static const String kPayloadTypeRelayPairAck = 'qgap_relay_pair_ack';

  /// `payloadType`-Konstante für B→A Relay-Nachrichten (Online B → Relay A).
  /// Payload ist ein vorverschlüsselter QGap-Inner-Envelope, den Relay A
  /// in die Pickup-Queue für Air-Gap A stellt.
  static const String kPayloadTypeRelayBtoA = 'qgap_relay_b_to_a';

  /// `payloadType`-Konstante für signierte Lese-Quittungen vom Air-Gap-Gerät.
  /// Die Payload ist ein UTF-8-JSON `{ "msgId": ..., "ts": ..., "sig": ... }`,
  /// signiert mit dem Private Key des Air-Gap-Geräts.
  static const String kPayloadTypeReadReceipt = 'qgap_read_receipt';

  /// Sendet eine beliebige Datei/Payload Ende-zu-Ende-verschlüsselt an einen
  /// anderen User (per Firestore-Collection `transfers/`).
  ///
  /// Standardmäßig wird hybrid verschlüsselt: AES-GCM für die Payload, RSA für
  /// den AES-Key. Über [wrap] kann dieser Schritt deaktiviert werden, wenn die
  /// Payload bereits Ende-zu-Ende verschlüsselt ist (z. B. ein vom Air-Gap-
  /// Gerät vorbereiteter EC-OTP-Blob, den der Online-Relay nur durchreicht).
  /// In diesem Fall darf [receiverPublicKeyJson] `null` sein.
  ///
  /// [receiverUid]              UID des Empfänger-Accounts (Auth UID).
  /// [receiverPublicKeyJson]    Public Key des Empfängers im JSON-Format
  ///                            (`{"modulus":"...","exponent":"..."}`),
  ///                            wie von `RSAEncryption.publicKeyToString()`
  ///                            erzeugt.
  /// [encryptionType]           Art der Original-Verschlüsselung der Payload
  ///                            (z. B. `aes`, `rsa`, `hybrid`, `QGAP_ec`).
  /// [payloadType]              Inhaltstyp (`QGAP_chat_invite`, `QGAP_ec_key`,
  ///                            `QGAP_file`, `text`).
  /// [fileName]                 Original-Dateiname (Anzeige).
  /// [payloadBytes]             Roh-Bytes (max. 300 KB).
  /// [senderIsOffline]          true, wenn der Absender ein Air-Gap-/Offline-
  ///                            Gerät ist und die Datei nur via Transfer-Hub
  ///                            herausgereicht wird → wird in der Anzeige beim
  ///                            Empfänger 3× als sichere Übertragung markiert.
  /// [firestoreChatId]          Optional: zugehöriger Cloud-Chat (zur Routung
  ///                            beim Empfänger).
  ///
  /// [relayHadKeyFile]         Optional: true, wenn das Relay-Phone beim
  ///                            Weiterleiten die Schlüsseldatei lokal hatte
  ///                            (Sicherheitswarnung für Empfänger).
  ///
  /// Wirft, wenn `payloadBytes.length > kMaxTransferBytes`.
  Future<String> sendUserTransfer({
    required String receiverUid,
    String? receiverPublicKeyJson,
    required String encryptionType,
    required String payloadType,
    required String fileName,
    required Uint8List payloadBytes,
    bool senderIsOffline = false,
    bool wrap = true,
    String? firestoreChatId,
    bool relayHadKeyFile = false,
  }) async {
    if (payloadBytes.length > kMaxTransferBytes) {
      throw StateError(
        'Payload zu groß: ${payloadBytes.length} Bytes (max $kMaxTransferBytes).',
      );
    }
    final senderUid = _requireUid();

    // ── Pfad A: Vorverschlüsselter Blob (Relay-Modus) ───────────────────────
    if (!wrap) {
      final data = <String, dynamic>{
        'version': 1,
        'kind': 'QGAP_transfer',
        'senderUid': senderUid,
        'receiverUid': receiverUid,
        'encryptionType': encryptionType,
        'payloadType': payloadType,
        'fileName': fileName,
        'senderIsOffline': senderIsOffline,
        'preencrypted': true,
        if (firestoreChatId != null) 'firestoreChatId': firestoreChatId,
        if (relayHadKeyFile) 'relayHadKeyFile': true,
        'cipher': base64.encode(payloadBytes),
        'createdAt': FieldValue.serverTimestamp(),
      };
      final ref = await _db.collection('transfers').add(data);
      return ref.id;
    }

    // ── Pfad B: Hybrid-verschlüsselt (Standard) ─────────────────────────────
    if (receiverPublicKeyJson == null) {
      throw ArgumentError(
          'receiverPublicKeyJson ist erforderlich, wenn wrap=true.');
    }

    // Receiver-Public-Key laden
    final rsa = RSAEncryption();
    final receiverPubKey = rsa.publicKeyFromString(receiverPublicKeyJson);

    // AES-256 Schlüssel + 96-Bit-IV erzeugen
    final rnd = Random.secure();
    final aesKey = Uint8List.fromList(
        List<int>.generate(32, (_) => rnd.nextInt(256)));
    final iv = Uint8List.fromList(
        List<int>.generate(12, (_) => rnd.nextInt(256)));

    // AES-GCM verschlüsseln
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    cipher.init(
      true,
      pc.AEADParameters(
        pc.KeyParameter(aesKey),
        128,
        iv,
        Uint8List(0),
      ),
    );
    final cipherBytesWithTag = cipher.process(payloadBytes);

    // AES-Key per RSA an Empfänger einwickeln
    final encKeyRsaB64 =
        rsa.encryptWithPublicKey(base64.encode(aesKey), receiverPubKey);

    final data = <String, dynamic>{
      'version': 1,
      'kind': 'QGAP_transfer',
      'senderUid': senderUid,
      'receiverUid': receiverUid,
      'encryptionType': encryptionType,
      'payloadType': payloadType,
      'fileName': fileName,
      'senderIsOffline': senderIsOffline,
      if (firestoreChatId != null) 'firestoreChatId': firestoreChatId,
      'encKey': encKeyRsaB64,
      'iv': base64.encode(iv),
      'cipher': base64.encode(cipherBytesWithTag),
      'createdAt': FieldValue.serverTimestamp(),
    };

    final ref = await _db.collection('transfers').add(data);
    return ref.id;
  }

  /// Stream aller eingehenden Transfers für den aktuellen User.
  Stream<QuerySnapshot<Map<String, dynamic>>> incomingTransfersStream() {
    final uid = _requireUid();
    return _db
        .collection('transfers')
        .where('receiverUid', isEqualTo: uid)
        .snapshots();
  }

  /// Entschlüsselt eine empfangene Transfer-Payload mit dem privaten
  /// Schlüssel des aktuellen Users (per `RSAEncryption`-Instanz).
  ///
  /// Erwartet die Map aus `doc.data()` der `transfers/`-Collection.
  /// Wirft bei Format- oder Crypto-Fehlern.
  Uint8List decryptUserTransfer(
    Map<String, dynamic> data,
    pc.RSAPrivateKey privateKey,
  ) {
    final encKeyRsaB64 = data['encKey'] as String?;
    final ivB64        = data['iv'] as String?;
    final cipherB64    = data['cipher'] as String?;
    if (encKeyRsaB64 == null || ivB64 == null || cipherB64 == null) {
      throw StateError('Transfer-Dokument unvollständig (encKey/iv/cipher fehlen).');
    }
    final rsa = RSAEncryption();
    final aesKeyBase64 = rsa.decryptWithPrivateKey(encKeyRsaB64, privateKey);
    final aesKey = Uint8List.fromList(base64.decode(aesKeyBase64));
    final iv = Uint8List.fromList(base64.decode(ivB64));
    final cipherWithTag = Uint8List.fromList(base64.decode(cipherB64));

    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    cipher.init(
      false,
      pc.AEADParameters(
        pc.KeyParameter(aesKey),
        128,
        iv,
        Uint8List(0),
      ),
    );
    return cipher.process(cipherWithTag);
  }

  /// Löscht einen verarbeiteten Transfer (Empfänger ruft auf, sobald importiert).
  Future<void> deleteTransfer(String transferId) async {
    await _db.collection('transfers').doc(transferId).delete();
  }
}
