// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:cloud_firestore/cloud_firestore.dart';

/// Zustand einer PublicScreen-Session
enum PublicScreenState { start, active, pause, ended }

extension PublicScreenStateExt on PublicScreenState {
  String get value {
    switch (this) {
      case PublicScreenState.start:  return 'start';
      case PublicScreenState.active: return 'active';
      case PublicScreenState.pause:  return 'pause';
      case PublicScreenState.ended:  return 'ended';
    }
  }

  static PublicScreenState fromString(String? s) {
    switch (s) {
      case 'active': return PublicScreenState.active;
      case 'pause':  return PublicScreenState.pause;
      case 'ended':  return PublicScreenState.ended;
      default:       return PublicScreenState.start;
    }
  }

  String get label {
    switch (this) {
      case PublicScreenState.start:  return 'Start';
      case PublicScreenState.active: return 'Aktiv';
      case PublicScreenState.pause:  return 'Pause';
      case PublicScreenState.ended:  return 'Beendet';
    }
  }
}

/// Schriftgrößen-Modus für Text-Folien
enum TextSizeMode { perSlide, uniform, fixed }

extension TextSizeModeExt on TextSizeMode {
  String get value {
    switch (this) {
      case TextSizeMode.perSlide: return 'perSlide';
      case TextSizeMode.uniform:  return 'uniform';
      case TextSizeMode.fixed:    return 'fixed';
    }
  }

  static TextSizeMode fromString(String? s) {
    switch (s) {
      case 'uniform': return TextSizeMode.uniform;
      case 'fixed':   return TextSizeMode.fixed;
      default:        return TextSizeMode.perSlide;
    }
  }

  String get label {
    switch (this) {
      case TextSizeMode.perSlide: return 'Pro Folie: so groß wie möglich';
      case TextSizeMode.uniform:  return 'Einheitlich: gleiche Größe, kein Umbruch';
      case TextSizeMode.fixed:    return 'Feste Schriftgröße';
    }
  }
}

/// Viewer-Orientierung pro Session
enum PublicScreenOrientation { landscape, portrait }

extension PublicScreenOrientationExt on PublicScreenOrientation {
  String get value =>
      this == PublicScreenOrientation.landscape ? 'landscape' : 'portrait';

  static PublicScreenOrientation fromString(String? s) =>
      s == 'portrait'
          ? PublicScreenOrientation.portrait
          : PublicScreenOrientation.landscape;
}

/// Konfiguration für ein Zustands-Bild (Start / Pause / Ende)
class SlideConfig {
  /// 'text' oder 'image'
  final String type;
  final String text;
  final String textColor;  // Hex, z.B. '#FFFFFF'
  final String bgColor;    // Hex, z.B. '#1A1A2E'
  final int fontSize;
  final String? imageUrl;

  const SlideConfig({
    this.type = 'text',
    this.text = '',
    this.textColor = '#FFFFFF',
    this.bgColor = '#1A1A2E',
    this.fontSize = 48,
    this.imageUrl,
  });

  Map<String, dynamic> toMap() => {
    'type': type,
    'text': text,
    'textColor': textColor,
    'bgColor': bgColor,
    'fontSize': fontSize,
    'imageUrl': imageUrl,
  };

  factory SlideConfig.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const SlideConfig();
    return SlideConfig(
      type:      m['type']      as String? ?? 'text',
      text:      m['text']      as String? ?? '',
      textColor: m['textColor'] as String? ?? '#FFFFFF',
      bgColor:   m['bgColor']   as String? ?? '#1A1A2E',
      fontSize:  (m['fontSize'] as num?)?.toInt() ?? 48,
      imageUrl:  m['imageUrl']  as String?,
    );
  }

  SlideConfig copyWith({
    String? type,
    String? text,
    String? textColor,
    String? bgColor,
    int? fontSize,
    String? imageUrl,
    bool clearImageUrl = false,
  }) {
    return SlideConfig(
      type:      type      ?? this.type,
      text:      text      ?? this.text,
      textColor: textColor ?? this.textColor,
      bgColor:   bgColor   ?? this.bgColor,
      fontSize:  fontSize  ?? this.fontSize,
      imageUrl:  clearImageUrl ? null : (imageUrl ?? this.imageUrl),
    );
  }
}

/// Export-Einstellungen für Folien-Upload (Komprimierung)
class ExportSettings {
  final int width;
  final int height;
  final int quality;  // 10–100
  final String format; // 'jpg' oder 'webp'

  const ExportSettings({
    this.width = 1920,
    this.height = 1080,
    this.quality = 80,
    this.format = 'jpg',
  });

  Map<String, dynamic> toMap() => {
    'width':   width,
    'height':  height,
    'quality': quality,
    'format':  format,
  };

  factory ExportSettings.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const ExportSettings();
    return ExportSettings(
      width:   (m['width']   as num?)?.toInt() ?? 1920,
      height:  (m['height']  as num?)?.toInt() ?? 1080,
      quality: (m['quality'] as num?)?.toInt() ?? 80,
      format:  m['format']  as String? ?? 'jpg',
    );
  }

  ExportSettings copyWith({int? width, int? height, int? quality, String? format}) {
    return ExportSettings(
      width:   width   ?? this.width,
      height:  height  ?? this.height,
      quality: quality ?? this.quality,
      format:  format  ?? this.format,
    );
  }

  String get resolutionLabel => '$width×$height';
}

/// Das vollständige Datenmodell einer PublicScreen-Session
class PublicScreenSession {
  final String id;              // Firestore-Dokument-ID
  final String adminUserId;     // UID des Admins
  final String title;
  final PublicScreenState state;
  final String? currentImageData; // base64 data-URI der aktuellen Folie
  final PublicScreenOrientation orientation;
  final ExportSettings exportSettings;
  final SlideConfig startConfig;
  final SlideConfig pauseConfig;
  final SlideConfig endConfig;
  final TextSizeMode textSizeMode;   // Schriftgrößen-Modus für Text-Folien
  final int fixedFontSize;           // Schriftgröße bei Modus 'fixed' (px)
  final String ccliLicense;          // CCLI Gemeinde Präsentations Lizenz-Nr.
  final DateTime createdAt;
  final DateTime updatedAt;

  const PublicScreenSession({
    required this.id,
    required this.adminUserId,
    required this.title,
    this.state = PublicScreenState.start,
    this.currentImageData,
    this.orientation = PublicScreenOrientation.landscape,
    this.exportSettings = const ExportSettings(),
    this.startConfig = const SlideConfig(
      text: 'Liedsession beginnt gleich …',
      bgColor: '#0D1B2A',
    ),
    this.pauseConfig = const SlideConfig(
      text: 'Zur Zeit gibt es keine Folie',
      bgColor: '#1A1A2E',
    ),
    this.endConfig = const SlideConfig(
      text: 'Liedsession beendet',
      bgColor: '#1B0000',
    ),
    this.textSizeMode = TextSizeMode.perSlide,
    this.fixedFontSize = 48,
    this.ccliLicense = '',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'adminUserId':      adminUserId,
    'title':            title,
    'state':            state.value,
    'currentImageData': currentImageData,
    'orientation':      orientation.value,
    'exportSettings':   exportSettings.toMap(),
    'startConfig':      startConfig.toMap(),
    'pauseConfig':      pauseConfig.toMap(),
    'endConfig':        endConfig.toMap(),
    'textSizeMode':     textSizeMode.value,
    'fixedFontSize':    fixedFontSize,
    'ccliLicense':      ccliLicense,
    'createdAt':        FieldValue.serverTimestamp(),
    'updatedAt':        FieldValue.serverTimestamp(),
  };

  Map<String, dynamic> toUpdateMap() => {
    'title':            title,
    'state':            state.value,
    'currentImageData': currentImageData,
    'orientation':      orientation.value,
    'exportSettings':   exportSettings.toMap(),
    'startConfig':      startConfig.toMap(),
    'pauseConfig':      pauseConfig.toMap(),
    'endConfig':        endConfig.toMap(),
    'textSizeMode':     textSizeMode.value,
    'fixedFontSize':    fixedFontSize,
    'ccliLicense':      ccliLicense,
    'updatedAt':        FieldValue.serverTimestamp(),
  };

  factory PublicScreenSession.fromDoc(DocumentSnapshot doc) {
    final m = doc.data() as Map<String, dynamic>? ?? {};
    return PublicScreenSession(
      id:               doc.id,
      adminUserId:      m['adminUserId']  as String? ?? '',
      title:            m['title']        as String? ?? '',
      state:            PublicScreenStateExt.fromString(m['state'] as String?),
      currentImageData: m['currentImageData'] as String?,
      orientation:      PublicScreenOrientationExt.fromString(m['orientation'] as String?),
      exportSettings:   ExportSettings.fromMap(m['exportSettings'] as Map<String, dynamic>?),
      startConfig:      SlideConfig.fromMap(m['startConfig'] as Map<String, dynamic>?),
      pauseConfig:      SlideConfig.fromMap(m['pauseConfig'] as Map<String, dynamic>?),
      endConfig:        SlideConfig.fromMap(m['endConfig']   as Map<String, dynamic>?),
      textSizeMode:     TextSizeModeExt.fromString(m['textSizeMode'] as String?),
      fixedFontSize:    (m['fixedFontSize'] as num?)?.toInt() ?? 48,
      ccliLicense:      m['ccliLicense']  as String? ?? '',
      createdAt:  (m['createdAt']  as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt:  (m['updatedAt']  as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  PublicScreenSession copyWith({
    String? title,
    PublicScreenState? state,
    String? currentImageData,
    bool clearCurrentImageData = false,
    PublicScreenOrientation? orientation,
    ExportSettings? exportSettings,
    SlideConfig? startConfig,
    SlideConfig? pauseConfig,
    SlideConfig? endConfig,
    TextSizeMode? textSizeMode,
    int? fixedFontSize,
    String? ccliLicense,
  }) {
    return PublicScreenSession(
      id:               id,
      adminUserId:      adminUserId,
      title:            title            ?? this.title,
      state:            state            ?? this.state,
      currentImageData: clearCurrentImageData ? null : (currentImageData ?? this.currentImageData),
      orientation:      orientation      ?? this.orientation,
      exportSettings:   exportSettings   ?? this.exportSettings,
      startConfig:      startConfig      ?? this.startConfig,
      pauseConfig:      pauseConfig      ?? this.pauseConfig,
      endConfig:        endConfig        ?? this.endConfig,
      textSizeMode:     textSizeMode     ?? this.textSizeMode,
      fixedFontSize:    fixedFontSize    ?? this.fixedFontSize,
      ccliLicense:      ccliLicense      ?? this.ccliLicense,
      createdAt:        createdAt,
      updatedAt:        DateTime.now(),
    );
  }

  /// Viewer-URL für Firebase Hosting
  String viewerUrl(String hostingBaseUrl) =>
      '$hostingBaseUrl/viewer.html?id=$id';
}
