// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart';
import 'rsa_encryption.dart';

/// Verwaltet RSA-Schlüssel für die Anwendung
class RSAKeyManager {
  static const String _publicKeyKey = 'rsa_public_key';
  static const String _privateKeyKey = 'rsa_private_key';
  static const String _contactKeysKey = 'rsa_contact_keys';
  
  final RSAEncryption _rsaEncryption = RSAEncryption();
  
  /// Generiert ein neues Schlüsselpaar und speichert es
  Future<void> generateAndSaveKeyPair() async {
    _rsaEncryption.generateKeyPair();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_publicKeyKey, _rsaEncryption.publicKeyToString());
    await prefs.setString(_privateKeyKey, _rsaEncryption.privateKeyToString());
  }
  
  /// Lädt das gespeicherte Schlüsselpaar
  Future<bool> loadKeyPair() async {
    final prefs = await SharedPreferences.getInstance();
    final publicKeyString = prefs.getString(_publicKeyKey);
    final privateKeyString = prefs.getString(_privateKeyKey);
    
    if (publicKeyString != null && privateKeyString != null) {
      try {
        _rsaEncryption.publicKeyFromString(publicKeyString);
        _rsaEncryption.privateKeyFromString(privateKeyString);
        return true;
      } catch (e) {
        return false;
      }
    }
    return false;
  }
  
  /// Gibt den eigenen öffentlichen Schlüssel zurück
  RSAPublicKey? getMyPublicKey() {
    try {
      return _rsaEncryption.publicKey;
    } catch (e) {
      return null;
    }
  }
  
  /// Gibt den eigenen privaten Schlüssel zurück
  RSAPrivateKey? getMyPrivateKey() {
    try {
      return _rsaEncryption.privateKey;
    } catch (e) {
      return null;
    }
  }
  
  /// Speichert den öffentlichen Schlüssel eines Kontakts
  Future<void> saveContactPublicKey(String contactName, RSAPublicKey publicKey) async {
    final prefs = await SharedPreferences.getInstance();
    final contactKeys = await getContactKeys();
    
    // Serialize the provided public key, not our own
    final serialized = jsonEncode({
      'modulus': publicKey.modulus.toString(),
      'exponent': publicKey.exponent.toString(),
    });
    contactKeys[contactName] = serialized;
    await prefs.setString(_contactKeysKey, jsonEncode(contactKeys));
  }
  
  /// Lädt den öffentlichen Schlüssel eines Kontakts
  Future<RSAPublicKey?> getContactPublicKey(String contactName) async {
    final contactKeys = await getContactKeys();
    final keyString = contactKeys[contactName];
    
    if (keyString != null) {
      try {
        return _rsaEncryption.publicKeyFromString(keyString);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
  
  /// Gibt alle gespeicherten Kontakt-Schlüssel zurück
  Future<Map<String, String>> getContactKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final contactKeysString = prefs.getString(_contactKeysKey);
    
    if (contactKeysString != null) {
      try {
        final decoded = jsonDecode(contactKeysString) as Map<String, dynamic>;
        return decoded.map((key, value) => MapEntry(key, value.toString()));
      } catch (e) {
        return {};
      }
    }
    return {};
  }
  
  /// Entfernt den Schlüssel eines Kontakts
  Future<void> removeContactKey(String contactName) async {
    final prefs = await SharedPreferences.getInstance();
    final contactKeys = await getContactKeys();
    
    contactKeys.remove(contactName);
    await prefs.setString(_contactKeysKey, jsonEncode(contactKeys));
  }
  
  /// Verschlüsselt eine Nachricht für einen Kontakt
  Future<String?> encryptMessageForContact(String message, String contactName) async {
    final contactKey = await getContactPublicKey(contactName);
    if (contactKey != null) {
      try {
        return _rsaEncryption.encryptWithPublicKey(message, contactKey);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
  
  /// Entschlüsselt eine empfangene Nachricht
  String? decryptReceivedMessage(String encryptedMessage) {
    final privateKey = getMyPrivateKey();
    if (privateKey != null) {
      try {
        return _rsaEncryption.decryptWithPrivateKey(encryptedMessage, privateKey);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
  
  /// Signiert eine Nachricht mit dem eigenen privaten Schlüssel
  String? signMessage(String message) {
    final privateKey = getMyPrivateKey();
    if (privateKey != null) {
      try {
        return _rsaEncryption.signText(message, privateKey);
      } catch (e) {
        return null;
      }
    }
    return null;
  }
  
  /// Verifiziert die Signatur einer Nachricht
  Future<bool> verifyMessageSignature(String message, String signature, String contactName) async {
    final contactKey = await getContactPublicKey(contactName);
    if (contactKey != null) {
      try {
        return _rsaEncryption.verifySignature(message, signature, contactKey);
      } catch (e) {
        return false;
      }
    }
    return false;
  }
  
  /// Erstellt einen QR-Code-String für den eigenen öffentlichen Schlüssel
  String? getPublicKeyQRCode() {
    try {
      return _rsaEncryption.getCompactPublicKey();
    } catch (e) {
      return null;
    }
  }
  
  /// Lädt einen öffentlichen Schlüssel aus einem QR-Code
  RSAPublicKey? loadPublicKeyFromQRCode(String qrData) {
    try {
      // Abwärtskompatibel: altes Präfix OBMC_RSA_PUB: weiterhin akzeptieren
      if (qrData.startsWith('QGAP_RSA_PUB:') || qrData.startsWith('OBMC_RSA_PUB:')) {
        // Fountain-Code-Format: QGAP_RSA_PUB:{"modulus":"...","exponent":"..."}
        final keyJson = qrData.substring(qrData.indexOf(':') + 1);
        return _rsaEncryption.publicKeyFromString(keyJson);
      }
      // Legacy: kompaktes base64-Format
      return _rsaEncryption.loadCompactPublicKey(qrData);
    } catch (e) {
      return null;
    }
  }
  
  /// Gibt den Fingerprint des eigenen öffentlichen Schlüssels zurück
  String? getMyPublicKeyFingerprint() {
    try {
      return _rsaEncryption.getPublicKeyFingerprint();
    } catch (e) {
      return null;
    }
  }
  
  /// Parst einen Public Key aus JSON-String und speichert ihn als Kontakt.
  /// Sicher: erzeugt kein Seiteneffekt auf den eigenen gespeicherten Schlüssel.
  Future<bool> saveContactPublicKeyFromJson(String contactName, String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final modulus  = BigInt.parse(data['modulus']  as String);
      final exponent = BigInt.parse(data['exponent'] as String);
      final key = RSAPublicKey(modulus, exponent);
      await saveContactPublicKey(contactName, key);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Prüft ob ein Schlüsselpaar existiert
  Future<bool> hasKeyPair() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_publicKeyKey) && prefs.containsKey(_privateKeyKey);
  }
  
  /// Löscht alle gespeicherten Schlüssel
  Future<void> clearAllKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_publicKeyKey);
    await prefs.remove(_privateKeyKey);
    await prefs.remove(_contactKeysKey);
  }
}
