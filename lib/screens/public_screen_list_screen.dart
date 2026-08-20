// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qgap/model/public_screen_session.dart';
import 'package:qgap/services/public_screen_service.dart';
import 'package:qgap/screens/public_screen_admin_screen.dart';

/// Übersicht aller eigenen PublicScreen-Sessions.
/// Von hier aus werden Sessions erstellt oder geöffnet.
class PublicScreenListScreen extends StatefulWidget {
  const PublicScreenListScreen({super.key});

  @override
  State<PublicScreenListScreen> createState() => _PublicScreenListScreenState();
}

class _PublicScreenListScreenState extends State<PublicScreenListScreen> {
  final PublicScreenService _service = PublicScreenService();
  final _dateFormat = DateFormat('dd.MM.yyyy HH:mm');
  late Future<List<PublicScreenSession>> _sessionsFuture;

  @override
  void initState() {
    super.initState();
    _sessionsFuture = _service.loadMySessions();
  }

  void _reload() {
    setState(() => _sessionsFuture = _service.loadMySessions());
  }

  // ── Session erstellen ────────────────────────────────────────────────────

  Future<void> _createSession() async {
    final controller = TextEditingController(
      text: 'Liedsession ${DateFormat('dd.MM.yyyy').format(DateTime.now())}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Neue PublicScreen-Session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Titel',
            border: OutlineInputBorder(),
          ),
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Erstellen'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final title = controller.text.trim();
    if (title.isEmpty) return;

    try {
      final session = await _service.createSession(title);
      if (!mounted) return;
      _reload();
      _openSession(session);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _openSession(PublicScreenSession session) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PublicScreenAdminScreen(sessionId: session.id),
    )).then((_) => _reload()); // Beim Zurücknavigieren neu laden
  }

  // ── Admin-Code als Text importieren (ohne Kamera, z. B. Windows) ───────

  Future<void> _importAdminCode() async {
    final controller = TextEditingController();
    // Zwischenablage vorbefüllen, wenn sie einen Admin-Code enthält
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final t = clip?.text?.trim() ?? '';
      if (t.contains('qgap_ps_admin')) controller.text = t;
    } catch (_) {}
    if (!mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Admin-Code einfügen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Admin-Code vom ersten Handy hier einfügen '
              '(im Teilen-Dialog über „Kopieren“ erhältlich):',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 4,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: '{"kind":"qgap_ps_admin","sessionId":"…","adminSecret":"…"}',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: 'Aus Zwischenablage einfügen',
                  onPressed: () async {
                    final clip =
                        await Clipboard.getData(Clipboard.kTextPlain);
                    if (clip?.text != null) {
                      controller.text = clip!.text!.trim();
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.admin_panel_settings, size: 18),
            label: const Text('Koppeln'),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final dynamic map = jsonDecode(controller.text.trim());
      final kind = map is Map ? map['kind'] as String? : null;
      final normalizedKind =
          kind != null && kind.startsWith('obmc_') ? 'qgap_${kind.substring(5)}' : kind;
      if (map is! Map ||
          normalizedKind != 'qgap_ps_admin' ||
          map['sessionId'] is! String ||
          map['adminSecret'] is! String) {
        throw Exception('Kein gültiger Admin-Code (kind=qgap_ps_admin fehlt).');
      }
      final session = await _service.joinAsAdmin(
          map['sessionId'] as String, map['adminSecret'] as String);
      if (!mounted) return;
      _reload();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Admin-Modus für „${session.title}“ aktiviert'),
        backgroundColor: Colors.green,
      ));
      _openSession(session);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('❌ Kopplung fehlgeschlagen: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  // ── State-Badge ──────────────────────────────────────────────────────────

  Color _stateColor(PublicScreenState state) {
    switch (state) {
      case PublicScreenState.start:  return Colors.blue.shade600;
      case PublicScreenState.active: return Colors.green.shade600;
      case PublicScreenState.pause:  return Colors.orange.shade600;
      case PublicScreenState.ended:  return Colors.grey.shade600;
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('📺 Präsentationen'),
        backgroundColor: const Color(0xFF5A07E9),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_go),
            tooltip: 'Admin-Code einfügen (Session koppeln)',
            onPressed: _importAdminCode,
          ),
        ],
      ),
      body: FutureBuilder<List<PublicScreenSession>>(
        future: _sessionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Fehler: ${snapshot.error}'));
          }

          final sessions = snapshot.data ?? [];

          if (sessions.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.slideshow, size: 80, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'Noch keine Sessions',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Tippe auf + um eine neue Liedsession zu starten.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _createSession,
                    icon: const Icon(Icons.add),
                    label: const Text('Session erstellen'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final s = sessions[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _stateColor(s.state),
                    child: const Icon(Icons.slideshow, color: Colors.white),
                  ),
                  title: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    '${s.state.label} · ${_dateFormat.format(s.updatedAt)}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Chip(
                    label: Text(
                      s.state.label,
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                    backgroundColor: _stateColor(s.state),
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onTap: () => _openSession(s),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createSession,
        icon: const Icon(Icons.add),
        label: const Text('Neue Session'),
        backgroundColor: const Color(0xFF5A07E9),
        foregroundColor: Colors.white,
      ),
    );
  }
}
