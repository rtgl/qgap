// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';

/// Kategorie eines gespeicherten QR-Code-Eintrags.
enum QrCategory {
  text,
  link,
  postInfo,
  qgap,
  rsaKey,
  sonstiges,
  binary,
  ron, // DHL Return Online Label
}

extension QrCategoryLabel on QrCategory {
  String get label {
    switch (this) {
      case QrCategory.text:
        return 'Text';
      case QrCategory.link:
        return 'Link';
      case QrCategory.postInfo:
        return 'Post-Info';
      case QrCategory.qgap:
        return 'QGap';
      case QrCategory.rsaKey:
        return 'RSA-Key';
      case QrCategory.sonstiges:
        return 'Sonstiges';
      case QrCategory.binary:
        return 'Binär';
      case QrCategory.ron:
        return 'RON - Return Online (DHL)';
    }
  }

  String get emoji {
    switch (this) {
      case QrCategory.text:
        return '📝';
      case QrCategory.link:
        return '🔗';
      case QrCategory.postInfo:
        return '📮';
      case QrCategory.qgap:
        return '🔒';
      case QrCategory.rsaKey:
        return '🔑';
      case QrCategory.sonstiges:
        return '📦';
      case QrCategory.binary:
        return '💾';
      case QrCategory.ron:
        return '📦';
    }
  }
}

/// Gespeicherter QR-Code-Eintrag (QR-Galerie im Transfer-Hub).
class SavedQrEntry {
  final String id;
  final String name;       // z.B. "Postfach-Info"
  final String content;    // Text / URL / Base64 / QGap-Daten
  final QrCategory category;
  final DateTime savedAt;

  const SavedQrEntry({
    required this.id,
    required this.name,
    required this.content,
    required this.category,
    required this.savedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'content': content,
      'category': category.toString(),
      'savedAt': savedAt.toIso8601String(),
    };
  }

  factory SavedQrEntry.fromJson(Map<String, dynamic> json) {
    return SavedQrEntry(
      id: json['id'] as String,
      name: json['name'] as String,
      content: json['content'] as String,
      category: QrCategory.values.firstWhere(
        (e) => e.toString() == json['category'],
        orElse: () => QrCategory.sonstiges,
      ),
      savedAt: DateTime.parse(json['savedAt'] as String),
    );
  }

  /// Erkennt automatisch eine passende Kategorie anhand des Inhalts.
  static QrCategory detectCategory(String content) {
    // Binäre Daten mit BIN: Marker (vom Scanner)
    if (content.startsWith('BIN:')) {
      // Prüfe ob es ein RON-Label ist
      try {
        final bytes = base64.decode(content.substring(4));
        final text = utf8.decode(bytes, allowMalformed: true);
        if (text.startsWith('RON|')) {
          return QrCategory.ron;
        }
      } catch (_) {}
      return QrCategory.binary;
    }
    
    if (content.startsWith('QGAP_RSA_PUB:') || content.startsWith('OBMC_RSA_PUB:')) {
      return QrCategory.rsaKey;
    }
    if (content.startsWith('http://') || content.startsWith('https://')) {
      return QrCategory.link;
    }
    
    // Prüfe ob es Base64-kodierte QGap-Daten sind (Metadaten-Präfix)
    if (content.length > 20) {
      try {
        for (int len = 20; len <= 64; len += 4) {
          if (len >= content.length) break;
          final possible = content.substring(0, len);
          final decoded = utf8.decode(base64.decode(possible));
          final parts = decoded.split(';');
          if (parts.length >= 2 && decoded.endsWith(';')) {
            return QrCategory.qgap;
          }
        }
      } catch (_) {}
    }
    return QrCategory.text;
  }

  /// Parst RON-Format (DHL Return Online Label).
  /// Format: RON|Sendungsnr||Service|Produktcode|Name|...
  static Map<String, String>? parseRon(String content) {
    if (!content.startsWith('BIN:')) return null;
    
    try {
      final bytes = base64.decode(content.substring(4));
      final text = utf8.decode(bytes, allowMalformed: true);
      
      if (!text.startsWith('RON|')) return null;
      
      final parts = text.split('|');
      if (parts.length < 15) return null;
      
      return {
        'format': 'RON',
        'sendungsnummer': parts[1],
        'service': parts[3],
        'produktcode': parts[4],
        'empfaenger_name': parts[5],
        'empfaenger_strasse': parts[7],
        'empfaenger_plz': parts[8],
        'empfaenger_ort': parts[9],
        'empfaenger_land': parts[10],
        'absender_name': parts[11],
        'absender_strasse': parts[13],
        'absender_plz': parts[14],
        'absender_ort': parts[15],
        'absender_land': parts[16],
        'tracking': parts.length > 20 ? parts[20] : '',
        'retourennummer': parts.length > 23 ? parts[23] : '',
      };
    } catch (_) {
      return null;
    }
  }
}
