// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

import 'rsa_encryption.dart';

/// Signierte Lese-Quittungen für die Offline-Welt.
///
/// Das Air-Gap-Gerät kann selbst keine Firestore-Schreibvorgänge auslösen.
/// Es signiert daher beim Lesen einer Nachricht einen kleinen JSON-Blob mit
/// seinem privaten Schlüssel; dieser Blob wird per QR/USB an das gepaarte
/// Online-Relay übergeben, das ihn als
/// `payloadType = FirestoreService.kPayloadTypeReadReceipt` (mit
/// `wrap = false`) an den ursprünglichen Absender weiterleitet. Der Absender
/// kann die Signatur mit dem ihm bekannten Public Key des Air-Gap-Geräts
/// verifizieren und erst dann das blaue Doppel-Häkchen setzen.
///
/// Format der Payload (UTF-8 JSON):
/// ```json
/// {
///   "v":       1,
///   "msgId":   "<original message id>",
///   "chatId":  "<firestore chat id, optional>",
///   "ts":      <unix-ms beim Lesen>,
///   "readerFp": "<sha256-fingerprint des signierenden Pubkeys>",
///   "sig":     "<base64 RSA-SHA256-Signatur über msgId|chatId|ts|readerFp>"
/// }
/// ```
class OfflineReceiptService {
  static const int version = 1;

  /// Erzeugt einen signierten Receipt-Blob (UTF-8-JSON, gzip-frei, klein).
  static Uint8List createReceipt({
    required String msgId,
    String? chatId,
    required String readerFingerprint,
    required pc.RSAPrivateKey readerPrivateKey,
    DateTime? readAt,
  }) {
    final ts = (readAt ?? DateTime.now()).millisecondsSinceEpoch;
    final canonical = '$msgId|${chatId ?? ''}|$ts|$readerFingerprint';
    final rsa = RSAEncryption();
    final sig = rsa.signText(canonical, readerPrivateKey);
    final payload = <String, dynamic>{
      'v': version,
      'msgId': msgId,
      if (chatId != null) 'chatId': chatId,
      'ts': ts,
      'readerFp': readerFingerprint,
      'sig': sig,
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  /// Verifiziert einen empfangenen Receipt-Blob mit dem [readerPublicKey]
  /// des erwarteten Air-Gap-Geräts. Liefert die geparsten Felder, wenn die
  /// Signatur passt – sonst `null`.
  static Map<String, dynamic>? verifyReceipt(
    Uint8List blob,
    pc.RSAPublicKey readerPublicKey,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(blob));
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['v'] != version) return null;
      final msgId = decoded['msgId'] as String?;
      final chatId = decoded['chatId'] as String?;
      final ts = decoded['ts'] as int?;
      final readerFp = decoded['readerFp'] as String?;
      final sig = decoded['sig'] as String?;
      if (msgId == null || ts == null || readerFp == null || sig == null) {
        return null;
      }
      final canonical = '$msgId|${chatId ?? ''}|$ts|$readerFp';
      final rsa = RSAEncryption();
      final ok = rsa.verifySignature(canonical, sig, readerPublicKey);
      if (!ok) return null;
      return decoded;
    } catch (_) {
      return null;
    }
  }
}
