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

// ─────────────────────────────────────────────────────────────────────────────
// Ergebnis-Typ des Universal-Scanners
// ─────────────────────────────────────────────────────────────────────────────

/// Ergebnis des [QRScannerDialog].
///
/// • [ScanResultText]   – normaler Einzelcode (String)
/// • [ScanResultBytes]  – Fountain-Code-Übertragung (Uint8List, mehrere Frames)
sealed class ScanResult {
  const ScanResult();
}

/// Normaler statischer QR-Code → Inhalt als String.
class ScanResultText extends ScanResult {
  final String text;
  const ScanResultText(this.text);
}

/// Fountain-Code-Übertragung → rekonstruierte Binärdaten.
class ScanResultBytes extends ScanResult {
  final Uint8List bytes;
  const ScanResultBytes(this.bytes);
}

// ─────────────────────────────────────────────────────────────────────────────
// Internes Datenmodell (Fountain-Code)
// ─────────────────────────────────────────────────────────────────────────────

class _FountainPacket {
  List<int> blockIndices;
  Uint8List data;
  _FountainPacket(this.blockIndices, this.data);
}

// ─────────────────────────────────────────────────────────────────────────────
// Universal-Scanner
// ─────────────────────────────────────────────────────────────────────────────

/// Universal-QR-Scanner.
///
/// Gibt [ScanResultText] zurück wenn ein normaler QR-Code erkannt wird,
/// oder [ScanResultBytes] wenn Fountain-Code-Pakete (Marker 0x46) erkannt werden.
class QRScannerDialog extends StatefulWidget {
  const QRScannerDialog({super.key});

  @override
  State<QRScannerDialog> createState() => _QRScannerDialogState();
}

class _QRScannerDialogState extends State<QRScannerDialog> {
  final MobileScannerController _controller = MobileScannerController(
    // Nur QR-Codes scannen – verhindert, dass EAN/ISBN-Barcodes auf dem
    // gleichen Produkt zuerst erkannt werden (z. B. EAN-13 statt GS1-Link-QR).
    formats: [BarcodeFormat.qrCode],
    // Verbesserte Erkennung für hochdichte QR-Codes:
    detectionSpeed: DetectionSpeed.noDuplicates,
    detectionTimeoutMs: 1000,
    // Automatisch höchste verfügbare Auflösung verwenden
    returnImage: false,
  );

  // ── Modus ──────────────────────────────────────────────────────────────────
  /// null = noch nicht bestimmt, 'text' = normaler QR, 'fountain' = Fountain-Code
  String? _mode;

  // ── Text-Modus ─────────────────────────────────────────────────────────────
  String? _scannedText;

  // ── Fountain-Modus ─────────────────────────────────────────────────────────
  final List<_FountainPacket> _pending = [];
  final Map<int, Uint8List> _decoded = {};
  String? _currentId;
  int _k = 0;
  int _blockSize = 0;
  bool _completed = false;
  int _seenPackets = 0;
  final ValueNotifier<double> _progressNotifier = ValueNotifier(0.0);

  @override
  void dispose() {
    if (_cameraScanSupported) _controller.dispose();
    _progressNotifier.dispose();
    super.dispose();
  }

  // ─── Erkennung ─────────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    if (_completed) return;

    // Debug: Log jede Erkennung
    print('🔍 Scanner onDetect: ${capture.barcodes.length} Barcodes');

    for (final barcode in capture.barcodes) {
      print('🔍 Barcode erkannt:');
      print('   - Format: ${barcode.format}');
      print('   - RawValue: ${barcode.rawValue?.substring(0, barcode.rawValue!.length > 50 ? 50 : barcode.rawValue!.length)}...');
      print('   - RawBytes: ${barcode.rawBytes?.length} bytes');
      if (barcode.rawBytes != null && barcode.rawBytes!.isNotEmpty) {
        print('   - Erste Bytes: ${barcode.rawBytes!.take(10).toList()}');
      }

      // Fountain-Code-Pakete kommen als Binär (rawBytes)
      final raw = barcode.rawBytes;
      if (raw != null && raw.isNotEmpty && raw[0] == 0x46) {
        print('✅ Fountain-Code erkannt!');
        if (_mode == null) {
          // Ersten Fountain-Frame erkannt → in Fountain-Modus wechseln
          setState(() => _mode = 'fountain');
        }
        if (_mode == 'fountain') {
          _processFountainPacket(raw);
        }
        return;
      }

      // Normaler String-QR-Code oder Binär-QR-Code
      if (_mode == null || _mode == 'text') {
        String? text = barcode.rawValue;
        
        // Wenn rawValue null ist: Binäre Daten → als Base64 mit Marker speichern
        // Das verhindert Korruption beim JSON-Speichern
        if (text == null && raw != null && raw.isNotEmpty) {
          text = 'BIN:${base64Encode(raw)}';
          print('🔧 Binärer QR-Code erkannt: ${raw.length} bytes → Base64 (${text.length} chars)');
        }
        
        print('📝 QR-Code: ${text?.length} Zeichen');
        if (text != null && text.isNotEmpty && _scannedText == null) {
          print('✅ QR-Code wird akzeptiert!');
          setState(() {
            _mode = 'text';
            _scannedText = text!;
          });
          // Kurze Bestätigungspause, dann zurückgeben
          Future.delayed(const Duration(milliseconds: 800), () {
            if (mounted) Navigator.of(context).pop(ScanResultText(text!));
          });
        } else {
          print('❌ QR-Code wird NICHT akzeptiert (text=${text?.isNotEmpty}, scannedText=$_scannedText)');
        }
      }
    }
  }

  // ─── Fountain-Code-Logik ──────────────────────────────────────────────────

  void _processFountainPacket(Uint8List raw) {
    if (raw.length < 20) return;
    if (raw[0] != 0x46) return;

    final k = (raw[5] << 8) | raw[6];
    if (k <= 0 || k > 65535) return;

    final id = String.fromCharCodes(raw.sublist(7, 13));
    final degree = raw[16];
    if (degree == 0 || degree > k || degree > 255) return;

    final headerSize = 17 + 2 * degree;
    if (raw.length <= headerSize) return;

    final indices = <int>[];
    for (int i = 0; i < degree; i++) {
      final idx = (raw[17 + i * 2] << 8) | raw[18 + i * 2];
      if (idx >= k) return;
      indices.add(idx);
    }

    final data = Uint8List.fromList(raw.sublist(headerSize));

    // Prüfsumme validieren
    final expectedChk = sha256.convert(data).bytes;
    if (raw[13] != expectedChk[0] ||
        raw[14] != expectedChk[1] ||
        raw[15] != expectedChk[2]) { return; }

    // Neue Übertragungs-ID → Reset
    if (_currentId != null && _currentId != id) { _fullReset(); }
    _currentId = id;
    _k = k;
    if (_blockSize == 0) { _blockSize = data.length; }
    if (data.length != _blockSize) return;

    _seenPackets++;

    final pkt = _FountainPacket(List<int>.from(indices), data);
    _reduce(pkt);

    if (pkt.blockIndices.isEmpty) {
      // Duplikat, verwerfen
    } else if (pkt.blockIndices.length == 1) {
      _decodeBlock(pkt.blockIndices[0], pkt.data);
      _peelingLoop();
    } else {
      _pending.add(pkt);
    }

    _progressNotifier.value = _k > 0 ? _decoded.length / _k : 0;
    setState(() {});

    if (_decoded.length == _k && !_completed) _reconstruct();
  }

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
    if (_decoded.containsKey(index)) return;
    _decoded[index] = Uint8List.fromList(data);
  }

  void _peelingLoop() {
    bool progress = true;
    while (progress) {
      progress = false;
      for (int i = _pending.length - 1; i >= 0; i--) {
        final pkt = _pending[i];
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

  void _reconstruct() {
    _completed = true;
    _controller.stop();
    try {
      final buffer = <int>[];
      for (int i = 0; i < _k; i++) {
        buffer.addAll(_decoded[i]!);
      }
      final decompressed = GZipDecoder().decodeBytes(buffer);
      final result = Uint8List.fromList(decompressed);
      if (mounted) Navigator.of(context).pop(ScanResultBytes(result));
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Dekodieren: $e')),
        );
        _fullReset();
        _controller.start();
      }
    }
  }

  void _fullReset() {
    _pending.clear();
    _decoded.clear();
    _currentId = null;
    _k = 0;
    _blockSize = 0;
    _completed = false;
    _seenPackets = 0;
    _scannedText = null;
    _mode = null;
    _progressNotifier.value = 0.0;
  }

  void _reset() {
    setState(() => _fullReset());
    _controller.start();
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  /// Kamera-QR-Scan wird von mobile_scanner auf Windows/Linux nicht unterstützt.
  static bool get _cameraScanSupported =>
      !Platform.isWindows && !Platform.isLinux;

  @override
  Widget build(BuildContext context) {
    if (!_cameraScanSupported) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: const Text('QR-Code scannen',
              style: TextStyle(color: Colors.white)),
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'QR-Scannen per Kamera wird auf dieser Plattform nicht unterstützt.\n\n'
              'Bitte die Daten stattdessen als Datei importieren\n'
              '(z. B. .qgap / .qgap_ec über den Datei-Dialog).',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _mode == 'fountain'
              ? 'Fountain-Code empfangen…'
              : 'QR-Code scannen',
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (_mode == 'fountain')
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              tooltip: 'Neu starten',
              onPressed: _reset,
            ),
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () async => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
            onPressed: () async => _controller.switchCamera(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Kamera-Vorschau
          Expanded(
            flex: _mode == 'fountain' ? 3 : 4,
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
            ),
          ),

          // Info-/Fortschritts-Panel
          Expanded(
            flex: _mode == 'fountain' ? 2 : 1,
            child: _mode == 'fountain'
                ? _buildFountainPanel()
                : _buildTextPanel(),
          ),
        ],
      ),
    );
  }

  // ── Text-Modus Panel ───────────────────────────────────────────────────────

  Widget _buildTextPanel() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _scannedText != null
                ? '✅ QR-Code erkannt!'
                : 'Kamera auf QR-Code richten\n'
                    '(Einzel-QR oder Fountain-Code wird automatisch erkannt)',
            style: const TextStyle(color: Colors.white, fontSize: 15),
            textAlign: TextAlign.center,
          ),
          if (_scannedText == null) ...[
            const SizedBox(height: 8),
            Text(
              '💡 Tipp: Bei dichten QR-Codes Gerät ruhig halten\n'
              'und Abstand variieren für beste Schärfe',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
          if (_scannedText != null) ...[
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).pop(ScanResultText(_scannedText!)),
              child: const Text('Verwenden'),
            ),
          ],
        ],
      ),
    );
  }

  // ── Fountain-Modus Panel ──────────────────────────────────────────────────

  Widget _buildFountainPanel() {
    return ValueListenableBuilder<double>(
      valueListenable: _progressNotifier,
      builder: (context, progress, _) {
        return Container(
          color: Colors.grey.shade900,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Fortschrittsbalken
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 14,
                  backgroundColor: Colors.grey.shade700,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    progress >= 1.0 ? Colors.green : Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${(progress * 100).round()} %',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18),
                  ),
                  Text(
                    _k > 0
                        ? '${_decoded.length} / $_k Blöcke'
                        : 'Warte auf Fountain-Pakete…',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _k > 0
                    ? '$_seenPackets Pakete empf.  |  ${_pending.length} ausstehend'
                        '${_currentId != null ? "  |  ID: $_currentId" : ""}'
                    : 'Fountain-Code erkannt – weiter scannen…',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }
}
