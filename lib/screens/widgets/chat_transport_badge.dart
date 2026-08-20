// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'package:qgap/model/chat_group.dart';
import 'package:qgap/model/message.dart';

/// Visuelle Kennzeichnung eines Chats gemäß Transport + Verschlüsselung
/// (+ ggf. USB-only-Modus bei OTP).
///
/// Symbol-Mapping:
/// - online   + RSA/AES/Hybrid → 1× `key_vertical`
/// - online   + OTP            → 2× `key_vertical`
/// - offline  + RSA/Hybrid     → 1× `encrypted`
/// - offline  + OTP            → 2× `encrypted`
/// - airGap   + RSA/Hybrid     → 1× `shield_lock`
/// - airGap   + OTP            → 2× `shield_lock`
/// - airGap   + OTP + USB-only → 3× `shield_lock`
class ChatTransportBadge extends StatelessWidget {
  final ChatTransport transport;
  final EncryptionType encryption;
  /// Nur relevant wenn [encryption] == oneTimePad und [transport] == airGap.
  final bool ecUsbOnly;
  final double iconSize;
  final double spacing;

  const ChatTransportBadge({
    super.key,
    required this.transport,
    required this.encryption,
    this.ecUsbOnly = false,
    this.iconSize = 18,
    this.spacing = -4,
  });

  IconData get _icon {
    switch (transport) {
      case ChatTransport.online:
        return Symbols.key_vertical;
      case ChatTransport.offline:
        return Symbols.encrypted;
      case ChatTransport.airGap:
        return Symbols.shield_lock;
    }
  }

  Color get _color {
    switch (transport) {
      case ChatTransport.online:
        return const Color(0xFF1976D2); // blue.shade700
      case ChatTransport.offline:
        return const Color(0xFF6A1B9A); // purple.shade800
      case ChatTransport.airGap:
        return const Color(0xFF2E7D32); // green.shade800
    }
  }

  int get _stackCount {
    final isOtp = encryption == EncryptionType.oneTimePad;
    if (transport == ChatTransport.airGap) {
      if (!isOtp) return 1;
      return ecUsbOnly ? 3 : 2;
    }
    return isOtp ? 2 : 1;
  }

  String get _tooltip {
    final encName = encryption == EncryptionType.oneTimePad
        ? 'One-Time-Pad'
        : encryption == EncryptionType.rsa
            ? 'RSA'
            : encryption == EncryptionType.relayForward
                ? 'Relay-Weiterleitung'
                : 'Hybrid (RSA+AES)';
    switch (transport) {
      case ChatTransport.online:
        return 'Online (Firestore) · $encName';
      case ChatTransport.offline:
        return 'Offline (lokal) · $encName';
      case ChatTransport.airGap:
        return ecUsbOnly && encryption == EncryptionType.oneTimePad
            ? 'Air-Gap · OTP · USB-only'
            : 'Air-Gap · $encName';
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _stackCount;
    return Tooltip(
      message: _tooltip,
      child: SizedBox(
        width: iconSize + (count - 1) * (iconSize + spacing),
        height: iconSize,
        child: Stack(
          children: [
            for (int i = 0; i < count; i++)
              Positioned(
                left: i * (iconSize + spacing),
                top: 0,
                child: Icon(_icon, size: iconSize, color: _color),
              ),
          ],
        ),
      ),
    );
  }
}
