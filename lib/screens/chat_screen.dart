// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

/*erzeuge Releas Version:
flutter build apk --release; 
if (Test-Path "build\app\outputs\flutter-apk\app-release.apk"){ Copy-Item "build\app\outputs\flutter-apk\app-release.apk" "build\app\outputs\flutter-apk\QGAP_chat.apk"; 
Write-Host "✅ APK erfolgreich als D:\Daten\VSC\qr_code_chat\build\app\outputs\flutter-apk\QGAP_chat.apk erstellt!" } else { Write-Host "❌ APK-Datei nicht gefunden!" }

ist dann unter: build/app/outputs/flutter-apk/QGAP_chat.apk
D:\Daten\VSC\qr_code_chat\build\app\outputs\apk\release
*/
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';
import 'package:qgap/model/message.dart' as qgap_model;
import 'package:qgap/services/rsa_encryption.dart';
import 'package:qgap/services/rsa_key_manager.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qgap/screens/widgets/settings_dialog_widget.dart';
import 'package:qgap/screens/qr_data_receiver.dart';
import 'package:qgap/screens/qr_data_sender.dart';
import 'dart:io';
import 'dart:developer' as developer;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:share_plus/share_plus.dart';
import 'package:open_file/open_file.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qgap/services/contact_utils.dart';
import 'package:qgap/services/firestore_service.dart';
import 'package:qgap/services/local_contact_service.dart';
import 'package:qgap/services/auth_service.dart';
import 'package:qgap/services/app_storage.dart';
import 'package:qgap/services/ec_keyfile_service.dart';
import 'package:qgap/services/share_service.dart';
import 'package:qgap/services/ec_provenance_service.dart';
import 'package:qgap/services/usb_saf_service.dart';
import 'package:qgap/model/device_role.dart';
import 'package:qgap/services/offline_receipt_service.dart';
import 'package:qgap/services/pairing_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart' show QuerySnapshot;
import 'package:qgap/theme/app_theme.dart';
import 'package:qgap/model/chat_group.dart' show ChatTransport, ChatTransportExt;
import 'package:qgap/screens/widgets/chat_transport_badge.dart';
import 'package:qgap/services/notification_service.dart';

class ChatScreen extends StatefulWidget {
  final String chatGroupName;
  final String chatGroupId;
  final String? pendingScannedData;
  final String? pendingMetadata;
  final qgap_model.EncryptionType encryptionType;
  /// Firestore Chat-ID (nur bei Online-Chats gesetzt)
  final String? firestoreChatId;

  const ChatScreen({
    super.key,
    required this.chatGroupName,
    required this.chatGroupId,
    this.encryptionType = qgap_model.EncryptionType.oneTimePad,
    this.pendingScannedData,
    this.pendingMetadata,
    this.firestoreChatId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<qgap_model.Message> messages = [];
  String keyInfo = 'Lade Key-Info...';
  String? selectedKeyFile;
  int usedKeyBytes = 0;
  final Map<String, bool> messageQrCodeAvailable = {};
  late qgap_model.EncryptionType currentEncryptionType;
  ChatTransport _transport = ChatTransport.offline;

  // EC-Datei (.qgap_ec) Einstellungen
  String? selectedEcFile; // Zugeordnete .qgap_ec Datei
  bool ecUsbOnly = false; // true = Datei nur von USB laden (Sicherheitsmodus)
  List<String> _cachedVolumeRoots = []; // Cache: externe Volumes (für sync Zugriff)
  bool _showBase64InChat = false; // Globale Einstellung: Base64-Text in empfangenen Nachrichten anzeigen
  final FocusNode _inputFocusNode = FocusNode();

  // Kontaktschlüssel-Status für RSA/Hybrid-Chats
  String? _chatContactName;
  bool _hasContactKey = false;

  // Sprachnachrichten
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingId; // ID der aktuell spielenden Nachricht
  StreamSubscription<void>? _playerCompleteSub;
  Timer? _recordingTimer;

  // Firestore Online-Stream
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _firestoreSubscription;
  final Set<String> _processedFirestoreDocs = {};
  static const int _kMaxPersistedDocIds = 300;

  /// Lädt bereits verarbeitete Firestore-Doc-IDs aus SharedPreferences,
  /// damit gecachte Nachrichten beim erneuten Öffnen nicht doppelt
  /// verarbeitet/gespeichert werden.
  Future<void> _seedProcessedDocIds() async {
    final prefs = await SharedPreferences.getInstance();
    _processedFirestoreDocs.addAll(
        prefs.getStringList('processed_docs_${widget.chatGroupId}') ??
            const []);
  }

  void _persistProcessedDocIds() {
    SharedPreferences.getInstance().then((prefs) {
      var list = _processedFirestoreDocs.toList();
      if (list.length > _kMaxPersistedDocIds) {
        list = list.sublist(list.length - _kMaxPersistedDocIds);
      }
      prefs.setStringList('processed_docs_${widget.chatGroupId}', list);
    });
  }

  /// Mapping: lokale Nachrichten-ID → Firestore Document-ID
  final Map<String, String> _firestoreDocIdForMessage = {};

  /// Mutable Firestore-Chat-ID (kann nach dem Öffnen des Chats erst angelegt werden)
  String? _firestoreChatId;

  /// Initialer Status für eigene neue Nachrichten:
  /// – Online-Chat → `sending` (Uhr-Symbol bis Firestore die Nachricht annimmt)
  /// – sonst       → `sent`    (1 graues Häkchen, lokal/QR-only)
  qgap_model.MessageDeliveryStatus get _initialDeliveryStatus =>
      _firestoreChatId != null
          ? qgap_model.MessageDeliveryStatus.sending
          : qgap_model.MessageDeliveryStatus.sent;

  /// Hebt den Status einer eigenen Nachricht an. Niemals downgraden.
  void _updateDeliveryStatus(
      String msgId, qgap_model.MessageDeliveryStatus status) {
    final idx = messages.indexWhere((m) => m.id == msgId);
    if (idx < 0) return;
    if (messages[idx].deliveryStatus.index >= status.index) return;
    if (!mounted) {
      messages[idx] = messages[idx].copyWith(deliveryStatus: status);
      return;
    }
    setState(() {
      messages[idx] = messages[idx].copyWith(deliveryStatus: status);
    });
    // Persistieren nicht zwingend bei jeder Statusänderung – einmal beim
    // nächsten regulären Save reicht.
  }

  /// WhatsApp-artige Status-Häkchen für eigene Nachrichten:
  /// – `sending`   = Uhr-Symbol (grau)
  /// – `sent`      = 1 Häkchen (grau)
  /// – `delivered` = 2 Häkchen (grau)
  /// – `read`      = 2 Häkchen (blau)
  Widget _buildDeliveryStatusIcon(qgap_model.MessageDeliveryStatus status) {
    switch (status) {
      case qgap_model.MessageDeliveryStatus.sending:
        return const Icon(Icons.access_time, size: 12, color: Colors.grey);
      case qgap_model.MessageDeliveryStatus.sent:
        return const Icon(Icons.check, size: 14, color: Colors.grey);
      case qgap_model.MessageDeliveryStatus.delivered:
        return const Icon(Icons.done_all, size: 14, color: Colors.grey);
      case qgap_model.MessageDeliveryStatus.read:
        return const Icon(Icons.done_all, size: 14, color: Color(0xFF34B7F1));
    }
  }

  @override
  void initState() {
    super.initState();
    currentEncryptionType = widget.encryptionType;
    _firestoreChatId = widget.firestoreChatId;
    // Initialer Transport-Wert: online wenn Firestore-Chat, sonst offline.
    // Wird gleich von SharedPreferences (chat_groups) ggf. überschrieben (airGap).
    _transport = (_firestoreChatId != null) ? ChatTransport.online : ChatTransport.offline;
    _loadTransportFromGroups();
    // WICHTIG: Firestore-Stream erst NACH dem Laden der lokalen Historie
    // abonnieren – sonst überschreibt _saveChatMessages() beim ersten
    // Stream-Event die gespeicherten Nachrichten mit einer fast leeren Liste.
    _initializeChat().then((_) async {
      if (!mounted || _firestoreChatId == null) return;
      await _seedProcessedDocIds();
      if (!mounted) return;
      _subscribeFirestore(_firestoreChatId!);
      // Auto-Handshake nur bei RSA/Hybrid-Chats (nicht bei OTP/EC oder relayForward – kein Public Key nötig)
      if (widget.encryptionType != qgap_model.EncryptionType.oneTimePad &&
          widget.encryptionType != qgap_model.EncryptionType.relayForward) {
        _autoSendPublicKeyHandshake();
      }
    });
  }

  /// Lädt den Transport-Modus aus der ChatGroup in SharedPreferences.
  Future<void> _loadTransportFromGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final groups = prefs.getStringList('chat_groups') ?? [];
      for (final s in groups) {
        try {
          final m = json.decode(s) as Map<String, dynamic>;
          if (m['id'] == widget.chatGroupId) {
            final t = ChatTransportExt.fromString(m['transport'] as String?);
            // Falls kein 'transport' Feld vorhanden: aus isOnlineEnabled ableiten
            final ChatTransport resolved;
            if (m['transport'] != null) {
              resolved = t;
            } else {
              resolved = (m['isOnlineEnabled'] == true)
                  ? ChatTransport.online
                  : ChatTransport.offline;
            }
            if (mounted) setState(() => _transport = resolved);
            return;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Sendet automatisch beim Öffnen den eigenen Public Key als Handshake,
  /// damit der Gesprächspartner immer den aktuellen Schlüssel hat.
  /// Wird pro Chat nur einmal gesendet – erneut nur, wenn sich der Key ändert.
  Future<void> _autoSendPublicKeyHandshake() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final myPublicKeyStr = prefs.getString('rsa_public_key');
      if (myPublicKeyStr != null && widget.firestoreChatId != null) {
        final sentKey = 'handshake_sent_${widget.chatGroupId}';
        if (prefs.getString(sentKey) == myPublicKeyStr.hashCode.toString()) {
          return; // bereits mit aktuellem Key gesendet
        }
        await FirestoreService().sendPublicKeyHandshake(
            widget.firestoreChatId!, myPublicKeyStr);
        await prefs.setString(sentKey, myPublicKeyStr.hashCode.toString());
        developer.log('🔑 Auto-Handshake gesendet', name: 'ChatScreen');
      }
    } catch (e) {
      developer.log('Auto-Handshake fehlgeschlagen: $e', name: 'ChatScreen');
    }
  }

  /// Manuell den eigenen Public Key als Handshake senden (Menü-Aktion).
  Future<void> _sendMyPublicKeyHandshake() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final myPublicKeyStr = prefs.getString('rsa_public_key');
      if (myPublicKeyStr == null) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(
                content: Text(
                    'Kein RSA-Schlüsselpaar vorhanden. Erst Schlüssel generieren.')));
        }
        return;
      }
      await FirestoreService()
          .sendPublicKeyHandshake(widget.firestoreChatId!, myPublicKeyStr);
      if (mounted) {
        showQgapSnackBar(context, 
          const SnackBar(
            content: Text(
                '🔑 Public Key gesendet. Gegenstelle kann jetzt entschlüsseln.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Senden des Public Keys: $e')),
        );
      }
    }
  }

  /// Abonniert den Firestore-Nachrichtenstream für Online-Chats.
  void _subscribeFirestore(String firestoreChatId) {
    final svc = FirestoreService();
    _firestoreSubscription = svc.messagesStream(firestoreChatId).listen(
      (snapshot) async {
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final type = data['type'] as String? ?? 'text';
          final senderId = data['senderId'] as String? ?? '';
          final myUid = AuthService.currentUid ?? '';

          // ── Eigene Nachrichten: nur Read-Receipts beobachten ────────────
          if (senderId == myUid) {
            if (type == 'text') {
              final readBy = (data['readBy'] as List?)?.cast<String>() ?? const <String>[];
              final readByOther = readBy.any((u) => u != myUid);
              if (readByOther) {
                // Lokale msgId zur DocId finden und Status auf "read" setzen
                String? localMsgId;
                _firestoreDocIdForMessage.forEach((mid, did) {
                  if (did == doc.id) localMsgId = mid;
                });
                if (localMsgId != null) {
                  _updateDeliveryStatus(
                      localMsgId!, qgap_model.MessageDeliveryStatus.read);
                }
              }
            }
            _processedFirestoreDocs.add(doc.id);
            continue;
          }

          // Duplikate verhindern (für eingehende Nachrichten)
          if (_processedFirestoreDocs.contains(doc.id)) continue;

          _processedFirestoreDocs.add(doc.id);

          if (type == 'handshake') {
            final text = data['text'] as String? ?? '';
            if (text.isNotEmpty && text.contains('modulus')) {
              await _importPublicKeyFromHandshake(senderId, text);
              // Handshake-Dokument nach dem Einlesen löschen – sonst wird der
              // Public Key bei jedem Öffnen des Chats erneut "empfangen".
              try {
                await FirestoreService().deleteMessage(firestoreChatId, doc.id);
              } catch (_) {}
            }
          } else if (type == 'offline_relay') {
            // Vom Relay-Phone weitergeleiteter QGap-Envelope.
            // Relay-Phone (relayForward): nur Weiterleitung anzeigen.
            // Tablet/Empfänger (oneTimePad): normal als text verarbeiten (OTP-entschlüsseln).
            final innerB64 = data['text'] as String? ?? '';
            if (innerB64.isNotEmpty && mounted) {
              if (currentEncryptionType == qgap_model.EncryptionType.relayForward) {
                // Relay-Phone: Sentinel anzeigen
                final msgId = '${doc.id}_relay';
                if (!mounted) continue;
                setState(() {
                  messages.add(qgap_model.Message(
                    text: innerB64,
                    originalText: _kRelayMsgSentinel,
                    isMe: false,
                    timestamp: DateTime.now(),
                    id: msgId,
                  ));
                  messageQrCodeAvailable[msgId] = false;
                });
                _firestoreDocIdForMessage[msgId] = doc.id;
                _saveChatMessages();
                _ensureScrollToBottom();
              } else {
                // Tablet/Empfänger: binäres QGap-Envelope entpacken, Metadaten extrahieren,
                // dann direkt _receiveFirestoreOtpText (oder _receiveFirestoreFileOtp) aufrufen.
                // KEIN _processScannedQRData – das würde den Key-File-Conflict-Check auslösen.
                try {
                  final innerBytes = base64.decode(innerB64);
                  final parsed = _parseBinaryEnvelope(Uint8List.fromList(innerBytes));
                  if (parsed != null) {
                    final metadata = parsed['metadata'] as String;
                    final payload = parsed['payload'] as Uint8List;
                    // fullText im gleichen Format wie normaler Firestore-Text aufbauen:
                    // base64(metadata) + base64(payload)
                    final fullText = (metadata.isNotEmpty
                            ? base64.encode(utf8.encode(metadata))
                            : '') +
                        base64.encode(payload);
                    final meta = metadata;
                    final attachmentName = parsed['fileName'] as String?;
                    final fileMatch = RegExp(r'FILE:([^;]+)').firstMatch(meta);
                    final effectiveFileName = fileMatch?.group(1) ?? attachmentName;
                    if (effectiveFileName != null) {
                      await _receiveFirestoreFileOtp(fullText, meta, effectiveFileName,
                          firestoreDocId: doc.id);
                    } else {
                      await _receiveFirestoreOtpText(fullText, meta, firestoreDocId: doc.id);
                    }
                  } else {
                    developer.log('log: offline_relay: _parseBinaryEnvelope null', name: 'ChatScreen');
                  }
                  try {
                    await FirestoreService().markMessageRead(firestoreChatId, doc.id);
                  } catch (_) {}
                } catch (e) {
                  developer.log('log: offline_relay decode/parse error: $e', name: 'ChatScreen');
                }
              }
            }
          } else if (type == 'offline_relay_btoa') {
            // B→A: Relay B hat eine von Air-Gap B relay-gewrappte Nachricht
            // weitergeleitet. innerB64 = base64(raw QGap-Binär-Envelope).
            // Nur Relay A (relayForward-Chat) muss diese anzeigen.
            final innerB64 = data['text'] as String? ?? '';
            if (innerB64.isNotEmpty && mounted &&
                currentEncryptionType == qgap_model.EncryptionType.relayForward) {
              final msgId = '${doc.id}_btoa';
              if (!mounted) continue;
              setState(() {
                messages.add(qgap_model.Message(
                  text: innerB64,
                  originalText: _kRelayBtoASentinel,
                  isMe: false,
                  timestamp: DateTime.now(),
                  id: msgId,
                ));
                messageQrCodeAvailable[msgId] = false;
              });
              _firestoreDocIdForMessage[msgId] = doc.id;
              _saveChatMessages();
              _ensureScrollToBottom();
            }
          } else if (type == 'text') {
            final text = data['text'] as String? ?? '';
            final attachmentName = data['attachmentName'] as String?;
            if (text.isNotEmpty && mounted) {
              // Relay-Phone (relayForward): OTP-Nachricht vom Tablet nicht entschlüsseln,
              // stattdessen als B→A-Sentinel speichern + QR-Code für Air-Gap anbieten.
              if (currentEncryptionType == qgap_model.EncryptionType.relayForward) {
                final msgId = doc.id;
                if (!mounted) continue;
                setState(() {
                  messages.add(qgap_model.Message(
                    text: text,
                    originalText: _kRelayBtoASentinel,
                    isMe: false,
                    timestamp: DateTime.now(),
                    id: msgId,
                  ));
                  messageQrCodeAvailable[msgId] = true; // QR anbieten
                });
                _firestoreDocIdForMessage[msgId] = doc.id;
                _saveChatMessages();
                _ensureScrollToBottom();
                try {
                  await FirestoreService().markMessageRead(firestoreChatId, doc.id);
                } catch (_) {}
                continue;
              }
              final meta = _extractMetadataFromText(text);
              final firstPart = meta.split(';')[0];
              String? decrypted;
              if (firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID') {
                decrypted = await _decryptRsaHybridFromData(text, firstPart);
                _showDecryptErrorIfNeeded(decrypted);
              }
              if (!mounted) continue;
              // Datei oder Sprachnachricht? (Metadaten enthalten FILE: bei Hybrid/RSA
              // ODER attachmentName im Firestore-Dokument bei OTP)
              final fileMatch = RegExp(r'FILE:([^;]+)').firstMatch(meta);
              final effectiveFileName = fileMatch?.group(1) ?? attachmentName;
              if (effectiveFileName != null) {
                if (decrypted != null && !decrypted.startsWith('\u274c')) {
                  // Hybrid/RSA: entschlüsseltes Base64 direkt speichern
                  await _receiveFirestoreFile(text, meta, effectiveFileName, decrypted, firestoreDocId: doc.id);
                } else if (firstPart != 'RSA' && firstPart != 'HYB' && firstPart != 'HYBRID') {
                  // OTP: Metadaten parsen und lokal entschlüsseln
                  await _receiveFirestoreFileOtp(text, meta, effectiveFileName, firestoreDocId: doc.id);
                } else {
                  // RSA/Hybrid entschlüsselung fehlgeschlagen → als Textnachricht anzeigen
                  _addReceivedMessage(text, meta, decryptedText: decrypted);
                  if (messages.isNotEmpty) {
                    _firestoreDocIdForMessage[messages.last.id] = doc.id;
                  }
                }
              } else {
                if (firstPart != 'RSA' && firstPart != 'HYB' && firstPart != 'HYBRID') {
                  // OTP-Textnachricht (kein Dateianhang): entschlüsseln
                  await _receiveFirestoreOtpText(text, meta, firestoreDocId: doc.id);
                } else {
                  // RSA/Hybrid-Entschlüsselung fehlgeschlagen → als Textnachricht anzeigen
                  _addReceivedMessage(text, meta, decryptedText: decrypted);
                  if (messages.isNotEmpty) {
                    _firestoreDocIdForMessage[messages.last.id] = doc.id;
                  }
                }
              }
              // Lese-Quittung senden (Best-Effort, blaue Häkchen beim Sender).
              FirestoreService()
                  .markMessageRead(firestoreChatId, doc.id);
            }
          }
        }
        _persistProcessedDocIds();
      },
      onError: (e) => developer.log('Firestore stream error: $e', name: 'ChatScreen'),
    );
  }

  /// Importiert einen Public Key aus einem Firestore-Handshake.
  Future<void> _importPublicKeyFromHandshake(String senderUid, String publicKeyJson) async {
    try {
      // Kontaktname für diese UID aus LocalContactService holen (Fallback: Chat-Name)
      String contactName = await LocalContactService.getLocalName(senderUid,
          fallback: _chatContactName ?? widget.chatGroupName);

      // UID → Name lokal speichern (damit spätere Lookups den Namen finden)
      await LocalContactService.saveLocalName(senderUid, contactName);

      final keyManager = RSAKeyManager();
      final ok = await keyManager.saveContactPublicKeyFromJson(contactName, publicKeyJson);
      if (ok && mounted) {
        // chat_contact setzen falls noch nicht gesetzt
        if (_chatContactName == null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('chat_contact_${widget.chatGroupId}', contactName);
          setState(() {
            _chatContactName = contactName;
            _hasContactKey = true;
          });
        } else {
          setState(() { _hasContactKey = true; });
        }
        developer.log('✅ Public Key von $senderUid ($contactName) importiert', name: 'ChatScreen');
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('🔑 Public Key von "$contactName" empfangen & importiert!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      developer.log('Fehler beim Importieren des Public Keys: $e', name: 'ChatScreen');
    }
  }

  /// Empfängt eine Datei/Sprachnachricht via Firestore-Stream:
  /// Speichert die entschlüsselten Bytes lokal und fügt eine Datei-Nachricht ein.
  Future<void> _receiveFirestoreFile(
      String fullText, String meta, String fileName, String decryptedBase64,
      {String? firestoreDocId}) async {
    try {
      final fileBytes = base64.decode(decryptedBase64);
      final isVoice = fileName.endsWith('.ogg') || fileName.endsWith('.m4a') || fileName.endsWith('.mp3');
      final saveDir = Directory(AppStorage.empfangenDir);
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final saveFile = File('${saveDir.path}/$fileName');
      await saveFile.writeAsBytes(fileBytes, flush: true);

      developer.log('✅ Firestore-Datei empfangen: ${saveFile.path}', name: '_receiveFirestoreFile');

      if (!mounted) return;
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: fileName,
          isMe: false,
          timestamp: DateTime.now(),
          id: msgId,
          messageType: isVoice ? qgap_model.MessageType.voice : qgap_model.MessageType.file,
          attachmentFileName: fileName,
          attachmentLocalPath: saveFile.path,
          attachmentSize: fileBytes.length,
        ));
        messageQrCodeAvailable[msgId] = false;
      });
      // Firestore DocId verknüpfen (falls vorhanden)
      if (firestoreDocId != null) {
        _firestoreDocIdForMessage[msgId] = firestoreDocId;
      }
      _saveChatMessages();
      _ensureScrollToBottom();

      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text(isVoice
              ? '🎤 Sprachnachricht "$fileName" empfangen'
              : '📎 Datei "$fileName" empfangen → Daten/QGap/empfangen/'),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      developer.log('Fehler beim Empfangen der Firestore-Datei: $e', name: '_receiveFirestoreFile');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Empfangen der Datei: $e')));
      }
    }
  }

  /// Empfängt eine OTP-verschlüsselte Datei/Sprachnachricht via Firestore.
  /// Metadaten-Format: `keyFileName;byteOffset;[ECC:<code>;]` (neu) oder
  /// `keyFileName;byteOffset;[EC:<ecFile>;]` (Legacy, vor Code-Einführung).
  Future<void> _receiveFirestoreFileOtp(
      String fullText, String meta, String fileName,
      {String? firestoreDocId}) async {
    try {
      final metaParts = meta.split(';');
      if (metaParts.length < 2) {
        throw Exception('Ungültige OTP-Metadaten: $meta');
      }
      final keyFileName = metaParts[0];
      final byteOffset = int.tryParse(metaParts[1]) ?? 0;
      String? ecFileName;
      String? ecCode;
      for (int i = 2; i < metaParts.length; i++) {
        final part = metaParts[i];
        if (part.startsWith('ECC:')) {
          ecCode = part.substring(4);
          break;
        }
        if (part.startsWith('EC:')) {
          ecFileName = part.substring(3);
          break;
        }
      }

      // Wenn ECC-Code übertragen wurde: passende lokale EC-Datei suchen.
      if (ecCode != null) {
        ecFileName = await EcKeyfileService.findEcFileByCode(ecCode);
        if (ecFileName == null) {
          // EC-Datei fehlt → Nachricht parken statt verwerfen.
          final encryptedBase64Park =
              _extractEncryptedTextWithoutMetadata(fullText);
          await _parkOtpMessage(
            fullText: fullText,
            ecCode: ecCode,
            keyFileName: keyFileName,
            byteOffset: byteOffset,
            fileName: fileName,
            encryptedBytes: base64.decode(encryptedBase64Park),
            firestoreDocId: firestoreDocId,
          );
          return;
        }
      }

      // Verschlüsselten Payload extrahieren (Base64 nach den Metadaten)
      final encryptedBase64 = _extractEncryptedTextWithoutMetadata(fullText);
      final encryptedBytes = base64.decode(encryptedBase64);

      // OTP-XOR Entschlüsselung
      final decryptedBytes = _decryptRawBytesXOR(encryptedBytes, keyFileName, byteOffset, ecFileName);

      final isVoice = fileName.endsWith('.ogg') || fileName.endsWith('.m4a') || fileName.endsWith('.mp3');
      final saveDir = Directory(AppStorage.empfangenDir);
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final saveFile = File('${saveDir.path}/$fileName');
      await saveFile.writeAsBytes(decryptedBytes, flush: true);

      developer.log('✅ Firestore OTP-Datei empfangen: ${saveFile.path}', name: '_receiveFirestoreFileOtp');

      if (!mounted) return;
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: fileName,
          isMe: false,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: keyFileName,
          byteOffset: byteOffset,
          messageType: isVoice ? qgap_model.MessageType.voice : qgap_model.MessageType.file,
          attachmentFileName: fileName,
          attachmentLocalPath: saveFile.path,
          attachmentSize: decryptedBytes.length,
        ));
        messageQrCodeAvailable[msgId] = false;
      });
      if (firestoreDocId != null) {
        _firestoreDocIdForMessage[msgId] = firestoreDocId;
      }
      _saveChatMessages();
      _ensureScrollToBottom();

      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text(isVoice
              ? '🎤 Sprachnachricht "$fileName" empfangen'
              : '📎 Datei "$fileName" empfangen → Daten/QGap/empfangen/'),
          duration: const Duration(seconds: 4),
        ));
      }
    } catch (e) {
      developer.log('Fehler beim Empfangen der OTP-Datei: $e', name: '_receiveFirestoreFileOtp');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Empfangen der Datei "$fileName": $e')));
      }
    }
  }

  /// Empfängt und entschlüsselt eine OTP-Textnachricht aus Firestore.
  /// Wird aufgerufen wenn die Nachricht kein FILE: oder attachmentName enthält
  /// und die Verschlüsselung nicht RSA/HYB/HYBRID ist.
  Future<void> _receiveFirestoreOtpText(String fullText, String meta,
      {String? firestoreDocId}) async {
    try {
      final metaParts = meta.split(';');
      if (metaParts.length < 2) {
        _addReceivedMessage(fullText, meta);
        if (messages.isNotEmpty && firestoreDocId != null) {
          _firestoreDocIdForMessage[messages.last.id] = firestoreDocId;
        }
        return;
      }
      final keyFileName = metaParts[0];
      final byteOffset = int.tryParse(metaParts[1]) ?? 0;
      String? ecFileName;
      String? ecCode;
      for (int i = 2; i < metaParts.length; i++) {
        final part = metaParts[i];
        if (part.startsWith('ECC:')) {
          ecCode = part.substring(4);
          break;
        }
        if (part.startsWith('EC:')) {
          ecFileName = part.substring(3);
          break;
        }
      }
      if (ecCode != null) {
        ecFileName = await EcKeyfileService.findEcFileByCode(ecCode);
        if (ecFileName == null) {
          // EC-Datei fehlt → Platzhalter anzeigen (kann später nicht nachgeholt werden)
          if (!mounted) return;
          final msgId = DateTime.now().millisecondsSinceEpoch.toString();
          setState(() {
            messages.add(qgap_model.Message(
              text: fullText,
              originalText:
                  '⏳ Nachricht kann nicht entschlüsselt werden\n(EC-Datei mit Code "$ecCode" fehlt)',
              isMe: false,
              timestamp: DateTime.now(),
              id: msgId,
            ));
            messageQrCodeAvailable[msgId] = false;
          });
          if (firestoreDocId != null) {
            _firestoreDocIdForMessage[msgId] = firestoreDocId;
          }
          _saveChatMessages();
          _ensureScrollToBottom();
          return;
        }
      }
      final encryptedBase64 = _extractEncryptedTextWithoutMetadata(fullText);
      final encryptedBytes = base64.decode(encryptedBase64);
      debugPrint('QGAP_DECRYPT: key=$keyFileName offset=$byteOffset ec=$ecFileName '
          'cipherLen=${encryptedBytes.length} cipherB64=$encryptedBase64');
      final decryptedBytes =
          _decryptRawBytesXOR(encryptedBytes, keyFileName, byteOffset, ecFileName);
      final decryptedText = utf8.decode(decryptedBytes, allowMalformed: true);
      debugPrint('QGAP_DECRYPT: Ergebnis="$decryptedText"');
      if (!mounted) return;
      _addReceivedMessage(fullText, meta, decryptedText: decryptedText);
      if (messages.isNotEmpty && firestoreDocId != null) {
        _firestoreDocIdForMessage[messages.last.id] = firestoreDocId;
      }
    } catch (e) {
      debugPrint('QGAP_DECRYPT: FEHLER: $e');
      developer.log('⚠️ OTP-Text-Entschlüsselung fehlgeschlagen: $e',
          name: '_receiveFirestoreOtpText');
      if (mounted) {
        _addReceivedMessage(fullText, meta);
        if (messages.isNotEmpty && firestoreDocId != null) {
          _firestoreDocIdForMessage[messages.last.id] = firestoreDocId;
        }
      }
    }
  }

  /// Prüft ob die Nachricht das Firestore-Limit (ca. 900 KB) überschreitet.
  /// Zeigt eine SnackBar-Meldung und gibt [false] zurück wenn zu groß.
  bool _checkFirestoreMessageSize(String fullText, String fileName) {
    // Firestore-Dokument-Limit ist 1 MB; wir verwenden 900 KB als sicheren Schwellwert.
    const int maxBytes = 900 * 1024;
    final int textBytes = utf8.encode(fullText).length;
    if (textBytes > maxBytes) {
      final mbSize = (textBytes / 1024 / 1024).toStringAsFixed(1);
      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text(
              '⚠️ "$fileName" ist $mbSize MB – zu groß für Online-Chat (Limit: ~900 KB). '
              'Nur per QR-Code übertragbar.'),
          duration: const Duration(seconds: 6),
          backgroundColor: Colors.orange.shade800,
        ));
      }
      return false;
    }
    return true;
  }

  void _ensureScrollToBottom() {
    void doScroll() {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      doScroll();
      Future.delayed(const Duration(milliseconds: 150), doScroll);
      Future.delayed(const Duration(milliseconds: 400), doScroll);
      // Zusätzlicher später Retry: Tastatur-Einblendanimation kann auf
      // manchen Geräten länger dauern und den sichtbaren Bereich erst
      // danach verkleinern.
      Future.delayed(const Duration(milliseconds: 650), doScroll);
    });
  }

  void _showDecryptErrorIfNeeded(String decryptedText) {
    if (!mounted || !decryptedText.startsWith('❌')) return;

    String code = 'DEC-UNK';
    final m = RegExp(r'^❌\s*\[([^\]]+)\]').firstMatch(decryptedText);
    if (m != null && m.groupCount >= 1) {
      code = m.group(1) ?? code;
    }

    showQgapSnackBar(context, 
      SnackBar(
        content: Text('Entschlüsselung fehlgeschlagen ($code)'),
        backgroundColor: Colors.red,
      ),
    );
  }

  // ─── Chat-Einladung aus dem Chat heraus senden ──────────────────────────

  /// Stellt sicher, dass ein Firestore-Chat existiert.
  /// Legt ihn bei Bedarf neu an und speichert die ID in State + SharedPreferences.
  Future<void> _ensureFirestoreChatId() async {
    if (_firestoreChatId != null) return;
    final uid = AuthService.currentUid;
    if (uid == null) return;
    try {
      final newId = AuthService.generateRandomString(20, emailSafe: true);
      final svc = FirestoreService();
      await svc.createChat(newId);
      await svc.sendHandshake(newId);

      // In der ChatGroup in SharedPreferences persistieren
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = List<String>.from(prefs.getStringList('chat_groups') ?? []);
      final idx = groupsJson.indexWhere((s) {
        try {
          final m = json.decode(s) as Map<String, dynamic>;
          return m['id'] == widget.chatGroupId;
        } catch (_) {
          return false;
        }
      });
      if (idx >= 0) {
        final groupMap = json.decode(groupsJson[idx]) as Map<String, dynamic>;
        groupMap['firestoreChatId'] = newId;
        groupMap['isOnlineEnabled'] = true;
        groupsJson[idx] = json.encode(groupMap);
        await prefs.setStringList('chat_groups', groupsJson);
      }

      if (mounted) {
        setState(() => _firestoreChatId = newId);
      } else {
        _firestoreChatId = newId;
      }
      // Firestore-Stream starten
      _subscribeFirestore(newId);
    } catch (e) {
      developer.log('Fehler beim Anlegen des Firestore-Chats: $e', name: '_ensureFirestoreChatId');
    }
  }

  /// Baut den JSON-Payload für eine Chat-Einladung auf.
  /// Gibt null zurück wenn kein Online-Chat oder nicht eingeloggt.
  Future<Map<String, dynamic>?> _buildInvitePayload() async {
    // Offline-EC nur für Offline-/AirGap-OTP-Chats — bei Transport "online"
    // muss eine Online-Einladung (Firestore) erzeugt werden.
    if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad &&
        _transport != ChatTransport.online) {
      return _buildOfflineEcInvitePayload();
    }
    final uid = AuthService.currentUid;
    if (uid == null) return null;
    await _ensureFirestoreChatId();
    if (_firestoreChatId == null) return null;
    final chatType = currentEncryptionType == qgap_model.EncryptionType.oneTimePad
        ? 'qgap_ec'
        : 'qgap_aes';
    final payloadMap = <String, dynamic>{
      'version': 1,
      'chatType': chatType,
      'firestoreChatId': _firestoreChatId,
      'creatorUid': uid,
      'chatName': widget.chatGroupName,
    };
    if (chatType == 'qgap_aes' && mounted) {
      final includeKey = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('🔑 Public Key mitsenden?'),
          content: const Text(
            'Soll dein eigener Public Key in die Einladung aufgenommen werden?\n\n'
            'Der Empfänger kann dann sofort verschlüsselte Nachrichten an dich senden.',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Nein')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Ja, mitsenden')),
          ],
        ),
      );
      if (includeKey == true) {
        final prefs = await SharedPreferences.getInstance();
        final myPublicKeyStr = prefs.getString('rsa_public_key');
        if (myPublicKeyStr != null) payloadMap['creatorPublicKey'] = myPublicKeyStr;
      }
    }
    return payloadMap;
  }

  /// Baut eine Offline-EC-Einladung. Übertragen wird AUSSCHLIESSLICH:
  ///  - `chatGroupId`        (gemeinsame lokale ID, kein Personenbezug)
  ///  - `ecCode`             (zufällige ID-Komponente des Dateinamens)
  ///  - `partnerOnlineUid`   (Firestore-UID des gepaarten Online-Relays
  ///                          dieses Geräts – Empfänger nutzt sie als
  ///                          Transport-Adresse zurück zu uns)
  ///
  /// Es werden KEINE personenbezogenen Daten unverschlüsselt übertragen
  /// (kein Chat-Name, keine Beschreibung, kein Emoji, kein freier Datei-Text).
  /// Die Schlüsseldatei selbst wird ausschließlich per USB ausgetauscht.
  Future<Map<String, dynamic>?> _buildOfflineEcInvitePayload() async {
    String? ecCode;
    if (selectedEcFile != null && selectedEcFile!.isNotEmpty) {
      ecCode = EcKeyfileService.extractCodeFromFilename(selectedEcFile!);
    }
    if (ecCode == null || ecCode.isEmpty) {
      if (mounted) {
        showQgapSnackBar(context,
          const SnackBar(
            content: Text(
              'Diesem Chat ist keine .qgap_ec mit gültigem Code zugeordnet – '
              'Einladung nicht möglich.',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return null;
    }
    final partnerOnlineUid = await PairingService.getPartnerOnlineUid();
    return <String, dynamic>{
      'version': 1,
      'chatType': 'qgap_ec_offline',
      'chatGroupId': widget.chatGroupId,
      'ecCode': ecCode,
      if (partnerOnlineUid != null && partnerOnlineUid.isNotEmpty)
        'partnerOnlineUid': partnerOnlineUid,
    };
  }

  /// Zeigt Einladungs-Dialog: Dateiname editierbar, Datei teilen oder QR-Code.
  Future<void> _showChatInviteDialog() async {
    final payloadMap = await _buildInvitePayload();
    if (!mounted) return;
    if (payloadMap == null) {
      // Einladung für Online-Chats benötigt Firebase-Auth
      final needsAuth =
          currentEncryptionType != qgap_model.EncryptionType.oneTimePad ||
              _transport == ChatTransport.online;
      if (needsAuth && AuthService.currentUid == null) {
        showQgapSnackBar(context, const SnackBar(
          content: Text(
            '⚠️ Einladung nicht möglich: Nicht eingeloggt.\n'
            'Auf Windows muss Firebase erst konfiguriert werden.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ));
      }
      return;
    }
    final jsonStr = jsonEncode(payloadMap);
    final isOfflineEc = payloadMap['chatType'] == 'qgap_ec_offline';
    final fileNameController = TextEditingController(text: 'ChatEinladung');
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: Row(
            children: [
              Icon(
                isOfflineEc ? Icons.usb : Icons.cloud_upload,
                color: Colors.blue,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(isOfflineEc
                    ? 'EC-Einladung senden (Offline)'
                    : 'Chat-Einladung senden'),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isOfflineEc
                  ? 'Diese Einladung enthält nur Chat-Metadaten und den Namen '
                      'der zugeordneten Schlüsseldatei.\n\n'
                      'Wichtig: die `.qgap_ec`-Schlüsseldatei muss separat per USB '
                      'an das andere Gerät übertragen werden — sie wird hier nicht '
                      'mitgeschickt.'
                  : 'Wähle wie du die Einladung teilen möchtest.'),
              const SizedBox(height: 12),
              TextField(
                controller: fileNameController,
                decoration: const InputDecoration(
                  labelText: 'Dateiname',
                  border: OutlineInputBorder(),
                  suffixText: '.qgap_ch',
                  helperText: 'Endung .qgap_ch wird automatisch ergänzt',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Abbrechen'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code),
              label: const Text('QR-Code'),
              onPressed: () {
                Navigator.of(ctx).pop();
                final bytes = Uint8List.fromList(utf8.encode(jsonStr));
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
                );
              },
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.share),
              label: const Text('Datei senden'),
              onPressed: () async {
                final name = fileNameController.text.trim();
                Navigator.of(ctx).pop();
                await _shareInviteAsFile(jsonStr, name);
              },
            ),
          ],
        ),
      ),
    );
    fileNameController.dispose();
  }

  /// Teilt die Einladung: System-Share, Datei-Export, Zwischenablage, E-Mail.
  Future<void> _shareInviteAsFile(String jsonStr, String rawName) async {
    String baseName = rawName.isEmpty ? 'ChatEinladung' : rawName;
    if (baseName.endsWith('.qgap_ch')) {
      baseName = baseName.substring(0, baseName.length - 8);
    }
    final fileName = '$baseName.qgap_ch';
    if (!mounted) return;
    await ShareService.showShareDialog(
      context: context,
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(jsonStr)),
      clipboardText: jsonStr,
      subject: 'QGap Chat-Einladung',
    );
  }

  /// Zeigt Chat-Info-Dialog mit Firestore-IDs im Hamburger-Menü.
  void _showChatInfoDialog() {
    final myUid = AuthService.currentUid ?? '–';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.blueGrey),
            SizedBox(width: 8),
            Text('Chat-Info'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoRow('Chat-Name', widget.chatGroupName),
              _infoRow('Chat-ID (lokal)', widget.chatGroupId),
              if (widget.firestoreChatId != null) ...[
                const Divider(),
                _infoRow('Firestore Chat-ID', widget.firestoreChatId!),
              ],
              const Divider(),
              _infoRow('Meine User-ID', myUid),
              _infoRow('Verschlüsselung', currentEncryptionType.toString().split('.').last),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Transport',
                        style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        ChatTransportBadge(
                          transport: _transport,
                          encryption: currentEncryptionType,
                          ecUsbOnly: ecUsbOnly,
                          iconSize: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _transport == ChatTransport.online
                              ? 'Online (Firestore)'
                              : _transport == ChatTransport.airGap
                                  ? (ecUsbOnly ? 'Air-Gap · USB-only' : 'Air-Gap')
                                  : 'Offline (lokal)',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _infoRow('Nachrichten', '${messages.length}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  /// Zeigt Nachricht-Info-Dialog beim Langklick (inkl. Firestore Message-ID falls vorhanden).
  void _showMessageInfoDialog(qgap_model.Message msg) {
    final firestoreDocId = _firestoreDocIdForMessage[msg.id];
    final plainText = _plainTextOf(msg);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.message, color: Colors.blueGrey),
            SizedBox(width: 8),
            Text('Nachrichten-Info'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _infoRow('Lokal-ID', msg.id),
              _infoRow('Zeitstempel', msg.timestamp.toString().split('.').first),
              _infoRow('Richtung', msg.isMe ? 'Gesendet' : 'Empfangen'),
              _infoRow('Typ', msg.messageType.toString().split('.').last),
              if (msg.attachmentFileName != null)
                _infoRow('Dateiname', msg.attachmentFileName!),
              if (firestoreDocId != null) ...[
                const Divider(),
                _infoRow('Firestore Chat-ID', widget.firestoreChatId ?? '–'),
                _infoRow('Firestore Message-ID', firestoreDocId),
              ],
            ],
          ),
        ),
        actions: [
          if (plainText != null)
            TextButton.icon(
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Text kopieren'),
              onPressed: () async {
                Navigator.pop(ctx);
                await _copyToClipboard(plainText);
                if (mounted) {
                  showQgapSnackBar(context, const SnackBar(
                    content: Text('✅ Text in Zwischenablage kopiert'),
                    backgroundColor: Colors.green,
                  ));
                }
              },
            ),
          if (!msg.isMe)
            TextButton.icon(
              icon: const Icon(Icons.verified, size: 16),
              label: const Text('Lesebestätigung'),
              onPressed: () async {
                Navigator.pop(ctx);
                await _createAndShowReadReceipt(msg);
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  /// Liefert den entschlüsselten Klartext einer Text-Nachricht
  /// (null bei Datei-/Sprach-Nachrichten, Relay-Platzhaltern und Fehlern).
  String? _plainTextOf(qgap_model.Message msg) {
    if (msg.messageType != qgap_model.MessageType.text) return null;
    final orig = msg.originalText;
    if (orig == _kRelayMsgSentinel || orig == _kRelayBtoASentinel) return null;
    if (orig.startsWith(_kParkedOtpSentinel)) return null;
    if (orig.startsWith('🔓 ')) return orig.substring(2).trim();
    if (msg.isMe) return orig;
    if (orig.startsWith('⏳') || orig.startsWith('❌') || orig.startsWith('⚠️')) {
      return null;
    }
    try {
      final decoded = _decodeBase64ToReadableText(msg.text);
      final parts = decoded.split('─────────────────────');
      if (parts.length >= 2) return parts[1].trim();
    } catch (_) {}
    return orig.isNotEmpty ? orig : null;
  }

  /// Erstellt eine signierte Offline-Lesebestätigung für die übergebene Nachricht
  /// und zeigt sie als QR-Code (zum Scannen durch das gepaarte Online-Relay)
  /// bzw. bietet alternativ Datei-Export an. Nur sinnvoll im Air-Gap-Modus.
  Future<void> _createAndShowReadReceipt(qgap_model.Message msg) async {
    final role = await DeviceRoleService.get();
    if (role != DeviceRole.airGap) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text(
                'Lesebestätigungen werden nur im Air-Gap-Modus benötigt.')),
      );
      return;
    }
    final myFp = await PairingService.getMyFingerprint();
    if (myFp == null) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text(
                'Kein Pairing-Fingerprint vorhanden – bitte zuerst Pairing einrichten.')),
      );
      return;
    }
    final keyManager = RSAKeyManager();
    final loaded = await keyManager.loadKeyPair();
    if (!loaded) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(content: Text('RSA-Key konnte nicht geladen werden.')),
      );
      return;
    }
    final priv = keyManager.getMyPrivateKey();
    if (priv == null) return;
    try {
      final blob = OfflineReceiptService.createReceipt(
        msgId: msg.id,
        chatId: widget.firestoreChatId,
        readerFingerprint: myFp,
        readerPrivateKey: priv,
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => QrDataSender(
          bytes: blob,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(content: Text('Receipt-Erstellung fehlgeschlagen: $e')),
      );
    }
  }

  /// Hilfsmethode: eine Zeile mit Label und Wert (für Info-Dialoge).
  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  // Schlanke Build-Methode, die das eigentliche UI delegiert.
  @override
  Widget build(BuildContext context) {
    // Tastatur-Höhe ermitteln und Sichtbarkeit ableiten
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // Tastatur gilt als sichtbar wenn viewInsets.bottom signifikant ist.
    // Wird als Basis für Button-Sichtbarkeit im Eingabebereich verwendet.
    final keyboardVisible = bottomInset > 50;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.blue,
        title: Row(
          children: [
            Flexible(
              child: Text(
                '💬 ${widget.chatGroupName}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            ChatTransportBadge(
              transport: _transport,
              encryption: currentEncryptionType,
              ecUsbOnly: ecUsbOnly,
              iconSize: 18,
            ),
          ],
        ),
        centerTitle: false, // Chat-Name links anzeigen
        actions: [
          // Chat-Verlauf löschen Button
          IconButton(
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            onPressed: _showDeleteChatDialog,
            tooltip: 'Chat-Verlauf löschen',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) async {
              if (value == 'reset') {
                if (selectedKeyFile != null) {
                  setState(() {
                    usedKeyBytes = 0;
                  });

                  // Byte-Position für die aktuelle Datei zurücksetzen
                  await _resetUsedKeyBytesForFile(selectedKeyFile!);
                }
              } else if (value == 'files') {
                _showAvailableFiles();
              } else if (value == 'settings') {
                _showSettingsDialog();
              } else if (value == 'toggle_base64') {
                setState(() => _showBase64InChat = !_showBase64InChat);
                _saveShowBase64();
              } else if (value == 'ec_file') {
                final ecFiles = await _getAvailableEcFiles(usbOnly: ecUsbOnly);
                _showEcFileAssignmentDialog(ecFiles);
              } else if (value == 'export_ec_usb') {
                await _exportSelectedEcFileToUsb();
              } else if (value == 'import_ec_usb_assign') {
                await _importEcFromUsbAndAssign();
              } else if (value == 'show_my_key') {
                _showMyPublicKeyQR();
              } else if (value == 'export_my_key') {
                await _exportMyPublicKeyAsFile();
              } else if (value == 'scan_contact_key') {
                _scanContactPublicKey(context);
              } else if (value == 'import_contact_key') {
                await _importContactKeyFromQGapAes();
                _loadContactKeyStatus();
              } else if (value == 'send_key_handshake') {
                await _sendMyPublicKeyHandshake();
              } else if (value == 'chat_info') {
                _showChatInfoDialog();
              } else if (value == 'send_invite') {
                await _showChatInviteDialog();
              } else if (value == 'relay_pairing') {
                Navigator.of(context).pop('relay_pairing');
              }
            },
            itemBuilder: (BuildContext context) => [
              PopupMenuItem<String>(
                value: 'settings',
                child: Row(
                  children: const [
                    Icon(Icons.settings, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Einstellungen',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'files',
                child: Row(
                  children: const [
                    Icon(QgapIcons.fileOpen, color: QgapColors.fileOpen, size: 20),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Verfügbare Dateien',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ),
              if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad)
                PopupMenuItem<String>(
                  value: 'reset',
                  child: Row(
                    children: const [
                      Icon(Icons.refresh, color: Colors.grey, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Byte-Position zurücksetzen',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              PopupMenuItem<String>(
                value: 'toggle_base64',
                child: Row(
                  children: [
                    Icon(
                      _showBase64InChat ? Icons.visibility : Icons.visibility_off,
                      color: Colors.grey,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _showBase64InChat
                            ? '🔐 Verschlüsselungs-Infos ausblenden'
                            : '🔐 Verschlüsselungs-Infos anzeigen',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ),
              if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad)
                PopupMenuItem<String>(
                  value: 'ec_file',
                  child: Row(
                    children: [
                      Icon(
                        selectedEcFile != null ? QgapIcons.lock : QgapIcons.lockOpen,
                        color: selectedEcFile != null ? Colors.green : Colors.orange,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          selectedEcFile != null
                              ? 'EC-Datei: $selectedEcFile'
                              : 'EC-Datei zuordnen',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad)
                PopupMenuItem<String>(
                  value: 'export_ec_usb',
                  enabled: selectedEcFile != null,
                  child: Row(
                    children: [
                      Icon(
                        Icons.usb,
                        color: selectedEcFile != null ? Colors.blue : Colors.grey,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          selectedEcFile != null
                              ? 'EC-Datei auf USB übertragen'
                              : 'EC-Datei auf USB übertragen (keine zugeordnet)',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad)
                PopupMenuItem<String>(
                  value: 'import_ec_usb_assign',
                  child: Row(
                    children: const [
                      Icon(Icons.usb, color: Colors.blue, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'EC-Datei von USB importieren & zuordnen',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              if (currentEncryptionType == qgap_model.EncryptionType.rsa ||
                  currentEncryptionType == qgap_model.EncryptionType.hybrid) ...[
                PopupMenuItem<String>(
                  value: 'show_my_key',
                  child: Row(
                    children: const [
                      Icon(QgapIcons.qrScan, color: QgapColors.qrScan, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Meinen Schlüssel zeigen (QR)',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'export_my_key',
                  child: Row(
                    children: const [
                      Icon(QgapIcons.fileShare, color: QgapColors.qrScan, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Meinen Schlüssel exportieren (.qgap_aes)',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'scan_contact_key',
                  child: Row(
                    children: const [
                      Icon(QgapIcons.keyContact, color: QgapColors.keyContact, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Kontakt-Schlüssel scannen (QR)',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'import_contact_key',
                  child: Row(
                    children: const [
                      Icon(QgapIcons.fileImport, color: QgapColors.keyContact, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Kontakt-Schlüssel importieren (.qgap_aes)',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.firestoreChatId != null)
                  PopupMenuItem<String>(
                    value: 'send_key_handshake',
                    child: Row(
                      children: const [
                        Icon(Icons.cloud_upload, color: Colors.blue, size: 20),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Meinen Key via Cloud senden',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
              // Einladung senden: für Online-Chats (RSA/AES, Hybrid über Firestore)
              // UND für Offline-EC-Chats (über lokale .qgap_ch-Datei mit Hinweis,
              // dass die zugehörige .qgap_ec separat per USB übertragen werden muss).
              PopupMenuItem<String>(
                value: 'send_invite',
                child: Row(
                  children: [
                    const Icon(Icons.person_add, color: Colors.teal, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        currentEncryptionType ==
                                    qgap_model.EncryptionType.oneTimePad &&
                                _transport != ChatTransport.online
                            ? 'EC-Einladung senden (Offline) 🔒'
                            : 'Online-Einladung senden ☁️',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ),
              if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad)
                const PopupMenuItem<String>(
                  value: 'relay_pairing',
                  child: Row(
                    children: [
                      Icon(Icons.compare_arrows, color: Colors.indigo, size: 20),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          'Relay-Pairing starten 📡',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ],
                  ),
                ),
              PopupMenuItem<String>(
                value: 'chat_info',
                child: Row(
                  children: const [
                    Icon(Icons.info_outline, color: Colors.blueGrey, size: 20),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Chat-Info',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Key-Info Anzeige
          if (currentEncryptionType == qgap_model.EncryptionType.rsa ||
              currentEncryptionType == qgap_model.EncryptionType.hybrid)
            Container(
              width: double.infinity,
              color: _hasContactKey ? Colors.green.shade50 : Colors.orange.shade50,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    currentEncryptionType == qgap_model.EncryptionType.hybrid
                        ? '🔐 Hybrid-Verschlüsselung (RSA + AES)'
                        : '🔐 RSA-Verschlüsselung',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue),
                  ),
                  const SizedBox(height: 4),
                  if (_hasContactKey)
                    Text(
                      '🔑 Kontaktschlüssel: $_chatContactName',
                      style: TextStyle(fontSize: 12, color: Colors.green.shade700),
                    )
                  else ...[
                    Text(
                      '⚠️ Kein Kontaktschlüssel importiert',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.orange.shade800),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await _scanContactPublicKey(context);
                              _loadContactKeyStatus();
                            },
                            icon: const Icon(QgapIcons.qrScan, size: 16),
                            label: const Text('QR scannen'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () async {
                              await _importContactKeyFromQGapAes();
                              _loadContactKeyStatus();
                            },
                            icon: const Icon(QgapIcons.fileAttach, size: 16),
                            label: const Text('.qgap_aes'),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12.0),
              color: Colors.blue.shade50,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '🔐 Aktuelle Verschlüsselungsdatei:',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.blue,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.blue),
                        ),
                        child: Text(
                          '📊 $usedKeyBytes Bytes verwendet',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    keyInfo,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue,
                    ),
                    textAlign: TextAlign.left,
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              shrinkWrap: true,
              itemCount: messages.length,
              itemBuilder: (context, index) {
                return Container(
                  margin: EdgeInsets.only(
                    left: messages[index].isMe
                        ? 60
                        : 0, // Eigene Nachrichten nach rechts einrücken
                    right: messages[index].isMe
                        ? 0
                        : 60, // Empfangene Nachrichten nach links einrücken
                    bottom: 8,
                  ),
                  child: ListTile(
                    onLongPress: () => _showMessageInfoDialog(messages[index]),
                    leading: messages[index].isMe
                        ? null // Eigene Nachrichten: kein Leading Icon
                        : const Icon(Icons
                            .computer), // Empfangene Nachrichten: Computer Icon links
                    trailing: messages[index].isMe
                        ? const Icon(Icons.person,
                            color: Colors
                                .green) // Eigene Nachrichten: Person Icon rechts
                        : null,
                    title: null, // Kein Titel für alle Nachrichten
                    subtitle: Column(
                      crossAxisAlignment: messages[index].isMe
                          ? CrossAxisAlignment
                              .end // Eigene Nachrichten rechtsbündig
                          : CrossAxisAlignment
                              .start, // Empfangene Nachrichten linksbündig
                      children: [
                        // Zeitstempel über der Nachricht anzeigen (mit
                        // WhatsApp-artigem Status-Häkchen für eigene Nachrichten)
                        Row(
                          mainAxisAlignment: messages[index].isMe
                              ? MainAxisAlignment.end
                              : MainAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Zeitstempel: ${messages[index].timestamp.toString().split('.').first}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                            if (messages[index].isMe) ...[
                              const SizedBox(width: 4),
                              _buildDeliveryStatusIcon(
                                  messages[index].deliveryStatus),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),

                        // Ursprünglicher Text prominent anzeigen
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12.0),
                          margin: const EdgeInsets.only(bottom: 8.0),
                          decoration: BoxDecoration(
                            color: messages[index].isMe
                                ? Colors.green.shade50
                                : Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: messages[index].isMe
                                    ? Colors.green.shade300
                                    : Colors.blue.shade300),
                          ),
                          child: Column(
                            crossAxisAlignment: messages[index].isMe
                                ? CrossAxisAlignment
                                    .end // Eigene Nachrichten rechtsbündig
                                : CrossAxisAlignment
                                    .start, // Empfangene Nachrichten linksbündig
                            children: [
                              // Datei-Nachricht anzeigen
                              if (messages[index].messageType ==
                                  qgap_model.MessageType.file) ...[                                Row(
                                  children: [
                                    Icon(QgapIcons.fileAttach,
                                        size: 22,
                                        color: messages[index].isMe
                                            ? Colors.green.shade700
                                            : Colors.blue.shade700),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        messages[index].attachmentFileName ??
                                            messages[index].originalText,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                if (messages[index].attachmentSize != null)
                                  Text(
                                    '${(messages[index].attachmentSize! / 1024).toStringAsFixed(1)} KB',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600),
                                  ),
                                if (!messages[index].isMe &&
                                    messages[index].attachmentLocalPath != null) ...[
                                  Text(
                                    '✅ Gespeichert: ${messages[index].attachmentLocalPath}',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.green.shade700),
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _openFileWithDefaultApp(
                                          messages[index].attachmentLocalPath!),
                                      icon: const Icon(Icons.open_in_new, size: 18),
                                      label: const Text('Datei öffnen'),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8, horizontal: 12),
                                        side: BorderSide(
                                            color: Colors.blue.shade300),
                                      ),
                                    ),
                                  ),
                                ],
                                // QR-Code und Teilen-Buttons für eigene Datei-Nachrichten
                                if (messages[index].isMe) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _showFullscreenQrCode(
                                          messages[index]),
                                      icon: Icon(QgapIcons.qrScan,
                                          size: 20,
                                          color: Colors.green.shade700),
                                      label: Text('QR-Code senden',
                                          style: TextStyle(
                                              color: Colors.green.shade700)),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12, horizontal: 16),
                                        backgroundColor: Colors.green.shade50,
                                        foregroundColor: Colors.green.shade700,
                                        side: BorderSide(
                                            color: Colors.green.shade300),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _shareAsQGapFile(
                                          messages[index].text),
                                      icon: Icon(QgapIcons.fileShare,
                                          size: 18,
                                          color: Colors.blue.shade700),
                                      label: Text('Als Datei teilen (.qgap)',
                                          style: TextStyle(
                                              color: Colors.blue.shade700,
                                              fontSize: 13)),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 10, horizontal: 16),
                                        side: BorderSide(
                                            color: Colors.blue.shade300),
                                      ),
                                    ),
                                  ),
                                ],
                              ] else if (messages[index].messageType ==
                                  qgap_model.MessageType.voice) ...[
                                // Sprachnachricht anzeigen
                                Row(
                                  children: [
                                    Icon(QgapIcons.mic,
                                        size: 22,
                                        color: messages[index].isMe
                                            ? Colors.red.shade700
                                            : Colors.blue.shade700),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        messages[index].attachmentFileName ??
                                            'Sprachnachricht',
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                if (messages[index].attachmentSize != null)
                                  Text(
                                    '${(messages[index].attachmentSize! / 1024).toStringAsFixed(1)} KB',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade600),
                                  ),
                                const SizedBox(height: 6),
                                // Wiedergabe-Button
                                if (messages[index].attachmentLocalPath != null)
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _playOrStopVoice(
                                          messages[index]),
                                      icon: Icon(
                                        _currentlyPlayingId ==
                                                messages[index].id
                                            ? Icons.stop_circle
                                            : Icons.play_circle,
                                        size: 22,
                                        color: Colors.blue.shade700,
                                      ),
                                      label: Text(
                                        _currentlyPlayingId ==
                                                messages[index].id
                                            ? 'Stopp'
                                            : 'Abspielen',
                                        style: TextStyle(
                                            color: Colors.blue.shade700),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 8, horizontal: 12),
                                        side: BorderSide(
                                            color: Colors.blue.shade300),
                                      ),
                                    ),
                                  ),
                                // QR-Code senden für eigene Sprachnachricht
                                if (messages[index].isMe) ...[
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _showFullscreenQrCode(
                                          messages[index]),
                                      icon: Icon(QgapIcons.qrScan,
                                          size: 20,
                                          color: Colors.green.shade700),
                                      label: Text('QR-Code senden',
                                          style: TextStyle(
                                              color: Colors.green.shade700)),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12, horizontal: 16),
                                        backgroundColor: Colors.green.shade50,
                                        foregroundColor: Colors.green.shade700,
                                        side: BorderSide(
                                            color: Colors.green.shade300),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: () => _shareVoiceAsQGapFile(
                                          messages[index]),
                                      icon: Icon(QgapIcons.fileShare,
                                          size: 18,
                                          color: Colors.blue.shade700),
                                      label: Text('Als .qgap teilen',
                                          style: TextStyle(
                                              color: Colors.blue.shade700)),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(
                                            color: Colors.blue.shade300),
                                      ),
                                    ),
                                  ),
                                ],
                              ] else if (messages[index].originalText == _kRelayMsgSentinel) ...[
                              // A→B Relay: Nachricht von Air-Gap A – QR-Code für Air-Gap B anbieten
                              Row(
                                children: [
                                  Icon(Icons.compare_arrows, size: 16, color: Colors.indigo.shade400),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      'Nachricht für Air-Gap B (weiterleiten):',
                                      style: TextStyle(fontSize: 13, color: Colors.indigo.shade700, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => _showFullscreenQrCode(messages[index]),
                                  icon: Icon(QgapIcons.qrScan, size: 20, color: Colors.green.shade700),
                                  label: Text('QR-Code für Air-Gap B', style: TextStyle(color: Colors.green.shade700)),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                    backgroundColor: Colors.green.shade50,
                                    foregroundColor: Colors.green.shade700,
                                    side: BorderSide(color: Colors.green.shade300),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () => _shareRelayMsgAsQGapFile(messages[index].text),
                                  icon: Icon(QgapIcons.fileShare, size: 18, color: Colors.blue.shade700),
                                  label: Text('Als Datei teilen (.qgap)', style: TextStyle(color: Colors.blue.shade700, fontSize: 13)),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                    side: BorderSide(color: Colors.blue.shade300),
                                  ),
                                ),
                              ),
                              ] else if (messages[index].originalText == _kRelayBtoASentinel) ...[
                              // B→A: Nachricht vom Tablet – QR-Code für Air-Gap anbieten
                              Row(
                                children: [
                                  Icon(Icons.qr_code, size: 16, color: Colors.teal.shade600),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      'Nachricht für Air-Gap:',
                                      style: TextStyle(fontSize: 13, color: Colors.teal.shade700, fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: () => _showFullscreenQrCode(messages[index]),
                                  icon: Icon(QgapIcons.qrScan, size: 20, color: Colors.green.shade700),
                                  label: Text('QR-Code anzeigen', style: TextStyle(color: Colors.green.shade700)),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                                    backgroundColor: Colors.green.shade50,
                                    foregroundColor: Colors.green.shade700,
                                    side: BorderSide(color: Colors.green.shade300),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: () => _shareAsQGapFile(messages[index].text),
                                  icon: Icon(QgapIcons.fileShare, size: 18, color: Colors.blue.shade700),
                                  label: Text('Als Datei teilen (.qgap)', style: TextStyle(color: Colors.blue.shade700, fontSize: 13)),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                                    side: BorderSide(color: Colors.blue.shade300),
                                  ),
                                ),
                              ),
                              ] else ...[                              // Label nur bei empfangenen Nachrichten anzeigen
                              if (!messages[index].isMe) ...[
                                if (_showBase64InChat) ...[
                                  Text(
                                    'Base64 - empfangen:',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.normal,
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    messages[index].text,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.normal,
                                    ),
                                    textAlign: TextAlign.left,
                                  ),
                                ] else ...[
                                  // Kompakte Ansicht: nur entschlüsselter Text, ohne Metadaten
                                  _buildDecryptedTextCompact(messages[index]),
                                ],
                              ],
                              if (messages[index].isMe) ...[
                                SelectableText(
                                  messages[index].originalText,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ],
                              ], // Ende else (kein Datei-Typ)
                              // Bei empfangenen Nachrichten: Verschlüsselungs-Infos (nur wenn eingeblendet)
                              if (!messages[index].isMe &&
                                  _showBase64InChat &&
                                  messages[index].originalText != _kRelayMsgSentinel &&
                                  messages[index].originalText != _kRelayBtoASentinel &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.file &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.voice) ...[
                                const SizedBox(height: 8),
                                const Divider(thickness: 1),
                                Text(
                                  'Verschlüsselungs - Infos:',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                _buildReceivedEncryptionInfo(messages[index]),
                              ],
                              // Bei eigenen Nachrichten: Verschlüsselungs-Infos anzeigen
                              if (messages[index].isMe &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.file &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.voice &&
                                  _showBase64InChat) ...[
                                const SizedBox(height: 8),
                                const Divider(thickness: 1),
                                const SizedBox(height: 4),
                                Text(
                                  '🔐 Verschlüsselt (zum Kopieren anklicken):',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green.shade700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                GestureDetector(
                                  onTap: () {
                                    // Der komplette Text mit Metadaten wird kopiert
                                    _copyToClipboard(messages[index].text);
                                  },
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      // Dateiname und Offset Info
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        margin:
                                            const EdgeInsets.only(bottom: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.green.shade50,
                                          borderRadius:
                                              BorderRadius.circular(3),
                                          border: Border.all(
                                              color: Colors.green.shade200),
                                        ),
                                        child: Text(
                                          _extractMetadataFromText(
                                              messages[index].text),
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: Colors.green.shade700,
                                            fontWeight: FontWeight.w500,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ),
                                      // Verschlüsselter Text (ohne Metadaten)
                                      Text(
                                        _extractEncryptedTextWithoutMetadata(
                                            messages[index].text),
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: Colors.grey,
                                          fontFamily: 'monospace',
                                        ),
                                        textAlign: TextAlign.right,
                                      ),
                                    ],
                                  ),
                                ),
                              ], // Ende if isMe && _showBase64InChat
                              // QR-Code Button und Teilen-Button immer anzeigen (unabhängig von _showBase64InChat)
                              if (messages[index].isMe &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.file &&
                                  messages[index].messageType !=
                                      qgap_model.MessageType.voice) ...[
                                const SizedBox(height: 8),
                                // QR-Code Button - nur anzeigen wenn Nachricht nicht zu lang ist
                                if (messageQrCodeAvailable[
                                        messages[index].id] ??
                                    true)
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: () => _showFullscreenQrCode(
                                          messages[index]),
                                      icon: Icon(
                                        QgapIcons.qrScan,
                                        size: 20,
                                        color: Colors.green.shade700,
                                      ),
                                      label: Text(
                                        'QR-Code anzeigen',
                                        style: TextStyle(
                                          color: Colors.green.shade700,
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 12, horizontal: 16),
                                        backgroundColor: Colors.green.shade50,
                                        foregroundColor: Colors.green.shade700,
                                        side: BorderSide(
                                            color: Colors.green.shade300),
                                      ),
                                    ),
                                  ),
                                // Als .qgap Datei teilen
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () => _shareAsQGapFile(
                                        messages[index].text),
                                    icon: Icon(
                                      QgapIcons.fileShare,
                                      size: 18,
                                      color: Colors.blue.shade700,
                                    ),
                                    label: Text(
                                      'Als Datei teilen (.qgap)',
                                      style: TextStyle(
                                          color: Colors.blue.shade700,
                                          fontSize: 13),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 10, horizontal: 16),
                                      side: BorderSide(
                                          color: Colors.blue.shade300),
                                    ),
                                  ),
                                ),
                                // Hinweis für zu lange Nachrichten
                                if (messageQrCodeAvailable[
                                        messages[index].id] ==
                                    false)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12, horizontal: 16),
                                    decoration: BoxDecoration(
                                      color: Colors.orange.shade50,
                                      border: Border.all(
                                          color: Colors.orange.shade300),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.warning_amber,
                                          size: 20,
                                          color: Colors.orange.shade700,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Nachricht zu lang für QR-Code - nur als Base64 kopierbar',
                                            style: TextStyle(
                                              color: Colors.orange.shade700,
                                              fontSize: 12,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ), // Ende von subtitle: Column
                  ), // Ende von ListTile
                ); // Ende von Container
              }, // Ende von itemBuilder
            ), // Ende von ListView.builder
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(8.0),
            child: SafeArea(
              child: Row(
                children: [
                  // Links: QR-Scanner Button (ausblenden wenn Tastatur sichtbar)
                  if (!keyboardVisible)
                    IconButton(
                      icon: const Icon(QgapIcons.qrScan, color: QgapColors.qrScan),
                      onPressed: _showQRScanner,
                      tooltip: 'QR-Code scannen',
                    ),
                  // Links: .qgap-Datei laden (ausblenden wenn Tastatur sichtbar)
                  if (!keyboardVisible)
                    IconButton(
                      icon: const Icon(QgapIcons.fileOpen, color: QgapColors.fileOpen),
                      onPressed: _loadQGapFileFromDisk,
                      tooltip: '.qgap Datei laden (USB / Google Drive)',
                    ),
                  // Textfeld – Key verhindert Neuerstellen wenn Row-Kinder sich ändern
                  Expanded(
                    key: const ValueKey('chat-input-expanded'),
                    child: CupertinoTextField(
                      controller: _textController,
                      focusNode: _inputFocusNode,
                      minLines: 1,
                      maxLines: 5,
                      placeholder: (currentEncryptionType !=
                                  qgap_model.EncryptionType.oneTimePad ||
                              selectedKeyFile != null)
                          ? 'Nachricht eingeben...'
                          : 'Keine Key-Datei zugeordnet',
                      enableInteractiveSelection: currentEncryptionType !=
                              qgap_model.EncryptionType.oneTimePad ||
                          selectedKeyFile != null,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (currentEncryptionType !=
                                  qgap_model.EncryptionType.oneTimePad ||
                              selectedKeyFile != null)
                          ? (_) => _sendMessage()
                          : null,
                    ),
                  ),
                  // Rechts: Büroklammer (Datei-Anhang) – ausblenden wenn Tastatur sichtbar
                  if (!keyboardVisible)
                    IconButton(
                      icon: const Icon(QgapIcons.fileAttach, color: QgapColors.fileAttach),
                      onPressed: _sendFileViaQR,
                      tooltip: 'Datei senden',
                    ),
                  // Rechts: Foto aufnehmen (Kamera) – ausblenden wenn Tastatur sichtbar
                  if (!keyboardVisible)
                    IconButton(
                      icon: const Icon(QgapIcons.camera, color: QgapColors.camera),
                      onPressed: (currentEncryptionType !=
                                  qgap_model.EncryptionType.oneTimePad ||
                              selectedKeyFile != null)
                          ? _takePhoto
                          : null,
                      tooltip: 'Foto aufnehmen',
                    ),
                  // Rechts: Mikrofon – ausblenden wenn Tastatur sichtbar
                  if (!keyboardVisible)
                    IconButton(
                      icon: const Icon(QgapIcons.mic, color: QgapColors.mic),
                      onPressed: (currentEncryptionType !=
                                  qgap_model.EncryptionType.oneTimePad ||
                              selectedKeyFile != null)
                          ? _showVoiceRecordSheet
                          : null,
                      tooltip: 'Sprachnachricht aufnehmen',
                    ),
                  // Rechts: Senden (nur anzeigen wenn Text vorhanden, unabhängig vom Fokus)
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textController,
                    builder: (_, value, __) {
                      final hasText = value.text.trim().isNotEmpty;
                      if (!hasText) return const SizedBox.shrink();
                      return IconButton(
                        icon: const Icon(QgapIcons.send, color: QgapColors.send),
                        onPressed: (currentEncryptionType !=
                                    qgap_model.EncryptionType.oneTimePad ||
                                selectedKeyFile != null)
                            ? _sendMessage
                            : null,
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Haupt-UI des Chat-Screens als ausgelagerte Methode
  // Keine separate Methode nötig, der Build verwendet den Getter _mainScaffold

  // Sequenzielle Initialisierung um sicherzustellen, dass Key-Datei zuerst geladen wird
  Future<void> _initializeChat() async {
    // Globale Einstellungen laden
    final prefsGlobal = await SharedPreferences.getInstance();
    setState(() {
      _showBase64InChat = prefsGlobal.getBool('global_show_base64') ?? false;
    });

    await _loadEncryptionType(); // Erst die gespeicherte Verschlüsselungsart laden
    await _loadSelectedKeyFile(); // Dann die zugewiesene Key-Datei laden
    await _loadEcSettings(); // EC-Datei-Einstellungen laden

    // Wenn keine Key-Datei zugeordnet ist, nur bei One-Time-Pad zwingend auswählen
    if (selectedKeyFile == null &&
        currentEncryptionType == qgap_model.EncryptionType.oneTimePad) {
      debugPrint('QGAP_CHAT: _initializeChat early return – no key file, pendingMeta=${widget.pendingMetadata}');
      // Historie trotzdem laden – sonst überschreibt ein späteres
      // _saveChatMessages() die gespeicherten Nachrichten mit leerer Liste.
      await _loadChatMessages();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showMandatoryKeyFileSelection();
      });
      return;
    }

    await _loadKeyInfo(); // Dann Key-Info mit der richtigen Datei laden (lädt auch _loadUsedKeyBytes)
    await _loadContactKeyStatus(); // Kontaktschlüssel-Status für RSA/Hybrid laden
    await _loadChatMessages(); // Schließlich Nachrichten laden

    // Beim Öffnen eines Chats immer ans Ende springen.
    _ensureScrollToBottom();

    // Verarbeite ausstehende Nachricht wenn vorhanden
    if (widget.pendingScannedData != null && widget.pendingMetadata != null) {
      developer.log('log: 📨 Ausstehende Nachricht gefunden im neuen Chat',
          name: '_initializeChat');
      developer.log(
          'log: 📱 Chat: ${widget.chatGroupName} (${widget.chatGroupId})',
          name: '_initializeChat');
      developer.log('log: 📋 Metadaten: ${widget.pendingMetadata}',
          name: '_initializeChat');
      developer.log(
          'log: 📄 Daten: ${widget.pendingScannedData!.length} Zeichen',
          name: '_initializeChat');

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        developer.log('log: ✅ Verarbeite ausstehende Nachricht...',
            name: '_initializeChat');
        final meta = widget.pendingMetadata!;
        final scanned = widget.pendingScannedData!;
        debugPrint('QGAP_CHAT: processing pending meta=$meta scannedLen=${scanned.length}');
        if (meta == 'QGAP_BINARY_VOICE') {
          // Binäres Sprachnachricht-Envelope (type=0x03) via .qgap-Datei empfangen
          debugPrint('QGAP_CHAT: → _processReceivedBinaryData (voice path)');
          developer.log(
              'log: 🎤 Verarbeite binäres Voice-Envelope aus .qgap-Datei',
              name: '_initializeChat');
          _processReceivedBinaryData(Uint8List.fromList(base64.decode(scanned)));
          return;
        }
        final firstPart = meta.split(';')[0];
        if (firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID') {
          final decrypted = await _decryptRsaHybridFromData(scanned, firstPart);
          _showDecryptErrorIfNeeded(decrypted);
          _addReceivedMessage(scanned, meta, decryptedText: decrypted);
        } else {
          // OTP: async entschlüsseln mit ECC-Code-Auflösung
          await _receiveFirestoreOtpText(scanned, meta);
        }
      });
    } else {
      developer.log('log: ℹ️ Keine ausstehende Nachricht vorhanden',
          name: '_initializeChat');
    }
  }

  // Lädt die diesem Chat zugewiesene Key-Datei
  Future<void> _loadSelectedKeyFile() async {
    final prefs = await SharedPreferences.getInstance();
    // fileNameOf heilt alte Zuordnungen mit Pfadresten (Windows-Backslash-Bug)
    final chatKeyFile = prefs.getString('chat_key_${widget.chatGroupId}');
    final cleanKeyFile =
        chatKeyFile != null ? AppStorage.fileNameOf(chatKeyFile) : null;
    developer.log(
        'log: Suche Key-Datei für Chat ${widget.chatGroupId}: $cleanKeyFile',
        name: '_loadSelectedKeyFile');

    if (cleanKeyFile != null && cleanKeyFile.isNotEmpty) {
      if (cleanKeyFile != chatKeyFile) {
        await prefs.setString('chat_key_${widget.chatGroupId}', cleanKeyFile);
      }
      setState(() {
        selectedKeyFile = cleanKeyFile;
      });
      developer.log(
          'log: ✅ Key-Datei für Chat ${widget.chatGroupId} geladen: $cleanKeyFile',
          name: '_loadSelectedKeyFile');
    } else {
      developer.log(
          'log: ⚠️ Keine Key-Datei für Chat ${widget.chatGroupId} gefunden - muss zugeordnet werden',
          name: '_loadSelectedKeyFile');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // EC-Datei (.qgap_ec) Unterstützung
  // ─────────────────────────────────────────────────────────────

  /// Lädt EC-Datei-Einstellungen aus SharedPreferences.
  Future<void> _loadEcSettings() async {
    final prefs = await SharedPreferences.getInstance();
    var ecFile = prefs.getString('chat_ec_file_${widget.chatGroupId}');
    // Fallback: ältere Chats speichern die Zuordnung nur unter chat_key_<id>.
    // Wenn dort eine .qgap_ec-Datei steht, übernehmen wir sie und migrieren
    // die Zuordnung nach chat_ec_file_<id>, damit das Hamburger-Menü
    // (USB-Export etc.) sie verwenden kann.
    if (ecFile == null || ecFile.isEmpty) {
      final keyFile = prefs.getString('chat_key_${widget.chatGroupId}');
      if (keyFile != null && keyFile.toLowerCase().endsWith('.qgap_ec')) {
        ecFile = keyFile;
        await prefs.setString('chat_ec_file_${widget.chatGroupId}', keyFile);
        developer.log(
            'log: 🔄 EC-Zuordnung aus chat_key_ migriert: $keyFile',
            name: '_loadEcSettings');
      }
    }
    // Offline-EC-Einladung: nur Code bekannt → nach passender lokaler
    // .qgap_ec-Datei suchen und automatisch zuordnen.
    if (ecFile == null || ecFile.isEmpty) {
      final code = prefs.getString('chat_ec_code_${widget.chatGroupId}');
      if (code != null && code.isNotEmpty) {
        final found = await EcKeyfileService.findEcFileByCode(code);
        if (found != null && found.isNotEmpty) {
          ecFile = found;
          await prefs.setString('chat_ec_file_${widget.chatGroupId}', found);
          await prefs.setString('chat_key_${widget.chatGroupId}', found);
          developer.log(
              'log: 🔑 EC-Datei via Code "$code" aufgelöst: $found',
              name: '_loadEcSettings');
        } else {
          developer.log(
              'log: ⏳ Warte auf USB-Import für EC-Code "$code" (Chat ${widget.chatGroupId})',
              name: '_loadEcSettings');
        }
      }
    }
    final usbOnly = prefs.getBool('chat_ec_usb_only_${widget.chatGroupId}') ?? false;
    if (mounted) {
      setState(() {
        selectedEcFile = ecFile;
        ecUsbOnly = usbOnly;
      });
    }
    developer.log(
        'log: EC-Einstellungen geladen: ecFile=$ecFile, ecUsbOnly=$usbOnly',
        name: '_loadEcSettings');
  }

  /// Speichert EC-Datei-Einstellungen in SharedPreferences.
  Future<void> _saveEcSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (selectedEcFile != null && selectedEcFile!.isNotEmpty) {
      await prefs.setString(
          'chat_ec_file_${widget.chatGroupId}', selectedEcFile!);
    } else {
      await prefs.remove('chat_ec_file_${widget.chatGroupId}');
    }
    await prefs.setBool(
        'chat_ec_usb_only_${widget.chatGroupId}', ecUsbOnly);
    developer.log(
        'log: EC-Einstellungen gespeichert: ecFile=$selectedEcFile, ecUsbOnly=$ecUsbOnly',
        name: '_saveEcSettings');
  }

  Future<void> _saveShowBase64() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('global_show_base64', _showBase64InChat);
  }

  /// Öffnet eine Datei mit der Standard-Android-App (Intent ACTION_VIEW).
  Future<void> _openFileWithDefaultApp(String path) async {
    final result = await OpenFile.open(path);
    if (result.type != ResultType.done && mounted) {
      showQgapSnackBar(context, 
        SnackBar(content: Text('Datei konnte nicht geöffnet werden: ${result.message}')),
      );
    }
  }

  /// Liefert alle externen Volume-Wurzeln via path_provider (inkl. USB OTG).
  /// Android gibt app-spezifische Pfade wie /storage/XXXX-XXXX/Android/data/.../files zurück;
  /// daraus wird der Volume-Root extrahiert.
  Future<List<String>> _getExternalVolumeRoots() async {
    final List<String> roots = [];

    // Methode 1: Nativer Platform Channel → StorageManager.getStorageVolumes()
    // Liefert zuverlässig alle Volumes inkl. USB OTG auch auf Samsung
    try {
      const storageChannel =
          MethodChannel('de.paulporg.obmc/storage');
      final List<dynamic>? nativeVolumes =
          await storageChannel.invokeMethod<List<dynamic>>('getStorageVolumes');
      if (nativeVolumes != null) {
        for (final v in nativeVolumes) {
          final path = v as String;
          if (!roots.contains(path)) {
            roots.add(path);
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler bei nativem getStorageVolumes: $e',
          name: '_getExternalVolumeRoots');
    }

    // Methode 2: path_provider (Fallback, oft nur internen Speicher)
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null) {
        for (final dir in dirs) {
          String path = dir.path;
          final idx = path.indexOf('/Android/');
          if (idx > 0) {
            path = path.substring(0, idx);
          }
          if (!roots.contains(path)) {
            roots.add(path);
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler bei getExternalStorageDirectories: $e',
          name: '_getExternalVolumeRoots');
    }

    _cachedVolumeRoots = roots; // Cache aktualisieren für sync Zugriff
    return roots;
  }

  /// Durchsucht Speicher nach .qgap_ec Dateien.
  /// Wenn [usbOnly] true ist, wird nur USB-Speicher durchsucht.
  Future<List<String>> _getAvailableEcFiles({bool? usbOnly}) async {
    final searchUsbOnly = usbOnly ?? ecUsbOnly;
    final List<Directory> searchDirs = [];

    if (!searchUsbOnly) {
      // Interner Speicher einschließen
      searchDirs.addAll([
        Directory(AppStorage.schluesselDir),
        Directory('/sdcard/Daten/QGap/schluessel'),
      ]);
    }

    // Statische USB-Pfade (inkl. Samsung ext_sd Symlink)
    searchDirs.addAll([
      Directory('/mnt/ext_sd/Daten/QGap/schluessel'),
      Directory('/storage/usbotg/Daten/QGap/schluessel'),
      Directory('/mnt/usb/Daten/QGap/schluessel'),
      Directory('/mnt/media_rw/usbotg/Daten/QGap/schluessel'),
    ]);

    // Dynamischer USB-Scan via /storage/
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
              searchDirs
                  .add(Directory('${entity.path}/Daten/QGap/schluessel'));
            }
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Scan von /storage/: $e',
          name: '_getAvailableEcFiles');
    }

    // Dynamischer USB-Scan via /mnt/media_rw/
    try {
      final mntDir = Directory('/mnt/media_rw');
      if (await mntDir.exists()) {
        await for (final entity in mntDir.list(followLinks: true)) {
          if (entity is Directory) {
            searchDirs
                .add(Directory('${entity.path}/Daten/QGap/schluessel'));
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Scan von /mnt/media_rw/: $e',
          name: '_getAvailableEcFiles');
    }

    // Dynamischer Scan via /mnt/ (Symlinks folgen, z.B. ext_sd -> USB)
    try {
      final mntRoot = Directory('/mnt');
      if (await mntRoot.exists()) {
        await for (final entity in mntRoot.list(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'shell' && name != 'knox' && name != 'vm') {
              final candidate =
                  Directory('${entity.path}/Daten/QGap/schluessel');
              if (!searchDirs.any((d) => d.path == candidate.path)) {
                searchDirs.add(candidate);
              }
            }
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Scan von /mnt/: $e',
          name: '_getAvailableEcFiles');
    }

    // Android path_provider: alle externen Volumes (inkl. USB OTG UUID-Pfade)
    for (final root in await _getExternalVolumeRoots()) {
      final candidate = Directory('$root/Daten/QGap/schluessel');
      if (!searchDirs.any((d) => d.path == candidate.path)) {
        searchDirs.add(candidate);
      }
    }

    final List<String> ecFiles = [];
    for (final dir in searchDirs) {
      try {
        if (await dir.exists()) {
          await for (final entity in dir.list()) {
            if (entity is File && entity.path.endsWith('.qgap_ec')) {
              final fileName = AppStorage.fileNameOf(entity.path);
              if (!ecFiles.contains(fileName)) {
                ecFiles.add(fileName);
              }
            }
          }
        }
      } catch (e) {
        developer.log('log: Fehler beim Lesen von ${dir.path}: $e',
            name: '_getAvailableEcFiles');
      }
    }

    developer.log(
        'log: .qgap_ec Dateien gefunden (usbOnly=$searchUsbOnly): $ecFiles',
        name: '_getAvailableEcFiles');
    return ecFiles;
  }

  /// Lädt die Bytes einer .qgap_ec Datei (synchron, respektiert ecUsbOnly).
  List<int> _loadEcFileSync(String ecFileName) {
    ecFileName = AppStorage.fileNameOf(ecFileName);
    final List<String> possiblePaths = [];

    if (!ecUsbOnly) {
      possiblePaths.addAll([
        AppStorage.keyFilePath(ecFileName),
        '/sdcard/Daten/QGap/schluessel/$ecFileName',
      ]);
    }

    // USB-Pfade (statisch, inkl. Samsung ext_sd Symlink)
    possiblePaths.addAll([
      '/mnt/ext_sd/Daten/QGap/schluessel/$ecFileName',
      '/storage/usbotg/Daten/QGap/schluessel/$ecFileName',
      '/mnt/usb/Daten/QGap/schluessel/$ecFileName',
      '/mnt/media_rw/usbotg/Daten/QGap/schluessel/$ecFileName',
    ]);

    // Dynamischer USB-Scan via /storage/
    try {
      final storageDir = Directory('/storage');
      if (storageDir.existsSync()) {
        for (final entity in storageDir.listSync(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' &&
                name != 'self' &&
                !name.startsWith('.')) {
              possiblePaths.add(
                  '${entity.path}/Daten/QGap/schluessel/$ecFileName');
            }
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Scan (EC sync /storage/): $e',
          name: '_loadEcFileSync');
    }

    // Dynamischer Scan via /mnt/
    try {
      final mntRoot = Directory('/mnt');
      if (mntRoot.existsSync()) {
        for (final entity in mntRoot.listSync(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'shell' && name != 'knox' && name != 'vm') {
              final p = '${entity.path}/Daten/QGap/schluessel/$ecFileName';
              if (!possiblePaths.contains(p)) {
                possiblePaths.add(p);
              }
            }
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Scan (EC sync /mnt/): $e',
          name: '_loadEcFileSync');
    }

    // Gecachte externe Volumes (inkl. USB OTG UUID-Pfade via path_provider)
    for (final root in _cachedVolumeRoots) {
      final p = '$root/Daten/QGap/schluessel/$ecFileName';
      if (!possiblePaths.contains(p)) {
        possiblePaths.add(p);
      }
    }

    for (final path in possiblePaths) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          final bytes = file.readAsBytesSync();
          developer.log(
              'log: .qgap_ec Datei geladen: $path (${bytes.length} Bytes)',
              name: '_loadEcFileSync');
          return bytes;
        }
      } catch (e) {
        developer.log('log: Fehler beim Laden von $path: $e',
            name: '_loadEcFileSync');
      }
    }

    developer.log(
        'log: .qgap_ec Datei "$ecFileName" nicht gefunden (usbOnly=$ecUsbOnly)',
        name: '_loadEcFileSync');
    return [];
  }

  /// Erstellt einen ausfuehrlichen USB-Diagnose-Report (fuer In-App-Anzeige).
  Future<String> _runUsbDiagnostics() async {
    final sb = StringBuffer();
    sb.writeln('USB-Diagnose  ${DateTime.now().toIso8601String()}');
    sb.writeln('Erwartet: Daten/QGap/schluessel/*.qgap_ec');
    sb.writeln('─' * 40);

    // /storage/ durchsuchen
    sb.writeln('\n/storage/ Eintraege:');
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final e in storageDir.list()) {
          final name = e.path.split('/').last;
          sb.writeln('  [$name]');
          if (e is Directory) {
            final sub = Directory('${e.path}/Daten/QGap/schluessel');
            final subExists = await sub.exists();
            sb.writeln('    Daten/QGap/schluessel: ${subExists ? "VORHANDEN" : "nicht vorhanden"}');
            if (subExists) {
              await for (final f in sub.list()) {
                sb.writeln('      -> ${f.path.split("/").last}');
              }
            }
          }
        }
      } else {
        sb.writeln('  /storage/ existiert nicht!');
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // /mnt/media_rw/ durchsuchen
    sb.writeln('\n/mnt/media_rw/ Eintraege:');
    try {
      final mntDir = Directory('/mnt/media_rw');
      if (await mntDir.exists()) {
        await for (final e in mntDir.list()) {
          final name = e.path.split('/').last;
          sb.writeln('  [$name]');
          if (e is Directory) {
            final sub = Directory('${e.path}/Daten/QGap/schluessel');
            final subExists = await sub.exists();
            sb.writeln('    Daten/QGap/schluessel: ${subExists ? "VORHANDEN" : "nicht vorhanden"}');
            if (subExists) {
              await for (final f in sub.list()) {
                sb.writeln('      -> ${f.path.split("/").last}');
              }
            }
          }
        }
      } else {
        sb.writeln('  /mnt/media_rw/ existiert nicht!');
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // /mnt/ Top-Level
    sb.writeln('\n/mnt/ Eintraege (Top-Level):');
    try {
      final mntTop = Directory('/mnt');
      if (await mntTop.exists()) {
        await for (final e in mntTop.list()) {
          final isDir = e is Directory;
          sb.writeln('  ${e.path.split("/").last} [${isDir ? "DIR" : "FILE"}]');
        }
      } else {
        sb.writeln('  /mnt/ existiert nicht!');
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // Berechtigungsstatus
    sb.writeln('\nBerechtigungen:');
    try {
      final manageStatus = await Permission.manageExternalStorage.status;
      final storageStatus = await Permission.storage.status;
      sb.writeln('  manageExternalStorage: $manageStatus');
      sb.writeln('  storage: $storageStatus');
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // /mnt/ext_sd direkt testen (Samsung USB-Symlink)
    sb.writeln('\n/mnt/ext_sd direkt:');
    try {
      final extSdType =
          await FileSystemEntity.type('/mnt/ext_sd', followLinks: true);
      sb.writeln('  Typ (followLinks): $extSdType');
      final schluessel =
          Directory('/mnt/ext_sd/Daten/QGap/schluessel');
      final skExists = await schluessel.exists();
      sb.writeln('  Daten/QGap/schluessel: ${skExists ? "VORHANDEN" : "nicht vorhanden"}');
      if (skExists) {
        await for (final f in schluessel.list()) {
          sb.writeln('    -> ${f.path.split("/").last}');
        }
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // Statische USB-Pfade
    sb.writeln('\nStatische USB-Pfade:');
    for (final path in [
      '/mnt/ext_sd/Daten/QGap/schluessel',
      '/storage/usbotg/Daten/QGap/schluessel',
      '/mnt/usb/Daten/QGap/schluessel',
      '/mnt/media_rw/usbotg/Daten/QGap/schluessel',
    ]) {
      final dir = Directory(path);
      final exists = await dir.exists();
      sb.writeln('  ${exists ? "[OK]" : "[--]"} $path');
      if (exists) {
        try {
          await for (final f in dir.list()) {
            sb.writeln('       -> ${f.path.split("/").last}');
          }
        } catch (e) {
          sb.writeln('       FEHLER: $e');
        }
      }
    }

    // path_provider: externe Volumes (inkl. USB OTG)
    sb.writeln('\npath_provider externe Volumes:');
    try {
      final roots = await _getExternalVolumeRoots();
      if (roots.isEmpty) {
        sb.writeln('  keine gefunden');
      } else {
        for (final root in roots) {
          sb.writeln('  $root');
          final schluessel = Directory('$root/Daten/QGap/schluessel');
          final skExists = await schluessel.exists();
          sb.writeln('    Daten/QGap/schluessel: ${skExists ? "VORHANDEN" : "nicht vorhanden"}');
          if (skExists) {
            await for (final f in schluessel.list()) {
              sb.writeln('      -> ${f.path.split("/").last}');
            }
          }
        }
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    // Gesamt-Ergebnis
    sb.writeln('\nGefundene .qgap_ec Dateien:');
    try {
      final found = await _getAvailableEcFiles(usbOnly: false);
      if (found.isEmpty) {
        sb.writeln('  KEINE GEFUNDEN');
      } else {
        for (final f in found) {
          sb.writeln('  OK  $f');
        }
      }
    } catch (e) {
      sb.writeln('  FEHLER: $e');
    }

    return sb.toString();
  }

  /// Zeigt Dialog zur Auswahl/Zuordnung einer .qgap_ec Datei für diesen Chat.
  Future<void> _showEcFileAssignmentDialog(List<String> ecFiles) async {
    if (!mounted) return;
    // Aktuell zugeordnete Datei vorauswählen; falls nicht in Liste → erste der Liste
    String? chosen = (selectedEcFile != null && ecFiles.contains(selectedEcFile))
        ? selectedEcFile
        : (ecFiles.isNotEmpty ? ecFiles.first : null);

    // Provenance-Flags vorladen für Anzeige im Dropdown
    final Map<String, String?> provenance = {};
    for (final f in ecFiles) {
      provenance[f] = await EcProvenanceService.getProvenance(f);
    }

    String provLabel(String? p) {
      switch (p) {
        case 'usb':     return '🔒 ';
        case 'digital': return '⚠️ ';
        default:        return '❔ ';
      }
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('🔑 Einmal-Code Datei (.qgap_ec)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    ecFiles.isNotEmpty
                        ? 'Gefundene .qgap_ec Dateien.\n'
                            'Bitte eine Datei für diesen Chat wählen:\n'
                            '🔒 = sicher per USB importiert · ⚠️ = digital empfangen · ❔ = unbekannt\n'
                            '🎲 = EC-Code (eindeutige Kennung der Schlüsseldatei)'
                        : 'Keine .qgap_ec Dateien gefunden.\n'
                            'USB-Stick eingesteckt? Pfad prüfen:\n'
                            'Daten/QGap/schluessel/*.qgap_ec'),
                const SizedBox(height: 12),
                if (ecFiles.isEmpty)
                  Text('Keine Dateien gefunden.',
                      style: TextStyle(color: Colors.red.shade700,
                          fontWeight: FontWeight.w600))
                else
                  DropdownButton<String>(
                    value: chosen,
                    isExpanded: true,
                    items: ecFiles
                        .map((f) {
                          final code =
                              EcKeyfileService.extractCodeFromFilename(f);
                          final codePart =
                              code != null ? '🎲 $code  —  ' : '🎲 (kein Code)  —  ';
                          return DropdownMenuItem(
                            value: f,
                            child: Text(
                              '${provLabel(provenance[f])}$codePart$f',
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        })
                        .toList(),
                    onChanged: (v) => setDialogState(() => chosen = v),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Switch(
                      value: ecUsbOnly,
                      onChanged: (v) => setDialogState(() => ecUsbOnly = v),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Nur von USB laden\n(Sicherheitsmodus)',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
                // Im USB-only-Modus: Datei direkt vom Datei-Picker (USB) wählen
                if (ecUsbOnly)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.usb, size: 16),
                      label: const Text('Datei von USB wählen'),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _pickEcFileFromDisk();
                      },
                    ),
                  ),
              ],
            ),
            actions: [
              // USB-Diagnose Button
              TextButton.icon(
                icon: const Icon(Icons.search, size: 16),
                label: const Text('USB-Diagnose'),
                onPressed: () async {
                  final report = await _runUsbDiagnostics();
                  if (!ctx.mounted) return;
                  showDialog(
                    context: ctx,
                    builder: (_) => AlertDialog(
                      title: const Text('🔍 USB-Diagnose'),
                      content: SizedBox(
                        width: double.maxFinite,
                        child: SingleChildScrollView(
                          child: SelectableText(
                            report,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Schließen'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Überspringen'),
              ),
              TextButton(
                onPressed: chosen == null
                    ? null
                    : () async {
                        setState(() {
                          selectedEcFile = chosen;
                          // .qgap_ec ist die tatsächlich verwendete Schlüsseldatei —
                          // muss synchron bleiben, sonst verschlüsselt der Chat
                          // weiterhin mit der alten Datei.
                          selectedKeyFile = chosen;
                        });
                        await _saveEcSettings();
                        await _saveSelectedKeyFile();
                        await _loadKeyInfo();
                        if (ctx.mounted) Navigator.of(ctx).pop();
                        // Nach EC-Wechsel geparkte Nachrichten erneut versuchen.
                        unawaited(_retryParkedMessages());
                      },
                child: const Text('Zuordnen'),
              ),
            ],
          );
        });
      },
    );
  }

  // Zeigt zwingenden Key-Datei-Auswahl-Dialog beim ersten Chat-Start
  void _showMandatoryKeyFileSelection() async {
    List<String> availableFiles = await _getUnassignedKeyFiles();

    if (availableFiles.isEmpty) {
      developer.log(
          'log: Keine unzugeordneten QGap-Key-Dateien gefunden für Zwangszuordnung',
          name: '_showMandatoryKeyFileSelection');

      // Zeige Dialog mit Hinweis, dass Key-Dateien benötigt werden
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) {
          return AlertDialog(
            title: const Text('⚠️ Keine Key-Dateien gefunden'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Für diesen Chat ist noch keine Verschlüsselungsdatei zugeordnet.\n\n'
                    'Alle verfügbaren .qgap_ec Dateien sind bereits anderen Chats zugewiesen.\n\n'
                    'Bitte erstellen Sie eine neue Datei oder importieren Sie eine .qgap_ec Datei vom USB-Stick.'),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showCreateRandomFileDialogFromHomeScreen();
                    },
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Zufallsdatei erstellen'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _importEcKeyFromFile();
                    },
                    icon: const Icon(Icons.usb),
                    label: const Text('Von USB-Stick importieren (.qgap_ec)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  Navigator.of(context).pop(); // Zurück zum HomeScreen
                },
                child: const Text('Zurück'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  // Versuche erneut nach Key-Dateien zu suchen
                  _showMandatoryKeyFileSelection();
                },
                child: const Text('Erneut versuchen'),
              ),
            ],
          );
        },
      );
      return;
    }

    // Zwingender Key-Datei-Auswahl-Dialog
    String selectedFile = availableFiles.first;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title:
                  Text('🔐 Key-Datei für "${widget.chatGroupName}" zuordnen'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Für diesen Chat muss eine Verschlüsselungsdatei zugeordnet werden:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 15),
                  DropdownButton<String>(
                    value: selectedFile,
                    isExpanded: true,
                    items: availableFiles.map((String fileName) {
                      return DropdownMenuItem<String>(
                        value: fileName,
                        child: Text(fileName),
                      );
                    }).toList(),
                    onChanged: (String? newValue) {
                      setDialogState(() {
                        selectedFile = newValue ?? availableFiles.first;
                      });
                    },
                  ),
                  const SizedBox(height: 15),
                  // Button zum Erstellen einer Zufallsdatei
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop(); // Aktuellen Dialog schließen
                      // Sofort den Dialog zur Dateierstellung öffnen
                      _showCreateRandomFileDialogFromHomeScreen();
                    },
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Zufallsdatei erstellen'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    Navigator.of(context).pop(); // Zurück zum HomeScreen
                  },
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    setState(() {
                      selectedKeyFile = selectedFile;
                    });

                    await _saveSelectedKeyFile();
                    Navigator.of(context).pop();

                    // Jetzt Chat vollständig initialisieren
                    await _loadKeyInfo();
                    await _loadChatMessages();

                    // Nach dem Laden zum Ende scrollen
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        _scrollController
                            .jumpTo(_scrollController.position.maxScrollExtent);
                      }
                    });
                  },
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Zuordnen'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Speichert die Key-Datei-Zuordnung für diesen Chat
  Future<void> _saveSelectedKeyFile() async {
    if (selectedKeyFile == null) {
      return; // Nur speichern wenn Key-Datei gesetzt ist
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_key_${widget.chatGroupId}', selectedKeyFile!);

    // Finde und speichere den Ort der Schlüsseldatei
    String? filePath = await _findKeyFileLocation(selectedKeyFile!);
    if (filePath != null) {
      await prefs.setString(
          'chat_key_location_${widget.chatGroupId}', filePath);
      developer.log('log: 📍 Schlüsseldatei-Ort gespeichert: $filePath',
          name: '_saveSelectedKeyFile');
    }

    developer.log(
        'log: ✅ Key-Datei für Chat ${widget.chatGroupId} gespeichert: $selectedKeyFile',
        name: '_saveSelectedKeyFile');

    // Zur Sicherheit nochmal prüfen, ob es gespeichert wurde
    final verifyFile = prefs.getString('chat_key_${widget.chatGroupId}');
    developer.log('log: 🔍 Verifikation - gespeicherte Datei: $verifyFile',
        name: '_saveSelectedKeyFile');
  }

  /// Importiert eine .qgap_ec Schlüsseldatei AUSSCHLIESSLICH vom USB-Stick
  /// (kein System-FilePicker mit Drive/Quickshare). Listet alle .qgap_ec-
  /// Dateien aus `<USB>/Daten/QGap/schluessel/` auf, kopiert die gewählte
  /// in den lokalen Schlüsselordner und ruft anschließend die
  /// Mandatory-Selection erneut auf.
  Future<void> _importEcKeyFromFile() async {
    final fileName = await _pickAndCopyEcFromUsbSaf();
    if (fileName == null) return;
    if (mounted) {
      showQgapSnackBar(context,
        SnackBar(
          content: Text('✅ $fileName von USB importiert'),
          backgroundColor: Colors.green,
        ),
      );
      _showMandatoryKeyFileSelection();
    }
  }

  /// Gemeinsamer SAF-Importflow:
  /// 1) stellt sicher, dass der USB-Stick gekoppelt ist (öffnet ggf. Picker),
  /// 2) listet .qgap_ec-Dateien unter `Daten/QGap/schluessel/`,
  /// 3) liest die ausgewählte Datei und kopiert sie nach
  ///    `/storage/emulated/0/Daten/QGap/schluessel/<filename>`,
  /// 4) markiert die Provenance als USB.
  /// Liefert den lokalen Dateinamen (ohne Pfad) oder `null`.
  Future<String?> _pickAndCopyEcFromUsbSaf() async {
    // ── Windows/iOS: Datei-Dialog statt SAF (USB = Laufwerk bzw. Dateien-App) ─
    if (!Platform.isAndroid) {
      try {
        FilePickerResult? result;
        try {
          result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['qgap_ec'],
            allowMultiple: false,
            withData: true,
            dialogTitle: '.qgap_ec Datei wählen (z. B. vom USB-Stick)',
          );
        } catch (_) {
          result = await FilePicker.platform.pickFiles(
            type: FileType.any,
            allowMultiple: false,
            withData: true,
          );
        }
        if (result == null || result.files.isEmpty) return null;
        final picked = result.files.first;
        if (!picked.name.toLowerCase().endsWith('.qgap_ec')) {
          if (mounted) {
            showQgapSnackBar(context,
              SnackBar(content: Text(
                  'Nur .qgap_ec-Dateien unterstützt (gewählt: ${picked.name})')),
            );
          }
          return null;
        }
        final data = picked.bytes ??
            (picked.path != null
                ? await File(picked.path!).readAsBytes()
                : null);
        if (data == null || data.isEmpty) {
          if (mounted) {
            showQgapSnackBar(context,
              const SnackBar(content: Text('Datei konnte nicht gelesen werden')),
            );
          }
          return null;
        }
        final targetDir = Directory(AppStorage.schluesselDir);
        await targetDir.create(recursive: true);
        final targetFile = File('${targetDir.path}/${picked.name}');
        await targetFile.writeAsBytes(data, flush: true);
        await EcProvenanceService.markUsbImport(picked.name);
        return picked.name;
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('Fehler beim Importieren: $e')),
          );
        }
        return null;
      }
    }

    // (1) Kopplung sicherstellen
    if (!await UsbSafService.hasTreeUri()) {
      if (!mounted) return null;
      final pick = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('USB-Stick koppeln'),
          content: const Text(
            'Damit die App vom USB-Stick lesen darf, musst du ihn einmalig '
            'im System-Dialog auswählen.\n\n'
            'Tippe auf „Auswählen", navigiere zum USB-Stick und tippe oben '
            'rechts auf „DIESEN ORDNER VERWENDEN".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.usb),
              label: const Text('Auswählen'),
            ),
          ],
        ),
      );
      if (pick != true) return null;
      try {
        final picked = await UsbSafService.pickUsbTreeUri();
        if (picked == null || picked.isEmpty) return null;
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('USB-Auswahl fehlgeschlagen: $e')),
          );
        }
        return null;
      }
    }

    // (2) Listing
    List<UsbSafFile> safEntries;
    try {
      safEntries = await UsbSafService.listUsbDir(
        subPath: 'Daten/QGap/schluessel',
        suffix: '.qgap_ec',
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context,
          SnackBar(content: Text('Fehler beim Lesen des USB-Sticks: $e')),
        );
      }
      return null;
    }
    if (safEntries.isEmpty) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Keine .qgap_ec auf USB'),
            content: const Text(
              'Auf dem gekoppelten USB-Stick wurden keine .qgap_ec-Dateien '
              'im Ordner „Daten/QGap/schluessel/" gefunden.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return null;
    }

    // (3) Auswahl
    if (!mounted) return null;
    final selected = await showDialog<UsbSafFile>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('.qgap_ec Datei von USB wählen'),
        children: [
          for (final f in safEntries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(f),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.usb, color: Colors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${f.name}\n  (${f.size} B)',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
        ],
      ),
    );
    if (selected == null) return null;

    // (4) Lesen + lokal ablegen + Provenance markieren
    try {
      final bytes = await UsbSafService.readUsbFile(selected.uri);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showQgapSnackBar(context,
            const SnackBar(content: Text('Datei konnte nicht gelesen werden')),
          );
        }
        return null;
      }
      final fileName = selected.name;
      final targetDir =
          Directory(AppStorage.schluesselDir);
      await targetDir.create(recursive: true);
      final targetFile = File('${targetDir.path}/$fileName');
      await targetFile.writeAsBytes(bytes, flush: true);
      await EcProvenanceService.markUsbImport(fileName);
      developer.log(
          'log: ✅ .qgap_ec via SAF importiert: $fileName (${bytes.length} Bytes)',
          name: '_pickAndCopyEcFromUsbSaf');
      return fileName;
    } catch (e) {
      developer.log('log: Fehler beim SAF-Importieren: $e',
          name: '_pickAndCopyEcFromUsbSaf');
      if (mounted) {
        showQgapSnackBar(context,
          SnackBar(content: Text('Fehler beim Importieren: $e')),
        );
      }
      return null;
    }
  }

  /// Öffnet den Datei-Picker um eine .qgap_ec Datei direkt diesem Chat zuzuordnen
  /// (z. B. von USB im Sicherheitsmodus, ohne sie zu kopieren).
  Future<void> _pickEcFileFromDisk() async {
    try {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['qgap_ec'],
          allowMultiple: false,
          withData: false,
          dialogTitle: '.qgap_ec Datei von USB wählen',
        );
      } catch (e) {
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: false,
        );
      }
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (!picked.name.toLowerCase().endsWith('.qgap_ec')) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Nur .qgap_ec-Dateien unterstützt (gewählt: ${picked.name})')),
          );
        }
        return;
      }
      // Provenance markieren (nur USB-Pfade gelten als sicher)
      final src = picked.path ?? '';
      if (EcProvenanceService.isUsbPath(src)) {
        await EcProvenanceService.markUsbImport(picked.name);
      } else {
        await EcProvenanceService.markDigitalImport(picked.name);
      }
      setState(() {
        selectedEcFile = picked.name;
        selectedKeyFile = picked.name;
      });
      await _saveEcSettings();
      await _saveSelectedKeyFile();
      await _loadKeyInfo();
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('✅ EC-Datei "${picked.name}" zugeordnet'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Wählen der EC-Datei: $e')),
        );
      }
    }
  }

  /// Lokalisiert die aktuell zugeordnete EC-Datei in den bekannten Verzeichnissen
  /// (interner Speicher + USB) und gibt den ersten vorhandenen Pfad zurück.
  Future<String?> _locateEcFilePath(String fileName) async {
    fileName = AppStorage.fileNameOf(fileName);
    final List<String> candidates = [
      AppStorage.keyFilePath(fileName),
      '/sdcard/Daten/QGap/schluessel/$fileName',
      '/mnt/ext_sd/Daten/QGap/schluessel/$fileName',
      '/storage/usbotg/Daten/QGap/schluessel/$fileName',
      '/mnt/usb/Daten/QGap/schluessel/$fileName',
      '/mnt/media_rw/usbotg/Daten/QGap/schluessel/$fileName',
    ];
    // Dynamische USB/SD-Pfade einsammeln
    final List<String> dynamicRoots = [];
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list(followLinks: true)) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
              dynamicRoots.add(entity.path);
            }
          }
        }
      }
    } catch (_) {}
    try {
      final mntRw = Directory('/mnt/media_rw');
      if (await mntRw.exists()) {
        await for (final entity in mntRw.list(followLinks: true)) {
          if (entity is Directory) {
            dynamicRoots.add(entity.path);
          }
        }
      }
    } catch (_) {}
    for (final root in dynamicRoots) {
      candidates.add('$root/Daten/QGap/schluessel/$fileName');
    }
    for (final root in await _getExternalVolumeRoots()) {
      candidates.add('$root/Daten/QGap/schluessel/$fileName');
    }
    for (final path in candidates) {
      try {
        final f = File(path);
        if (await f.exists()) return path;
      } catch (_) {}
    }
    return null;
  }

  /// Exportiert die aktuell zugeordnete .qgap_ec-Datei direkt auf einen
  /// erkannten USB-Stick (ohne System-Share-Dialog mit Drive/Quickshare).
  /// Bei mehreren USB-Volumes erscheint ein Auswahldialog.
  Future<void> _exportSelectedEcFileToUsb() async {
    final fileName = selectedEcFile;
    if (fileName == null || fileName.isEmpty) {
      if (mounted) {
        showQgapSnackBar(context,
          const SnackBar(content: Text('Diesem Chat ist keine EC-Datei zugeordnet.')),
        );
      }
      return;
    }
    final fullPath = await _locateEcFilePath(fileName);
    if (fullPath == null) {
      if (mounted) {
        showQgapSnackBar(context,
          SnackBar(content: Text('EC-Datei "$fileName" nicht gefunden (weder lokal noch auf USB).')),
        );
      }
      return;
    }

    // ── Windows/iOS: USB ist normales Laufwerk bzw. Dateien-App → Speichern-Dialog ─
    if (!Platform.isAndroid) {
      try {
        final bytes = await File(fullPath).readAsBytes();
        if (!mounted) return;
        await ShareService.saveAsFile(context, fileName, bytes);
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('Fehler beim Export: $e')),
          );
        }
      }
      return;
    }

    // ── 1) SAF-Weg (Android 11+): USB-OTG-Stick über Storage Access Framework ─
    // Wenn noch nicht gekoppelt: System-Picker öffnen und Tree-Uri dauerhaft
    // speichern. Andernfalls darf die App nicht auf den USB-Stick zugreifen.
    bool hasUsb = await UsbSafService.hasTreeUri();
    if (!hasUsb) {
      if (!mounted) return;
      final pick = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('USB-Stick koppeln'),
          content: const Text(
            'Damit die App auf den USB-Stick schreiben darf, musst du ihn '
            'einmalig im System-Dialog auswählen.\n\n'
            'Tippe auf „Auswählen", navigiere zum USB-Stick und tippe oben '
            'rechts auf „DIESEN ORDNER VERWENDEN".',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Abbrechen'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(ctx).pop(true),
              icon: const Icon(Icons.usb),
              label: const Text('Auswählen'),
            ),
          ],
        ),
      );
      if (pick != true) return;
      try {
        final picked = await UsbSafService.pickUsbTreeUri();
        if (picked == null || picked.isEmpty) {
          if (mounted) {
            showQgapSnackBar(context,
              const SnackBar(content: Text('USB-Auswahl abgebrochen.')),
            );
          }
          return;
        }
        hasUsb = true;
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('USB-Auswahl fehlgeschlagen: $e')),
          );
        }
        return;
      }
    }

    // SAF-Schreibweg
    try {
      final source = File(fullPath);
      if (!await source.exists()) {
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('Quelldatei nicht gefunden: $fullPath')),
          );
        }
        return;
      }
      final bytes = await source.readAsBytes();
      final written = await UsbSafService.writeUsbFile(
        subPath: 'Daten/QGap/schluessel',
        fileName: fileName,
        bytes: bytes,
        mime: 'application/octet-stream',
      );
      developer.log(
          'log: ✅ EC-Datei via SAF auf USB geschrieben: ${written.uri} (${written.size} Bytes)',
          name: '_exportSelectedEcFileToUsb');
      if (mounted) {
        showQgapSnackBar(context,
          SnackBar(
            content: Text(
              '✅ "$fileName" auf USB geschrieben\n'
              '${written.size} Bytes',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
      return;
    } on PlatformException catch (e) {
      // Häufige Ursache: Tree-Uri gehört zu falschem Volume (z. B. interner Speicher).
      developer.log(
          'log: ❌ SAF-Schreibfehler: code=${e.code} msg=${e.message}',
          name: '_exportSelectedEcFileToUsb');
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Schreibfehler auf USB'),
            content: Text(
              'Die EC-Datei konnte nicht auf den gekoppelten USB-Stick '
              'geschrieben werden.\n\n'
              'Code: ${e.code}\n${e.message ?? ''}\n\n'
              'Tipp: Im Home-Screen unter „🔍 USB-Speicher Debug" die '
              'USB-Kopplung zurücksetzen und den Stick neu auswählen.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    } catch (e) {
      developer.log('log: Fehler beim SAF-Schreiben auf USB: $e',
          name: '_exportSelectedEcFileToUsb');
      if (mounted) {
        showQgapSnackBar(context,
          SnackBar(content: Text('Fehler beim Schreiben auf USB: $e')),
        );
      }
      return;
    }
  }

  /// Importiert eine .qgap_ec Datei AUSSCHLIESSLICH vom USB-Stick
  /// (kein System-FilePicker), kopiert sie in den lokalen Schlüsselordner
  /// und ordnet sie direkt diesem Chat zu.
  Future<void> _importEcFromUsbAndAssign() async {
    final fileName = await _pickAndCopyEcFromUsbSaf();
    if (fileName == null) return;
    setState(() {
      selectedEcFile = fileName;
      selectedKeyFile = fileName;
      ecUsbOnly = false; // Datei liegt jetzt lokal
    });
    await _saveEcSettings();
    await _saveSelectedKeyFile();
    await _loadKeyInfo();
    developer.log(
        'log: ✅ .qgap_ec via SAF importiert + Chat ${widget.chatGroupId} zugeordnet: $fileName',
        name: '_importEcFromUsbAndAssign');
    if (mounted) {
      showQgapSnackBar(context,
        SnackBar(
          content: Text('✅ "$fileName" von USB importiert und zugeordnet'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // Zeigt den Dialog zum Erstellen einer Zufallsdatei (vereinfachte Version)
  void _showCreateRandomFileDialogFromHomeScreen() {
    String fileName = '';
    String sizeText = '1';

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('🎲 Zufällige .qgap_ec Datei erstellen'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      initialValue: fileName,
                      decoration: const InputDecoration(
                        labelText: 'Dateiname (ohne Endung)',
                        hintText: 'z.B. my_key_file',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) {
                        fileName = value;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      initialValue: sizeText,
                      decoration: const InputDecoration(
                        labelText: 'Größe in MB',
                        hintText: '1-1000',
                        border: OutlineInputBorder(),
                        suffixText: 'MB',
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (value) {
                        sizeText = value;
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Datei wird im Daten/QGap/schluessel/ Ordner erstellt',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    // Nach dem Schließen den ursprünglichen Dialog wieder öffnen
                    _showMandatoryKeyFileSelection();
                  },
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    final trimmedFileName = fileName.trim();
                    final trimmedSizeText = sizeText.trim();

                    if (trimmedFileName.isEmpty) {
                      return;
                    }

                    final size = int.tryParse(trimmedSizeText);
                    if (size == null || size < 1 || size > 1000) {
                      return;
                    }

                    Navigator.of(context).pop();

                    // Datei mit Progress-Dialog erstellen
                    _createRandomFileWithProgress(trimmedFileName, size);
                  },
                  child: const Text('Erstellen'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Erstellt eine zufällige binäre .qgap Datei mit Progress Dialog
  void _createRandomFileWithProgress(String fileName, int sizeInMB) {
    developer.log(
        'log: _createRandomFileWithProgress aufgerufen: $fileName, $sizeInMB MB',
        name: 'CreateRandomFile');

    double progress = 0.0;
    late StateSetter updateProgress;

    // Progress Dialog sofort anzeigen
    showDialog(
      context: context,
      barrierDismissible: false, // Nicht schließbar während Erstellung
      builder: (BuildContext dialogContext) {
        developer.log('log: Progress Dialog wird aufgebaut',
            name: 'CreateRandomFile');
        return StatefulBuilder(
          builder: (context, setProgressState) {
            updateProgress = setProgressState;
            return AlertDialog(
              title: const Text('🎲 Datei wird erstellt...'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Erstelle "$fileName.qgap_ec" ($sizeInMB MB)',
                    style: const TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).primaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${(progress * 100).toInt()}%',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    progress == 0.0 ? 'Wird gestartet...' : 'Schreibt Daten...',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    // Kurze Verzögerung um sicherzustellen dass der Dialog angezeigt wird
    Future.delayed(const Duration(milliseconds: 200), () {
      developer.log('log: Starte Dateierstellung nach Dialog-Anzeige',
          name: 'CreateRandomFile');

      // Datei-Erstellung mit Progress-Updates
      _performFileCreationWithProgress(fileName, sizeInMB, (newProgress) {
        developer.log('log: Progress Update: ${(newProgress * 100).toInt()}%',
            name: 'CreateRandomFile');
        if (mounted) {
          updateProgress(() {
            progress = newProgress;
          });
        }
      }).then((createdFileName) {
        developer.log(
            'log: Dateierstellung abgeschlossen: ${createdFileName ?? '(fehlgeschlagen)'}',
            name: 'CreateRandomFile');

        // Progress Dialog schließen
        if (mounted) {
          Navigator.of(context).pop();
        }

        if (createdFileName != null) {
          // Automatisch die neu erstellte Datei für diesen Chat zuordnen
          final newFileName = createdFileName;
          setState(() {
            selectedKeyFile = newFileName;
            // Neu erstellte Datei trägt die Endung .qgap_ec — auch als
            // EC-Zuordnung übernehmen, damit beide Felder synchron bleiben.
            selectedEcFile = newFileName;
          });

          // Key-Datei-Zuordnung speichern
          _saveSelectedKeyFile().then((_) async {
            await _saveEcSettings();
            // Chat vollständig initialisieren mit der neuen Datei
            _loadKeyInfo().then((_) {
              _loadChatMessages().then((_) {
                // Nach dem Laden zum Ende scrollen
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController
                        .jumpTo(_scrollController.position.maxScrollExtent);
                  }
                });
              });
            });
          });

          // Erfolg nur über developer.log protokollieren
          developer.log(
              'log: ✅ Datei "$newFileName" erstellt und automatisch zugeordnet ($sizeInMB MB)',
              name: 'CreateRandomFile');

          // Code aus Dateiname extrahieren und kurz anzeigen, damit der
          // Anwender ihn dem Empfänger ggf. mitteilen kann.
          final code = EcKeyfileService.extractCodeFromFilename(newFileName);
          if (mounted && code != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                content: Text(
                    '🎲 EC-Code: $code\nDatei: $newFileName'),
              ),
            );
          }
        } else {
          // Fehler nur über developer.log protokollieren
          developer.log('log: ❌ Fehler beim Erstellen der Datei',
              name: 'CreateRandomFile');
        }
      }).catchError((error) {
        developer.log('log: Fehler bei Dateierstellung: $error',
            name: 'CreateRandomFile');

        // Progress Dialog schließen
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
    });
  }

  // Führt die eigentliche Dateierstellung mit Progress-Updates durch.
  // Gibt den tatsächlich erzeugten Dateinamen (inkl. zufälligem EC-Code-Suffix
  // und `.qgap_ec`-Endung) zurück oder `null` bei Abbruch/Fehler.
  Future<String?> _performFileCreationWithProgress(
      String fileName, int sizeInMB, Function(double) onProgressUpdate) async {
    try {
      // Berechtigung anfordern (nur Android nötig)
      PermissionStatus status = PermissionStatus.granted;

      if (Platform.isAndroid) {
        status = PermissionStatus.denied;
        try {
          status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            status = await Permission.storage.request();
          }
        } catch (e) {
          status = await Permission.storage.request();
        }
      }

      if (!status.isGranted) {
        return null;
      }

      // Ordner erstellen falls nicht vorhanden
      final qgapDir = Directory(AppStorage.schluesselDir);
      if (!await qgapDir.exists()) {
        await qgapDir.create(recursive: true);
        developer.log('log: Ordner erstellt: ${qgapDir.path}',
            name: '_performFileCreation');
      }

      // Dateiname mit Zufalls-Code-Suffix und `.qgap_ec`-Endung
      final fullFileName =
          await EcKeyfileService.appendCodeToFilename(fileName);
      final filePath = '${qgapDir.path}/$fullFileName';
      final file = File(filePath);

      // Prüfen ob Datei bereits existiert (extrem unwahrscheinlich durch Zufalls-Code)
      if (await file.exists()) {
        final shouldOverwrite = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Datei existiert bereits'),
              content: Text(
                  'Die Datei "$fullFileName" existiert bereits. Überschreiben?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Überschreiben'),
                ),
              ],
            );
          },
        );

        if (shouldOverwrite != true) return null;
      }

      // Bytes in Blöcken generieren für bessere Performance bei großen Dateien
      final random = Random.secure();
      final totalBytes = sizeInMB * 1024 * 1024;
      const chunkSize = 512 * 1024; // 512 KB Blöcke für häufigere Updates

      final sink = file.openWrite();
      int writtenBytes = 0;

      // Ersten Progress-Update senden
      onProgressUpdate(0.0);

      try {
        for (int offset = 0; offset < totalBytes; offset += chunkSize) {
          final remainingBytes = totalBytes - offset;
          final currentChunkSize =
              remainingBytes > chunkSize ? chunkSize : remainingBytes;

          // Chunk generieren
          final chunk = List<int>.generate(
              currentChunkSize, (index) => random.nextInt(256));
          sink.add(chunk);

          writtenBytes += currentChunkSize;

          // Progress aktualisieren
          final progress = writtenBytes / totalBytes;
          onProgressUpdate(progress);

          developer.log(
              'log: Fortschritt: ${(progress * 100).toInt()}% ($writtenBytes/$totalBytes bytes)',
              name: 'CreateRandomFile');

          // Pause für UI-Responsiveness und Progress-Update
          await Future.delayed(const Duration(milliseconds: 100));
        }

        // Finaler Progress-Update
        onProgressUpdate(1.0);
      } finally {
        await sink.close();
      }

      developer.log(
          'log: Zufallsdatei erfolgreich erstellt: $filePath ($totalBytes bytes)',
          name: '_performFileCreationWithProgress');
      return fullFileName;
    } catch (e) {
      developer.log('log: Fehler beim Erstellen der Zufallsdatei: $e',
          name: '_performFileCreationWithProgress');
      return null;
    }
  }

  // Überprüft ob eine Datei bereits einem anderen Chat zugewiesen ist
  Future<bool> _isFileAssignedToOtherChat(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    for (String key in keys) {
      if (key.startsWith('chat_key_') &&
          key != 'chat_key_${widget.chatGroupId}') {
        final assignedFile = prefs.getString(key);
        if (assignedFile == fileName) {
          developer.log(
              'log: Datei $fileName ist bereits Chat ${key.replaceAll('chat_key_', '')} zugewiesen',
              name: '_isFileAssignedToOtherChat');
          return true;
        }
      }
    }
    return false;
  }

  // Gibt den Chat-Namen zurück, dem die Datei zugewiesen ist
  Future<String?> _getChatNameForFile(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    for (String key in keys) {
      if (key.startsWith('chat_key_') &&
          key != 'chat_key_${widget.chatGroupId}') {
        final assignedFile = prefs.getString(key);
        if (assignedFile == fileName) {
          final chatId = key.replaceAll('chat_key_', '');
          // Versuche den Chat-Namen zu finden
          final chatGroupsJson = prefs.getStringList('chat_groups') ?? [];
          for (String groupJson in chatGroupsJson) {
            final group = json.decode(groupJson);
            if (group['id'] == chatId) {
              return group['name'];
            }
          }
          return 'Chat $chatId';
        }
      }
    }
    return null;
  }

  // Lädt die Nachrichten für diese Chat-Gruppe
  Future<void> _loadChatMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesKey = 'messages_${widget.chatGroupId}';
    final messagesJson = prefs.getStringList(messagesKey) ?? [];

    setState(() {
      messages.clear();
      messageQrCodeAvailable
          .clear(); // Map für QR-Code-Verfügbarkeit zurücksetzen
      for (String messageJson in messagesJson) {
        try {
          final Map<String, dynamic> messageData = json.decode(messageJson);
          // fromJson liest alle Felder inkl. messageType, attachmentFileName
          // Timestamp-Kompatibilität: ältere Einträge speichern ISO-8601-String,
          // neuere speichern Millisekunden als int.
          final raw = messageData;
          if (raw['timestamp'] is String) {
            raw['timestamp'] =
                DateTime.parse(raw['timestamp'] as String)
                    .millisecondsSinceEpoch;
          }
          // Fallback encryptionType auf aktuellen Chat-Typ
          raw['encryptionType'] ??= currentEncryptionType.toString();
          final msg = qgap_model.Message.fromJson(raw);
          messages.add(msg);

          // Bestehende Nachrichten standardmäßig als QR-Code-fähig markieren
          messageQrCodeAvailable[msg.id] = true;
        } catch (e) {
          developer.log('log: Fehler beim Laden der Nachricht: $e',
              name: '_loadChatMessages');
        }
      }
    });
    developer.log(
        'log: ${messages.length} Nachrichten für Gruppe ${widget.chatGroupName} geladen',
        name: '_loadChatMessages');

    _ensureScrollToBottom();

    // Automatischer Retry geparkter OTP-Nachrichten: falls inzwischen die
    // passende EC-Datei lokal verfügbar ist, werden geparkte Einträge
    // entschlüsselt und in echte Nachrichten umgewandelt.
    unawaited(_retryParkedMessages());
  }

  // Speichert die Nachrichten für diese Chat-Gruppe
  Future<void> _saveChatMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final messagesKey = 'messages_${widget.chatGroupId}';
    final List<String> messagesJson =
        messages.map((m) => json.encode(m.toJson())).toList();

    await prefs.setStringList(messagesKey, messagesJson);
    developer.log(
        'log: ${messages.length} Nachrichten für Gruppe ${widget.chatGroupName} gespeichert',
        name: '_saveChatMessages');
  }

  // Speichert die Verschlüsselungsart für diese Chat-Gruppe
  Future<void> _saveEncryptionType() async {
    final prefs = await SharedPreferences.getInstance();
    final encryptionKey = 'encryptionType_${widget.chatGroupId}';
    await prefs.setString(encryptionKey, currentEncryptionType.toString());
    developer.log(
        'log: Verschlüsselungsart $currentEncryptionType für Gruppe ${widget.chatGroupName} gespeichert',
        name: '_saveEncryptionType');
  }

  // Lädt die gespeicherte Verschlüsselungsart für diese Chat-Gruppe
  Future<void> _loadEncryptionType() async {
    final prefs = await SharedPreferences.getInstance();
    final encryptionKey = 'encryptionType_${widget.chatGroupId}';
    final savedEncryptionType = prefs.getString(encryptionKey);

    if (savedEncryptionType != null) {
      try {
        currentEncryptionType = qgap_model.EncryptionType.values.firstWhere(
          (e) => e.toString() == savedEncryptionType,
        );
        developer.log(
            'log: Verschlüsselungsart $currentEncryptionType für Gruppe ${widget.chatGroupName} geladen',
            name: '_loadEncryptionType');
      } catch (e) {
        developer.log(
            'log: Fehler beim Laden der Verschlüsselungsart: $e, verwende Standard: ${widget.encryptionType}',
            name: '_loadEncryptionType');
        currentEncryptionType = widget.encryptionType;
      }
    } else {
      currentEncryptionType = widget.encryptionType;
      developer.log(
          'log: Keine gespeicherte Verschlüsselungsart gefunden, verwende Standard: $currentEncryptionType',
          name: '_loadEncryptionType');
    }
  }

  // Lädt die verwendeten Bytes für die aktuell ausgewählte Datei (gruppenbezogen)
  Future<void> _loadUsedKeyBytes() async {
    if (selectedKeyFile == null) return; // Keine Key-Datei zugeordnet

    final prefs = await SharedPreferences.getInstance();
    final key = 'usedKeyBytes_${widget.chatGroupId}_$selectedKeyFile';
    final savedBytes = prefs.getInt(key) ?? 0;
    setState(() {
      usedKeyBytes = savedBytes;
    });
    developer.log(
        'log: Geladene Byte-Position für ${widget.chatGroupName}/$selectedKeyFile: $usedKeyBytes',
        name: '_loadUsedKeyBytes');
  }

  // Speichert die verwendeten Bytes für die aktuell ausgewählte Datei (gruppenbezogen)
  Future<void> _saveUsedKeyBytes() async {
    if (selectedKeyFile == null) return; // Keine Key-Datei zugeordnet

    final prefs = await SharedPreferences.getInstance();
    final key = 'usedKeyBytes_${widget.chatGroupId}_$selectedKeyFile';
    await prefs.setInt(key, usedKeyBytes);
    developer.log(
        'log: Gespeicherte Byte-Position für ${widget.chatGroupName}/$selectedKeyFile: $usedKeyBytes',
        name: '_saveUsedKeyBytes');
  }

  // Setzt die Byte-Position für eine bestimmte Datei zurück (gruppenbezogen)
  Future<void> _resetUsedKeyBytesForFile(String fileName) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'usedKeyBytes_${widget.chatGroupId}_$fileName';
    await prefs.setInt(key, 0);
    developer.log(
        'log: Byte-Position für ${widget.chatGroupName}/$fileName zurückgesetzt',
        name: '_resetUsedKeyBytesForFile');
  }

  // Kopiert Text in die Zwischenablage
  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    developer.log('log: Text in Zwischenablage kopiert: ${text.length} Zeichen',
        name: '_copyToClipboard');
  }

  /// Lädt eine .qgap-Datei vom Gerätespeicher (Interner Speicher, USB-Stick,
  /// Google Drive usw.) und verarbeitet sie als empfangene Nachricht im
  /// aktuellen Chat.
  Future<void> _loadQGapFileFromDisk() async {
    try {
      // withData: false → Bytes werden separat gelesen (verhindert TransactionTooLargeException
      // bei großen Dateien und bei USB-OTG / Google Drive Content-URIs)
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['qgap'],
          allowMultiple: false,
          withData: false,
          dialogTitle: '.qgap Datei laden',
        );
      } catch (_) {
        // Fallback: Android kann custom MIME-Typ für .qgap nicht filtern → alle Dateien anzeigen
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: false,
        );
      }
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;

      // Nach Fallback: Erweiterung prüfen
      if (!picked.name.toLowerCase().endsWith('.qgap')) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Nur .qgap-Dateien werden unterstützt (gewählt: ${picked.name})')),
          );
        }
        return;
      }

      // Bytes lesen: Content-URI (USB-OTG, Google Drive, SAF) → MethodChannel;
      // Direkte Datei → File.readAsBytes()
      Uint8List? bytes;
      final path = picked.path;
      if (path != null && path.isNotEmpty) {
        if (path.startsWith('content://')) {
          const ch = MethodChannel('de.paulporg.obmc/file_intent');
          developer.log('log: Lese .qgap via Content-URI: $path', name: '_loadQGapFileFromDisk');
          final raw = await ch.invokeMethod<Uint8List>('readContentUri', path);
          bytes = raw;
        } else {
          bytes = await File(path).readAsBytes();
        }
      }

      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(content: Text('Datei konnte nicht gelesen werden')),
          );
        }
        return;
      }

      // Binäres QGap-Envelope oder Text-Format?
      if (bytes.length >= 8 &&
          bytes[0] == 0x4F &&
          bytes[1] == 0x42 &&
          bytes[2] == 0x4D &&
          bytes[3] == 0x43) {
        developer.log('log: 📂 Binäres .qgap-Envelope geladen: ${picked.name}',
            name: '_loadQGapFileFromDisk');
        _processReceivedBinaryData(bytes);
      } else {
        try {
          final content = utf8.decode(bytes);
          debugPrint('QGAP_IMPORT: Text-.qgap geladen: ${picked.name}, ${content.length} Zeichen');
          developer.log('log: 📂 Text-Format .qgap geladen: ${picked.name}',
              name: '_loadQGapFileFromDisk');
          _processScannedQRData(content);
        } catch (e) {
          if (mounted) {
            showQgapSnackBar(context, 
              SnackBar(content: Text('Unbekanntes Dateiformat: ${picked.name}')),
            );
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Laden der .qgap-Datei: $e',
          name: '_loadQGapFileFromDisk');
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Laden: $e')),
        );
      }
    }
  }

  // QR-Code Scanner (Fountain-Code Mehrbild-Empfaenger)
  void _showQRScanner() async {
    PermissionStatus cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      developer.log('log: Kamera-Berechtigung nicht erteilt',
          name: '_showQRScanner');
      return;
    }
    if (!mounted) return;
    final receivedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const QrDataReceiver()),
    );
    if (receivedBytes != null && receivedBytes.isNotEmpty) {
      _processReceivedBinaryData(receivedBytes);
    }
  }

  /// Verarbeitet empfangene Binärdaten aus dem QR-Fountain-Code-Empfänger.
  /// Parst das QGap-Binär-Envelope und leitet Text- oder Datei-Nachrichten weiter.
  void _processReceivedBinaryData(Uint8List rawBytes) {
    debugPrint('QGAP_CHAT: _processReceivedBinaryData bytes=${rawBytes.length}');
    final parsed = _parseBinaryEnvelope(rawBytes);
    if (parsed != null) {
      final metadata = parsed['metadata'] as String;
      final payload = parsed['payload'] as Uint8List;
      debugPrint('QGAP_CHAT: parsed type=${parsed['type']} metadata=$metadata payloadLen=${payload.length}');
      if (parsed['type'] == 'text') {
        // Base64-Format für bestehende Verarbeitungs-Pipeline rekonstruieren
        final scannedData = (metadata.isNotEmpty
                ? base64.encode(utf8.encode(metadata))
                : '') +
            base64.encode(payload);
        _processScannedQRData(scannedData);
      } else if (parsed['type'] == 'file') {
        _processReceivedFile(parsed);
      } else if (parsed['type'] == 'voice') {
        debugPrint('QGAP_CHAT: → _processReceivedVoice');
        _processReceivedVoice(parsed);
      }
    } else {
      debugPrint('QGAP_CHAT: _parseBinaryEnvelope returned null – fallback to text');
      // Abwärtskompatibilität: alte App-Version sendet noch UTF-8 String
      try {
        final str = utf8.decode(rawBytes);
        if (str.isNotEmpty) _processScannedQRData(str);
      } catch (e) {
        developer.log(
            'log: Empfangene Daten konnten nicht dekodiert werden: $e',
            name: '_processReceivedBinaryData');
      }
    }
  }

  // ─── Datei-Verschlüsselung (reine Bytes, kein UTF-8-Umweg) ─────────────────

  /// Verschlüsselt Rohbytes mit OTP-XOR (EINE Schicht — die .qgap_ec-Datei
  /// ist der Schlüssel; der ECC-Code in den Metadaten dient dem Empfänger
  /// nur zum Auffinden derselben Datei).
  Future<Uint8List> _encryptRawBytesXOR(Uint8List plainBytes) async {
    final keyResult = await ladeKeyAusDatei(selectedKeyFile);
    final key = keyResult['key'] ?? '';
    if (key.isEmpty) throw Exception('Key ist leer (Datei: $selectedKeyFile)');

    List<int> keyBytes;
    try {
      if (key.length > 20 &&
          (key.contains('=') ||
              RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(key))) {
        keyBytes = base64.decode(key);
      } else {
        keyBytes = utf8.encode(key);
      }
    } catch (e) {
      throw Exception('Key konnte nicht dekodiert werden: $e');
    }
    if (keyBytes.isEmpty) throw Exception('Key-Bytes sind leer');

    final encrypted = List<int>.generate(plainBytes.length, (i) {
      return plainBytes[i] ^ keyBytes[(usedKeyBytes + i) % keyBytes.length];
    });

    return Uint8List.fromList(encrypted);
  }

  /// Entschlüsselt Rohbytes mit OTP-XOR (eine Schicht, XOR ist symmetrisch).
  /// [ecFileName] = via ECC-Code aufgelöste Datei — Fallback, falls die
  /// Schlüsseldatei lokal unter anderem Namen liegt.
  Uint8List _decryptRawBytesXOR(
      Uint8List encryptedBytes, String keyFileName, int byteOffset,
      [String? ecFileName]) {
    List<int> keyBytes = _loadKeyFileSync(keyFileName);
    if (keyBytes.isEmpty && ecFileName != null && ecFileName.isNotEmpty) {
      keyBytes = _loadEcFileSync(ecFileName);
    }
    if (keyBytes.isEmpty) throw Exception('Key-Datei "$keyFileName" nicht gefunden');

    return Uint8List.fromList(List<int>.generate(
        encryptedBytes.length,
        (i) => encryptedBytes[i] ^ keyBytes[(byteOffset + i) % keyBytes.length]));
  }

  // ─── Empfangene Datei verarbeiten ──────────────────────────────────────────

  Future<void> _processReceivedFile(Map<String, dynamic> parsed) async {
    final metadata = parsed['metadata'] as String;
    final fileName = parsed['fileName'] as String;
    final encryptedBytes = parsed['payload'] as Uint8List;

    try {
      final metaParts = metadata.split(';');
      if (metaParts.length < 2) throw Exception('Ungültige Metadaten: $metadata');
      final keyFileName = metaParts[0];
      final byteOffset = int.tryParse(metaParts[1]) ?? 0;
      String? ecFileName;
      String? ecCode;
      for (int i = 2; i < metaParts.length; i++) {
        final part = metaParts[i];
        if (part.startsWith('ECC:')) {
          ecCode = part.substring(4);
          break;
        }
        if (part.startsWith('EC:')) {
          ecFileName = part.substring(3);
          break;
        }
      }
      if (ecCode != null) {
        ecFileName = await EcKeyfileService.findEcFileByCode(ecCode);
        if (ecFileName == null) {
          // EC-Datei fehlt → Nachricht parken statt verwerfen.
          await _parkOtpMessage(
            fullText: '',
            ecCode: ecCode,
            keyFileName: keyFileName,
            byteOffset: byteOffset,
            fileName: fileName,
            encryptedBytes: encryptedBytes,
          );
          return;
        }
      }

      final decryptedBytes =
          _decryptRawBytesXOR(encryptedBytes, keyFileName, byteOffset, ecFileName);

      // In Empfangs-Ordner speichern
      final saveDir = Directory(AppStorage.empfangenDir);
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final saveFile = File('${saveDir.path}/$fileName');
      await saveFile.writeAsBytes(decryptedBytes, flush: true);

      developer.log('log: ✅ Datei empfangen und gespeichert: ${saveFile.path}',
          name: '_processReceivedFile');

      if (!mounted) return;
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        messages.add(qgap_model.Message(
          text: base64.encode(encryptedBytes), // verschlüsselt aufbewahren
          originalText: fileName,
          isMe: false,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: keyFileName,
          byteOffset: byteOffset,
          messageType: qgap_model.MessageType.file,
          attachmentFileName: fileName,
          attachmentLocalPath: saveFile.path,
          attachmentSize: decryptedBytes.length,
        ));
        messageQrCodeAvailable[msgId] = false;
      });
      _saveChatMessages();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });

      showQgapSnackBar(context, SnackBar(
        content: Text(
            '📎 Datei "$fileName" empfangen → Daten/QGap/empfangen/'),
      ));
    } catch (e) {
      developer.log('log: Fehler beim Verarbeiten der empfangenen Datei: $e',
          name: '_processReceivedFile');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Empfangen der Datei: $e')));
      }
    }
  }

  // ─── Sprachnachrichten ────────────────────────────────────────────────────

  /// Zeigt das Bottom-Sheet zum Aufnehmen einer Sprachnachricht.
  Future<void> _showVoiceRecordSheet() async {
    // Mikrofon-Berechtigung anfordern
    final status = await Permission.microphone.request();
    if (!mounted) return;
    if (status.isDenied || status.isPermanentlyDenied) {
      showQgapSnackBar(context, const SnackBar(
          content: Text('Mikrofon-Berechtigung benötigt.')));
      return;
    }

    bool isRecording = false;
    bool isDone = false;
    String? recordedPath;
    int recordedSeconds = 0;
    Timer? timer;

    await showModalBottomSheet(
      context: context,
      isDismissible: true,
      enableDrag: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Sprachnachricht',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  Icon(
                    isRecording ? Icons.mic : (isDone ? Icons.check_circle : Icons.mic_none),
                    size: 56,
                    color: isRecording
                        ? Colors.red
                        : (isDone ? Colors.green : Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    isRecording
                        ? '${recordedSeconds ~/ 60}:${(recordedSeconds % 60).toString().padLeft(2, '0')} – Aufnahme läuft…'
                        : isDone
                            ? '${recordedSeconds ~/ 60}:${(recordedSeconds % 60).toString().padLeft(2, '0')} aufgenommen'
                            : 'Zum Starten antippen',
                    style: TextStyle(
                        color: isRecording ? Colors.red : Colors.grey.shade700),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // Verwerfen
                      TextButton.icon(
                        onPressed: () async {
                          timer?.cancel();
                          if (isRecording) await _recorder.stop();
                          if (recordedPath != null) {
                            final f = File(recordedPath!);
                            if (await f.exists()) await f.delete();
                          }
                          if (ctx.mounted) Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.delete_outline, color: Colors.grey),
                        label: const Text('Verwerfen',
                            style: TextStyle(color: Colors.grey)),
                      ),
                      // Aufnehmen / Stopp
                      if (!isDone)
                        ElevatedButton.icon(
                          onPressed: () async {
                            if (!isRecording) {
                              // Aufnahme starten
                              final tmpDir = await getTemporaryDirectory();
                              final path =
                                  '${tmpDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.ogg';
                              await _recorder.start(
                                const RecordConfig(encoder: AudioEncoder.opus),
                                path: path,
                              );
                              timer = Timer.periodic(
                                  const Duration(seconds: 1), (_) {
                                setSheetState(() => recordedSeconds++);
                              });
                              setSheetState(() {
                                isRecording = true;
                                recordedPath = path;
                              });
                            } else {
                              // Aufnahme stoppen
                              timer?.cancel();
                              await _recorder.stop();
                              setSheetState(() {
                                isRecording = false;
                                isDone = true;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor:
                                isRecording ? Colors.red : Colors.red.shade100,
                            foregroundColor:
                                isRecording ? Colors.white : Colors.red,
                          ),
                          icon: Icon(isRecording ? Icons.stop : Icons.fiber_manual_record),
                          label: Text(isRecording ? 'Stopp' : 'Aufnehmen'),
                        ),
                      // Senden (nur wenn fertig)
                      if (isDone)
                        ElevatedButton.icon(
                          onPressed: recordedPath == null
                              ? null
                              : () {
                                  Navigator.of(ctx).pop();
                                  _sendVoiceMessage(
                                      recordedPath!, recordedSeconds);
                                },
                          icon: const Icon(Icons.send),
                          label: const Text('Senden'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  /// Verschlüsselt die Audiodatei und fügt sie als Sprachnachricht dem Chat hinzu.
  Future<void> _sendVoiceMessage(String filePath, int durationSeconds) async {
    final audioFile = File(filePath);
    if (!await audioFile.exists()) return;
    final audioBytes = await audioFile.readAsBytes();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final fileName = 'voice_$ts.ogg';

    // Permanent copy in send directory (temp dir can be cleared by OS)
    final sendDir = Directory(AppStorage.gesendeteDir);
    if (!await sendDir.exists()) await sendDir.create(recursive: true);
    final permanentFile = File('${sendDir.path}/$fileName');
    await permanentFile.writeAsBytes(audioBytes, flush: true);
    final permanentPath = permanentFile.path;

    try {
      String fullText;
      String metadataString;
      qgap_model.EncryptionType encType;

      final isRsaOrHybrid = currentEncryptionType == qgap_model.EncryptionType.rsa ||
          currentEncryptionType == qgap_model.EncryptionType.hybrid;

      if (isRsaOrHybrid) {
        final contactName = await _ensureChatContactAssignment();
        if (contactName == null) {
          if (mounted) {
            showQgapSnackBar(context, const SnackBar(
                content: Text('Kein Kontakt zugeordnet.')));
          }
          return;
        }
        final audioBase64 = base64.encode(audioBytes);
        final hyb = await _encryptHybridForContact(audioBase64, contactName);
        metadataString =
            'HYB;${widget.chatGroupId};$contactName;FILE:$fileName;';
        fullText = base64.encode(utf8.encode(metadataString)) + hyb['payload']!;
        encType = qgap_model.EncryptionType.hybrid;
      } else {
        final ecSnippet = await _buildEcMetaSnippetForOnlineSend();
        if (ecSnippet == null) return; // EC-Datei ohne Code: Versand abbrechen
        final encryptedBytes = await _encryptRawBytesXOR(audioBytes);
        metadataString =
            '$selectedKeyFile;$usedKeyBytes;$ecSnippet';
        setState(() => usedKeyBytes += audioBytes.length);
        await _saveUsedKeyBytes();
        fullText = base64.encode(utf8.encode(metadataString)) +
            base64.encode(encryptedBytes);
        encType = qgap_model.EncryptionType.oneTimePad;
      }

      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      final durationLabel =
          '${durationSeconds ~/ 60}:${(durationSeconds % 60).toString().padLeft(2, '0')}';
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: durationLabel,
          isMe: true,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: selectedKeyFile,
          byteOffset: encType == qgap_model.EncryptionType.oneTimePad
              ? usedKeyBytes - audioBytes.length
              : null,
          encryptionType: encType,
          messageType: qgap_model.MessageType.voice,
          attachmentFileName: fileName,
          attachmentLocalPath: permanentPath,
          attachmentSize: audioBytes.length,
          deliveryStatus: _initialDeliveryStatus,
        ));
        messageQrCodeAvailable[msgId] = true;
      });
      _saveChatMessages();
      _ensureScrollToBottom();
      // Online-Chat: Sprachnachricht auch in Firestore senden
      if (widget.firestoreChatId != null) {
        if (!_checkFirestoreMessageSize(fullText, fileName)) {
          // Nachricht zu groß für Firestore – nur lokal/QR verfügbar
        } else {
          try {
            final docId = await FirestoreService().sendMessage(
              widget.firestoreChatId!,
              fullText,
              attachmentName: fileName,
            );
            if (docId != null) {
              _firestoreDocIdForMessage[msgId] = docId;
              _updateDeliveryStatus(
                  msgId, qgap_model.MessageDeliveryStatus.delivered);
            }
          } catch (e) {
            developer.log('⚠️ Firestore Voice-Senden Fehler: $e', name: '_sendVoiceMessage');
          }
        }
      }

      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text('🎤 Sprachnachricht ($durationLabel) bereit – QR senden.'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      developer.log('log: Fehler beim Senden der Sprachnachricht: $e',
          name: '_sendVoiceMessage');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler bei Sprachnachricht: $e')));
      }
    }
  }

  /// Spielt eine empfangene/gesendete Sprachnachricht ab oder stoppt sie.
  Future<void> _playOrStopVoice(qgap_model.Message msg) async {
    if (_currentlyPlayingId == msg.id) {
      await _audioPlayer.stop();
      setState(() => _currentlyPlayingId = null);
      return;
    }
    final path = msg.attachmentLocalPath;
    if (path == null) return;
    if (!await File(path).exists()) {
      if (mounted) {
        showQgapSnackBar(context, 
            const SnackBar(content: Text('Audiodatei nicht mehr vorhanden.')));
      }
      return;
    }
    await _audioPlayer.stop();
    setState(() => _currentlyPlayingId = msg.id);
    _playerCompleteSub?.cancel();
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _currentlyPlayingId = null);
    });
    await _audioPlayer.play(DeviceFileSource(path));
  }

  /// Verarbeitet eine empfangene binäre Sprachnachricht (Fountain-Code-Empfang).
  Future<void> _processReceivedVoice(Map<String, dynamic> parsed) async {
    final metadata = parsed['metadata'] as String;
    final fileName = parsed['fileName'] as String;
    final encryptedBytes = parsed['payload'] as Uint8List;
    debugPrint('QGAP_CHAT: _processReceivedVoice fileName=$fileName metaParts=${metadata.split(';').take(2).join(";")} encryptedLen=${encryptedBytes.length}');

    try {
      // RSA/Hybrid path
      final firstPart = metadata.split(';')[0];
      if (firstPart == 'HYB' || firstPart == 'HYBRID' || firstPart == 'RSA') {
        // Payload is UTF-8-encoded hybrid payload string stored in encryptedBytes
        final payloadString = utf8.decode(encryptedBytes);
        final scannedData = base64.encode(utf8.encode(metadata)) + payloadString;
        final decryptedB64 = await _decryptRsaHybridFromData(scannedData, firstPart);
        if (decryptedB64.startsWith('❌')) {
          throw Exception('RSA/Hybrid Entschlüsselung fehlgeschlagen: $decryptedB64');
        }
        final audioBytes = base64.decode(decryptedB64);

        final saveDir = Directory(AppStorage.empfangenDir);
        if (!await saveDir.exists()) await saveDir.create(recursive: true);
        final saveFile = File('${saveDir.path}/$fileName');
        await saveFile.writeAsBytes(audioBytes, flush: true);

        developer.log('log: ✅ HYB/RSA-Sprachnachricht empfangen: ${saveFile.path}',
            name: '_processReceivedVoice');

        if (!mounted) return;
        final msgId = DateTime.now().millisecondsSinceEpoch.toString();
        setState(() {
          messages.add(qgap_model.Message(
            text: base64.encode(encryptedBytes),
            originalText: fileName,
            isMe: false,
            timestamp: DateTime.now(),
            id: msgId,
            encryptionType: firstPart == 'RSA'
                ? qgap_model.EncryptionType.rsa
                : qgap_model.EncryptionType.hybrid,
            messageType: qgap_model.MessageType.voice,
            attachmentFileName: fileName,
            attachmentLocalPath: saveFile.path,
            attachmentSize: audioBytes.length,
          ));
          messageQrCodeAvailable[msgId] = false;
        });
        _saveChatMessages();
        _ensureScrollToBottom();
        if (mounted) {
          showQgapSnackBar(context, SnackBar(
            content: Text('🎤 Sprachnachricht "$fileName" empfangen.'),
            duration: const Duration(seconds: 3),
          ));
        }
        return;
      }

      // OTP path
      final metaParts = metadata.split(';');
      if (metaParts.length < 2) throw Exception('Ungültige Metadaten: $metadata');
      final keyFileName = metaParts[0];
      final byteOffset = int.tryParse(metaParts[1]) ?? 0;
      String? ecFileName;
      String? ecCode;
      for (int i = 2; i < metaParts.length; i++) {
        final part = metaParts[i];
        if (part.startsWith('ECC:')) {
          ecCode = part.substring(4);
          break;
        }
        if (part.startsWith('EC:')) {
          ecFileName = part.substring(3);
          break;
        }
      }
      if (ecCode != null) {
        ecFileName = await EcKeyfileService.findEcFileByCode(ecCode);
        if (ecFileName == null) {
          // EC-Datei fehlt → Nachricht parken statt verwerfen.
          await _parkOtpMessage(
            fullText: '',
            ecCode: ecCode,
            keyFileName: keyFileName,
            byteOffset: byteOffset,
            fileName: fileName,
            encryptedBytes: encryptedBytes,
          );
          return;
        }
      }

      final decryptedBytes =
          _decryptRawBytesXOR(encryptedBytes, keyFileName, byteOffset, ecFileName);

      final saveDir = Directory(AppStorage.empfangenDir);
      if (!await saveDir.exists()) await saveDir.create(recursive: true);
      final saveFile = File('${saveDir.path}/$fileName');
      await saveFile.writeAsBytes(decryptedBytes, flush: true);

      developer.log('log: ✅ Sprachnachricht empfangen: ${saveFile.path}',
          name: '_processReceivedVoice');

      if (!mounted) return;
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        messages.add(qgap_model.Message(
          text: base64.encode(encryptedBytes),
          originalText: fileName,
          isMe: false,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: keyFileName,
          byteOffset: byteOffset,
          messageType: qgap_model.MessageType.voice,
          attachmentFileName: fileName,
          attachmentLocalPath: saveFile.path,
          attachmentSize: decryptedBytes.length,
        ));
        messageQrCodeAvailable[msgId] = false;
      });
      _saveChatMessages();
      _ensureScrollToBottom();

      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text('🎤 Sprachnachricht "$fileName" empfangen.'),
        ));
      }
    } catch (e) {
      debugPrint('QGAP_CHAT: _processReceivedVoice ERROR: $e');
      developer.log('log: Fehler bei empfangener Sprachnachricht: $e',
          name: '_processReceivedVoice');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Empfangen der Sprachnachricht: $e')));
      }
    }
  }

  // ─── Foto aufnehmen und senden ─────────────────────────────────────────────

  Future<void> _takePhoto() async {
    if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad &&
        selectedKeyFile == null) {
      showQgapSnackBar(context, const SnackBar(
          content: Text('Keine Key-Datei zugeordnet. Bitte Einstellungen öffnen.')));
      return;
    }

    // Kameraberechtigung prüfen
    final camStatus = await Permission.camera.request();
    if (!camStatus.isGranted) {
      if (mounted) {
        showQgapSnackBar(context, 
            const SnackBar(content: Text('Kamera-Berechtigung verweigert.')));
      }
      return;
    }

    final picker = ImagePicker();
    XFile? photo;
    try {
      photo = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1920,
        maxHeight: 1920,
      );
    } catch (e) {
      developer.log('log: Kamera-Fehler: $e', name: '_takePhoto');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Kamera-Fehler: ${e.toString()}')));
      }
      return;
    }
    if (photo == null) return;

    final fileName = photo.name.isNotEmpty ? photo.name : 'photo.jpg';
    final fileBytes = await photo.readAsBytes();

    // Weiter wie bei _sendFileViaQR
    await _encryptAndSendFileBytes(fileBytes, fileName);
  }

  // ─── Datei-Bytes verschlüsseln und via QR senden (gemeinsame Logik) ────────

  Future<void> _encryptAndSendFileBytes(Uint8List fileBytes, String fileName) async {
    // Warnung bei großen Dateien
    if (fileBytes.length > 512 * 1024) {
      final mbSize = (fileBytes.length / 1024 / 1024).toStringAsFixed(1);
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Große Datei'),
          content: Text(
              '"$fileName" ist $mbSize MB groß.\n\nDie QR-Übertragung wird sehr lange dauern.\n\nFortfahren?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Fortfahren')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    try {
      String fullText;
      String metadataString;
      qgap_model.EncryptionType encType;

      final isRsaOrHybrid = currentEncryptionType == qgap_model.EncryptionType.rsa ||
          currentEncryptionType == qgap_model.EncryptionType.hybrid;

      if (isRsaOrHybrid) {
        final contactName = await _ensureChatContactAssignment();
        if (contactName == null) {
          if (mounted) {
            showQgapSnackBar(context, 
                const SnackBar(content: Text('Kein Kontakt zugeordnet.')));
          }
          return;
        }
        final fileBase64 = base64.encode(fileBytes);
        final hyb = await _encryptHybridForContact(fileBase64, contactName);
        metadataString = 'HYB;${widget.chatGroupId};$contactName;FILE:$fileName;';
        fullText = base64.encode(utf8.encode(metadataString)) + hyb['payload']!;
        encType = currentEncryptionType;
      } else {
        // One-Time-Pad (+ optional EC-Schicht)
        final ecSnippet = await _buildEcMetaSnippetForOnlineSend();
        if (ecSnippet == null) return; // EC-Datei ohne Code: Versand abbrechen
        final encryptedBytes = await _encryptRawBytesXOR(fileBytes);
        metadataString =
            '$selectedKeyFile;$usedKeyBytes;$ecSnippet';
        setState(() => usedKeyBytes += fileBytes.length);
        await _saveUsedKeyBytes();
        fullText = base64.encode(utf8.encode(metadataString)) + base64.encode(encryptedBytes);
        encType = qgap_model.EncryptionType.oneTimePad;
      }

      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      if (!mounted) return;
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: fileName,
          isMe: true,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: encType == qgap_model.EncryptionType.oneTimePad ? selectedKeyFile : null,
          byteOffset: encType == qgap_model.EncryptionType.oneTimePad
              ? usedKeyBytes - fileBytes.length
              : null,
          encryptionType: encType,
          messageType: qgap_model.MessageType.file,
          attachmentFileName: fileName,
          attachmentSize: fileBytes.length,
          deliveryStatus: _initialDeliveryStatus,
        ));
        messageQrCodeAvailable[msgId] = true;
      });
      await _saveChatMessages();
      // Online-Chat: Datei auch in Firestore senden
      if (widget.firestoreChatId != null) {
        if (!_checkFirestoreMessageSize(fullText, fileName)) {
          // Nachricht zu groß für Firestore – nur lokal/QR verfügbar
        } else {
          try {
            final docId = await FirestoreService().sendMessage(
              widget.firestoreChatId!,
              fullText,
              attachmentName: fileName,
            );
            if (docId != null) {
              _firestoreDocIdForMessage[msgId] = docId;
              _updateDeliveryStatus(
                  msgId, qgap_model.MessageDeliveryStatus.delivered);
            }
          } catch (e) {
            developer.log('⚠️ Firestore Datei-Senden Fehler: $e', name: '_encryptAndSendFileBytes');
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler beim Senden der Datei: $e', name: '_encryptAndSendFileBytes');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler: ${e.toString()}')));
      }
    }
  }

  // ─── Datei via QR senden ───────────────────────────────────────────────────

  Future<void> _sendFileViaQR() async {
    if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad &&
        selectedKeyFile == null) {
      showQgapSnackBar(context, const SnackBar(
          content: Text('Keine Key-Datei zugeordnet. Bitte Einstellungen öffnen.')));
      return;
    }

    // Datei auswählen
    FilePickerResult? result;
    try {
      result = await FilePicker.platform
          .pickFiles(type: FileType.any, allowMultiple: false);
    } catch (e) {
      developer.log('log: FilePicker Fehler: $e', name: '_sendFileViaQR');
      return;
    }
    if (result == null || result.files.isEmpty || result.files.first.path == null) {
      return;
    }

    final pickedFile = result.files.first;
    final fileName = pickedFile.name;
    final fileBytes = await File(pickedFile.path!).readAsBytes();

    // Warnung bei großen Dateien
    if (fileBytes.length > 512 * 1024) {
      final mbSize = (fileBytes.length / 1024 / 1024).toStringAsFixed(1);
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Große Datei'),
          content: Text(
              '"$fileName" ist $mbSize MB groß.\n\nDie QR-Übertragung wird sehr lange dauern (ca. ${(fileBytes.length / 400 * 0.3 / 60).toStringAsFixed(0)} Min bei ECC-M).\n\nFortfahren?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Fortfahren')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    try {
      String fullText;
      String metadataString;
      qgap_model.EncryptionType encType;

      final isRsaOrHybrid = currentEncryptionType == qgap_model.EncryptionType.rsa ||
          currentEncryptionType == qgap_model.EncryptionType.hybrid;

      if (isRsaOrHybrid) {
        // RSA/Hybrid: Datei-Bytes als Base64 kodieren und mit Hybrid verschlüsseln
        final contactName = await _ensureChatContactAssignment();
        if (contactName == null) {
          if (mounted) {
            showQgapSnackBar(context, 
                const SnackBar(content: Text('Kein Kontakt zugeordnet. Bitte Einstellungen öffnen.')));
          }
          return;
        }
        final fileBase64 = base64.encode(fileBytes);
        final hyb = await _encryptHybridForContact(fileBase64, contactName);
        metadataString = 'HYB;${widget.chatGroupId};$contactName;FILE:$fileName;';
        fullText = base64.encode(utf8.encode(metadataString)) + hyb['payload']!;
        encType = qgap_model.EncryptionType.hybrid;
      } else {
        // One-Time-Pad (+ optional EC-Schicht)
        final ecSnippet = await _buildEcMetaSnippetForOnlineSend();
        if (ecSnippet == null) return; // EC-Datei ohne Code: Versand abbrechen
        final encryptedBytes = await _encryptRawBytesXOR(fileBytes);
        metadataString =
            '$selectedKeyFile;$usedKeyBytes;$ecSnippet';
        // Byte-Offset aktualisieren
        setState(() => usedKeyBytes += fileBytes.length);
        await _saveUsedKeyBytes();
        fullText = base64.encode(utf8.encode(metadataString)) + base64.encode(encryptedBytes);
        encType = qgap_model.EncryptionType.oneTimePad;
      }

      // Nachricht in Chat eintragen
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: fileName,
          isMe: true,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: selectedKeyFile,
          byteOffset: encType == qgap_model.EncryptionType.oneTimePad
              ? usedKeyBytes - fileBytes.length
              : null,
          encryptionType: encType,
          messageType: qgap_model.MessageType.file,
          attachmentFileName: fileName,
          attachmentSize: fileBytes.length,
          deliveryStatus: _initialDeliveryStatus,
        ));
        messageQrCodeAvailable[msgId] = true;
      });
      _saveChatMessages();
      _ensureScrollToBottom();
      // Online-Chat: Datei auch in Firestore senden
      if (widget.firestoreChatId != null) {
        if (!_checkFirestoreMessageSize(fullText, fileName)) {
          // Nachricht zu groß für Firestore – nur lokal/QR verfügbar
        } else {
          try {
            final docId = await FirestoreService().sendMessage(
              widget.firestoreChatId!,
              fullText,
              attachmentName: fileName,
            );
            if (docId != null) {
              _firestoreDocIdForMessage[msgId] = docId;
              _updateDeliveryStatus(
                  msgId, qgap_model.MessageDeliveryStatus.delivered);
            }
          } catch (e) {
            developer.log('⚠️ Firestore Datei-Senden Fehler: $e', name: '_sendFileViaQR');
          }
        }
      }

      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text('📎 "$fileName" hinzugefügt – QR-Code über den Chat-Eintrag senden.'),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      developer.log('log: Fehler beim Verschlüsseln der Datei: $e',
          name: '_sendFileViaQR');
      if (mounted) {
        showQgapSnackBar(context, 
            SnackBar(content: Text('Fehler beim Vorbereiten der Datei: $e')));
      }
    }
  }

  // Verarbeitet die gescannten QR-Daten
  void _processScannedQRData(String scannedData) async {
    developer.log('log: QR-Code gescannt: ${scannedData.length} Zeichen',
        name: '_processScannedQRData');

    // Tastatur explizit ausblenden nach QR-Scan - mehrfach für sicheres Ausblenden
    FocusScope.of(context).unfocus();

    // Zusätzlich: System-UI verstecken um Tastatur-Trigger zu vermeiden
    SystemChannels.textInput.invokeMethod('TextInput.hide');

    // Fokus komplett entfernen vom Textfeld
    _textController.clearComposing();

    try {
      // Versuche Metadaten zu extrahieren
      String extractedMetadata = _extractMetadataFromText(scannedData);
      debugPrint('QGAP_IMPORT: Metadaten="$extractedMetadata" selectedKey="$selectedKeyFile"');

      // Prüfe, ob die verwendete Verschlüsselungsdatei einem anderen Chat zugeordnet ist
      if (extractedMetadata != 'Keine Metadaten verfügbar') {
        List<String> metaParts = extractedMetadata.split(';');
        if (metaParts.length >= 2) {
          String usedKeyFile = metaParts[0];

          developer.log('log: 🔍 Prüfe Datei-Zuordnung für: "$usedKeyFile"',
              name: '_processScannedQRData');
          developer.log('log: 📍 Aktuelle Chat-Datei: "$selectedKeyFile"',
              name: '_processScannedQRData');

          // Prüfe zuerst, ob die Datei dem aktuellen Chat zugeordnet ist
          bool isCurrentChatFile = (usedKeyFile == selectedKeyFile);

          if (isCurrentChatFile) {
            developer.log(
                'log: ✅ Datei "$usedKeyFile" gehört zum aktuellen Chat - kein Konflikt',
                name: '_processScannedQRData');
          } else {
            developer.log(
                'log: ⚠️ Datei "$usedKeyFile" gehört NICHT zum aktuellen Chat - prüfe Konflikte',
                name: '_processScannedQRData');

            // Prüfe, ob diese Datei einem anderen Chat zugeordnet ist (mit await!)
            bool wasHandled = await _checkKeyFileAssignment(
                usedKeyFile, scannedData, extractedMetadata);
            if (wasHandled) {
              return; // Nachricht wurde bereits verarbeitet oder Chat-Wechsel durchgeführt
            }
          }
        }
      }

      // Falls keine Metadaten oder keine Konflikt-Prüfung erforderlich, normal verarbeiten
      // RSA/HYB: Automatisch entschlüsseln
      if (extractedMetadata != 'Keine Metadaten verfügbar') {
        final firstPart = extractedMetadata.split(';')[0];
        if (firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID') {
          developer.log('log: 🔐 RSA/HYB Nachricht erkannt ($firstPart) – entschlüssele…',
              name: '_processScannedQRData');
          final decrypted = await _decryptRsaHybridFromData(scannedData, firstPart);
          _showDecryptErrorIfNeeded(decrypted);
          _addReceivedMessage(scannedData, extractedMetadata, decryptedText: decrypted);
          return;
        }
        // OTP: async entschlüsseln (inkl. ECC-Code-Auflösung via findEcFileByCode)
        await _receiveFirestoreOtpText(scannedData, extractedMetadata);
        return;
      }
      _addReceivedMessage(scannedData, extractedMetadata);
    } catch (e) {
      developer.log('log: Fehler beim Verarbeiten der QR-Daten: $e',
          name: '_processScannedQRData');

      // Zeige Fehlermeldung als Chat-Nachricht an
      setState(() {
        String messageId = Random().nextInt(1000).toString();
        messages.add(qgap_model.Message(
          text:
              "❌ FEHLER beim Verarbeiten der QR-Code Nachricht:\n\n${e.toString()}",
          originalText: "❌ Fehler beim QR-Code scannen",
          isMe: false,
          id: messageId,
          timestamp: DateTime.now(),
          keyFileName: null,
          byteOffset: null,
        ));

        // Fehlernachrichten haben keinen QR-Code-Button
        messageQrCodeAvailable[messageId] = false;
      });

      // Nachrichten speichern
      _saveChatMessages();

      // Zum neuesten Element scrollen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  // Prüft, ob die Key-Datei einem anderen Chat zugeordnet ist
  Future<bool> _checkKeyFileAssignment(
      String usedKeyFile, String scannedData, String extractedMetadata) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys();

    String? assignedChatId;
    String? assignedChatName;

    developer.log('log: 🔍 Prüfe Key-Datei-Zuordnung für: "$usedKeyFile"',
        name: '_checkKeyFileAssignment');
    developer.log(
        'log: 📍 Aktueller Chat: "${widget.chatGroupName}" (ID: ${widget.chatGroupId})',
        name: '_checkKeyFileAssignment');
    developer.log('log: 📍 Aktuelle Chat-Datei: "$selectedKeyFile"',
        name: '_checkKeyFileAssignment');

    // Zusätzliche Sicherheitsprüfung: Wenn die Datei bereits dem aktuellen Chat zugeordnet ist, kein Konflikt
    if (usedKeyFile == selectedKeyFile) {
      developer.log(
          'log: ✅ Datei "$usedKeyFile" ist bereits dem aktuellen Chat zugeordnet - kein Konflikt',
          name: '_checkKeyFileAssignment');
      return false; // Kein Konflikt
    }

    // Suche nach Zuordnung der Datei zu einem anderen Chat
    for (String key in keys) {
      if (key.startsWith('chat_key_') &&
          key != 'chat_key_${widget.chatGroupId}') {
        final assignedFile = prefs.getString(key);
        developer.log('log: 🔑 Prüfe Key "$key" -> Datei: "$assignedFile"',
            name: '_checkKeyFileAssignment');

        if (assignedFile == usedKeyFile) {
          assignedChatId = key.replaceFirst('chat_key_', '');
          developer.log(
              'log: ⚠️ KONFLIKT gefunden! Datei "$usedKeyFile" ist zugeordnet zu Chat-ID: "$assignedChatId"',
              name: '_checkKeyFileAssignment');
          developer.log(
              'log: 🔎 Starte Chat-Namen-Suche für ID: "$assignedChatId"',
              name: '_checkKeyFileAssignment');

          // Finde den Chat-Namen mit verbesserter Suche
          String? foundChatName = await _findChatNameById(assignedChatId);

          if (foundChatName != null && foundChatName.isNotEmpty) {
            assignedChatName = foundChatName;
            developer.log(
                'log: ✅ Chat-Name erfolgreich gefunden: "$assignedChatName"',
                name: '_checkKeyFileAssignment');
          } else {
            developer.log(
                'log: ❌ Chat-Name-Suche fehlgeschlagen für ID "$assignedChatId"',
                name: '_checkKeyFileAssignment');

            // Fallback: Suche in allen verfügbaren Chats
            List<Map<String, String>> allChats = await _getAllAvailableChats();
            bool chatFoundInList = false;

            for (Map<String, String> chat in allChats) {
              if (chat['id'] == assignedChatId) {
                assignedChatName = chat['name']!;
                chatFoundInList = true;
                developer.log(
                    'log: ✅ Chat gefunden in allChats-Liste: "$assignedChatName"',
                    name: '_checkKeyFileAssignment');
                break;
              }
            }

            if (!chatFoundInList) {
              developer.log(
                  'log: ❌ Chat mit ID "$assignedChatId" existiert nicht mehr!',
                  name: '_checkKeyFileAssignment');

              // Zeige alle verfügbaren Chats zur manuellen Auswahl
              if (mounted && allChats.isNotEmpty) {
                String? selectedChatName = await _showChatSelectionDialog(
                    usedKeyFile, allChats, scannedData, extractedMetadata);
                if (selectedChatName != null &&
                    selectedChatName != 'ERROR_WRONG_CHAT') {
                  assignedChatName = selectedChatName;
                  // Benutzer hat einen Chat ausgewählt, finde die entsprechende ID
                  for (Map<String, String> chat in allChats) {
                    if (chat['name'] == assignedChatName) {
                      assignedChatId = chat['id']!;
                      break;
                    }
                  }
                  developer.log(
                      'log: ✅ Benutzer wählte Chat: "$assignedChatName" (ID: $assignedChatId)',
                      name: '_checkKeyFileAssignment');
                } else if (selectedChatName == 'ERROR_WRONG_CHAT') {
                  throw Exception(
                      '❌ Verarbeitung abgebrochen: Die gescannte Nachricht gehört zu einem anderen Chat und kann nicht im aktuellen Chat "${widget.chatGroupName}" entschlüsselt werden.');
                } else {
                  developer.log('log: ℹ️ Benutzer brach Chat-Auswahl ab',
                      name: '_checkKeyFileAssignment');
                  throw Exception(
                      '❌ Chat-Auswahl abgebrochen: Die gescannte Nachricht konnte keinem verfügbaren Chat zugeordnet werden.');
                }
              } else {
                assignedChatName = 'Unbekannter Chat ($assignedChatId)';
                developer.log(
                    'log: ❌ Keine verfügbaren Chats gefunden, verwende Fallback: "$assignedChatName"',
                    name: '_checkKeyFileAssignment');
              }
            }
          }

          break;
        }
      }
    }

    if (assignedChatId != null && assignedChatName != null) {
      developer.log(
          'log: Zeige Konflikt-Dialog für Chat: $assignedChatName (ID: $assignedChatId)',
          name: '_checkKeyFileAssignment');

      // Warnung anzeigen und Chat-Wechsel anbieten
      if (!mounted) return true;

      bool shouldSwitch = await showDialog<bool>(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('⚠️ Verschlüsselungsdatei-Konflikt'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        'Die empfangene Nachricht verwendet die Verschlüsselungsdatei:'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Text(
                        usedKeyFile,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                        'Diese Datei ist bereits dem Chat "$assignedChatName" zugeordnet.'),
                    const SizedBox(height: 12),
                    const Text(
                        'Möchten Sie zu diesem Chat wechseln, um die Nachricht korrekt zu verarbeiten?'),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Hier behalten'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.blue.shade50,
                    ),
                    child: const Text('Zu Chat wechseln'),
                  ),
                ],
              );
            },
          ) ??
          false;

      if (shouldSwitch) {
        developer.log(
            'log: Benutzer wählte Chat-Wechsel zu: $assignedChatName (ID: $assignedChatId)',
            name: '_checkKeyFileAssignment');
        _switchToAssignedChat(
            assignedChatId, assignedChatName, scannedData, extractedMetadata);
        return true; // Chat-Wechsel wurde durchgeführt
      } else {
        developer.log(
            'log: ❌ Benutzer wählte "Hier behalten" - aber Nachricht gehört zu anderem Chat!',
            name: '_checkKeyFileAssignment');
        // Fehler werfen anstatt Nachricht im falschen Chat zu verarbeiten
        throw Exception(
            '❌ Verarbeitung abgebrochen: Die gescannte Nachricht gehört zu "$assignedChatName" und kann nicht im aktuellen Chat "$widget.chatGroupName" entschlüsselt werden.');
      }
    }

    developer.log(
        'log: ✅ Keine Konflikte gefunden für Datei: "$usedKeyFile" - Datei ist verfügbar',
        name: '_checkKeyFileAssignment');
    // Keine Konflikte gefunden
    return false;
  }

  // Findet den Chat-Namen anhand der Chat-ID
  Future<String?> _findChatNameById(String chatId) async {
    final prefs = await SharedPreferences.getInstance();

    developer.log(
        'log: 🔍 SUCHE Chat-Name für ID: "$chatId" (Typ: ${chatId.runtimeType})',
        name: '_findChatNameById');

    // Versuche verschiedene mögliche Speicherorte für Chat-Gruppen
    final possibleKeys = [
      'chat_groups',
      'chatGroups',
      'groups',
    ];

    // Sammle alle verfügbaren Schlüssel für Debug-Zwecke
    final allKeys = prefs.getKeys();
    developer.log(
        'log: 📋 Alle verfügbaren SharedPreferences Keys: ${allKeys.toList()}',
        name: '_findChatNameById');

    for (String key in possibleKeys) {
      final groupsJson = prefs.getStringList(key) ?? [];
      developer.log('log: 📂 Durchsuche $key: ${groupsJson.length} Einträge',
          name: '_findChatNameById');

      if (groupsJson.isNotEmpty) {
        for (int i = 0; i < groupsJson.length; i++) {
          String groupJson = groupsJson[i];
          try {
            final groupData = json.decode(groupJson);
            developer.log('log: 🔎 Gruppe $i: ${groupData.toString()}',
                name: '_findChatNameById');

            // Versuche verschiedene mögliche ID-Felder
            final possibleIdFields = ['id', 'chatId', 'groupId', 'chatGroupId'];
            final possibleNameFields = [
              'name',
              'chatName',
              'groupName',
              'title'
            ];

            String? foundId;
            String? foundName;

            // Detaillierte Suche nach ID
            for (String idField in possibleIdFields) {
              if (groupData.containsKey(idField) &&
                  groupData[idField] != null) {
                foundId = groupData[idField].toString();
                developer.log(
                    'log: 🆔 Gefundene ID in Feld "$idField": "$foundId" (Typ: ${groupData[idField].runtimeType})',
                    name: '_findChatNameById');
                break;
              }
            }

            // Detaillierte Suche nach Name
            for (String nameField in possibleNameFields) {
              if (groupData.containsKey(nameField) &&
                  groupData[nameField] != null) {
                foundName = groupData[nameField].toString();
                developer.log(
                    'log: 📝 Gefundener Name in Feld "$nameField": "$foundName"',
                    name: '_findChatNameById');
                break;
              }
            }

            // Vergleiche die IDs mit verschiedenen Methoden
            if (foundId != null) {
              developer.log('log: 🔄 Vergleiche IDs:',
                  name: '_findChatNameById');
              developer.log('log: 🔄   Gesuchte ID: "$chatId"',
                  name: '_findChatNameById');
              developer.log('log: 🔄   Gefundene ID: "$foundId"',
                  name: '_findChatNameById');
              developer.log('log: 🔄   String-Vergleich: ${foundId == chatId}',
                  name: '_findChatNameById');
              developer.log(
                  'log: 🔄   Trimmed-Vergleich: ${foundId.trim() == chatId.trim()}',
                  name: '_findChatNameById');
              developer.log(
                  'log: 🔄   Lowercase-Vergleich: ${foundId.toLowerCase() == chatId.toLowerCase()}',
                  name: '_findChatNameById');

              // Verschiedene Vergleichsmethoden ausprobieren
              bool idsMatch = false;

              // 1. Exakter String-Vergleich
              if (foundId == chatId) {
                idsMatch = true;
                developer.log('log: ✅ ID-Match: Exakter String-Vergleich',
                    name: '_findChatNameById');
              }
              // 2. Vergleich nach Trimmen
              else if (foundId.trim() == chatId.trim()) {
                idsMatch = true;
                developer.log('log: ✅ ID-Match: Nach Trimmen',
                    name: '_findChatNameById');
              }
              // 3. Case-insensitive Vergleich
              else if (foundId.toLowerCase() == chatId.toLowerCase()) {
                idsMatch = true;
                developer.log('log: ✅ ID-Match: Case-insensitive',
                    name: '_findChatNameById');
              }
              // 4. Numerischer Vergleich (falls IDs Zahlen sind)
              else {
                try {
                  int foundIdNum = int.parse(foundId);
                  int chatIdNum = int.parse(chatId);
                  if (foundIdNum == chatIdNum) {
                    idsMatch = true;
                    developer.log('log: ✅ ID-Match: Numerischer Vergleich',
                        name: '_findChatNameById');
                  }
                } catch (e) {
                  developer.log('log: ℹ️ Keine numerischen IDs: $e',
                      name: '_findChatNameById');
                }
              }

              if (idsMatch && foundName != null && foundName.isNotEmpty) {
                developer.log(
                    'log: 🎉 ✅ Chat-Name gefunden: "$foundName" für ID: "$chatId"',
                    name: '_findChatNameById');
                return foundName;
              }
            }
          } catch (e) {
            developer.log('log: ❌ Fehler beim Parsen der Chat-Gruppe $i: $e',
                name: '_findChatNameById');
            developer.log('log: ❌ Problematischer JSON: $groupJson',
                name: '_findChatNameById');
            continue;
          }
        }
      } else {
        developer.log('log: ⚠️ Keine Einträge in $key gefunden',
            name: '_findChatNameById');
      }
    }

    developer.log('log: ❌ FEHLER: Kein Chat-Name gefunden für ID: "$chatId"',
        name: '_findChatNameById');
    developer.log(
        'log: ❌ FEHLER: Chat mit ID "$chatId" existiert nicht in den gespeicherten Chat-Gruppen!',
        name: '_findChatNameById');
    developer.log(
        'log: ❌ FEHLER: Überprüfung der Chat-Gruppen-Daten erforderlich!',
        name: '_findChatNameById');

    // Starte Debug-Ausgabe für alle Chat-Gruppen
    await _debugAllChatGroups();

    return null;
  }

  // Debug-Methode: Zeigt alle gespeicherten Chat-Gruppen an
  Future<void> _debugAllChatGroups() async {
    final prefs = await SharedPreferences.getInstance();

    developer.log('log: 🐛 === DEBUG: Alle Chat-Gruppen ===',
        name: '_debugAllChatGroups');

    final possibleKeys = ['chat_groups', 'chatGroups', 'groups'];

    for (String key in possibleKeys) {
      final groupsJson = prefs.getStringList(key) ?? [];
      developer.log('log: 🐛 $key: ${groupsJson.length} Einträge',
          name: '_debugAllChatGroups');

      for (int i = 0; i < groupsJson.length; i++) {
        try {
          final groupData = json.decode(groupsJson[i]);
          developer.log('log: 🐛 [$i] $groupData', name: '_debugAllChatGroups');
        } catch (e) {
          developer.log('log: 🐛 [$i] FEHLER: $e - JSON: ${groupsJson[i]}',
              name: '_debugAllChatGroups');
        }
      }
    }

    // Zeige auch alle chat_key_ Zuordnungen
    developer.log('log: 🐛 === DEBUG: Alle Chat-Key-Zuordnungen ===',
        name: '_debugAllChatGroups');
    final allKeys = prefs.getKeys();
    for (String key in allKeys) {
      if (key.startsWith('chat_key_')) {
        final assignedFile = prefs.getString(key);
        final chatId = key.replaceFirst('chat_key_', '');
        developer.log('log: 🐛 Chat-ID: "$chatId" -> Datei: "$assignedFile"',
            name: '_debugAllChatGroups');
      }
    }

    developer.log('log: 🐛 === DEBUG ENDE ===', name: '_debugAllChatGroups');
  }

  // Neue Methode: Listet alle verfügbaren Chats mit ihren IDs und Namen auf
  Future<List<Map<String, String>>> _getAllAvailableChats() async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, String>> availableChats = [];

    developer.log('log: 📋 Suche alle verfügbaren Chats...',
        name: '_getAllAvailableChats');

    final possibleKeys = ['chat_groups', 'chatGroups', 'groups'];

    for (String key in possibleKeys) {
      final groupsJson = prefs.getStringList(key) ?? [];
      developer.log('log: 📂 Prüfe $key: ${groupsJson.length} Einträge',
          name: '_getAllAvailableChats');

      for (int i = 0; i < groupsJson.length; i++) {
        try {
          final groupData = json.decode(groupsJson[i]);

          // Versuche verschiedene mögliche ID-Felder
          final possibleIdFields = ['id', 'chatId', 'groupId', 'chatGroupId'];
          final possibleNameFields = ['name', 'chatName', 'groupName', 'title'];

          String? foundId;
          String? foundName;

          // Suche ID
          for (String idField in possibleIdFields) {
            if (groupData.containsKey(idField) && groupData[idField] != null) {
              foundId = groupData[idField].toString();
              break;
            }
          }

          // Suche Name
          for (String nameField in possibleNameFields) {
            if (groupData.containsKey(nameField) &&
                groupData[nameField] != null) {
              foundName = groupData[nameField].toString();
              break;
            }
          }

          if (foundId != null &&
              foundName != null &&
              foundId.isNotEmpty &&
              foundName.isNotEmpty) {
            availableChats.add({
              'id': foundId,
              'name': foundName,
            });
            developer.log(
                'log: ✅ Chat gefunden: ID="$foundId", Name="$foundName"',
                name: '_getAllAvailableChats');
          }
        } catch (e) {
          developer.log('log: ❌ Fehler beim Parsen von Chat [$i]: $e',
              name: '_getAllAvailableChats');
        }
      }
    }

    developer.log('log: 📊 Gesamt gefundene Chats: ${availableChats.length}',
        name: '_getAllAvailableChats');
    return availableChats;
  }

  // Zeigt Dialog zur manuellen Chat-Auswahl wenn automatische Suche fehlschlägt
  Future<String?> _showChatSelectionDialog(
      String usedKeyFile,
      List<Map<String, String>> availableChats,
      String scannedData,
      String extractedMetadata) async {
    developer.log('log: 🔧 Zeige Chat-Auswahl-Dialog für Datei: "$usedKeyFile"',
        name: '_showChatSelectionDialog');

    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('🔍 Chat für Verschlüsselungsdatei wählen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Die Datei "$usedKeyFile" konnte keinem Chat automatisch zugeordnet werden.'),
              const SizedBox(height: 12),
              const Text('Bitte wählen Sie den passenden Chat aus:'),
              const SizedBox(height: 8),
              SizedBox(
                width: double.maxFinite,
                height: 200,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: availableChats.length,
                  itemBuilder: (context, index) {
                    final chat = availableChats[index];
                    return ListTile(
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(chat['name']!),
                      subtitle: Text('ID: ${chat['id']}'),
                      onTap: () {
                        developer.log(
                            'log: ✅ Benutzer wählte Chat: "${chat['name']}" (ID: ${chat['id']})',
                            name: '_showChatSelectionDialog');
                        Navigator.of(context).pop(chat['name']);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                developer.log('log: ❌ Benutzer brach Chat-Auswahl ab',
                    name: '_showChatSelectionDialog');
                Navigator.of(context).pop(null);
              },
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () {
                developer.log(
                    'log: ❌ Benutzer wählte "Hier behalten" - aber Nachricht gehört zu anderem Chat!',
                    name: '_showChatSelectionDialog');
                // Fehler weiterleiten anstatt Nachricht im falschen Chat zu verarbeiten
                Navigator.of(context).pop('ERROR_WRONG_CHAT');
              },
              style: TextButton.styleFrom(
                backgroundColor: Colors.blue.shade50,
              ),
              child: const Text('Hier behalten'),
            ),
          ],
        );
      },
    );
  }

  // Wechselt zum zugeordneten Chat
  void _switchToAssignedChat(String chatId, String chatName, String scannedData,
      String extractedMetadata) async {
    developer.log('log: 🔄 Starte Chat-Wechsel...',
        name: '_switchToAssignedChat');
    developer.log(
        'log: 📍 Von: ${widget.chatGroupName} (${widget.chatGroupId})',
        name: '_switchToAssignedChat');
    developer.log('log: 📍 Zu: $chatName ($chatId)',
        name: '_switchToAssignedChat');
    developer.log('log: 📱 Nachrichtendaten: ${scannedData.length} Zeichen',
        name: '_switchToAssignedChat');
    developer.log('log: 📋 Metadaten: $extractedMetadata',
        name: '_switchToAssignedChat');

    // Prüfe, ob der Chat-Name auf "Unbekannter Chat" hinweist
    if (chatName.startsWith('Unbekannter Chat')) {
      developer.log(
          'log: ❌ FEHLER: Chat nicht gefunden - versuche alternative Lösungen!',
          name: '_switchToAssignedChat');

      // Versuche eine erneute umfassende Suche
      List<Map<String, String>> allChats = await _getAllAvailableChats();
      Map<String, String>? foundChat;

      for (Map<String, String> chat in allChats) {
        if (chat['id'] == chatId) {
          foundChat = chat;
          break;
        }
      }

      if (foundChat != null) {
        developer.log(
            'log: ✅ Chat doch gefunden in umfassender Suche: "${foundChat['name']}"',
            name: '_switchToAssignedChat');
        // Aktualisiere den Chat-Namen und führe normale Navigation durch
        chatName = foundChat['name']!;
      } else {
        developer.log(
            'log: ❌ Chat wirklich nicht vorhanden - zeige Benutzer-Dialog',
            name: '_switchToAssignedChat');

        // Zeige erweiterte Fehlermeldung mit Optionen
        if (mounted) {
          showDialog(
            context: context,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('❌ Chat nicht gefunden'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Der Chat mit der ID "$chatId" wurde nicht gefunden.'),
                    const SizedBox(height: 12),
                    const Text('Mögliche Ursachen:'),
                    const Text('• Chat wurde gelöscht'),
                    const Text('• Chat-Gruppen-Daten beschädigt'),
                    const Text(
                        '• Verschlüsselungsdatei verweist auf veralteten Chat'),
                    const SizedBox(height: 12),
                    if (allChats.isNotEmpty) ...[
                      const Text('Verfügbare Chats:'),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 100,
                        child: ListView.builder(
                          itemCount: allChats.length,
                          itemBuilder: (context, index) {
                            return Text(
                                '• ${allChats[index]['name']} (ID: ${allChats[index]['id']})');
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('Wählen Sie eine Option:'),
                    ] else
                      const Text(
                          'Die Nachricht wird im aktuellen Chat verarbeitet.'),
                  ],
                ),
                actions: [
                  if (allChats.isNotEmpty) ...[
                    TextButton(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        // Zeige Chat-Auswahl-Dialog
                        String? selectedChatName =
                            await _showChatSelectionDialog(
                                extractedMetadata
                                    .split(';')[0], // Key-Datei-Name
                                allChats,
                                scannedData,
                                extractedMetadata);
                        if (selectedChatName != null &&
                            selectedChatName != 'ERROR_WRONG_CHAT') {
                          // Finde Chat-ID für gewählten Namen
                          for (Map<String, String> chat in allChats) {
                            if (chat['name'] == selectedChatName) {
                              _switchToAssignedChat(
                                  chat['id']!,
                                  selectedChatName,
                                  scannedData,
                                  extractedMetadata);
                              return;
                            }
                          }
                        } else if (selectedChatName == 'ERROR_WRONG_CHAT') {
                          // Zeige Fehlermeldung im aktuellen Chat an
                          setState(() {
                            String messageId =
                                Random().nextInt(1000).toString();
                            messages.add(qgap_model.Message(
                              text:
                                  "❌ FEHLER: Die gescannte Nachricht gehört zu einem anderen Chat und kann nicht im aktuellen Chat \"${widget.chatGroupName}\" entschlüsselt werden.",
                              originalText:
                                  "❌ Fehler: Nachricht gehört zu anderem Chat",
                              isMe: false,
                              id: messageId,
                              timestamp: DateTime.now(),
                              keyFileName: null,
                              byteOffset: null,
                            ));
                            messageQrCodeAvailable[messageId] = false;
                          });
                          _saveChatMessages();
                        }
                      },
                      child: const Text('Chat manuell wählen'),
                    ),
                  ],
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      // Zeige Fehlermeldung anstatt die Nachricht im falschen Chat zu verarbeiten
                      setState(() {
                        String messageId = Random().nextInt(1000).toString();
                        messages.add(qgap_model.Message(
                          text:
                              "❌ FEHLER: Die gescannte Nachricht gehört zu einem anderen Chat und kann nicht im aktuellen Chat \"${widget.chatGroupName}\" entschlüsselt werden.",
                          originalText:
                              "❌ Fehler: Nachricht gehört zu anderem Chat",
                          isMe: false,
                          id: messageId,
                          timestamp: DateTime.now(),
                          keyFileName: null,
                          byteOffset: null,
                        ));
                        messageQrCodeAvailable[messageId] = false;
                      });
                      _saveChatMessages();
                    },
                    child: const Text('Im aktuellen Chat verarbeiten'),
                  ),
                ],
              );
            },
          );
        }
        return; // Navigation abbrechen
      }
    }

    try {
      // Zum richtigen Chat navigieren mit Ersetzung des aktuellen Screens
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: chatName,
            chatGroupId: chatId,
            pendingScannedData: scannedData,
            pendingMetadata: extractedMetadata,
          ),
        ),
      );
      developer.log('log: ✅ Navigation erfolgreich gestartet',
          name: '_switchToAssignedChat');
    } catch (e) {
      developer.log('log: ❌ Fehler bei Navigation: $e',
          name: '_switchToAssignedChat');

      // Bei Navigationsfehler - Fallback: Nachricht im aktuellen Chat verarbeiten
      if (mounted) {
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('❌ Navigationsfehler'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Fehler beim Wechsel zu Chat "$chatName": $e'),
                  const SizedBox(height: 12),
                  const Text(
                      'FEHLER: Die Nachricht kann nicht verarbeitet werden, da sie zu einem anderen Chat gehört.'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    // Zeige Fehlermeldung anstatt die Nachricht im falschen Chat zu verarbeiten
                    setState(() {
                      String messageId = Random().nextInt(1000).toString();
                      messages.add(qgap_model.Message(
                        text:
                            "❌ FEHLER: Navigationsfehler beim Chat-Wechsel zu \"$chatName\". Die gescannte Nachricht gehört zu einem anderen Chat und kann nicht im aktuellen Chat \"${widget.chatGroupName}\" entschlüsselt werden.\n\nFehlerdetails: $e",
                        originalText: "❌ Fehler: Navigation fehlgeschlagen",
                        isMe: false,
                        id: messageId,
                        timestamp: DateTime.now(),
                        keyFileName: null,
                        byteOffset: null,
                      ));
                      messageQrCodeAvailable[messageId] = false;
                    });
                    _saveChatMessages();
                  },
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    }
  }

  // Entschlüsselt eine empfangene RSA oder Hybrid-Nachricht mit dem eigenen privaten Schlüssel.
  // [scannedData] = rekonstruiertes Base64 nach QR-Empfang: base64(metadata)+base64(utf8(payload))
  // [type] = 'RSA' | 'HYB' | 'HYBRID'
  Future<String> _decryptRsaHybridFromData(String scannedData, String type) async {
    try {
      final keyManager = RSAKeyManager();
      final loaded = await keyManager.loadKeyPair();
      if (!loaded) {
        return '❌ [RSA-KEY-01] Kein RSA-Schlüsselpaar vorhanden. Schlüssel generieren!';
      }
      final privKey = keyManager.getMyPrivateKey();
      if (privKey == null) return '❌ [RSA-KEY-02] Privater Schlüssel nicht verfügbar';

      // Payload aus scannedData extrahieren.
      // Je nach Importpfad existieren zwei Formate:
      // 1) Direkt: base64(metadata) + payloadString
      // 2) Wrapped (Transfer-Hub): base64(metadata) + base64(utf8(payloadString))
      final encryptedPart = _extractEncryptedTextWithoutMetadata(scannedData);

      final encryption = RSAEncryption();
      if (type == 'RSA') {
        // RSA-Ciphertext kann direkt oder wrapped vorliegen.
        String rsaCipherBase64 = encryptedPart;
        try {
          final maybeWrapped = utf8.decode(base64.decode(encryptedPart));
          if (_looksLikeBase64(maybeWrapped)) {
            rsaCipherBase64 = maybeWrapped;
          }
        } catch (_) {
          // Direktformat: encryptedPart ist bereits der benötigte Base64-RSA-Block.
        }
        return encryption.decryptWithPrivateKey(rsaCipherBase64, privKey);
      } else {
        // HYB kann als Roh-String oder wrapped übertragen werden.
        String payloadString;
        if (encryptedPart.contains('.')) {
          payloadString = encryptedPart;
        } else {
          final payloadBytes = base64.decode(encryptedPart);
          payloadString = utf8.decode(payloadBytes);
        }

        // payloadString = "encKeyRsaB64.ivBase64.cipherBase64"
        final parts = payloadString.split('.');
        if (parts.length != 3) {
          return '❌ [HYB-FMT-01] Ungültiges Hybrid-Format (${parts.length} Teile)';
        }
        final encKeyRsaB64 = parts[0];
        final iv = Uint8List.fromList(base64.decode(parts[1]));
        final cipherBytesWithTag = Uint8List.fromList(base64.decode(parts[2]));

        final aesKeyBase64 = encryption.decryptWithPrivateKey(encKeyRsaB64, privKey);
        final aesKey = Uint8List.fromList(base64.decode(aesKeyBase64));

        final cipher = pc.GCMBlockCipher(pc.AESEngine());
        final aeadParams = pc.AEADParameters(
          pc.KeyParameter(aesKey), 128, iv, Uint8List(0),
        );
        cipher.init(false, aeadParams);
        final plainBytes = cipher.process(cipherBytesWithTag);
        return utf8.decode(plainBytes);
      }
    } catch (e) {
      developer.log('log: RSA/HYB Entschlüsselung fehlgeschlagen: $e', name: '_decryptRsaHybridFromData');
      return '❌ [DEC-EXC-01] Entschlüsselung fehlgeschlagen: ${e.toString()}';
    }
  }

  bool _looksLikeBase64(String value) {
    if (value.isEmpty || value.length % 4 != 0) return false;
    return RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(value);
  }

  // Fügt eine empfangene Nachricht zum aktuellen Chat hinzu
  void _addReceivedMessage(String scannedData, String extractedMetadata, {String? decryptedText}) {
    setState(() {
      String messageId = Random().nextInt(1000).toString();
      messages.add(qgap_model.Message(
        text: scannedData, // Kompletter gescannter Text
        originalText: decryptedText != null
            ? '🔓 $decryptedText'
            : "📱 QR-Code empfangen: $extractedMetadata", // Info über empfangene Daten
        isMe: false, // Von extern empfangen
        id: messageId,
        timestamp: DateTime.now(),
        keyFileName: null, // Wird aus Metadaten extrahiert
        byteOffset: null, // Wird aus Metadaten extrahiert
      ));

      // Empfangene Nachrichten haben keinen QR-Code-Button (nur gesendete Nachrichten haben QR-Codes)
      messageQrCodeAvailable[messageId] = false;
    });

    // Nachrichten speichern
    _saveChatMessages();

    // System-Benachrichtigung (wenn aktiviert und App im Hintergrund)
    if (NotificationService.enabled) {
      final appState = WidgetsBinding.instance.lifecycleState;
      final isBackground = appState == AppLifecycleState.paused ||
          appState == AppLifecycleState.inactive ||
          appState == AppLifecycleState.hidden;
      if (isBackground) {
        NotificationService().showNewMessagesNotification(
          chatGroupId: widget.chatGroupId,
        );
      }
    }

    // Nochmals Tastatur ausblenden nach setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusScope.of(context).unfocus();
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      _ensureScrollToBottom();
    });
  }

  // Dialog zum Löschen des Chat-Verlaufs
  void _showDeleteChatDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('⚠️ Chat-Verlauf löschen'),
          content: Text(
              'Möchten Sie wirklich den gesamten Chat-Verlauf für "${widget.chatGroupName}" löschen?\n\n'
              'Diese Aktion kann nicht rückgängig gemacht werden!'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () async {
                await _deleteChatHistory();
                Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Löschen'),
            ),
          ],
        );
      },
    );
  }

  // Löscht den kompletten Chat-Verlauf
  Future<void> _deleteChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final messagesKey = 'messages_${widget.chatGroupId}';

      // Chat-Verlauf löschen
      await prefs.remove(messagesKey);

      // Lokale Messages-Liste leeren
      setState(() {
        messages.clear();
      });

      developer.log(
          'log: Chat-Verlauf für Gruppe ${widget.chatGroupName} gelöscht',
          name: '_deleteChatHistory');
    } catch (e) {
      developer.log('log: Fehler beim Löschen des Chat-Verlaufs: $e',
          name: '_deleteChatHistory');
    }
  }

  // Extrahiert die Metadaten (Dateiname;Offset;) aus dem verschlüsselten Text
  /// Prüft ob ein dekodierter Metadaten-String gültig ist (keine False-Positives).
  bool _isValidMetadata(String decoded) {
    // Muss mit Semikolon enden
    if (!decoded.endsWith(';')) return false;
    final parts = decoded.split(';');
    // Mindestens 3 Teile: [dateiname, offset, '']
    if (parts.length < 3) return false;
    final firstPart = parts[0];
    final secondPart = parts[1];
    // Zweites Feld muss eine parsbare nicht-negative Zahl sein (Byte-Offset)
    final offset = int.tryParse(secondPart);
    if (offset == null || offset < 0) return false;
    // Erstes Feld muss bekanntes Format haben
    if (firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID') {
      // Kontaktname (3. Feld) darf nicht leer sein – verhindert False-Positives bei kurzen Metadaten
      if (parts.length < 4 || parts[2].isEmpty) return false;
      return true;
    }
    if (!firstPart.endsWith('.qgap') && !firstPart.endsWith('.qgap_ec')) {
      return false;
    }
    return true;
  }

  /// Findet die korrekte Metadaten-Länge (als Base64-Zeichen) im verschlüsselten String.
  /// Prüft zusätzlich, dass der Rest gültiges Base64 ist (schließt False-Positives aus).
  int _findMetadataLength(String encryptedTextWithMetadata) {
    for (int length = 4; length <= 512; length += 4) {
      if (length > encryptedTextWithMetadata.length) break;
      try {
        final possibleMetadataBase64 =
            encryptedTextWithMetadata.substring(0, length);
        final decodedMetadata =
            utf8.decode(base64.decode(possibleMetadataBase64));
        if (!_isValidMetadata(decodedMetadata)) continue;

        // Sicherstellen dass der Rest nicht leer ist
        final remaining = encryptedTextWithMetadata.substring(length);
        if (remaining.isEmpty) continue;
        // RSA/HYB Payloads können Nicht-Base64-Zeichen enthalten (z.B. Punkte bei Hybrid)
        // -> Für RSA/HYB den Rest-Validierungsschritt überspringen
        final firstPart = decodedMetadata.split(';')[0];
        final isRsaOrHybrid = firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID';
        if (!isRsaOrHybrid) {
          base64.decode(remaining); // wirft FormatException wenn ungültig (nur OTP)
        }
        return length; // Echter Match: Metadaten korrekt abgegrenzt
      } catch (_) {
        continue;
      }
    }
    return -1; // Nicht gefunden
  }

  String _extractMetadataFromText(String encryptedTextWithMetadata) {
    try {
      final len = _findMetadataLength(encryptedTextWithMetadata);
      if (len > 0) {
        return utf8.decode(
            base64.decode(encryptedTextWithMetadata.substring(0, len)));
      }
    } catch (e) {
      developer.log('log: Fehler beim Dekodieren der Metadaten: $e',
          name: '_extractMetadataFromText');
    }
    return 'Keine Metadaten verfügbar';
  }

  /// Erstellt das EC-Metadaten-Snippet (`ECC:<code>;`) für den Online-Versand.
  ///
  /// Liefert
  /// - `''` wenn keine EC-Datei zugeordnet ist (kein Snippet nötig),
  /// - `'ECC:<code>;'` wenn eine EC-Datei mit gültigem Code gewählt ist,
  /// - `null` wenn die zugeordnete EC-Datei keinen Code besitzt (Legacy):
  ///   in diesem Fall wird ein Hinweisdialog angezeigt und der Aufrufer
  ///   muss den Versand abbrechen.
  Future<String?> _buildEcMetaSnippetForOnlineSend() async {
    if (selectedEcFile == null || selectedEcFile!.isEmpty) return '';
    final code =
        EcKeyfileService.extractCodeFromFilename(selectedEcFile!);
    if (code != null) {
      return 'ECC:$code;';
    }
    if (mounted) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) {
          return AlertDialog(
            title: const Text('EC-Datei ohne Code'),
            content: Text(
                'Die zugeordnete EC-Datei "${selectedEcFile!}" enthält keinen '
                'Zufalls-Code im Dateinamen.\n\n'
                'Online-Versand ist nur mit Code möglich, damit das andere '
                'Gerät die Datei eindeutig zuordnen kann.\n\n'
                'Bitte eine neue EC-Datei mit Code erstellen oder die '
                'vorhandene Datei umbenennen (Format: '
                'name_<5-20 Zeichen a-z0-9>.qgap_ec).'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
    }
    return null;
  }

  // Sentinel-Prefix für `originalText` einer geparkten OTP-Nachricht.
  // Format: __PARKED_OTP|<ecCode>|<keyFile>|<byteOffset>|<fileName>
  static const String _kParkedOtpSentinel = '__PARKED_OTP|';
  static const String _kRelayMsgSentinel = '__RELAY_FWD__';
  // B→A: Nachricht vom Tablet, die das Relay-Phone als QR an Air-Gap zeigen soll
  static const String _kRelayBtoASentinel = '__RELAY_BTOA__';

  /// Parkt eine eingehende OTP-Nachricht, wenn die zugehörige EC-Datei lokal
  /// nicht gefunden wurde. Der verschlüsselte Payload wird unter
  /// `Daten/QGap/empfangen_geparkt/<msgId>.blob` abgelegt; in der Chatliste
  /// wird ein Platzhalter-Eintrag erzeugt, der den fehlenden EC-Code anzeigt.
  Future<void> _parkOtpMessage({
    required String fullText,
    required String ecCode,
    required String keyFileName,
    required int byteOffset,
    required String fileName,
    required Uint8List encryptedBytes,
    String? firestoreDocId,
  }) async {
    try {
      final parkDir =
          Directory(AppStorage.empfangenGeparktDir);
      if (!await parkDir.exists()) await parkDir.create(recursive: true);
      final msgId = DateTime.now().millisecondsSinceEpoch.toString();
      final blobFile = File('${parkDir.path}/$msgId.blob');
      await blobFile.writeAsBytes(encryptedBytes, flush: true);

      final isVoice = fileName.endsWith('.ogg') ||
          fileName.endsWith('.m4a') ||
          fileName.endsWith('.mp3');
      final marker =
          '$_kParkedOtpSentinel$ecCode|$keyFileName|$byteOffset|$fileName';
      // Sichtbare Kennzeichnung im UI (Datei-Nachrichtenkopf nutzt
      // attachmentFileName, daher dort den geparkten Status zeigen).
      final visibleName = '🔒 GEPARKT [Code: $ecCode] $fileName';

      if (!mounted) return;
      setState(() {
        messages.add(qgap_model.Message(
          text: fullText,
          originalText: marker,
          isMe: false,
          timestamp: DateTime.now(),
          id: msgId,
          keyFileName: keyFileName,
          byteOffset: byteOffset,
          messageType: isVoice
              ? qgap_model.MessageType.voice
              : qgap_model.MessageType.file,
          attachmentFileName: visibleName,
          attachmentLocalPath: blobFile.path,
          attachmentSize: encryptedBytes.length,
        ));
      });
      if (firestoreDocId != null) {
        _firestoreDocIdForMessage[msgId] = firestoreDocId;
      }
      _saveChatMessages();
      _ensureScrollToBottom();

      // Hinweisdialog für den Empfänger.
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (BuildContext ctx) {
            return AlertDialog(
              title: const Text('🔒 Schlüsseldatei fehlt'),
              content: Text(
                  'Die eingehende Nachricht "$fileName" wurde geparkt.\n\n'
                  'EC-Code: $ecCode\n\n'
                  'Bitte die passende .qgap_ec-Datei (mit diesem Code im '
                  'Dateinamen) per USB importieren. Sobald die Datei lokal '
                  'verfügbar ist, kann die Nachricht über das Chat-Menü '
                  'erneut entschlüsselt werden.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      developer.log('log: Fehler beim Parken der OTP-Nachricht: $e',
          name: '_parkOtpMessage');
    }
  }

  /// Versucht, alle geparkten OTP-Nachrichten erneut zu entschlüsseln. Wird
  /// nach dem Laden des Chats sowie nach Auswahl/Import einer EC-Datei
  /// aufgerufen. Erfolgreich entschlüsselte Nachrichten werden in echte
  /// Datei-/Sprachnachrichten umgewandelt.
  Future<void> _retryParkedMessages() async {
    final List<qgap_model.Message> updates = [];
    for (final msg in messages) {
      if (!msg.originalText.startsWith(_kParkedOtpSentinel)) continue;
      final tail = msg.originalText.substring(_kParkedOtpSentinel.length);
      final parts = tail.split('|');
      if (parts.length < 4) continue;
      final ecCode = parts[0];
      final keyFile = parts[1];
      final offset = int.tryParse(parts[2]) ?? msg.byteOffset ?? 0;
      final fileName = parts.sublist(3).join('|');
      final blobPath = msg.attachmentLocalPath;
      if (blobPath == null) continue;

      final ecFileName = await EcKeyfileService.findEcFileByCode(ecCode);
      if (ecFileName == null) continue;

      try {
        final blob = await File(blobPath).readAsBytes();
        final decryptedBytes =
            _decryptRawBytesXOR(blob, keyFile, offset, ecFileName);
        final saveDir =
            Directory(AppStorage.empfangenDir);
        if (!await saveDir.exists()) await saveDir.create(recursive: true);
        final saveFile = File('${saveDir.path}/$fileName');
        await saveFile.writeAsBytes(decryptedBytes, flush: true);
        updates.add(msg.copyWith(
          originalText: fileName,
          attachmentFileName: fileName,
          attachmentLocalPath: saveFile.path,
          attachmentSize: decryptedBytes.length,
        ));
        // Geparktes Blob entfernen.
        try {
          await File(blobPath).delete();
        } catch (_) {}
      } catch (e) {
        developer.log(
            'log: Retry der geparkten Nachricht fehlgeschlagen ($ecCode): $e',
            name: '_retryParkedMessages');
      }
    }
    if (updates.isEmpty) return;
    if (!mounted) return;
    setState(() {
      for (final updated in updates) {
        final idx = messages.indexWhere((m) => m.id == updated.id);
        if (idx >= 0) messages[idx] = updated;
      }
    });
    await _saveChatMessages();
  }

  // Extrahiert nur den verschlüsselten Text ohne Metadaten
  String _extractEncryptedTextWithoutMetadata(
      String encryptedTextWithMetadata) {
    final len = _findMetadataLength(encryptedTextWithMetadata);
    if (len > 0) {
      return encryptedTextWithMetadata.substring(len);
    }
    return encryptedTextWithMetadata; // Fallback: ganzen Text zurückgeben
  }

  // Dekodiert Base64-Text zu lesbarem Text (für empfangene Nachrichten)
  String _decodeBase64ToReadableText(String base64Text) {
    try {
      // Extrahiere die Metadaten
      String metadata = _extractMetadataFromText(base64Text);

      // Kombiniere Metadaten und dekodierten Text
      String result = '';

      // Metadaten hinzufügen
      if (metadata != 'Keine Metadaten verfügbar') {
        result += '$metadata\n';

        // Versuche zu entschlüsseln
        try {
          // Parse Metadaten: dateiname.qgap;123; oder RSA;chatId;contact; oder HYB;chatId;contact;
          List<String> metaParts = metadata.split(';');
          if (metaParts.length >= 2) {
            String keyFileName = metaParts[0];

            // RSA/HYB: Entschlüsselung erfolgt asynchron beim Empfang, hier nur Info anzeigen
            if (keyFileName == 'RSA' || keyFileName == 'HYB' || keyFileName == 'HYBRID') {
              final encType = keyFileName == 'RSA' ? 'RSA' : 'Hybrid (RSA+AES)';
              final contact = metaParts.length >= 3 ? metaParts[2] : '?';
              result += 'ℹ️ $encType-verschlüsselt für: $contact\n'
                        '(Entschlüsselung beim Empfang via QR-Scan)';
            } else {
              int byteOffset = int.tryParse(metaParts[1]) ?? 0;

              // EC-Datei aus Metadaten extrahieren (optional, ab Index 2)
              String? ecFileName;
              for (int i = 2; i < metaParts.length; i++) {
                final part = metaParts[i];
                if (part.startsWith('ECC:')) {
                  // ECC-Code synchron auflösen — ohne EC-Schicht wäre das
                  // Ergebnis Zeichensalat (Bug: Windows-Anzeige).
                  ecFileName =
                      EcKeyfileService.findEcFileByCodeSync(part.substring(4));
                  break;
                }
                if (part.startsWith('EC:')) {
                  ecFileName = part.substring(3);
                  break;
                }
              }

              // Extrahiere den verschlüsselten Teil
              String encryptedPart =
                  _extractEncryptedTextWithoutMetadata(base64Text);

              // Entschlüssele mit der angegebenen Datei und Offset (+ EC-Datei falls vorhanden)
              String decryptedText =
                  _decryptWithXOR(encryptedPart, keyFileName, byteOffset, ecFileName);

              if (decryptedText.isNotEmpty) {
                // Prüfe ob es sich um eine Fehlermeldung handelt
                if (decryptedText.contains('fehlgeschlagen') ||
                    decryptedText.contains('Fehler') ||
                    decryptedText.contains('fehlt')) {
                  result +=
                      '❗ Entschlüsselter Text:\n─────────────────────\n$decryptedText';
                } else {
                  result +=
                      '✅ Entschlüsselter Text:\n─────────────────────\n$decryptedText';
                }
              } else {
                result += '⚠️ Entschlüsselung fehlgeschlagen';
              }
            }
          } else {
            result += '⚠️ Ungültige Metadaten-Format';
          }
        } catch (e) {
          result += '⚠️ Fehler bei Entschlüsselung: ${e.toString()}';
          developer.log('log: Fehler bei Entschlüsselung: $e',
              name: '_decodeBase64ToReadableText');
        }
      } else {
        result += '⚠️ Keine Metadaten verfügbar';
      }

      return result;
    } catch (e) {
      developer.log('log: Fehler beim Dekodieren des Base64-Texts: $e',
          name: '_decodeBase64ToReadableText');
      return 'Fehler beim Dekodieren als Text';
    }
  }

  // Baut formatierten Text mit unterschiedlichen Schriftgrößen für Text über und unter der Linie
  Widget _buildFormattedDecryptedText(String base64Text) {
    String decodedText = _decodeBase64ToReadableText(base64Text);

    // Teile den Text an der horizontalen Linie
    List<String> parts = decodedText.split('─────────────────────');

    if (parts.length == 2) {
      // Text enthält eine Linie - formatiere entsprechend
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Text über der Linie: normal, 10px
          Text(
            parts[0].trim(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.normal,
            ),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 4),
          // Horizontale Linie
          const Text(
            '─────────────────────',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.normal,
            ),
          ),
          const SizedBox(height: 4),
          // Text unter der Linie: fett, 14px
          SelectableText(
            parts[1].trim(),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.left,
          ),
        ],
      );
    } else {
      // Kein Linienseparator gefunden - zeige alles mit 14px fett
      return SelectableText(
        decodedText,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.left,
      );
    }
  }

  /// Zeigt nur den entschlüsselten Text ohne Metadaten (kompakte Ansicht
  /// wenn Verschlüsselungs-Infos ausgeblendet sind).
  Widget _buildDecryptedTextCompact(qgap_model.Message message) {
    // Entschlüsselter Text ist in originalText als '🔓 <text>' gespeichert
    if (message.originalText.startsWith('🔓 ')) {
      return SelectableText(
        message.originalText.substring(2).trim(),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        textAlign: TextAlign.left,
      );
    }
    // Fehlermeldungen (EC-Datei fehlt, Entschlüsselung fehlgeschlagen, …)
    if (message.originalText.startsWith('⏳') ||
        message.originalText.startsWith('❌') ||
        message.originalText.startsWith('⚠️')) {
      return Text(
        message.originalText,
        style: TextStyle(fontSize: 13, color: Colors.orange.shade800),
      );
    }
    // Fallback: OTP-Entschlüsselung on-the-fly (nur den Text-Teil nach dem Trennstrich)
    try {
      final decoded = _decodeBase64ToReadableText(message.text);
      final parts = decoded.split('─────────────────────');
      if (parts.length >= 2) {
        return SelectableText(
          parts[1].trim(),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          textAlign: TextAlign.left,
        );
      }
    } catch (_) {}
    return SelectableText(
      message.originalText,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
    );
  }

  /// Einheitliche Anzeige für empfangene Verschlüsselungsinfos (OTP, RSA, Hybrid).
  /// RSA/Hybrid werden im selben Stil wie OTP dargestellt.
  Widget _buildReceivedEncryptionInfo(qgap_model.Message message) {
    // Für RSA/Hybrid ist der entschlüsselte Text bereits in originalText vorhanden.
    // WICHTIG: OTP-Nachrichten haben originalText AUCH als '🔓 ...' – deshalb
    // nur den RSA/Hybrid-Pfad nehmen wenn der Verschlüsselungstyp das bestätigt.
    // Sonst entsteht ein doppelter entschlüsselter Text (einmal aus originalText,
    // einmal aus _decodeBase64ToReadableText).
    final isRsaOrHybrid =
        message.encryptionType == qgap_model.EncryptionType.rsa ||
        message.encryptionType == qgap_model.EncryptionType.hybrid;
    if (isRsaOrHybrid && message.originalText.startsWith('🔓 ')) {
      final baseInfo = _decodeBase64ToReadableText(message.text);
      final decrypted = message.originalText.substring(2).trim();
      final composed = '$baseInfo\n✅ Entschlüsselter Text:\n─────────────────────\n$decrypted';

      final parts = composed.split('─────────────────────');
      if (parts.length == 2) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              parts[0].trim(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.normal,
              ),
              textAlign: TextAlign.left,
            ),
            const SizedBox(height: 4),
            const Text(
              '─────────────────────',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              parts[1].trim(),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.left,
            ),
          ],
        );
      }

      return SelectableText(
        composed,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
        textAlign: TextAlign.left,
      );
    }

    return _buildFormattedDecryptedText(message.text);
  }

  // Entschlüsselt Base64-verschlüsselten Text mit XOR
  String _decryptWithXOR(
      String encryptedBase64, String keyFileName, int byteOffset,
      [String? ecFileName]) {
    try {
      developer.log(
          'log: Starte Entschlüsselung: Base64 ${encryptedBase64.length} Zeichen, Datei: $keyFileName, Offset: $byteOffset, EC: $ecFileName',
          name: '_decryptWithXOR');

      // Base64 dekodieren
      List<int> encryptedBytes = base64.decode(encryptedBase64);
      developer.log('log: Base64 dekodiert zu ${encryptedBytes.length} bytes',
          name: '_decryptWithXOR');

      // Key-Datei laden und entschlüsseln
      String result =
          _decryptBytesWithKey(encryptedBytes, keyFileName, byteOffset, ecFileName);

      developer.log(
          'log: Entschlüsselungsergebnis: "${result.substring(0, result.length > 100 ? 100 : result.length)}..."',
          name: '_decryptWithXOR');

      return result;
    } catch (e) {
      developer.log('log: Fehler beim Entschlüsseln: $e',
          name: '_decryptWithXOR');
      return 'Entschlüsselung fehlgeschlagen: ${e.toString()}';
    }
  }

  // Entschlüsselt Bytes mit einem Key ab einer bestimmten Position
  String _decryptBytesWithKey(
      List<int> encryptedBytes, String keyFileName, int byteOffset,
      [String? ecFileName]) {
    try {
      developer.log(
          'log: Versuche Entschlüsselung mit $keyFileName ab Byte $byteOffset',
          name: '_decryptBytesWithKey');

      // Eine XOR-Schicht: ecFileName (via ECC-Code aufgelöst) ist Fallback,
      // falls die Schlüsseldatei lokal unter anderem Namen liegt.
      List<int> keyBytes = _loadKeyFileSync(keyFileName);
      if (keyBytes.isEmpty && ecFileName != null && ecFileName.isNotEmpty) {
        keyBytes = _loadEcFileSync(ecFileName);
      }

      if (keyBytes.isEmpty) {
        throw Exception('Key-Datei "$keyFileName" fehlt!');
      }

      developer.log(
          'log: Verwende Key mit ${keyBytes.length} Bytes, Offset: $byteOffset',
          name: '_decryptBytesWithKey');

      // XOR-Entschlüsselung mit Offset
      List<int> decryptedBytes =
          List<int>.generate(encryptedBytes.length, (i) {
        int keyIndex = (byteOffset + i) % keyBytes.length;
        return encryptedBytes[i] ^ keyBytes[keyIndex];
      });

      // Versuche als UTF-8 zu dekodieren
      String decryptedText = utf8.decode(decryptedBytes, allowMalformed: true);

      // Entferne nur Null-Bytes und andere problematische Steuerzeichen, aber behalte Umlaute
      String cleanText = decryptedText.replaceAll(
          RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'), '');

      developer.log(
          'log: Entschlüsselter Text: "${cleanText.substring(0, cleanText.length > 50 ? 50 : cleanText.length)}..."',
          name: '_decryptBytesWithKey');

      return cleanText.isNotEmpty
          ? cleanText
          : 'Kein lesbarer Text nach Entschlüsselung';
    } catch (e) {
      developer.log('log: Fehler beim Entschlüsseln der Bytes: $e',
          name: '_decryptBytesWithKey');
      return 'Bytes-Entschlüsselung fehlgeschlagen \n ${e.toString()}';
    }
  }

  // Ermittelt die Dateigröße einer Key-Datei
  int _getKeyFileSize(String keyFileName) {
    keyFileName = AppStorage.fileNameOf(keyFileName);
    try {
      final possiblePaths = [
        AppStorage.keyFilePath(keyFileName),
        if (Platform.isAndroid) ...[
          '/sdcard/Daten/QGap/schluessel/$keyFileName',
          // USB-Stick Pfade (statisch)
          '/storage/usbotg/Daten/QGap/schluessel/$keyFileName',
          '/mnt/usb/Daten/QGap/schluessel/$keyFileName',
          '/mnt/media_rw/usbotg/Daten/QGap/schluessel/$keyFileName',
        ],
      ];
      // Dynamisch ermittelte USB-Pfade: Scan /storage/ nach externen Datenträgern
      if (Platform.isAndroid) {
        try {
          final storageDir = Directory('/storage');
          if (storageDir.existsSync()) {
            for (final entity in storageDir.listSync()) {
              if (entity is Directory) {
                final name = entity.path.split('/').last;
                if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
                  possiblePaths.add('${entity.path}/Daten/QGap/schluessel/$keyFileName');
                }
              }
            }
          }
        } catch (e) { /* USB-Scan-Fehler ignorieren */ }
      }

      for (String path in possiblePaths) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            int fileSize = file.lengthSync();
            developer.log('log: Dateigröße für $keyFileName: $fileSize bytes',
                name: '_getKeyFileSize');
            return fileSize;
          }
        } catch (e) {
          developer.log(
              'log: Fehler beim Ermitteln der Dateigröße von $path: $e',
              name: '_getKeyFileSize');
          continue;
        }
      }

      developer.log(
          'log: Key-Datei $keyFileName nicht gefunden für Größenermittlung',
          name: '_getKeyFileSize');
      return 0;
    } catch (e) {
      developer.log('log: Fehler beim Ermitteln der Dateigröße: $e',
          name: '_getKeyFileSize');
      return 0;
    }
  }

  // Lädt Key-Datei synchron (vereinfachte Version)
  List<int> _loadKeyFileSync(String keyFileName) {
    keyFileName = AppStorage.fileNameOf(keyFileName);
    try {
      final possiblePaths = [
        AppStorage.keyFilePath(keyFileName),
        if (Platform.isAndroid) ...[
          '/sdcard/Daten/QGap/schluessel/$keyFileName',
          // USB-Stick Pfade (statisch)
          '/storage/usbotg/Daten/QGap/schluessel/$keyFileName',
          '/mnt/usb/Daten/QGap/schluessel/$keyFileName',
          '/mnt/media_rw/usbotg/Daten/QGap/schluessel/$keyFileName',
        ],
      ];
      // Dynamisch ermittelte USB-Pfade: Scan /storage/ nach externen Datenträgern
      if (Platform.isAndroid) {
        try {
          final storageDir = Directory('/storage');
          if (storageDir.existsSync()) {
            for (final entity in storageDir.listSync()) {
              if (entity is Directory) {
                final name = entity.path.split('/').last;
                if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
                  possiblePaths.add('${entity.path}/Daten/QGap/schluessel/$keyFileName');
                }
              }
            }
          }
        } catch (e) { /* USB-Scan-Fehler ignorieren */ }
      }

      for (String path in possiblePaths) {
        try {
          final file = File(path);
          if (file.existsSync()) {
            List<int> keyBytes = file.readAsBytesSync();
            developer.log(
                'log: Key-Datei geladen: $path (${keyBytes.length} bytes)',
                name: '_loadKeyFileSync');
            return keyBytes;
          }
        } catch (e) {
          developer.log('log: Fehler beim Laden von $path: $e',
              name: '_loadKeyFileSync');
          continue;
        }
      }

      developer.log('log: Key-Datei $keyFileName nicht gefunden',
          name: '_loadKeyFileSync');
      return [];
    } catch (e) {
      developer.log('log: Fehler beim synchronen Laden der Key-Datei: $e',
          name: '_loadKeyFileSync');
      return [];
    }
  }

  // Findet den Speicherort einer Schlüsseldatei
  Future<String?> _findKeyFileLocation(String fileName) async {
    fileName = AppStorage.fileNameOf(fileName);
    // Alle möglichen Pfade prüfen
    List<String> possiblePaths = [
      AppStorage.keyFilePath(fileName),
      '/sdcard/Daten/QGap/schluessel/$fileName',
      // USB-Stick Pfade (statisch)
      '/storage/usbotg/Daten/QGap/schluessel/$fileName',
      '/mnt/usb/Daten/QGap/schluessel/$fileName',
      '/mnt/media_rw/usbotg/Daten/QGap/schluessel/$fileName',
    ];
    // Dynamisch ermittelte USB-Pfade
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
              possiblePaths.add('${entity.path}/Daten/QGap/schluessel/$fileName');
            }
          }
        }
      }
    } catch (e) { /* USB-Scan-Fehler ignorieren */ }

    for (String path in possiblePaths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          developer.log('log: 📍 Schlüsseldatei gefunden: $path',
              name: '_findKeyFileLocation');

          // Kategorisierung des Speicherorts
          if (path.startsWith(AppStorage.schluesselDir) ||
              path.contains('/storage/emulated/0/') ||
              path.contains('/sdcard/')) {
            return 'local'; // Lokaler Speicher
          } else {
            return 'usb'; // Alle nicht-lokalen Pfade = USB-Stick
          }
        }
      } catch (e) {
        // Fehler beim Zugriff ignorieren
        continue;
      }
    }

    developer.log('log: ❌ Schlüsseldatei nicht gefunden: $fileName',
        name: '_findKeyFileLocation');
    return null; // Datei nicht gefunden
  }

  @override
  void dispose() {
    _firestoreSubscription?.cancel();
    _inputFocusNode.dispose();
    _textController.dispose();
    _scrollController.dispose();
    _recordingTimer?.cancel();
    _playerCompleteSub?.cancel();
    _recorder.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _loadKeyInfo() async {
    if (selectedKeyFile == null) {
      setState(() {
        keyInfo = 'Keine Key-Datei zugeordnet';
      });
      return;
    }

    developer.log('log: Lade Key-Info für Datei: $selectedKeyFile',
        name: '_loadKeyInfo');
    try {
      final keyResult = await ladeKeyAusDatei(selectedKeyFile!);
      developer.log('log: Key-Result: ${keyResult.toString().length}',
          name: '_loadKeyInfo');

      // Lade die gespeicherte Byte-Position für diese Datei
      await _loadUsedKeyBytes();

      setState(() {
        keyInfo = keyResult['info'] ?? 'Unbekannt';
      });
      developer.log(
          'log: Key-Info aktualisiert: $keyInfo, verwendete Bytes: $usedKeyBytes',
          name: '_loadKeyInfo');
    } catch (e) {
      developer.log('log: Fehler beim Laden der Key-Info: $e',
          name: '_loadKeyInfo');
      setState(() {
        keyInfo = 'Fehler: $e';
      });
    }
  }

  void _showSettingsDialog() async {
    // Überprüfe zuerst, ob eine Key-Datei zugeordnet ist
    if (selectedKeyFile == null) {
      _showMandatoryKeyFileSelection();
      return;
    }

    String tempSelectedFile = selectedKeyFile!; // Temporäre Variable für Dialog

    // Nur unzugeordnete Dateien laden (plus die aktuell ausgewählte)
    List<String> availableFiles = await _getUnassignedKeyFiles();

    // Wenn keine Key-Dateien verfügbar sind, trotzdem Dialog öffnen mit aktuellem Key
    if (availableFiles.isEmpty) {
      availableFiles = [selectedKeyFile!];
      developer.log('log: Keine weiteren Key-Dateien gefunden, zeige Dialog mit aktuellem Key',
          name: '_showSettingsDialog');
    }

    // Wenn die aktuell ausgewählte Datei nicht verfügbar ist, erste verfügbare nehmen
    if (!availableFiles.contains(tempSelectedFile)) {
      tempSelectedFile = availableFiles.first;
    }

    // EC-Dateien laden (immer alle, da der Nutzer im Dialog umschalten kann)
    final List<String> availableEcFiles =
        await _getAvailableEcFiles(usbOnly: false);

    // Kontakt-Schlüssel Fingerprint laden
    final String? contactKeyFingerprint = await _getContactKeyFingerprint();

    // BuildContext check vor Dialog - nach async operation
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return SettingsDialogWidget(
          chatGroupName: widget.chatGroupName,
          availableFiles: availableFiles,
          initialSelectedFile: tempSelectedFile,
          initialOffset: usedKeyBytes,
          initialEncryptionType: currentEncryptionType,
          getKeyFileSize: _getKeyFileSize,
          availableEcFiles: availableEcFiles,
          initialEcFile: selectedEcFile,
          initialEcUsbOnly: ecUsbOnly,
          initialContactKeyFingerprint: contactKeyFingerprint,
          onScanContactPublicKey: () => _scanContactPublicKey(dialogContext),
          onShowMyPublicKey: () => _showMyPublicKeyQR(dialogContext),
          onSave: (String selectedFile, int newOffset,
              qgap_model.EncryptionType newEncryptionType,
              String? newEcFile,
              bool newEcUsbOnly) async {
            // Lokale Kopie des Kontexts vor async operations
            final navigator = Navigator.of(dialogContext);

            setState(() {
              selectedKeyFile = selectedFile;
              usedKeyBytes = newOffset;
              currentEncryptionType = newEncryptionType;
              selectedEcFile = newEcFile;
              ecUsbOnly = newEcUsbOnly;
            });

            // Datei-Zuordnung speichern
            await _saveSelectedKeyFile();

            // Neuen Byte-Offset speichern
            await _saveUsedKeyBytes();

            // Verschlüsselungsart speichern
            await _saveEncryptionType();

            // EC-Einstellungen speichern
            await _saveEcSettings();

            // BuildContext check vor Navigation
            if (!mounted) return;
            navigator.pop();

            // Key-Info sofort neu laden
            await _loadKeyInfo();

            developer.log(
                'log: 🔄 Einstellungen abgeschlossen - Key: $selectedKeyFile, Offset: $usedKeyBytes, EC: $selectedEcFile (usbOnly=$ecUsbOnly)',
                name: '_showSettingsDialog');
          },
        );
      },
    );
  }

  /// Berechnet den Fingerprint des gespeicherten öffentlichen Schlüssels des Kontakts.
  Future<String?> _getContactKeyFingerprint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final contactName =
          prefs.getString('chat_contact_${widget.chatGroupId}') ??
          widget.chatGroupName;
      final keyManager = RSAKeyManager();
      final pubKey = await keyManager.getContactPublicKey(contactName);
      if (pubKey == null) return null;
      final keyJson = jsonEncode({
        'modulus': pubKey.modulus.toString(),
        'exponent': pubKey.exponent.toString(),
      });
      final digest = crypto.sha256.convert(utf8.encode(keyJson)).bytes;
      return digest.take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(':')
          .toUpperCase();
    } catch (_) {
      return null;
    }
  }

  /// Lädt den Kontaktschlüssel-Status aus den Prefs und prüft ob der Key vorhanden ist.
  Future<void> _loadContactKeyStatus() async {
    if (currentEncryptionType != qgap_model.EncryptionType.rsa &&
        currentEncryptionType != qgap_model.EncryptionType.hybrid) { return; }
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('chat_contact_${widget.chatGroupId}');
    if (name != null && name.isNotEmpty) {
      final keyManager = RSAKeyManager();
      final pubKey = await keyManager.getContactPublicKey(name);
      if (mounted) {
        setState(() {
          _chatContactName = name;
          _hasContactKey = pubKey != null;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _chatContactName = null;
          _hasContactKey = false;
        });
      }
    }
  }

  /// Importiert einen Kontakt-Public-Key aus einer .qgap_aes Datei.
  Future<void> _importContactKeyFromQGapAes() async {
    try {
      FilePickerResult? result;
      try {
        result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['qgap_aes'],
          allowMultiple: false,
          withData: false,
          dialogTitle: 'Kontakt-Public-Key (.qgap_aes) wählen',
        );
      } catch (e) {
        result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
          withData: false,
        );
      }
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (!picked.name.toLowerCase().endsWith('.qgap_aes')) {
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('Nur .qgap_aes-Dateien werden unterstützt (gewählt: ${picked.name})')),
          );
        }
        return;
      }
      // Bytes lesen (USB/Content-URI oder direkt)
      Uint8List? bytes;
      final path = picked.path;
      if (path != null && path.isNotEmpty) {
        if (path.startsWith('content://')) {
          const ch = MethodChannel('de.paulporg.obmc/file_intent');
          final raw = await ch.invokeMethod<Uint8List>('readContentUri', path);
          bytes = raw;
        } else {
          bytes = await File(path).readAsBytes();
        }
      }
      if (bytes == null || bytes.isEmpty) {
        if (mounted) showQgapSnackBar(context, const SnackBar(content: Text('Datei konnte nicht gelesen werden')));
        return;
      }
      final content = utf8.decode(bytes);
      final keyManager = RSAKeyManager();
      final publicKey = keyManager.loadPublicKeyFromQRCode(content);
      if (publicKey == null) {
        if (mounted) {
          showQgapSnackBar(context, const SnackBar(
            content: Text('❌ Ungültige .qgap_aes Datei'),
            backgroundColor: Colors.red,
          ));
        }
        return;
      }
      // Kontaktname vorschlagen aus Dateiname
      final prefs = await SharedPreferences.getInstance();
      final existingName = prefs.getString('chat_contact_${widget.chatGroupId}');
      String suggested = existingName ?? widget.chatGroupName;
      final fn = picked.name;
      if (fn.startsWith('Public_Key_') && fn.endsWith('.qgap_aes')) {
        suggested = fn.replaceFirst('Public_Key_', '').replaceAll('.qgap_aes', '');
      }
      final nameCtrl = TextEditingController(text: suggested);
      if (!mounted) return;
      final contactName = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Kontaktname'),
          content: TextField(
            controller: nameCtrl,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Alice'),
            autofocus: true,
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()), child: const Text('Übernehmen')),
          ],
        ),
      );
      if (contactName == null || contactName.isEmpty) return;
      // Eindeutigkeit: Kein Kontakt darf zwei Chats zugeordnet sein
      final usedBy = await ContactUtils.findChatUsingContact(
        contactName,
        excludeChatId: widget.chatGroupId,
      );
      if (usedBy != null) {
        if (mounted) {
          showQgapSnackBar(context, SnackBar(
            content: Text('❌ Kontakt "$contactName" ist bereits dem Chat "$usedBy" zugeordnet.'),
            backgroundColor: Colors.red,
          ));
        }
        return;
      }
      await keyManager.saveContactPublicKey(contactName, publicKey);
      await prefs.setString('chat_contact_${widget.chatGroupId}', contactName);
      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text('✅ Schlüssel für "$contactName" importiert'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, SnackBar(content: Text('Fehler: $e')));
      }
    }
  }

  /// Öffnet den QR-Scanner, liest den öffentlichen Schlüssel des Kontakts ein
  /// und speichert ihn. Gibt den Fingerprint zurück oder null bei Fehler/Abbruch.
  Future<String?> _scanContactPublicKey(BuildContext dialogContext) async {
    if (!mounted) return null;

    final receivedBytes = await Navigator.of(dialogContext).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const QrDataReceiver()),
    );

    if (receivedBytes == null || !mounted) return null;

    try {
      final decoded = utf8.decode(receivedBytes);
      // Abwärtskompatibel: altes Präfix OBMC_RSA_PUB: weiterhin akzeptieren
      const legacyPrefix = 'OBMC_RSA_PUB:';
      const newPrefix = 'QGAP_RSA_PUB:';
      final matchedPrefix = decoded.startsWith(newPrefix)
          ? newPrefix
          : (decoded.startsWith(legacyPrefix) ? legacyPrefix : null);
      if (matchedPrefix == null) {
        showQgapSnackBar(context, 
          const SnackBar(
            content: Text('❌ Ungültiger QR-Code: Kein RSA-Public-Key'),
            backgroundColor: Colors.red,
          ),
        );
        return null;
      }
      final keyJson = decoded.substring(matchedPrefix.length);
      final data = jsonDecode(keyJson) as Map<String, dynamic>;
      final modulus = BigInt.parse(data['modulus'].toString());
      final exponent = BigInt.parse(data['exponent'].toString());
      final pubKey = pc.RSAPublicKey(modulus, exponent);

      final keyManager = RSAKeyManager();
      // Unter dem bereits zugeordneten Kontaktnamen speichern, damit der Schlüssel
      // beim Verschlüsseln korrekt gefunden wird. Fallback: chatGroupName.
      final prefs = await SharedPreferences.getInstance();
      final assignedContactName =
          prefs.getString('chat_contact_${widget.chatGroupId}') ??
          widget.chatGroupName;
      // Eindeutigkeit: nur prüfen wenn der Name noch nicht diesem Chat zugeordnet ist
      final alreadyAssigned = prefs.getString('chat_contact_${widget.chatGroupId}');
      if (alreadyAssigned == null) {
        // Neuzuordnung: prüfen ob der Name schon bei einem anderen Chat belegt ist
        final usedByScan = await ContactUtils.findChatUsingContact(
          assignedContactName,
          excludeChatId: widget.chatGroupId,
        );
        if (usedByScan != null) {
          if (mounted) {
            showQgapSnackBar(context, SnackBar(
              content: Text('❌ Kontakt "$assignedContactName" ist bereits dem Chat "$usedByScan" zugeordnet.'),
              backgroundColor: Colors.red,
            ));
          }
          return null;
        }
      }
      await keyManager.saveContactPublicKey(assignedContactName, pubKey);
      // Kontaktzuordnung sicherstellen
      await prefs.setString('chat_contact_${widget.chatGroupId}', assignedContactName);

      final digest = crypto.sha256.convert(utf8.encode(keyJson)).bytes;
      final fingerprint = digest.take(8)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(':')
          .toUpperCase();

      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('✅ Öffentlicher Schlüssel gespeichert\nFingerprint: $fingerprint'),
            backgroundColor: Colors.green,
          ),
        );
        _loadContactKeyStatus(); // Status-Bar aktualisieren
      }
      return fingerprint;
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('❌ Fehler beim Einlesen des Schlüssels: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  /// Zeigt den eigenen öffentlichen RSA-Schlüssel als QR-Code an.
  /// Exportiert den eigenen RSA-Public-Key als .qgap_aes Datei (speichern oder teilen).
  Future<void> _exportMyPublicKeyAsFile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pubKeyString = prefs.getString('rsa_public_key');
      if (pubKeyString == null) {
        if (mounted) {
          showQgapSnackBar(context, 
            const SnackBar(
              content: Text('❌ Kein RSA-Schlüsselpaar gefunden. Bitte zuerst Schlüssel generieren.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      final content = 'QGAP_RSA_PUB:$pubKeyString';
      final contentBytes = Uint8List.fromList(utf8.encode(content));
      final fileName = 'Public_Key_${widget.chatGroupName}.qgap_aes';
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Eigenen Schlüssel exportieren'),
          content: Text('Datei "$fileName" speichern oder teilen?'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen')),
            TextButton(onPressed: () => Navigator.of(ctx).pop('save'), child: const Text('💾 Speichern')),
            TextButton(onPressed: () => Navigator.of(ctx).pop('share'), child: const Text('📤 Teilen')),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'save') {
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: contentBytes,
          type: FileType.any,
        );
        if (mounted && savedPath != null) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('✅ "$fileName" gespeichert'), duration: const Duration(seconds: 2)),
          );
        }
      } else {
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(contentBytes, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: fileName)],
          subject: fileName,
        );
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, SnackBar(content: Text('Fehler: $e')));
      }
    }
  }

  void _showMyPublicKeyQR([BuildContext? dialogContext]) async {
    try {
      // Nur den öffentlichen Schlüssel direkt aus SharedPreferences lesen.
      // loadKeyPair() wird bewusst NICHT verwendet, da es auch den privaten
      // Schlüssel parst (deprecated RSAPrivateKey-Konstruktor) und bei Fehler
      // false zurückgibt – obwohl der öffentliche Schlüssel korrekt gespeichert ist.
      final prefs = await SharedPreferences.getInstance();
      final pubKeyString = prefs.getString('rsa_public_key');

      if (pubKeyString == null) {
        if (!mounted) return;
        showQgapSnackBar(context, 
          const SnackBar(
            content: Text('❌ Kein RSA-Schlüsselpaar gefunden. Bitte zuerst unter Menü → RSA-Schlüssel generieren.'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // pubKeyString ist bereits das JSON {"modulus":"...","exponent":"..."}
      // das direkt als QGAP_RSA_PUB:-Payload verwendet werden kann.
      final payload = Uint8List.fromList(utf8.encode('QGAP_RSA_PUB:$pubKeyString'));

      if (!mounted) return;
      // Falls aus einem Dialog heraus aufgerufen: Dialog schließen
      if (dialogContext != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      }
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => QrDataSender(bytes: payload),
        ),
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('❌ Fehler beim Laden des Schlüssels: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showAvailableFiles() async {
    List<String> foundFiles = [];
    Map<String, String> fileAssignments = {}; // Datei -> Chat-Name

    try {
      // Prüfe Daten/QGap/schluessel Unterordner - sowohl lokal als auch auf USB-Stick
      final searchDirs = [
        Directory(AppStorage.schluesselDir),
        // USB-Stick Verzeichnisse (statisch)
        Directory('/storage/usbotg/Daten/QGap/schluessel'),
        Directory('/mnt/usb/Daten/QGap/schluessel'),
        Directory('/mnt/media_rw/usbotg/Daten/QGap/schluessel'),
      ];
      // Dynamisch ermittelte USB-Pfade hinzufügen
      try {
        final storageDir = Directory('/storage');
        if (await storageDir.exists()) {
          await for (final entity in storageDir.list()) {
            if (entity is Directory) {
              final name = entity.path.split('/').last;
              if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
                searchDirs.add(Directory('${entity.path}/Daten/QGap/schluessel'));
              }
            }
          }
        }
      } catch (e) { /* USB-Scan-Fehler ignorieren */ }

      for (var downloadDir in searchDirs) {
        if (await downloadDir.exists()) {
          developer.log('log: Durchsuche Ordner: ${downloadDir.path}',
              name: '_showAvailableFiles');
          final files = await downloadDir.list().toList();
          for (var file in files) {
            if (file is File) {
              final fileName = AppStorage.fileNameOf(file.path);
              // Nur Dateien mit .qgap* Endung anzeigen
              if (fileName.toLowerCase().contains('.qgap')) {
                if (!foundFiles.contains(fileName)) {
                  foundFiles.add(fileName);

                  // Prüfen ob die Datei zugewiesen ist
                  String? assignedChatName =
                      await _getChatNameForFile(fileName);
                  if (assignedChatName != null) {
                    fileAssignments[fileName] = assignedChatName;
                  } else if (fileName == selectedKeyFile) {
                    fileAssignments[fileName] =
                        widget.chatGroupName; // Aktueller Chat
                  }
                }
              }
            }
          }
        }
      }
    } catch (e) {
      foundFiles.add('Fehler beim Listen: $e');
    }

    // BuildContext check vor Dialog - nach async operations
    if (!mounted) return;

    // Lokale Kopie des Contexts vor dem Dialog
    final dialogContext = context;

    showDialog(
      context: dialogContext,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Verfügbare .qgap* Dateien mit Zuordnungen'),
          content: SizedBox(
            width: double.maxFinite,
            child: foundFiles.isEmpty
                ? const Text(
                    'Keine .qgap Dateien gefunden oder keine Berechtigung')
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: foundFiles.length,
                    itemBuilder: (context, index) {
                      final fileName = foundFiles[index];
                      final assignedChat = fileAssignments[fileName];

                      return ListTile(
                        leading: Icon(
                          fileName == selectedKeyFile
                              ? Icons.security
                              : Icons.description,
                          color:
                              fileName == selectedKeyFile ? Colors.green : null,
                        ),
                        title: Text(fileName),
                        subtitle: assignedChat != null
                            ? Text(
                                '📌 Zugewiesen: $assignedChat',
                                style: TextStyle(
                                  color: assignedChat == widget.chatGroupName
                                      ? Colors.green
                                      : Colors.orange,
                                  fontWeight: FontWeight.w500,
                                ),
                              )
                            : const Text(
                                '🆓 Verfügbar',
                                style: TextStyle(color: Colors.grey),
                              ),
                        trailing: fileName == selectedKeyFile
                            ? const Icon(Icons.check_circle,
                                color: Colors.green)
                            : null,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
          ],
        );
      },
    );
  }

  // Gibt nur die Dateien zurück, die noch nicht zugeordnet sind (außer der aktuell ausgewählten)
  Future<List<String>> _getUnassignedKeyFiles() async {
    List<String> allFiles = await _getAvailableKeyFiles();
    List<String> unassignedFiles = [];

    for (String fileName in allFiles) {
      // Die aktuell ausgewählte Datei immer hinzufügen
      if (fileName == selectedKeyFile) {
        unassignedFiles.add(fileName);
        continue;
      }

      // Prüfen ob die Datei einem anderen Chat zugewiesen ist
      bool isAssigned = await _isFileAssignedToOtherChat(fileName);
      if (!isAssigned) {
        unassignedFiles.add(fileName);
      }
    }

    developer.log('log: Verfügbare unzugeordnete Key-Dateien: $unassignedFiles',
        name: '_getUnassignedKeyFiles');
    return unassignedFiles;
  }

  Future<List<String>> _getAvailableKeyFiles() async {
    List<String> foundFiles = [];

    try {
      // Prüfe Daten/QGap/schluessel Unterordner - sowohl lokal als auch auf USB-Stick
      final searchDirs = [
        Directory(AppStorage.schluesselDir),
        // USB-Stick Verzeichnisse
        Directory('/storage/usbotg/daten/QGap/schluessel'),
        Directory('/mnt/usb/daten/QGap/schluessel'),
        Directory('/mnt/media_rw/usbotg/daten/QGap/schluessel'),
      ];

      for (var downloadDir in searchDirs) {
        if (await downloadDir.exists()) {
          developer.log(
              'log: Durchsuche Ordner für Settings: ${downloadDir.path}',
              name: '_getAvailableKeyFiles');
          final files = await downloadDir.list().toList();
          for (var file in files) {
            if (file is File) {
              final fileName = AppStorage.fileNameOf(file.path);
              // Nur Dateien mit .qgap_ec Endung sammeln
              if (fileName.endsWith('.qgap_ec')) {
                if (!foundFiles.contains(fileName)) {
                  foundFiles.add(fileName);
                }
              }
            }
          }
        }
      }

      // Wenn keine Dateien gefunden wurden, leere Liste zurückgeben
      if (foundFiles.isEmpty) {
        developer.log('log: Keine QGap-Key-Dateien gefunden',
            name: '_getAvailableKeyFiles');
      }
    } catch (e) {
      developer.log('log: Fehler beim Laden verfügbarer Dateien: $e',
          name: '_getAvailableKeyFiles');
      // Keine Fallback-Dateien mehr hinzufügen
    }

    developer.log('log: Verfügbare Key-Dateien für Settings: $foundFiles',
        name: '_getAvailableKeyFiles');
    return foundFiles;
  }

  /// Speichert die verschlüsselte Nachricht als .qgap Datei und teilt sie.
  /// Erstellt ein binäres QGap-Envelope (type=0x03) für eine Sprachnachricht
  /// und teilt es als .qgap-Datei. Damit erkennt das Empfangsgerät die
  /// Datei korrekt als Audio und leitet sie an [_processReceivedVoice] weiter.
  Future<void> _shareVoiceAsQGapFile(qgap_model.Message msg) async {
    if (msg.attachmentFileName == null) {
      // Fallback: kein Dateiname → normaler Text-Share
      await _shareAsQGapFile(msg.text);
      return;
    }
    Uint8List envelope;
    try {
      final encType = msg.encryptionType;
      final isRsaOrHybrid = encType == qgap_model.EncryptionType.rsa ||
          encType == qgap_model.EncryptionType.hybrid;
      final metaLen = _findMetadataLength(msg.text);
      if (metaLen <= 0) throw const FormatException('Metadaten nicht gefunden');
      final metadata = utf8.decode(base64.decode(msg.text.substring(0, metaLen)));
      final payloadString = msg.text.substring(metaLen);
      if (isRsaOrHybrid) {
        final payloadBytes = Uint8List.fromList(utf8.encode(payloadString));
        envelope = _buildVoiceEnvelope(metadata, msg.attachmentFileName!, payloadBytes);
      } else {
        final encryptedBytes = Uint8List.fromList(base64.decode(payloadString));
        envelope = _buildVoiceEnvelope(metadata, msg.attachmentFileName!, encryptedBytes);
      }
    } catch (e) {
      developer.log('log: Fehler beim Erstellen des Voice-Envelopes: $e',
          name: '_shareVoiceAsQGapFile');
      await _shareAsQGapFile(msg.text);
      return;
    }

    // Dateinamen vom Benutzer erfragen
    final now = DateTime.now();
    final baseName =
        'voice_${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}_QGap';
    final nameCtrl = TextEditingController(text: baseName);
    if (!mounted) return;
    final chosenName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            suffixText: '.qgap',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('save:${nameCtrl.text.trim()}'),
              child: const Text('💾 USB/Datei')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('share:${nameCtrl.text.trim()}'),
              child: const Text('📤 Teilen')),
        ],
      ),
    );
    if (chosenName == null || chosenName.isEmpty || !mounted) return;
    final parts = chosenName.split(':');
    final action = parts[0];
    final parsedName = parts.length > 1 ? parts.sublist(1).join(':') : '';
    if (parsedName.isEmpty) return;
    final fileName = '$parsedName.qgap';

    try {
      if (action == 'save') {
        // Direkt auf USB-Stick / Dateisystem speichern (SAF)
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: envelope,
          allowedExtensions: const ['qgap'],
          type: FileType.custom,
        );
        if (mounted && savedPath != null) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('✅ "$fileName" gespeichert'), duration: const Duration(seconds: 2)),
          );
        }
        developer.log('log: Voice als $fileName gespeichert: $savedPath', name: '_shareVoiceAsQGapFile');
      } else {
        // System-Share
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(envelope, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: fileName)],
          subject: fileName,
        );
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(
              content: Text('✅ "$fileName" geteilt'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        developer.log('log: Voice-Nachricht als $fileName geteilt (binäres Envelope, type=0x03)',
            name: '_shareVoiceAsQGapFile');
      }
    } catch (e) {
      developer.log('log: Fehler beim Teilen: $e', name: '_shareVoiceAsQGapFile');
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler: ${e.toString()}')),
        );
      }
    }
  }

  /// Teilt eine Relay-A→B-Nachricht als binäre .qgap-Datei.
  /// [innerB64] ist das base64-kodierte QGap-Binär-Envelope von Air-Gap A.
  Future<void> _shareRelayMsgAsQGapFile(String innerB64) async {
    final bytes = Uint8List.fromList(base64.decode(innerB64));
    final now = DateTime.now();
    final defaultName = '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}_relay';
    final nameCtrl = TextEditingController(text: defaultName);
    if (!mounted) return;
    final chosenName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            suffixText: '.qgap',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('save:${nameCtrl.text.trim()}'),
              child: const Text('💾 USB/Datei')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('share:${nameCtrl.text.trim()}'),
              child: const Text('📤 Teilen')),
        ],
      ),
    );
    if (chosenName == null || chosenName.isEmpty || !mounted) return;
    final parts = chosenName.split(':');
    final action = parts[0];
    final baseName = parts.length > 1 ? parts.sublist(1).join(':') : '';
    if (baseName.isEmpty) return;
    final fileName = '$baseName.qgap';
    try {
      if (action == 'save') {
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: bytes,
          allowedExtensions: const ['qgap'],
          type: FileType.custom,
        );
        if (mounted && savedPath != null) {
          showQgapSnackBar(context,
            SnackBar(content: Text('✅ "$fileName" gespeichert'), duration: const Duration(seconds: 2)));
        }
      } else {
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: fileName)],
          subject: fileName,
        );
        if (mounted) {
          showQgapSnackBar(context,
            SnackBar(content: Text('✅ "$fileName" geteilt'), duration: const Duration(seconds: 2)));
        }
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, SnackBar(content: Text('Fehler: ${e.toString()}')));
      }
    }
  }

  Future<void> _shareAsQGapFile(String encryptedText) async {
    // Dateinamen vom Benutzer erfragen
    final now = DateTime.now();
    final defaultName =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}_QGap';
    final nameCtrl = TextEditingController(text: defaultName);
    if (!mounted) return;
    final chosenName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            suffixText: '.qgap',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('save:${nameCtrl.text.trim()}'),
              child: const Text('💾 USB/Datei')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop('share:${nameCtrl.text.trim()}'),
              child: const Text('📤 Teilen')),
        ],
      ),
    );
    if (chosenName == null || chosenName.isEmpty || !mounted) return;
    final parts = chosenName.split(':');
    final action = parts[0];
    final baseName = parts.length > 1 ? parts.sublist(1).join(':') : '';
    if (baseName.isEmpty) return;
    final fileName = '$baseName.qgap';
    final contentBytes = Uint8List.fromList(utf8.encode(encryptedText));

    try {
      if (action == 'save') {
        // Direkt auf USB-Stick / Dateisystem speichern (SAF)
        final savedPath = await FilePicker.platform.saveFile(
          fileName: fileName,
          bytes: contentBytes,
          allowedExtensions: const ['qgap'],
          type: FileType.custom,
        );
        if (mounted && savedPath != null) {
          showQgapSnackBar(context, 
            SnackBar(content: Text('✅ "$fileName" gespeichert'), duration: const Duration(seconds: 2)),
          );
        }
        developer.log('log: Nachricht als $fileName gespeichert: $savedPath', name: '_shareAsQGapFile');
      } else {
        // System-Share
        final dir = Directory.systemTemp;
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(encryptedText, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: fileName)],
          subject: fileName,
        );
        if (mounted) {
          showQgapSnackBar(context, 
            SnackBar(
              content: Text('✅ "$fileName" geteilt'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        developer.log('log: Nachricht als $fileName geteilt', name: '_shareAsQGapFile');
      }
    } catch (e) {
      developer.log('log: Fehler beim Teilen: $e', name: '_shareAsQGapFile');
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler: ${e.toString()}')),
        );
      }
    }
  }

  // ─── Binäres QGap-Envelope für QR-Übertragung ──────────────────────────────
  //
  // Format:
  //   [0..3]  Magic 'O','B','M','C'
  //   [4]     Version 0x01
  //   [5]     Type: 0x01=Text, 0x02=Datei
  //   [6..7]  MetaLen uint16 BE
  //   [8..8+MetaLen-1]  Metadaten UTF-8
  //   --- nur Type=0x02: ---
  //   [8+MetaLen..9+MetaLen]  NameLen uint16 BE
  //   [10+MetaLen..10+MetaLen+NameLen-1]  Dateiname UTF-8
  //   --- gemeinsam: ---
  //   [Rest]  Verschlüsselte Nutzdaten (Rohbytes, kein Base64)

  static Uint8List _buildTextEnvelope(String metadata, Uint8List encryptedBytes) {
    final metaBytes = utf8.encode(metadata);
    final buf = BytesBuilder();
    buf.add(const [0x4F, 0x42, 0x4D, 0x43, 0x01, 0x01]); // magic + version + type=text
    buf.add([(metaBytes.length >> 8) & 0xFF, metaBytes.length & 0xFF]);
    buf.add(metaBytes);
    buf.add(encryptedBytes);
    return buf.toBytes();
  }

  static Uint8List _buildFileEnvelope(
      String metadata, String fileName, Uint8List encryptedBytes) {
    final metaBytes = utf8.encode(metadata);
    final nameBytes = utf8.encode(fileName);
    final buf = BytesBuilder();
    buf.add(const [0x4F, 0x42, 0x4D, 0x43, 0x01, 0x02]); // magic + version + type=file
    buf.add([(metaBytes.length >> 8) & 0xFF, metaBytes.length & 0xFF]);
    buf.add(metaBytes);
    buf.add([(nameBytes.length >> 8) & 0xFF, nameBytes.length & 0xFF]);
    buf.add(nameBytes);
    buf.add(encryptedBytes);
    return buf.toBytes();
  }

  static Uint8List _buildVoiceEnvelope(
      String metadata, String fileName, Uint8List encryptedBytes) {
    final metaBytes = utf8.encode(metadata);
    final nameBytes = utf8.encode(fileName);
    final buf = BytesBuilder();
    buf.add(const [0x4F, 0x42, 0x4D, 0x43, 0x01, 0x03]); // magic + version + type=voice
    buf.add([(metaBytes.length >> 8) & 0xFF, metaBytes.length & 0xFF]);
    buf.add(metaBytes);
    buf.add([(nameBytes.length >> 8) & 0xFF, nameBytes.length & 0xFF]);
    buf.add(nameBytes);
    buf.add(encryptedBytes);
    return buf.toBytes();
  }

  /// Relay-Wrap-Envelope (Type 0x10) zum Weiterleiten einer Nachricht über das
  /// gepaarte Online-Relay an einen entfernten Firestore-User.
  ///
  /// Format:
  ///   [0..3]  Magic 'OBMC' (Byte-Format bewusst unverändert)
  ///   [4]     Version 0x01
  ///   [5]     Type 0x10
  ///   [6..7]  DestUidLen   uint16 BE
  ///   [8..]   DestUid      UTF-8
  ///   [..]    ChatGroupIdLen uint16 BE
  ///   [..]    ChatGroupId  UTF-8
  ///   [..]    Inner QGap envelope (Type 0x01/0x02/0x03), unverändert
  ///
  /// Der Online-Relay parst nur den Header (DestUid + ChatGroupId) und reicht
  /// den inneren Envelope unverändert per `sendUserTransfer` mit
  /// `payloadType=kPayloadTypeRelayPreencrypted` an den Empfänger durch.
  /// Baut einen Relay-Wrap-Header um [innerEnvelope].
  ///
  /// Binärformat (v2, rückwärtskompatibel wenn ecCode leer):
  ///   [0..3]  Magic 'OBMC' (Byte-Format bewusst unverändert)
  ///   [4]     Version 0x01
  ///   [5]     Type 0x10
  ///   [6..7]  destUidLen    uint16 BE
  ///   [8..]   destUid       UTF-8
  ///   [..]    chatGroupIdLen uint16 BE
  ///   [..]    chatGroupId   UTF-8
  ///   [..]    ecCodeLen     uint16 BE   (0 → kein Code, Legacy-kompatibel)
  ///   [..]    ecCode        UTF-8       (Zufalls-Suffix der .qgap_ec-Datei)
  ///   [..]    inner QGap envelope
  static Uint8List _buildRelayWrap({
    required String destUid,
    required String chatGroupId,
    required Uint8List innerEnvelope,
    String ecCode = '',
  }) {
    final destBytes = utf8.encode(destUid);
    final cgBytes = utf8.encode(chatGroupId);
    final ecBytes = utf8.encode(ecCode);
    final buf = BytesBuilder();
    buf.add(const [0x4F, 0x42, 0x4D, 0x43, 0x01, 0x10]); // magic + ver + type=relay-wrap
    buf.add([(destBytes.length >> 8) & 0xFF, destBytes.length & 0xFF]);
    buf.add(destBytes);
    buf.add([(cgBytes.length >> 8) & 0xFF, cgBytes.length & 0xFF]);
    buf.add(cgBytes);
    buf.add([(ecBytes.length >> 8) & 0xFF, ecBytes.length & 0xFF]);
    buf.add(ecBytes);
    buf.add(innerEnvelope);
    return buf.toBytes();
  }

  static Map<String, dynamic>? _parseBinaryEnvelope(Uint8List data) {
    if (data.length < 8) return null;
    if (data[0] != 0x4F || data[1] != 0x42 || data[2] != 0x4D || data[3] != 0x43) {
      return null;
    }
    // data[4] = version (für Zukunft)
    final type = data[5];
    final metaLen = (data[6] << 8) | data[7];
    final metaEnd = 8 + metaLen;
    if (data.length < metaEnd) return null;
    final metadata = utf8.decode(data.sublist(8, metaEnd));

    if (type == 0x01) {
      // Text-Nachricht
      return {
        'type': 'text',
        'metadata': metadata,
        'payload': Uint8List.fromList(data.sublist(metaEnd)),
      };
    } else if (type == 0x02) {
      // Datei-Nachricht
      if (data.length < metaEnd + 2) return null;
      final nameLen = (data[metaEnd] << 8) | data[metaEnd + 1];
      final nameEnd = metaEnd + 2 + nameLen;
      if (data.length < nameEnd) return null;
      final fileName = utf8.decode(data.sublist(metaEnd + 2, nameEnd));
      return {
        'type': 'file',
        'metadata': metadata,
        'fileName': fileName,
        'payload': Uint8List.fromList(data.sublist(nameEnd)),
      };
    } else if (type == 0x03) {
      // Sprachnachricht
      if (data.length < metaEnd + 2) return null;
      final nameLen = (data[metaEnd] << 8) | data[metaEnd + 1];
      final nameEnd = metaEnd + 2 + nameLen;
      if (data.length < nameEnd) return null;
      final fileName = utf8.decode(data.sublist(metaEnd + 2, nameEnd));
      return {
        'type': 'voice',
        'metadata': metadata,
        'fileName': fileName,
        'payload': Uint8List.fromList(data.sublist(nameEnd)),
      };
    }
    return null; // unbekannter Typ
  }

  void _showFullscreenQrCode(qgap_model.Message message) async {
    try {
      Uint8List envelope;
      // For text messages, limit QR size to prevent unusable tiny modules.
      // File and voice messages have no limit – QrDataSender handles any size.
      const int maxTextQrBytes = 60000;

      final encType = message.encryptionType;
      final isRsaOrHybrid = encType == qgap_model.EncryptionType.rsa ||
          encType == qgap_model.EncryptionType.hybrid;

      // A→B Relay-Nachricht: message.text = innerB64 (base64 des rohen QGap-Envelopes
      // von Air-Gap A). Einfach dekodieren – das ergibt direkt das Binär-Envelope,
      // das Air-Gap B scannen und mit dem gemeinsamen OTP-Schlüssel entschlüsseln kann.
      if (message.originalText == _kRelayMsgSentinel) {
        envelope = Uint8List.fromList(base64.decode(message.text));
      } else if (message.originalText == _kRelayBtoASentinel) {
        // B→A Relay-Nachricht. message.text ist entweder:
        // a) base64(raw QGap-Binär-Envelope) – wenn über Relay B weitergeleitet
        //    (offlineRelayBtoA-Typ) → direkt als Envelope verwenden.
        // b) base64(metadata)+base64(payload) – wenn direkt von Online B gesendet
        //    (normales Firestore-Textformat) → Envelope bauen.
        final rawBytes = base64.decode(message.text);
        if (rawBytes.length >= 6 &&
            rawBytes[0] == 0x4F && rawBytes[1] == 0x42 &&
            rawBytes[2] == 0x4D && rawBytes[3] == 0x43) {
          // QGap-Magic gefunden → direkt als Envelope
          envelope = Uint8List.fromList(rawBytes);
        } else {
          // Altes Firestore-Format: base64(meta)+base64(payload)
          final metaLen = _findMetadataLength(message.text);
          if (metaLen <= 0) throw const FormatException('QRM-R01: Metadaten nicht gefunden');
          final metadata = utf8.decode(base64.decode(message.text.substring(0, metaLen)));
          final encryptedBytes = Uint8List.fromList(base64.decode(message.text.substring(metaLen)));
          envelope = _buildTextEnvelope(metadata, encryptedBytes);
        }
      } else if (isRsaOrHybrid) {
        // RSA/Hybrid: Payload ist kein reines Base64.
        // Format: base64(metadata) + payload_string (enthält Punkte bei Hybrid).
        // Wir übertragen den kompletten message.text als UTF-8-Bytes im Envelope.
        final metaLen = _findMetadataLength(message.text);
        if (metaLen <= 0) {
          throw const FormatException('QRM-001: Metadaten nicht gefunden');
        }
        final metadata =
            utf8.decode(base64.decode(message.text.substring(0, metaLen)));
        final payloadString =
            metaLen > 0 ? message.text.substring(metaLen) : message.text;
        if (payloadString.isEmpty) {
          throw const FormatException('QRM-002: Leerer Payload');
        }
        // Payload als UTF-8-Rohbytes (kein base64.decode!)
        final payloadBytes = Uint8List.fromList(utf8.encode(payloadString));
        if (message.messageType == qgap_model.MessageType.file &&
            message.attachmentFileName != null) {
          envelope = _buildFileEnvelope(metadata, message.attachmentFileName!, payloadBytes);
        } else if (message.messageType == qgap_model.MessageType.voice &&
            message.attachmentFileName != null) {
          envelope = _buildVoiceEnvelope(metadata, message.attachmentFileName!, payloadBytes);
        } else {
          envelope = _buildTextEnvelope(metadata, payloadBytes);
        }
      } else {
        // One-Time-Pad: Payload ist echtes Base64 (verschlüsselte Rohbytes)
        final metaLen = _findMetadataLength(message.text);
        if (metaLen <= 0) {
          throw const FormatException('QRM-003: OTP-Metadaten nicht gefunden');
        }
        final metadata = metaLen > 0
            ? utf8.decode(base64.decode(message.text.substring(0, metaLen)))
            : '';
        final encryptedBytes = Uint8List.fromList(base64
            .decode(metaLen > 0 ? message.text.substring(metaLen) : message.text));
        if (message.messageType == qgap_model.MessageType.file &&
            message.attachmentFileName != null) {
          envelope =
              _buildFileEnvelope(metadata, message.attachmentFileName!, encryptedBytes);
        } else if (message.messageType == qgap_model.MessageType.voice &&
            message.attachmentFileName != null) {
          envelope =
              _buildVoiceEnvelope(metadata, message.attachmentFileName!, encryptedBytes);
        } else {
          envelope = _buildTextEnvelope(metadata, encryptedBytes);
        }
      }

      // Offline-EC-Chats mit gepaartem Online-Relay-Partner: Envelope in einen
      // Relay-Wrap (Type 0x10) packen, der DestUid + ChatGroupId voranstellt.
      // Der Online-Relay des Senders kann den QR auf seinem Hauptscreen
      // einscannen und den inneren Envelope per Firestore an den Partner
      // weiterleiten (sendUserTransfer mit kPayloadTypeRelayPreencrypted).
      // B→A-Sentinel NICHT relay-wrappen: der Air-Gap soll die Nachricht
      // direkt aus dem QR entschlüsseln (Type 0x01 = normaler Text-Envelope).
      if (encType == qgap_model.EncryptionType.oneTimePad &&
          message.originalText != _kRelayBtoASentinel &&
          message.originalText != _kRelayMsgSentinel) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final destUid =
              (prefs.getString('chat_partner_uid_${widget.chatGroupId}') ?? '')
                  .trim();
          if (destUid.isNotEmpty) {
            // ecCode für Schlüsseldatei-Check auf Relay-Phone
            final ecCode =
                (prefs.getString('chat_ec_code_${widget.chatGroupId}') ?? '')
                    .trim();
            envelope = _buildRelayWrap(
              destUid: destUid,
              chatGroupId: widget.chatGroupId,
              innerEnvelope: envelope,
              ecCode: ecCode,
            );
            developer.log(
                'log: 📡 Relay-Wrap (0x10) für QR aktiviert (destUid=$destUid)',
                name: '_showFullscreenQrCode');
          } else {
            // Kein Relay-Wrap möglich → Warnung anzeigen
            developer.log(
                'log: ⚠️ chat_partner_uid_ leer – QR ohne Relay-Wrap',
                name: '_showFullscreenQrCode');
            if (mounted) {
              final proceed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Row(
                    children: [
                      Icon(Icons.warning_amber, color: Colors.orange),
                      SizedBox(width: 8),
                      Flexible(child: Text('Relay-Ziel fehlt')),
                    ],
                  ),
                  content: const Text(
                    'Für diesen Chat ist noch kein Relay-Ziel (Partner-UID) '
                    'hinterlegt.\n\n'
                    'Der QR-Code kann nicht automatisch vom Transfer-Handy '
                    'weitergeleitet werden.\n\n'
                    'Lösung: Empfange zuerst die Einladungs-Datei (.qgap_ch) '
                    'vom Partner — darin ist die Empfänger-UID enthalten.\n\n'
                    'QR trotzdem anzeigen (nur direkte Anzeige möglich)?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Abbrechen'),
                    ),
                    OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('QR trotzdem zeigen'),
                    ),
                  ],
                ),
              );
              if (proceed != true || !mounted) return;
            }
          }
        } catch (e) {
          developer.log(
              'log: ⚠️ Relay-Wrap konnte nicht angewendet werden: $e',
              name: '_showFullscreenQrCode');
        }
      }

      final isLargeMedia = message.messageType == qgap_model.MessageType.file ||
          message.messageType == qgap_model.MessageType.voice;
      if (!isLargeMedia && envelope.length > maxTextQrBytes) {
        throw FormatException(
          'QRM-004: Text-Nachricht zu gross fuer QR-Anzeige (${envelope.length} Bytes)',
        );
      }

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => QrDataSender(bytes: envelope),
        ),
      );
    } catch (e) {
      developer.log('log: Fehler beim Erstellen des QR-Envelopes: $e',
          name: '_showFullscreenQrCode');
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Erstellen des QR-Codes: $e')),
        );
      }
    }
  }

  // Stellt sicher, dass ein Kontakt für diesen Chat zugeordnet ist und liefert den Namen
  Future<String?> _ensureChatContactAssignment() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'chat_contact_${widget.chatGroupId}';
    String? contactName = prefs.getString(key);

    // Prüfen, ob der gespeicherte Kontakt noch vorhanden ist
    final keyManager = RSAKeyManager();
    final allContacts = await keyManager.getContactKeys();
    if (contactName != null && allContacts.containsKey(contactName)) {
      developer.log('log: 👤 Kontakt bereits zugeordnet: $contactName',
          name: '_ensureChatContactAssignment');
      return contactName;
    }

    // Auswahl anzeigen, wenn kein Kontakt zugeordnet ist
    if (allContacts.isEmpty) {
      if (mounted) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Kein Kontakt vorhanden'),
            content: const Text(
                'Es sind keine Kontakt-Schlüssel gespeichert. Bitte importieren Sie einen öffentlichen Schlüssel (QR-Scanner) und versuchen Sie es erneut.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('OK')),
            ],
          ),
        );
      }
      return null;
    }

    final selected =
        await _showContactSelectionDialog(allContacts.keys.toList());
    if (selected != null && selected.isNotEmpty) {
      await prefs.setString(key, selected);
      developer.log('log: ✅ Kontakt "$selected" dem Chat zugeordnet',
          name: '_ensureChatContactAssignment');
      return selected;
    }
    return null;
  }

  // Dialog zur Auswahl eines Kontakts (Namen)
  Future<String?> _showContactSelectionDialog(List<String> contactNames) async {
    if (!mounted) return null;
    return await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Kontakt wählen'),
          content: SizedBox(
            width: double.maxFinite,
            height: 250,
            child: ListView.builder(
              itemCount: contactNames.length,
              itemBuilder: (c, i) {
                final name = contactNames[i];
                return ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(name),
                  onTap: () {
                    Navigator.of(ctx).pop(name);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Abbrechen')),
          ],
        );
      },
    );
  }

  // Hybrid: AES-GCM verschlüsseln und AES-Key via RSA (Kontakt) einwickeln
  Future<Map<String, String>> _encryptHybridForContact(
      String plainText, String contactName) async {
    final keyManager = RSAKeyManager();
    final contactPubKey = await keyManager.getContactPublicKey(contactName);
    if (contactPubKey == null) {
      throw Exception(
          'Öffentlicher Schlüssel für "$contactName" nicht gefunden.');
    }

    // AES-256 Schlüssel und IV erzeugen
    final rnd = Random.secure();
    final aesKey = List<int>.generate(32, (_) => rnd.nextInt(256));
    final iv =
        List<int>.generate(12, (_) => rnd.nextInt(256)); // 96-bit Nonce für GCM

    // AES-GCM Verschlüsselung
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final aeadParams = pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(aesKey)),
      128,
      Uint8List.fromList(iv),
      Uint8List(0),
    );
    cipher.init(true, aeadParams);

    final plainBytes = utf8.encode(plainText);
    final cipherBytes = cipher.process(Uint8List.fromList(plainBytes));

    // RSA: AES-Key verpacken (als Base64-String, dann RSA)
    final rsa = RSAEncryption();
    final encKeyRsaB64 =
        rsa.encryptWithPublicKey(base64.encode(aesKey), contactPubKey);

    final payload = [
      encKeyRsaB64,
      base64.encode(iv),
      base64.encode(cipherBytes),
    ].join('.');

    final metadata = 'HYB;${widget.chatGroupId};$contactName;';
    return {'payload': payload, 'metadata': metadata};
  }

  // Längenprüfung entfällt: QrDataSender überträgt beliebig lange Nachrichten
  // als Sequenz von QR-Codes — keine Begrenzung mehr notwendig.
  String _checkMessageLength(String text) {
    return 'ok';
  }

  void _sendMessage() async {
    if (_textController.text.isNotEmpty) {
      // Prüfe Nachrichtenlänge für optimale QR-Code-Scanbarkeit
      String lengthStatus = _checkMessageLength(_textController.text);
      // Alle Nachrichten werden jetzt gesendet, auch die zu langen

      // Prüfe ob Key-Datei zugeordnet ist (nur für One-Time-Pad erforderlich)
      if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad &&
          selectedKeyFile == null) {
            developer.log(
            'log: ⚠️ Keine Key-Datei zugeordnet - One-Time-Pad Nachricht kann nicht verschlüsselt werden',
            name: '_sendMessage');
        return;
      }

      developer.log(
          'log: Sende Nachricht in Gruppe ${widget.chatGroupName} mit ${currentEncryptionType.toString()}',
          name: '_sendMessage');

      // Tastatur ausblenden
      FocusScope.of(context).unfocus();

      // Key-Info aktualisieren vor Verschlüsselung (nur für One-Time-Pad)
      if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad) {
        developer.log('log: wenn oneTimePad Start: ', name: '_sendMessage');

        try {
          final keyResult = await ladeKeyAusDatei(selectedKeyFile!);
          setState(() {
            keyInfo = keyResult['info'] ?? 'Unbekannt';
          });

          // Zusätzliche Überprüfung, ob die Datei wirklich existiert
          bool fileExists = false;
          final cleanSelectedKey = AppStorage.fileNameOf(selectedKeyFile!);
          final possiblePaths = [
            AppStorage.keyFilePath(cleanSelectedKey),
            '/sdcard/Daten/QGap/schluessel/$cleanSelectedKey',
            // USB-Stick Pfade
            '/storage/usbotg/daten/QGap/schluessel/$cleanSelectedKey',
            '/mnt/usb/daten/QGap/schluessel/$cleanSelectedKey',
            '/mnt/media_rw/usbotg/daten/QGap/schluessel/$cleanSelectedKey',
          ];

          for (String path in possiblePaths) {
            final file = File(path);
            if (await file.exists()) {
              fileExists = true;
              break;
            }
          }

          if (!fileExists) {
            throw Exception(
                'Verschlüsselungsdatei "$selectedKeyFile" wurde nicht gefunden in /Daten/QGap/schluessel/');
          }
        } catch (e) {
          developer.log('log: Fehler beim Laden der Key-Datei: $e',
              name: '_sendMessage');

          // Benutzerfreundliche Fehlermeldung anzeigen
          if (mounted) {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('❌ Verschlüsselungsfehler'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Die Verschlüsselungsdatei konnte nicht gefunden werden:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          selectedKeyFile ?? 'Keine Datei ausgewählt',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.orange.shade200),
                        ),
                        child: Text(
                          'Fehlerdetails: ${e.toString()}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('Mögliche Ursachen:'),
                      const Text('• Datei wurde gelöscht oder verschoben'),
                      const Text('• Keine Berechtigung für Dateizugriff'),
                      const Text(
                          '• Datei nicht im /Daten/QGap/schluessel/ Ordner'),
                      const SizedBox(height: 12),
                      const Text(
                        'Bitte überprüfen Sie die Datei oder wählen Sie eine andere Verschlüsselungsdatei in den Einstellungen.',
                        style: TextStyle(
                            fontSize: 12, fontStyle: FontStyle.italic),
                      ),
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
                        _showSettingsDialog();
                      },
                      child: const Text('Einstellungen öffnen'),
                    ),
                  ],
                );
              },
            );
          }
          developer.log('log: nach catch oneTimePad e ${e.toString()}',
              name: '_sendMessage');
          return; // Nachricht nicht senden, wenn Key-Datei fehlt
        }
      }
        // Loggen, dass wir den Verschlüsselungs-Dispatch erreichen
        if (currentEncryptionType != qgap_model.EncryptionType.oneTimePad) {
          developer.log(
              'log: 🚦 nicht One-Time-Pad -> direkt in Verschlüsselungs-Dispatch (Hybrid/RSA)',
              name: '_sendMessage');
        } else {
          developer.log('log: ✅ OTP-Block beendet (weiter zur Verschlüsselung)',
              name: '_sendMessage');
        }

        // Anzahl der verwendeten Bytes aktualisieren
        int usedBytesForThisMessage = utf8.encode(_textController.text).length;
        String originalMessage =
            _textController.text; // Ursprünglichen Text speichern

        // Verschlüsselung mit Metadaten im Base64-String
        try {
          String encryptedText;
          String metadataString;

          // Je nach Verschlüsselungsart unterschiedliche Methoden verwenden
          switch (currentEncryptionType) {
            case qgap_model.EncryptionType.oneTimePad:
              // Klassische One-Time-Pad Verschlüsselung mit .qgap Dateien
              encryptedText = await verschluesselMitXOR(
                  _textController.text, selectedKeyFile, usedKeyBytes);
              // EC-Datei in Metadaten aufnehmen, falls aktiv (Code statt Dateiname)
              {
                final ecSnippet = await _buildEcMetaSnippetForOnlineSend();
                if (ecSnippet == null) return; // EC-Datei ohne Code: Abbruch
                metadataString =
                    '$selectedKeyFile;$usedKeyBytes;$ecSnippet';
              }
              break;

            case qgap_model.EncryptionType.rsa:
              // RSA-Verschlüsselung auf Kontakt-Schlüssel (mit Fallback auf Hybrid bei zu großer Ausgabe)
              final keyManager = RSAKeyManager();
              await keyManager.loadKeyPair();

              // Kontakt für diesen Chat sicherstellen/auswählen
              final contactName = await _ensureChatContactAssignment();
              if (contactName == null) {
                throw Exception(
                    'Kein Kontakt zugeordnet. Bitte Kontakt auswählen.');
              }
              final contactPubKey =
                  await keyManager.getContactPublicKey(contactName);
              if (contactPubKey == null) {
                throw Exception(
                    'Öffentlicher Schlüssel für Kontakt "$contactName" nicht gefunden.');
              }
              final encryption = RSAEncryption();
              String rsaResult;
              try {
                rsaResult = encryption.encryptWithPublicKey(
                    _textController.text, contactPubKey);
              } catch (e) {
                developer.log(
                    'log: ⚠️ RSA-Verschlüsselung fehlgeschlagen ($e) -> Fallback Hybrid',
                    name: '_sendMessage');
                // Fallback: Hybrid
                final hyb = await _encryptHybridForContact(
                    _textController.text, contactName);
                encryptedText = hyb['payload']!;
                metadataString = hyb['metadata']!;
                break;
              }

              // Falls RSA-Ausgabe sehr groß, auf Hybrid wechseln
              if (rsaResult.length > 800) {
                developer.log(
                    'log: ⚠️ RSA-Ausgabe zu groß (${rsaResult.length} Zeichen) -> Fallback Hybrid',
                    name: '_sendMessage');
                final hyb = await _encryptHybridForContact(
                    _textController.text, contactName);
                encryptedText = hyb['payload']!;
                metadataString = hyb['metadata']!;
              } else {
                encryptedText = rsaResult;
                metadataString = 'RSA;${widget.chatGroupId};$contactName;';
              }
              break;

            case qgap_model.EncryptionType.hybrid:
              // Hybrid-Verschlüsselung (RSA + AES-GCM) mit Kontakt-Schlüssel
              final contactName = await _ensureChatContactAssignment();
              if (contactName == null) {
                throw Exception(
                    'Kein Kontakt zugeordnet. Bitte Kontakt auswählen.');
              }
              final hyb = await _encryptHybridForContact(
                  _textController.text, contactName);
              encryptedText = hyb['payload']!;
              metadataString = hyb['metadata']!;
              break;

            case qgap_model.EncryptionType.relayForward:
              // Relay-Phone: kann keine eigenen Nachrichten senden
              throw Exception('Relay-Chat: Senden nicht möglich (nur Weiterleitung).');
          }
          String encodedMetadata = base64.encode(utf8.encode(metadataString));
          String encryptedTextWithMetadata = '$encodedMetadata$encryptedText';

          setState(() {
            // Byte-Verwendung nur bei One-Time-Pad aktualisieren
            if (currentEncryptionType == qgap_model.EncryptionType.oneTimePad) {
              usedKeyBytes += usedBytesForThisMessage;
            }

            String messageId = Random().nextInt(1000).toString();
            messages.add(qgap_model.Message(
              text:
                  encryptedTextWithMetadata, // Verschlüsselter Text mit Metadaten für QR-Code
              originalText:
                  originalMessage, // Ursprünglicher Text mit Verschlüsselungs-Symbol
              isMe: true,
              id: messageId,
              timestamp: DateTime.now(),
              keyFileName:
                  currentEncryptionType == qgap_model.EncryptionType.oneTimePad
                      ? selectedKeyFile
                      : null,
              byteOffset:
                  currentEncryptionType == qgap_model.EncryptionType.oneTimePad
                      ? (usedKeyBytes - usedBytesForThisMessage)
                      : null,
              encryptionType:
                  currentEncryptionType, // Verwende die Verschlüsselungsart des Chats
              deliveryStatus: _initialDeliveryStatus,
            ));

            // Verfolge, ob diese Nachricht QR-Code haben kann
            messageQrCodeAvailable[messageId] = (lengthStatus != 'toolong');

            _textController.clear();
          });

          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Fokus zurück ins Eingabefeld, damit direkt weitergeschrieben werden kann
            if (mounted) _inputFocusNode.requestFocus();
          });
          // Mehrfach scrollen: die Tastatur bleibt eingeblendet (Fokus-Rückgabe
          // oben) und verkleinert den sichtbaren Bereich erst mit Verzögerung —
          // ohne die Retries würde die gerade gesendete Nachricht dahinter verschwinden.
          _ensureScrollToBottom();

          // Byte-Position für die aktuelle Datei speichern
          await _saveUsedKeyBytes();

          // Nachrichten für diese Gruppe speichern
          await _saveChatMessages();

          // Bei Online-Chats: verschlüsselte Nachricht auch in Firestore schreiben
          if (widget.firestoreChatId != null) {
            try {
              final docId = await FirestoreService().sendMessage(
                widget.firestoreChatId!,
                encryptedTextWithMetadata,
              );
              if (docId != null && messages.isNotEmpty) {
                _firestoreDocIdForMessage[messages.last.id] = docId;
                _updateDeliveryStatus(messages.last.id,
                    qgap_model.MessageDeliveryStatus.delivered);
              }
              developer.log('✅ Nachricht in Firestore gesendet (${widget.firestoreChatId})', name: '_sendMessage');
            } catch (e) {
              developer.log('⚠️ Firestore sendMessage Fehler: $e', name: '_sendMessage');
            }
          }

          // B→A Relay: OTP-Chat ohne Firestore-Chat aber mit Relay-Partner-UID
          // → Nachricht als QGAP_relay_b_to_a an Relay A senden
          if (widget.firestoreChatId == null &&
              currentEncryptionType == qgap_model.EncryptionType.oneTimePad) {
            try {
              final prefs = await SharedPreferences.getInstance();
              final relayUid =
                  (prefs.getString('chat_partner_uid_${widget.chatGroupId}') ?? '').trim();
              if (relayUid.isNotEmpty) {
                // QGap-Envelope aus verschlüsseltem Text bauen
                final metaLen = _findMetadataLength(encryptedTextWithMetadata);
                if (metaLen > 0) {
                  final metadata = utf8.decode(
                      base64.decode(encryptedTextWithMetadata.substring(0, metaLen)));
                  final encBytes = Uint8List.fromList(base64
                      .decode(encryptedTextWithMetadata.substring(metaLen)));
                  final innerEnvelope = _buildTextEnvelope(metadata, encBytes);
                  await FirestoreService().sendUserTransfer(
                    receiverUid: relayUid,
                    encryptionType: 'qgap_ec',
                    payloadType: FirestoreService.kPayloadTypeRelayBtoA,
                    fileName: 'btoa_${widget.chatGroupId}_${DateTime.now().millisecondsSinceEpoch}.qgap',
                    payloadBytes: innerEnvelope,
                    wrap: false,
                    firestoreChatId: widget.chatGroupId,
                  );
                  developer.log(
                      '✅ B→A Relay-Transfer gesendet → relayUid=$relayUid',
                      name: '_sendMessage');
                  if (mounted) {
                    showQgapSnackBar(context, const SnackBar(
                      content: Text('📡 Nachricht via Relay gesendet.'),
                      backgroundColor: Colors.indigo,
                      duration: Duration(seconds: 3),
                    ));
                  }
                }
              }
            } catch (e) {
              developer.log('⚠️ B→A Relay-Transfer fehlgeschlagen: $e',
                  name: '_sendMessage');
            }
          }

          // Verschlüsselungsart für diese Gruppe speichern
          await _saveEncryptionType();

          developer.log('log: Nachricht erfolgreich verschlüsselt und gesendet',
              name: '_sendMessage');
        } catch (e) {
          developer.log('log: Fehler bei Verschlüsselung: $e',
              name: '_sendMessage');

          // Benutzerfreundliche Fehlermeldung für Verschlüsselungsfehler anzeigen
          if (mounted) {
            showDialog(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('❌ Verschlüsselungsfehler'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Die Nachricht konnte nicht verschlüsselt werden:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Text(
                          e.toString(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text('Mögliche Ursachen:'),
                      const Text('• Verschlüsselungsdatei nicht verfügbar'),
                      const Text('• Datei beschädigt oder unlesbar'),
                      const Text('• Unzureichende Dateiberechtigungen'),
                      const Text('• Speicherplatz erschöpft'),
                      const SizedBox(height: 12),
                      const Text(
                        'Versuchen Sie es erneut oder überprüfen Sie die Verschlüsselungseinstellungen.',
                        style: TextStyle(
                            fontSize: 12, fontStyle: FontStyle.italic),
                      ),
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
                        _showSettingsDialog();
                      },
                      child: const Text('Einstellungen'),
                    ),
                  ],
                );
              },
            );
          }
          return;
        }

        // Sofort zum neuesten QR-Code scrollen (ohne Animation)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController
                .jumpTo(_scrollController.position.maxScrollExtent);
          }
        });

        developer.log(
            'log: Nachricht verschlüsselt, $usedBytesForThisMessage Bytes verwendet, gesamt: $usedKeyBytes',
            name: '_sendMessage');
      
    }

    // build() enthält die UI direkt; Getter entfernt
  }

// Hilfsfunktionen (aus main.dart übernommen)
  String wandleInBase64(String text) {
    final bytes = utf8.encode(text);
    return base64.encode(bytes);
  }

  Future<String> verschluesselMitXOR(String text,
      [String? fileName, int startOffset = 0]) async {
    try {
      final keyResult = await ladeKeyAusDatei(fileName);
      final key = keyResult['key'] ?? '';

      if (key.isEmpty) {
        throw Exception(
            'Verschlüsselungskey ist leer - Datei "$fileName" konnte nicht gelesen werden');
      }

      // Zusätzliche Dateiexistenz-Prüfung
      if (fileName != null) {
        bool fileExists = false;
        final cleanName = AppStorage.fileNameOf(fileName);
        final possiblePaths = [
          AppStorage.keyFilePath(cleanName),
          '/sdcard/Daten/QGap/schluessel/$cleanName',
          // USB-Stick Pfade
          '/storage/usbotg/daten/QGap/schluessel/$cleanName',
          '/mnt/usb/daten/QGap/schluessel/$cleanName',
          '/mnt/media_rw/usbotg/daten/QGap/schluessel/$cleanName',
        ];

        for (String path in possiblePaths) {
          final file = File(path);
          if (await file.exists()) {
            fileExists = true;
            break;
          }
        }

        if (!fileExists) {
          throw Exception(
              'Verschlüsselungsdatei "$fileName" nicht gefunden in /Daten/QGap/schluessel/');
        }
      }

      final textBytes = utf8.encode(text);
      List<int> keyBytes;

      // Prüfen ob der Key Base64-kodiert ist (für binäre .qgap Dateien)
      try {
        if (key.length > 20 && key.contains('=') ||
            RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(key)) {
          // Base64-dekodieren für binäre Keys
          keyBytes = base64.decode(key);
          developer.log(
              'log: Verwende binären Key (${keyBytes.length} bytes) mit Offset $startOffset',
              name: 'verschluesselMitXOR');
        } else {
          // Text-Key direkt verwenden
          keyBytes = utf8.encode(key);
          developer.log(
              'log: Verwende Text-Key (${keyBytes.length} bytes) mit Offset $startOffset',
              name: 'verschluesselMitXOR');
        }
      } catch (e) {
        throw Exception(
            'Verschlüsselungskey aus Datei "$fileName" konnte nicht dekodiert werden: $e');
      }

      if (keyBytes.isEmpty) {
        throw Exception(
            'Kein gültiger Verschlüsselungskey aus Datei "$fileName" extrahiert');
      }

      final encryptedBytes = List<int>.generate(textBytes.length, (i) {
        // Verwende startOffset + i für die Position im Key
        int keyIndex = (startOffset + i) % keyBytes.length;
        return textBytes[i] ^ keyBytes[keyIndex];
      });

      return base64.encode(encryptedBytes); // Sicher für QR-Codes
    } catch (e) {
      developer.log('log: Fehler bei XOR-Verschlüsselung: $e',
          name: 'verschluesselMitXOR');
      rethrow;
    }
  }

  Future<Map<String, String>> ladeKeyAusDatei([String? fileName]) async {
    // Vereinfachte Version für bessere Kompatibilität
    // fileNameOf heilt alte Zuordnungen mit Pfadresten (z. B. "schluessel\x.qgap_ec")
    final keyFileName = AppStorage.fileNameOf(fileName ?? 'mm-test.qgap');
    developer.log('log: Versuche Key-Datei zu laden: $keyFileName',
        name: 'ladeKeyAusDatei');

    try {
      if (Platform.isAndroid) {
        // Berechtigungen anfordern (nur Android nötig)
        developer.log('log: Fordere Storage-Berechtigung an',
            name: 'ladeKeyAusDatei');

        // Prüfe Android API-Level und verwende entsprechende Berechtigungen
        PermissionStatus status = PermissionStatus.denied;

        // Für Android 13+ (API 33+) - scoped storage
        try {
          status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            // Fallback für neuere Android-Versionen
            status = await Permission.storage.request();
          }
        } catch (e) {
          developer.log(
              'log: Fehler bei Berechtigung manageExternalStorage: $e',
              name: 'ladeKeyAusDatei');
          // Versuche die klassische Storage-Berechtigung
          status = await Permission.storage.request();
        }

        developer.log('log: Berechtigung Status: $status',
            name: 'ladeKeyAusDatei');

        if (!status.isGranted) {
          developer.log('log: Keine Berechtigung erhalten',
              name: 'ladeKeyAusDatei');
          throw Exception(
              'Keine Berechtigung für Dateizugriff. Bitte Storage-Berechtigung erteilen.');
        }
      }

      // Prüfe Daten/QGap Pfade und USB-Stick-Pfade
      final possiblePaths = [
        AppStorage.keyFilePath(keyFileName),
        if (Platform.isAndroid) ...[
          '/sdcard/Daten/QGap/schluessel/$keyFileName',
          // USB-Stick-Pfade
          '/storage/usbotg/daten/QGap/schluessel/$keyFileName',
          '/mnt/usb/daten/QGap/schluessel/$keyFileName',
          '/mnt/media_rw/usbotg/daten/QGap/schluessel/$keyFileName',
        ],
      ];

      for (String path in possiblePaths) {
        final keyFile = File(path);
        developer.log('log: Prüfe Pfad: $path', name: 'ladeKeyAusDatei');

        if (await keyFile.exists()) {
          try {
            // Für binäre .qgap Dateien: Direkt als Bytes lesen
            final bytes = await keyFile.readAsBytes();
            developer.log(
                'log: Binäre Key-Datei gelesen: ${bytes.length} bytes',
                name: 'ladeKeyAusDatei');

            // Binäre Daten als Base64 für Verschlüsselung verwenden
            final base64Key = base64.encode(bytes);
            developer.log(
                'log: Key-Datei erfolgreich geladen von: $path (${bytes.length} bytes)',
                name: 'ladeKeyAusDatei');

            final result = {
              'key': base64Key,
              'info': '$keyFileName (${bytes.length} bytes binär) ✅'
            };
            return result;
          } catch (e) {
            developer.log(
                'log: Fehler beim Lesen der binären Datei $path: $e',
                name: 'ladeKeyAusDatei');
          }
        } else {
          developer.log('log: Datei nicht gefunden: $path',
              name: 'ladeKeyAusDatei');
        }
      }

      // Versuche Daten-Ordner zu listen
      try {
        final searchDirs = [
          Directory(AppStorage.schluesselDir),
        ];

        for (var downloadDir in searchDirs) {
          if (await downloadDir.exists()) {
            final files = await downloadDir.list().toList();
            developer.log('log: Verfügbare Dateien in ${downloadDir.path}:',
                name: 'ladeKeyAusDatei');
            for (var file in files) {
              developer.log('log:   - ${file.path}', name: 'ladeKeyAusDatei');
            }
          } else {
            developer.log('log: Ordner existiert nicht: ${downloadDir.path}',
                name: 'ladeKeyAusDatei');
          }
        }
      } catch (e) {
        developer.log('log: Fehler beim Listen der Daten-Ordner: $e',
            name: 'ladeKeyAusDatei');
      }
    } catch (e) {
      developer.log('log: Fehler beim Laden der Key-Datei: $e',
          name: 'ladeKeyAusDatei');
      rethrow;
    }

    // Wenn keine Key-Datei gefunden wurde, Fehler werfen
    developer.log('log: Key-Datei nicht gefunden: $keyFileName',
        name: 'ladeKeyAusDatei');
    throw Exception(
        'Key-Datei "$keyFileName" nicht gefunden.\n'
        'Erwarteter Pfad: ${AppStorage.keyFilePath(keyFileName)}');
  }
}
// Ende: ausgelagertes SettingsDialogWidget wird nun importiert

// Ende: QRScannerDialog ausgelagert und importiert
