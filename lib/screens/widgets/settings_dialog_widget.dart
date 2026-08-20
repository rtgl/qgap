// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/material.dart';
import 'package:qgap/model/message.dart' as qgap_model;

class SettingsDialogWidget extends StatefulWidget {
  final String chatGroupName;
  final List<String> availableFiles;
  final String initialSelectedFile;
  final int initialOffset;
  final qgap_model.EncryptionType initialEncryptionType;
  final int Function(String) getKeyFileSize;

  // EC-Datei (.qgap_ec) Optionen
  final List<String> availableEcFiles;
  final String? initialEcFile;
  final bool initialEcUsbOnly;

  // RSA-Schl�sselaustausch
  final String? initialContactKeyFingerprint;
  final Future<String?> Function() onScanContactPublicKey;
  final VoidCallback onShowMyPublicKey;

  final Future<void> Function(
      String, int, qgap_model.EncryptionType, String?, bool) onSave;

  const SettingsDialogWidget({
    super.key,
    required this.chatGroupName,
    required this.availableFiles,
    required this.initialSelectedFile,
    required this.initialOffset,
    required this.initialEncryptionType,
    required this.getKeyFileSize,
    required this.availableEcFiles,
    required this.initialEcFile,
    required this.initialEcUsbOnly,
    required this.initialContactKeyFingerprint,
    required this.onScanContactPublicKey,
    required this.onShowMyPublicKey,
    required this.onSave,
  });

  @override
  State<SettingsDialogWidget> createState() => _SettingsDialogWidgetState();
}

class _SettingsDialogWidgetState extends State<SettingsDialogWidget> {
  late String tempSelectedFile;
  late TextEditingController offsetController;
  late qgap_model.EncryptionType tempEncryptionType;

  // EC-Datei-State
  String? tempEcFile;
  late bool tempEcUsbOnly;

  // RSA-State
  String? tempContactKeyFingerprint;
  bool _scanningPublicKey = false;

  @override
  void initState() {
    super.initState();
    tempSelectedFile = widget.initialSelectedFile;
    // Nur One-Time-Pad und Hybrid zulassen; falls initial RSA, auf One-Time-Pad zurückfallen
    tempEncryptionType =
        widget.initialEncryptionType == qgap_model.EncryptionType.rsa
            ? qgap_model.EncryptionType.oneTimePad
            : widget.initialEncryptionType;
    offsetController =
        TextEditingController(text: widget.initialOffset.toString());
    tempEcFile = widget.initialEcFile;
    tempEcUsbOnly = widget.initialEcUsbOnly;
    tempContactKeyFingerprint = widget.initialContactKeyFingerprint;
  }

  @override
  void dispose() {
    offsetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Einstellungen - ${widget.chatGroupName}'),
      // Feste Inhaltsbreite: verhindert unbegrenzte Constraints im Dialog
      // (Desktop-Crash "RenderConstrainedBox size MISSING").
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Verfügbare Verschlüsselungsdateien:'),
              const SizedBox(height: 5),
              Text(
                '(Nur unzugeordnete Dateien werden angezeigt)',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 10),
              widget.availableFiles.isEmpty
                  ? const Text('Keine verfügbaren .qgap Dateien gefunden',
                      style: TextStyle(color: Colors.red))
                  : DropdownButton<String>(
                      value: tempSelectedFile,
                      isExpanded: true,
                      selectedItemBuilder: (BuildContext context) {
                        return widget.availableFiles.map((String fileName) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              fileName,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          );
                        }).toList();
                      },
                      items: widget.availableFiles.map((String fileName) {
                        return DropdownMenuItem<String>(
                          value: fileName,
                          child: Text(
                            fileName,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          tempSelectedFile =
                              newValue ?? widget.availableFiles.first;
                        });
                      },
                    ),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 10),

              // Verschlüsselungsart Einstellung
              const Text(
                'Verschlüsselungsart:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),

              DropdownButton<qgap_model.EncryptionType>(
                value: tempEncryptionType,
                isExpanded: true,
                items: <qgap_model.EncryptionType>[
                  qgap_model.EncryptionType.oneTimePad,
                  qgap_model.EncryptionType.hybrid,
                ].map((qgap_model.EncryptionType type) {
                  String displayName;
                  switch (type) {
                    case qgap_model.EncryptionType.oneTimePad:
                      displayName = 'One-Time-Pad (QGap)';
                      break;
                    case qgap_model.EncryptionType.hybrid:
                      displayName = 'Hybrid (RSA + AES)';
                      break;
                    default:
                      displayName = type.toString();
                  }
                  return DropdownMenuItem<qgap_model.EncryptionType>(
                    value: type,
                    child: Text(displayName,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                  );
                }).toList(),
                onChanged: (qgap_model.EncryptionType? newValue) {
                  setState(() {
                    tempEncryptionType =
                        (newValue == qgap_model.EncryptionType.hybrid)
                            ? qgap_model.EncryptionType.hybrid
                            : qgap_model.EncryptionType.oneTimePad;
                  });
                },
              ),

              // Show description below the dropdown
              Builder(
                builder: (context) {
                  String description;
                  switch (tempEncryptionType) {
                    case qgap_model.EncryptionType.oneTimePad:
                      description =
                          'Sichere Einmal-Code - Verschlüsselung mit .qgap Dateien';
                      break;
                    case qgap_model.EncryptionType.hybrid:
                      description =
                          'Kombination aus RSA und AES für optimale Sicherheit';
                      break;
                    default:
                      description = '';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4.0, bottom: 16.0),
                    child: Text(
                      description,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                          fontStyle: FontStyle.italic),
                    ),
                  );
                },
              ),
              const Divider(),
              const SizedBox(height: 10),

              // Byte-Offset Einstellung
              const Text(
                'Byte-Offset (verwendete Bytes):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Aktuell: ${widget.initialOffset} Bytes verwendet',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (context) {
                  int fileSize = widget.getKeyFileSize(tempSelectedFile);
                  int maxOffset = fileSize > 100 ? fileSize - 100 : 0;
                  return TextField(
                    controller: offsetController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Neuer Byte-Offset',
                      hintText: 'z.B. 0 für Zurücksetzen',
                      border: const OutlineInputBorder(),
                      suffixText: 'Bytes',
                      helperText: fileSize > 0
                          ? 'Max: $maxOffset Bytes (Dateigröße: $fileSize - 100)'
                          : 'Achtung: Falsche Werte können Entschlüsselung beeinträchtigen',
                      helperStyle: TextStyle(
                          color: fileSize > 0
                              ? Colors.blue.shade600
                              : Colors.orange.shade600,
                          fontSize: 11),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final maxW = constraints.maxWidth.isFinite
                      ? constraints.maxWidth
                      : 400.0;
                  final half = (maxW - 8) / 2;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      SizedBox(
                        width: half > 0 ? half : maxW,
                        child: OutlinedButton(
                          onPressed: () {
                            offsetController.text = '0';
                          },
                          child: const Text('Zurücksetzen auf 0',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                      SizedBox(
                        width: half > 0 ? half : maxW,
                        child: OutlinedButton(
                          onPressed: () {
                            offsetController.text =
                                widget.initialOffset.toString();
                          },
                          child: const Text('Aktuellen Wert',
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                  );
                },
              ),

              // ─────────────────────────────────────────────────────────────
              // EC-Datei Sektion - nur bei One-Time-Pad
              // �"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"��"�
              if (tempEncryptionType ==
                  qgap_model.EncryptionType.oneTimePad) ...[
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 10),

                const Text(
                  'Einmal-Code Datei (.qgap_ec):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Optionaler Zusatz-Schlüssel für diesen Chat.',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 10),

                // USB-only Toggle
                Row(
                  children: [
                    Switch(
                      value: tempEcUsbOnly,
                      onChanged: (v) => setState(() => tempEcUsbOnly = v),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Nur von USB laden',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500)),
                          Text(
                            'Sicherheitsmodus: EC-Datei muss\nphysisch am USB-Stick vorhanden sein.',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // EC-Datei Dropdown
                if (widget.availableEcFiles.isEmpty)
                  Text(
                    'Keine .qgap_ec Dateien gefunden.\n'
                    'Dateien im Verzeichnis Daten/QGap/schluessel ablegen.',
                    style:
                        TextStyle(fontSize: 12, color: Colors.orange.shade700),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // "Keine" Option + Dateien
                      DropdownButton<String?>(
                        value: tempEcFile,
                        isExpanded: true,
                        hint: const Text('— keine EC-Datei —'),
                        selectedItemBuilder: (ctx) {
                          final items = <String?>[
                            null,
                            ...widget.availableEcFiles
                          ];
                          return items.map((f) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                f ?? '— keine EC-Datei —',
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            );
                          }).toList();
                        },
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('— keine EC-Datei —',
                                style: TextStyle(
                                    fontStyle: FontStyle.italic,
                                    color: Colors.grey)),
                          ),
                          ...widget.availableEcFiles.map(
                            (f) => DropdownMenuItem<String?>(
                              value: f,
                              child: Text(f,
                                  overflow: TextOverflow.ellipsis, maxLines: 1),
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => tempEcFile = v),
                      ),
                      if (tempEcFile != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4.0),
                          child: Text(
                            'Gewählt: $tempEcFile',
                            style: TextStyle(
                                fontSize: 11, color: Colors.green.shade700),
                          ),
                        ),
                    ],
                  ),
              ], // end if oneTimePad

              // --------------------------------------------------------------------
              // RSA-Schl�sselaustausch-Sektion (nur bei Hybrid)
              // --------------------------------------------------------------------
              if (tempEncryptionType == qgap_model.EncryptionType.hybrid) ...[
                const SizedBox(height: 20),
                const Divider(),
                const SizedBox(height: 10),
                const Text(
                  'RSA-Schl�sselaustausch:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),

                // Status: Kontakt-Schl�ssel
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: tempContactKeyFingerprint != null
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: tempContactKeyFingerprint != null
                          ? Colors.green.shade300
                          : Colors.orange.shade300,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        tempContactKeyFingerprint != null
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        color: tempContactKeyFingerprint != null
                            ? Colors.green.shade700
                            : Colors.orange.shade700,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: tempContactKeyFingerprint != null
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '�ffentlicher Schl�ssel gespeichert',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.green.shade800,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Fingerprint: $tempContactKeyFingerprint',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.green.shade700,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                'Kein �ffentlicher Schl�ssel des Kontakts gespeichert.\n'
                                'Schl�ssel des Gegen�bers scannen, um Nachrichten senden zu k�nnen.',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange.shade800,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Schl�ssel des Kontakts scannen
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: _scanningPublicKey
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.qr_code_scanner),
                    label: const Text('Schl�ssel des Kontakts scannen'),
                    onPressed: _scanningPublicKey
                        ? null
                        : () async {
                            setState(() => _scanningPublicKey = true);
                            try {
                              final fp = await widget.onScanContactPublicKey();
                              if (fp != null) {
                                setState(() => tempContactKeyFingerprint = fp);
                              }
                            } finally {
                              if (mounted) {
                                setState(() => _scanningPublicKey = false);
                              }
                            }
                          },
                  ),
                ),
                const SizedBox(height: 8),

                // Eigenen Schl�ssel als QR anzeigen
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Meinen Schl�ssel als QR anzeigen'),
                    onPressed: widget.onShowMyPublicKey,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Der Gegen�ber scannt diesen QR-Code, um dir verschl�sselte Nachrichten senden zu k�nnen.',
                  style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic),
                ),
              ], // end if hybrid
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Abbrechen'),
        ),
        TextButton(
          onPressed: () async {
            // Byte-Offset validieren
            int? newOffset = int.tryParse(offsetController.text.trim());
            if (newOffset == null || newOffset < 0) {
              // Ungültiger Byte-Offset
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('❌ Ungültiger Byte-Offset'),
                    content: Text(
                        'Der eingegebene Wert "${offsetController.text}" ist kein gültiger Byte-Offset.\n\n'
                        'Bitte geben Sie eine positive Zahl oder 0 ein.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  );
                },
              );
              return;
            }

            // Prüfe ob der Offset die Dateigröße überschreitet
            int fileSize = widget.getKeyFileSize(tempSelectedFile);
            int maxAllowedOffset = fileSize - 100; // 100 Bytes Reserve

            if (fileSize > 0 && newOffset > maxAllowedOffset) {
              showDialog(
                context: context,
                builder: (BuildContext context) {
                  return AlertDialog(
                    title: const Text('❌ Byte-Offset zu groß'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            'Der eingegebene Byte-Offset ist zu groß für die gewählte Datei:'),
                        const SizedBox(height: 8),
                        Text('• Eingabe: $newOffset Bytes'),
                        Text('• Dateigröße: $fileSize Bytes'),
                        Text(
                            '• Maximum erlaubt: $maxAllowedOffset Bytes (Dateigröße - 100)'),
                        const SizedBox(height: 8),
                        const Text('Bitte wählen Sie einen kleineren Wert.'),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          offsetController.text = maxAllowedOffset.toString();
                        },
                        child: const Text('Maximum setzen'),
                      ),
                    ],
                  );
                },
              );
              return;
            }

            // Speichern � bei Hybrid/RSA keine EC-Datei �bergeben
            final ecFileForSave =
                tempEncryptionType == qgap_model.EncryptionType.oneTimePad
                    ? tempEcFile
                    : null;
            await widget.onSave(tempSelectedFile, newOffset, tempEncryptionType,
                ecFileForSave, tempEcUsbOnly);
          },
          child: const Text('OK'),
        ),
      ],
    );
  }
}
