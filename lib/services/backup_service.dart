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
import 'package:encrypt/encrypt.dart' as enc;
import 'package:file_picker/file_picker.dart';
import 'package:pointycastle/export.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'auth_service.dart';
import 'local_contact_service.dart';

/// Exportiert und importiert die Firebase-Identität als verschlüsselte .qgap_Privat_ID_aes Datei.
///
/// Format: AES-256-CBC, Schlüssel via PBKDF2-SHA256 (100 000 Iterationen, 32 Byte)
/// Salt (16 Byte) + IV (16 Byte) + verschlüsselte JSON-Daten, alles Base64 kodiert.
class BackupService {
  static const int _pbkdf2Iterations = 100000;
  static const int _keyLength        = 32; // 256 bit
  static const int _saltLength       = 16;
  static const String _fileExtension = '.qgap_Privat_ID_aes';
  static const int _backupVersion    = 1;

  // ─── Export ─────────────────────────────────────────────────────────────

  /// Erstellt eine verschlüsselte Backup-Datei und öffnet den Share-Dialog.
  ///
  /// [masterPassword]: frei gewähltes Passwort des Users.
  /// Gibt true zurück wenn der Export erfolgreich war.
  static Future<bool> exportBackup(String masterPassword) async {
    final username  = await AuthService.getStoredUsername();
    final password  = await AuthService.getStoredPassword();
    final uid       = AuthService.currentUid;
    final contacts  = await LocalContactService.getAllContacts();

    if (username == null || password == null || uid == null) return false;

    final payload = jsonEncode({
      'version':           _backupVersion,
      'firebase_uid':      uid,
      'firebase_username': username,
      'firebase_password': password,
      'local_contacts':    contacts,
    });

    final encrypted = _encrypt(payload, masterPassword);

    if (Platform.isAndroid || Platform.isIOS) {
      // Temporäre Datei schreiben und System-Share-Sheet öffnen
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/QGAP_id_backup$_fileExtension');
      await file.writeAsString(encrypted, flush: true);
      await Share.shareXFiles(
        [XFile(file.path)],
        subject: 'QGap Identitäts-Backup',
      );
    } else {
      // Windows/Desktop: Speichern-Dialog (kein Share-Sheet verfügbar)
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Backup speichern',
        fileName: 'QGAP_id_backup$_fileExtension',
      );
      if (path == null) return false;
      await File(path).writeAsString(encrypted, flush: true);
    }
    return true;
  }

  // ─── Import ─────────────────────────────────────────────────────────────

  /// Öffnet den File-Picker, liest die Backup-Datei und entschlüsselt sie.
  ///
  /// Gibt ein Map mit den Backup-Daten zurück, oder null bei Fehler.
  static Future<Map<String, dynamic>?> importBackup(
      String masterPassword) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;

    final path = result.files.single.path;
    if (path == null) return null;
    if (!path.endsWith(_fileExtension) &&
        !path.endsWith('.qgap_Privat_ID_aes')) {
      throw const FormatException('Keine gültige QGap-Backup-Datei.');
    }

    final encrypted = await File(path).readAsString();
    final plain     = _decrypt(encrypted, masterPassword);
    return jsonDecode(plain) as Map<String, dynamic>;
  }

  // ─── Krypto-Kern ────────────────────────────────────────────────────────

  static String _encrypt(String plainText, String password) {
    final salt  = _randomBytes(_saltLength);
    final key   = _deriveKey(password, salt);
    final iv    = enc.IV(_randomBytes(16));
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(key), mode: enc.AESMode.cbc),
    );
    final encrypted = encrypter.encrypt(plainText, iv: iv);

    // Format: base64(salt) + ':' + base64(iv.bytes) + ':' + base64(ciphertext)
    return '${base64.encode(salt)}:'
        '${base64.encode(iv.bytes)}:'
        '${encrypted.base64}';
  }

  static String _decrypt(String data, String password) {
    final parts = data.split(':');
    if (parts.length != 3) {
      throw const FormatException('Ungültiges Backup-Format.');
    }
    final salt       = base64.decode(parts[0]);
    final ivBytes    = base64.decode(parts[1]);
    final ciphertext = parts[2];

    final key       = _deriveKey(password, salt);
    final iv        = enc.IV(ivBytes);
    final encrypter = enc.Encrypter(
      enc.AES(enc.Key(key), mode: enc.AESMode.cbc),
    );
    return encrypter.decrypt64(ciphertext, iv: iv);
  }

  static Uint8List _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(salt, _pbkdf2Iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _randomBytes(int length) {
    final rng   = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) { bytes[i] = rng.nextInt(256); }
    return bytes;
  }
}
