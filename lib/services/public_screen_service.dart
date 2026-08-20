// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qgap/model/public_screen_session.dart';

/// Alle Firestore- und Storage-Operationen für PublicScreen-Sessions.
class PublicScreenService {
  static const String _collection = 'public_screens';
  static const String _hostingBaseUrl = 'https://obmc-1856d.web.app';
  static const String _prefKey = 'public_screen_session_ids';
  static const String _secretPrefPrefix = 'public_screen_admin_secret_';

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  // ── Lokale Session-ID-Verwaltung (SharedPreferences) ────────────────────────

  Future<List<String>> _loadStoredIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_prefKey) ?? [];
  }

  Future<void> _addSessionId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefKey) ?? [];
    if (!ids.contains(id)) {
      ids.insert(0, id); // neueste zuerst
      await prefs.setStringList(_prefKey, ids);
    }
  }

  Future<void> _removeSessionId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_prefKey) ?? [];
    ids.remove(id);
    await prefs.setStringList(_prefKey, ids);
  }

  // ── Hilfsmethoden ────────────────────────────────────────────────────────

  String _requireUid() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Nicht eingeloggt.');
    return uid;
  }

  static String _generateSessionId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(20, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ── Session CRUD ─────────────────────────────────────────────────────────

  /// Erstellt eine neue PublicScreen-Session und gibt sie zurück.
  Future<PublicScreenSession> createSession(String title) async {
    final uid = _requireUid();
    final sessionId = _generateSessionId();

    final now = DateTime.now();
    final session = PublicScreenSession(
      id:          sessionId,
      adminUserId: uid,
      title:       title,
      createdAt:   now,
      updatedAt:   now,
    );

    await _db.collection(_collection).doc(sessionId).set(session.toMap());
    await _addSessionId(sessionId); // lokal merken

    // Admin-Secret für die Kopplung weiterer Admin-Handys anlegen.
    // Liegt in private/meta (per Rules nur für den Ersteller lesbar –
    // das Hauptdokument ist wegen des Viewers öffentlich lesbar).
    try {
      final secret = _generateSessionId();
      await _db
          .collection(_collection)
          .doc(sessionId)
          .collection('private')
          .doc('meta')
          .set({'adminSecret': secret});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_secretPrefPrefix$sessionId', secret);
    } catch (e) {
      debugPrint('PublicScreenService: adminSecret anlegen fehlgeschlagen: $e');
    }
    return session;
  }

  // ── Admin-Kopplung (weitere Admin-Handys) ─────────────────────────

  /// Liefert das Admin-Secret einer Session.
  /// Reihenfolge: lokal gespeichert → Firestore private/meta (nur Ersteller)
  /// → neu erzeugen (Backfill für Alt-Sessions).
  Future<String> getOrCreateAdminSecret(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    final local = prefs.getString('$_secretPrefPrefix$sessionId');
    if (local != null && local.isNotEmpty) return local;

    _requireUid();
    final metaRef = _db
        .collection(_collection)
        .doc(sessionId)
        .collection('private')
        .doc('meta');
    String? secret;
    try {
      final doc = await metaRef.get();
      secret = doc.data()?['adminSecret'] as String?;
    } catch (_) {
      // Kein Lesezugriff → unten neu anlegen (schlägt bei Co-Admins fehl,
      // die haben das Secret aber ohnehin lokal vom Koppel-QR)
    }
    if (secret == null || secret.isEmpty) {
      secret = _generateSessionId();
      await metaRef.set({'adminSecret': secret});
    }
    await prefs.setString('$_secretPrefPrefix$sessionId', secret);
    return secret;
  }

  /// Koppelt dieses Gerät als Co-Admin an eine Session (Admin-QR gescannt).
  /// Legt joins/{uid} an – die Firestore-Rules prüfen das Secret gegen
  /// private/meta. Danach ist die Session lokal bekannt und administrierbar.
  Future<PublicScreenSession> joinAsAdmin(
      String sessionId, String adminSecret) async {
    final uid = _requireUid();
    final doc = await _db.collection(_collection).doc(sessionId).get();
    if (!doc.exists) throw Exception('Session nicht gefunden.');
    final session = PublicScreenSession.fromDoc(doc);

    if (session.adminUserId != uid) {
      final joinRef = _db
          .collection(_collection)
          .doc(sessionId)
          .collection('joins')
          .doc(uid);
      final existing = await joinRef.get();
      if (!existing.exists) {
        await joinRef.set({
          'secret':   adminSecret,
          'joinedAt': FieldValue.serverTimestamp(),
        });
      }
    }

    // Secret lokal merken, damit auch dieses Handy den Admin-QR weitergeben kann
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_secretPrefPrefix$sessionId', adminSecret);
    await _addSessionId(sessionId);
    return session;
  }

  /// Lädt alle lokal bekannten Sessions (neueste zuerst, anhand gespeicherter IDs).
  /// Kein Firestore-Query → kein Index nötig, kein Browsen möglich.
  Future<List<PublicScreenSession>> loadMySessions() async {
    final ids = await _loadStoredIds();
    if (ids.isEmpty) return [];

    final sessions = <PublicScreenSession>[];
    final staleIds = <String>[];

    for (final id in ids) {
      try {
        final doc = await _db.collection(_collection).doc(id).get();
        if (doc.exists) {
          sessions.add(PublicScreenSession.fromDoc(doc));
        } else {
          staleIds.add(id); // in Firestore gelöscht → lokal entfernen
        }
      } catch (e) {
        debugPrint('PublicScreenService: Session $id laden fehlgeschlagen: $e');
      }
    }

    // Veraltete IDs bereinigen
    for (final id in staleIds) {
      await _removeSessionId(id);
    }

    return sessions;
  }

  /// Echtzeit-Stream für eine einzelne Session (auch für Viewer).
  Stream<PublicScreenSession?> watchSession(String sessionId) {
    return _db
        .collection(_collection)
        .doc(sessionId)
        .snapshots()
        .map((doc) => doc.exists ? PublicScreenSession.fromDoc(doc) : null);
  }

  /// Aktualisiert Titel, Einstellungen und Zustands-Configs.
  Future<void> updateSettings(PublicScreenSession session) async {
    _requireUid();
    await _db
        .collection(_collection)
        .doc(session.id)
        .update(session.toUpdateMap());
  }

  /// Setzt nur den State (start / active / pause / ended).
  Future<void> setState(String sessionId, PublicScreenState state) async {
    _requireUid();
    await _db.collection(_collection).doc(sessionId).update({
      'state':     state.value,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Löscht eine Session (Firestore-Dokument + lokale ID).
  Future<void> deleteSession(PublicScreenSession session) async {
    _requireUid();
    await _db.collection(_collection).doc(session.id).delete();
    await _removeSessionId(session.id);
  }

  // ── Folien-Upload ────────────────────────────────────────────────────────

  /// Schreibt eine fertige Base64-Data-URI direkt als aktive Folie in Firestore.
  Future<void> uploadSlideData(String sessionId, String dataUri) async {
    _requireUid();
    if (dataUri.length > 900000) {
      throw Exception(
        'Bild zu groß (${(dataUri.length / 1024).toStringAsFixed(0)} KB). '
        'Qualität oder Auflösung in den Einstellungen reduzieren.',
      );
    }
    await _db.collection(_collection).doc(sessionId).update({
      'currentImageData': dataUri,
      'slideType':        'image',
      'slidePayload':     null,
      'state':            PublicScreenState.active.value,
      'updatedAt':        FieldValue.serverTimestamp(),
    });
  }

  /// Sendet eine Liedtext-Strophe als reinen Text-Payload (~1 KB) in Firestore.
  /// 100× kleiner als JPEG – praktisch sofortige Übertragung.
  Future<void> uploadSlideText({
    required String sessionId,
    required String songTitle,
    required String sectionTitle,
    required String text,
    String bgColor = '#0D1B2A',
    String textColor = '#FFFFFF',
    int fontSize = 52,
    String textSizeMode = 'perSlide',
    bool showSongTitle = false,
  }) async {
    _requireUid();
    await _db.collection(_collection).doc(sessionId).update({
      'state':     PublicScreenState.active.value,
      'slideType': 'text',
      'slidePayload': {
        'songTitle':    songTitle,
        'sectionTitle': sectionTitle,
        'text':         text,
        'bgColor':      bgColor,
        'textColor':    textColor,
        'fontSize':     fontSize,
        'textSizeMode': textSizeMode,
        'showSongTitle': showSongTitle,
      },
      'currentImageData': null,
      'updatedAt':        FieldValue.serverTimestamp(),
    });
  }

  /// Komprimiert eine Bilddatei und speichert sie als Base64-Data-URI in Firestore.
  Future<void> uploadSlide(
    PublicScreenSession session,
    File imageFile,
  ) async {
    _requireUid();

    // 1. Komprimieren
    final compressed = await _compressImage(imageFile, session.exportSettings);

    // 2. Base64-Data-URI erstellen
    final mimeType = session.exportSettings.format == 'webp'
        ? 'image/webp'
        : 'image/jpeg';
    final dataUri = 'data:$mimeType;base64,${base64Encode(compressed)}';

    // 3. Größenprüfung (Firestore-Dokumentlimit ~1 MB)
    if (dataUri.length > 900000) {
      throw Exception(
        'Bild zu groß (${(dataUri.length / 1024).toStringAsFixed(0)} KB). '
        'Qualität oder Auflösung in den Einstellungen reduzieren.',
      );
    }

    // 4. Firestore aktualisieren
    await _db.collection(_collection).doc(session.id).update({
      'currentImageData': dataUri,
      'slideType':        'image',
      'slidePayload':     null,
      'state':            PublicScreenState.active.value,
      'updatedAt':        FieldValue.serverTimestamp(),
    });
  }

  /// Komprimiert Roh-Bytes eines Bildes und lädt sie in die Session hoch.
  /// Geeignet für USB/SAF-Bilder die als Bytes gelesen wurden.
  Future<void> uploadImageBytes(
    PublicScreenSession session,
    Uint8List imageBytes,
    String fileName,
  ) async {
    _requireUid();
    // Temporäre Datei anlegen, damit FlutterImageCompress darauf arbeiten kann
    final dir = await getTemporaryDirectory();
    final tmpPath = p.join(dir.path, 'ps_img_${DateTime.now().millisecondsSinceEpoch}_$fileName');
    final tmpFile = File(tmpPath);
    await tmpFile.writeAsBytes(imageBytes);
    try {
      final compressed = await _compressImage(tmpFile, session.exportSettings);
      final mimeType = session.exportSettings.format == 'webp' ? 'image/webp' : 'image/jpeg';
      final dataUri = 'data:$mimeType;base64,${base64Encode(compressed)}';
      if (dataUri.length > 900000) {
        throw Exception(
          'Bild zu groß (${(dataUri.length / 1024).toStringAsFixed(0)} KB). '
          'Qualität oder Auflösung reduzieren.',
        );
      }
      await _db.collection(_collection).doc(session.id).update({
        'currentImageData': dataUri,
        'slideType':        'image',
        'slidePayload':     null,
        'state':            PublicScreenState.active.value,
        'updatedAt':        FieldValue.serverTimestamp(),
      });
    } finally {
      try { await tmpFile.delete(); } catch (_) {}
    }
  }

  /// Komprimiert ein Bild nach den ExportSettings.
  /// Auf Windows/Linux (flutter_image_compress nicht verfügbar) werden
  /// die Bytes ohne Komprimierung zurückgegeben.
  Future<Uint8List> _compressImage(File file, ExportSettings settings) async {
    // flutter_image_compress unterstützt Android, iOS, macOS, Web – NICHT Windows/Linux.
    if (Platform.isWindows || Platform.isLinux) {
      return await file.readAsBytes();
    }
    final dir = await getTemporaryDirectory();
    final targetPath = p.join(
      dir.path,
      'ps_slide_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    final result = await FlutterImageCompress.compressAndGetFile(
      file.absolute.path,
      targetPath,
      minWidth:  settings.width,
      minHeight: settings.height,
      quality:   settings.quality,
      format: settings.format == 'webp'
          ? CompressFormat.webp
          : CompressFormat.jpeg,
    );

    if (result == null) {
      // Fallback: unkomprimiert
      return await file.readAsBytes();
    }

    final bytes = await result.readAsBytes();

    // Temp-Datei aufräumen
    try { await File(result.path).delete(); } catch (_) {}

    return bytes;
  }


  // ── Viewer-URL ───────────────────────────────────────────────────────────

  static String viewerUrl(String sessionId) =>
      '$_hostingBaseUrl/viewer.html?id=$sessionId';
}
