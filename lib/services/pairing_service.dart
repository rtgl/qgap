// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fortschrittsgrad des Pairings auf diesem Gerät.
enum PairingCompleteness {
  /// Noch kein Pairing begonnen.
  none,
  /// Eigene Daten gesendet, Partner-QR noch nicht gescannt.
  sentOnly,
  /// Partner-QR gescannt – Pairing auf diesem Gerät vollständig.
  complete,
}

/// Speichert die Pairing-Beziehung zwischen einem Online-Relay und einem
/// Air-Gap-Gerät.
///
/// Beide Seiten speichern dieselben Felder. Die Bedeutung der Felder ist
/// asymmetrisch:
///
/// - **Online-Relay** speichert:
///   - `partnerPublicKeyJson` – Public Key des Air-Gap-Geräts
///   - `partnerFingerprint`   – SHA-256-Fingerprint dieses Keys
///   - `partnerDisplayName`   – lokaler Anzeigename des Air-Gap-Geräts
///                              (verlässt nie das Gerät)
///   - `myFingerprint`        – Fingerprint des eigenen Public Keys (Online)
///   - `pairedAt`             – Zeitstempel der Kopplung (ms epoch)
///
/// - **Air-Gap-Gerät** speichert die spiegelbildliche Sicht: der Online-Relay
///   ist hier `partner...`, der Online-Relay hat zusätzlich `partnerOnlineUid`,
///   damit das Air-Gap-Gerät weiß, an welche UID seine signierten Receipts
///   adressiert werden müssen.
///
/// Niemals werden Display-Namen oder Public Keys in Firestore geschrieben.
class PairingService {
  static const String _kPartnerPubKey      = 'pairing_partner_pubkey_json';
  static const String _kPartnerFingerprint = 'pairing_partner_fingerprint';
  static const String _kPartnerDisplayName = 'pairing_partner_display_name';
  static const String _kPartnerOnlineUid   = 'pairing_partner_online_uid';
  static const String _kMyFingerprint      = 'pairing_my_fingerprint';
  static const String _kPairedAt           = 'pairing_paired_at_ms';
  static const String _kOwnDataSentAt      = 'pairing_own_data_sent_at_ms';

  /// SHA-256-Fingerprint eines Public Keys, formatiert als
  /// `aa:bb:cc:dd:ee:ff:gg:hh:ii:jj:kk:ll:mm:nn:oo:pp` (16-Byte-Hex, Hex-Paare
  /// durch Doppelpunkt getrennt). Akzeptiert sowohl JSON-Format
  /// (`{"modulus":...,"exponent":...}`) als auch beliebige Bytes.
  static String computeFingerprint(String publicKeyJson) {
    final bytes = Uint8List.fromList(utf8.encode(publicKeyJson));
    final digest = SHA256Digest().process(bytes);
    final first16 = digest.sublist(0, 16);
    return first16
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':');
  }

  /// Speichert eine neue Pairing-Beziehung. Alle Felder außer
  /// [partnerOnlineUid] sind erforderlich.
  static Future<void> savePairing({
    required String partnerPublicKeyJson,
    required String partnerDisplayName,
    required String myFingerprint,
    String? partnerOnlineUid,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final fp = computeFingerprint(partnerPublicKeyJson);
    await prefs.setString(_kPartnerPubKey, partnerPublicKeyJson);
    await prefs.setString(_kPartnerFingerprint, fp);
    await prefs.setString(_kPartnerDisplayName, partnerDisplayName);
    await prefs.setString(_kMyFingerprint, myFingerprint);
    if (partnerOnlineUid != null) {
      await prefs.setString(_kPartnerOnlineUid, partnerOnlineUid);
    }
    await prefs.setInt(_kPairedAt, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<bool> isPaired() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_kPartnerPubKey) ?? '').isNotEmpty;
  }

  static Future<String?> getPartnerPublicKeyJson() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPartnerPubKey);
  }

  static Future<String?> getPartnerFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPartnerFingerprint);
  }

  static Future<String?> getPartnerDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPartnerDisplayName);
  }

  static Future<String?> getPartnerOnlineUid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPartnerOnlineUid);
  }

  static Future<String?> getMyFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMyFingerprint);
  }

  static Future<DateTime?> getPairedAt() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_kPairedAt);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Löscht alle Pairing-Daten.
  static Future<void> clearPairing() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPartnerPubKey);
    await prefs.remove(_kPartnerFingerprint);
    await prefs.remove(_kPartnerDisplayName);
    await prefs.remove(_kPartnerOnlineUid);
    await prefs.remove(_kMyFingerprint);
    await prefs.remove(_kPairedAt);
    await prefs.remove(_kOwnDataSentAt);
  }

  /// Markiert, dass dieses Gerät seine eigenen Pairing-Daten per QR gesendet hat.
  static Future<void> markOwnDataSent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOwnDataSentAt, DateTime.now().millisecondsSinceEpoch);
  }

  /// Gibt zurück, ob dieses Gerät seine eigenen Daten bereits gesendet hat.
  static Future<bool> hasOwnDataSent() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_kOwnDataSentAt) ?? 0) > 0;
  }

  /// Gibt den aktuellen Pairing-Fortschritt zurück.
  static Future<PairingCompleteness> getCompleteness() async {
    if (await isPaired()) return PairingCompleteness.complete;
    if (await hasOwnDataSent()) return PairingCompleteness.sentOnly;
    return PairingCompleteness.none;
  }

  /// Liefert eine kurze Status-Zusammenfassung für die UI.
  static Future<String> describeStatus() async {
    if (!await isPaired()) return 'Kein Pairing aktiv';
    final name = await getPartnerDisplayName() ?? '(unbenannt)';
    final fp = await getPartnerFingerprint() ?? '?';
    return 'Gepaart mit "$name"\nFingerprint: $fp';
  }
}
