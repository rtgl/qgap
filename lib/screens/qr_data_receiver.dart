// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qgap/theme/app_theme.dart';

/// Internes Datenmodell fuer ein empfangenes Fountain-Code-Paket.
class _FountainPacket {
  List<int> blockIndices; // Mutable: bekannte Bloecke werden herausgepelt
  Uint8List data;         // XOR-Daten (immer blockSize lang)
  _FountainPacket(this.blockIndices, this.data);
}

/// Empfaengt LT-Fountain-Code QR-Pakete (Binaerprotokoll) und rekonstruiert die Originaldaten.
///
/// Binaeres Protokoll (Byte-Modus, kein Base64):
/// [0]       0x46 'F'        – Marker
/// [1..4]    seq (uint32 BE) – Sequenznummer
/// [5..6]    k   (uint16 BE) – Anzahl Quell-Bloecke
/// [7..12]   id  (6 Bytes)   – Uebertragungs-ID (ASCII)
/// [13..15]  chk (3 Bytes)   – SHA-256[0..2] der XOR-Daten
/// [16]      deg (uint8)     – Grad (Anzahl XOR-kombinierter Bloecke)
/// [17..17+2*deg-1] Indizes  – uint16 BE je Index
/// [17+2*deg..]     XOR-Daten – blockSize Bytes
///
/// Nutzt einen Peeling-Decoder (Glaubenspropagation):
///  1. Grad-1-Pakete werden sofort als Quell-Block dekodiert.
///  2. Dieser Block wird aus allen anderen gespeicherten Paketen herausgexort.
///  3. Dadurch entstehen neue Grad-1-Pakete -> Wiederholung.
class QrDataReceiver extends StatefulWidget {
  const QrDataReceiver({super.key});

  @override
  State<QrDataReceiver> createState() => _QrDataReceiverState();
}

class _QrDataReceiverState extends State<QrDataReceiver> {
  /// Noch nicht vollstaendig aufgeloeste Pakete (Grad >= 2).
  final List<_FountainPacket> _pending = [];

  /// Bereits dekodierte Quell-Bloecke: index -> Daten.
  final Map<int, Uint8List> _decoded = {};

  String? _currentId;
  int _k = 0;           // Anzahl Quell-Bloecke
  int _blockSize = 0;   // Bytes pro Block (aus erstem Paket inferiert)
  bool _completed = false;
  int _seenPackets = 0; // Gesamt empfangene Pakete (inkl. Duplikate)

  final ValueNotifier<double> _progressNotifier = ValueNotifier(0.0);
  final MobileScannerController _scannerController = MobileScannerController();

  @override
  void dispose() {
    if (_cameraScanSupported) _scannerController.dispose();
    _progressNotifier.dispose();
    super.dispose();
  }

  // ─── Protokoll ────────────────────────────────────────────────────────────

  /// ECC-Level-Bezeichnung aus der Block-Groesse ableiten.
  String get _inferredEccLabel {
    if (_blockSize == 0) return '–';
    if (_blockSize >= 550) return 'L – 7 % (max. Kapazitaet)';
    if (_blockSize >= 280) return 'M – 15 % (Sweet Spot)';
    return 'H – 30 % (max. robust)';
  }

  void _onDetect(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      // Binaerprotokoll: rawBytes verwenden (kein Base64-Overhead)
      final raw = barcode.rawBytes;
      if (raw != null && raw.isNotEmpty && raw[0] == 0x46) {
        _processPacket(raw);
        continue;
      }
      // Statischer Einzel-QR (z. B. Admin-Kopplung der Präsentation,
      // Chat-Einladung, Pairing-JSON): direkt als UTF-8-Bytes zurückgeben.
      // Nur solange keine Fountain-Übertragung läuft, damit ein zufällig
      // gescannter Fremd-QR keinen laufenden Empfang abbricht.
      if (_seenPackets == 0) {
        final text = barcode.rawValue;
        if (text != null && text.isNotEmpty) {
          _completed = true;
          _scannerController.stop();
          if (mounted) {
            Navigator.of(context).pop(Uint8List.fromList(utf8.encode(text)));
          }
          return;
        }
      }
    }
  }

  void _processPacket(Uint8List raw) {
    // Mindestgroesse: 1 Marker + 4 seq + 2 k + 6 id + 3 chk + 1 deg + 2 idx + 1 data
    if (raw.length < 20) { return; }
    if (raw[0] != 0x46) { return; } // Marker 'F'

    final k = (raw[5] << 8) | raw[6];
    if (k <= 0 || k > 65535) { return; }

    final id = String.fromCharCodes(raw.sublist(7, 13));
    final degree = raw[16];
    if (degree == 0 || degree > k || degree > 255) { return; }

    final headerSize = 17 + 2 * degree;
    if (raw.length <= headerSize) { return; }

    // Indizes lesen
    final indices = <int>[];
    for (int i = 0; i < degree; i++) {
      final idx = (raw[17 + i * 2] << 8) | raw[18 + i * 2];
      if (idx >= k) { return; } // ungueltig
      indices.add(idx);
    }

    // XOR-Daten extrahieren
    final data = Uint8List.fromList(raw.sublist(headerSize));

    // 3-Byte-Pruefsumme validieren
    final expectedChk = sha256.convert(data).bytes;
    if (raw[13] != expectedChk[0] ||
        raw[14] != expectedChk[1] ||
        raw[15] != expectedChk[2]) { return; }

    // Neue Uebertragungs-ID -> Puffer zuruecksetzen
    if (_currentId != null && _currentId != id) { _fullReset(); }
    _currentId = id;
    _k = k;

    // Blockgroesse aus erstem validen Paket bestimmen
    if (_blockSize == 0) { _blockSize = data.length; }
    if (data.length != _blockSize) { return; } // inkonsistentes Paket

    _seenPackets++;

    // Paket sofort mit bekannten Bloecken reduzieren
    final pkt = _FountainPacket(List<int>.from(indices), data);
    _reduce(pkt);

    if (pkt.blockIndices.isEmpty) {
      // Vollstaendig aufgeloest (Duplikat), verwerfen
    } else if (pkt.blockIndices.length == 1) {
      _decodeBlock(pkt.blockIndices[0], pkt.data);
      _peelingLoop();
    } else {
      _pending.add(pkt);
    }

    _updateProgress();
    if (_decoded.length == _k && !_completed) {
      _reconstruct();
    }
  }

  /// Zieht alle bereits bekannten Bloecke aus einem Paket heraus (XOR).
  void _reduce(_FountainPacket pkt) {
    for (final idx in List<int>.from(pkt.blockIndices)) {
      if (_decoded.containsKey(idx)) {
        pkt.blockIndices.remove(idx);
        final known = _decoded[idx]!;
        for (int b = 0; b < pkt.data.length; b++) {
          pkt.data[b] ^= known[b];
        }
      }
    }
  }

  void _decodeBlock(int index, Uint8List data) {
    if (_decoded.containsKey(index)) { return; }
    _decoded[index] = Uint8List.fromList(data);
  }

  /// Peeling-Schleife: wiederholt bis keine neuen Bloecke mehr gefunden werden.
  void _peelingLoop() {
    bool progress = true;
    while (progress) {
      progress = false;
      for (int i = _pending.length - 1; i >= 0; i--) {
        final pkt = _pending[i];

        // Bekannte Bloecke herausrechnen
        for (final idx in List<int>.from(pkt.blockIndices)) {
          if (_decoded.containsKey(idx)) {
            pkt.blockIndices.remove(idx);
            final known = _decoded[idx]!;
            for (int b = 0; b < pkt.data.length; b++) {
              pkt.data[b] ^= known[b];
            }
            progress = true;
          }
        }

        if (pkt.blockIndices.length == 1) {
          _decodeBlock(pkt.blockIndices[0], pkt.data);
          _pending.removeAt(i);
          progress = true;
        } else if (pkt.blockIndices.isEmpty) {
          _pending.removeAt(i);
        }
      }
    }
  }

  void _updateProgress() {
    _progressNotifier.value = _k > 0 ? _decoded.length / _k : 0;
    setState(() {});
  }

  // ─── Rekonstruktion ────────────────────────────────────────────────────────

  void _reconstruct() {
    _completed = true;
    _scannerController.stop();

    try {
      // Bloecke in Reihenfolge zusammenfuegen
      final buffer = <int>[];
      for (int i = 0; i < _k; i++) {
        buffer.addAll(_decoded[i]!);
      }
      // GZip dekomprimieren (ignoriert automatisch Null-Padding des letzten Blocks)
      final decompressed = GZipDecoder().decodeBytes(buffer);
      // Rohe Bytes zurueckgeben — der Aufrufer entscheidet das Format
      final result = Uint8List.fromList(decompressed);

      if (mounted) {
        // Ergebnis an den Aufrufer zurueckgeben (z.B. Chat-Screen)
        Navigator.of(context).pop(result);
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Dekodieren: $e')),
        );
      }
      _reset();
    }
  }

  // ─── Reset ────────────────────────────────────────────────────────────────

  void _fullReset() {
    _pending.clear();
    _decoded.clear();
    _currentId = null;
    _k = 0;
    _blockSize = 0;
    _completed = false;
    _seenPackets = 0;
    _progressNotifier.value = 0.0;
  }

  void _reset() {
    setState(() => _fullReset());
    _scannerController.start();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  /// Kamera-QR-Scan wird von mobile_scanner auf Windows/Linux nicht unterstützt.
  static bool get _cameraScanSupported =>
      !Platform.isWindows && !Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    if (!_cameraScanSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('QR-Daten empfangen')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.no_photography_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'QR-Scannen per Kamera wird auf dieser Plattform nicht unterstützt.\n\n'
                  'Bitte die Daten stattdessen als Datei importieren\n'
                  '(z. B. .qgap / .qgap_ec über den Datei-Dialog).',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('QR-Daten empfangen'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _reset,
            tooltip: 'Neu starten',
          ),
        ],
      ),
      body: Column(
        children: [
          // Kamera-Vorschau
          Expanded(
            flex: 3,
            child: MobileScanner(
              controller: _scannerController,
              onDetect: _onDetect,
            ),
          ),

          // Fortschritts-Panel
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: ValueListenableBuilder<double>(
                valueListenable: _progressNotifier,
                builder: (context, progress, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Linearer Fortschrittsbalken
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 14,
                          backgroundColor: Colors.grey.shade200,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            progress >= 1.0 ? Colors.green : Colors.blue,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),

                      // Prozent + Blockzaehler
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${(progress * 100).round()} %',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18),
                          ),
                          Text(
                            _k > 0
                                ? '${_decoded.length} / $_k Bloecke'
                                : 'Warte auf QR-Code…',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Kreisfortschritt + Stats nebeneinander
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 70,
                            height: 70,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 7,
                                  backgroundColor: Colors.grey.shade200,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    progress >= 1.0
                                        ? Colors.green
                                        : Colors.blue,
                                  ),
                                ),
                                Center(
                                  child: Text(
                                    '${(progress * 100).round()}%',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Stats-Box (wie beim Sender)
                          Expanded(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.blue.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.blue.shade200),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _k > 0
                                        ? '$_seenPackets Pkt. empf.  |  ${_pending.length} ausstehend'
                                        : 'Noch kein Paket empfangen',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.blue.shade800),
                                  ),
                                  if (_currentId != null)
                                    Text(
                                      'ID: $_currentId',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.blue.shade800),
                                    ),
                                  if (_blockSize > 0)
                                    Text(
                                      'ECC: $_inferredEccLabel  |  $_blockSize B/Block',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.blue.shade800),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),

                      // Block-Grid (gruen = dekodiert, grau = ausstehend)
                      if (_k > 0)
                        Wrap(
                          spacing: 3,
                          runSpacing: 3,
                          children: List.generate(_k, (i) {
                            final done = _decoded.containsKey(i);
                            return Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                color: done
                                    ? Colors.green
                                    : Colors.grey.shade300,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Center(
                                child: Text(
                                  '$i',
                                  style: TextStyle(
                                    fontSize: 8,
                                    color: done
                                        ? Colors.white
                                        : Colors.grey.shade600,
                                  ),
                                ),
                              ),
                            );
                          }),
                        ),

                      const SizedBox(height: 6),
                      // Info-Box (wie beim Sender)
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.amber.shade300),
                        ),
                        child: const Text(
                          'Fountain-Code: Beliebige ~80 % der gesendeten Pakete '
                          'genuegen zur vollstaendigen Rekonstruktion. '
                          'Binaer-Protokoll (kein Base64) spart 33 % Platz.',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
