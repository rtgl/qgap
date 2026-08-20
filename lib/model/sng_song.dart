// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

/// Eine einzelne Strophe / Abschnitt eines Liedes
class SngStrophe {
  final String title; // z.B. "Vers 1", "Refrain 1"
  final String text;  // mehrzeiliger Liedtext

  const SngStrophe({required this.title, required this.text});

  Map<String, dynamic> toJson() => {'t': title, 'x': text};

  factory SngStrophe.fromJson(Map<String, dynamic> j) =>
      SngStrophe(title: j['t'] as String, text: j['x'] as String);
}

/// Ein geparster SongBeamer-.sng-Song
class SngSong {
  final String fileName;      // ohne Erweiterung
  final String fileExtension; // z.B. ".sng" oder ".txt"
  final String title;         // aus #Title= oder fileName
  final String author;        // aus #Author=
  final String ccli;          // aus #CCLI= (z.B. "5282557")
  final String copyright;     // aus #(c)= oder #Copyright=
  final List<SngStrophe> strophes;

  const SngSong({
    required this.fileName,
    this.fileExtension = '',
    required this.title,
    required this.author,
    this.ccli = '',
    this.copyright = '',
    required this.strophes,
  });

  /// Dateiname mit Erweiterung
  String get fileNameWithExt =>
      fileExtension.isNotEmpty ? '$fileName$fileExtension' : fileName;

  Map<String, dynamic> toJson() => {
        'fn': fileName,
        'fe': fileExtension,
        'ti': title,
        'au': author,
        'cc': ccli,
        'cp': copyright,
        'st': strophes.map((s) => s.toJson()).toList(),
      };

  factory SngSong.fromJson(Map<String, dynamic> j) => SngSong(
        fileName: j['fn'] as String,
        fileExtension: (j['fe'] as String?) ?? '',
        title: j['ti'] as String,
        author: (j['au'] as String?) ?? '',
        ccli: (j['cc'] as String?) ?? '',
        copyright: (j['cp'] as String?) ?? '',
        strophes: (j['st'] as List)
            .map((e) => SngStrophe.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
