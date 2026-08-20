// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:qgap/model/playlist_item.dart';
import 'package:qgap/model/sng_song.dart';
import 'package:qgap/model/public_screen_session.dart';
import 'package:qgap/services/sng_parser_service.dart';
import 'package:qgap/services/usb_saf_service.dart';
import 'package:qgap/services/public_screen_service.dart';

/// Vollbild-Liedtext-Presenter mit 4-Pfeil-Navigation.
/// Rendert die aktuelle Strophe und kann sie als Folie hochladen.
class SongSlideScreen extends StatefulWidget {
  /// Session in die hochgeladen wird (optional – kann null sein wenn nur
  /// vorgeschaut wird ohne aktive Präsentation).
  final PublicScreenSession? session;

  const SongSlideScreen({super.key, this.session});

  @override
  State<SongSlideScreen> createState() => _SongSlideScreenState();
}

class _SongSlideScreenState extends State<SongSlideScreen> {
  final PublicScreenService _service = PublicScreenService();

  List<PlaylistItem> _items = [];
  int _songIndex = 0;
  int _stropheIndex = -1;  // -1 = Titelfolie, 0..N-1 = Strophen
  bool _loading = true;
  (int, int)? _loadProgress;   // (geladene, gesamt) während Ladevorgang
  bool _uploading = false;
  bool _autoSend = false;
  String? _folderPath;
  String? _statusMsg;
  String _loadHint = 'Lade …';       // Hinweistext während Ladevorgang
  String? _sourceInfo;  // Dauerhaft sichtbare Quellen-Info (Laufwerk/Ordner)
  PublicScreenState _sessionState = PublicScreenState.start;
  bool _isFullscreen = false;
  bool _listMode = false;   // Vollbild: alle Folien untereinander statt Einzelfolie
  int _listCols = 1;        // Folienliste: Spaltenzahl (Strg+Mausrad, Desktop)
  bool _ctrlDown = false;   // Strg gedrückt → Mausrad zoomt statt scrollt
  double _lastListItemH = 300; // gemessene Kachelhöhe für Auswahl-Scrolling
  final Set<int> _sentStropheIndices = {};  // im aktuellen Lied bereits gesendete Folien
  int? _activeStropheIndex; // zuletzt gesendete Folie (= aktiv beim Viewer) → hellgrün
  final ScrollController _listScrollCtrl = ScrollController();

  // ── Initialisierung ───────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _init();
  }

  bool _onKeyEvent(KeyEvent event) {
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl != _ctrlDown && mounted) setState(() => _ctrlDown = ctrl);
    if (!mounted || _loading || _items.isEmpty) return false;
    // Nicht reagieren, wenn ein anderer Screen (z. B. Liedsuche) darüber liegt
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    final key = event.logicalKey;
    // Button-Fokus (z. B. zuletzt geklickter Button) wegnehmen, damit die
    // Pfeiltasten immer die Folie steuern und Space NUR die Folie sendet —
    // nie einen fokussierten Button auslöst.
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.space) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    final inList = _isFullscreen && _listMode;
    // Pfeiltasten: Folie auswählen (Listenansicht: gelber Rahmen, ohne Senden)
    if (key == LogicalKeyboardKey.arrowDown) {
      inList ? _moveSelection(_listCols) : _nextStrophe();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      inList ? _moveSelection(-_listCols) : _prevStrophe();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      inList ? _moveSelection(1) : _nextStrophe();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      inList ? _moveSelection(-1) : _prevStrophe();
      return true;
    }
    // Bild ↓/↑: nächstes/vorheriges Lied
    if (key == LogicalKeyboardKey.pageDown) {
      _nextSong();
      return true;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _prevSong();
      return true;
    }
    // Escape: Vollbild verlassen
    if (key == LogicalKeyboardKey.escape) {
      if (_isFullscreen) _exitFullscreen();
      return true;
    }
    // Keine Wiederholung für Einmal-Aktionen
    if (event is KeyRepeatEvent) return false;
    // Space: aktuelle Folie online schalten
    if (key == LogicalKeyboardKey.space) {
      if (widget.session != null && !_uploading) _uploadSlide();
      return true;
    }
    // S / P / E: Session-Status Start / Pause / Ende
    if (widget.session != null) {
      if (key == LogicalKeyboardKey.keyS) {
        _setSessionState(PublicScreenState.start);
        return true;
      }
      if (key == LogicalKeyboardKey.keyP) {
        _setSessionState(PublicScreenState.pause);
        return true;
      }
      if (key == LogicalKeyboardKey.keyE) {
        _setSessionState(PublicScreenState.ended);
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _listScrollCtrl.dispose();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    super.dispose();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _autoSend = prefs.getBool('sng_auto_send') ?? false;
    _listMode = prefs.getBool('sng_list_mode') ?? false;
    _listCols = (prefs.getInt('sng_list_cols') ?? 1).clamp(1, 4);
    final usbMode = prefs.getBool('sng_usb_mode') ?? false;
    if (usbMode) {
      // Prüfen ob die SAF-URI auf internen Speicher (primary:) zeigt.
      // Das passiert wenn der Benutzer einen lokalen Ordner per "Stick koppeln"
      // ausgewählt hat – SAF ist dann unnötig langsam, besser direkt laden.
      final treeUri = await UsbSafService.getPersistedUsbTreeUri();
      final savedSubPath = prefs.getString('sng_usb_subpath');
      final localPath = _safUriToLocalPath(treeUri, subPath: savedSubPath);
      if (localPath != null) {
        // Auto-Migration: SAF-Overhead entfernen, direkt mit Dateipfad laden
        await prefs.setBool('sng_usb_mode', false);
        await prefs.remove('sng_usb_subpath');
        await SngParserService.saveFolderPath(localPath);
        await SngParserService.clearCache(); // neu aufbauen ohne content-URIs
        await _loadFromFolder(localPath);
        return;
      }
      await _loadFromUsbSaf(subPath: savedSubPath);
    } else {
      final saved = await SngParserService.getSavedFolderPath();
      if (saved != null) {
        await _loadFromFolder(saved);
      } else {
        setState(() => _loading = false);
      }
    }
  }

  /// Wandelt eine SAF-Tree-URI in einen lokalen Dateipfad um,
  /// falls sie auf den primären internen Speicher zeigt (primary:).
  /// Gibt null zurück bei echten USB-Sticks (Volume-ID wie "F655-2C50").
  static String? _safUriToLocalPath(String? treeUri, {String? subPath}) {
    if (treeUri == null || treeUri.isEmpty) return null;
    try {
      final decoded = Uri.decodeComponent(treeUri);
      // content://com.android.externalstorage.documents/tree/primary%3ASongs
      // → decoded: .../tree/primary:Songs
      final treeIdx = decoded.lastIndexOf('/tree/');
      if (treeIdx < 0) return null;
      final docPart = decoded.substring(treeIdx + 6);
      if (!docPart.startsWith('primary:')) return null;
      final relativePath = docPart.substring('primary:'.length);
      String localPath = '/storage/emulated/0';
      if (relativePath.isNotEmpty) {
        localPath = '$localPath/$relativePath';
      }
      if (subPath != null && subPath.isNotEmpty) {
        localPath = '$localPath/$subPath';
      }
      return localPath;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadFromFolder(String path) async {
    setState(() { _loading = true; _folderPath = path; _loadProgress = null; _loadHint = 'Prüfe Cache …'; });
    try {
      // Laufzeit-Permission für Medien/Speicher anfragen (Android 13+ braucht
      // READ_MEDIA_IMAGES zur Laufzeit, ältere Android READ_EXTERNAL_STORAGE).
      if (Platform.isAndroid) {
        final imgPerm = await Permission.photos.status;
        if (imgPerm.isDenied || imgPerm.isRestricted) {
          await Permission.photos.request();
        }
        // Fallback für Android ≤ 12
        final storagePerm = await Permission.storage.status;
        if (storagePerm.isDenied || storagePerm.isRestricted) {
          await Permission.storage.request();
        }
      }
      final songs = await SngParserService.loadPlaylistFromFolder(
        path,
        onProgress: (loaded, total) {
          if (mounted && (loaded % 10 == 0 || loaded == total)) {
            setState(() { _loadProgress = (loaded, total); _loadHint = 'Lade Lieder …'; });
          }
        },
      );
      await SngParserService.saveFolderPath(path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sng_usb_mode', false);
      if (mounted) {
        setState(() {
          _items = songs;
          _songIndex = 0;
          _stropheIndex = -1;
          _loading = false;
          _loadProgress = null;
          _sourceInfo = '📂 $path';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _loadProgress = null; _statusMsg = 'Ladefehler: $e'; });
    }
  }

  // ── Von USB-Stick laden (SAF) ──────────────────────────────────────────

  Future<void> _loadFromUsbSaf({bool forceNewPicker = false, String? subPath}) async {
    bool hasUri = !forceNewPicker && await UsbSafService.hasTreeUri();
    if (!hasUri) {
      // System-Picker öffnen (immer wenn forceNewPicker=true oder kein URI gespeichert)
      String? picked;
      try {
        picked = await UsbSafService.pickUsbTreeUri();
      } catch (e) {
        if (mounted) setState(() { _loading = false; _statusMsg = 'USB-Picker Fehler: $e'; });
        return;
      }
      if (picked == null || picked.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      hasUri = true;
    }
    setState(() { _loading = true; _folderPath = 'USB-Stick'; _loadHint = 'Lese USB-Verzeichnis …'; });
    try {
      final songs = await SngParserService.loadPlaylistFromUsbSaf(
        subPath: subPath,
        onProgress: (loaded, total) {
          if (mounted && (loaded % 10 == 0 || loaded == total)) {
            setState(() { _loadProgress = (loaded, total); _loadHint = 'Lade Lieder …'; });
          }
        },
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sng_usb_mode', true);
      // subPath persistieren, damit beim nächsten Start derselbe Unterordner geladen wird
      if (subPath != null) {
        await prefs.setString('sng_usb_subpath', subPath);
      } else {
        await prefs.remove('sng_usb_subpath');
      }
      final treeUri = await UsbSafService.getPersistedUsbTreeUri();
      final usbLabel = _usbLabelFromUri(treeUri);
      final displayLabel = subPath != null ? '$usbLabel / ${subPath.replaceAll('/', ' / ')}' : usbLabel;
      if (mounted) {
        setState(() {
          _items = songs;
          _songIndex = 0;
          _stropheIndex = -1;
          _loading = false;
          _sourceInfo = '💾 $displayLabel';
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _statusMsg = 'USB-Fehler: $e'; });
    }
  }

  Future<void> _forceReload() async {
    await SngParserService.clearCache();
    final prefs = await SharedPreferences.getInstance();
    final usbMode = prefs.getBool('sng_usb_mode') ?? false;
    if (usbMode) {
      final savedSubPath = prefs.getString('sng_usb_subpath');
      await _loadFromUsbSaf(subPath: savedSubPath);
    } else {
      final path = await SngParserService.getSavedFolderPath();
      if (path != null) await _loadFromFolder(path);
    }
  }

  // ── Ordner auswählen ──────────────────────────────────────────

  /// Dekodiert eine SAF-Tree-URI in ein lesbares Laufwerk/Pfad-Label.
  /// z. B. content://...tree/F655-2C50%3AMueh%2FLiedTexte
  ///  → "F655-2C50 / Mueh / LiedTexte"
  static String _usbLabelFromUri(String? uri) {
    if (uri == null || uri.isEmpty) return 'USB-Stick';
    try {
      // Letztes Pfadsegment nach /tree/ oder /document/
      final decoded = Uri.decodeComponent(uri);
      final treeIdx = decoded.lastIndexOf('/tree/');
      final docIdx  = decoded.lastIndexOf('/document/');
      final idx = treeIdx >= 0 ? treeIdx + 6
                : docIdx  >= 0 ? docIdx  + 10
                : decoded.lastIndexOf('/') + 1;
      final raw = decoded.substring(idx); // z.B. "F655-2C50:Mueh/LiedTexte"
      // Doppelpunkt und Slash als Trennzeichen anzeigen
      return raw.replaceAll(':', ' / ').replaceAll('/', ' / ');
    } catch (_) {
      return 'USB-Stick';
    }
  }

  /// Öffnet den SAF-Ordner-Browser wenn der Stick gekoppelt ist,
  /// sonst den normalen Datei-Picker für internen Speicher
  /// bzw. den Koppel-Dialog für externen Speicher.
  Future<void> _pickFolder() async {
    // USB SAF ist nur auf Android verfügbar.
    if (!Platform.isAndroid) {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Lied-Ordner wählen',
      );
      if (path != null) await _loadFromFolder(path);
      return;
    }

    final isUsbCoupled = await UsbSafService.hasTreeUri();

    if (isUsbCoupled) {
      // Stick ist gekoppelt → eigenen SAF-Browser zeigen (kein FilePicker!).
      // Der FilePicker würde auf Android 11+ wieder den System-Dialog zeigen.
      if (!mounted) return;
      final subPath = await showDialog<_UsbFolderResult>(
        context: context,
        builder: (_) => const _UsbFolderBrowserDialog(),
      );
      if (subPath == null) return; // Abgebrochen
      if (subPath.recouple) {
        await _loadFromUsbSaf(forceNewPicker: true);
      } else {
        await _loadFromUsbSaf(subPath: subPath.path.isEmpty ? null : subPath.path);
      }
      return;
    }

    // Kein Stick gekoppelt → normaler FilePicker
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Lied-Ordner wählen',
    );
    if (path == null) return;

    final bool isInternalStorage =
        path.startsWith('/storage/emulated/') || path.startsWith('/data/');

    if (isInternalStorage) {
      await _loadFromFolder(path);
    } else {
      // Externer Speicher ohne Kopplung → Koppel-Dialog
      if (!mounted) return;
      final couple = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('USB-Stick koppeln?'),
          content: Text(
            'Externer Speicher erkannt:\n$path\n\n'
            'Bitte „Stick koppeln" wählen und im nächsten Dialog '
            'den USB-Stick als Ganzes auswählen, damit alle Dateien gelesen werden können.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stick koppeln'),
            ),
          ],
        ),
      );
      if (couple == true) {
        await _loadFromUsbSaf(forceNewPicker: true);
      }
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  PlaylistItem? get _currentItem =>
      _items.isEmpty ? null : _items[_songIndex];

  SngSong? get _currentSong {
    final item = _currentItem;
    return item is SongItem ? item.song : null;
  }

  ImageItem? get _currentImage {
    final item = _currentItem;
    return item is ImageItem ? item : null;
  }

  SngStrophe? get _currentStrophe {
    final song = _currentSong;
    if (song == null || song.strophes.isEmpty) return null;
    if (_stropheIndex < 0) return null;  // Titelfolie
    return song.strophes[_stropheIndex];
  }

  bool get _isTitleSlide => _currentSong != null && _stropheIndex < 0;

  void _prevSong() {
    if (_items.isEmpty) return;
    setState(() {
      _songIndex = (_songIndex - 1 + _items.length) % _items.length;
      _stropheIndex = -1;
      _statusMsg = null;
      _sentStropheIndices.clear();
      _activeStropheIndex = null;
    });
    if (_listScrollCtrl.hasClients) _listScrollCtrl.jumpTo(0);
    _autoUpload();
  }

  void _nextSong() {
    if (_items.isEmpty) return;
    setState(() {
      _songIndex = (_songIndex + 1) % _items.length;
      _stropheIndex = -1;
      _statusMsg = null;
      _sentStropheIndices.clear();
      _activeStropheIndex = null;
    });
    if (_listScrollCtrl.hasClients) _listScrollCtrl.jumpTo(0);
    _autoUpload();
  }

  void _prevStrophe() {
    if (_currentImage != null) { _prevSong(); return; }
    final song = _currentSong;
    if (song == null) return;
    setState(() {
      if (_stropheIndex < 0) {
        _stropheIndex = song.strophes.length - 1;  // wrap: Titel → letzte Strophe
      } else if (_stropheIndex == 0) {
        _stropheIndex = -1;  // erste Strophe → Titelfolie
      } else {
        _stropheIndex--;
      }
      _statusMsg = null;
    });
    _autoUpload();
  }

  void _nextStrophe() {
    if (_currentImage != null) { _nextSong(); return; }
    final song = _currentSong;
    if (song == null) return;
    setState(() {
      if (_stropheIndex < 0) {
        _stropheIndex = 0;  // Titelfolie → erste Strophe
      } else {
        _stropheIndex = (_stropheIndex + 1) % song.strophes.length;
      }
      _statusMsg = null;
    });
    _autoUpload();
  }

  void _autoUpload() {
    if (_autoSend && widget.session != null && !_uploading) {
      _uploadSlide();
    }
  }

  Future<void> _setAutoSend(bool value) async {
    setState(() => _autoSend = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sng_auto_send', value);
  }

  Future<void> _setSessionState(PublicScreenState state) async {
    if (widget.session == null) return;
    setState(() => _sessionState = state);
    try {
      await _service.setState(widget.session!.id, state);
    } catch (e) {
      if (mounted) setState(() => _statusMsg = 'Status-Fehler: $e');
    }
  }

  Future<void> _showSongSearch() async {
    final result = await Navigator.push<int>(
      context,
      MaterialPageRoute(
        builder: (_) => _SongSearchScreen(items: _items),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _songIndex = result;
        _stropheIndex = -1;
        _statusMsg = null;
        _sentStropheIndices.clear();
        _activeStropheIndex = null;
      });
      if (_listScrollCtrl.hasClients) _listScrollCtrl.jumpTo(0);
      _autoUpload();
    }
  }

  // ── Folie hochladen ─────────────────────────────────────────────────────────

  Future<void> _uploadSlide() async {
    if (widget.session == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Keine aktive Session – über den Admin-Screen öffnen.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() { _uploading = true; _statusMsg = 'Sende …'; });

    try {
      // ── Bild-Folie ──────────────────────────────────────────────────────
      final image = _currentImage;
      if (image != null) {
        if (image.isContentUri) {
          // USB/SAF: Bytes lesen, dann komprimiert hochladen
          final bytes = await UsbSafService.readUsbFile(image.uri);
          if (bytes == null) throw Exception('Bild konnte nicht gelesen werden');
          await _service.uploadImageBytes(widget.session!, bytes, image.fileName);
        } else {
          // Lokale Datei: direkt komprimiert hochladen
          await _service.uploadSlide(widget.session!, File(image.uri));
        }
        if (mounted) setState(() { _statusMsg = '✓ Gesendet'; _sessionState = PublicScreenState.active; _sentStropheIndices.add(_stropheIndex); _activeStropheIndex = _stropheIndex; });
        return;
      }

      // ── Titelfolie ──────────────────────────────────────────────────────
      final song = _currentSong;
      if (_isTitleSlide && song != null) {
        final metaLines = <String>[];
        if (song.ccli.isNotEmpty)      metaLines.add('CCLI Song #${song.ccli}');
        if (song.copyright.isNotEmpty) metaLines.add(song.copyright);
        if (song.author.isNotEmpty)    metaLines.add(song.author);
        final license = widget.session!.ccliLicense;
        if (license.isNotEmpty)        metaLines.add('CCLI Lizenz #$license');
        await _service.uploadSlideText(
          sessionId:    widget.session!.id,
          songTitle:    song.title,
          sectionTitle: '',
          text:         metaLines.join('\n'),
          textSizeMode: 'titleSlide',
          fontSize:     widget.session!.fixedFontSize,
        );
        if (mounted) setState(() { _statusMsg = '✓ Gesendet'; _sessionState = PublicScreenState.active; _sentStropheIndices.add(_stropheIndex); _activeStropheIndex = _stropheIndex; });
        return;
      }

      // ── Text-Folie ──────────────────────────────────────────────────────
      final strophe = _currentStrophe;
      if (strophe == null || song == null) return;

      await _service.uploadSlideText(
        sessionId:    widget.session!.id,
        songTitle:    song.title,
        sectionTitle: strophe.title,
        text:         strophe.text,
        textSizeMode: widget.session!.textSizeMode.value,
        fontSize:     widget.session!.fixedFontSize,
        // Erste Liedfolie: Titel oben auf der Folie anzeigen (auch im Viewer)
        showSongTitle: _stropheIndex == 0,
      );
      if (mounted) setState(() { _statusMsg = '✓ Gesendet'; _sessionState = PublicScreenState.active; _sentStropheIndices.add(_stropheIndex); _activeStropheIndex = _stropheIndex; });
    } catch (e) {
      if (mounted) setState(() => _statusMsg = 'Fehler: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isFullscreen && !_loading && _items.isNotEmpty) {
      return PopScope<Object?>(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _exitFullscreen();
        },
        // Buttons ohne Tastaturfokus: Space/Pfeile steuern NUR die Folien
        child: ExcludeFocus(
          child: Scaffold(
            backgroundColor: Colors.black,
            body: _buildFullscreenBody(),
          ),
        ),
      );
    }
    return ExcludeFocus(
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        title: _currentItem == null
            ? const Text('Liedtexte')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentSong?.title ?? _currentItem!.fileNameWithExt,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _currentSong != null
                        ? 'Lied ${_songIndex + 1}/${_items.length}  ·  '
                          '${_isTitleSlide ? "Titel" : "Abschnitt ${_stropheIndex + 1}"}'
                          '/${_currentSong!.strophes.length}'
                        : 'Bild ${_songIndex + 1}/${_items.length}',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Neu laden (Cache leeren)',
            onPressed: _loading ? null : _forceReload,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'Ordner wählen',
            onPressed: _pickFolder,
          ),
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: 'Lied suchen',
              onPressed: _showSongSearch,
            ),
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.view_agenda_outlined),
              tooltip: 'Vollbild: Folienliste',
              onPressed: () => _enterFullscreen(listMode: true),
            ),
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.fullscreen),
              tooltip: 'Vollbild: Einzelfolie',
              onPressed: () => _enterFullscreen(listMode: false),
            ),
        ],
      ),
      body: _loading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_loadProgress != null) ...[
                    Text(
                      '${_loadProgress!.$1} / ${_loadProgress!.$2}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: 220,
                      child: LinearProgressIndicator(
                        value: _loadProgress!.$2 > 0
                            ? _loadProgress!.$1 / _loadProgress!.$2
                            : null,
                        color: Colors.white54,
                        backgroundColor: Colors.white12,
                        borderRadius: BorderRadius.circular(4),
                        minHeight: 6,
                      ),
                    ),
                  ] else
                    const CircularProgressIndicator(color: Colors.white54),
                  const SizedBox(height: 12),
                  Text(_loadHint,
                      style: const TextStyle(color: Colors.white54)),
                ],
              ),
            )
          : _items.isEmpty
              ? _buildEmptyState()
              : Column(
                  children: [
                    // ── Liedname: zentriert zwischen AppBar und Folie ──
                    if (_currentSong != null)
                      Expanded(
                        flex: 1,
                        child: Container(
                          color: const Color(0xFF0D1020),
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 2),
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.center,
                              child: Text(
                                _currentSong!.title,
                                style: const TextStyle(
                                  color: Color(0xFFFFDD00),
                                  fontSize: 40,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                    // ── Abschnitts-Bezeichnung direkt über der Folie ───
                    if (_isTitleSlide)
                      Container(
                        color: const Color(0xFF0D1020),
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                        child: const Text(
                          'Titelfolie',
                          style: TextStyle(
                            color: Color(0xFF8888FF),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                        ),
                      )
                    else if (_currentStrophe != null)
                      Container(
                        color: const Color(0xFF0D1020),
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                        child: Text(
                          _currentStrophe!.title.isNotEmpty
                              ? '${_currentStrophe!.title}  ( ${_stropheIndex + 1} / ${_currentSong!.strophes.length} )'
                              : '( ${_stropheIndex + 1} / ${_currentSong!.strophes.length} )',
                          style: const TextStyle(
                            color: Color(0xFF8888FF),
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // ── Folie im Ziel-Seitenverhältnis ──────────
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: _buildSlideWithAspectRatio(
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () {
                              // Tippen ohne Wischen → Folie sofort senden
                              if (widget.session != null && !_uploading) {
                                _uploadSlide();
                              }
                            },
                            onPanEnd: (details) {
                              final dx = details.velocity.pixelsPerSecond.dx;
                              final dy = details.velocity.pixelsPerSecond.dy;
                              const t = 400.0;
                              if (dx.abs() > dy.abs()) {
                                if (dx < -t) { _nextSong(); }    // links → nächstes Lied
                                else if (dx > t) { _prevSong(); }  // rechts → vorheriges Lied
                              } else {
                                if (dy < -t) { _nextStrophe(); }   // hoch → nächste Folie
                                else if (dy > t) { _prevStrophe(); } // runter → vorherige Folie
                              }
                            },
                            child: _buildSlide(),
                          ),
                        ),
                      ),
                    ),
                    if (_sourceInfo != null)
                      Container(
                        color: const Color(0xFF0A0F1E),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 3),
                        width: double.infinity,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _sourceInfo!,
                              style: const TextStyle(
                                  color: Color(0xFF7090B0), fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (_items.isNotEmpty && _currentItem != null)
                              Text(
                                _currentItem!.fileNameWithExt,
                                style: const TextStyle(
                                    color: Color(0xFF9AB0CC), fontSize: 12,
                                    fontWeight: FontWeight.w500),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                    // ── Viewer-Status-Leiste ────────────────────────────
                    if (widget.session != null)
                      Container(
                        color: const Color(0xFF0D1020),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: _SlideStateBtn(
                                label: 'Start',
                                icon: Icons.play_circle_outline,
                                active: _sessionState == PublicScreenState.start,
                                onTap: () => _setSessionState(PublicScreenState.start),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SlideStateBtn(
                                label: 'Pause',
                                icon: Icons.pause_circle_outline,
                                active: _sessionState == PublicScreenState.pause,
                                onTap: () => _setSessionState(PublicScreenState.pause),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _SlideStateBtn(
                                label: 'Ende',
                                icon: Icons.stop_circle_outlined,
                                active: _sessionState == PublicScreenState.ended,
                                onTap: () => _setSessionState(PublicScreenState.ended),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_statusMsg != null)
                      Container(
                        color: const Color(0xFF1A1A2E),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        width: double.infinity,
                        child: Text(
                          _statusMsg!,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    // ── Navigations-Leiste ──────────────────────────
                    _buildNavBar(),
                  ],
                ),
      ),
    );
  }

  // ── Leerer Zustand ────────────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.music_note, size: 80, color: Colors.white24),
          const SizedBox(height: 16),
          const Text('Kein Lied-Ordner gewählt',
              style: TextStyle(color: Colors.white54, fontSize: 16)),
          const SizedBox(height: 8),
          Text(
            Platform.isAndroid
                ? 'Ordner mit .sng- oder .txt-Dateien wählen,\noder Lieder von USB-Stick laden.'
                : 'Ordner mit .sng- oder .txt-Dateien wählen.',
            style: const TextStyle(color: Colors.white30, fontSize: 13),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('Ordner auswählen'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF5A07E9),
              foregroundColor: Colors.white,
            ),
          ),
          if (Platform.isAndroid) ...[            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _loadFromUsbSaf,
              icon: const Icon(Icons.usb),
              label: const Text('Von USB laden'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A4A7E),
                foregroundColor: Colors.white,
              ),
            ),
          ],
          if (_folderPath != null && _items.isEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Keine Lied-Dateien in:\n$_folderPath',
              style:
                  const TextStyle(color: Colors.red, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  // ── Titelfolie ───────────────────────────────────────────────────────────

  Widget _buildTitleSlide(Color bg) {
    final song = _currentSong!;
    final metaLines = <String>[];
    if (song.ccli.isNotEmpty)      metaLines.add('CCLI Song #${song.ccli}');
    if (song.copyright.isNotEmpty) metaLines.add(song.copyright);
    if (song.author.isNotEmpty)    metaLines.add(song.author);
    final license = widget.session?.ccliLicense ?? '';
    if (license.isNotEmpty)        metaLines.add('CCLI Gemeinde #$license');

    return LayoutBuilder(builder: (context, constraints) {
      return Container(
        color: bg,
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Titel Lied Titel: gelb, etwas kleiner (flex 2 statt 3)
            Flexible(
              flex: 2,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  song.title,
                  style: const TextStyle(
                    color: Color(0xFFFFDD00),
                    fontSize: 120,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            if (metaLines.isNotEmpty) ...[
              const SizedBox(height: 12),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: metaLines.map((line) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      height: 1.5,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                )).toList(),
              ),
            ],
          ],
        ),
      );
    });
  }

  // ── Folie ─────────────────────────────────────────────────────────────────

  // ── Folie mit Seitenverhältnis ────────────────────────────────────────────

  Widget _buildSlideWithAspectRatio(Widget child) {
    final ori = widget.session?.orientation;
    if (ori == PublicScreenOrientation.landscape) {
      return AspectRatio(aspectRatio: 16 / 9, child: child);
    } else if (ori == PublicScreenOrientation.portrait) {
      return AspectRatio(aspectRatio: 9 / 16, child: child);
    }
    // Keine Session → füllt den verfügbaren Platz
    return SizedBox(width: double.infinity, height: double.infinity, child: child);
  }

  Widget _buildSlide() {
    // Gleiche Farblogik wie in der Folienliste:
    // aktiv übertragen = helleres Grün, früher gesendet = dunkelgrün,
    // noch nicht gesendet = dunkelrot
    return _buildSlideAt(_stropheIndex, _listTileBg(_stropheIndex));
  }

  /// Rendert eine Folie für einen beliebigen Strophen-Index des aktuellen
  /// Liedes (-1 = Titelfolie) mit vorgegebener Hintergrundfarbe.
  Widget _buildSlideAt(int stropheIdx, Color bg) {
    // ── Titelfolie ──────────────────────────────────────────────
    if (_currentSong != null && stropheIdx < 0) return _buildTitleSlide(bg);

    // ── Bild-Folie ──────────────────────────────────────────────
    final image = _currentImage;
    if (image != null) {
      final imgWidget = image.isContentUri
          ? FutureBuilder<Uint8List?>(
              // key: URI als Key damit Flutter bei Bildwechsel neu lädt
              key: ValueKey(image.uri),
              future: UsbSafService.readUsbFile(image.uri),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator(color: Colors.white38));
                }
                final bytes = snap.data;
                if (bytes == null) {
                  return const Center(child: Icon(Icons.broken_image, color: Colors.white38, size: 64));
                }
                return Image.memory(bytes, fit: BoxFit.contain);
              },
            )
          : Image.file(File(image.uri), fit: BoxFit.contain,
              errorBuilder: (_, __, ___) =>
                  const Center(child: Icon(Icons.broken_image, color: Colors.white38, size: 64)));
      return Container(
        color: bg,
        width: double.infinity,
        height: double.infinity,
        child: imgWidget,
      );
    }
    // ── Text-Folie ──────────────────────────────────────────────
    final song = _currentSong;
    final strophe = (song != null &&
            stropheIdx >= 0 &&
            stropheIdx < song.strophes.length)
        ? song.strophes[stropheIdx]
        : null;
    final session = widget.session;
    final textSizeMode = session?.textSizeMode ?? TextSizeMode.perSlide;
    // fixed: genau die eingestellte Größe; sonst: sehr groß damit FittedBox
    // auf max. verfügbare Fläche skaliert (entspricht viewer 'perSlide'/'uniform')
    final baseFontSize = textSizeMode == TextSizeMode.fixed
        ? (session!.fixedFontSize).toDouble()
        : 200.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;
        final vPad = isLandscape ? 16.0 : 24.0;

        return Container(
          color: bg,
          width: double.infinity,
          height: double.infinity,
          padding: EdgeInsets.fromLTRB(24, vPad, 24, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Erste Liedfolie: Lied-Titel oben (gelb, fett)
              if (stropheIdx == 0 && song != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topCenter,
                      child: Text(
                        song.title,
                        style: const TextStyle(
                          color: Color(0xFFFFDD00),
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              if (strophe != null)
                // FittedBox: skaliert runter wenn nötig (fixed) oder bis max
                // Fläche füllt (perSlide/uniform) – wie der Internet-Viewer.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      strophe.text,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: baseFontSize,
                        height: 1.55,
                        fontWeight: FontWeight.w400,
                      ),
                      textAlign: TextAlign.center,
                      softWrap: true,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // ── Vollbild ──────────────────────────────────────────────────────────────

  /// Geräte-Orientierung passend zum Vollbild-Modus sperren:
  /// Listenansicht → immer Portrait (mehrere Folien untereinander sichtbar),
  /// Einzelfolie → passend zur Session-Einstellung.
  void _applyFullscreenOrientation() {
    final ori = widget.session?.orientation;
    if (!_listMode && ori == PublicScreenOrientation.landscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      // Listenansicht, Portrait-Session oder keine Session → Hochformat
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  Future<void> _enterFullscreen({bool? listMode}) async {
    if (listMode != null && listMode != _listMode) {
      _listMode = listMode;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('sng_list_mode', _listMode);
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _applyFullscreenOrientation();
    setState(() => _isFullscreen = true);
  }

  void _exitFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Zurück zu Portrait (wie in main.dart)
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    setState(() => _isFullscreen = false);
  }

  /// Einheitliche Aktionsleiste (oben rechts) für beide Vollbild-Ansichten:
  /// Neu laden, Ordner wählen, Lied suchen, Vollbild/Folienliste umschalten,
  /// Vollbild beenden – dieselben Aktionen wie in der Normalansicht-AppBar.
  Widget _buildFullscreenTopBar() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.refresh, color: Colors.white70, size: 22),
          tooltip: 'Neu laden (Cache leeren)',
          visualDensity: VisualDensity.compact,
          onPressed: _loading ? null : _forceReload,
        ),
        IconButton(
          icon: const Icon(Icons.folder_open, color: Colors.white70, size: 22),
          tooltip: 'Ordner wählen',
          visualDensity: VisualDensity.compact,
          onPressed: _pickFolder,
        ),
        IconButton(
          icon: const Icon(Icons.search, color: Colors.white70, size: 22),
          tooltip: 'Lied suchen',
          visualDensity: VisualDensity.compact,
          onPressed: _showSongSearch,
        ),
        IconButton(
          icon: Icon(
            _listMode ? Icons.rectangle_outlined : Icons.view_agenda_outlined,
            color: Colors.white70, size: 22,
          ),
          tooltip: _listMode ? 'Einzelfolie' : 'Folienliste',
          visualDensity: VisualDensity.compact,
          onPressed: _toggleListMode,
        ),
        IconButton(
          icon: const Icon(Icons.fullscreen_exit, color: Colors.white70, size: 22),
          tooltip: 'Vollbild beenden',
          visualDensity: VisualDensity.compact,
          onPressed: _exitFullscreen,
        ),
      ],
    );
  }

  Widget _buildFullscreenBody() {
    if (_listMode) return _buildFullscreenListBody();
    final String infoText;
    if (_currentSong != null) {
      if (_isTitleSlide) {
        infoText = 'Titelfolie  –  Lied ${_songIndex + 1}/${_items.length}';
      } else {
        final strophePrefix = _currentStrophe?.title.isNotEmpty == true
            ? '${_currentStrophe!.title}  · '
            : '';
        infoText = '${strophePrefix}Abschnitt ${_stropheIndex + 1}/${_currentSong!.strophes.length}'
            '  –  Lied ${_songIndex + 1}/${_items.length}';
      }
    } else {
      infoText = 'Bild ${_songIndex + 1}/${_items.length}';
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Folie füllt den ganzen Bildschirm
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (widget.session != null && !_uploading) _uploadSlide();
          },
          onPanEnd: (details) {
            final dx = details.velocity.pixelsPerSecond.dx;
            final dy = details.velocity.pixelsPerSecond.dy;
            const t = 400.0;
            if (dx.abs() > dy.abs()) {
              if (dx < -t) { _nextSong(); }    // links → nächstes Lied
              else if (dx > t) { _prevSong(); }  // rechts → vorheriges Lied
            } else {
              if (dy < -t) { _nextStrophe(); }   // hoch → nächste Folie
              else if (dy > t) { _prevStrophe(); } // runter → vorherige Folie
            }
          },
          child: _buildSlide(),
        ),
        // Oberes Info-Overlay: Titel + Strophe (gelb) links, Aktionsleiste rechts
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      _currentSong != null
                          ? '${_currentSong!.title}  ·  $infoText'
                          : infoText,
                      style: const TextStyle(
                        color: Color(0xFFFFDD00), fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                _buildFullscreenTopBar(),
              ],
            ),
          ),
        ),
        // Status-Meldung (nur Fehler – Erfolg erkennbar an Hintergrundfarbe)
        if (_statusMsg != null && _statusMsg != 'Sende …' && !_statusMsg!.startsWith('✓'))
          Positioned(
            top: 80, left: 24, right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusMsg!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        // Untere Steuerleiste
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _buildFullscreenBottomBar(),
        ),
      ],
    );
  }

  // ── Vollbild: Folienliste ─────────────────────────────────────────────────

  /// Seitenverhältnis der Folien-Kacheln (wie Ziel-Anzeige).
  double get _slideAspect =>
      widget.session?.orientation == PublicScreenOrientation.portrait
          ? 9 / 16
          : 16 / 9;

  /// Hintergrundfarbe einer Folie (gilt für alle drei Darstellungen:
  /// Normalansicht, Vollbild-Einzelfolie und Folienliste).
  Color _listTileBg(int stropheIdx) {
    if (widget.session == null) {
      return const Color.fromARGB(255, 13, 87, 42);  // keine Session → neutral grün
    }
    if (stropheIdx == _activeStropheIndex) {
      return const Color.fromARGB(255, 33, 150, 83);  // helleres Grün: aktiv übertragen
    }
    if (_sentStropheIndices.contains(stropheIdx)) {
      return const Color.fromARGB(255, 13, 87, 42);   // dunkelgrün: früher gesendet
    }
    return const Color.fromARGB(255, 141, 80, 80);    // dunkelrot: noch nicht gesendet
  }

  Future<void> _sendSlideAt(int stropheIdx) async {
    if (_uploading) return;
    setState(() {
      _stropheIndex = stropheIdx;
      _statusMsg = null;
    });
    if (widget.session != null) {
      await _uploadSlide();
    }
  }

  Future<void> _toggleListMode() async {
    setState(() => _listMode = !_listMode);
    if (_isFullscreen) _applyFullscreenOrientation();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sng_list_mode', _listMode);
  }

  /// Strg+Mausrad in der Folienliste: Foliengröße zoomen (1–4 Spalten).
  void _onListPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!HardwareKeyboard.instance.isControlPressed) return;
    final next = (_listCols + (event.scrollDelta.dy > 0 ? 1 : -1)).clamp(1, 4);
    if (next == _listCols) return;
    setState(() => _listCols = next);
    SharedPreferences.getInstance()
        .then((p) => p.setInt('sng_list_cols', next));
  }

  /// Pfeiltasten in der Folienliste: Auswahl (gelber Rahmen) verschieben,
  /// ohne zu senden. Senden erst per Leertaste/Antippen.
  void _moveSelection(int delta) {
    final song = _currentSong;
    if (song == null) {
      if (delta > 0) { _nextSong(); } else { _prevSong(); }
      return;
    }
    final next =
        (_stropheIndex + delta).clamp(-1, song.strophes.length - 1);
    if (next == _stropheIndex) return;
    setState(() {
      _stropheIndex = next;
      _statusMsg = null;
    });
    _scrollToSelection();
  }

  /// Scrollt die Folienliste so, dass die ausgewählte Folie sichtbar ist.
  void _scrollToSelection() {
    if (!_listScrollCtrl.hasClients) return;
    final row = (_stropheIndex + 1) ~/ _listCols;
    final target = (row * _lastListItemH - 80)
        .clamp(0.0, _listScrollCtrl.position.maxScrollExtent);
    _listScrollCtrl.animateTo(target,
        duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
  }

  Widget _buildFullscreenListBody() {
    final song = _currentSong;
    final slideCount = song != null ? song.strophes.length + 1 : 1;
    final String infoText = song != null
        ? 'Lied ${_songIndex + 1}/${_items.length}  –  '
          '${song.strophes.length} Abschnitte'
        : 'Bild ${_songIndex + 1}/${_items.length}';

    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrollbare Folienliste; horizontal wischen → Liedwechsel;
        // Desktop: Strg+Mausrad zoomt (Spaltenzahl 1–4)
        Listener(
          onPointerSignal: _onListPointerSignal,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (details) {
              final dx = details.velocity.pixelsPerSecond.dx;
              const t = 400.0;
              if (dx < -t) { _nextSong(); }        // links → nächstes Lied
              else if (dx > t) { _prevSong(); }    // rechts → vorheriges Lied
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final physics = _ctrlDown
                    ? const NeverScrollableScrollPhysics()
                    : null;
                if (_listCols <= 1) {
                  _lastListItemH =
                      (constraints.maxWidth - 24) / _slideAspect + 34;
                  return ListView.builder(
                    controller: _listScrollCtrl,
                    physics: physics,
                    padding: const EdgeInsets.fromLTRB(12, 64, 12, 90),
                    itemCount: slideCount,
                    itemBuilder: (context, i) {
                      final stropheIdx = song != null ? i - 1 : -1;
                      return _buildListSlideTile(song, stropheIdx);
                    },
                  );
                }
                // Mehrspaltig: Zellhöhe = Folie + Kopfzeile + Abstand
                final cellW = (constraints.maxWidth -
                        24 - (_listCols - 1) * 12) / _listCols;
                final cellH = cellW / _slideAspect + 40;
                _lastListItemH = cellH;
                return GridView.builder(
                  controller: _listScrollCtrl,
                  physics: physics,
                  padding: const EdgeInsets.fromLTRB(12, 64, 12, 90),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _listCols,
                    crossAxisSpacing: 12,
                    childAspectRatio: cellW / cellH,
                  ),
                  itemCount: slideCount,
                  itemBuilder: (context, i) {
                    final stropheIdx = song != null ? i - 1 : -1;
                    return _buildListSlideTile(song, stropheIdx);
                  },
                );
              },
            ),
          ),
        ),
        // Oberes Info-Overlay: Titel + Liedposition (links), Aktionsleiste (rechts)
        Positioned(
          top: 0, left: 0, right: 0,
          child: SafeArea(
            bottom: false,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (song != null)
                            Text(
                              song.title,
                              style: const TextStyle(
                                color: Color(0xFFFFDD00), fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          Text(
                            infoText,
                            style: const TextStyle(
                              color: Color(0xFF8888FF), fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildFullscreenTopBar(),
                ],
              ),
            ),
          ),
        ),
        // Status-Meldung (nur Fehler)
        if (_statusMsg != null && _statusMsg != 'Sende …' && !_statusMsg!.startsWith('✓'))
          Positioned(
            top: 80, left: 24, right: 24,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _statusMsg!,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        // Untere Steuerleiste
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: _buildFullscreenBottomBar(),
        ),
      ],
    );
  }

  Widget _buildListSlideTile(SngSong? song, int stropheIdx) {
    final String header;
    if (song == null) {
      header = 'Bild';
    } else if (stropheIdx < 0) {
      header = 'Titelfolie';
    } else {
      final strophe = song.strophes[stropheIdx];
      final pos = '( ${stropheIdx + 1} / ${song.strophes.length} )';
      header = strophe.title.isNotEmpty ? '${strophe.title}  $pos' : pos;
    }
    final bg = _listTileBg(stropheIdx);
    final isActiveUploading = _uploading && stropheIdx == _stropheIndex;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 2, left: 4),
            child: Text(
              header,
              style: const TextStyle(
                color: Color(0xFF8888FF), fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _sendSlideAt(stropheIdx),
            child: AspectRatio(
              aspectRatio: _slideAspect,
              child: Container(
                // Ausgewählte Folie (Pfeiltasten): gelber Rahmen
                foregroundDecoration: stropheIdx == _stropheIndex
                    ? BoxDecoration(
                        border: Border.all(
                            color: const Color(0xFFFFDD00), width: 3),
                      )
                    : null,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildSlideAt(stropheIdx, bg),
                    if (isActiveUploading)
                      Container(
                        color: Colors.black38,
                        child: const Center(
                          child: SizedBox(
                            width: 32, height: 32,
                            child: CircularProgressIndicator(
                                color: Colors.white70, strokeWidth: 3),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenBottomBar() {
    final hasSession = widget.session != null;
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            if (hasSession) ...[
              Expanded(
                child: _SlideStateBtn(
                  label: 'Start',
                  icon: Icons.play_circle_outline,
                  active: _sessionState == PublicScreenState.start,
                  onTap: () => _setSessionState(PublicScreenState.start),
                  transparent: true,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _SlideStateBtn(
                  label: 'Pause',
                  icon: Icons.pause_circle_outline,
                  active: _sessionState == PublicScreenState.pause,
                  onTap: () => _setSessionState(PublicScreenState.pause),
                  transparent: true,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _SlideStateBtn(
                  label: 'Ende',
                  icon: Icons.stop_circle_outlined,
                  active: _sessionState == PublicScreenState.ended,
                  onTap: () => _setSessionState(PublicScreenState.ended),
                  transparent: true,
                ),
              ),
              const SizedBox(width: 8),
            ],
            if (hasSession && !_listMode)
              // Auto-Senden (nur in Einzelfolien-Ansicht sinnvoll)
              GestureDetector(
                onTap: () => _setAutoSend(!_autoSend),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Checkbox(
                    value: _autoSend,
                    onChanged: (v) => _setAutoSend(v ?? false),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: Colors.green.shade400,
                    side: const BorderSide(color: Colors.white38),
                  ),
                ),
              ),
            if (!hasSession)
              const Expanded(
                child: Text(
                  'Keine Session',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Navigations-Leiste ────────────────────────────────────────────────────

  Widget _buildNavBar() {
    final hasSession = widget.session != null;
    return Container(
      color: const Color(0xFF111122),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 1. Lied-Datei zurück
            _NavBtn(
              icon: Icons.skip_previous,
              tooltip: 'Lied zurück',
              onTap: _prevSong,
            ),
            // 2. Lied-Datei vor
            _NavBtn(
              icon: Icons.skip_next,
              tooltip: 'Nächstes Lied',
              onTap: _nextSong,
            ),
            // 3. Auto-Senden Checkbox (kein Label)
            if (hasSession)
              GestureDetector(
                onTap: () => _setAutoSend(!_autoSend),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Checkbox(
                    value: _autoSend,
                    onChanged: (v) => _setAutoSend(v ?? false),
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    activeColor: Colors.green.shade400,
                    side: const BorderSide(color: Colors.white38),
                  ),
                ),
              ),
            // 4. Senden-Button
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: ElevatedButton.icon(
                  onPressed: (_uploading || !hasSession) ? null : _uploadSlide,
                  icon: _uploading
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_upload, size: 18),
                  label: Text(
                    hasSession ? 'Senden' : 'Keine Session',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: (hasSession && !_autoSend)
                        ? Colors.green.shade700
                        : Colors.grey.shade800,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ),
            // 5. Folie zurück
            _NavBtn(
              icon: Icons.arrow_upward,
              tooltip: 'Strophe zurück',
              onTap: _prevStrophe,
            ),
            // 6. Folie vor
            _NavBtn(
              icon: Icons.arrow_downward,
              tooltip: 'Nächste Strophe',
              onTap: _nextStrophe,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Navigations-Button ────────────────────────────────────────────────────────

class _NavBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _NavBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 56,
          height: 52,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A3E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white12),
          ),
          child: Icon(icon, color: Colors.white70, size: 26),
        ),
      ),
    );
  }
}

// Ergebnis des SAF-Ordner-Browsers
class _UsbFolderResult {
  final String path;      // relativer Pfad (leer = Root)
  final bool recouple;    // true → neu koppeln

  const _UsbFolderResult({required this.path, this.recouple = false});
}

/// Ordner-Browser für gekoppelte USB-Sticks.
/// Navigiert ausschließlich via SAF (DocumentFile.listFiles), ohne FilePicker.
class _UsbFolderBrowserDialog extends StatefulWidget {
  const _UsbFolderBrowserDialog();

  @override
  State<_UsbFolderBrowserDialog> createState() => _UsbFolderBrowserDialogState();
}

class _UsbFolderBrowserDialogState extends State<_UsbFolderBrowserDialog> {
  final List<String> _stack = [];  // Breadcrumb-Stack (leer = Root)
  List<String> _dirs = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDirs();
  }

  String get _currentPath => _stack.join('/');

  Future<void> _loadDirs() async {
    setState(() { _loading = true; _error = null; });
    try {
      final path = _currentPath;
      final dirs = await UsbSafService.listSubDirs(
        subPath: path.isEmpty ? null : path,
      );
      if (mounted) { setState(() { _dirs = dirs; _loading = false; }); }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final path = _currentPath;
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Ordner wählen', style: TextStyle(color: Colors.white)),
          Text(
            path.isEmpty ? '/ (Stick-Root)' : '/ ${path.replaceAll('/', ' / ')}',
            style: const TextStyle(color: Color(0xFF8888FF), fontSize: 12),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white54))
            : _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.usb_off, color: Colors.red, size: 48),
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
                    ],
                  )
                : Column(
                    children: [
                      // Aktuellen Ordner laden
                      ListTile(
                        leading: const Icon(Icons.folder_open, color: Color(0xFFFFDD00)),
                        title: Text(
                          path.isEmpty ? 'Stick-Root laden' : '"${_stack.last}" laden',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                        onTap: () => Navigator.pop(
                          context,
                          _UsbFolderResult(path: path),
                        ),
                      ),
                      const Divider(color: Colors.white24, height: 1),
                      // Unterordner
                      Expanded(
                        child: _dirs.isEmpty
                            ? const Center(
                                child: Text(
                                  'Keine Unterordner',
                                  style: TextStyle(color: Colors.white38),
                                ),
                              )
                            : ListView.builder(
                                itemCount: _dirs.length,
                                itemBuilder: (_, i) => ListTile(
                                  leading: const Icon(Icons.folder, color: Color(0xFF7090B0)),
                                  title: Text(
                                    _dirs[i],
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                                  onTap: () {
                                    setState(() { _stack.add(_dirs[i]); });
                                    _loadDirs();
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
      ),
      actions: [
        if (_stack.isNotEmpty)
          TextButton.icon(
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Zurück'),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            onPressed: () {
              setState(() { _stack.removeLast(); });
              _loadDirs();
            },
          ),
        TextButton(
          onPressed: () => Navigator.pop(context, null), // Abbrechen
          style: TextButton.styleFrom(foregroundColor: Colors.white38),
          child: const Text('Abbrechen'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.check, size: 16),
          label: const Text('OK'),
          onPressed: () => Navigator.pop(context, _UsbFolderResult(path: path)),
        ),
        TextButton.icon(
          icon: const Icon(Icons.usb, size: 16),
          label: const Text('Neu koppeln'),
          style: TextButton.styleFrom(foregroundColor: Colors.orange),
          onPressed: () => Navigator.pop(
            context,
            const _UsbFolderResult(path: '', recouple: true),
          ),
        ),
      ],
    );
  }
}

// Pastell-Grün aktiv / Grau inaktiv, immer anklickbar
class _SlideStateBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final bool transparent;

  const _SlideStateBtn({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.transparent = false,
  });

  // Pastell-Grün
  static const _activeColor = Color(0xFF81C784);
  // Grau für dunklen Hintergrund
  static const _inactiveBg  = Color(0xFF2A2A3A);
  static const _inactiveFg  = Color(0xFF888899);

  @override
  Widget build(BuildContext context) {
    if (transparent) {
      return ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: active ? _activeColor : _inactiveFg,
          elevation: 0,
          shadowColor: Colors.transparent,
          side: active
              ? const BorderSide(color: _activeColor, width: 1.5)
              : BorderSide(color: _inactiveFg.withValues(alpha: 0.35), width: 1),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ).copyWith(
          overlayColor: WidgetStateProperty.all(
            Colors.white.withValues(alpha: 0.08),
          ),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: onTap, // immer anklickbar
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: active ? _activeColor : _inactiveBg,
        foregroundColor: active ? const Color(0xFF1B3A1C) : _inactiveFg,
        elevation: active ? 3 : 0,
        side: active
            ? BorderSide.none
            : const BorderSide(color: Color(0xFF3A3A4A), width: 1),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shadowColor: active ? _activeColor.withValues(alpha: 0.5) : Colors.transparent,
      ),
    );
  }
}

// ── Lied-Such-Screen ──────────────────────────────────────────────────────────

class _SongSearchScreen extends StatefulWidget {
  final List<PlaylistItem> items;

  const _SongSearchScreen({required this.items});

  @override
  State<_SongSearchScreen> createState() => _SongSearchScreenState();
}

class _SongSearchScreenState extends State<_SongSearchScreen> {
  final _searchController = TextEditingController();
  late List<int> _filteredIndices;

  @override
  void initState() {
    super.initState();
    _filteredIndices = List.generate(widget.items.length, (i) => i);
    _searchController.addListener(_onSearch);
  }

  void _onSearch() {
    final q = _searchController.text.toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filteredIndices = List.generate(widget.items.length, (i) => i);
        return;
      }
      _filteredIndices = [
        for (int i = 0; i < widget.items.length; i++)
          if (_matches(widget.items[i], q)) i,
      ];
    });
  }

  bool _matches(PlaylistItem item, String q) {
    if (item is SongItem) {
      final song = item.song;
      if (song.title.toLowerCase().contains(q)) return true;
      if (song.author.toLowerCase().contains(q)) return true;
      if (song.ccli.toLowerCase().contains(q)) return true;
      if (song.copyright.toLowerCase().contains(q)) return true;
      return song.strophes.any((s) => s.text.toLowerCase().contains(q));
    } else if (item is ImageItem) {
      return item.fileNameWithExt.toLowerCase().contains(q);
    }
    return false;
  }

  @override
  void dispose() {
    _searchController.removeListener(_onSearch);
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A2E),
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontSize: 16),
          decoration: const InputDecoration(
            hintText: 'Lied suchen …',
            hintStyle: TextStyle(color: Colors.white38),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 4),
            prefixIcon: Icon(Icons.search, color: Colors.white38),
          ),
        ),
      ),
      body: _filteredIndices.isEmpty
          ? const Center(
              child: Text(
                'Kein Lied gefunden',
                style: TextStyle(color: Colors.white38, fontSize: 15),
              ),
            )
          : NotificationListener<ScrollStartNotification>(
              onNotification: (notification) {
                // Tastatur einklappen sobald gescrollt wird
                FocusScope.of(context).unfocus();
                return false;
              },
              child: ListView.builder(
              itemCount: _filteredIndices.length,
              itemBuilder: (_, i) {
                final idx = _filteredIndices[i];
                final item = widget.items[idx];
                final String title;
                final String subtitle;
                final IconData leadIcon;
                if (item is SongItem) {
                  title = item.song.title;
                  leadIcon = Icons.music_note;
                  final List<String> lines = [];
                  outer:
                  for (final strophe in item.song.strophes) {
                    for (final line in strophe.text.split('\n')) {
                      final t = line.trim();
                      if (t.isNotEmpty) {
                        lines.add(t);
                        if (lines.length == 2) break outer;
                      }
                    }
                  }
                  subtitle = lines.join(' – ');
                } else if (item is ImageItem) {
                  title = item.fileNameWithExt;
                  subtitle = 'Bild';
                  leadIcon = Icons.image;
                } else {
                  title = item.fileNameWithExt;
                  subtitle = '';
                  leadIcon = Icons.insert_drive_file;
                }
                return ListTile(
                  dense: true,
                  visualDensity: const VisualDensity(vertical: -2),
                  leading: Icon(leadIcon, color: const Color(0xFF7090B0)),
                  title: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: subtitle.isNotEmpty
                      ? Text(
                          subtitle,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, idx),
                );
              },
            ),
            ),
    );
  }
}
