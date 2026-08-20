// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Plattformübergreifendes Teilen von Inhalten (Android / iOS / Windows).
///
/// Zeigt einen Auswahl-Dialog mit allen auf der Plattform verfügbaren Wegen:
///  • System-Teilen (Share-Sheet mit E-Mail, Messenger … — nur Android/iOS)
///  • Als Datei speichern (Speichern-Dialog — alle Plattformen)
///  • In Zwischenablage kopieren (bei Text-Inhalten — alle Plattformen)
///  • Per E-Mail senden (mailto — nur Windows, dort gibt es kein Share-Sheet)
class ShareService {
  ShareService._();

  static bool get _hasSystemShare => Platform.isAndroid || Platform.isIOS;

  /// Zeigt den Teilen-Dialog für [bytes] mit Dateiname [fileName].
  /// [clipboardText]: textuelle Repräsentation für Zwischenablage/E-Mail
  /// (z. B. Einladungs-JSON oder Liedtext); null = Option ausblenden.
  static Future<void> showShareDialog({
    required BuildContext context,
    required String fileName,
    required Uint8List bytes,
    String? clipboardText,
    String mime = 'application/octet-stream',
    String? subject,
  }) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(fileName,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text('${bytes.length} Bytes'),
            ),
            const Divider(height: 1),
            if (_hasSystemShare)
              ListTile(
                leading: const Icon(Icons.share),
                title: const Text('Teilen …'),
                subtitle: const Text('E-Mail, Messenger, Nearby …'),
                onTap: () => Navigator.of(ctx).pop('system'),
              ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Als Datei speichern …'),
              subtitle: Text(Platform.isWindows
                  ? 'Speicherort wählen (z. B. USB-Stick, Ordner)'
                  : 'Speicherort wählen'),
              onTap: () => Navigator.of(ctx).pop('file'),
            ),
            if (clipboardText != null)
              ListTile(
                leading: const Icon(Icons.copy),
                title: const Text('In Zwischenablage kopieren'),
                onTap: () => Navigator.of(ctx).pop('clipboard'),
              ),
            if (Platform.isWindows && clipboardText != null)
              ListTile(
                leading: const Icon(Icons.email_outlined),
                title: const Text('Per E-Mail senden'),
                subtitle: const Text('Öffnet Standard-Mailprogramm (Inhalt als Text)'),
                onTap: () => Navigator.of(ctx).pop('email'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'system':
        await _shareViaSystem(context, fileName, bytes, mime, subject);
      case 'file':
        await saveAsFile(context, fileName, bytes);
      case 'clipboard':
        await Clipboard.setData(ClipboardData(text: clipboardText!));
        _snack(context, '✅ In Zwischenablage kopiert.', success: true);
      case 'email':
        await _sendViaMailto(context, subject ?? fileName, clipboardText!);
    }
  }

  // ── System-Share-Sheet (Android/iOS) ──────────────────────────────────────
  static Future<void> _shareViaSystem(BuildContext context, String fileName,
      Uint8List bytes, String mime, String? subject) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes, flush: true);
      final result = await Share.shareXFiles(
        [XFile(file.path, name: fileName, mimeType: mime)],
        subject: subject,
      );
      if (!context.mounted) return;
      if (result.status == ShareResultStatus.success) {
        _snack(context, '✅ "$fileName" erfolgreich geteilt.', success: true);
      } else if (result.status == ShareResultStatus.dismissed) {
        _snack(context, 'Teilen abgebrochen.');
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Fehler beim Teilen: $e');
    }
  }

  // ── Speichern-Dialog (alle Plattformen) ───────────────────────────────────
  static Future<void> saveAsFile(
      BuildContext context, String fileName, Uint8List bytes) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Speichern unter',
        fileName: fileName,
        bytes: bytes, // Android/iOS: schreibt direkt über SAF/Files-App
      );
      if (path == null) {
        if (context.mounted) _snack(context, 'Speichern abgebrochen.');
        return;
      }
      // Desktop: saveFile liefert nur den Pfad, schreiben müssen wir selbst.
      if (!Platform.isAndroid && !Platform.isIOS) {
        await File(path).writeAsBytes(bytes, flush: true);
      }
      if (context.mounted) {
        _snack(context, '✅ Gespeichert: $path', success: true);
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Fehler beim Speichern: $e');
    }
  }

  // ── mailto (Windows) ──────────────────────────────────────────────────────
  static Future<void> _sendViaMailto(
      BuildContext context, String subject, String body) async {
    try {
      final uri = Uri(
        scheme: 'mailto',
        query: 'subject=${Uri.encodeComponent(subject)}'
            '&body=${Uri.encodeComponent(body)}',
      ).toString();
      await Process.start(
          'rundll32', ['url.dll,FileProtocolHandler', uri]);
      if (context.mounted) {
        _snack(context, 'Mailprogramm geöffnet.', success: true);
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'E-Mail fehlgeschlagen: $e');
    }
  }

  static void _snack(BuildContext context, String msg, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? Colors.green : null,
      duration: const Duration(seconds: 4),
    ));
  }
}
