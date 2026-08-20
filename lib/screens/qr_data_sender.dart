// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top-level Funktion für compute() – GZip-Komprimierung im Isolate.
Uint8List _gzipCompress(Uint8List input) {
  final compressed = GZipEncoder().encode(input);
  return compressed != null ? Uint8List.fromList(compressed) : input;
}

/// LT-Fountain-Code Sender – Binaerprotokoll (kein Base64, +33 % Effizienz).
///
/// Statt sequenzieller Pakete wird kontinuierlich eine zufaellige XOR-Kombination
/// von Quell-Bloecken gesendet (Luby Transform Code). Der Empfaenger braucht nur
/// ca. k*1.1 beliebige Pakete, unabhaengig von der Reihenfolge.
///
/// Binaeres Protokoll pro QR-Code (Byte-Modus, kein Base64):
/// [0]       0x46 'F'        – Marker
/// [1..4]    seq (uint32 BE) – Sequenznummer
/// [5..6]    k   (uint16 BE) – Anzahl Quell-Bloecke
/// [7..12]   id  (6 Bytes)   – Uebertragungs-ID (ASCII)
/// [13..15]  chk (3 Bytes)   – SHA-256[0..2] der XOR-Daten
/// [16]      deg (uint8)     – Grad (Anzahl XOR-kombinierter Bloecke)
/// [17..17+2*deg-1] Indizes  – uint16 BE je Index
/// [17+2*deg..]     XOR-Daten – blockSize Bytes (alle Bloecke gleich gross)
class QrDataSender extends StatefulWidget {
  final Uint8List bytes;
  const QrDataSender({super.key, required this.bytes});

  @override
  State<QrDataSender> createState() => _QrDataSenderState();
}

class _QrDataSenderState extends State<QrDataSender> {
  /// Nutzdaten-Bytes pro Quell-Block je ECC-Level.
  /// Gegenueber dem alten Base64-Protokoll 33 % groesser, da kein Kodierungsoverhead.
  static const Map<int, int> _blockSizes = {
    QrErrorCorrectLevel.L: 640,
    QrErrorCorrectLevel.M: 400,
    QrErrorCorrectLevel.H: 200,
  };

  int _eccLevel = QrErrorCorrectLevel.M;
  int _intervalMs = 650;

  late List<Uint8List> _sourceBlocks;
  late String _id;
  late int _k;
  late int _blockSize;

  QrCode? _currentQr;
  int _seqNum = 0;
  Timer? _timer;
  bool _isGenerating = false;
  bool _isLoading = true; // true während GZip im Isolate läuft
  bool _singlePage = false; // true wenn k==1 (ein QR genügt)

  final Random _rng = Random();
  final Random _secureRng = Random.secure();

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// Lädt gespeicherte Einstellungen und bereitet dann die Daten vor.
  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _eccLevel = prefs.getInt('qr_sender_ecc_level') ?? QrErrorCorrectLevel.M;
        _intervalMs = prefs.getInt('qr_sender_interval_ms') ?? 650;
      });
    }
    await _prepareAsync();
  }

  /// Startet GZip-Komprimierung im Hintergrund-Isolate, dann Timer.
  Future<void> _prepareAsync() async {
    final compressed = await compute(_gzipCompress, widget.bytes);
    if (!mounted) return;
    _prepareWithCompressed(compressed);
    if (mounted) {
      setState(() {
        _isLoading = false;
        _singlePage = _k == 1;
      });
      if (!_singlePage) _startTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _generateId() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(6, (_) => chars[_secureRng.nextInt(chars.length)])
        .join();
  }

  int _sampleDegree() {
    if (_k == 1) return 1;
    final r = _rng.nextDouble();
    if (r < 0.50) return 1;
    if (r < 0.80) return min(2, _k);
    if (r < 0.95) return min(3, _k);
    return min(4, _k);
  }

  /// Bereitet Quell-Blöcke aus bereits komprimierten Daten vor (synchron, schnell).
  void _prepareWithCompressed(Uint8List compressed) {
    _id = _generateId();
    _blockSize = _blockSizes[_eccLevel]!;

    _sourceBlocks = [];
    for (int i = 0; i < compressed.length; i += _blockSize) {
      final end = min(i + _blockSize, compressed.length);
      final block = Uint8List(_blockSize);
      block.setAll(0, compressed.sublist(i, end));
      _sourceBlocks.add(block);
    }
    _k = _sourceBlocks.length;
    _seqNum = 0;
    _currentQr = _generateQr();
  }

  // Legacy-Wrapper (wird nur noch beim ECC-Level-Wechsel genutzt – dort sind
  // die Daten bereits als _sourceBlocks vorhanden, also nur Block-Größe neu berechnen).
  void _rebuildBlocks() {
    if (_sourceBlocks.isEmpty) return;
    // Komprimierte Daten aus Source-Blöcken zusammensetzen (war schon komprimiert)
    final allData = Uint8List(_sourceBlocks.length * _blockSize);
    for (int i = 0; i < _sourceBlocks.length; i++) {
      allData.setAll(i * _blockSize, _sourceBlocks[i]);
    }
    _blockSize = _blockSizes[_eccLevel]!;
    _sourceBlocks = [];
    for (int i = 0; i < allData.length; i += _blockSize) {
      final end = min(i + _blockSize, allData.length);
      final block = Uint8List(_blockSize);
      block.setAll(0, allData.sublist(i, end));
      _sourceBlocks.add(block);
    }
    _k = _sourceBlocks.length;
    _seqNum = 0;
    _currentQr = _generateQr();
  }

  /// Erstellt ein binaeres Fountain-Code-Paket und verpackt es als QrCode.
  QrCode? _generateQr() {
    final degree = _sampleDegree();

    final indexSet = <int>{};
    while (indexSet.length < degree) {
      indexSet.add(_rng.nextInt(_k));
    }
    final indices = indexSet.toList()..sort();

    final xorData = Uint8List(_blockSize);
    for (final idx in indices) {
      for (int b = 0; b < _blockSize; b++) {
        xorData[b] ^= _sourceBlocks[idx][b];
      }
    }

    // 3-Byte-Pruefsumme (erste 3 Bytes des SHA-256)
    final chkBytes = sha256.convert(xorData).bytes;

    // Binaeres Paket aufbauen
    final headerSize = 17 + 2 * degree;
    final packet = Uint8List(headerSize + _blockSize);
    packet[0] = 0x46; // 'F'
    packet[1] = (_seqNum >> 24) & 0xFF;
    packet[2] = (_seqNum >> 16) & 0xFF;
    packet[3] = (_seqNum >> 8) & 0xFF;
    packet[4] = _seqNum & 0xFF;
    packet[5] = (_k >> 8) & 0xFF;
    packet[6] = _k & 0xFF;
    for (int i = 0; i < 6; i++) { packet[7 + i] = _id.codeUnitAt(i); }
    packet[13] = chkBytes[0];
    packet[14] = chkBytes[1];
    packet[15] = chkBytes[2];
    packet[16] = degree;
    for (int i = 0; i < degree; i++) {
      packet[17 + i * 2] = (indices[i] >> 8) & 0xFF;
      packet[18 + i * 2] = indices[i] & 0xFF;
    }
    packet.setAll(headerSize, xorData);

    try {
      return QrCode.fromUint8List(
        data: packet,
        errorCorrectLevel: _eccLevel,
      );
    } catch (_) {
      return null; // Daten zu gross fuer QR (sollte nicht vorkommen)
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) {
      if (!mounted || _k == 0) return;
      if (_isGenerating) return;
      _isGenerating = true;
      _seqNum++;
      final nextQr = _generateQr();
      if (mounted) {
        setState(() => _currentQr = nextQr);
      }
      _isGenerating = false;
    });
  }

  void _onEccChanged(int level) {
    setState(() => _eccLevel = level);
    SharedPreferences.getInstance()
        .then((p) => p.setInt('qr_sender_ecc_level', level));
    _rebuildBlocks();
    _singlePage = _k == 1;
    if (!_singlePage) {
      _startTimer();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _onSliderChanged(double value) {
    setState(() => _intervalMs = value.round());
    SharedPreferences.getInstance()
        .then((p) => p.setInt('qr_sender_interval_ms', value.round()));
    _startTimer();
  }

  String get _eccLabel {
    switch (_eccLevel) {
      case QrErrorCorrectLevel.L:
        return 'L 7%  (maximale Kapazitaet, weniger robust)';
      case QrErrorCorrectLevel.M:
        return 'M 15%  (Sweet Spot fuer Display-Scans)';
      case QrErrorCorrectLevel.H:
        return 'H 30%  (maximal robust, kleinere Bloecke)';
      default:
        return '';
    }
  }

  String get _statText {
    final dataBytes = widget.bytes.length;
    final minPackets = (_k * 1.15).ceil();
    return '$_k Bloecke x $_blockSize B  |  $dataBytes B Eingabe (GZip-komprimiert)\n'
        'Empfaenger braucht mind. ~$minPackets beliebige Pakete\n'
        'Binaer-Protokoll: kein Base64-Overhead (+33 % Effizienz)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR-Daten senden')),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Daten werden vorbereitet…'),
                ],
              ),
            )
          : SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: _currentQr != null
                  ? Builder(
                      builder: (ctx) {
                        try {
                          return QrImageView.withQr(
                            qr: _currentQr!,
                            size: 300,
                            backgroundColor: Colors.white,
                            errorStateBuilder: (c, e) => SizedBox(
                              width: 300,
                              height: 300,
                              child: Center(
                                child: Text(
                                  'Fehler beim Rendern:\n$e',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ),
                            ),
                          );
                        } catch (e) {
                          return SizedBox(
                            width: 300,
                            height: 300,
                            child: Center(
                              child: Text(
                                'Fehler beim Rendern:\n$e',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          );
                        }
                      },
                    )
                  : const SizedBox(
                      width: 300,
                      height: 300,
                      child: Center(child: Text('Fehler: Daten zu gross fuer QR')),
                    ),
            ),
            const SizedBox(height: 12),
            if (_singlePage)
              Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          color: Colors.green, size: 20),
                      SizedBox(width: 8),
                      Text(
                        '✅ Ein Scan genügt',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.green),
                      ),
                    ],
                  ),
                ),
              )
            else
              Center(
                child: Text(
                  'Paket #$_seqNum',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            Center(
              child: Text(
                'ID: $_id',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Text(
                _statText,
                style:
                    TextStyle(fontSize: 12, color: Colors.blue.shade800),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 18),

            const Text(
              'Fehlerkorrektur-Level (ECC):',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: QrErrorCorrectLevel.L,
                  label: Text('L'),
                  icon: Icon(Icons.storage),
                ),
                ButtonSegment(
                  value: QrErrorCorrectLevel.M,
                  label: Text('M'),
                  icon: Icon(Icons.balance),
                ),
                ButtonSegment(
                  value: QrErrorCorrectLevel.H,
                  label: Text('H'),
                  icon: Icon(Icons.shield),
                ),
              ],
              selected: {_eccLevel},
              onSelectionChanged: (s) => _onEccChanged(s.first),
            ),
            const SizedBox(height: 4),
            Text(
              _eccLabel,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),

            if (!_singlePage) ...[
            Text(
              'Bildrate: $_intervalMs ms / Bild',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Row(
              children: [
                const Text('100ms', style: TextStyle(fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: _intervalMs.toDouble(),
                    min: 100,
                    max: 1500,
                    divisions: 28,
                    label: '$_intervalMs ms',
                    onChanged: _onSliderChanged,
                  ),
                ),
                const Text('1.5s', style: TextStyle(fontSize: 11)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: const Text(
                'Fountain-Code: Jedes Bild enthaelt eine neue Zufallsmischung '
                'der Daten (Luby Transform). Der Empfaenger kann beliebige '
                '~80 % der Pakete aufnehmen und trotzdem alles rekonstruieren. '
                'Reihenfolge ist egal. Binaer-Protokoll (kein Base64) spart 33 % '
                'Platz und erhoehe die Block-Groesse um denselben Faktor.',
                style: TextStyle(fontSize: 12),
              ),
            ),
            ], // end if !_singlePage
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}
