// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Erzwingt einen Firestore-Reconnect bei Netzwerkwechseln.
///
/// Hintergrund: Der gRPC-Stream von Firestore bleibt nach WLAN-/DNS-Wechseln
/// gelegentlich dauerhaft in UNAVAILABLE hängen (UnknownHostException) und
/// verbindet ohne App-Neustart nicht neu. disableNetwork()+enableNetwork()
/// baut die Verbindung sauber neu auf.
class FirestoreReconnect {
  FirestoreReconnect._();

  static StreamSubscription<List<ConnectivityResult>>? _sub;
  static Set<ConnectivityResult> _last = const {};

  static bool _toggling = false;

  /// Startet den Connectivity-Listener (idempotent). In main() nach
  /// erfolgreicher Firebase-Initialisierung aufrufen.
  static void start() {
    _sub ??= Connectivity().onConnectivityChanged.listen((results) {
      final current = results.toSet();
      final hasNet =
          current.isNotEmpty && !current.contains(ConnectivityResult.none);
      final hadNet =
          _last.isNotEmpty && !_last.contains(ConnectivityResult.none);
      final changed = !setEquals(current, _last);
      _last = current;
      // Reconnect wenn Netz zurückkommt oder der Netztyp wechselt (WLAN↔Mobil)
      if (hasNet && (!hadNet || changed)) {
        unawaited(_forceReconnect());
      }
    });
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  static Future<void> _forceReconnect() async {
    if (_toggling) return;
    _toggling = true;
    try {
      final db = FirebaseFirestore.instance;
      await db.disableNetwork();
      await db.enableNetwork();
      debugPrint('QGAP_NET: Firestore-Reconnect nach Netzwechsel ausgeführt');
    } catch (e) {
      // Firebase nicht initialisiert oder Toggle fehlgeschlagen – unkritisch.
      debugPrint('QGAP_NET: Firestore-Reconnect fehlgeschlagen: $e');
    } finally {
      _toggling = false;
    }
  }
}
