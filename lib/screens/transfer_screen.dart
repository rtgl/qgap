// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:developer' as developer;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qgap/model/chat_group.dart';
import 'package:qgap/model/device_role.dart';
import 'package:qgap/model/message.dart' as qgap_model;
import 'package:qgap/model/saved_qr_entry.dart';
import 'package:qgap/screens/chat_screen.dart';
import 'package:qgap/screens/qr_data_sender.dart';
import 'package:qgap/screens/widgets/qr_scanner_dialog.dart';
import 'package:qgap/services/auth_service.dart';
import 'package:qgap/services/firestore_service.dart';
import 'package:qgap/services/local_contact_service.dart';
import 'package:qgap/services/offline_receipt_service.dart';
import 'package:qgap/services/pairing_service.dart';
import 'package:qgap/services/app_storage.dart';
import 'package:qgap/services/pickup_queue_service.dart';
import 'package:qgap/services/relay_mapping_service.dart';
import 'package:qgap/services/rsa_key_manager.dart';
import 'package:qgap/theme/app_theme.dart';

/// Transfer-Hub: QR-Galerie + Fountain-Code Senden/Empfangen + Datei-Teilen.
class TransferScreen extends StatefulWidget {
  /// Optionaler Eintrag, der beim Öffnen automatisch in die Galerie übernommen wird.
  final SavedQrEntry? pendingEntry;

  const TransferScreen({super.key, this.pendingEntry});

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  final ScrollController _scrollController = ScrollController();
  List<SavedQrEntry> _entries = [];
  final RSAKeyManager _rsaKeyManager = RSAKeyManager();
  final FirestoreService _firestore = FirestoreService();
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _transfersSub;
  // IDs bereits verarbeiteter Transfer-Dokumente (verhindert Doppel-Import).
  final Set<String> _processedTransferIds = {};

  // ─── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    // Einträge laden und ggf. pendingEntry direkt hinzufügen
    _loadEntries().then((_) {
      if (widget.pendingEntry != null && mounted) {
        _addEntry(widget.pendingEntry!);
      }
    });
    _subscribeIncomingTransfers();
  }

  @override
  void dispose() {
    _transfersSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ─── Persistenz ───────────────────────────────────────────────────────────

  static const String _prefsKey = 'saved_qr_entries';

  Future<void> _loadEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_prefsKey) ?? [];
      final loaded = <SavedQrEntry>[];
      for (final s in list) {
        try {
          loaded.add(SavedQrEntry.fromJson(json.decode(s) as Map<String, dynamic>));
        } catch (e) {
          developer.log('log: Fehler beim Laden von QR-Eintrag: $e', name: 'TransferScreen');
        }
      }
      if (mounted) setState(() => _entries = loaded);
    } catch (e) {
      developer.log('log: Fehler beim Laden der QR-Einträge: $e', name: 'TransferScreen');
    }
  }

  Future<void> _saveEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _entries.map((e) => json.encode(e.toJson())).toList();
    await prefs.setStringList(_prefsKey, list);
  }

  Future<void> _addEntry(SavedQrEntry entry) async {
    setState(() => _entries.add(entry));
    await _saveEntries();
    // Ans Ende scrollen
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _deleteEntry(String id) async {
    setState(() => _entries.removeWhere((e) => e.id == id));
    await _saveEntries();
  }

  /// Bestätigungsdialog für "Alle löschen"
  void _confirmDeleteAll() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Alle löschen?'),
          ],
        ),
        content: Text(
          'Möchten Sie wirklich alle ${_entries.length} gespeicherten QR-Codes löschen?\n\nDieser Vorgang kann nicht rückgängig gemacht werden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _deleteAllEntries();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Alle löschen'),
          ),
        ],
      ),
    );
  }

  /// Löscht alle gespeicherten QR-Code-Einträge
  Future<void> _deleteAllEntries() async {
    setState(() => _entries.clear());
    await _saveEntries();
    if (mounted) {
      showQgapSnackBar(context, 
        const SnackBar(
          content: Text('Alle QR-Codes wurden gelöscht'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      appBar: AppBar(
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('📡', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Text('Transfer-Hub'),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Alle löschen',
            onPressed: _entries.isEmpty ? null : _confirmDeleteAll,
          ),
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Hilfe',
            onPressed: _showHelp,
          ),
        ],
      ),
      body: Column(
        children: [
          // 📥 Offline-Pickup-Queue (sichtbar wenn Online-Relay aktiv ODER
          // mindestens ein Eintrag wartet)
          _PickupQueueSection(
            onChanged: () {
              if (mounted) setState(() {});
            },
          ),
          // Scrollbarer Chat-Bereich
          Expanded(
            child: _entries.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    itemCount: _entries.length,
                    itemBuilder: (context, index) =>
                        _buildEntryBubble(_entries[index]),
                  ),
          ),
          // Bottom-Aktionsleiste
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.qr_code_2, size: 80, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text(
            'Noch keine QR-Codes gespeichert',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Scannen, manuell eingeben oder QR-Codes\nper Fountain-Code empfangen',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // ─── Eintrag-Bubble ───────────────────────────────────────────────────────

  Widget _buildEntryBubble(SavedQrEntry entry) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          CircleAvatar(
            backgroundColor: Colors.teal.shade100,
            radius: 20,
            child: Text(
              entry.category.emoji,
              style: const TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(width: 8),
          // Bubble
          Expanded(
            child: GestureDetector(
              onTap: () => _showFullscreenQr(entry),
              onLongPress: () => _showEntryActions(entry),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(16),
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Kopfzeile: Name + Stift + Kategorie-Badge
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _renameEntry(entry),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 2),
                            child: Icon(Icons.edit,
                                size: 14, color: Colors.grey.shade400),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.teal.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.teal.shade200),
                          ),
                          child: Text(
                            entry.category.label,
                            style: TextStyle(
                                fontSize: 11, color: Colors.teal.shade700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // QR-Vorschau + Inhalts-Vorschau nebeneinander
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // QR-Vorschau
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildQrPreview(entry),
                        ),
                        const SizedBox(width: 10),
                        // Inhalts-Vorschau
                        Expanded(
                          child: Text(
                            _getEntryPreviewText(entry),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade700,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Aktionsleiste
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _bubbleActionBtn(
                          icon: Icons.fullscreen,
                          label: 'Vollbild',
                          onTap: () => _showFullscreenQr(entry),
                        ),
                        const SizedBox(width: 8),
                        _bubbleActionBtn(
                          icon: QgapIcons.send,
                          label: 'Senden',
                          color: QgapColors.fileSend,
                          onTap: () => _sendEntryViaFountain(entry),
                        ),
                        const SizedBox(width: 8),
                        _bubbleActionBtn(
                          icon: QgapIcons.fileShare,
                          label: 'Teilen',
                          color: QgapColors.fileShare,
                          onTap: () => _shareEntryText(entry),
                        ),
                        const SizedBox(width: 8),
                        _bubbleActionBtn(
                          icon: Icons.copy,
                          label: 'Kopieren',
                          color: Colors.blueGrey,
                          onTap: () {
                            final text = _getEntryPreviewText(entry);
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('In Zwischenablage kopiert'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        _bubbleActionBtn(
                          icon: Icons.delete_outline,
                          label: 'Löschen',
                          color: Colors.red,
                          onTap: () => _confirmDeleteEntry(entry),
                        ),
                        const SizedBox(width: 4),
                        // Zeitstempel rechts
                        Text(
                          _formatDate(entry.savedAt),
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade400),
                        ),
                      ],
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

  Widget _bubbleActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color ?? Colors.teal.shade700),
            Text(
              label,
              style: TextStyle(
                  fontSize: 9, color: color ?? Colors.teal.shade700),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Bottom-Aktionsleiste ─────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).padding.bottom + 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _bottomBtn(
            icon: QgapIcons.qrScan,
            label: 'Scannen',
            color: QgapColors.qrScan,
            onTap: _actionScanQr,
          ),
          _bottomBtn(
            icon: Icons.edit_note,
            label: 'Neu',
            onTap: _actionNewManual,
          ),
          _bottomBtn(
            icon: QgapIcons.fileSend,
            label: 'Senden',
            color: QgapColors.fileSend,
            onTap: _actionSendFountain,
          ),
          _bottomBtn(
            icon: QgapIcons.fileShare,
            label: 'Datei teilen',
            color: QgapColors.fileShare,
            onTap: _actionShareFile,
          ),
          _bottomBtn(
            icon: QgapIcons.fileImport,
            label: 'Importieren',
            color: QgapColors.fileImport,
            onTap: _actionImportQGapFile,
          ),
          _bottomBtn(
            icon: Icons.cloud_upload_outlined,
            label: 'An User',
            color: Colors.indigo,
            onTap: _actionSendToUser,
          ),
        ],
      ),
    );
  }

  Widget _bottomBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: color ?? Colors.teal.shade700),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(fontSize: 10, color: color ?? Colors.teal.shade800),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Aktionen Bottom-Bar ──────────────────────────────────────────────────

  /// 📷 Universal-Scanner: erkennt automatisch Einzel-QR oder Fountain-Code.
  Future<void> _actionScanQr() async {
    final result = await Navigator.of(context).push<ScanResult>(
      MaterialPageRoute(builder: (_) => const QRScannerDialog()),
    );
    if (result == null || !mounted) return;

    // ── Fountain-Code (Binärdaten) ────────────────────────────────────────
    if (result is ScanResultBytes) {
      await _handleReceivedBytes(result.bytes);
      return;
    }

    // ── Normaler QR-Code (String) ─────────────────────────────────────────
    if (result is ScanResultText) {
      final scanned = result.text;
      if (scanned.isEmpty) return;

      final category = SavedQrEntry.detectCategory(scanned);

      // RSA-Public-Key direkt importieren
      if (category == QrCategory.rsaKey) {
        await _handleRsaKeyImport(scanned);
        return;
      }

      // QGap-QR-Code: automatisch in Galerie + Chat-Import
      if (category == QrCategory.qgap) {
        await _autoSaveToGallery(scanned, QrCategory.qgap);
        if (!mounted) return;
        // Zuerst: .qgap_ec Datei auto-erkennen (mit Bestätigung)
        final handled = await _tryEcFileAutoAssign(scanned);
        if (!handled && mounted) await _importQGapContent(scanned, null);
        return;
      }

      // Link / Text / Sonstiges: Speichern-Dialog
      await _showSaveEntryDialog(content: scanned, category: category);
    }
  }

  /// ✏️ Manuell neuen Eintrag erstellen.
  Future<void> _actionNewManual() async {
    await _showSaveEntryDialog();
  }

  /// 📤 Fountain-Code Senden.
  Future<void> _actionSendFountain() async {
    if (!mounted) return;
    final choice = await _showSendSourceDialog();
    if (choice == null || !mounted) return;

    Uint8List? bytes;

    if (choice == 'file') {
      // .qgap Datei auswählen (KEINE .qgap_ec!)
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['qgap'],
        allowMultiple: false,
        dialogTitle: '.qgap Datei zum Senden wählen',
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final path = result.files.first.path;
      if (path == null) return;

      // Sicherheitsprüfung: .qgap_ec NIEMALS senden
      if (path.toLowerCase().endsWith('.qgap_ec')) {
        _showQGapEcBlockedDialog();
        return;
      }

      try {
        bytes = await File(path).readAsBytes();
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Lesen der Datei: $e')),
          );
        }
        return;
      }
    } else if (choice == 'clipboard') {
      // Base64 aus Clipboard
      final clipData = await Clipboard.getData('text/plain');
      final base64Str = clipData?.text?.trim() ?? '';
      if (base64Str.isEmpty) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(content: Text('Zwischenablage ist leer')),
          );
        }
        return;
      }
      try {
        bytes = base64.decode(base64Str);
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(
                content: Text('Inhalt der Zwischenablage ist kein gültiges Base64')),
          );
        }
        return;
      }
    } else if (choice == 'entry') {
      // Gespeicherten QR-Eintrag wählen
      final entry = await _showPickEntryDialog();
      if (entry == null || !mounted) return;
      bytes = Uint8List.fromList(utf8.encode(entry.content));
    }

    if (bytes == null || !mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes!)),
    );
  }

  ///  .qgap Datei teilen (KEINE .qgap_ec!).
  Future<void> _actionShareFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['qgap'],
      allowMultiple: false,
      dialogTitle: '.qgap Datei zum Teilen wählen',
    );
    if (result == null || result.files.isEmpty || !mounted) return;
    final path = result.files.first.path;
    if (path == null) return;

    // Sicherheitsprüfung: .qgap_ec NIEMALS digital teilen
    if (path.toLowerCase().endsWith('.qgap_ec')) {
      _showQGapEcBlockedDialog();
      return;
    }

    try {
      await Share.shareXFiles(
        [XFile(path)],
        subject: 'QGap-Datei',
        text: 'QGap verschlüsselte Datei',
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Teilen: $e')),
        );
      }
    }
  }

  // ─── Empfang-Verarbeitung ─────────────────────────────────────────────────

  /// 📥 .qgap Datei importieren (Dateisystem / USB-Stick / Google Drive).
  Future<void> _actionImportQGapFile() async {
    try {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['qgap'],
          allowMultiple: false,
          withData: false,
          dialogTitle: '.qgap Datei importieren',
        );
      } catch (e) {
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: false,
        );
      }
      if (result == null || result.files.isEmpty || !mounted) return;
      final picked = result.files.first;
      if (!picked.name.toLowerCase().endsWith('.qgap')) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Nur .qgap-Dateien werden unterstützt (gewählt: ${picked.name})')),
          );
        }
        return;
      }
      // Bytes lesen: Content-URI (USB-OTG, Google Drive) oder direkt
      Uint8List? bytes;
      final path = picked.path;
      if (path != null && path.isNotEmpty) {
        if (path.startsWith('content://')) {
          const ch = MethodChannel('de.paulporg.obmc/file_intent');
          final raw = await ch.invokeMethod<Uint8List>('readContentUri', path);
          bytes = raw;
        } else {
          bytes = await File(path).readAsBytes();
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(content: Text('Datei konnte nicht gelesen werden')),
          );
        }
        return;
      }
      if (mounted) await _handleReceivedBytes(bytes);
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Importieren: $e')),
        );
      }
    }
  }

  /// Verarbeitet empfangene Bytes (nach QrDataReceiver).
  Future<void> _handleReceivedBytes(Uint8List bytes) async {
    if (!mounted) return;

    // Typ bestimmen
    String? asText;
    try {
      asText = utf8.decode(bytes);
    } catch (_) {
      asText = null;
    }

    // 📨 Offline-Lesebestätigung erkennen (vom gepaarten Air-Gap-Gerät).
    // Heuristik: JSON-Objekt mit den Schlüsseln msgId, sig, readerFp.
    if (asText != null && asText.trimLeft().startsWith('{')) {
      try {
        final parsed = jsonDecode(asText);
        if (parsed is Map &&
            parsed['msgId'] != null &&
            parsed['sig'] != null &&
            parsed['readerFp'] != null) {
          await _forwardReceiptToOriginalSender(bytes, parsed);
          return;
        }
      } catch (_) {
        // Nicht-JSON oder unpassend – weiter wie gehabt.
      }
    }

    // RSA-Public-Key? (abwärtskompatibel: altes Präfix OBMC_RSA_PUB: auch akzeptieren)
    if (asText != null &&
        (asText.startsWith('QGAP_RSA_PUB:') || asText.startsWith('OBMC_RSA_PUB:'))) {
      await _handleRsaKeyImport(asText);
      return;
    }

    // Binäres QGap-Envelope erkennen (Magic 0x4F 0x42 0x4D 0x43 = "OBMC" —
    // Byte-Format bewusst unverändert, nur Branding/Text umbenannt).
    // utf8.decode kann trotzdem gelingen wenn der verschlüsselte Teil zufällig valid-UTF8 ist.
    // Deshalb Magic-Bytes explizit prüfen und asText ggf. zurücksetzen.
    if (bytes.length >= 4 &&
        bytes[0] == 0x4F && bytes[1] == 0x42 &&
        bytes[2] == 0x4D && bytes[3] == 0x43) {
      asText = null; // als binär behandeln
    }

    // Empfangene Bytes immer sofort als Galerie-Eintrag speichern (Text und Binär).
    String? b64content;
    if (asText != null && asText.isNotEmpty) {
      final cat = SavedQrEntry.detectCategory(asText);
      await _autoSaveToGallery(asText, cat);
    } else {
      // Rein binäre Daten (QGap-Datei) → sofort im Transfer-Hub sichern
      b64content = base64.encode(bytes);
      await _autoSaveToGallery(b64content, QrCategory.qgap);
    }

    // Auto-Erkennung: passende .qgap_ec Datei oder passender Chat gefunden?
    // Inhalt ist bereits gespeichert → showSaveField immer false.
    final contentForAutoAssign =
        (asText != null && asText.isNotEmpty) ? asText : b64content;
    if (contentForAutoAssign != null) {
      final handled = await _tryEcFileAutoAssign(contentForAutoAssign, showSaveField: false);
      if (handled) return;
    }

    // Ergebnis-Dialog: Was mit den Bytes tun?
    final action = await _showReceivedBytesDialog(bytes, asText);
    if (action == null || !mounted) return;

    if (action == 'save_file') {
      await _saveBytesAsQGapFile(bytes);
    } else if (action == 'clipboard') {
      final b64 = base64.encode(bytes);
      await Clipboard.setData(ClipboardData(text: b64));
      if (mounted) {
        showQgapSnackBar(context, 
          const SnackBar(
              content: Text('✅ Base64 in Zwischenablage kopiert'),
              backgroundColor: Colors.green),
        );
      }
    } else if (action == 'share') {
      await _shareBytesAsFile(bytes);
    } else if (action == 'import_chat') {
      // .qgap Inhalt → Chat-Import-Flow (Galerie-Eintrag wurde bereits oben gespeichert)
      if (asText != null) {
        if (mounted) await _importQGapContent(asText, null);
      }
    } else if (action == 'save_qr') {
      // Als QR-Eintrag speichern (nur Text-Inhalte) – Galerie-Eintrag schon vorhanden,
      // dieser Dialog erlaubt noch einen eigenen Namen zu vergeben.
      if (asText != null) {
        final cat = SavedQrEntry.detectCategory(asText);
        await _showSaveEntryDialog(content: asText, category: cat);
      }
    }
  }

  /// Gibt die korrekte Dateiendung für den Byte-Inhalt zurück:
  /// RSA-/AES-Public-Keys → .qgap_aes, alles andere → .qgap
  String _extensionForBytes(Uint8List bytes) {
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      if (text.startsWith('QGAP_RSA_PUB:') || text.startsWith('OBMC_RSA_PUB:')) {
        return '.qgap_aes';
      }
    } catch (_) {}
    return '.qgap';
  }

  /// Empfangene Bytes als Datei im Downloads/Temp speichern (.qgap oder .qgap_aes).
  Future<void> _saveBytesAsQGapFile(Uint8List bytes) async {
    final nameCtrl = TextEditingController(
        text: 'empfangen_${DateTime.now().millisecondsSinceEpoch}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              child: const Text('Speichern')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;

    final ext = _extensionForBytes(bytes);
    try {
      final dir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
              await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name$ext');
      await file.writeAsBytes(bytes);
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
              content: Text('✅ Gespeichert: ${file.path}'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Speichern: $e')),
        );
      }
    }
  }

  /// Bytes als temporäre Datei über share_plus teilen.
  Future<void> _shareBytesAsFile(Uint8List bytes) async {
    final ext = _extensionForBytes(bytes);
    // Dateinamen vom Benutzer erfragen
    final nameCtrl = TextEditingController(
        text: 'QGAP_${DateTime.now().millisecondsSinceEpoch}');
    if (!mounted) return;
    final chosenName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            suffixText: ext,
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              child: const Text('Teilen')),
        ],
      ),
    );
    if (chosenName == null || chosenName.isEmpty || !mounted) return;
    try {
      final dir = await getTemporaryDirectory();
      final tmpFile = File('${dir.path}/$chosenName$ext');
      await tmpFile.writeAsBytes(bytes);
      await Share.shareXFiles(
        [XFile(tmpFile.path, name: '$chosenName$ext')],
        subject: '$chosenName$ext',
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Teilen: $e')),
        );
      }
    }
  }

  // ─── RSA-Key-Import ───────────────────────────────────────────────────────

  Future<void> _handleRsaKeyImport(String qrData) async {
    if (!mounted) return;

    // Key laden
    final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(qrData);
    if (publicKey == null) {
      showQgapSnackBar(context, 
        const SnackBar(
            content: Text('❌ Ungültiger RSA-Public-Key'),
            backgroundColor: Colors.red),
      );
      return;
    }

    // Kontaktname abfragen + optional Hybrid-Chat anlegen
    String contactName = '';
    bool createChat = false;
    String chatName = '';

    await showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController();
        final chatCtrl = TextEditingController();
        bool createChatLocal = false;
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('🔑 RSA-Public-Key importieren'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Kontaktname:'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name (z. B. Alice)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: createChatLocal,
                        onChanged: (v) =>
                            setS(() => createChatLocal = v ?? false),
                      ),
                      const Expanded(
                          child: Text('Neuen Hybrid-Chat anlegen?')),
                    ],
                  ),
                  if (createChatLocal) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: chatCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Chat-Name',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () {
                  contactName = nameCtrl.text.trim();
                  createChat = createChatLocal;
                  chatName = chatCtrl.text.trim();
                  Navigator.of(ctx).pop();
                },
                child: const Text('Importieren'),
              ),
            ],
          );
        });
      },
    );

    if (contactName.isEmpty || !mounted) return;

    await _rsaKeyManager.saveContactPublicKey(contactName, publicKey);

    if (mounted) {
      showQgapSnackBar(context, 
        SnackBar(
          content: Text('✅ RSA-Schlüssel für "$contactName" gespeichert'),
          backgroundColor: Colors.green,
        ),
      );
    }

    // Als QR-Eintrag speichern
    final entry = SavedQrEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: 'RSA-Key: $contactName',
      content: qrData,
      category: QrCategory.rsaKey,
      savedAt: DateTime.now(),
    );
    await _addEntry(entry);

    // Optionaler neuer Hybrid-Chat
    if (createChat && chatName.isNotEmpty && mounted) {
      await _createHybridChat(chatName, contactName);
    }
  }

  /// Legt einen neuen Hybrid-Chat an und öffnet ihn.
  Future<void> _createHybridChat(String chatName, String contactName) async {
    final prefs = await SharedPreferences.getInstance();
    final newGroup = ChatGroup(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: chatName,
      description: 'Hybrid-Chat mit $contactName',
      createdAt: DateTime.now(),
      iconEmoji: '🔑',
      defaultEncryptionType: qgap_model.EncryptionType.hybrid,
    );

    final groupsJson = prefs.getStringList('chat_groups') ?? [];
    groupsJson.add(json.encode(newGroup.toJson()));
    await prefs.setStringList('chat_groups', groupsJson);

    if (!mounted) return;

    showQgapSnackBar(context, 
      SnackBar(
        content: Text('✅ Hybrid-Chat "${newGroup.name}" erstellt'),
        backgroundColor: Colors.green,
      ),
    );

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          chatGroupName: newGroup.name,
          chatGroupId: newGroup.id,
          encryptionType: newGroup.defaultEncryptionType,
        ),
      ),
    );
  }

  // ─── .qgap Import-Flow ────────────────────────────────────────────────────

  /// Prüft ob eine .qgap_ec Datei mit dem angegebenen Namen auf dem Gerät vorhanden ist.
  /// Prüft beim Empfang ob die zur .qgap-Nachricht passende .qgap_ec Datei
  /// auf diesem Gerät vorhanden ist. Wenn ja: Bestätigungsdialog zeigen und
  /// direkt den passenden Chat öffnen (oder Import-Dialog starten).
  /// Gibt [true] zurück wenn der Flow abgeschlossen wurde (regulärer Dialog überspringen).
  Future<bool> _tryEcFileAutoAssign(String content, {bool showSaveField = false}) async {
    debugPrint('QGAP_EC_AUTO: START contentLen=${content.length} first40="${content.substring(0, content.length < 40 ? content.length : 40)}"');
    // Metadaten extrahieren
    String? metadata;
    String? keyFileName;
    String? chatContent; // Text-Format für ChatScreen-Entschlüsselung (base64(meta)+base64(encrypted))
    String? contactName;
    bool isRsaOrHybrid = false;
    qgap_model.EncryptionType encType = qgap_model.EncryptionType.oneTimePad;

    // 1. Binär-Envelope-Format zuerst prüfen (QGap-Magic-Header)
    // Format: [0x4F,0x42,0x4D,0x43] + version(1B) + type(1B) + metaLen(2B BE) + metadata + payload
    try {
      final bytes = base64.decode(content);
      if (bytes.length >= 8 &&
          bytes[0] == 0x4F && bytes[1] == 0x42 &&
          bytes[2] == 0x4D && bytes[3] == 0x43) {
        final type = bytes[5]; // 0x01=text, 0x02=file, 0x03=voice
        if (type == 0x01 || type == 0x02 || type == 0x03) {
          final metaLen = (bytes[6] << 8) | bytes[7];
          if (metaLen > 0 && bytes.length >= 8 + metaLen) {
            final meta = utf8.decode(bytes.sublist(8, 8 + metaLen));
            final parts = meta.split(';');
            final firstPart = parts[0];
            debugPrint('QGAP_EC_AUTO: binary envelope type=$type metaLen=$metaLen meta="$meta" firstPart="$firstPart"');
            metadata = meta;
            // Text-Format für ChatScreen-Entschlüsselung aufbauen
            chatContent = base64.encode(bytes.sublist(8, 8 + metaLen)) +
                base64.encode(bytes.sublist(8 + metaLen));

            if (firstPart == 'RSA') {
              isRsaOrHybrid = true;
              encType = qgap_model.EncryptionType.rsa;
              contactName = parts.length >= 3 ? parts[2].trim() : null;
            } else if (firstPart == 'HYB' || firstPart == 'HYBRID') {
              isRsaOrHybrid = true;
              encType = qgap_model.EncryptionType.hybrid;
              contactName = parts.length >= 3 ? parts[2].trim() : null;
            } else if (firstPart.endsWith('.qgap_ec') || firstPart.endsWith('.qgap')) {
              keyFileName = firstPart;
              encType = qgap_model.EncryptionType.oneTimePad;
            } else {
              metadata = null;
              chatContent = null;
            }
          }
        }
      }
    } catch (_) {}

    // 2. Text-Format als Fallback (base64(metadata) + encrypted)
    if (metadata == null) {
      for (int len = 4; len <= 512; len += 4) {
        if (len > content.length) break;
        try {
          final possible = content.substring(0, len);
          final decoded = utf8.decode(base64.decode(possible));
          final parts = decoded.split(';');
          if (parts.length >= 2 && decoded.endsWith(';')) {
            final firstPart = parts[0];
            // Steuerzeichen = Binär-Header wurde fälschlich erkannt → abbrechen
            if (firstPart.codeUnits.any((c) => c < 0x20)) break;
            debugPrint('QGAP_EC_AUTO: text metadata hit at len=$len firstPart="$firstPart"');
            metadata = decoded;
            chatContent = content;
            if (firstPart == 'RSA') {
              isRsaOrHybrid = true;
              encType = qgap_model.EncryptionType.rsa;
              contactName = parts.length >= 3 ? parts[2].trim() : null;
            } else if (firstPart == 'HYB' || firstPart == 'HYBRID') {
              isRsaOrHybrid = true;
              encType = qgap_model.EncryptionType.hybrid;
              contactName = parts.length >= 3 ? parts[2].trim() : null;
            } else if (firstPart.endsWith('.qgap_ec') || firstPart.endsWith('.qgap')) {
              metadata = decoded;
              keyFileName = firstPart;
              encType = qgap_model.EncryptionType.oneTimePad;
            }
            break;
          }
        } catch (_) {}
      }
    }

    debugPrint('QGAP_EC_AUTO: keyFileName="$keyFileName" metadata="$metadata" encType=$encType contact="$contactName" isRsaOrHybrid=$isRsaOrHybrid');
    if (metadata == null || !mounted) return false;

    // Passenden Chat über SharedPreferences suchen
    final prefs = await SharedPreferences.getInstance();
    final groupsJson = prefs.getStringList('chat_groups') ?? [];
    final chatGroups = <ChatGroup>[];
    for (final s in groupsJson) {
      try {
        chatGroups.add(ChatGroup.fromJson(json.decode(s) as Map<String, dynamic>));
      } catch (_) {}
    }

    ChatGroup? targetGroup;
    if (isRsaOrHybrid) {
      final wanted = (contactName ?? '').trim().toLowerCase();
      debugPrint('QGAP_EC_AUTO: RSA/HYB match for contact="$wanted"');
      for (final g in chatGroups) {
        if (g.defaultEncryptionType != qgap_model.EncryptionType.rsa &&
            g.defaultEncryptionType != qgap_model.EncryptionType.hybrid) {
          continue;
        }
        final assignedContact =
            (prefs.getString('chat_contact_${g.id}') ?? '').trim().toLowerCase();
        debugPrint('QGAP_EC_AUTO: chat "${g.name}" → chat_contact="$assignedContact"');
        if (wanted.isNotEmpty && assignedContact == wanted) {
          targetGroup = g;
          break;
        }
      }
      if (targetGroup == null) {
        debugPrint('QGAP_EC_AUTO: no RSA/HYB chat matched contact="$wanted"');
      }
    } else {
      if (keyFileName == null) return false;

      // .qgap_ec Datei auf Gerät suchen (nur OTP)
      final ecExists = await _checkEcFileExists(keyFileName);
      debugPrint('QGAP_EC_AUTO: _checkEcFileExists("$keyFileName") = $ecExists');
      if (!ecExists || !mounted) return false;

      for (final g in chatGroups) {
        final assignedKey =
            prefs.getString('chat_key_${g.id}') ?? prefs.getString('chat_ec_file_${g.id}');
        debugPrint('QGAP_EC_AUTO: chat "${g.name}" → chat_key="$assignedKey"');
        if (assignedKey == keyFileName) {
          targetGroup = g;
          break;
        }
      }
    }
    debugPrint('QGAP_EC_AUTO: targetGroup="${targetGroup?.name}"');

    // Kombinierter Dialog: Name vergeben + Chat zuordnen (ein einziger Dialog)
    await _showQGapImportDialog(
      content: content,
      chatContent: chatContent ?? content,
      metadata: metadata,
      encType: encType,
      keyFileName: keyFileName,
      chatGroups: chatGroups,
      prefs: prefs,
      preselectedGroup: targetGroup,
      showSaveNameField: showSaveField,
    );
    return true;
  }

  Future<bool> _checkEcFileExists(String keyFileName) async {
    final dirs = <Directory>[
      Directory(AppStorage.schluesselDir),
      Directory('/sdcard/Daten/QGap/schluessel'),
      Directory('/mnt/ext_sd/Daten/QGap/schluessel'),
      Directory('/storage/usbotg/Daten/QGap/schluessel'),
      Directory('/mnt/usb/Daten/QGap/schluessel'),
      Directory('/mnt/media_rw/usbotg/Daten/QGap/schluessel'),
    ];

    // Dynamischer /storage/ Scan
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
              dirs.add(Directory('${entity.path}/Daten/QGap/schluessel'));
            }
          }
        }
      }
    } catch (_) {}

    for (final dir in dirs) {
      try {
        final file = File('${dir.path}/$keyFileName');
        final exists = await file.exists();
        debugPrint('QGAP_EC_CHECK: "${file.path}" exists=$exists');
        if (exists) {
          developer.log('log: .qgap_ec gefunden: ${file.path}', name: 'TransferScreen');
          return true;
        }
      } catch (e) {
        debugPrint('QGAP_EC_CHECK: error checking "${dir.path}/$keyFileName": $e');
      }
    }
    debugPrint('QGAP_EC_CHECK: "$keyFileName" nicht gefunden in allen Pfaden');
    return false;
  }

  /// Verarbeitet empfangenen .qgap-Inhalt (Text-Form) und bietet Chat-Import an.
  Future<void> _importQGapContent(String content, String? fileName) async {
    if (!mounted) return;

    // Metadaten auslesen (Text-Format: base64(metadata)+encrypted)
    String? metadata;
    for (int len = 4; len <= 512; len += 4) {
      if (len > content.length) break;
      try {
        final possible = content.substring(0, len);
        final decoded = utf8.decode(base64.decode(possible));
        final parts = decoded.split(';');
        if (parts.length >= 2 && decoded.endsWith(';')) {
          metadata = decoded;
          break;
        }
      } catch (_) {}
    }

    // Fallback: Binär-Envelope-Format (Fountain-Code)
    if (metadata == null) {
      try {
        final bytes = base64.decode(content);
        if (bytes.length >= 8 &&
            bytes[0] == 0x4F && bytes[1] == 0x42 &&
            bytes[2] == 0x4D && bytes[3] == 0x43) {
          final type = bytes[5];
          if (type == 0x01 || type == 0x02 || type == 0x03) {
            final metaLen = (bytes[6] << 8) | bytes[7];
            if (metaLen > 0 && bytes.length >= 8 + metaLen) {
              metadata = utf8.decode(bytes.sublist(8, 8 + metaLen));
            }
          }
        }
      } catch (_) {}
    }

    // EncryptionType aus Metadaten ableiten
    qgap_model.EncryptionType encType = qgap_model.EncryptionType.oneTimePad;
    String? keyFileName;
    if (metadata != null) {
      final parts = metadata.split(';');
      final firstPart = parts[0];
      if (firstPart == 'RSA') {
        encType = qgap_model.EncryptionType.rsa;
      } else if (firstPart == 'HYB' || firstPart == 'HYBRID') {
        encType = qgap_model.EncryptionType.hybrid;
      } else {
        encType = qgap_model.EncryptionType.oneTimePad;
        keyFileName = firstPart;
      }
    }

    final prefs = await SharedPreferences.getInstance();
    final groupsJson = prefs.getStringList('chat_groups') ?? [];
    final chatGroups = <ChatGroup>[];
    for (final s in groupsJson) {
      try {
        chatGroups.add(ChatGroup.fromJson(json.decode(s) as Map<String, dynamic>));
      } catch (_) {}
    }

    // Geräterolle bestimmen
    final isOfflineOnly = (prefs.getBool('device_role_offline') ?? false) &&
        !(prefs.getBool('device_role_online') ?? false);

    // Passenden Chat suchen (chat_key_ oder chat_ec_file_ als Fallback)
    ChatGroup? targetGroup;
    if (keyFileName != null) {
      for (final g in chatGroups) {
        final assignedKey = prefs.getString('chat_key_${g.id}')
            ?? prefs.getString('chat_ec_file_${g.id}');
        if (assignedKey == keyFileName) {
          targetGroup = g;
          // chat_key_ sicherstellen
          final existing = prefs.getString('chat_key_${g.id}');
          if (existing == null || existing.isEmpty) {
            await prefs.setString('chat_key_${g.id}', keyFileName);
          }
          break;
        }
      }
    }

    // Offline-only + Chat gefunden → direkt navigieren
    if (isOfflineOnly && targetGroup != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatGroupName: targetGroup!.name,
            chatGroupId: targetGroup.id,
            encryptionType: targetGroup.defaultEncryptionType,
            pendingScannedData: content,
            pendingMetadata: metadata,
          ),
        ),
      );
      return;
    }

    // Schlüsseldatei auf Gerät vorhanden + passender Chat bekannt → direkte Zuweisung mit Bestätigung
    if (targetGroup != null && keyFileName != null && mounted) {
      final ecExists = await _checkEcFileExists(keyFileName);
      if (ecExists && mounted) {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Expanded(child: Text('Schlüsseldatei gefunden')),
              ],
            ),
            content: Text(
              'Die Schlüsseldatei "$keyFileName" ist auf diesem Gerät vorhanden.\n\n'
              'Nachricht direkt dem Chat "${targetGroup!.name}" zuweisen?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Manuell wählen'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: TextButton.styleFrom(foregroundColor: Colors.green),
                child: const Text('Direkt öffnen'),
              ),
            ],
          ),
        );
        if (confirm == true && mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                chatGroupName: targetGroup!.name,
                chatGroupId: targetGroup.id,
                encryptionType: targetGroup.defaultEncryptionType,
                pendingScannedData: content,
                pendingMetadata: metadata,
              ),
            ),
          );
          return;
        }
      }
    }

    // Alle anderen Fälle: Dialog
    if (!mounted) return;
    await _showQGapImportDialog(
      content: content,
      metadata: metadata,
      encType: encType,
      keyFileName: keyFileName,
      chatGroups: chatGroups,
      prefs: prefs,
    );
  }

  Future<void> _showQGapImportDialog({
    required String content,
    String? chatContent,
    required String? metadata,
    required qgap_model.EncryptionType encType,
    required String? keyFileName,
    required List<ChatGroup> chatGroups,
    required SharedPreferences prefs,
    ChatGroup? preselectedGroup,
    // showSaveNameField is kept for API compatibility but no longer used –
    // content is always auto-saved before this dialog is shown.
    bool showSaveNameField = false,
  }) async {
    if (!mounted) return;

    String encLabel;
    switch (encType) {
      case qgap_model.EncryptionType.rsa:
        encLabel = 'RSA';
        break;
      case qgap_model.EncryptionType.hybrid:
        encLabel = 'Hybrid (RSA+AES)';
        break;
      default:
        encLabel = 'One-Time-Pad';
    }

    final selectableGroups = chatGroups.where((g) {
      if (encType == qgap_model.EncryptionType.oneTimePad) {
        return g.defaultEncryptionType == qgap_model.EncryptionType.oneTimePad;
      }
      return g.defaultEncryptionType == qgap_model.EncryptionType.rsa ||
          g.defaultEncryptionType == qgap_model.EncryptionType.hybrid;
    }).toList();

    // Modus: bevorzugt vorhandenen kompatiblen Chat, falls verfügbar.
    String mode = preselectedGroup != null
        ? 'existing'
        : (selectableGroups.isNotEmpty ? 'existing' : 'new');
    ChatGroup? selectedGroup =
        preselectedGroup ?? (selectableGroups.isNotEmpty ? selectableGroups.first : null);
    final newNameCtrl = TextEditingController();

    // Dialog gibt seine Auswahl als Map zurück; null = "Im Transfer-Hub behalten" (dismiss).
    // Navigation und Async-Arbeit erfolgen AUSSERHALB des Dialogs.
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      barrierDismissible: true, // Tippen außerhalb = Im Transfer-Hub behalten
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('📨 .qgap Nachricht empfangen'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Info: Inhalt ist bereits im Transfer-Hub gespeichert
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.teal.shade200),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.teal, size: 16),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Im Transfer-Hub gespeichert.',
                            style: TextStyle(fontSize: 13, color: Colors.teal),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Verschlüsselungstyp anzeigen
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.shield, size: 16, color: Colors.blue),
                        const SizedBox(width: 6),
                        Text('Verschlüsselung: $encLabel',
                            style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Optional: Nachricht einem Chat zuweisen',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  // Chat-Auswahl: Vorschlag wenn gefunden, sonst manuell
                  if (preselectedGroup != null) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.green.shade300),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.check_circle_outline,
                              color: Colors.green, size: 18),
                          SizedBox(width: 8),
                          Text('Passender Chat gefunden:',
                              style: TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.w600)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Radio<String>(
                          value: 'existing',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                        ),
                        Expanded(
                          child: Text(
                            '💬 ${preselectedGroup.name}',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Radio<String>(
                          value: 'new',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                        ),
                        const Text('Stattdessen neuen Chat anlegen'),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Radio<String>(
                          value: 'existing',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                        ),
                        const Text('Vorhandenem Chat zuweisen'),
                      ],
                    ),
                    if (mode == 'existing') ...[
                      if (selectableGroups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(left: 16),
                          child: Text('Keine passenden Chats vorhanden.',
                              style: TextStyle(color: Colors.red)),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: DropdownButton<ChatGroup>(
                            value: selectedGroup,
                            isExpanded: true,
                            items: selectableGroups
                                .map((g) => DropdownMenuItem(
                                      value: g,
                                      child: Text(g.name,
                                          overflow: TextOverflow.ellipsis),
                                    ))
                                .toList(),
                            onChanged: (v) => setS(() => selectedGroup = v),
                          ),
                        ),
                    ],
                    Row(
                      children: [
                        Radio<String>(
                          value: 'new',
                          groupValue: mode,
                          onChanged: (v) => setS(() => mode = v!),
                        ),
                        const Text('Neuen Chat anlegen'),
                      ],
                    ),
                  ],
                  if (mode == 'new') ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextField(
                        controller: newNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Chat-Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (encType == qgap_model.EncryptionType.oneTimePad)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 8),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.warning_amber,
                                  color: Colors.orange, size: 16),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '⚠️ .qgap Schlüsseldatei muss noch zugewiesen werden.',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              // Primäre Aktion: Im Transfer-Hub behalten (kein Chat nötig)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop({'action': 'hub'}),
                child: const Text('Im Transfer-Hub behalten'),
              ),
              // Sekundäre Aktion: Chat öffnen
              TextButton(
                onPressed: () {
                  if (mode == 'existing' && selectedGroup == null) {
                    // Kein Chat auswählbar – Button deaktiviert
                    return;
                  }
                  Navigator.of(ctx).pop({
                    'action': mode,
                    'group': selectedGroup,
                    'chatName': newNameCtrl.text.trim(),
                  });
                },
                child: const Text('Im Chat öffnen'),
              ),
            ],
          );
        });
      },
    );

    // result == null → Tippen außerhalb = Im Transfer-Hub behalten
    if (result == null || !mounted) return;
    final chosenAction = result['action'] as String? ?? 'hub';
    if (chosenAction == 'hub') return; // Inhalt ist bereits gespeichert

    // Chat-Navigation außerhalb des Dialog-Callbacks (kein async in onPressed)
    if (chosenAction == 'existing') {
      final group = result['group'] as ChatGroup?;
      if (group == null || !mounted) return;
      // Schlüsseldatei-Zuweisung persistieren (für spätere Auto-Erkennung)
      if (keyFileName != null && encType == qgap_model.EncryptionType.oneTimePad) {
        final existing = prefs.getString('chat_key_${group.id}');
        if (existing == null || existing.isEmpty) {
          await prefs.setString('chat_key_${group.id}', keyFileName);
        }
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatGroupName: group.name,
            chatGroupId: group.id,
            encryptionType: group.defaultEncryptionType,
            pendingScannedData: chatContent ?? content,
            pendingMetadata: metadata,
          ),
        ),
      );
    } else if (chosenAction == 'new') {
      final chatName = result['chatName'] as String? ?? '';
      if (chatName.isEmpty || !mounted) return;

      final newGroup = ChatGroup(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: chatName,
        description: '',
        createdAt: DateTime.now(),
        iconEmoji: encType == qgap_model.EncryptionType.hybrid ? '🔑' : '💬',
        defaultEncryptionType: encType,
      );

      // Schlüsseldatei zuweisen falls OTP
      if (keyFileName != null && encType == qgap_model.EncryptionType.oneTimePad) {
        await prefs.setString('chat_key_${newGroup.id}', keyFileName);
        await prefs.setBool('chat_needs_QGAP_key_${newGroup.id}', true);
      }

      final updatedGroups =
          List<String>.from(prefs.getStringList('chat_groups') ?? []);
      updatedGroups.add(json.encode(newGroup.toJson()));
      await prefs.setStringList('chat_groups', updatedGroups);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatGroupName: newGroup.name,
            chatGroupId: newGroup.id,
            encryptionType: newGroup.defaultEncryptionType,
            pendingScannedData: chatContent ?? content,
            pendingMetadata: metadata,
          ),
        ),
      );
    }
  }

  // ─── Eintrag speichern / Dialoge ──────────────────────────────────────────

  /// Speichert einen Inhalt automatisch mit Zeitstempel-Name in der Galerie
  /// (ohne Dialog). Zeigt kurz einen Snackbar-Hinweis.
  Future<void> _autoSaveToGallery(String content, QrCategory category) async {
    final now = DateTime.now();
    final name =
        '${category.label} ${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final entry = SavedQrEntry(
      id: now.millisecondsSinceEpoch.toString(),
      name: name,
      content: content,
      category: category,
      savedAt: now,
    );
    await _addEntry(entry);

    if (mounted) {
      showQgapSnackBar(context, 
        SnackBar(
          content: Text('📌 In Transfer-Hub gespeichert: $name'),
          backgroundColor: Colors.teal,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Dialog zum Speichern eines neuen QR-Eintrags.
  Future<void> _showSaveEntryDialog({
    String? content,
    QrCategory? category,
  }) async {
    if (!mounted) return;

    final nameCtrl = TextEditingController();
    final contentCtrl = TextEditingController(text: content ?? '');
    QrCategory selectedCat = category ?? QrCategory.text;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('📥 QR-Code speichern'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Name (optional – sonst Zeitstempel)',
                      hintText: 'z. B. "Postfach-Info"',
                      border: OutlineInputBorder(),
                    ),
                    maxLength: 50,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<QrCategory>(
                    value: selectedCat,
                    decoration: const InputDecoration(
                      labelText: 'Kategorie',
                      border: OutlineInputBorder(),
                    ),
                    items: QrCategory.values
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text('${c.emoji} ${c.label}'),
                            ))
                        .toList(),
                    onChanged: (v) => setS(() => selectedCat = v!),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: contentCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Inhalt (Text / URL / Base64)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 5,
                    readOnly: content != null, // Vorbelegter Inhalt ist readonly
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () async {
                  final cnt = contentCtrl.text.trim();
                  if (cnt.isEmpty) return;

                  final now = DateTime.now();
                  final ts =
                      '${now.year.toString().padLeft(4, '0')}-'
                      '${now.month.toString().padLeft(2, '0')}-'
                      '${now.day.toString().padLeft(2, '0')} '
                      '${now.hour.toString().padLeft(2, '0')}:'
                      '${now.minute.toString().padLeft(2, '0')}:'
                      '${now.second.toString().padLeft(2, '0')}';
                  final name = nameCtrl.text.trim().isEmpty ? ts : nameCtrl.text.trim();

                  final entry = SavedQrEntry(
                    id: now.millisecondsSinceEpoch.toString(),
                    name: name,
                    content: cnt,
                    category: selectedCat,
                    savedAt: now,
                  );
                  Navigator.of(ctx).pop();
                  await _addEntry(entry);
                },
                child: const Text('Speichern'),
              ),
            ],
          );
        });
      },
    );
  }

  /// Dialog: Empfangene Bytes – was tun?
  Future<String?> _showReceivedBytesDialog(
      Uint8List bytes, String? asText) async {
    if (!mounted) return null;

    final isText = asText != null;
    final isQGap = asText != null && asText.length > 20;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📥 Daten empfangen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Empfangen: ${bytes.length} Bytes'),
            if (isText && asText.length <= 200) ...[
              const SizedBox(height: 8),
              Text(
                asText,
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        actions: [
          Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('save_file'),
                child: Text('💾 Als ${_extensionForBytes(bytes)} speichern'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('clipboard'),
                child: const Text('📋 Base64 kopieren'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop('share'),
                child: const Text('📤 Teilen'),
              ),
              if (isQGap)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('import_chat'),
                  child: const Text('💬 Chat-Import'),
                ),
              if (isText)
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('save_qr'),
                  child: const Text('📌 Als QR speichern'),
                ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Schließen'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Dialog: Quelle für Fountain-Code-Senden wählen.
  Future<String?> _showSendSourceDialog() async {
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📤 Was senden?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(QgapIcons.fileOpen, color: QgapColors.fileOpen),
              title: const Text('.qgap Datei wählen'),
              subtitle: const Text('Datei direkt von Gerät'),
              onTap: () => Navigator.of(ctx).pop('file'),
            ),
            ListTile(
              leading:
                  const Icon(Icons.content_paste, color: Colors.teal),
              title: const Text('Base64 aus Zwischenablage'),
              subtitle: const Text('Kopierter Base64-Text'),
              onTap: () => Navigator.of(ctx).pop('clipboard'),
            ),
            ListTile(
              leading: const Icon(QgapIcons.qrScan, color: QgapColors.qrScan),
              title: const Text('Gespeicherten QR-Eintrag'),
              subtitle: const Text('Aus der Galerie wählen'),
              onTap: () => Navigator.of(ctx).pop('entry'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
  }

  /// Dialog: Gespeicherten Eintrag auswählen (für Fountain-Send).
  Future<SavedQrEntry?> _showPickEntryDialog() async {
    if (_entries.isEmpty) {
      if (mounted) {
        showQgapSnackBar(context, 
          const SnackBar(content: Text('Keine gespeicherten Einträge vorhanden')),
        );
      }
      return null;
    }
    return showDialog<SavedQrEntry>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('QR-Eintrag wählen'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _entries.length,
            itemBuilder: (ctx2, i) {
              final e = _entries[i];
              return ListTile(
                leading: Text(e.category.emoji,
                    style: const TextStyle(fontSize: 20)),
                title: Text(e.name),
                subtitle: Text(e.category.label),
                onTap: () => Navigator.of(ctx).pop(e),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
  }

  // ─── Eintrag-Aktionen ─────────────────────────────────────────────────────

  /// Zeigt QR-Code an: automatisch Einzel-QR (klein) oder Fountain-Code (groß).
  /// Für .qgap-Einträge und Inhalte > 1000 Zeichen wird immer Fountain verwendet.
  void _showFullscreenQr(SavedQrEntry entry) {
    // Große Inhalte und QGap → Fountain-Code Sender (Mehrseiten-QR)
    if (!_fitsInSingleQr(entry)) {
      _startFountainSender(entry);
      return;
    }
    // Für binäre Daten: Base64 dekodieren und im Byte-Mode rendern
    Widget qrWidget;
    if ((entry.category == QrCategory.binary || entry.category == QrCategory.ron)
        && entry.content.startsWith('BIN:')) {
      try {
        final bytes = base64Decode(entry.content.substring(4));
        print('🔍 QR-Vollbild: ${bytes.length} bytes (Byte-Mode)');
        print('🔍 Erste 10 Bytes: ${bytes.take(10).toList()}');
        
        qrWidget = BinaryQrImage(
          bytes: bytes,
          size: 280,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
        );
      } catch (e) {
        print('❌ Fehler beim Dekodieren von Binärdaten: $e');
        qrWidget = const SizedBox(
          width: 280,
          height: 280,
          child: Center(
            child: Text(
              'Fehler beim Dekodieren',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.red),
            ),
          ),
        );
      }
    } else {
      // Normale Text-QR-Codes – sicherer Fallback bei Encoding-Fehler
      final qrData = entry.content.length > _singleQrMaxChars
          ? entry.content.substring(0, _singleQrMaxChars)
          : entry.content;

      qrWidget = QrImageView(
        data: qrData,
        version: QrVersions.auto,
        size: 280,
        backgroundColor: Colors.white,
        errorStateBuilder: (c, e) => SizedBox(
          width: 280,
          height: 280,
          child: Center(
            child: Text(
              'Inhalt zu groß für einzelnen QR-Code.\nBitte „Senden" (Fountain) verwenden.\n\n$e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Kopfzeile
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            // QR-Code
            Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: qrWidget,
            ),
            // RON-Daten Info
            if (entry.category == QrCategory.ron) _buildRonInfo(entry),
            // Kategorie-Info
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${entry.category.emoji} ${entry.category.label}  ·  ${_formatDate(entry.savedAt)}',
                style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Long-Press Aktionsmenü für einen Eintrag.
  void _showEntryActions(SavedQrEntry entry) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.teal),
              title: const Text('Umbenennen'),
              onTap: () {
                Navigator.of(ctx).pop();
                _renameEntry(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.fullscreen),
              title: const Text('Vollbild anzeigen'),
              onTap: () {
                Navigator.of(ctx).pop();
                _showFullscreenQr(entry);
              },
            ),
            ListTile(
              leading: const Icon(QgapIcons.send, color: QgapColors.fileSend),
              title: const Text('Via Fountain-Code senden'),
              onTap: () {
                Navigator.of(ctx).pop();
                _sendEntryViaFountain(entry);
              },
            ),
            ListTile(
              leading: const Icon(QgapIcons.fileShare, color: QgapColors.fileShare),
              title: const Text('Text teilen'),
              onTap: () {
                Navigator.of(ctx).pop();
                _shareEntryText(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy),
              title: const Text('Inhalt kopieren'),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: entry.content));
                showQgapSnackBar(context, 
                  const SnackBar(content: Text('✅ In Zwischenablage kopiert')),
                );
              },
            ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Löschen',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmDeleteEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Gibt true zurück, wenn ein QGap-Eintrag Base64-kodierte Binärdaten enthält
  /// (d.h. aus einer Fountain-Code-Übertragung stammt, nicht aus einem Text-QR).
  /// Schwellwert: Zeichenlänge ab der Fountain-Code (Mehrseiten-QR) verwendet wird.
  static const int _singleQrMaxChars = 1000;

  /// Maximale Bytes für einen einzelnen Byte-Mode-QR (Version 40, ECC L ≈ 2953).
  /// Etwas Puffer einplanen, damit das Encoding immer klappt.
  static const int _singleQrMaxBytes = 2900;

  /// Gibt [true] zurück wenn der Eintrag in einen einzelnen QR-Code passt.
  /// QGap-Einträge sind immer zu groß. Binär-Einträge mit BIN:-Prefix werden
  /// nur dann als Einzel-QR gerendert, wenn die dekodierten Bytes ins QR-Limit passen.
  bool _fitsInSingleQr(SavedQrEntry entry) {
    // Binäre Daten mit BIN:-Prefix: BinaryQrImage übernimmt das Rendering,
    // aber nur wenn die Bytes ins QR-Limit passen → sonst Fountain-Code.
    if ((entry.category == QrCategory.binary || entry.category == QrCategory.ron)
        && entry.content.startsWith('BIN:')) {
      try {
        final bytes = base64Decode(entry.content.substring(4));
        return bytes.length <= _singleQrMaxBytes;
      } catch (_) {
        return false; // Lieber Fountain-Code als Crash
      }
    }
    // QGap-Dateien sind immer mehrere KB → immer Fountain-Code
    if (entry.category == QrCategory.qgap) {
      return false;
    }
    return entry.content.length <= _singleQrMaxChars;
  }

  bool _isBinaryQGap(SavedQrEntry entry) {
    if (entry.category != QrCategory.qgap) return false;
    // Text-QGap-Einträge beginnen mit Base64-kodierten Metadaten (kurzes Prefix)
    // und sind als String lesbar. Rein binäre sind deutlich länger und kompakt.
    // Einfacher Heuristik: Wenn der Inhalt NICHT mit 'QGAP_RSA_PUB:' beginnt
    // und auch kein http enthält, aber extrem lang und kein Leerzeichen hat,
    // dann ist es Base64-kodiertes Binary.
    // Zuverlässiger: Versuch, als UTF-8 zu dekodieren.
    try {
      final decoded = base64.decode(entry.content);
      // Wenn Base64-Dekodierung klappt UND das Ergebnis nicht als UTF-8 lesbar ist
      // → Binärdaten
      utf8.decode(decoded); // wirft FormatException bei Binärdaten
      return false; // Es ist lesbarer Text (kein Binary-QGap)
    } catch (_) {
      return true; // Dekodiertes Binary ist kein valides UTF-8 → Binary-QGap
    }
  }

  /// Returns a human-readable label if the entry is a voice QGap envelope (type 0x03).
  /// Returns null for all other entry types.
  String? _getVoiceQGapInfo(SavedQrEntry entry) {
    if (entry.category != QrCategory.qgap) return null;
    try {
      final bytes = base64.decode(entry.content);
      if (bytes.length < 10) return null;
      if (bytes[0] != 0x4F || bytes[1] != 0x42 || bytes[2] != 0x4D || bytes[3] != 0x43) return null;
      if (bytes[5] != 0x03) return null; // only voice type
      final metaLen = (bytes[6] << 8) | bytes[7];
      if (bytes.length < 8 + metaLen) return null;
      final meta = utf8.decode(bytes.sublist(8, 8 + metaLen));
      final firstPart = meta.split(';')[0];
      if (firstPart == 'HYB' || firstPart == 'HYBRID') return 'Audio QGap Hybrid';
      if (firstPart == 'RSA') return 'Audio QGap RSA';
      if (meta.contains('EC:') || meta.contains('ECC:')) return 'Audio QGap EC';
      return 'Audio QGap OTP';
    } catch (_) {
      return null;
    }
  }

  /// Gibt die QR-Code-Daten für einen Entry zurück.
  /// Für binäre Daten wird Base64 dekodiert und als Latin-1 String kodiert.
  String _getQrDataForEntry(SavedQrEntry entry, {int? maxLength}) {
    if (entry.category == QrCategory.binary && entry.content.startsWith('BIN:')) {
      try {
        final bytes = base64Decode(entry.content.substring(4));
        final latinString = latin1.decode(bytes);
        print('QR-Preview: ${bytes.length} bytes → Latin-1 String (${latinString.length} chars)');
        if (maxLength != null && latinString.length > maxLength) {
          return '(Binärdaten zu groß für Vorschau)';
        }
        return latinString;
      } catch (e) {
        print('Fehler beim Dekodieren von Binärdaten: $e');
        return '(Fehler beim Dekodieren)';
      }
    }
    
    final content = entry.content;
    if (maxLength != null && content.length > maxLength) {
      return '(Inhalt zu groß für Vorschau)';
    }
    return content;
  }

  Future<void> _sendEntryViaFountain(SavedQrEntry entry) async {
    if (_fitsInSingleQr(entry)) {
      // Kleiner Inhalt → statischer Einzel-QR-Code anzeigen
      _showFullscreenQr(entry);
      return;
    }
    await _startFountainSender(entry);
  }

  /// Startet den Fountain-Code Sender (Mehrseiten-QR) für einen Galerie-Eintrag.
  Future<void> _startFountainSender(SavedQrEntry entry) async {
    final Uint8List bytes;
    if (entry.category == QrCategory.binary || _isBinaryQGap(entry)) {
      // Inhalt ist Base64-kodierte Binärdaten → zurück zu Bytes
      try {
        bytes = base64.decode(entry.content);
      } catch (_) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(content: Text('❌ Binärdaten konnten nicht dekodiert werden')),
          );
        }
        return;
      }
    } else {
      bytes = Uint8List.fromList(utf8.encode(entry.content));
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
    );
  }

  Future<void> _renameEntry(SavedQrEntry entry) async {
    final ctrl = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eintrag umbenennen'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
          maxLength: 80,
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == entry.name) return;
    final updated = SavedQrEntry(
      id: entry.id,
      name: newName,
      content: entry.content,
      category: entry.category,
      savedAt: entry.savedAt,
    );
    setState(() {
      final idx = _entries.indexWhere((e) => e.id == entry.id);
      if (idx != -1) _entries[idx] = updated;
    });
    await _saveEntries();
  }

  Future<void> _shareEntryText(SavedQrEntry entry) async {
    if (entry.category == QrCategory.rsaKey) {
      // RSA-Public-Key als .qgap_aes Datei teilen
      try {
        final bytes = utf8.encode(entry.content);
        final dir = await getTemporaryDirectory();
        final safeName = entry.name.replaceAll(RegExp(r'[^\w\-.]'), '_');
        final tmpFile = File('${dir.path}/$safeName.qgap_aes');
        await tmpFile.writeAsBytes(bytes);
        await Share.shareXFiles(
          [XFile(tmpFile.path)],
          subject: entry.name,
          text: 'RSA/AES Public-Key (.qgap_aes)',
        );
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(
              content: Text('✅ Datei geteilt'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Teilen: $e')),
          );
        }
      }
      return;
    }
    // QGap-Inhalt als .qgap Datei teilen (damit Google Drive die Endung erkennt)
    try {
      Uint8List fileBytes;
      try {
        fileBytes = base64.decode(entry.content);
      } catch (_) {
        fileBytes = utf8.encode(entry.content);
      }
      final dir = await getTemporaryDirectory();
      final safeName = entry.name.replaceAll(RegExp(r'[^\w\-.]'), '_');
      final tmpFile = File('${dir.path}/$safeName.qgap');
      await tmpFile.writeAsBytes(fileBytes);
      await Share.shareXFiles(
        [XFile(tmpFile.path)],
        subject: entry.name,
        text: 'QGap verschlüsselte Nachricht',
      );
      if (mounted) {
        showQgapSnackBar(context, 
          const SnackBar(
            content: Text('✅ Datei geteilt'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Teilen: \$e')),
        );
      }
    }
  }

  Future<void> _confirmDeleteEntry(SavedQrEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eintrag löschen?'),
        content: Text('"${entry.name}" wirklich löschen?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen',
                style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteEntry(entry.id);
  }

  // ─── Sicherheits-Dialog .qgap_ec ─────────────────────────────────────────

  void _showQGapEcBlockedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.block, color: Colors.red),
            SizedBox(width: 8),
            Text('Nicht erlaubt'),
          ],
        ),
        content: const Text(
          '.qgap_ec Dateien dürfen NIEMALS digital übertragen werden!\n\n'
          'Diese Dateien enthalten Einmalschlüssel und dürfen ausschließlich '
          'physisch per USB übertragen werden.\n\n'
          'Bitte wählen Sie eine .qgap Datei (ohne "_ec").',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Verstanden'),
          ),
        ],
      ),
    );
  }

  // ─── Hilfe ────────────────────────────────────────────────────────────────

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📡 Transfer-Hub – Hilfe'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('📷 Scannen',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(
                  'QR-Code mit Kamera scannen und als Eintrag speichern.\n'),
              Text('✏️ Neu',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text('Eintrag manuell eingeben (Text, Link, etc.).\n'),
              Text('📤 Senden',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(
                  'Daten als animierte QR-Code-Folge (Fountain-Code) senden.\n'
                  '• .qgap Datei vom Gerät wählen\n'
                  '• Base64 aus Zwischenablage\n'
                  '• Gespeicherten Eintrag\n'),
              Text('📥 Empfangen',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(
                  'Fountain-Code QR-Sequenz scannen und Daten empfangen.\n'),
              Text('📂 Datei teilen',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(
                  '.qgap Datei via WhatsApp, Telegram, Google Drive usw. teilen.\n'),
              Divider(),
              Text('⚠️ Sicherheitshinweis:',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.red)),
              Text(
                '.qgap_ec Schlüsseldateien dürfen NIEMALS digital '
                'übertragen werden – nur per USB (Luftspalt).',
                style: TextStyle(color: Colors.red),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ─── Hilfsmethoden ────────────────────────────────────────────────────────

  /// Erstellt das QR-Preview Widget für die Galerie.
  Widget _buildQrPreview(SavedQrEntry entry) {
    // Große Einträge und QGap → Fountain-Code Platzhalter (Mehrseiten-QR)
    if (!_fitsInSingleQr(entry)) {
      return Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: Colors.teal.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.teal.shade200),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.view_carousel, color: Colors.teal.shade600, size: 28),
            const SizedBox(height: 2),
            Text(
              'Fountain',
              style: TextStyle(fontSize: 8, color: Colors.teal.shade700,
                  fontWeight: FontWeight.bold),
            ),
          ],
        ),
      );
    }
    if ((entry.category == QrCategory.binary || entry.category == QrCategory.ron) 
        && entry.content.startsWith('BIN:')) {
      try {
        final bytes = base64Decode(entry.content.substring(4));
        return BinaryQrImage(
          bytes: bytes,
          size: 80,
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
        );
      } catch (e) {
        return Container(
          width: 80,
          height: 80,
          color: Colors.grey.shade200,
          child: const Icon(Icons.error, color: Colors.red),
        );
      }
    }
    
    // Normale Text-QR-Codes
    return QrImageView(
      data: _getQrDataForEntry(entry, maxLength: 800),
      version: QrVersions.auto,
      size: 80,
      backgroundColor: Colors.white,
      errorStateBuilder: (ctx, err) => Container(
        width: 80,
        height: 80,
        color: Colors.grey.shade200,
        child: const Icon(Icons.qr_code, color: Colors.grey),
      ),
    );
  }

  /// Erstellt Vorschautext für Galerie-Einträge.
  String _getEntryPreviewText(SavedQrEntry entry) {
    final voiceInfo = _getVoiceQGapInfo(entry);
    if (voiceInfo != null) {
      return '🎤 $voiceInfo\n${((entry.content.length * 3) ~/ 4)} Bytes';
    }
    if (_isBinaryQGap(entry)) {
      return '🔒 QGap-Datei\n${((entry.content.length * 3) ~/ 4)} Bytes';
    }
    
    if (entry.category == QrCategory.ron) {
      final ronData = SavedQrEntry.parseRon(entry.content);
      if (ronData != null) {
        return '📦 DHL Retoure\nSendung: ${ronData['sendungsnummer']}\n'
               '${ronData['service']} (${ronData['produktcode']})\n'
               'An: ${ronData['empfaenger_name']}, ${ronData['empfaenger_plz']} ${ronData['empfaenger_ort']}';
      }
    }
    
    if (entry.category == QrCategory.binary) {
      try {
        final bytes = base64Decode(entry.content.substring(4));
        return '📦 Binärdaten\n${bytes.length} Bytes';
      } catch (_) {
        return '📦 Binärdaten';
      }
    }
    
    return entry.content.length > 120
        ? '${entry.content.substring(0, 120)}…'
        : entry.content;
  }

  /// Erstellt formatierte RON-Daten Anzeige.
  Widget _buildRonInfo(SavedQrEntry entry) {
    final ronData = SavedQrEntry.parseRon(entry.content);
    if (ronData == null) {
      return const SizedBox.shrink();
    }
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DHL Retourenlabel',
            style: TextStyle(
              color: Colors.yellow.shade700,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          _buildRonInfoRow('Sendungsnummer', ronData['sendungsnummer'] ?? ''),
          _buildRonInfoRow('Service', ronData['service'] ?? ''),
          _buildRonInfoRow('Produktcode', ronData['produktcode'] ?? ''),
          const Divider(color: Colors.grey, height: 16),
          Text(
            'Empfänger:',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          _buildRonInfoRow('Name', ronData['empfaenger_name'] ?? ''),
          _buildRonInfoRow('Adresse', 
            '${ronData['empfaenger_strasse']}, ${ronData['empfaenger_plz']} ${ronData['empfaenger_ort']}'),
          const Divider(color: Colors.grey, height: 16),
          Text(
            'Absender:',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          _buildRonInfoRow('Name', ronData['absender_name'] ?? ''),
          _buildRonInfoRow('Adresse', 
            '${ronData['absender_strasse']}, ${ronData['absender_plz']} ${ronData['absender_ort']}'),
          if (ronData['tracking']?.isNotEmpty ?? false) ...[
            const Divider(color: Colors.grey, height: 16),
            _buildRonInfoRow('Tracking', ronData['tracking'] ?? ''),
          ],
          if (ronData['retourennummer']?.isNotEmpty ?? false)
            _buildRonInfoRow('Retourennummer', ronData['retourennummer'] ?? ''),
        ],
      ),
    );
  }

  Widget _buildRonInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              '$label:',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 7) {
      return 'vor ${diff.inDays}d';
    } else {
      return '${dt.day}.${dt.month}.${dt.year}';
    }
  }

  // ─── Firestore-User-Transfer (E2E) ────────────────────────────────────────

  /// Abonniert eingehende `transfers/`-Dokumente und importiert sie automatisch.
  void _subscribeIncomingTransfers() {
    try {
      if (AuthService.currentUid == null) {
        developer.log('log: User-Transfer-Stream übersprungen (nicht eingeloggt)',
            name: 'TransferScreen');
        return;
      }
      _transfersSub = _firestore.incomingTransfersStream().listen(
        _handleTransferSnapshot,
        onError: (e) {
          developer.log('log: Transfer-Stream-Fehler: $e', name: 'TransferScreen');
        },
      );
    } catch (e) {
      developer.log('log: Konnte Transfer-Stream nicht starten: $e',
          name: 'TransferScreen');
    }
  }

  Future<void> _handleTransferSnapshot(
      QuerySnapshot<Map<String, dynamic>> snap) async {
    for (final change in snap.docChanges) {
      if (change.type != DocumentChangeType.added) continue;
      final doc = change.doc;
      if (_processedTransferIds.contains(doc.id)) continue;
      _processedTransferIds.add(doc.id);
      await _importIncomingTransfer(doc);
    }
  }

  Future<void> _importIncomingTransfer(
      DocumentSnapshot<Map<String, dynamic>> doc) async {
    final data = doc.data();
    if (data == null) return;
    final fileName = (data['fileName'] as String?) ?? 'transfer.bin';
    final senderUid = (data['senderUid'] as String?) ?? '';
    final senderIsOffline = data['senderIsOffline'] == true;
    final encryptionType = (data['encryptionType'] as String?) ?? 'unknown';
    // Legacy: alte App-Versionen senden noch obmc_*-payloadTypes
    final payloadTypeRaw = (data['payloadType'] as String?) ?? 'QGAP_file';
    final payloadType = payloadTypeRaw.startsWith('obmc_')
        ? 'qgap_${payloadTypeRaw.substring(5)}'
        : payloadTypeRaw;
    final preencrypted = data['preencrypted'] == true ||
        payloadType == FirestoreService.kPayloadTypeRelayPreencrypted;
    final isReceipt = payloadType == FirestoreService.kPayloadTypeReadReceipt;

    final myRole = await DeviceRoleService.get();
    final firestoreChatId = (data['chatId'] as String?) ?? (data['firestoreChatId'] as String?);

    // ─── Pfad A: Lesebestätigung (signiert, verifizieren) ─────────────────
    if (isReceipt) {
      try {
        final cipherB64 = (data['cipher'] as String?) ?? '';
        final blob = base64.decode(cipherB64);
        await _processIncomingReceipt(blob, senderUid);
      } catch (e) {
        developer.log('log: Receipt-Import fehlgeschlagen: $e',
            name: 'TransferScreen');
      }
      try {
        await _firestore.deleteTransfer(doc.id);
      } catch (_) {}
      return;
    }

    // ─── Pfad A2: Relay-Pairing-ACK (Online B → Relay A) ─────────────────
    if (payloadType == FirestoreService.kPayloadTypeRelayPairAck) {
      try {
        final cipherB64 = (data['cipher'] as String?) ?? '';
        final rawBytes = base64.decode(cipherB64);
        final ackJson = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
        final ackChatGroupId = ackJson['chatGroupId'] as String?;
        final ackSenderUid   = ackJson['senderUid']   as String?;
        if (ackChatGroupId != null && ackSenderUid != null) {
          await RelayMappingService.confirmAck(
            chatGroupId: ackChatGroupId,
            destUid: ackSenderUid,
          );
          developer.log(
              'log: ✅ Relay-ACK empfangen: chatGroupId=$ackChatGroupId, senderUid=$ackSenderUid',
              name: 'TransferScreen');
          if (mounted) {
            showQgapSnackBar(
              context,
              SnackBar(
                content: const Text('✅ Relay-Pairing abgeschlossen! Config-QR für Air-Gap bereit.'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 6),
                action: SnackBarAction(
                  label: 'Config-QR',
                  onPressed: () async {
                    final mapping = await RelayMappingService.load(ackChatGroupId);
                    if (mapping != null && mapping.destUid != null && mounted) {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => QrDataSender(
                            bytes: Uint8List.fromList(utf8.encode(jsonEncode({
                              'version': 1,
                              'chatType': 'qgap_relay_cfg',
                              'chatGroupId': ackChatGroupId,
                              'destUid': mapping.destUid,
                            }))),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            );
          }
        }
      } catch (e) {
        developer.log('log: ⚠️ Relay-ACK Verarbeitung fehlgeschlagen: $e',
            name: 'TransferScreen');
      }
      try { await _firestore.deleteTransfer(doc.id); } catch (_) {}
      return;
    }

    // ─── Pfad A3: B→A Relay-Nachricht (Online B → Relay A → Pickup-Queue) ──
    if (payloadType == FirestoreService.kPayloadTypeRelayBtoA) {
      try {
        final cipherB64 = (data['cipher'] as String?) ?? '';
        final blob = base64.decode(cipherB64);
        final chatId = firestoreChatId ?? 'unknown';
        await PickupQueueService.enqueue(
          transferDocId: doc.id,
          senderUid: senderUid,
          fileName: fileName,
          encryptionType: encryptionType,
          payloadType: payloadType,
          blob: blob,
          firestoreChatId: chatId,
          reason: 'B→A Relay-Nachricht für Air-Gap-Gerät',
        );
        if (mounted) {
          setState(() {});
          showQgapSnackBar(context, SnackBar(
            content: Text('📥 B→A Nachricht in Pickup-Queue: $fileName'),
            backgroundColor: Colors.indigo,
          ));
        }
      } catch (e) {
        developer.log('log: B→A Relay-Enqueue fehlgeschlagen: $e',
            name: 'TransferScreen');
      }
      // Nicht löschen – Air-Gap-Gerät muss noch abholen
      return;
    }

    // ─── Pfad B: Online-Relay parkt alles in der Pickup-Queue ────────────
    // Auch vor-verschlüsselte Relay-Pakete (preencrypted=true) gehen hierhin.
    if (myRole == DeviceRole.onlineRelay || preencrypted) {
      try {
        final cipherB64 = (data['cipher'] as String?) ?? '';
        final blob = base64.decode(cipherB64);
        await PickupQueueService.enqueue(
          transferDocId: doc.id,
          senderUid: senderUid,
          fileName: fileName,
          encryptionType: encryptionType,
          payloadType: payloadType,
          blob: blob,
          firestoreChatId: firestoreChatId,
          reason: preencrypted
              ? 'Relay-vorverschlüsselt'
              : 'Online-Relay-Modus aktiv',
        );
        // ⚠️ Sicherheitswarnung wenn Relay die Schlüsseldatei hatte
        final relayHadKeyFile = data['relayHadKeyFile'] == true;
        if (mounted) {
          setState(() {}); // Pickup-Sektion aktualisieren
          if (relayHadKeyFile) {
            await showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.security, color: Colors.red),
                    SizedBox(width: 8),
                    Flexible(child: Text('⚠️ Sicherheitswarnung')),
                  ],
                ),
                content: const Text(
                  'Das Relay-Handy hatte die zugehörige Schlüsseldatei '
                  'lokal gespeichert!\n\n'
                  'Das ist ein Sicherheitsproblem: Schlüsseldateien '
                  'sollten sich ausschließlich auf Air-Gap-Geräten '
                  'befinden, niemals auf Online-Geräten.\n\n'
                  'Bitte die Datei sofort vom Relay-Handy löschen.',
                  style: TextStyle(fontSize: 13),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Verstanden'),
                  ),
                ],
              ),
            );
          } else {
            showQgapSnackBar(
              context,
              SnackBar(
                content: Text(
                    '📥 Transfer in Pickup-Queue: $fileName (für Air-Gap-Gerät)'),
                backgroundColor: Colors.indigo,
              ),
            );
          }
        }
      } catch (e) {
        developer.log('log: Pickup-Enqueue fehlgeschlagen: $e',
            name: 'TransferScreen');
      }
      // NICHT löschen – Air-Gap-Partner muss die Daten noch abholen können
      // (Re-Stream nach Neustart). Stattdessen über _processedTransferIds
      // verhindern wir Doppel-Enqueue innerhalb derselben Session.
      return;
    }

    try {
      // Eigenen privaten Schlüssel laden.
      final loaded = await _rsaKeyManager.loadKeyPair();
      if (!loaded) {
        developer.log('log: ⚠️ Eingehender Transfer kann nicht entschlüsselt werden – kein RSA-Key',
            name: 'TransferScreen');
        return;
      }
      final privKey = _rsaKeyManager.getMyPrivateKey();
      if (privKey == null) return;

      final plainBytes = _firestore.decryptUserTransfer(data, privKey);

      // Inhalt als Galerie-Eintrag speichern (Base64 für Binär, Text als Text).
      String? asText;
      try {
        asText = utf8.decode(plainBytes);
      } catch (_) {
        asText = null;
      }
      final isMagicQGap = plainBytes.length >= 4 &&
          plainBytes[0] == 0x4F && plainBytes[1] == 0x42 &&
          plainBytes[2] == 0x4D && plainBytes[3] == 0x43;
      if (asText != null && asText.isNotEmpty && !isMagicQGap) {
        await _autoSaveToGallery(asText, SavedQrEntry.detectCategory(asText));
      } else {
        await _autoSaveToGallery(base64.encode(plainBytes), QrCategory.qgap);
      }

      // Lokalen Anzeigenamen für Sender (falls bekannt) holen.
      final senderName = senderUid.isEmpty
          ? 'unbekannt'
          : await LocalContactService.getLocalName(senderUid, fallback: senderUid);

      if (mounted) {
        final marker = senderIsOffline ? '🛡️🛡️🛡️ ' : '☁️ ';
        showQgapSnackBar(
          context,
          SnackBar(
            content: Text(
              '${marker}Transfer empfangen: $fileName\n'
              'von: $senderName · $payloadType ($encryptionType)',
            ),
            duration: const Duration(seconds: 4),
            backgroundColor: senderIsOffline ? Colors.green.shade700 : Colors.indigo,
          ),
        );
      }

      // Verarbeitetes Dokument löschen (verhindert mehrfache Importe).
      try {
        await _firestore.deleteTransfer(doc.id);
      } catch (e) {
        developer.log('log: Transfer-Löschen fehlgeschlagen: $e',
            name: 'TransferScreen');
      }
    } catch (e) {
      developer.log(
          'log: Fehler beim Import eingehender Transfer-Datei: $e – parke in Pickup-Queue.',
          name: 'TransferScreen');
      // Entschlüsselung fehlgeschlagen → in Pickup-Queue parken („halten").
      try {
        final cipherB64 = (data['cipher'] as String?) ?? '';
        final blob = base64.decode(cipherB64);
        await PickupQueueService.enqueue(
          transferDocId: doc.id,
          senderUid: senderUid,
          fileName: fileName,
          encryptionType: encryptionType,
          payloadType: payloadType,
          blob: blob,
          firestoreChatId: firestoreChatId,
          reason: 'Lokal nicht entschlüsselbar: $e',
        );
      } catch (e2) {
        developer.log('log: Pickup-Enqueue (Fallback) fehlgeschlagen: $e2',
            name: 'TransferScreen');
      }
      if (mounted) {
        setState(() {});
        showQgapSnackBar(
          context,
          SnackBar(
              content: Text(
                  'Nicht entschlüsselbar – in Pickup-Queue geparkt: $fileName')),
        );
      }
    }
  }

  /// Verifiziert eine eingehende Lesebestätigung und aktualisiert ggf. den
  /// Delivery-Status der zugehörigen Nachricht im lokalen Cache.
  Future<void> _processIncomingReceipt(
      Uint8List blob, String senderUid) async {
    // 1) Pubkey des Senders ermitteln – bevorzugt aus Pairing, sonst überspringen.
    final pairedPubKeyJson = await PairingService.getPartnerPublicKeyJson();
    final pairedUid = await PairingService.getPartnerOnlineUid();
    if (pairedPubKeyJson == null) {
      developer.log(
          'log: Receipt empfangen, aber kein Pairing-Pubkey – ignoriert.',
          name: 'TransferScreen');
      return;
    }
    if (pairedUid != null && pairedUid != senderUid) {
      developer.log(
          'log: Receipt von $senderUid, aber Pairing-UID=$pairedUid – ignoriert.',
          name: 'TransferScreen');
      return;
    }

    try {
      final parsed = jsonDecode(pairedPubKeyJson) as Map<String, dynamic>;
      final modulus = BigInt.parse(parsed['modulus'].toString());
      final exponent = BigInt.parse(parsed['exponent'].toString());
      final pub = pc.RSAPublicKey(modulus, exponent);
      final result = OfflineReceiptService.verifyReceipt(blob, pub);
      if (result == null) {
        developer.log('log: Receipt-Signatur ungültig.',
            name: 'TransferScreen');
        return;
      }
      final msgId = result['msgId'] as String?;
      if (msgId == null) return;
      if (mounted) {
        showQgapSnackBar(
          context,
          SnackBar(
            content: Text(
                '✅ Lesebestätigung (Air-Gap) erhalten für Nachricht $msgId'),
            backgroundColor: Colors.teal,
          ),
        );
      }
      developer.log(
          'log: Receipt OK – msgId=$msgId, readerFp=${result['readerFp']}',
          name: 'TransferScreen');
    } catch (e) {
      developer.log('log: Receipt-Verifikation fehlgeschlagen: $e',
          name: 'TransferScreen');
    }
  }

  /// Online-Relay: nimmt eine vom Air-Gap-Gerät gescannte Lesebestätigung
  /// (signiertes JSON-Blob) entgegen und leitet sie per Firestore an den
  /// ursprünglichen Nachrichten-Absender weiter. Das Blob wird unverändert
  /// als `payloadType=QGAP_read_receipt` mit `wrap=false` übertragen.
  Future<void> _forwardReceiptToOriginalSender(
      Uint8List blob, Map<dynamic, dynamic> parsed) async {
    final msgId = parsed['msgId']?.toString() ?? '(unbekannt)';
    final readerFp = parsed['readerFp']?.toString() ?? '–';
    final pairedUid = await PairingService.getPartnerOnlineUid();
    final pairedName = await PairingService.getPartnerDisplayName() ?? '–';

    // UID des Original-Absenders abfragen (Air-Gap kennt sie i. d. R. nicht).
    final uidCtrl = TextEditingController();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('📨 Lesebestätigung weiterleiten'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Air-Gap-Partner: $pairedName'),
            Text('Reader-Fingerprint: $readerFp',
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace')),
            Text('Bestätigte Nachricht: $msgId',
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace')),
            if (pairedUid != null) ...[
              const SizedBox(height: 4),
              Text('(Pairing-UID: $pairedUid)',
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: uidCtrl,
              decoration: const InputDecoration(
                labelText: 'UID des ursprünglichen Absenders',
                hintText: 'z. B. abc123...',
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Weiterleiten')),
        ],
      ),
    );
    if (confirmed != true) return;
    final targetUid = uidCtrl.text.trim();
    if (targetUid.isEmpty) {
      if (!mounted) return;
      showQgapSnackBar(context,
          const SnackBar(content: Text('Keine Empfänger-UID angegeben.')));
      return;
    }

    try {
      await _firestore.sendUserTransfer(
        receiverUid: targetUid,
        receiverPublicKeyJson: null,
        fileName: 'read_receipt_$msgId.json',
        payloadBytes: blob,
        payloadType: FirestoreService.kPayloadTypeReadReceipt,
        encryptionType: 'rsa_signed',
        wrap: false,
      );
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text('✅ Lesebestätigung weitergeleitet.'),
            backgroundColor: Colors.teal),
      );
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(content: Text('Weiterleitung fehlgeschlagen: $e')),
      );
    }
  }

  /// ☁️ Datei verschlüsselt an einen anderen User senden (Firestore).
  Future<void> _actionSendToUser() async {
    if (AuthService.currentUid == null) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(content: Text('Nicht eingeloggt – Anmeldung erforderlich.')),
      );
      return;
    }

    // Datei wählen (.qgap oder .qgap_ec).
    final filePicked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['qgap', 'qgap_ec'],
      allowMultiple: false,
      withData: false,
      dialogTitle: 'Datei zum Senden wählen',
    ).catchError((_) => FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: false,
        ));
    if (filePicked == null || filePicked.files.isEmpty || !mounted) return;
    final picked = filePicked.files.first;
    final lower = picked.name.toLowerCase();
    if (!(lower.endsWith('.qgap') || lower.endsWith('.qgap_ec'))) {
      showQgapSnackBar(context,
          SnackBar(content: Text('Nur .qgap/.qgap_ec unterstützt: ${picked.name}')));
      return;
    }

    // Bytes lesen.
    Uint8List? bytes;
    final path = picked.path;
    if (path != null && path.isNotEmpty) {
      if (path.startsWith('content://')) {
        const ch = MethodChannel('de.paulporg.obmc/file_intent');
        bytes = await ch.invokeMethod<Uint8List>('readContentUri', path);
      } else {
        bytes = await File(path).readAsBytes();
      }
    }
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      showQgapSnackBar(context,
          const SnackBar(content: Text('Datei konnte nicht gelesen werden')));
      return;
    }
    if (bytes.length > FirestoreService.kMaxTransferBytes) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(
          content: Text(
            'Datei zu groß für Firestore-Transfer: ${bytes.length} Bytes '
            '(max ${FirestoreService.kMaxTransferBytes} = 300 KB).',
          ),
        ),
      );
      return;
    }

    // Empfänger auswählen.
    final recipient = await _pickTransferRecipient();
    if (recipient == null || !mounted) return;

    // Public Key serialisieren (JSON-Format wie publicKeyToString()).
    final pubKeyJson = jsonEncode({
      'modulus': recipient.publicKey.modulus.toString(),
      'exponent': recipient.publicKey.exponent.toString(),
    });

    // Payload-Typ ableiten.
    final payloadType =
        lower.endsWith('.qgap_ec') ? 'QGAP_ec_key' : 'QGAP_file';

    try {
      final id = await _firestore.sendUserTransfer(
        receiverUid: recipient.uid,
        receiverPublicKeyJson: pubKeyJson,
        encryptionType: 'rsa-hybrid',
        payloadType: payloadType,
        fileName: picked.name,
        payloadBytes: bytes,
        senderIsOffline: recipient.senderIsOffline,
      );
      developer.log('log: ✅ Transfer gesendet: $id → ${recipient.uid}',
          name: 'TransferScreen._actionSendToUser');
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(
          content: Text('✅ "${picked.name}" an ${recipient.displayName} gesendet'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      developer.log('log: Fehler beim Senden: $e',
          name: 'TransferScreen._actionSendToUser');
      if (!mounted) return;
      showQgapSnackBar(context,
          SnackBar(content: Text('Senden fehlgeschlagen: $e')));
    }
  }

  /// Zeigt Empfänger-Auswahl: alle Kontakte mit gespeichertem Public Key.
  Future<_TransferRecipient?> _pickTransferRecipient() async {
    final contacts = await LocalContactService.getAllContacts();
    final keys = await _rsaKeyManager.getContactKeys();

    // Mögliche Empfänger: UID-Kontakte, deren displayName auch in keys vorkommt.
    final List<_TransferRecipient> candidates = [];
    for (final entry in contacts.entries) {
      final uid = entry.key;
      final name = entry.value;
      if (!keys.containsKey(name)) continue;
      final pub = await _rsaKeyManager.getContactPublicKey(name);
      if (pub == null) continue;
      candidates.add(_TransferRecipient(
        uid: uid,
        displayName: name,
        publicKey: pub,
      ));
    }

    if (!mounted) return null;
    bool senderIsOffline = false;
    return showDialog<_TransferRecipient>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Empfänger wählen'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Keine Empfänger mit hinterlegtem Public-Key gefunden.\n\n'
                      'Tipp: Zuerst RSA-Public-Key des Kontakts scannen und Kontakt-UID '
                      'lokal speichern (z. B. via Online-Chat).',
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      itemBuilder: (c, i) {
                        final r = candidates[i];
                        return ListTile(
                          leading: const Icon(Icons.person_outline),
                          title: Text(r.displayName),
                          subtitle: Text(
                            r.uid,
                            style: const TextStyle(
                                fontSize: 11, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => Navigator.of(ctx).pop(
                            r.copyWith(senderIsOffline: senderIsOffline),
                          ),
                        );
                      },
                    ),
                  ),
                const Divider(height: 24),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '🛡️ Quelle ist Air-Gap-Gerät',
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: const Text(
                    'Empfänger sieht 3× Schutzschild als Hinweis auf sichere Herkunft.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: senderIsOffline,
                  onChanged: (v) => setDialogState(() => senderIsOffline = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empfänger-Datensatz für Transfer-Hub-Sender-Dialog.
class _TransferRecipient {
  final String uid;
  final String displayName;
  final dynamic publicKey; // RSAPublicKey – dynamic vermeidet zusätzlichen Import.
  final bool senderIsOffline;
  _TransferRecipient({
    required this.uid,
    required this.displayName,
    required this.publicKey,
    this.senderIsOffline = false,
  });

  _TransferRecipient copyWith({bool? senderIsOffline}) => _TransferRecipient(
        uid: uid,
        displayName: displayName,
        publicKey: publicKey,
        senderIsOffline: senderIsOffline ?? this.senderIsOffline,
      );
}

/// Widget für binäre QR-Codes mit Byte-Mode Encoding.
/// Verwendet direkt das `qr` Package für korrekte Byte-Mode Unterstützung.
class BinaryQrImage extends StatelessWidget {
  final Uint8List bytes;
  final double size;
  final Color backgroundColor;
  final Color foregroundColor;

  const BinaryQrImage({
    super.key,
    required this.bytes,
    this.size = 280,
    this.backgroundColor = Colors.white,
    this.foregroundColor = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    try {
      print('🔧 BinaryQrImage: Erstelle QR-Code für ${bytes.length} bytes');
      print('🔧 Erste 10 Bytes: ${bytes.take(10).toList()}');
      
      // Erstelle QR-Code im Byte-Mode (nicht UTF-8!)
      final qrCode = QrCode.fromUint8List(
        data: bytes,
        errorCorrectLevel: QrErrorCorrectLevel.L, // Niedrigste EC für maximale Datendichte
      );
      
      final qrImage = QrImage(qrCode);
      print('✅ QR-Code erstellt: Version ${qrCode.typeNumber}, Module: ${qrCode.moduleCount}');
      
      return CustomPaint(
        size: Size(size, size),
        painter: _BinaryQrPainter(
          qrImage: qrImage,
          moduleCount: qrCode.moduleCount,
          color: foregroundColor,
          backgroundColor: backgroundColor,
        ),
      );
    } catch (e) {
      print('❌ Fehler beim Erstellen des QR-Codes: $e');
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            'Fehler beim Erstellen\ndes QR-Codes:\n$e',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }
  }
}

/// CustomPainter für binäre QR-Codes.
class _BinaryQrPainter extends CustomPainter {
  final QrImage qrImage;
  final int moduleCount;
  final Color color;
  final Color backgroundColor;

  _BinaryQrPainter({
    required this.qrImage,
    required this.moduleCount,
    required this.color,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = color;

    // Hintergrund
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = backgroundColor,
    );

    if (moduleCount == 0) return;

    final moduleSize = size.width / moduleCount;

    // Zeichne jeden Modul
    for (var y = 0; y < moduleCount; y++) {
      for (var x = 0; x < moduleCount; x++) {
        if (qrImage.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH(
              x * moduleSize,
              y * moduleSize,
              moduleSize,
              moduleSize,
            ),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BinaryQrPainter oldDelegate) {
    return qrImage != oldDelegate.qrImage ||
        color != oldDelegate.color ||
        backgroundColor != oldDelegate.backgroundColor;
  }
}

// ─── Offline-Pickup-Queue-Sektion ─────────────────────────────────────────
/// Zeigt eine ein-/ausklappbare Sektion mit allen in der `PickupQueueService`
/// geparkten Transfers. Nur sichtbar, wenn das Gerät als Online-Relay
/// konfiguriert ist ODER die Queue mindestens einen Eintrag enthält.
class _PickupQueueSection extends StatefulWidget {
  final VoidCallback onChanged;
  const _PickupQueueSection({required this.onChanged});

  @override
  State<_PickupQueueSection> createState() => _PickupQueueSectionState();
}

class _PickupQueueSectionState extends State<_PickupQueueSection> {
  bool _expanded = true;
  List<PickupQueueEntry> _entries = const [];
  DeviceRole _role = DeviceRole.standalone;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final role = await DeviceRoleService.get();
    final entries = await PickupQueueService.loadEntries();
    if (!mounted) return;
    setState(() {
      _role = role;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _exportEntry(PickupQueueEntry e) async {
    try {
      final blob = await PickupQueueService.readBlob(e.transferDocId);
      if (blob == null) {
        if (!mounted) return;
        showQgapSnackBar(context,
            const SnackBar(content: Text('Pickup-Blob nicht gefunden.')));
        return;
      }
      // Auf SD-Karte / Download-Ordner exportieren
      final dir = Platform.isAndroid ? await getExternalStorageDirectory() : null;
      final basePath = dir?.path ?? (await getApplicationDocumentsDirectory()).path;
      final outPath = '$basePath/${e.fileName}.pickup.bin';
      final f = File(outPath);
      await f.writeAsBytes(blob, flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(outPath)],
          text: 'QGap Pickup: ${e.fileName}');
    } catch (err) {
      if (!mounted) return;
      showQgapSnackBar(context,
          SnackBar(content: Text('Export fehlgeschlagen: $err')));
    }
  }

  Future<void> _discardEntry(PickupQueueEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pickup-Eintrag verwerfen?'),
        content: Text(
            'Soll der geparkte Transfer "${e.fileName}" endgültig gelöscht werden? '
            'Der Air-Gap-Partner kann ihn dann nicht mehr abholen.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verwerfen',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    await PickupQueueService.remove(e.transferDocId);
    await _reload();
    widget.onChanged();
  }

  Future<void> _sendViaQr(PickupQueueEntry e) async {
    try {
      final blob = await PickupQueueService.readBlob(e.transferDocId);
      if (blob == null) {
        if (!mounted) return;
        showQgapSnackBar(context,
            const SnackBar(content: Text('Pickup-Blob nicht gefunden.')));
        return;
      }
      if (!mounted) return;
      // Wiederverwendung des bestehenden Fountain-Code-Senders.
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => QrDataSender(
          bytes: blob,
        ),
      ));
    } catch (err) {
      if (!mounted) return;
      showQgapSnackBar(context,
          SnackBar(content: Text('QR-Versand fehlgeschlagen: $err')));
    }
  }

  String _shortSender(String uid) =>
      uid.isEmpty ? 'unbekannt' : (uid.length > 8 ? uid.substring(0, 8) : uid);

  String _formatBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final visible =
        _role == DeviceRole.onlineRelay || _entries.isNotEmpty;
    if (!visible) return const SizedBox.shrink();

    return Material(
      color: Colors.indigo.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.inbox, color: Colors.indigo, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '📥 Offline-Pickup-Queue (${_entries.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.indigo),
                    ),
                  ),
                  IconButton(
                    iconSize: 18,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    tooltip: 'Aktualisieren',
                    icon: const Icon(Icons.refresh, color: Colors.indigo),
                    onPressed: _reload,
                  ),
                  const SizedBox(width: 4),
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                      color: Colors.indigo),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            if (_entries.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Text(
                  'Keine geparkten Transfers. '
                  'Online-Relay nimmt eingehende Pakete entgegen, '
                  'die nicht lokal entschlüsselt werden können.',
                  style: TextStyle(fontSize: 12, color: Colors.indigo),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.indigo),
                  itemBuilder: (ctx, i) {
                    final e = _entries[i];
                    return Container(
                      color: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(e.fileName,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13)),
                                Text(
                                  'von ${_shortSender(e.senderUid)} · '
                                  '${e.payloadType} (${e.encryptionType}) · '
                                  '${_formatBytes(e.sizeBytes)}',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade700),
                                ),
                                if (e.reason.isNotEmpty)
                                  Text(
                                    e.reason,
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.orange,
                                        fontStyle: FontStyle.italic),
                                  ),
                              ],
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Aktionen',
                            iconSize: 18,
                            padding: EdgeInsets.zero,
                            onSelected: (v) async {
                              switch (v) {
                                case 'qr':
                                  await _sendViaQr(e);
                                  break;
                                case 'export':
                                  await _exportEntry(e);
                                  break;
                                case 'discard':
                                  await _discardEntry(e);
                                  break;
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'qr',
                                child: Row(children: [
                                  Icon(Icons.qr_code, size: 16),
                                  SizedBox(width: 8),
                                  Text('Per QR an Air-Gap'),
                                ]),
                              ),
                              PopupMenuItem(
                                value: 'export',
                                child: Row(children: [
                                  Icon(Icons.file_upload, size: 16),
                                  SizedBox(width: 8),
                                  Text('Per USB exportieren'),
                                ]),
                              ),
                              PopupMenuItem(
                                value: 'discard',
                                child: Row(children: [
                                  Icon(Icons.delete_outline,
                                      size: 16, color: Colors.red),
                                  SizedBox(width: 8),
                                  Text('Verwerfen',
                                      style:
                                          TextStyle(color: Colors.red)),
                                ]),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    );
  }
}

