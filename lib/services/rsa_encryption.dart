// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart';

/// RSA-Verschlüsselungsklasse für sichere Kommunikation
class RSAEncryption {
  late RSAPublicKey _publicKey;
  late RSAPrivateKey _privateKey;
  
  // Getter für die Schlüssel
  RSAPublicKey get publicKey => _publicKey;
  RSAPrivateKey get privateKey => _privateKey;
  
  /// Generiert ein neues RSA-Schlüsselpaar (2048 Bit)
  void generateKeyPair() {
    final keyGen = RSAKeyGenerator();
    final secureRandom = FortunaRandom();
    
    // Seed für den Zufallsgenerator
    final seedSource = Random.secure();
    final seeds = <int>[];
    for (int i = 0; i < 32; i++) {
      seeds.add(seedSource.nextInt(255));
    }
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    
    // RSA-Parameter (2048 Bit)
    final params = RSAKeyGeneratorParameters(BigInt.parse('65537'), 2048, 64);
    
    keyGen.init(ParametersWithRandom(params, secureRandom));
    final pair = keyGen.generateKeyPair();
    
    _publicKey = pair.publicKey as RSAPublicKey;
    _privateKey = pair.privateKey as RSAPrivateKey;
  }
  
  /// Verschlüsselt Text mit dem öffentlichen Schlüssel
  String encryptWithPublicKey(String plainText, RSAPublicKey publicKey) {
    final encryptor = PKCS1Encoding(RSAEngine());
    encryptor.init(true, PublicKeyParameter<RSAPublicKey>(publicKey));
    
    final bytes = utf8.encode(plainText);
    final encrypted = _processInBlocks(encryptor, bytes);
    
    return base64.encode(encrypted);
  }
  
  /// Entschlüsselt Text mit dem privaten Schlüssel
  String decryptWithPrivateKey(String encryptedText, RSAPrivateKey privateKey) {
    try {
      final decryptor = PKCS1Encoding(RSAEngine());
      decryptor.init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
      
      final encryptedBytes = base64.decode(encryptedText);
      final decrypted = _processInBlocks(decryptor, encryptedBytes);
      
      return utf8.decode(decrypted);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('block type') || msg.contains('unsupported')) {
        throw Exception(
          'Schlüssel stimmt nicht überein – bitte Public Key neu austauschen '
          '(Menü → RSA-Schlüssel → QR zeigen / scannen)');
      }
      throw Exception('RSA-Entschlüsselung fehlgeschlagen: $e');
    }
  }
  
  /// Signiert Text mit dem privaten Schlüssel
  String signText(String text, RSAPrivateKey privateKey) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201');
    signer.init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    
    final bytes = utf8.encode(text);
    final signature = signer.generateSignature(bytes);
    
    return base64.encode(signature.bytes);
  }
  
  /// Verifiziert eine Signatur mit dem öffentlichen Schlüssel
  bool verifySignature(String text, String signature, RSAPublicKey publicKey) {
    try {
      final verifier = RSASigner(SHA256Digest(), '0609608648016503040201');
      verifier.init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
      
      final bytes = utf8.encode(text);
      final signatureBytes = base64.decode(signature);
      
      return verifier.verifySignature(bytes, RSASignature(signatureBytes));
    } catch (e) {
      return false;
    }
  }
  
  /// Verarbeitet Daten in Blöcken (für große Nachrichten)
  Uint8List _processInBlocks(AsymmetricBlockCipher cipher, Uint8List data) {
    final blockSize = cipher.inputBlockSize;
    final output = <int>[];
    
    for (int i = 0; i < data.length; i += blockSize) {
      final end = (i + blockSize < data.length) ? i + blockSize : data.length;
      final block = data.sublist(i, end);
      final processed = cipher.process(block);
      output.addAll(processed);
    }
    
    return Uint8List.fromList(output);
  }
  
  /// Konvertiert öffentlichen Schlüssel zu String-Format
  String publicKeyToString() {
    return jsonEncode({
      'modulus': _publicKey.modulus.toString(),
      'exponent': _publicKey.exponent.toString(),
    });
  }
  
  /// Konvertiert privaten Schlüssel zu String-Format
  String privateKeyToString() {
    return jsonEncode({
      'modulus': _privateKey.modulus.toString(),
      'privateExponent': _privateKey.privateExponent.toString(),
      'p': _privateKey.p.toString(),
      'q': _privateKey.q.toString(),
    });
  }
  
  /// Lädt öffentlichen Schlüssel aus String-Format
  RSAPublicKey publicKeyFromString(String keyString) {
    final data = jsonDecode(keyString);
    final modulus = BigInt.parse(data['modulus']);
    final exponent = BigInt.parse(data['exponent']);
    
    _publicKey = RSAPublicKey(modulus, exponent);
    return _publicKey;
  }
  
  /// Lädt privaten Schlüssel aus String-Format
  RSAPrivateKey privateKeyFromString(String keyString) {
    final data = jsonDecode(keyString);
    final modulus = BigInt.parse(data['modulus']);
    final privateExponent = BigInt.parse(data['privateExponent']);
    final p = BigInt.parse(data['p']);
    final q = BigInt.parse(data['q']);
    
    _privateKey = RSAPrivateKey(modulus, privateExponent, p, q);
    return _privateKey;
  }
  
  /// Generiert einen Fingerprint für den öffentlichen Schlüssel
  String getPublicKeyFingerprint() {
    final keyData = publicKeyToString();
    final bytes = utf8.encode(keyData);
    final digest = sha256.convert(bytes);
    
    // Formatiere als Hex mit Doppelpunkten
    final hex = digest.toString();
    final formatted = StringBuffer();
    for (int i = 0; i < hex.length; i += 2) {
      if (i > 0) formatted.write(':');
      formatted.write(hex.substring(i, i + 2).toUpperCase());
    }
    
    return formatted.toString();
  }
  
  /// Erstellt einen kompakten öffentlichen Schlüssel für QR-Codes
  String getCompactPublicKey() {
    final keyData = {
      'n': _publicKey.modulus.toString(),
      'e': _publicKey.exponent.toString(),
    };
    return base64.encode(utf8.encode(jsonEncode(keyData)));
  }
  
  /// Lädt kompakten öffentlichen Schlüssel aus QR-Code
  RSAPublicKey loadCompactPublicKey(String compactKey) {
    final decoded = utf8.decode(base64.decode(compactKey));
    final data = jsonDecode(decoded);
    final modulus = BigInt.parse(data['n']);
    final exponent = BigInt.parse(data['e']);
    
    return RSAPublicKey(modulus, exponent);
  }
}
