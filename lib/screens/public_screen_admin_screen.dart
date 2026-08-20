// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:qgap/model/public_screen_session.dart';
import 'package:qgap/services/public_screen_service.dart';
import 'package:qgap/services/share_service.dart';
import 'package:qgap/screens/public_screen_settings_dialog.dart';
import 'package:qgap/screens/song_slide_screen.dart';

/// Admin-Steuerung einer PublicScreen-Session.
/// Zeigt QR-Code, State-Buttons und Folien-Upload.
class PublicScreenAdminScreen extends StatefulWidget {
  final String sessionId;

  const PublicScreenAdminScreen({super.key, required this.sessionId});

  @override
  State<PublicScreenAdminScreen> createState() =>
      _PublicScreenAdminScreenState();
}

class _PublicScreenAdminScreenState extends State<PublicScreenAdminScreen> {
  final PublicScreenService _service = PublicScreenService();
  PublicScreenSession? _session;
  bool _uploading = false;
  String? _lastUploadInfo;

  // ── Viewer URL ────────────────────────────────────────────────────────────

  String get _viewerUrl => PublicScreenService.viewerUrl(widget.sessionId);

  // ── State setzen ─────────────────────────────────────────────────────────

  Future<void> _setState(PublicScreenState state) async {
    try {
      await _service.setState(widget.sessionId, state);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ── Folie hochladen ───────────────────────────────────────────────────────

  Future<void> _uploadSlide() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;

    final session = _session;
    if (session == null) return;

    setState(() {
      _uploading = true;
      _lastUploadInfo = null;
    });

    try {
      final before = DateTime.now();
      await _service.uploadSlide(session, File(path));
      final elapsed = DateTime.now().difference(before).inMilliseconds;
      if (!mounted) return;
      setState(() {
        final time = TimeOfDay.now().format(context);
        _lastUploadInfo = '$time · ${elapsed}ms';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload-Fehler: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ── Einstellungen ────────────────────────────────────────────────────────

  Future<void> _openSettings() async {
    final session = _session;
    if (session == null) return;

    final result = await showDialog<PublicScreenSession>(
      context: context,
      builder: (_) => PublicScreenSettingsDialog(session: session),
    );

    if (result != null && mounted) {
      // Session wurde bereits im Dialog gespeichert, Stream aktualisiert automatisch
    }
  }

  // ── Session löschen ──────────────────────────────────────────────────────

  Future<void> _deleteSession() async {
    final session = _session;
    if (session == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Session löschen?'),
        content: Text(
          'Die Session "${session.title}" und alle zugehörigen Bilder werden '
          'unwiderruflich gelöscht.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _service.deleteSession(session);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // ── URL teilen / kopieren ────────────────────────────────────────────────

  void _copyUrl() {
    Clipboard.setData(ClipboardData(text: _viewerUrl));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('URL in Zwischenablage kopiert')),
    );
  }

  Future<void> _shareUrl() async {
    await Share.share(
      'Lied-Session live:\n$_viewerUrl',
      subject: _session?.title ?? 'QGap Liedsession',
    );
  }

  // ── Admin-Modus teilen (weiteres Handy koppeln) ────────────────────

  Future<void> _shareAdminMode() async {
    String secret;
    try {
      secret = await _service.getOrCreateAdminSecret(widget.sessionId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Admin-Secret Fehler: $e'), backgroundColor: Colors.red),
      );
      return;
    }
    if (!mounted) return;

    final payload = jsonEncode({
      'kind':        'qgap_ps_admin',
      'sessionId':   widget.sessionId,
      'adminSecret': secret,
    });

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin-Modus teilen'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Anderes Handy: QGap-App öffnen und diesen QR-Code mit dem '
                'Scan-Button auf der Startseite scannen. Das Handy kann die '
                'Session dann gleichberechtigt steuern.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(8),
                child: QrImageView(
                  data: payload,
                  version: QrVersions.auto,
                  size: 220,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Windows/iPhone ohne Kamera-Scan: „Als Datei teilen“ oder '
                '„Kopieren“ nutzen – auf dem Zielgerät die Datei öffnen bzw. '
                'den Code über den Scan-Button einfügen.',
                style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              const Text(
                '⚠️ Nur an Personen weitergeben, die die Präsentation '
                'steuern dürfen – nicht der Mitsinger-QR!',
                style: TextStyle(fontSize: 11, color: Colors.orange),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Als Datei teilen'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              final title = (_session?.title ?? 'Session')
                  .replaceAll(RegExp(r'[^\w\-äöüÄÖÜß ]'), '_');
              await ShareService.showShareDialog(
                context: context,
                fileName: 'PsAdmin_$title.qgap_ch',
                bytes: Uint8List.fromList(utf8.encode(payload)),
                clipboardText: payload,
                subject: 'QGap Präsentations-Admin: ${_session?.title ?? ''}',
              );
            },
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Kopieren'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Admin-Code kopiert')),
              );
            },
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  // ── State-Badge-Farbe ─────────────────────────────────────────────────────

  Color _stateColor(PublicScreenState state) {
    switch (state) {
      case PublicScreenState.start:  return Colors.blue.shade600;
      case PublicScreenState.active: return Colors.green.shade600;
      case PublicScreenState.pause:  return Colors.orange.shade600;
      case PublicScreenState.ended:  return Colors.red.shade600;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PublicScreenSession?>(
      stream: _service.watchSession(widget.sessionId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && _session == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final session = snapshot.data ?? _session;
        if (session != null) _session = session;

        if (session == null) {
          return const Scaffold(
            body: Center(child: Text('Session nicht gefunden.')),
          );
        }

        return Scaffold(
          appBar: AppBar(
            backgroundColor: const Color(0xFF5A07E9),
            foregroundColor: Colors.white,
            title: Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: 'Einstellungen',
                onPressed: _openSettings,
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Status-Anzeige ─────────────────────────────────────────
                _StatusCard(session: session, stateColor: _stateColor(session.state)),
                const SizedBox(height: 16),

                // ── QR-Code ───────────────────────────────────────────────
                _QrCard(
                  url: _viewerUrl,
                  onCopy: _copyUrl,
                  onShare: _shareUrl,
                ),
                const SizedBox(height: 16),

                // ── State-Buttons ─────────────────────────────────────────
                _StateButtons(
                  currentState: session.state,
                  onSetState: _setState,
                ),
                const SizedBox(height: 16),

                // ── Folien-Upload ─────────────────────────────────────────
                _UploadCard(
                  uploading: _uploading,
                  lastUploadInfo: _lastUploadInfo,
                  currentImageData: session.currentImageData,
                  exportSettings: session.exportSettings,
                  onUpload: _uploadSlide,
                ),
                const SizedBox(height: 24),
                // ── Liedtexte (SongBeamer) ──────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.purple.shade300,
                      side: BorderSide(color: Colors.purple.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SongSlideScreen(session: session),
                      ));
                    },
                    icon: const Icon(Icons.music_note),
                    label: const Text('Liedtexte (SongBeamer)'),
                  ),
                ),
                const SizedBox(height: 8),
                // ── Admin-Modus teilen (weiteres Handy koppeln) ──────────
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.orange.shade700,
                      side: BorderSide(color: Colors.orange.shade700),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _shareAdminMode,
                    icon: const Icon(Icons.admin_panel_settings),
                    label: const Text('Admin-Modus teilen'),
                  ),
                ),
                const SizedBox(height: 8),
                // ── Session löschen ───────────────────────────────────────
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                  onPressed: _deleteSession,
                  icon: const Icon(Icons.delete_forever),
                  label: const Text('Session löschen'),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Status-Card ───────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final PublicScreenSession session;
  final Color stateColor;

  const _StatusCard({required this.session, required this.stateColor});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: stateColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Status: ${session.state.label}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: stateColor,
                fontSize: 16,
              ),
            ),
            const Spacer(),
            Chip(
              label: Text(
                session.orientation == PublicScreenOrientation.landscape
                    ? 'Quer'
                    : 'Hoch',
                style: const TextStyle(fontSize: 11),
              ),
              avatar: Icon(
                session.orientation == PublicScreenOrientation.landscape
                    ? Icons.stay_current_landscape
                    : Icons.stay_current_portrait,
                size: 14,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }
}

// ── QR-Code-Card ──────────────────────────────────────────────────────────────

class _QrCard extends StatelessWidget {
  final String url;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  const _QrCard({
    required this.url,
    required this.onCopy,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'QR-Code für Mitsinger',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 4),
            const Text(
              'Einmal antippen → Vollbild-Viewer öffnet sich',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 200,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 8),
            Text(
              url,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Kopieren'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share, size: 16),
                  label: const Text('Teilen'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF5A07E9),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── State-Buttons ─────────────────────────────────────────────────────────────

class _StateButtons extends StatelessWidget {
  final PublicScreenState currentState;
  final Future<void> Function(PublicScreenState) onSetState;

  const _StateButtons({
    required this.currentState,
    required this.onSetState,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Viewer-Status',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _StateBtn(
                    label: 'Start',
                    icon: Icons.play_circle_outline,
                    color: Colors.blue.shade600,
                    active: currentState == PublicScreenState.start,
                    onTap: () => onSetState(PublicScreenState.start),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StateBtn(
                    label: 'Pause',
                    icon: Icons.pause_circle_outline,
                    color: Colors.orange.shade600,
                    active: currentState == PublicScreenState.pause,
                    onTap: () => onSetState(PublicScreenState.pause),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StateBtn(
                    label: 'Ende',
                    icon: Icons.stop_circle_outlined,
                    color: Colors.red.shade600,
                    active: currentState == PublicScreenState.ended,
                    onTap: () => onSetState(PublicScreenState.ended),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StateBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  const _StateBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: active ? null : onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: active ? color : color.withValues(alpha: 0.12),
        foregroundColor: active ? Colors.white : color,
        elevation: active ? 2 : 0,
        side: BorderSide(color: color, width: active ? 0 : 1),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}

// ── Upload-Card ───────────────────────────────────────────────────────────────

class _UploadCard extends StatelessWidget {
  final bool uploading;
  final String? lastUploadInfo;
  final String? currentImageData;
  final ExportSettings exportSettings;
  final VoidCallback onUpload;

  const _UploadCard({
    required this.uploading,
    required this.lastUploadInfo,
    required this.currentImageData,
    required this.exportSettings,
    required this.onUpload,
  });

  static Uint8List _decodeBase64(String dataUri) {
    final str = dataUri.contains(',') ? dataUri.split(',').last : dataUri;
    return base64Decode(str);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Folie hochladen',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 4),
            Text(
              '${exportSettings.resolutionLabel} · ${exportSettings.format.toUpperCase()} Q${exportSettings.quality}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            if (currentImageData != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  _decodeBase64(currentImageData!),
                  height: 120,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) =>
                      const Icon(Icons.broken_image, size: 60),
                ),
              ),
            if (currentImageData != null) const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: uploading ? null : onUpload,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green.shade700,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: uploading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.upload_file),
                label: Text(uploading ? 'Wird hochgeladen …' : 'Folie auswählen & hochladen'),
              ),
            ),
            if (lastUploadInfo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Zuletzt: $lastUploadInfo',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
