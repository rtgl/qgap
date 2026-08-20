// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qgap/model/playlist_item.dart';
import 'package:qgap/model/sng_song.dart';
import 'package:qgap/services/usb_saf_service.dart';

// Top-level-Funktion: läuft in einem separaten Dart-Isolate (via compute()),
// damit der UI-Thread nicht blockiert wird.
// Nur listSync() ohne jeden stat()-Aufruf → stabil auf Android FUSE,
// läuft in <50 ms egal wie viele Dateien.
String _folderFingerprintWork(String folderPath) {
  const imageExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};
  try {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return '';
    // Nur Dateianzahl – kein lastModified, kein statSync.
    // Ändert sich beim Hinzufügen/Entfernen von Liedern → Cache ungültig.
    // Bei reinen Inhaltsänderungen → Refresh-Button nutzen.
    final count = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return ext == '.sng' || ext == '.txt' || imageExts.contains(ext);
        })
        .length;
    return '$count';
  } catch (_) {
    return '';
  }
}

// Cache-JSON im Hintergrund-Isolate dekodieren (UI bleibt flüssig).
// Argument: [rawJson, expectedFingerprint]
List<dynamic>? _decodeCacheWork(List<String> args) {
  try {
    final map = jsonDecode(args[0]) as Map<String, dynamic>;
    if ((map['fp'] as String?) != args[1]) return null;
    return map['items'] as List;
  } catch (_) {
    return null;
  }
}

/// Liest und parst SongBeamer-.sng-Dateien (Windows-1252 / Latin-1 kodiert)
/// sowie Liedtext-.txt-Dateien (UTF-8).
class SngParserService {
  static const String _prefKeyFolder = 'sng_folder_path';

  // ── Playlist-Cache ───────────────────────────────────────────────────────

  static const String _cacheFileFolder = 'sng_playlist_folder.json';
  static const String _cacheFileUsb    = 'sng_playlist_usb.json';

  static Future<File> _cacheFile(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, name));
  }

  /// Speichert die Playlist als JSON-Cache.
  /// [fingerprint] ist eine Zeichenkette zur Cache-Invalidierung
  /// (z. B. "Dateizählung:maxLastModified").
  static Future<void> _saveCache(
    String name,
    List<PlaylistItem> items,
    String fingerprint,
  ) async {
    try {
      final file = await _cacheFile(name);
      final json = jsonEncode({
        'fp': fingerprint,
        'items': items.map((e) => e.toJson()).toList(),
      });
      await file.writeAsString(json, flush: true);
    } catch (_) {}
  }

  /// Lädt Playlist aus JSON-Cache, falls der Fingerprint übereinstimmt.
  /// Gibt null zurück wenn kein Cache oder veraltet.
  /// jsonDecode läuft im Hintergrund-Isolate (UI bleibt flüssig).
  static Future<List<PlaylistItem>?> _loadCache(
    String name,
    String fingerprint,
  ) async {
    try {
      final file = await _cacheFile(name);
      if (!file.existsSync()) return null;
      final raw = await file.readAsString();
      // jsonDecode im Hintergrund-Isolate – blockiert den UI-Thread nicht
      final decoded = await compute(_decodeCacheWork, [raw, fingerprint]);
      if (decoded == null) return null;
      return decoded
          .map((e) => PlaylistItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Löscht beide Cache-Dateien (erzwingt komplettes Neuladen).
  static Future<void> clearCache() async {
    for (final name in [_cacheFileFolder, _cacheFileUsb]) {
      try {
        final f = await _cacheFile(name);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
  }

  /// Berechnet den Fingerprint im Hintergrund-Isolate (UI bleibt flüssig).
  static Future<String> _folderFingerprintAsync(String folderPath) =>
      compute(_folderFingerprintWork, folderPath);

  /// Berechnet einen Fingerprint für ein USB-SAF-Verzeichnis:
  /// Dateianzahl + Gesamtgröße (zuverlässiger als Timestamps auf FAT32-USB).
  static String _usbFingerprint(List<UsbSafFile> files) {
    int totalSize = 0;
    for (final f in files) {
      totalSize += f.size;
    }
    return '${files.length}:$totalSize';
  }

  // ── Ordner-Pfad (SharedPreferences) ─────────────────────────────────────

  static Future<String?> getSavedFolderPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKeyFolder);
  }

  static Future<void> saveFolderPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyFolder, path);
  }

  // ── Strophen-Bezeichner-Erkennung ─────────────────────────────────────────

  /// Wörter, die am Anfang einer Zeile nach '---' darauf hinweisen,
  /// dass diese Zeile ein Abschnitts-Bezeichner ist (kein Liedtext).
  /// Erweiterbar: einfach neue Einträge hier hinzufügen.
  static const List<String> sectionKeywords = [
    'refrain',
    'vers',
    'strophe',
    'bridge',
    'chorus',
    'pre-chorus',
    'intro',
    'outro',
    'coda',
    'interlude',
    'tag',
    'hook',
    'schluss',
  ];

  /// Gibt zurück ob [line] ein Abschnitts-Bezeichner ist.
  static bool _isSectionTitle(String line) {
    final lower = line.trim().toLowerCase();
    return sectionKeywords.any((kw) => lower.startsWith(kw));
  }

  // ── Dateien laden ─────────────────────────────────────────────────────────
  static Future<List<SngSong>> loadSongsFromFolder(String folderPath) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return [];

    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final lower = f.path.toLowerCase();
          return lower.endsWith('.sng') || lower.endsWith('.txt');
        })
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final songs = <SngSong>[];
    for (final file in files) {
      final lower = file.path.toLowerCase();
      final song = lower.endsWith('.txt')
          ? _parseTxtFile(file)
          : _parseFile(file);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  static SngSong? _parseFile(File file) {
    try {
      final bytes = file.readAsBytesSync();
      return _parseSngContent(
          p.basenameWithoutExtension(file.path), _decodeSng(bytes));
    } catch (e) {
      return null;
    }
  }

  /// Dekodiert .sng-Bytes korrekt:
  /// – UTF-8 mit BOM (EF BB BF) → UTF-8 dekodieren, BOM entfernen
  /// – Gültiges UTF-8 ohne BOM → UTF-8
  /// – Sonst → Windows-1252 (klassisches SongBeamer-Format; NICHT Latin-1,
  ///   denn 0x80–0x9F sind dort Satzzeichen wie ’ “ ” – … statt Steuerzeichen)
  static String _decodeSng(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    try {
      // Strikt versuchen – schlägt bei cp1252-Sonderzeichen fehl
      return utf8.decode(bytes);
    } on FormatException {
      return _decodeCp1252(bytes);
    }
  }

  /// Windows-1252-Dekodierung: wie Latin-1, aber 0x80–0x9F sind
  /// typografische Zeichen (’ ‘ “ ” – — … € u. a.).
  static String _decodeCp1252(Uint8List bytes) {
    const cp1252 = <int, int>{
      0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E,
      0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021, 0x88: 0x02C6,
      0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152,
      0x8E: 0x017D, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201C,
      0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014,
      0x98: 0x02DC, 0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A,
      0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    };
    final codeUnits = List<int>.generate(
        bytes.length, (i) => cp1252[bytes[i]] ?? bytes[i]);
    return String.fromCharCodes(codeUnits);
  }

  // ── .sng-Inhalt parsen ────────────────────────────────────────────────────
  static SngSong? _parseSngContent(String fileName, String content) {
    try {
      final lines = content.split('\n').map((l) => l.trimRight()).toList();
      String title = fileName;
      String author = '';
      String ccli = '';
      String copyright = '';
      final strophes = <SngStrophe>[];
      String? currentTitle;
      final currentLines = <String>[];

      void flush() {
        if (currentTitle != null) {
          final text = currentLines.join('\n').trim();
          if (text.isNotEmpty) {
            strophes.add(SngStrophe(title: currentTitle!, text: text));
          }
          currentTitle = null;
          currentLines.clear();
        }
      }

      bool nextLineIsTitle = false;

      for (final line in lines) {
        if (line.startsWith('#')) {
          if (line.startsWith('#Title=')) {
            title = line.substring('#Title='.length).trim();
          } else if (line.startsWith('#Author=')) {
            author = line.substring('#Author='.length).trim();
          } else if (line.startsWith('#CCLI=')) {
            ccli = line.substring('#CCLI='.length).trim();
          } else if (line.startsWith('#(c)=')) {
            copyright = line.substring('#(c)='.length).trim();
          } else if (line.startsWith('#Copyright=')) {
            copyright = line.substring('#Copyright='.length).trim();
          }
          continue;
        }
        if (line == '---') {
          flush();
          nextLineIsTitle = true;
          continue;
        }
        if (nextLineIsTitle) {
          nextLineIsTitle = false;
          if (line.trim().isEmpty) {
            currentTitle = '';
          } else if (_isSectionTitle(line)) {
            currentTitle = line.trim();
          } else {
            currentTitle = '';
            currentLines.add(line);
          }
          continue;
        }
        if (currentTitle != null) {
          currentLines.add(line);
        }
      }
      flush();

      if (strophes.isEmpty) return null;
      return SngSong(fileName: fileName, title: title, author: author, ccli: ccli, copyright: copyright, strophes: strophes);
    } catch (e) {
      return null;
    }
  }

  static SngSong? _parseTxtFile(File file) {
    try {
      return _parseTxtContent(
          p.basenameWithoutExtension(file.path),
          file.readAsStringSync(encoding: utf8));
    } catch (e) {
      return null;
    }
  }

  // ── USB SAF laden (.sng + .txt, kein Dateisystem-Zugriff nötig) ──────────
  static Future<List<SngSong>> loadSongsFromUsbSaf({String? subPath}) async {
    final sngFiles = await UsbSafService.listUsbDir(subPath: subPath, suffix: '.sng');
    final txtFiles = await UsbSafService.listUsbDir(subPath: subPath, suffix: '.txt');
    final allFiles = [...sngFiles, ...txtFiles]
      ..sort((a, b) => a.name.compareTo(b.name));

    final songs = <SngSong>[];
    for (final f in allFiles) {
      final bytes = await UsbSafService.readUsbFile(f.uri);
      if (bytes == null) continue;
      final nameNoExt = f.name.contains('.')
          ? f.name.substring(0, f.name.lastIndexOf('.'))
          : f.name;
      final isTxt = f.name.toLowerCase().endsWith('.txt');
      final content = isTxt
          ? utf8.decode(bytes, allowMalformed: true)
          : _decodeSng(bytes);
      final song = isTxt
          ? _parseTxtContent(nameNoExt, content)
          : _parseSngContent(nameNoExt, content);
      if (song != null) songs.add(song);
    }
    return songs;
  }

  // ── Gemeinsame Bild-Erweiterungen ─────────────────────────────────────────
  static const _imageExts = {'.jpg', '.jpeg', '.png', '.webp', '.gif'};

  // ── Playlist laden: Ordner (.sng + .txt + Bilder) ─────────────────────────
  /// [onProgress] wird aufgerufen während des Erstladens (loaded, total).
  /// Bei Cache-Treffer wird onProgress nicht aufgerufen.
  static Future<List<PlaylistItem>> loadPlaylistFromFolder(
    String folderPath, {
    void Function(int loaded, int total)? onProgress,
  }) async {
    final dir = Directory(folderPath);
    if (!dir.existsSync()) return [];

    // ── Cache-Prüfung im Hintergrund-Isolate (UI bleibt animiert) ────────────
    final fingerprint = await _folderFingerprintAsync(folderPath);
    if (fingerprint.isNotEmpty) {
      final cached = await _loadCache(_cacheFileFolder, fingerprint);
      if (cached != null) return cached;
    }

    // ── Vollständiges Laden ──────────────────────────────────────────────────
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final ext = p.extension(f.path).toLowerCase();
          return ext == '.sng' || ext == '.txt' || _imageExts.contains(ext);
        })
        .toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

    final total = files.length;
    onProgress?.call(0, total);

    // ── Paralleles Lesen in Gruppen von 20 ──────────────────────────────────
    const batchSize = 20;
    final items = List<PlaylistItem?>.filled(files.length, null);
    int loaded = 0;

    for (int start = 0; start < files.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, files.length);
      await Future.wait([
        for (int i = start; i < end; i++)
          () async {
            final file = files[i];
            final ext = p.extension(file.path).toLowerCase();
            if (_imageExts.contains(ext)) {
              items[i] = ImageItem(uri: file.path, fileName: p.basename(file.path));
            } else {
              try {
                if (ext == '.txt') {
                  items[i] = SongItem(
                    _parseTxtContent(
                      p.basenameWithoutExtension(file.path),
                      await file.readAsString(encoding: utf8),
                    )!,
                  );
                } else {
                  items[i] = SongItem(
                    _parseSngContent(
                      p.basenameWithoutExtension(file.path),
                      _decodeSng(await file.readAsBytes()),
                    )!,
                  );
                }
              } catch (_) {}
            }
          }(),
      ]);
      loaded = end;
      onProgress?.call(loaded, total);
    }

    final result = items.whereType<PlaylistItem>().toList();

    // ── Cache schreiben (await – stellt sicher dass die Datei wirklich geschrieben wird)
    if (fingerprint.isNotEmpty) {
      await _saveCache(_cacheFileFolder, result, fingerprint);
    }
    return result;
  }

  // ── Playlist laden: USB SAF (.sng + .txt + Bilder) ────────────────────────
  static Future<List<PlaylistItem>> loadPlaylistFromUsbSaf({
    String? subPath,
    void Function(int loaded, int total)? onProgress,
  }) async {
    // Alle Dateien ohne Suffix-Filter holen, in Dart filtern
    final allFiles = await UsbSafService.listUsbDir(subPath: subPath);
    allFiles.sort((a, b) => a.name.compareTo(b.name));

    // ── Cache-Prüfung ────────────────────────────────────────────────────────
    final fingerprint = _usbFingerprint(allFiles);
    if (fingerprint.isNotEmpty) {
      final cached = await _loadCache(_cacheFileUsb, fingerprint);
      if (cached != null) return cached;
    }

    // ── Vollständiges Laden ──────────────────────────────────────────────────
    // Bilder sofort eintragen (kein I/O nötig), Song-Dateien parallel lesen.
    final songFiles = <(int, UsbSafFile)>[];
    final items = List<PlaylistItem?>.filled(allFiles.length, null);

    for (int i = 0; i < allFiles.length; i++) {
      final f = allFiles[i];
      final ext = f.name.contains('.')
          ? f.name.substring(f.name.lastIndexOf('.')).toLowerCase()
          : '';
      if (_imageExts.contains(ext)) {
        items[i] = ImageItem(uri: f.uri, fileName: f.name, isContentUri: true);
      } else if (ext == '.sng' || ext == '.txt') {
        songFiles.add((i, f));
      }
    }

    final total = allFiles.length;
    onProgress?.call(allFiles.length - songFiles.length, total);

    // Paralleles Lesen der Song-Dateien in Gruppen von 10
    // (SAF-Platform-Channel verträgt weniger parallele Aufrufe als lokales I/O).
    const batchSize = 10;
    int loaded = allFiles.length - songFiles.length;

    for (int start = 0; start < songFiles.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, songFiles.length);
      await Future.wait([
        for (int b = start; b < end; b++)
          () async {
            final (idx, f) = songFiles[b];
            final ext = f.name.substring(f.name.lastIndexOf('.')).toLowerCase();
            final bytes = await UsbSafService.readUsbFile(f.uri);
            if (bytes == null) return;
            final nameNoExt = f.name.substring(0, f.name.lastIndexOf('.'));
            final isTxt = ext == '.txt';
            final content = isTxt
                ? utf8.decode(bytes, allowMalformed: true)
                : _decodeSng(bytes);
            final song = isTxt
                ? _parseTxtContent(nameNoExt, content)
                : _parseSngContent(nameNoExt, content);
            if (song != null) items[idx] = SongItem(song);
          }(),
      ]);
      loaded += end - start;
      onProgress?.call(loaded, total);
    }

    final result = items.whereType<PlaylistItem>().toList();

    // ── Cache schreiben (await – stellt sicher dass die Datei wirklich geschrieben wird)
    if (fingerprint.isNotEmpty) {
      await _saveCache(_cacheFileUsb, result, fingerprint);
    }
    return result;
  }

  // ── .txt-Inhalt parsen (UTF-8) ────────────────────────────────────────────
  static SngSong? _parseTxtContent(String fileName, String content) {
    try {
      final lines = content.split('\n').map((l) => l.trimRight()).toList();
      if (lines.isEmpty) return null;
      final title = lines[0].trim();
      if (title.isEmpty) return null;

      int ccliIndex = lines.length;
      for (int i = 1; i < lines.length; i++) {
        if (lines[i].trimLeft().toUpperCase().startsWith('CCLI')) {
          ccliIndex = i;
          break;
        }
      }

      String author = '';
      if (ccliIndex > 1 && lines[ccliIndex - 1].trim().isNotEmpty) {
        author = lines[ccliIndex - 1].trim();
      }

      final int contentEnd = author.isNotEmpty ? ccliIndex - 1 : ccliIndex;
      final contentLines = lines.sublist(
        lines.length > 1 ? 2 : 1,
        contentEnd.clamp(0, lines.length),
      );

      final strophes = <SngStrophe>[];
      final sectionLines = <String>[];

      void flushSection() {
        if (sectionLines.isEmpty) return;
        String sectionTitle = '';
        int textStart = 0;
        if (_isSectionTitle(sectionLines[0])) {
          sectionTitle = sectionLines[0].trim();
          textStart = 1;
        }
        final text = sectionLines.sublist(textStart).join('\n').trim();
        if (text.isNotEmpty) {
          strophes.add(SngStrophe(title: sectionTitle, text: text));
        }
        sectionLines.clear();
      }

      for (final line in contentLines) {
        if (line.trim().isEmpty) {
          flushSection();
        } else {
          sectionLines.add(line);
        }
      }
      flushSection();

      if (strophes.isEmpty) return null;
      // CCLI-Nummer aus der "CCLI Song #XXXXXXX"-Zeile extrahieren
      String ccli = '';
      String copyright = '';
      if (ccliIndex < lines.length) {
        final match = RegExp(r'\d+').firstMatch(lines[ccliIndex].trim());
        if (match != null) ccli = match.group(0)!;
        // Copyright: Zeile direkt danach wenn sie mit © beginnt
        if (ccliIndex + 1 < lines.length) {
          final nextLine = lines[ccliIndex + 1].trim();
          if (nextLine.startsWith('©') || nextLine.startsWith('(c)') || nextLine.startsWith('(C)')) {
            copyright = nextLine;
          }
        }
      }
      return SngSong(fileName: fileName, fileExtension: '.txt', title: title, author: author, ccli: ccli, copyright: copyright, strophes: strophes);
    } catch (e) {
      return null;
    }
  }
}
