// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:qgap/model/sng_song.dart';

/// Ein Element in der Präsentations-Playlist – entweder ein Lied oder ein Bild.
sealed class PlaylistItem {
  /// Dateiname mit Erweiterung (für Sortierung und Statuszeile).
  String get fileNameWithExt;

  Map<String, dynamic> toJson();

  static PlaylistItem fromJson(Map<String, dynamic> j) {
    if (j['type'] == 'img') return ImageItem.fromJson(j);
    return SongItem.fromJson(j);
  }
}

/// Ein Lied mit Strophen.
final class SongItem extends PlaylistItem {
  final SngSong song;
  SongItem(this.song);

  @override
  String get fileNameWithExt => song.fileNameWithExt;

  @override
  Map<String, dynamic> toJson() => {'type': 'song', 'song': song.toJson()};

  factory SongItem.fromJson(Map<String, dynamic> j) =>
      SongItem(SngSong.fromJson(j['song'] as Map<String, dynamic>));
}

/// Ein Bild (.jpg, .jpeg, .png, .webp, .gif).
final class ImageItem extends PlaylistItem {
  /// Dateipfad (lokal) oder content://-URI (SAF/USB).
  final String uri;

  /// true wenn [uri] eine content://-URI ist (SAF), false für lokale Pfade.
  final bool isContentUri;

  final String fileName; // mit Erweiterung

  ImageItem({
    required this.uri,
    required this.fileName,
    this.isContentUri = false,
  });

  @override
  String get fileNameWithExt => fileName;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'img',
        'uri': uri,
        'fn': fileName,
        'cu': isContentUri,
      };

  factory ImageItem.fromJson(Map<String, dynamic> j) => ImageItem(
        uri: j['uri'] as String,
        fileName: j['fn'] as String,
        isContentUri: (j['cu'] as bool?) ?? false,
      );
}
