// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Callback-Typ: wird aufgerufen wenn der User auf eine Notification tippt.
/// Gibt die chatGroupId zurück.
typedef NotificationTapCallback = void Function(String chatGroupId);

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  static const String _prefKey = 'notifications_enabled';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  NotificationTapCallback? _onTap;

  /// Ob Benachrichtigungen global aktiviert sind.
  static bool enabled = true;

  bool _initialized = false;

  /// flutter_local_notifications unterstützt Android, iOS und macOS —
  /// auf Windows/Linux werden Benachrichtigungen still übersprungen.
  static bool get _platformSupported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  // ─── Initialisierung ───────────────────────────────────────────────────────

  /// Muss einmalig in main() aufgerufen werden.
  Future<void> initialize({NotificationTapCallback? onTap}) async {
    if (_initialized) return;
    _onTap = onTap;

    // Einstellung aus SharedPreferences laden
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_prefKey) ?? true;
    } catch (_) {}

    if (!_platformSupported) {
      developer.log(
          'NotificationService: Plattform ohne Notification-Support — übersprungen',
          name: 'NotificationService');
      return;
    }

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
    );

    // Android 13+: Benachrichtigungs-Berechtigung anfragen
    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();

    _initialized = true;
    developer.log('NotificationService initialisiert', name: 'NotificationService');
  }

  void _onNotificationResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && _onTap != null) {
      developer.log('Notification getippt: payload=$payload',
          name: 'NotificationService');
      _onTap!(payload);
    }
  }

  // ─── Einstellung ───────────────────────────────────────────────────────────

  /// Gibt zurück ob Benachrichtigungen aktiviert sind.
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_prefKey) ?? true;
    } catch (_) {
      return enabled;
    }
  }

  /// Aktiviert oder deaktiviert Benachrichtigungen und persistiert die Einstellung.
  static Future<void> setEnabled(bool value) async {
    enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (_) {}
    developer.log('Benachrichtigungen ${value ? "aktiviert" : "deaktiviert"}',
        name: 'NotificationService');
  }

  // ─── Benachrichtigung anzeigen ─────────────────────────────────────────────

  /// Zeigt eine System-Benachrichtigung für eine neue Nachricht im Chat.
  ///
  /// [chatGroupId] wird als Payload gesetzt – Tap öffnet diesen Chat.
  /// [chatGroupName] erscheint im Benachrichtigungstext.
  /// [count] optionale Anzahl ungelesener Nachrichten.
  Future<void> showNewMessageNotification({
    required String chatGroupId,
    required String chatGroupName,
    int count = 1,
  }) async {
    if (!enabled) return;
    if (!_initialized) {
      developer.log('NotificationService nicht initialisiert',
          name: 'NotificationService');
      return;
    }

    final body = count > 1
        ? '$count neue Nachrichten'
        : 'Neue Nachricht';

    const androidDetails = AndroidNotificationDetails(
      'QGAP_messages', // channel id
      'QGap Nachrichten', // channel name
      channelDescription: 'Benachrichtigungen für neue QGap-Nachrichten',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
      playSound: true,
      enableVibration: true,
    );

    const darwinDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
    );

    // Notification-ID aus chatGroupId ableiten (stabil pro Chat)
    final notifId = chatGroupId.hashCode.abs() % 100000;

    try {
      await _plugin.show(
        notifId,
        'Neue Nachricht(en) im QGap $chatGroupName Chat',
        body,
        details,
        payload: chatGroupId,
      );
      developer.log(
          'Notification gezeigt: "$chatGroupName" (id=$notifId)',
          name: 'NotificationService');
    } catch (e) {
      developer.log('Fehler beim Anzeigen der Notification: $e',
          name: 'NotificationService');
    }
  }

  /// Löscht alle Benachrichtigungen für einen Chat (z.B. beim Öffnen).
  Future<void> cancelNotificationsForChat(String chatGroupId) async {
    final notifId = chatGroupId.hashCode.abs() % 100000;
    try {
      await _plugin.cancel(notifId);
    } catch (_) {}
  }

  // ─── Widget-Helper ─────────────────────────────────────────────────────────

  /// Baut einen ListTile für die Benachrichtigungs-Einstellung.
  static Widget buildSettingsTile({
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      title: const Text('Benachrichtigungen'),
      subtitle: const Text(
          'System-Benachrichtigung bei neuen Nachrichten (auch im Hintergrund)'),
      value: value,
      onChanged: onChanged,
      secondary: const Icon(Icons.notifications_outlined),
    );
  }
}
