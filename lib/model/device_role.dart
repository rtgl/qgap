// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:shared_preferences/shared_preferences.dart';

/// Rollen, die ein QGap-Gerät einnehmen kann.
///
/// - [standalone]   Klassische Konfiguration: Internet vorhanden, eigenes
///                  RSA-Schlüsselpaar, kann selbst entschlüsseln und versenden.
///                  Standardwert, wenn nichts anderes konfiguriert ist.
///
/// - [onlineRelay]  Internet vorhanden, **kein eigenes** Schlüsselpaar für die
///                  Nutzlast. Das Gerät ist als Briefkasten/Relay für ein
///                  gepaartes Air-Gap-Gerät (siehe [PairingService]) registriert
///                  und reicht eingehende Transfers, die es selbst nicht
///                  entschlüsseln kann, an das Offline-Partnergerät weiter
///                  (Offline-Pickup-Queue). Eigene Nachrichten sendet der
///                  Relay nur als bereits vorverschlüsselte Blobs
///                  (`payloadType = QGAP_relay_preencrypted`).
///
/// - [airGap]       Vollständig offline. Hält RSA-Schlüsselpaar und EC-Dateien
///                  lokal, kommuniziert mit dem Online-Partner ausschließlich
///                  per QR-Code / USB.
enum DeviceRole {
  standalone,
  onlineRelay,
  airGap,
}

extension DeviceRoleExt on DeviceRole {
  String get id {
    switch (this) {
      case DeviceRole.standalone:  return 'standalone';
      case DeviceRole.onlineRelay: return 'online_relay';
      case DeviceRole.airGap:      return 'air_gap';
    }
  }

  String get label {
    switch (this) {
      case DeviceRole.standalone:  return 'Standalone (Internet + eigene Schlüssel)';
      case DeviceRole.onlineRelay: return 'Online-Relay (für gepaartes Offline-Gerät)';
      case DeviceRole.airGap:      return 'Air-Gap (Luftspalt, nur QR/USB)';
    }
  }

  String get shortLabel {
    switch (this) {
      case DeviceRole.standalone:  return 'Standalone';
      case DeviceRole.onlineRelay: return 'Online-Relay';
      case DeviceRole.airGap:      return 'Air-Gap';
    }
  }

  String get description {
    switch (this) {
      case DeviceRole.standalone:
        return 'Klassischer Modus: dieses Gerät hat Internet und kann '
               'eingehende Nachrichten selbst entschlüsseln.';
      case DeviceRole.onlineRelay:
        return 'Relay-Modus: dieses Gerät hat Internet, dient aber als '
               'Briefkasten für ein gepaartes Offline-Gerät. Eingehende '
               'Transfers, die nicht entschlüsselt werden können, werden '
               'in die Offline-Pickup-Queue gestellt und können per QR/USB '
               'an das Offline-Gerät übergeben werden.';
      case DeviceRole.airGap:
        return 'Air-Gap-Modus: dieses Gerät ist vollständig offline. '
               'Datenaustausch erfolgt ausschließlich per QR-Code oder USB '
               'über das gepaarte Online-Relay.';
    }
  }

  static DeviceRole fromId(String? s) {
    switch (s) {
      case 'online_relay': return DeviceRole.onlineRelay;
      case 'air_gap':      return DeviceRole.airGap;
      case 'standalone':
      default:
        return DeviceRole.standalone;
    }
  }
}

/// Lädt, speichert und migriert die Geräterolle.
///
/// Migrationspfad (einmalig beim ersten Aufruf):
/// - `device_role_offline = true`  & `device_role_online = false` → [DeviceRole.airGap]
/// - `device_role_offline = true`  & `device_role_online = true`  → [DeviceRole.standalone]
/// - `device_role_offline = false` & `device_role_online = true`  → [DeviceRole.standalone]
/// - sonst → [DeviceRole.standalone]
///
/// Den neuen [DeviceRole.onlineRelay]-Modus muss der Anwender explizit
/// auswählen.
class DeviceRoleService {
  static const String _prefsKey = 'device_role';
  static const String _legacyOfflineKey = 'device_role_offline';
  static const String _legacyOnlineKey  = 'device_role_online';
  static const String _migrationMarker  = 'device_role_migrated_v1';

  static DeviceRole? _cached;

  /// Liefert die aktuell konfigurierte Rolle. Führt beim ersten Aufruf eine
  /// Migration der alten Bool-Flags durch.
  static Future<DeviceRole> get() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefsKey);
    if (stored != null) {
      _cached = DeviceRoleExt.fromId(stored);
      return _cached!;
    }
    // Migration aus alten Booleans
    final migrated = await _migrateLegacy(prefs);
    _cached = migrated;
    return migrated;
  }

  static Future<DeviceRole> _migrateLegacy(SharedPreferences prefs) async {
    final wasOffline = prefs.getBool(_legacyOfflineKey) ?? false;
    final wasOnline  = prefs.getBool(_legacyOnlineKey)  ?? false;
    DeviceRole role;
    if (wasOffline && !wasOnline) {
      role = DeviceRole.airGap;
    } else {
      role = DeviceRole.standalone;
    }
    await prefs.setString(_prefsKey, role.id);
    await prefs.setBool(_migrationMarker, true);
    return role;
  }

  static Future<void> set(DeviceRole role) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, role.id);
    // Legacy-Bools synchron halten, damit alter Code, der noch nicht migriert
    // wurde (z. B. Farbgebung in `_buildMainScaffold`), korrekt funktioniert.
    await prefs.setBool(_legacyOfflineKey, role == DeviceRole.airGap);
    await prefs.setBool(_legacyOnlineKey,
        role == DeviceRole.standalone || role == DeviceRole.onlineRelay);
    _cached = role;
  }

  /// Wirft den Cache zurück (z. B. für Tests).
  static void resetCache() {
    _cached = null;
  }
}
