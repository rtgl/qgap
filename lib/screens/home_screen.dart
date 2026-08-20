// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart'
    show DocumentChangeType, QuerySnapshot, Timestamp;
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qgap/model/chat_group.dart';
import 'package:qgap/model/message.dart' as message_model;
import 'package:qgap/screens/chat_screen.dart';
import 'package:qgap/services/rsa_key_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:developer' as developer;
import 'package:qgap/screens/qr_data_sender.dart';
import 'package:qgap/screens/qr_data_receiver.dart';
import 'package:qgap/screens/transfer_screen.dart';
import 'package:qgap/model/saved_qr_entry.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:qgap/services/contact_utils.dart';
import 'package:qgap/model/device_role.dart';
import 'package:qgap/services/auth_service.dart';
import 'package:qgap/services/app_storage.dart';
import 'package:qgap/services/ec_keyfile_service.dart';
import 'package:qgap/services/launch_args.dart';
import 'package:qgap/services/share_service.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:qgap/services/ec_provenance_service.dart';
import 'package:qgap/services/usb_saf_service.dart';
import 'package:qgap/services/firestore_service.dart';
import 'package:qgap/services/local_contact_service.dart';
import 'package:qgap/services/pairing_service.dart';
import 'package:qgap/services/relay_mapping_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qgap/theme/app_theme.dart';
import 'package:qgap/screens/widgets/chat_transport_badge.dart';
import 'package:qgap/services/notification_service.dart';
import 'package:qgap/screens/public_screen_list_screen.dart';
import 'package:qgap/screens/public_screen_admin_screen.dart';
import 'package:qgap/services/public_screen_service.dart';
import 'package:qgap/model/public_screen_session.dart';

/// Normalisiert alte Protokoll-Werte (`obmc_*`) auf die neuen (`qgap_*`),
/// damit bereits vor der Umbenennung erstellte QR-Codes/Dateien (Einladungen,
/// Pairing-Dateien, Admin-Kopplung) weiterhin erkannt werden.
String _normalizeLegacyType(String? v) {
  if (v == null) return '';
  return v.startsWith('obmc_') ? 'qgap_${v.substring(5)}' : v;
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<ChatGroup> chatGroups = [];
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupDescriptionController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _descriptionFocusNode = FocusNode();
  final FocusNode _editNameFocusNode = FocusNode();
  final FocusNode _editDescriptionFocusNode = FocusNode();
  String _selectedEmoji = '💬';
  Map<String, DateTime?> lastMessageTimes = {}; // Zeitstempel der letzten Nachrichten
  final RSAKeyManager _rsaKeyManager = RSAKeyManager();
  bool _rsaKeysInitialized = false;
  Map<String, bool> _chatNeedsKey = {}; // ⚠️ Badge: OTP-Schlüsseldatei fehlt
  Map<String, bool> _chatEcUsbOnly = {}; // Badge: OTP USB-only Modus
  Map<String, String?> _chatContactName = {}; // 🔑 Kontaktname für RSA/Hybrid-Chats
  Map<String, int> _unreadCounts = {}; // 🔴 Ungelesene Nachrichten pro Chat
  bool _notificationsEnabled = true; // Benachrichtigungen aktiviert

  // Live-Aktualisierung des Ungelesen-Zählers für Online-Chats (ohne Firestore-
  // Reload nur beim Verlassen/Betreten eines Chats – reagiert auch während
  // die App im Hintergrund/auf dem Home-Screen ist).
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _unreadMsgSubs = {};
  final Map<String, int> _lastSeenMillisCache = {};
  final Map<String, int> _liveUnreadKnown = {}; // Baseline gg. Doppel-Notifications

  // Such-/Filterfeld über der Chat-Liste (durchsucht Name + Nachrichtentexte)
  final TextEditingController _chatSearchController = TextEditingController();
  String _chatSearchQuery = '';
  Map<String, String> _chatSearchIndex = {}; // chatId -> durchsuchbarer Text (lowercase)

  /// Mehrwort-Suche: jedes durch Leerzeichen getrennte Suchwort muss
  /// irgendwo in [haystack] vorkommen (nicht zwingend zusammenhängend) —
  /// wirkt wie eine Stern-Suche `*wort1*wort2*`.
  bool _searchTextMatches(String haystack, String query) {
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (terms.isEmpty) return true;
    final h = haystack.toLowerCase();
    return terms.every((t) => h.contains(t));
  }

  /// Chat-Gruppen, gefiltert nach [_chatSearchQuery] (Name/Beschreibung/Nachrichtentexte).
  /// Bereits sortiert, da [chatGroups] selbst nach letzter Nachricht sortiert wird.
  List<ChatGroup> get _visibleChatGroups {
    final query = _chatSearchQuery.trim();
    if (query.isEmpty) return chatGroups;
    return chatGroups.where((g) {
      final indexed = _chatSearchIndex[g.id] ?? g.name.toLowerCase();
      return _searchTextMatches(indexed, query);
    }).toList();
  }

  /// Präsentations-Sessions, gefiltert nach [_chatSearchQuery] (Titel/Status).
  List<PublicScreenSession> get _visiblePublicSessions {
    final query = _chatSearchQuery.trim();
    if (query.isEmpty) return _publicSessions;
    return _publicSessions.where((s) => _searchTextMatches(
        '${s.title} präsentation ${s.state.label}', query)).toList();
  }

  /// Transfer-Hub-Kachel nur anzeigen, wenn kein Suchwort aktiv ist oder
  /// ihr Text zum Suchwort passt.
  bool get _transferHubVisible {
    final query = _chatSearchQuery.trim();
    if (query.isEmpty) return true;
    return _searchTextMatches(
      'transfer-hub qr-codes senden empfangen dateien teilen qr-galerie',
      query,
    );
  }

  /// Pairing-Status-Banner nur anzeigen, wenn kein Suchwort aktiv ist oder
  /// sein Text (Titel + Untertitel) zum Suchwort passt.
  bool get _pairingBannerVisible {
    final query = _chatSearchQuery.trim();
    if (query.isEmpty) return true;
    final String text;
    switch (_pairingCompleteness) {
      case PairingCompleteness.none:
        text = 'kein pairing aktiv bitte pairing einrichten '
            '${_deviceRole == DeviceRole.airGap ? 'online-relay' : 'air-gap-gerät'}';
        break;
      case PairingCompleteness.sentOnly:
        text = 'pairing unvollständig eigene daten gesendet partner qr scannen';
        break;
      case PairingCompleteness.complete:
        text = 'pairing aktiv verbunden ${_pairingPartnerName ?? ''}';
        break;
    }
    return _searchTextMatches(text, query);
  }

  // Präsentations-Sessions (PublicScreen) für die Startseiten-Liste
  final PublicScreenService _publicScreenService = PublicScreenService();
  List<PublicScreenSession> _publicSessions = [];

  // Geräterolle (persistent in SharedPreferences, verwaltet von DeviceRoleService).
  // Die Bool-Spiegel bleiben für bestehende Codepfade (Farbgebung, Badges) erhalten
  // und werden bei jedem `_loadDeviceRole()`-Aufruf konsistent gesetzt.
  bool _deviceRoleOffline = false;
  bool _deviceRoleOnline  = false;
  DeviceRole _deviceRole  = DeviceRole.standalone;

  /// Hintergrund-Listener für eingehende Firestore-Transfers (ACK, B→A Relay).
  /// Aktiv solange HomeScreen im Widget-Baum ist – unabhängig von TransferScreen.
  StreamSubscription<dynamic>? _homeTransferSub;
  StreamSubscription<dynamic>? _authStateSub;
  final Set<String> _homeProcessedTransferIds = {};

  /// Pairing-Vollständigkeitsstatus (wird beim Start und nach jeder Pairing-Aktion geladen).
  PairingCompleteness _pairingCompleteness = PairingCompleteness.none;
  String? _pairingPartnerName;

  final List<String> availableEmojis = [
    '💬', '🔒', '🛡️', '🔐', '📱', '💻', '🌐', '🔑',
    '📊', '🎯', '⚡', '🚀', '💡', '🎨', '📈', '🔧',
    '🏠', '💼', '🎓', '🎮', '🏃', '🍕', '☕', '🎵'
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Sicherheitsverzögerung für bessere App-Stabilität
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeApp();
      _initializeRSA();
      _loadPublicSessions();
    });

    // Benachrichtigungsdienst: onTap-Callback registrieren (Chat öffnen)
    NotificationService().initialize(onTap: (chatGroupId) {
      if (!mounted) return;
      final group = chatGroups.firstWhere(
        (g) => g.id == chatGroupId,
        orElse: () => chatGroups.isEmpty
            ? ChatGroup(
                id: chatGroupId,
                name: chatGroupId,
                description: '',
                createdAt: DateTime.now(),
              )
            : chatGroups.first,
      );
      _openChatGroup(group);
    });

    // MethodChannel: Eingehende Datei-Intents aus MainActivity empfangen
    const MethodChannel intentChannel =
        MethodChannel('de.paulporg.obmc/file_intent');
    intentChannel.setMethodCallHandler((call) async {
      if (call.method == 'onFileIntent') {
        final uri = call.arguments as String?;
        if (uri != null && mounted) {
          await _handleIncomingFileIntent(uri);
        }
      }
    });

    // Desktop: Dateien von einer zweiten Instanz (Doppelklick/„Öffnen mit“)
    LaunchArgs.onFile = (path) {
      if (mounted) _handleIncomingFileIntent(path);
    };
    
    // FocusNode Listener für automatisches Scrollen
    _descriptionFocusNode.addListener(() {
      if (_descriptionFocusNode.hasFocus) {
        // Wenn der Fokus aktiviert wird, nach oben scrollen damit das Beschreibungsfeld sichtbar bleibt
        Future.delayed(const Duration(milliseconds: 800), () {
          if (_scrollController.hasClients) {
            // Nach oben scrollen, damit das Beschreibungsfeld über der Tastatur sichtbar ist
            _scrollController.animateTo(
              0.0, // Zum Anfang scrollen
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
            );
          }
        });
      }
      // Entferne das Zurück-Scrollen wenn Fokus verloren geht, da es störend sein kann
    });
  }

  // Initialisiert die App-Komponenten sicher
  Future<void> _initializeApp() async {
    try {
      developer.log('log: App-Initialisierung gestartet', name: 'initializeApp');
      
      // Kleine Verzögerung für bessere Stabilität
      await Future.delayed(const Duration(milliseconds: 100));
      
      // Lade Chat-Gruppen asynchron
      await _loadChatGroups();

      // Geräterolle laden und ggf. Offline-Verbindungscheck starten
      await _loadDeviceRole();
      await _checkOfflineConnections();
      await _loadPairingStatus();

      // Hintergrund-Transfer-Listener starten (für ACK, B→A Relay-Nachrichten)
      _startHomeTransferListener();

      // Benachrichtigungs-Einstellung laden
      final notifEnabled = await NotificationService.isEnabled();
      if (mounted) setState(() => _notificationsEnabled = notifEnabled);
      NotificationService.enabled = notifEnabled;

      // Prüfe ob die App über einen Datei-Intent gestartet wurde
      try {
        const channel = MethodChannel('de.paulporg.obmc/file_intent');
        final pendingUri = await channel.invokeMethod<String>('getPendingFileIntent');
        if (pendingUri != null && mounted) {
          // Kurze Verzögerung damit das UI vollständig aufgebaut ist
          await Future.delayed(const Duration(milliseconds: 300));
          await _handleIncomingFileIntent(pendingUri);
        }
      } catch (e) {
        developer.log('log: Intent-Kanal nicht verfügbar: $e', name: 'initializeApp');
      }

      // Windows: per Drag auf die EXE / „Öffnen mit“ übergebene Datei
      final launchFile = LaunchArgs.pendingFilePath;
      if (launchFile != null && mounted) {
        LaunchArgs.pendingFilePath = null;
        await Future.delayed(const Duration(milliseconds: 300));
        await _handleIncomingFileIntent(launchFile);
      }
      
      developer.log('log: App-Initialisierung erfolgreich abgeschlossen', name: 'initializeApp');
    } catch (e) {
      developer.log('log: Fehler bei App-Initialisierung: $e', name: 'initializeApp');
      
      // Fallback: Versuche erneut nach kurzer Pause
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) {
          try {
            _loadChatGroups();
          } catch (e2) {
            developer.log('log: Fallback-Initialisierung fehlgeschlagen: $e2', name: 'initializeApp');
            // Setze leere Liste als letzten Ausweg
            if (mounted) {
              setState(() {
                chatGroups = [];
              });
            }
          }
        }
      });
    }
  }

  // Initialisiert RSA-Verschlüsselung
  Future<void> _initializeRSA() async {
    try {
      developer.log('log: RSA-Initialisierung gestartet', name: 'initializeRSA');
      
      // Prüfe ob bereits Schlüssel existieren
      final hasKeys = await _rsaKeyManager.hasKeyPair();
      
      if (!hasKeys) {
        // Generiere neues Schlüsselpaar
        developer.log('log: Generiere neues RSA-Schlüsselpaar', name: 'initializeRSA');
        await _rsaKeyManager.generateAndSaveKeyPair();
      } else {
        // Lade vorhandene Schlüssel
        developer.log('log: Lade vorhandene RSA-Schlüssel', name: 'initializeRSA');
        await _rsaKeyManager.loadKeyPair();
      }
      
      setState(() {
        _rsaKeysInitialized = true;
      });
      
      developer.log('log: RSA-Initialisierung erfolgreich abgeschlossen', name: 'initializeRSA');
    } catch (e) {
      developer.log('log: Fehler bei RSA-Initialisierung: $e', name: 'initializeRSA');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Eingehende Datei-Intents verarbeiten (.qgap / .qgap_ec)
  // ─────────────────────────────────────────────────────────────

  Future<void> _handleIncomingFileIntent(String uriString) async {
    developer.log('QGAP_INTENT: Eingehender File-Intent URI: $uriString',
        name: '_handleIncomingFileIntent');

    // Neues Format: "localPath\u001FdisplayName\u001FintentMimeType\u001ForiginalUri"
    // Fallback: alter einfacher URI-String
    String localPathOrUri = uriString;
    String? passedDisplayName;
    String? passedMimeType;

    if (uriString.contains('\u001F')) {
      final parts = uriString.split('\u001F');
      localPathOrUri = parts[0]; // temp-Dateipfad oder original-URI
      passedDisplayName = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
      passedMimeType   = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;
      debugPrint('QGAP_INTENT: localPath=$localPathOrUri displayName=$passedDisplayName intentMime=$passedMimeType');
    }

    // Dateiinhalt lesen (content:// oder file:// oder direkter Dateipfad)
    List<int> fileBytes = [];
    String fileName = passedDisplayName
        ?? AppStorage.fileNameOf(localPathOrUri).split('?').first;
    String? mimeType = passedMimeType;

    try {
      if (localPathOrUri.startsWith('content://')) {
        // Fallback: Content URI direkt lesen (altes Verhalten)
        const channel = MethodChannel('de.paulporg.obmc/file_intent');
        developer.log('QGAP_INTENT: Rufe getContentUriInfo für URI auf', name: '_handleIncomingFileIntent');
        final info = await channel.invokeMethod<Map<dynamic, dynamic>>(
          'getContentUriInfo',
          localPathOrUri,
        );
        developer.log('QGAP_INTENT: getContentUriInfo Ergebnis: $info', name: '_handleIncomingFileIntent');
        if (info != null) {
          final displayName = info['displayName'] as String?;
          final detectedMimeType = info['mimeType'] as String?;
          developer.log('QGAP_INTENT: displayName=$displayName mimeType=$detectedMimeType', name: '_handleIncomingFileIntent');
          if (displayName != null && displayName.trim().isNotEmpty) fileName = displayName;
          if (detectedMimeType != null && detectedMimeType.trim().isNotEmpty && mimeType == null) {
            mimeType = detectedMimeType;
          }
        }
        developer.log('QGAP_INTENT: Lese Dateiinhalt via readContentUri', name: '_handleIncomingFileIntent');
        final bytes = await channel.invokeMethod<Uint8List>('readContentUri', localPathOrUri);
        fileBytes = bytes ?? [];
        developer.log('QGAP_INTENT: Dateiinhalt gelesen: ${fileBytes.length} Bytes', name: '_handleIncomingFileIntent');
      } else {
        // Direkte Datei (gecachter Temp-File vom nativen Code oder file://)
        final path = localPathOrUri.startsWith('file://')
            ? localPathOrUri.replaceFirst('file://', '')
            : localPathOrUri;
        fileBytes = await File(path).readAsBytes();
        debugPrint('QGAP_INTENT: Datei gelesen: $path → ${fileBytes.length} Bytes');
      }
    } catch (e) {
      developer.log('QGAP_INTENT: Fehler beim Lesen der Datei: $e',
          name: '_handleIncomingFileIntent');
      debugPrint('QGAP_INTENT: Fehler beim Lesen der Datei: $e');
    }

    if (!mounted) return;

    final normalizedFileName = fileName.toLowerCase();
    final isQGapEcByName  = normalizedFileName.endsWith('.qgap_ec');
    final isQGapAesByName = normalizedFileName.endsWith('.qgap_aes');
    final isQGapByName    = normalizedFileName.endsWith('.qgap');
    final isQGapByPayload = _looksLikeQGapPayload(fileBytes);
    final isQGapByMime   = mimeType == 'application/octet-stream';

    debugPrint(
      'QGAP_INTENT: fileName="$fileName" mimeType="$mimeType" bytes=${fileBytes.length} '
      'isQGapEcByName=$isQGapEcByName isQGapByName=$isQGapByName '
      'isQGapByPayload=$isQGapByPayload isQGapByMime=$isQGapByMime',
    );

    final isQGapChByName  = normalizedFileName.endsWith('.qgap_ch');
    final isQGapChByPayload = !isQGapChByName && _looksLikeQGapChPayload(fileBytes);

    if (isQGapChByName || isQGapChByPayload) {
      debugPrint('QGAP_INTENT: → _handleQGapChIntent (byName=$isQGapChByName byPayload=$isQGapChByPayload)');
      await _handleQGapChIntent(fileName, fileBytes);
    } else if (isQGapEcByName) {
      debugPrint('QGAP_INTENT: → _handleQGapEcIntent');
      await _handleQGapEcIntent(fileName, fileBytes);
    } else if (isQGapAesByName) {
      debugPrint('QGAP_INTENT: → _handleQGapAesIntent');
      await _handleQGapAesIntent(fileName, fileBytes);
    } else if (isQGapByName || isQGapByPayload || isQGapByMime) {
      // isQGapByMime allein reicht jetzt aus (MIME vom Intent ist vertrauenswürdig)
      debugPrint('QGAP_INTENT: → _handleQGapIntent');
      await _handleQGapIntent(fileName, fileBytes);
    } else {
      debugPrint('QGAP_INTENT: → UNBEKANNTER DATEITYP');
      // Unbekannter Typ — Hinweis anzeigen
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unbekannter Dateityp'),
          content: Text(
              'Die Datei "$fileName" wird nicht unterstützt.\n\nNur .qgap, .qgap_ec und .qgap_aes Dateien können geöffnet werden.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'))
          ],
        ),
      );
    }
  }

  /// Prüft, ob der Dateiinhalt wie eine .qgap Nachricht mit Base64-Metadaten aussieht.
  bool _looksLikeQGapPayload(List<int> bytes) {
    if (bytes.isEmpty) return false;
    if (bytes.length >= 8 &&
        bytes[0] == 0x4F &&
        bytes[1] == 0x42 &&
        bytes[2] == 0x4D &&
        bytes[3] == 0x43) {
      return true;
    }
    try {
      final content = utf8.decode(bytes, allowMalformed: true);
      return _extractQGapMetadata(content) != null;
    } catch (_) {
      return false;
    }
  }

  /// Erkennt eine .qgap_ch Einladungsdatei anhand des JSON-Inhalts,
  /// unabhängig vom Dateinamen.
  bool _looksLikeQGapChPayload(List<int> bytes) {
    if (bytes.isEmpty) return false;
    try {
      final content = utf8.decode(bytes, allowMalformed: true);
      final data = jsonDecode(content);
      if (data is Map<String, dynamic>) {
        return data.containsKey('firestoreChatId') && data.containsKey('creatorUid');
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Extrahiert valide QGap-Metadaten aus einem payload-String.
  String? _extractQGapMetadata(String content) {
    for (int len = 4; len <= 512; len += 4) {
      if (len > content.length) break;
      try {
        final possibleMeta = content.substring(0, len);
        final decoded = utf8.decode(base64.decode(possibleMeta));
        if (!_isValidQGapMetadata(decoded)) continue;

        final remaining = content.substring(len);
        if (remaining.isEmpty) continue;

        final firstPart = decoded.split(';')[0];
        final isRsaOrHybrid =
            firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID';
        if (!isRsaOrHybrid) {
          base64.decode(remaining);
        }

        return decoded;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  bool _isValidQGapMetadata(String decoded) {
    if (!decoded.endsWith(';')) return false;
    final parts = decoded.split(';');
    if (parts.length < 3) return false;

    final firstPart = parts[0];
    final secondPart = parts[1];
    final offset = int.tryParse(secondPart);
    if (offset == null || offset < 0) return false;

    if (firstPart == 'RSA' || firstPart == 'HYB' || firstPart == 'HYBRID') {
      if (parts.length < 4 || parts[2].isEmpty) return false;
      return true;
    }

    return firstPart.endsWith('.qgap') || firstPart.endsWith('.qgap_ec');
  }

  /// Verarbeitet eine eingehende .qgap_ec Datei:
  /// Fragt den Nutzer, welchem Chat die EC-Datei zugeordnet werden soll.
  Future<void> _handleQGapEcIntent(
      String fileName, List<int> fileBytes) async {
    if (!mounted) return;

    // Chat-Gruppe auswählen
    ChatGroup? chosen;
    await showDialog(
      context: context,
      builder: (ctx) {
        ChatGroup? selected =
            chatGroups.isNotEmpty ? chatGroups.first : null;
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('🔑 EC-Schlüssel zuordnen'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Datei: $fileName'),
                const SizedBox(height: 8),
                const Text(
                    'Welchem Chat soll dieser EC-Schlüssel zugeordnet werden?'),
                const SizedBox(height: 12),
                if (chatGroups.isEmpty)
                  const Text('Keine Chats vorhanden.',
                      style: TextStyle(color: Colors.red))
                else
                  DropdownButton<ChatGroup>(
                    value: selected,
                    isExpanded: true,
                    items: chatGroups
                        .map((g) => DropdownMenuItem(
                            value: g,
                            child: Text(g.name,
                                overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (v) => setS(() => selected = v),
                  ),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Abbrechen')),
              TextButton(
                  onPressed: selected == null
                      ? null
                      : () {
                          chosen = selected;
                          Navigator.of(ctx).pop();
                        },
                  child: const Text('Zuordnen')),
            ],
          );
        });
      },
    );

    if (chosen != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('chat_ec_file_${chosen!.id}', fileName);
      developer.log('log: EC-Datei "$fileName" → Chat "${chosen!.name}" zugeordnet',
          name: '_handleQGapEcIntent');
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
              content: Text(
                  '✅ EC-Schlüssel "$fileName" → "${chosen!.name}" zugeordnet')),
        );
      }
    }
  }

  /// Verarbeitet eine eingehende .qgap_aes Datei (RSA/AES-Public-Key):
  /// Liest den öffentlichen Schlüssel, importiert ihn und bietet Chat-Anlage an.
  Future<void> _handleQGapAesIntent(
      String fileName, List<int> fileBytes) async {
    if (!mounted) return;

    String decoded;
    try {
      decoded = utf8.decode(fileBytes);
    } catch (e) {
      showQgapSnackBar(context, 
        const SnackBar(
          content: Text('❌ Datei konnte nicht gelesen werden (kein UTF-8)'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(decoded);
    if (publicKey == null) {
      if (!mounted) return;
      showQgapSnackBar(context, 
        SnackBar(
          content: Text('❌ "$fileName" enthält keinen gültigen RSA-Public-Key'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!mounted) return;

    // Vorhandene Kontaktschlüssel laden
    final existingKeys = await _rsaKeyManager.getContactKeys();

    // Kontaktname vorschlagen: Dateiname ohne Endung
    final suggested = fileName.endsWith('.qgap_aes')
        ? fileName.substring(0, fileName.length - 9)
        : fileName;
    final controller = TextEditingController(text: suggested);

    // Modus-Auswahl für den Empfang
    String chatMode = 'new'; // 'new', 'existing', 'only'
    ChatGroup? selectedGroup;
    final rsaGroups = chatGroups
        .where((g) =>
            g.defaultEncryptionType == message_model.EncryptionType.rsa ||
            g.defaultEncryptionType == message_model.EncryptionType.hybrid)
        .toList();
    if (rsaGroups.isNotEmpty) {
      chatMode = 'existing';
      selectedGroup = rsaGroups.first;
    }

    String? contactName;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final nameAlreadyKnown = existingKeys.containsKey(controller.text.trim());
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.vpn_key, color: Colors.blue),
                SizedBox(width: 8),
                Expanded(child: Text('🔐 RSA-Schlüssel empfangen')),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Datei: $fileName',
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 12),
                  const Text('Kontaktname für diesen Schlüssel:'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'z. B. Alice',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setS(() {}),
                  ),
                  if (nameAlreadyKnown) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber,
                              color: Colors.orange, size: 16),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '⚠️ Für "${controller.text.trim()}" existiert bereits ein Schlüssel. Er wird überschrieben.',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Divider(),
                  const Text('Nach dem Import:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  RadioListTile<String>(
                    dense: true,
                    title: const Text('Neuen Chat anlegen'),
                    value: 'new',
                    groupValue: chatMode,
                    onChanged: (v) => setS(() => chatMode = v!),
                  ),
                  if (rsaGroups.isNotEmpty) ...[
                    RadioListTile<String>(
                      dense: true,
                      title: const Text('Vorhandenem Chat zuweisen'),
                      value: 'existing',
                      groupValue: chatMode,
                      onChanged: (v) => setS(() => chatMode = v!),
                    ),
                    if (chatMode == 'existing')
                      Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: DropdownButton<ChatGroup>(
                          value: selectedGroup,
                          isExpanded: true,
                          items: rsaGroups
                              .map((g) => DropdownMenuItem(
                                    value: g,
                                    child: Text(g.name,
                                        overflow: TextOverflow.ellipsis),
                                  ))
                              .toList(),
                          onChanged: (v) => setS(() => selectedGroup = v),
                        ),
                      ),
                  ],
                  RadioListTile<String>(
                    dense: true,
                    title: const Text('Nur importieren'),
                    value: 'only',
                    groupValue: chatMode,
                    onChanged: (v) => setS(() => chatMode = v!),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () {
                  contactName = controller.text.trim();
                  Navigator.of(ctx).pop();
                },
                child: const Text('Importieren'),
              ),
            ],
          );
        },
      ),
    );

    if (contactName == null || contactName!.isEmpty || !mounted) return;

    await _rsaKeyManager.saveContactPublicKey(contactName!, publicKey);

    if (!mounted) return;
    showQgapSnackBar(context, 
      SnackBar(
        content: Text('✅ RSA-Schlüssel für "$contactName" importiert'),
        backgroundColor: Colors.green,
      ),
    );

    if (chatMode == 'only') return;

    final prefs = await SharedPreferences.getInstance();
    if (chatMode == 'existing' && selectedGroup != null) {
      // Kontakt dem Chat zuordnen
      await prefs.setString('chat_contact_${selectedGroup!.id}', contactName!);
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: selectedGroup!.name,
            chatGroupId: selectedGroup!.id,
            encryptionType: selectedGroup!.defaultEncryptionType,
          ),
        ),
      ).then((_) => _loadChatGroups());
    } else if (chatMode == 'new') {
      // Neuen RSA-Chat anlegen
      final newGroup = ChatGroup(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: contactName!,
        description: '',
        createdAt: DateTime.now(),
        iconEmoji: '🔐',
        defaultEncryptionType: message_model.EncryptionType.rsa,
      );
      await prefs.setString('chat_contact_${newGroup.id}', contactName!);
      final groupsJson =
          List<String>.from(prefs.getStringList('chat_groups') ?? []);
      groupsJson.add(json.encode(newGroup.toJson()));
      await prefs.setStringList('chat_groups', groupsJson);
      await _loadChatGroups();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: newGroup.name,
            chatGroupId: newGroup.id,
            encryptionType: newGroup.defaultEncryptionType,
          ),
        ),
      ).then((_) => _loadChatGroups());
    }
  }

  // ─── Online-Chat: Einladung senden ──────────────────────────────────────────

  /// Erstellt (falls nötig) einen Firestore-Chat und teilt eine .qgap_ch Datei.

  Future<void> _sendOnlineInvite(ChatGroup group) async {
    // Gerät muss als Online-Gerät konfiguriert sein
    if (!_deviceRoleOnline) {
      if (!mounted) return;
      showQgapSnackBar(context, 
        const SnackBar(content: Text(
            '⚠️ Gerät ist nicht als Online-Gerät konfiguriert. Geräterolle bitte in den Einstellungen ändern.')));
      return;
    }
    try {
      final svc = FirestoreService();
      final uid = AuthService.currentUid;
      if (uid == null) {
        if (!mounted) return;
        showQgapSnackBar(context, 
          const SnackBar(content: Text('Nicht mit Firebase verbunden.')));
        return;
      }

      // Chat-Typ bestimmen: QGAP_ec = One-Time-Pad, QGAP_aes = RSA/Hybrid
      final chatType = group.defaultEncryptionType == message_model.EncryptionType.oneTimePad
          ? 'qgap_ec'
          : 'qgap_aes';

      // firestoreChatId generieren falls noch nicht vorhanden
      String firestoreChatId = group.firestoreChatId
          ?? AuthService.generateRandomString(20, emailSafe: true);

      // Firestore-Chat anlegen (oder vorhandenen nutzen)
      final alreadyMember = group.firestoreChatId != null
          ? await svc.isMemberOf(firestoreChatId)
          : false;
      if (!alreadyMember) {
        await svc.createChat(firestoreChatId);
        await svc.sendHandshake(firestoreChatId);
      }

      // ChatGroup lokal aktualisieren
      if (group.firestoreChatId == null) {
        final idx = chatGroups.indexWhere((g) => g.id == group.id);
        if (idx >= 0) {
          chatGroups[idx] = chatGroups[idx].copyWith(
            isOnlineEnabled: true,
            firestoreChatId: firestoreChatId,
          );
          await _saveChatGroups();
        }
      }

      // Payload aufbauen (kein chatName – Privatsphäre)
      final payloadMap = <String, dynamic>{
        'version': 1,
        'chatType': chatType,
        'firestoreChatId': firestoreChatId,
        'creatorUid': uid,
      };

      // Bei QGAP_aes: Nutzer fragen ob Public Key mitgesendet werden soll
      if (chatType == 'qgap_aes' && mounted) {
        final includeKey = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('🔑 Public Key mitsenden?'),
            content: const Text(
              'Soll dein eigener Public Key in die Einladung aufgenommen werden?\n\n'
              'Der Empfänger kann dann sofort verschlüsselte Nachrichten an dich senden. '
              'Du kannst den Key auch später separat übermitteln.',
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
          if (myPublicKeyStr != null) {
            payloadMap['creatorPublicKey'] = myPublicKeyStr;
          }
        }
      }

      // Dateiname abfragen + Wahl: Datei teilen oder QR-Code
      final jsonStr = jsonEncode(payloadMap);
      final fileNameController = TextEditingController(text: 'ChatEinladung');
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cloud_upload, color: Colors.blue),
              SizedBox(width: 8),
              Flexible(child: Text('Einladung senden')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Wähle wie du die Einladung teilen möchtest.'),
              const SizedBox(height: 12),
              TextField(
                controller: fileNameController,
                decoration: const InputDecoration(
                  labelText: 'Dateiname',
                  border: OutlineInputBorder(),
                  suffixText: '.qgap_ch',
                  helperText: 'Nur für "Datei senden" relevant',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Abbrechen'),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.qr_code),
              label: const Text('QR-Code'),
              onPressed: () => Navigator.of(ctx).pop('qr'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.share),
              label: const Text('Datei senden'),
              onPressed: () => Navigator.of(ctx).pop('file'),
            ),
          ],
        ),
      );
      final rawName = fileNameController.text.trim();
      fileNameController.dispose();
      if (action == null || !mounted) return;

      if (action == 'qr') {
        final bytes = Uint8List.fromList(utf8.encode(jsonStr));
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
        );
        return;
      }

      String baseName = rawName.isEmpty ? 'ChatEinladung' : rawName;
      if (baseName.endsWith('.qgap_ch')) baseName = baseName.substring(0, baseName.length - 8);
      final fileName = '$baseName.qgap_ch';

      if (!mounted) return;
      await ShareService.showShareDialog(
        context: context,
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
        clipboardText: jsonStr,
        subject: 'QGap Chat-Einladung',
      );
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context, 
        SnackBar(content: Text('Fehler beim Erstellen der Einladung: $e')));
    }
  }

  // ─── Offline-EC-Chat: Einladung senden (Air-Gap-fähig, ohne Firestore) ──

  /// Sendet eine Offline-EC-Einladung (`chatType=QGAP_ec_offline`) für einen
  /// One-Time-Pad-Chat per QR-Code oder als `.qgap_ch`-Datei.
  ///
  /// Funktioniert sowohl auf dem Air-Gap- als auch auf dem Online-Gerät, da
  /// kein Firestore erforderlich ist.
  ///
  /// Übertragen werden ausschließlich:
  ///  - `chatGroupId`        gemeinsame lokale Chat-ID
  ///  - `ecCode`             Zufalls-ID-Suffix der `.qgap_ec`-Datei
  ///  - `partnerOnlineUid`   (optional) Firestore-UID des gepaarten
  ///                         Online-Relays — dient dem Empfänger als
  ///                         Transport-Adresse (Firestore-Routing).
  ///
  /// KEINE personenbezogenen Klartext-Daten (Name, Beschreibung, Emoji,
  /// freier Datei-Text). Die Schlüsseldatei selbst geht ausschließlich
  /// per USB.
  Future<void> _sendOfflineEcInvite(ChatGroup group) async {
    final prefs = await SharedPreferences.getInstance();
    // EC-Datei-Zuordnung lesen (chat_ec_file_<id> bevorzugt, chat_key_<id>
    // als Fallback aus älteren Versionen). Falls nur der Code direkt
    // hinterlegt ist (Empfänger vor USB-Import), nehmen wir diesen.
    final ecFile = (prefs.getString('chat_ec_file_${group.id}') ??
            prefs.getString('chat_key_${group.id}') ??
            '')
        .trim();
    String? ecCode;
    if (ecFile.isNotEmpty && ecFile.endsWith('.qgap_ec')) {
      ecCode = EcKeyfileService.extractCodeFromFilename(ecFile);
    }
    ecCode ??= prefs.getString('chat_ec_code_${group.id}')?.trim();
    if (ecCode == null || ecCode.isEmpty) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
          content: Text(
            'Diesem Chat ist keine .qgap_ec mit gültigem Code zugeordnet — '
            'Einladung nicht möglich.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Partner-UID des gepaarten Online-Relays (für Firestore-Routing).
    final partnerOnlineUid = await PairingService.getPartnerOnlineUid();

    final payloadMap = <String, dynamic>{
      'version': 1,
      'chatType': 'qgap_ec_offline',
      'chatGroupId': group.id,
      'ecCode': ecCode,
      if (partnerOnlineUid != null && partnerOnlineUid.isNotEmpty)
        'partnerOnlineUid': partnerOnlineUid,
    };
    final jsonStr = jsonEncode(payloadMap);

    if (!mounted) return;
    final fileNameController =
        TextEditingController(text: 'ChatEinladung_EC');
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.usb, color: Colors.blue),
            SizedBox(width: 8),
            Flexible(child: Text('EC-Einladung senden (Offline)')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diese Einladung enthält nur die Chat-ID, den EC-Code '
              'und (falls vorhanden) die Firestore-UID des gepaarten '
              'Online-Geräts — keine persönlichen Daten.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            const Text(
              'Wichtig: die zugehörige .qgap_ec-Schlüsseldatei muss '
              'separat per USB übertragen werden — sie wird hier nicht '
              'mitgeschickt.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: fileNameController,
              decoration: const InputDecoration(
                labelText: 'Dateiname',
                border: OutlineInputBorder(),
                suffixText: '.qgap_ch',
                helperText: 'Nur für „Datei senden" relevant',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Abbrechen'),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('QR-Code'),
            onPressed: () => Navigator.of(ctx).pop('qr'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('Datei senden'),
            onPressed: () => Navigator.of(ctx).pop('file'),
          ),
        ],
      ),
    );
    final rawName = fileNameController.text.trim();
    fileNameController.dispose();
    if (action == null || !mounted) return;

    if (action == 'qr') {
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
      );
      return;
    }

    // action == 'file' → .qgap_ch teilen
    String baseName = rawName.isEmpty ? 'ChatEinladung_EC' : rawName;
    if (baseName.endsWith('.qgap_ch')) {
      baseName = baseName.substring(0, baseName.length - 8);
    }
    final fileName = '$baseName.qgap_ch';
    try {
      if (!mounted) return;
      await ShareService.showShareDialog(
        context: context,
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(jsonStr)),
        clipboardText: jsonStr,
        subject: 'QGap EC-Einladung',
      );
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(
          content: Text('Fehler beim Erstellen der EC-Einladung: $e'),
        ),
      );
    }
  }

  // ─── Online-Chat: Einladung empfangen ────────────────────────────────────

  /// Verarbeitet eine empfangene .qgap_ch Chat-Einladungs-Datei.
  Future<void> _handleQGapChIntent(
      String fileName, List<int> fileBytes) async {
    if (!mounted) return;
    try {
      final jsonData = jsonDecode(utf8.decode(fileBytes)) as Map<String, dynamic>;

      // Admin-Kopplung für Präsentation (als Datei empfangen)
      if (_normalizeLegacyType(jsonData['kind'] as String?) == 'qgap_ps_admin') {
        await _handlePublicScreenAdminQr(jsonData);
        return;
      }

      final chatTypeRaw = _normalizeLegacyType(
          jsonData['chatType'] as String? ?? 'qgap_ec');

      // Offline-EC-Einladung: kein Firestore, separater Code-Pfad
      if (chatTypeRaw == 'qgap_ec_offline') {
        await _handleOfflineEcChatInvite(jsonData);
        return;
      }

      // Relay-Pairing-Einladung (Relay → Online B)
      if (chatTypeRaw == 'qgap_relay_pair_inv') {
        await _handleRelayPairInv(jsonData);
        return;
      }

      final firestoreChatId  = jsonData['firestoreChatId']  as String?;
      final creatorUid       = jsonData['creatorUid']       as String?;
      final remoteName       = jsonData['chatName']         as String? ?? 'Unbekannt';
      final chatType         = chatTypeRaw;
      final creatorPublicKey = jsonData['creatorPublicKey'] as String?;

      if (firestoreChatId == null || creatorUid == null) {
        showQgapSnackBar(context, 
          const SnackBar(content: Text('Ungültige Chat-Einladung.')));
        return;
      }

      final isAesChat = chatType == 'qgap_aes';

      // Schon lokal vorhanden?
      final existing = chatGroups
          .where((g) => g.firestoreChatId == firestoreChatId)
          .firstOrNull;

      if (existing != null) {
        if (!mounted) return;
        showQgapSnackBar(context, SnackBar(
          content: Text('ℹ️ Chat „${existing.name}" ist bereits vorhanden.'),
          backgroundColor: Colors.blueGrey,
          action: SnackBarAction(label: 'OK', onPressed: () {}),
        ));
        return;
      }

      final nameCtrl = TextEditingController(text: remoteName);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('☁️ Chat-Einladung empfangen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Einladung zum Online-Chat \u201e$remoteName\u201c.'),
              Text(
                isAesChat ? 'Verschlüsselung: RSA/AES (QGAP_aes)' : 'Verschlüsselung: One-Time-Pad (QGAP_ec)',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              const Text('Lokaler Chat-Name:'),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Chat-Name'),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Abbrechen')),
            ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Beitreten')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      final localName = nameCtrl.text.trim().isEmpty ? remoteName : nameCtrl.text.trim();
      final svc = FirestoreService();

      // Auth sicherstellen: läuft im Hintergrund, kann beim schnellen Scan noch fehlen.
      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await AuthService.ensureLoggedIn().timeout(const Duration(seconds: 15));
        } catch (_) {}
      }
      if (FirebaseAuth.instance.currentUser == null) {
        if (mounted) {
          showQgapSnackBar(context, const SnackBar(
            content: Text('⚠️ Nicht eingeloggt – bitte kurz warten und erneut versuchen.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ));
        }
        return;
      }

      if (existing == null) {
        await svc.joinChat(firestoreChatId);
      }
      await svc.sendHandshake(firestoreChatId);
      await LocalContactService.saveLocalName(creatorUid, localName);

      // Bei QGAP_aes: Ersteller-Public-Key speichern
      if (isAesChat && creatorPublicKey != null) {
        await _rsaKeyManager.saveContactPublicKeyFromJson(localName, creatorPublicKey);
      }

      if (existing == null) {
        final encType = isAesChat
            ? message_model.EncryptionType.hybrid
            : message_model.EncryptionType.oneTimePad;
        final prefs = await SharedPreferences.getInstance();
        final newGroup = ChatGroup(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: localName,
          description: 'Online-Chat ($chatType)',
          createdAt: DateTime.now(),
          iconEmoji: '☁️',
          defaultEncryptionType: encType,
          isOnlineEnabled: true,
          firestoreChatId: firestoreChatId,
        );
        // Bei QGAP_aes: Kontaktzuordnung speichern
        if (isAesChat) {
          await prefs.setString('chat_contact_${newGroup.id}', localName);
        }
        // Bei QGAP_ec: creatorUid als Partner-UID für Relay-Wrap speichern.
        // Das Air-Gap-Gerät nutzt diesen Wert wenn es QR-Codes für die
        // Weiterleitung über das Online-Relay erstellt (chat_partner_uid_).
        if (!isAesChat && creatorUid.isNotEmpty) {
          await prefs.setString('chat_partner_uid_${newGroup.id}', creatorUid);
          developer.log(
              'log: 📡 chat_partner_uid_${newGroup.id} = $creatorUid gesetzt (QGAP_ec Relay-Ziel)',
              name: '_handleQGapChIntent');
        }
        final groupsJson =
            List<String>.from(prefs.getStringList('chat_groups') ?? []);
        groupsJson.add(json.encode(newGroup.toJson()));
        await prefs.setStringList('chat_groups', groupsJson);
        await _loadChatGroups();
        if (!mounted) return;
        showQgapSnackBar(context, 
          SnackBar(content: Text('☁️ Online-Chat „$localName" beigetreten!')));
      } else {
        // Chat existiert bereits – Partner-UID ggf. nachpflegen
        if (!isAesChat && creatorUid.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          if ((prefs.getString('chat_partner_uid_${existing.id}') ?? '').isEmpty) {
            await prefs.setString('chat_partner_uid_${existing.id}', creatorUid);
            developer.log(
                'log: 📡 chat_partner_uid_${existing.id} nachgepflegt = $creatorUid',
                name: '_handleQGapChIntent');
          }
        }
        if (!mounted) return;
        showQgapSnackBar(context, 
          const SnackBar(content: Text('☁️ Handshake gesendet. Bereits Mitglied.')));
      }

      // Bei QGAP_aes: eigenen Public Key zurück senden (mit User-Bestätigung)
      if (isAesChat && mounted) {
        final sendKey = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('🔑 Eigenen Public Key senden?'),
            content: const Text(
              'Soll dein eigener Public Key an den Einladenden gesendet werden?\n\n'
              'Nur dann kann der Einladende dir verschlüsselte Nachrichten senden.',
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Nein')),
              ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Ja, senden')),
            ],
          ),
        );
        if (sendKey == true && mounted) {
          final prefs = await SharedPreferences.getInstance();
          final myPublicKeyStr = prefs.getString('rsa_public_key');
          if (myPublicKeyStr != null) {
            await svc.sendPublicKeyHandshake(firestoreChatId, myPublicKeyStr);
            if (mounted) {
              showQgapSnackBar(context, 
                const SnackBar(content: Text('🔑 Public Key gesendet.')));
            }
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context, 
        SnackBar(content: Text('Fehler beim Verarbeiten der Einladung: $e')));
    }
  }

  /// Verarbeitet eine empfangene Offline-EC-Einladung (chatType=`QGAP_ec_offline`).
  /// Legt einen lokalen OTP-Chat an (gleiche `chatGroupId` wie der Sender),
  /// hinterlegt nur den EC-Code (zur sp\u00e4teren Auflösung über USB-Import) und
  /// die Firestore-UID des gepaarten Online-Relays des Senders (für den
  /// Transport via Firestore).
  ///
  /// In der Einladung sind KEINE persönlichen Daten enthalten (kein Chatname,
  /// keine Beschreibung, kein Emoji, kein freier Datei-Text). Diese Werte
  /// vergibt der Empfänger lokal.
  Future<void> _handleOfflineEcChatInvite(Map<String, dynamic> data) async {
    if (!mounted) return;
    final remoteId         = data['chatGroupId']      as String?;
    final ecCode           = data['ecCode']           as String?;
    final partnerOnlineUid = data['partnerOnlineUid'] as String?;

    if (remoteId == null || remoteId.isEmpty) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Ungültige Offline-EC-Einladung (keine Chat-ID).')),
      );
      return;
    }
    if (ecCode == null || ecCode.isEmpty) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Ungültige Offline-EC-Einladung (kein EC-Code).')),
      );
      return;
    }

    // Schon vorhanden?
    final existing =
        chatGroups.where((g) => g.id == remoteId).firstOrNull;
    if (existing != null) {
      // Code/Partner-UID nachpflegen, falls fehlt
      final prefs = await SharedPreferences.getInstance();
      if ((prefs.getString('chat_ec_code_${existing.id}') ?? '').isEmpty) {
        await prefs.setString('chat_ec_code_${existing.id}', ecCode);
      }
      if (partnerOnlineUid != null && partnerOnlineUid.isNotEmpty) {
        if ((prefs.getString('chat_partner_uid_${existing.id}') ?? '').isEmpty) {
          await prefs.setString('chat_partner_uid_${existing.id}', partnerOnlineUid);
        }
      }
      if (!mounted) return;
      showQgapSnackBar(context, SnackBar(
        content: Text('ℹ️ Chat „${existing.name}" ist bereits vorhanden.'),
        backgroundColor: Colors.blueGrey,
      ));
      return;
    }

    // Empfänger vergibt lokalen Namen + Emoji selbst (keine Übertragung
    // personenbezogener Daten in der Einladung).
    final nameCtrl = TextEditingController();
    String selectedEmoji = '🔒';
    const emojiOptions = ['🔒', '💬', '🛡️', '🔐', '📡', '🤝', '🧑‍💻', '👤'];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.usb, color: Colors.blue),
              SizedBox(width: 8),
              Flexible(child: Text('EC-Einladung empfangen')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Einladung zu einem Offline-EC-Chat (One-Time-Pad).',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 6),
              const Text(
                'Es wurden keine persönlichen Daten übertragen. '
                'Vergib lokal Namen und Symbol für diesen Chat:',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Chat-Name (lokal)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Symbol:', style: TextStyle(fontSize: 12)),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in emojiOptions)
                    ChoiceChip(
                      label: Text(e, style: const TextStyle(fontSize: 18)),
                      selected: selectedEmoji == e,
                      onSelected: (_) => setS(() => selectedEmoji = e),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'EC-Code (Schlüsseldatei-Kennung):',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    SelectableText(
                      ecCode,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Die zugehörige .qgap_ec-Datei muss anschließend per USB '
                      'importiert werden \u2013 sie wird dann automatisch diesem '
                      'Chat zugeordnet.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Abbrechen')),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Beitreten'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final localName = nameCtrl.text.trim();
    final prefs = await SharedPreferences.getInstance();
    final newGroup = ChatGroup(
      id: remoteId, // gleiche ID wie Sender
      name: localName,
      description: 'Offline-EC-Chat',
      createdAt: DateTime.now(),
      iconEmoji: selectedEmoji,
      defaultEncryptionType: message_model.EncryptionType.oneTimePad,
      isOnlineEnabled: false,
    );
    final groupsJson =
        List<String>.from(prefs.getStringList('chat_groups') ?? []);
    groupsJson.add(json.encode(newGroup.toJson()));
    await prefs.setStringList('chat_groups', groupsJson);

    // Nur den EC-Code hinterlegen \u2013 die Datei selbst kommt per USB.
    // Beim Öffnen des Chats sucht _loadEcSettings via findEcFileByCode().
    await prefs.setString('chat_ec_code_${newGroup.id}', ecCode);
    if (partnerOnlineUid != null && partnerOnlineUid.isNotEmpty) {
      await prefs.setString(
          'chat_partner_uid_${newGroup.id}', partnerOnlineUid);
    }

    await _loadChatGroups();
    if (!mounted) return;
    showQgapSnackBar(context, SnackBar(
      content: Text(
        '✅ Offline-EC-Chat „$localName" angelegt. '
        'Bitte .qgap_ec mit Code "$ecCode" per USB importieren.',
      ),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 6),
    ));
  }

  /// Verarbeitet eine eingehende .qgap Datei:
  /// Berücksichtigt Geräterolle (offline/online) und kann neue Chats anlegen.
  Future<void> _handleQGapIntent(
      String fileName, List<int> fileBytes) async {
    if (!mounted) return;

    // Metadaten aus Dateiinhalt extrahieren
    String? scannedData;
    String? metadata;
    // Für Sprachnachrichten: echte Metadaten zum Ermitteln der Ziel-Chat-Gruppe
    String? voiceRealMeta;

    if (fileBytes.isNotEmpty) {
      // 1) Binäres QGap-Envelope bevorzugt parsen.
      if (fileBytes.length >= 8 &&
          fileBytes[0] == 0x4F &&
          fileBytes[1] == 0x42 &&
          fileBytes[2] == 0x4D &&
          fileBytes[3] == 0x43) {
        try {
          final type = fileBytes[5];
          final metaLen = (fileBytes[6] << 8) | fileBytes[7];
          const metaStart = 8;
          final metaEnd = metaStart + metaLen;
          debugPrint('QGAP_INTENT: binary type=0x${type.toRadixString(16)} metaLen=$metaLen fileLen=${fileBytes.length} metaEnd=$metaEnd');
          if ((type == 0x01 || type == 0x02 || type == 0x03) &&
              metaLen > 0 &&
              fileBytes.length >= metaEnd) {
            final extractedMeta =
                utf8.decode(fileBytes.sublist(metaStart, metaEnd));
            debugPrint('QGAP_INTENT: extractedMeta=$extractedMeta');

            int payloadStart = metaEnd;
            if (type == 0x02 || type == 0x03) {
              if (fileBytes.length >= metaEnd + 2) {
                final nameLen =
                    (fileBytes[metaEnd] << 8) | fileBytes[metaEnd + 1];
                payloadStart = metaEnd + 2 + nameLen;
              }
            }

            if (type == 0x03) {
              // Sprachnachricht (Audio): komplettes binäres Envelope als Base64
              // an ChatScreen übergeben; dort erkennt _initializeChat den
              // Marker und leitet die Bytes an _processReceivedBinaryData weiter.
              metadata = 'QGAP_BINARY_VOICE';
              scannedData = base64.encode(fileBytes);
              // Echte Metadaten für die lokale Chat-Gruppen-Erkennung merken.
              // (wird weiter unten unter voiceRealMeta ausgelesen)
              voiceRealMeta = extractedMeta;
              debugPrint('QGAP_INTENT: Voice binary → metadata=QGAP_BINARY_VOICE voiceRealMeta=$extractedMeta');
              developer.log(
                'log: Binäres .qgap-Envelope erkannt (type=voice, metaLen=$metaLen)',
                name: '_handleQGapIntent',
              );
            } else {
              if (fileBytes.length >= payloadStart) {
                metadata = extractedMeta;
                scannedData =
                    base64.encode(fileBytes.sublist(metaStart, metaEnd)) +
                        base64.encode(fileBytes.sublist(payloadStart));
                debugPrint('QGAP_INTENT: binary type=$type parsed OK');
                developer.log(
                  'log: Binäres .qgap-Envelope erkannt (type=$type, metaLen=$metaLen, payloadStart=$payloadStart)',
                  name: '_handleQGapIntent',
                );
              }
            }
          } else {
            debugPrint('QGAP_INTENT: binary envelope condition FAILED type=0x${type.toRadixString(16)} metaLen=$metaLen fileLen=${fileBytes.length} metaEnd=$metaEnd');
          }
        } catch (e) {
          debugPrint('QGAP_INTENT: binary parse ERROR: $e');
          developer.log('log: Fehler beim Parsen des binären .qgap-Envelopes: $e',
              name: '_handleQGapIntent');
        }
      }

      // 2) Fallback: Text-Format base64(metadata)+payload
      try {
        if (metadata == null || scannedData == null) {
          debugPrint('QGAP_INTENT: falling back to text format parsing');
          final content = utf8.decode(fileBytes, allowMalformed: true);
          scannedData = content;
          metadata = _extractQGapMetadata(content);
          debugPrint('QGAP_INTENT: text fallback metadata=$metadata');
        }
      } catch (e) {
        debugPrint('QGAP_INTENT: text fallback ERROR: $e');
        developer.log('log: Fehler beim Parsen der .qgap Datei: $e',
            name: '_handleQGapIntent');
      }
    }

    debugPrint('QGAP_INTENT: after parsing metadata=$metadata scannedData=${scannedData?.length} voiceRealMeta=$voiceRealMeta');

    // EncryptionType aus Metadaten ableiten
    // Bei Sprachnachrichten (type=0x03) steht in metadata nur der Marker
    // 'QGAP_BINARY_VOICE'; die echten Metadaten sind in voiceRealMeta.
    message_model.EncryptionType encType = message_model.EncryptionType.oneTimePad;
    String? keyFileName;
    String? contactName;
    final metaForParsing = voiceRealMeta ?? metadata;
    if (metaForParsing != null) {
      final parts = metaForParsing.split(';');
      final firstPart = parts.isNotEmpty ? parts[0] : '';
      if (firstPart == 'RSA') {
        encType = message_model.EncryptionType.rsa;
        contactName = parts.length >= 3 ? parts[2].trim() : null;
      } else if (firstPart == 'HYB' || firstPart == 'HYBRID') {
        encType = message_model.EncryptionType.hybrid;
        contactName = parts.length >= 3 ? parts[2].trim() : null;
      } else {
        encType = message_model.EncryptionType.oneTimePad;
        keyFileName = firstPart.isNotEmpty ? firstPart : null;
      }
    }

    // Passenden Chat suchen (chat_key_ oder chat_ec_file_ als Fallback)
    ChatGroup? targetGroup;
    if (keyFileName != null) {
      final prefs = await SharedPreferences.getInstance();
      for (final group in chatGroups) {
        final assignedKey = prefs.getString('chat_key_${group.id}')
            ?? prefs.getString('chat_ec_file_${group.id}');
        if (assignedKey == keyFileName) {
          targetGroup = group;
          // chat_key_ sicherstellen für künftige Auto-Erkennung
          final existing = prefs.getString('chat_key_${group.id}');
          if (existing == null || existing.isEmpty) {
            await prefs.setString('chat_key_${group.id}', keyFileName);
          }
          break;
        }
      }
    } else if (contactName != null && contactName.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final wanted = contactName.trim().toLowerCase();
      developer.log(
        'log: RSA/HYB Auto-Match gestartet für Kontakt "$wanted"',
        name: '_handleQGapIntent',
      );
      for (final group in chatGroups) {
        if (group.defaultEncryptionType != message_model.EncryptionType.rsa &&
            group.defaultEncryptionType != message_model.EncryptionType.hybrid) {
          continue;
        }
        final assignedContact =
            (prefs.getString('chat_contact_${group.id}') ?? '').trim().toLowerCase();
        developer.log(
          'log: Prüfe Chat "${group.name}" mit Kontakt "$assignedContact"',
          name: '_handleQGapIntent',
        );
        if (assignedContact == wanted) {
          targetGroup = group;
          break;
        }
      }
      if (targetGroup == null) {
        developer.log(
          'log: Kein passender RSA/HYB-Chat gefunden für Kontakt "$wanted"',
          name: '_handleQGapIntent',
        );
      }
    }

    if (!mounted) return;

    debugPrint('QGAP_INTENT: targetGroup=${targetGroup?.name} encType=$encType keyFileName=$keyFileName');

    // Chat gefunden -> direkt öffnen (automatische Zuordnung)
    final prefs = await SharedPreferences.getInstance();
    if (targetGroup != null) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text(
              '✅ Datei "$fileName" automatisch Chat "${targetGroup.name}" zugeordnet',
            ),
          ),
        );
      }
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: targetGroup!.name,
            chatGroupId: targetGroup.id,
            encryptionType: targetGroup.defaultEncryptionType,
            pendingScannedData: scannedData,
            pendingMetadata: metadata,
          ),
        ),
      ).then((_) => _loadChatGroups());
      return;
    }

    // Alle anderen Fälle: Dialog mit Optionen
    await _showQGapImportChoiceDialog(
      fileName: fileName,
      scannedData: scannedData,
      metadata: metadata,
      encType: encType,
      keyFileName: keyFileName,
      targetGroup: targetGroup,
      prefs: prefs,
    );
  }

  /// Dialog: .qgap empfangen – vorhandenem Chat zuweisen ODER neuen anlegen.
  Future<void> _showQGapImportChoiceDialog({
    required String fileName,
    required String? scannedData,
    required String? metadata,
    required message_model.EncryptionType encType,
    required String? keyFileName,
    required ChatGroup? targetGroup,
    required SharedPreferences prefs,
  }) async {
    if (!mounted) return;

    String encLabel;
    switch (encType) {
      case message_model.EncryptionType.rsa:
        encLabel = 'RSA';
        break;
      case message_model.EncryptionType.hybrid:
        encLabel = 'Hybrid (RSA+AES)';
        break;
      case message_model.EncryptionType.relayForward:
        encLabel = 'Relay-Weiterleitung';
        break;
      default:
        encLabel = 'One-Time-Pad';
    }

    // Modus: 'existing' oder 'new'
    // Bei RSA/Hybrid standardmäßig vorhandenen Chat vorschlagen (sofern verfügbar)
    final selectableGroups = chatGroups.where((g) {
      if (encType == message_model.EncryptionType.oneTimePad) {
        if (g.defaultEncryptionType != message_model.EncryptionType.oneTimePad) {
          return false;
        }
        // .qgap_ec-Chats (mit zugewiesener EC-Datei) ausschließen
        return (prefs.getString('chat_ec_file_${g.id}') ?? '').isEmpty;
      }
      return g.defaultEncryptionType == message_model.EncryptionType.rsa ||
          g.defaultEncryptionType == message_model.EncryptionType.hybrid;
    }).toList();

    String mode;
    if (targetGroup != null) {
      mode = 'existing';
    } else if ((encType == message_model.EncryptionType.rsa ||
                encType == message_model.EncryptionType.hybrid) &&
               selectableGroups.isNotEmpty) {
      // Bei RSA/Hybrid: vorhandenen Chat bevorzugen, falls möglich
      mode = 'existing';
    } else {
      mode = 'new';
    }

    ChatGroup? selectedGroup =
        targetGroup ?? (selectableGroups.isNotEmpty ? selectableGroups.first : null);
    final newNameCtrl = TextEditingController();

    ChatGroup? resultGroup;
    bool shouldCreate = false;
    bool openTransferHub = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('📨 .qgap Datei empfangen'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Datei: $fileName',
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.shield, size: 16, color: Colors.blue),
                        const SizedBox(width: 6),
                        Text('Verschlüsselung: $encLabel',
                            style: const TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Radio<String>(
                        value: 'existing',
                        groupValue: mode,
                        onChanged: (v) => setS(() => mode = v!),
                      ),
                      const Text('Vorhandenem Chat zuweisen'),
                    ],
                  ),
                  if (mode == 'existing') ...[
                    if (selectableGroups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(left: 16),
                        child: Text('Keine passenden Chats vorhanden.',
                            style: TextStyle(color: Colors.red)),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: DropdownButton<ChatGroup>(
                          value: selectedGroup,
                          isExpanded: true,
                            items: selectableGroups
                              .map((g) => DropdownMenuItem(
                                    value: g,
                                    child: Text(g.name,
                                        overflow: TextOverflow.ellipsis),
                                  ))
                              .toList(),
                          onChanged: (v) => setS(() => selectedGroup = v),
                        ),
                      ),
                  ],
                  Row(
                    children: [
                      Radio<String>(
                        value: 'new',
                        groupValue: mode,
                        onChanged: (v) => setS(() => mode = v!),
                      ),
                      const Text('Neuen Chat anlegen'),
                    ],
                  ),
                  Row(
                    children: [
                      Radio<String>(
                        value: 'transfer',
                        groupValue: mode,
                        onChanged: (v) => setS(() => mode = v!),
                      ),
                      const Expanded(
                        child: Text('📡 Transfer-Hub (per QR an anderes Gerät)'),
                      ),
                    ],
                  ),
                  if (mode == 'new') ...[
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextField(
                        controller: newNameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Chat-Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (encType == message_model.EncryptionType.oneTimePad)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: Colors.orange.shade200),
                              ),
                              child: const Row(
                                children: [
                                  Icon(Icons.warning_amber, color: Colors.orange, size: 16),
                                  SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '⚠️ .qgap Schlüsseldatei muss noch '
                                      'per USB zugewiesen werden.',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                _showCreateRandomFileDialog();
                              },
                              icon: const Icon(Icons.folder_special, color: Colors.green, size: 18),
                              label: const Text('📁 Zufallsdatei erstellen'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () {
                  if (mode == 'existing') {
                    resultGroup = selectedGroup;
                    shouldCreate = false;
                  } else if (mode == 'new') {
                    shouldCreate = true;
                  } else if (mode == 'transfer') {
                    openTransferHub = true;
                  }
                  Navigator.of(ctx).pop();
                },
                child: const Text('Öffnen'),
              ),
            ],
          );
        });
      },
    );

    if (!mounted) return;

    if (!shouldCreate && resultGroup != null) {
      // chat_key_ persistieren für künftige Auto-Erkennung
      if (keyFileName != null && encType == message_model.EncryptionType.oneTimePad) {
        final existing = prefs.getString('chat_key_${resultGroup!.id}');
        if (existing == null || existing.isEmpty) {
          await prefs.setString('chat_key_${resultGroup!.id}', keyFileName);
        }
      }
      // Vorhandenen Chat öffnen
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: resultGroup!.name,
            chatGroupId: resultGroup!.id,
            encryptionType: resultGroup!.defaultEncryptionType,
            pendingScannedData: scannedData,
            pendingMetadata: metadata,
          ),
        ),
      ).then((_) => _loadChatGroups());
    } else if (shouldCreate) {
      // Neuen Chat anlegen
      final chatName = newNameCtrl.text.trim();
      if (chatName.isEmpty) return;

      final newGroup = ChatGroup(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: chatName,
        description: '',
        createdAt: DateTime.now(),
        iconEmoji: encType == message_model.EncryptionType.hybrid ? '🔑' : '💬',
        defaultEncryptionType: encType,
      );

      // OTP: Schlüsseldatei-Zuweisung und ⚠️-Flag setzen
      if (keyFileName != null && encType == message_model.EncryptionType.oneTimePad) {
        await prefs.setString('chat_key_${newGroup.id}', keyFileName);
        await prefs.setBool('chat_needs_QGAP_key_${newGroup.id}', true);
      }

      final groupsJson = List<String>.from(
          prefs.getStringList('chat_groups') ?? []);
      groupsJson.add(json.encode(newGroup.toJson()));
      await prefs.setStringList('chat_groups', groupsJson);
      await _loadChatGroups();

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ChatScreen(
            chatGroupName: newGroup.name,
            chatGroupId: newGroup.id,
            encryptionType: newGroup.defaultEncryptionType,
            pendingScannedData: scannedData,
            pendingMetadata: metadata,
          ),
        ),
      ).then((_) => _loadChatGroups());
    } else if (openTransferHub && scannedData != null) {
      // Transfer-Hub öffnen mit der empfangenen .qgap-Datei als vorgeladenen Eintrag
      final entry = SavedQrEntry(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: fileName,
        content: scannedData,
        category: QrCategory.qgap,
        savedAt: DateTime.now(),
      );
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => TransferScreen(pendingEntry: entry),
        ),
      );
    }
  }

  /// Startet einen Hintergrund-Listener für eingehende Firestore-Transfers.
  /// Verarbeitet ausschließlich Relay-Pairing-ACKs und B→A-Relay-Nachrichten.
  /// Reguläre Transfers (Dateien, Einladungen) werden vom TransferScreen behandelt.
  /// Wartet auf Auth-Login und startet dann den Transfer-Listener.
  /// Wird bei jedem Auth-State-Wechsel (Login/Logout) reaktiv ausgeführt.
  void _startHomeTransferListener() {
    _authStateSub?.cancel();
    _authStateSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user == null) {
        _homeTransferSub?.cancel();
        _homeTransferSub = null;
        return;
      }
      _startHomeTransferListenerInternal();
    });
  }

  void _startHomeTransferListenerInternal() {
    _homeTransferSub?.cancel();
    final uid = AuthService.currentUid;
    print('QGAP_RELAY: _startHomeTransferListenerInternal uid=$uid');
    if (uid == null) {
      print('QGAP_RELAY: UID noch null – kein Listener gestartet');
      return;
    }
    try {
      _homeTransferSub = FirestoreService().incomingTransfersStream().listen(
        (snap) async {
          print('QGAP_RELAY: Transfer-Stream-Event: ${snap.docChanges.length} Changes');
          for (final change in snap.docChanges) {
            if (change.type != DocumentChangeType.added) continue;
            final doc = change.doc;
            if (_homeProcessedTransferIds.contains(doc.id)) continue;
            final data = doc.data();
            if (data == null) continue;
            final payloadType =
                _normalizeLegacyType(data['payloadType'] as String?);
            print('QGAP_RELAY: Eingehender Transfer id=${doc.id} payloadType=$payloadType');
            // Nur Relay-spezifische Payloads hier verarbeiten
            if (payloadType == FirestoreService.kPayloadTypeRelayPairAck) {
              _homeProcessedTransferIds.add(doc.id);
              print('QGAP_RELAY: ACK empfangen id=${doc.id}');
              try {
                final cipherB64 = (data['cipher'] as String?) ?? '';
                final rawBytes = base64.decode(cipherB64);
                final ackJson = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
                final ackChatGroupId  = ackJson['chatGroupId']    as String?;
                final ackSenderUid    = ackJson['senderUid']      as String?;
                final ackFirestoreId  = ackJson['firestoreChatId'] as String?;
                print('QGAP_RELAY: ACK chatGroupId=$ackChatGroupId senderUid=$ackSenderUid');
                if (ackChatGroupId != null && ackSenderUid != null) {
                  await _handleRelayPairAck(
                    chatGroupId: ackChatGroupId,
                    senderUid: ackSenderUid,
                    firestoreChatId: ackFirestoreId,
                  );
                }
              } catch (e) {
                print('QGAP_RELAY: ⚠️ ACK-Verarbeitung fehlgeschlagen: $e');
              }
              try { await FirestoreService().deleteTransfer(doc.id); } catch (_) {}
            }
          }
        },
        onError: (e) {
          print('QGAP_RELAY: ❌ Transfer-Stream-Fehler: $e – starte neu in 5s');
          // Auto-Reconnect nach Fehler
          Future.delayed(const Duration(seconds: 5), () {
            if (mounted && AuthService.currentUid != null) {
              _startHomeTransferListenerInternal();
            }
          });
        },
      );
      print('QGAP_RELAY: ✅ HomeScreen Transfer-Listener gestartet für uid=$uid');
    } catch (e) {
      print('QGAP_RELAY: ❌ Transfer-Listener Start fehlgeschlagen: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Beim Zurückkehren aus dem Hintergrund: Ungelesen-Zähler + Chat-Liste
    // neu laden, da wir keinen Timer/Live-Reload für offline-lokale Chats haben.
    if (state == AppLifecycleState.resumed && mounted) {
      _loadChatGroups();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authStateSub?.cancel();
    _homeTransferSub?.cancel();
    for (final sub in _unreadMsgSubs.values) {
      sub.cancel();
    }
    _unreadMsgSubs.clear();
    _groupNameController.dispose();
    _groupDescriptionController.dispose();
    _scrollController.dispose();
    _descriptionFocusNode.dispose();
    _editNameFocusNode.dispose();
    _editDescriptionFocusNode.dispose();
    _chatSearchController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────────────────────────────
  // Passwort-Sicherheit: SHA-256 Hashing (OWASP M4)
  // ─────────────────────────────────────────────────────────────

  /// Erzeugt einen SHA-256 Hash des Passworts.
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Vergleicht ein eingegebenes Passwort mit dem gespeicherten Hash.
  bool _verifyPassword(String input, String storedHash) {
    return _hashPassword(input) == storedHash;
  }
  Future<void> _loadChatGroups() async {
    try {
      developer.log('log: Starte Laden der Chat-Gruppen', name: '_loadChatGroups');
      
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = prefs.getStringList('chat_groups') ?? [];
      
      List<ChatGroup> loadedGroups = [];
      bool needsMigration = false;

      // Lade jede Gruppe einzeln mit Fehlerbehandlung
      for (String groupJson in groupsJson) {
        try {
          ChatGroup group = ChatGroup.fromJson(json.decode(groupJson));
          // Migration: alte Relay-Chats die noch als 'hybrid' gespeichert sind
          // → auf relayForward upgraden (relay_ prefix + hybrid = Relay-Phone-Chat)
          if (group.firestoreChatId?.startsWith('relay_') == true &&
              group.defaultEncryptionType == message_model.EncryptionType.hybrid) {
            group = group.copyWith(
              defaultEncryptionType: message_model.EncryptionType.relayForward,
            );
            needsMigration = true;
          }
          loadedGroups.add(group);
        } catch (e) {
          developer.log('log: Fehler beim Laden einer Chat-Gruppe: $e', name: '_loadChatGroups');
          // Überspringe defekte Gruppen
        }
      }
      
      if (mounted) {
        setState(() {
          chatGroups = loadedGroups;
        });

        // Migration persistieren (relay-Chats hybrid→relayForward)
        if (needsMigration) {
          final migratedJson = loadedGroups.map((g) => json.encode(g.toJson())).toList();
          await prefs.setStringList('chat_groups', migratedJson);
        }

        developer.log('log: ${chatGroups.length} Chat-Gruppen erfolgreich geladen', name: '_loadChatGroups');
        
        // Verwaiste Zuordnungen (chat_ec_file_*, chat_key_*, chat_ec_usb_only_*)
        // für nicht mehr existierende Chats bereinigen, damit EC-Dateien
        // wieder anderen Chats zugeordnet werden können.
        await _cleanupOrphanedChatPrefs();

        // Lade die letzten Nachrichtenzeiten für alle Gruppen
        await _loadLastMessageTimes();
        // Lade ⚠️-Flags (OTP-Schlüsseldatei fehlt)
        await _loadChatNeedsKeyFlags(loadedGroups);
        // Lade Ungelesen-Zähler
        await _loadUnreadCounts();
      }
      
    } catch (e) {
      developer.log('log: Kritischer Fehler beim Laden der Chat-Gruppen: $e', name: '_loadChatGroups');
      
      // Fallback: Leere Liste setzen
      if (mounted) {
        setState(() {
          chatGroups = [];
        });
      }
    }
  }

  // Lädt die Zeitstempel der letzten Nachrichten für alle Chat-Gruppen,
  // baut den Such-Index auf und sortiert die Chat-Liste (neueste zuerst).
  Future<void> _loadLastMessageTimes() async {
    try {
      developer.log('log: Starte Laden der letzten Nachrichtenzeiten', name: '_loadLastMessageTimes');
      
      final prefs = await SharedPreferences.getInstance();
      Map<String, DateTime?> tempLastMessageTimes = {};
      Map<String, String> tempSearchIndex = {};
      
      for (ChatGroup group in chatGroups) {
        try {
          final messagesKey = 'messages_${group.id}';
          final messagesJson = prefs.getStringList(messagesKey) ?? [];
          
          DateTime? lastMessageTime;
          final searchBuf = StringBuffer()
            ..write(group.name.toLowerCase())
            ..write(' ')
            ..write(group.description.toLowerCase());

          for (final msgJson in messagesJson) {
            try {
              final messageData = json.decode(msgJson) as Map<String, dynamic>;
              final ts = messageData['timestamp'];
              final msgTime = ts is int
                  ? DateTime.fromMillisecondsSinceEpoch(ts)
                  : DateTime.tryParse(ts?.toString() ?? '');
              if (msgTime != null &&
                  (lastMessageTime == null || msgTime.isAfter(lastMessageTime))) {
                lastMessageTime = msgTime;
              }
              final originalText = messageData['originalText'] as String?;
              if (originalText != null && originalText.isNotEmpty) {
                searchBuf.write(' ');
                searchBuf.write(originalText.toLowerCase());
              }
            } catch (e) {
              developer.log('log: Fehler beim Laden einer Nachricht für Gruppe ${group.name}: $e', name: '_loadLastMessageTimes');
            }
          }

          tempLastMessageTimes[group.id] = lastMessageTime;
          tempSearchIndex[group.id] = searchBuf.toString();
        } catch (e) {
          developer.log('log: Fehler beim Laden der Nachrichten für Gruppe ${group.id}: $e', name: '_loadLastMessageTimes');
          tempLastMessageTimes[group.id] = null;
        }
      }

      // Neueste Nachricht zuerst; ohne Nachrichten fällt auf Erstellungsdatum
      // zurück, damit neu angelegte Chats nicht ganz unten verschwinden.
      DateTime effectiveTime(ChatGroup g) =>
          tempLastMessageTimes[g.id] ?? g.createdAt;
      chatGroups.sort((a, b) => effectiveTime(b).compareTo(effectiveTime(a)));
      
      if (mounted) {
        setState(() {
          lastMessageTimes = tempLastMessageTimes;
          _chatSearchIndex = tempSearchIndex;
        });
        
        developer.log('log: Letzte Nachrichtenzeiten für ${lastMessageTimes.length} Gruppen erfolgreich geladen', name: '_loadLastMessageTimes');
      }
      
    } catch (e) {
      developer.log('log: Kritischer Fehler beim Laden der letzten Nachrichtenzeiten: $e', name: '_loadLastMessageTimes');
      
      // Fallback: Leere Map setzen
      if (mounted) {
        setState(() {
          lastMessageTimes = {};
        });
      }
    }
  }


  /// Lädt Ungelesen-Zähler für alle Chats (Nachrichten nach letztem Öffnen).
  Future<void> _loadUnreadCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, int> counts = {};
      for (final group in chatGroups) {
        final lastSeen = prefs.getInt('last_seen_${group.id}') ?? 0;
        _lastSeenMillisCache[group.id] = lastSeen;
        final messagesJson = prefs.getStringList('messages_${group.id}') ?? [];
        int unread = 0;
        for (final msgJson in messagesJson) {
          try {
            final msgData = json.decode(msgJson) as Map<String, dynamic>;
            final timestamp = msgData['timestamp'] as int? ?? 0;
            final isMe = msgData['isMe'] as bool? ?? true;
            if (!isMe && timestamp > lastSeen) unread++;
          } catch (_) {}
        }
        counts[group.id] = unread;
      }
      if (mounted) {
        setState(() => _unreadCounts = counts);
      }
      // Live-Listener für Online-Chats starten/aufräumen (reagiert auch,
      // während die App im Hintergrund/auf dem Home-Screen ist).
      _syncUnreadListeners();
    } catch (e) {
      developer.log('log: Fehler beim Laden der Ungelesen-Zähler: $e', name: '_loadUnreadCounts');
    }
  }

  /// Startet für jeden Online-Chat einen Firestore-Live-Listener, der den
  /// Ungelesen-Zähler ohne Navigation/Reload aktuell hält, und räumt
  /// Listener für nicht mehr vorhandene Chats auf.
  void _syncUnreadListeners() {
    final onlineIds = <String>{};
    for (final group in chatGroups) {
      if (!group.isOnlineEnabled || group.firestoreChatId == null) continue;
      onlineIds.add(group.id);
      if (_unreadMsgSubs.containsKey(group.id)) continue;
      try {
        _unreadMsgSubs[group.id] = FirestoreService()
            .messagesStream(group.firestoreChatId!, pageSize: 200)
            .listen(
          (snap) => _handleUnreadSnapshot(group, snap),
          onError: (e) => developer.log(
              'log: Unread-Listener Fehler (${group.id}): $e',
              name: '_syncUnreadListeners'),
        );
      } catch (e) {
        developer.log('log: Unread-Listener Start fehlgeschlagen (${group.id}): $e',
            name: '_syncUnreadListeners');
      }
    }
    final staleIds =
        _unreadMsgSubs.keys.where((id) => !onlineIds.contains(id)).toList();
    for (final id in staleIds) {
      _unreadMsgSubs.remove(id)?.cancel();
      _liveUnreadKnown.remove(id);
    }
  }

  /// Berechnet den Ungelesen-Zähler eines Online-Chats aus einem
  /// Firestore-Snapshot (ohne Entschlüsselung — nur senderId/timestamp/type)
  /// und benachrichtigt bei Anstieg, wenn die App im Hintergrund ist.
  void _handleUnreadSnapshot(
      ChatGroup group, QuerySnapshot<Map<String, dynamic>> snap) {
    final myUid = AuthService.currentUid;
    final lastSeen = _lastSeenMillisCache[group.id] ?? 0;
    int unread = 0;
    for (final doc in snap.docs) {
      final data = doc.data();
      final ts = data['timestamp'];
      final msgMillis = ts is Timestamp ? ts.millisecondsSinceEpoch : 0;
      if (data['type'] == 'handshake') continue;
      if (data['senderId'] == myUid) continue;
      if (msgMillis > lastSeen) unread++;
    }
    if (!mounted) return;
    setState(() => _unreadCounts[group.id] = unread);

    final knownBefore = _liveUnreadKnown[group.id] ?? unread;
    _liveUnreadKnown[group.id] = unread;
    if (unread > knownBefore && NotificationService.enabled) {
      final appState = WidgetsBinding.instance.lifecycleState;
      final isBackground = appState == AppLifecycleState.paused ||
          appState == AppLifecycleState.inactive ||
          appState == AppLifecycleState.hidden;
      if (isBackground) {
        NotificationService().showNewMessagesNotification(
          chatGroupId: group.id,
          count: unread,
        );
      }
    }
  }

  /// Markiert einen Chat als gelesen (setzt last_seen auf jetzt, Zähler → 0).
  Future<void> _markChatAsSeen(String chatGroupId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt('last_seen_$chatGroupId', now);
      _lastSeenMillisCache[chatGroupId] = now;
      _liveUnreadKnown[chatGroupId] = 0;
      if (mounted) {
        setState(() => _unreadCounts[chatGroupId] = 0);
      }
    } catch (e) {
      developer.log('log: Fehler beim Markieren als gelesen: $e', name: '_markChatAsSeen');
    }
  }

  // Lädt ⚠️-Flags: Welche Chats brauchen noch eine OTP-Schlüsseldatei?
  Future<void> _loadChatNeedsKeyFlags(List<ChatGroup> groups) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, bool> flags = {};
      final Map<String, String?> contactNames = {};
      final Map<String, bool> ecUsbFlags = {};
      for (final g in groups) {
        flags[g.id] = prefs.getBool('chat_needs_QGAP_key_${g.id}') ?? false;
        contactNames[g.id] = prefs.getString('chat_contact_${g.id}');
        ecUsbFlags[g.id] = prefs.getBool('chat_ec_usb_only_${g.id}') ?? false;
      }
      if (mounted) {
        setState(() {
          _chatNeedsKey = flags;
          _chatContactName = contactNames;
          _chatEcUsbOnly = ecUsbFlags;
        });
      }
    } catch (e) {
      developer.log('log: Fehler beim Laden der NeedsKey-Flags: $e', name: '_loadChatNeedsKeyFlags');
    }
  }

  // Formatiert DateTime für die Anzeige
  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    if (difference.inDays > 0) {
      return '${dateTime.day}.${dateTime.month}.${dateTime.year}';
    } else if (difference.inHours > 0) {
      return 'vor ${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return 'vor ${difference.inMinutes}min';
    } else {
      return 'gerade eben';
    }
  }

  // Speichert die Chat-Gruppen in SharedPreferences
  Future<void> _saveChatGroups() async {
    final prefs = await SharedPreferences.getInstance();
    final groupsJson = chatGroups.map((group) {
      return json.encode(group.toJson());
    }).toList();
    
    await prefs.setStringList('chat_groups', groupsJson);
    developer.log('log: ${chatGroups.length} Chat-Gruppen gespeichert', name: '_saveChatGroups');
    
    // Aktualisiere die letzten Nachrichtenzeiten nach dem Speichern
    _loadLastMessageTimes();
  }

  // Erstellt eine neue Chat-Gruppe
  void _createChatGroup() {
    message_model.EncryptionType selectedEncryption = message_model.EncryptionType.oneTimePad;
    String? assignedKeyFile; // Schlüsseldatei die per Zufallsdatei-Dialog zugewiesen wurde
    String? importedContactNameForNewChat; // Kontaktschlüssel für RSA/Hybrid-Chats
    bool isOnlineChatSelected = false; // Online-Chat (Firestore) oder Offline-Chat
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              alignment: Alignment.topCenter, // Dialog oben positionieren
              insetPadding: const EdgeInsets.only(
                top: 40,  // Weniger Abstand von oben
                left: 20,
                right: 20,
                bottom: 40,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Titel
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(28),
                          topRight: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.add_circle, color: Colors.blue.shade700),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'Chat-Gruppe erstellen',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Scrollbarer Inhalt
                    Flexible(
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Emoji-Auswahl
                            const Text(
                              'Icon auswählen:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              height: 120,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 6,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                                itemCount: availableEmojis.length,
                                itemBuilder: (context, index) {
                                  final emoji = availableEmojis[index];
                                  final isSelected = emoji == _selectedEmoji;
                                  return GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        _selectedEmoji = emoji;
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSelected ? Colors.blue.shade100 : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                        border: isSelected 
                                          ? Border.all(color: Colors.blue, width: 2)
                                          : Border.all(color: Colors.grey.shade300),
                                      ),
                                      child: Center(
                                        child: Text(
                                          emoji,
                                          style: const TextStyle(fontSize: 20),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 24),
                            
                            // Gruppen-Name
                            TextField(
                              controller: _groupNameController,
                              decoration: const InputDecoration(
                                labelText: 'Gruppen-Name',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.group),
                              ),
                              maxLength: 30,
                            ),
                            const SizedBox(height: 16),
                            
                            // Beschreibung
                            TextField(
                              controller: _groupDescriptionController,
                              focusNode: _descriptionFocusNode,
                              decoration: const InputDecoration(
                                labelText: 'Beschreibung (optional)',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.description),
                              ),
                              maxLength: 100,
                              maxLines: 3,
                            ),
                            const SizedBox(height: 16),
                            
                            // Verschlüsselungstyp-Auswahl
                            const Text(
                              'Verschlüsselungstyp:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<message_model.EncryptionType>(
                              value: selectedEncryption,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.security),
                              ),
                              // Nur One-Time-Pad und Hybrid anbieten
                              items: <message_model.EncryptionType>[
                                message_model.EncryptionType.oneTimePad,
                                message_model.EncryptionType.hybrid,
                                if (selectedEncryption == message_model.EncryptionType.relayForward)
                                  message_model.EncryptionType.relayForward,
                              ].map((type) {
                                String displayName;
                                String description;
                                Color color;
                                IconData icon;
                                switch (type) {
                                  case message_model.EncryptionType.oneTimePad:
                                    displayName = 'One-Time-Pad';
                                    description = 'Perfekte Sicherheit mit .qgap-Dateien';
                                    color = Colors.green;
                                    icon = Icons.shield;
                                    break;
                                  case message_model.EncryptionType.hybrid:
                                    displayName = 'Hybrid';
                                    description = 'RSA + AES (empfohlen)';
                                    color = Colors.orange;
                                    icon = Icons.auto_awesome;
                                    break;
                                  case message_model.EncryptionType.relayForward:
                                    displayName = 'ohne (Relais-Chat)';
                                    description = 'Weiterleitung ohne eigene Verschlüsselung';
                                    color = Colors.indigo;
                                    icon = Icons.compare_arrows;
                                    break;
                                  default:
                                    displayName = type.toString();
                                    description = '';
                                    color = Colors.grey;
                                    icon = Icons.security;
                                }
                                return DropdownMenuItem(
                                  value: type,
                                  child: Row(
                                    children: [
                                      Icon(icon, color: color, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              displayName,
                                              style: const TextStyle(fontWeight: FontWeight.bold),
                                            ),
                                            if (description.isNotEmpty)
                                              Text(
                                                description,
                                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setDialogState(() {
                                  selectedEncryption = value!;
                                });
                              },
                            ),
                            if ((selectedEncryption == message_model.EncryptionType.rsa ||
                                selectedEncryption == message_model.EncryptionType.hybrid) &&
                                !_rsaKeysInitialized)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.error, color: Colors.red.shade700, size: 20),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'RSA-Schlüssel sind nicht initialisiert. Bitte initialisieren Sie RSA-Schlüssel über das Menü.',
                                        style: TextStyle(fontSize: 12, color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            if (selectedEncryption == message_model.EncryptionType.oneTimePad)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    TextButton.icon(
                                      onPressed: () {
                                        _showCreateRandomFileDialog(
                                          onFileCreated: (fileName) {
                                            setDialogState(() {
                                              assignedKeyFile = fileName;
                                            });
                                          },
                                        );
                                      },
                                      icon: const Icon(Icons.folder_special, color: Colors.green),
                                      label: const Text('📁 Zufallsdatei erstellen'),
                                      style: TextButton.styleFrom(
                                        alignment: Alignment.centerLeft,
                                      ),
                                    ),
                                    if (assignedKeyFile != null)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4, bottom: 4),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.check_circle, color: Colors.green, size: 16),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                '✅ Zugewiesen: $assignedKeyFile',
                                                style: const TextStyle(fontSize: 12, color: Colors.green),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            // Kontakt-Schlüssel-Import für Hybrid/RSA
                            if (selectedEncryption == message_model.EncryptionType.hybrid ||
                                selectedEncryption == message_model.EncryptionType.rsa)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Kontakt-Schlüssel importieren:',
                                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () async {
                                              final receivedBytes = await Navigator.of(context).push<Uint8List>(
                                                MaterialPageRoute(builder: (_) => const QrDataReceiver()),
                                              );
                                              if (receivedBytes == null || !mounted) return;
                                              try {
                                                final decoded = utf8.decode(receivedBytes);
                                                final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(decoded);
                                                if (publicKey == null) {
                                                  showQgapSnackBar(context, const SnackBar(
                                                    content: Text('❌ Ungültiger QR-Code'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                  return;
                                                }
                                                final nameCtrl = TextEditingController();
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
                                                final usedByQr = await ContactUtils.findChatUsingContact(contactName);
                                                if (usedByQr != null) {
                                                  if (!mounted) return;
                                                  showQgapSnackBar(context, SnackBar(
                                                    content: Text('❌ Kontakt "$contactName" ist bereits dem Chat "$usedByQr" zugeordnet.'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                  return;
                                                }
                                                await _rsaKeyManager.saveContactPublicKey(contactName, publicKey);
                                                setDialogState(() => importedContactNameForNewChat = contactName);
                                              } catch (e) {
                                                if (mounted) {
                                                  showQgapSnackBar(context, SnackBar(
                                                    content: Text('Fehler: $e'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                }
                                              }
                                            },
                                            icon: const Icon(QgapIcons.qrScan, size: 18),
                                            label: const Text('QR scannen'),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: OutlinedButton.icon(
                                            onPressed: () async {
                                              try {
                                                final result = await FilePicker.platform.pickFiles(
                                                  type: FileType.custom,
                                                  allowedExtensions: ['qgap_aes'],
                                                  withData: true,
                                                );
                                                if (result == null || result.files.isEmpty) return;
                                                final bytes = result.files.first.bytes;
                                                if (bytes == null) return;
                                                final content = utf8.decode(bytes);
                                                final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(content);
                                                if (publicKey == null) {
                                                  if (!mounted) return;
                                                  showQgapSnackBar(context, const SnackBar(
                                                    content: Text('❌ Ungültige .qgap_aes Datei'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                  return;
                                                }
                                                if (!mounted) return;
                                                final nameCtrl = TextEditingController();
                                                final fn = result.files.first.name;
                                                if (fn.startsWith('Public_Key_') && fn.endsWith('.qgap_aes')) {
                                                  nameCtrl.text = fn.replaceFirst('Public_Key_', '').replaceAll('.qgap_aes', '');
                                                }
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
                                                final usedByFile = await ContactUtils.findChatUsingContact(contactName);
                                                if (usedByFile != null) {
                                                  if (!mounted) return;
                                                  showQgapSnackBar(context, SnackBar(
                                                    content: Text('❌ Kontakt "$contactName" ist bereits dem Chat "$usedByFile" zugeordnet.'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                  return;
                                                }
                                                await _rsaKeyManager.saveContactPublicKey(contactName, publicKey);
                                                setDialogState(() => importedContactNameForNewChat = contactName);
                                              } catch (e) {
                                                if (mounted) {
                                                  showQgapSnackBar(context, SnackBar(
                                                    content: Text('Fehler: $e'),
                                                    backgroundColor: Colors.red,
                                                  ));
                                                }
                                              }
                                            },
                                            icon: const Icon(QgapIcons.fileAttach, size: 18),
                                            label: const Text('.qgap_aes'),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (importedContactNameForNewChat != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.check_circle, color: Colors.green, size: 16),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                '✅ Schlüssel von: $importedContactNameForNewChat',
                                                style: const TextStyle(fontSize: 12, color: Colors.green),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            // ── Online / Offline ──────────────────────────
                            const SizedBox(height: 8),
                            const Divider(),
                            SwitchListTile(
                              value: isOnlineChatSelected,
                              onChanged: (v) => setDialogState(() => isOnlineChatSelected = v),
                              title: const Text('Online-Chat (Firestore)'),
                              subtitle: Text(
                                isOnlineChatSelected
                                    ? 'Chat wird über Firebase-Cloud synchronisiert'
                                    : 'Chat ist nur lokal gespeichert (kein Internet nötig)',
                                style: const TextStyle(fontSize: 12),
                              ),
                              secondary: Icon(
                                isOnlineChatSelected ? Icons.cloud : Icons.cloud_off,
                                color: isOnlineChatSelected ? Colors.blue : Colors.grey,
                              ),
                              contentPadding: EdgeInsets.zero,
                            ),
                            if (isOnlineChatSelected && !_deviceRoleOnline)
                              Container(
                                margin: const EdgeInsets.only(top: 4),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.orange.shade300),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.warning_amber, color: Colors.orange.shade700, size: 18),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'Gerät ist nicht als Online-Gerät konfiguriert. '
                                        'Geräterolle bitte in den Einstellungen ändern.',
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            // Extra Platz für Tastatur-Sichtbarkeit
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                    
                    // Buttons
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(28),
                          bottomRight: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              _groupNameController.clear();
                              _groupDescriptionController.clear();
                              _selectedEmoji = '💬';
                              Navigator.of(context).pop();
                            },
                            child: const Text('Abbrechen'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: ((selectedEncryption == message_model.EncryptionType.rsa ||
                                    selectedEncryption == message_model.EncryptionType.hybrid) &&
                                !_rsaKeysInitialized)
                                ? null
                                : () async {
                              final name = _groupNameController.text.trim();
                              if (name.isEmpty) {
                                showQgapSnackBar(context, const SnackBar(
                                  content: Text('⚠️ Bitte einen Chat-Namen eingeben.'),
                                  backgroundColor: Colors.orange,
                                ));
                                return;
                              }
                              final newGroup = ChatGroup(
                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                name: name,
                                description: _groupDescriptionController.text.trim(),
                                createdAt: DateTime.now(),
                                iconEmoji: _selectedEmoji,
                                defaultEncryptionType: selectedEncryption,
                                isOnlineEnabled: isOnlineChatSelected,
                              );
                              
                              setState(() {
                                chatGroups.add(newGroup);
                              });
                              
                              await _saveChatGroups();

                              // OTP: Schlüsseldatei automatisch zuweisen falls erstellt
                              if (selectedEncryption == message_model.EncryptionType.oneTimePad &&
                                  assignedKeyFile != null) {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setString('chat_key_${newGroup.id}', assignedKeyFile!);
                                // Für .qgap_ec zusätzlich die EC-Zuordnung setzen,
                                // damit das Chat-Hamburger-Menü (Export/Reset) sie findet.
                                if (assignedKeyFile!.toLowerCase().endsWith('.qgap_ec')) {
                                  await prefs.setString('chat_ec_file_${newGroup.id}', assignedKeyFile!);
                                }
                                developer.log('log: ✅ Schlüsseldatei "$assignedKeyFile" dem Chat "${newGroup.name}" zugewiesen', name: '_createChatGroup');
                              }
                              
                              // Hybrid/RSA: Kontaktschlüssel-Zuordnung speichern
                              if ((selectedEncryption == message_model.EncryptionType.hybrid ||
                                  selectedEncryption == message_model.EncryptionType.rsa) &&
                                  importedContactNameForNewChat != null) {
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setString('chat_contact_${newGroup.id}', importedContactNameForNewChat!);
                                developer.log('log: ✅ Kontaktschlüssel "$importedContactNameForNewChat" dem Chat "${newGroup.name}" zugewiesen', name: '_createChatGroup');
                              }
                              
                              _groupNameController.clear();
                              _groupDescriptionController.clear();
                              _selectedEmoji = '💬';
                              
                              if (mounted) {
                                // Dialog sofort schließen – Chat ist schon via setState in der Liste
                                Navigator.of(context).pop();
                                showQgapSnackBar(context, SnackBar(
                                  content: Text(
                                    assignedKeyFile != null
                                        ? '✅ Chat "$name" erstellt & "$assignedKeyFile" zugewiesen'
                                        : '✅ Chat "$name" wurde erstellt.',
                                  ),
                                  duration: const Duration(seconds: 3),
                                ));
                              }
                              
                              developer.log('log: Neue Chat-Gruppe erstellt: ${newGroup.name} mit $selectedEncryption', name: '_createChatGroup');
                            },
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                            child: const Text('Erstellen'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Zeigt Informationen über eine Chat-Gruppe an
  void _showChatGroupInfo(ChatGroup group) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Text(group.iconEmoji, style: const TextStyle(fontSize: 24)),
              const SizedBox(width: 8),
              Expanded(child: Text(group.name)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (group.description.isNotEmpty) ...[
                const Text(
                  'Beschreibung:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(group.description),
                const SizedBox(height: 16),
              ],
              // Verschlüsselungstyp anzeigen
              Row(
                children: [
                  Icon(
                    group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                        ? Icons.shield 
                        : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                        ? Icons.vpn_key 
                        : Icons.auto_awesome,
                    size: 16, 
                    color: group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                        ? Colors.green 
                        : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                        ? Colors.blue 
                        : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Verschlüsselung:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                    ? 'One-Time-Pad (Perfekte Sicherheit)'
                    : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                    ? 'RSA (Asymmetrische Verschlüsselung)'
                    : 'Hybrid (RSA + AES)',
                style: TextStyle(
                  color: group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                      ? Colors.green.shade700
                      : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                      ? Colors.blue.shade700
                      : Colors.orange.shade700,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.access_time, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text(
                    'Erstellt:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('${group.createdAt.day}.${group.createdAt.month}.${group.createdAt.year} um ${group.createdAt.hour.toString().padLeft(2, '0')}:${group.createdAt.minute.toString().padLeft(2, '0')} Uhr'),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.key, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text(
                    'Chat-ID:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                group.id,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
              if (lastMessageTimes[group.id] != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.message, size: 16, color: Colors.green),
                    const SizedBox(width: 8),
                    const Text(
                      'Letzte Nachricht:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_formatDateTime(lastMessageTimes[group.id]!)),
              ],
            ],
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

  // Löscht eine Chat-Gruppe
  void _deleteChatGroup(ChatGroup group) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Chat-Gruppe löschen'),
          content: Text('Möchten Sie die Gruppe "${group.name}" wirklich löschen?\n\nAlle Nachrichten gehen dabei verloren.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();

                // Zuordnungen erfassen, bevor wir sie entfernen
                final assignedEcFile = prefs.getString('chat_ec_file_${group.id}');
                final assignedKeyFile = prefs.getString('chat_key_${group.id}');

                // Lösche Nachrichten der Gruppe
                await prefs.remove('messages_${group.id}');

                // Lösche Byte-Position der Gruppe
                final keys = prefs.getKeys();
                for (String key in keys) {
                  if (key.startsWith('usedKeyBytes_${group.id}_')) {
                    await prefs.remove(key);
                  }
                }

                // Zuordnungen (EC/Key) explizit entfernen, damit die Dateien
                // wieder frei für andere Chats werden
                await prefs.remove('chat_ec_file_${group.id}');
                await prefs.remove('chat_key_${group.id}');
                await prefs.remove('chat_ec_usb_only_${group.id}');

                setState(() {
                  chatGroups.remove(group);
                });

                await _saveChatGroups();

                // Verwaiste Zuordnungen (anderer Chats, die nicht mehr existieren)
                // gleich mit aufräumen
                await _cleanupOrphanedChatPrefs();

                if (mounted) {
                  Navigator.of(context).pop();
                }

                developer.log('log: Chat-Gruppe gelöscht: ${group.name}', name: '_deleteChatGroup');

                // Falls dem gelöschten Chat eine .qgap_ec-Datei zugeordnet war,
                // prüfen ob sie noch von einem anderen Chat genutzt wird.
                // Wenn nicht: sicheres Löschen anbieten.
                if (assignedEcFile != null && assignedEcFile.isNotEmpty) {
                  final stillReferenced =
                      await _isEcFileReferencedByAnyChat(assignedEcFile);
                  if (!stillReferenced && mounted) {
                    await _offerSecureDeleteOfEcFile(assignedEcFile);
                  } else {
                    developer.log(
                        'log: EC-Datei "$assignedEcFile" wird noch von anderem Chat genutzt, kein Lösch-Angebot.',
                        name: '_deleteChatGroup');
                  }
                } else if (assignedKeyFile != null && assignedKeyFile.isNotEmpty) {
                  developer.log(
                      'log: Hinweis - Chat hatte (Nicht-EC) Schlüsseldatei "$assignedKeyFile". Bleibt unverändert.',
                      name: '_deleteChatGroup');
                }
              },
              child: const Text('Löschen', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  /// Entfernt SharedPreferences-Einträge `chat_ec_file_<id>`, `chat_key_<id>`
  /// und `chat_ec_usb_only_<id>` für Chat-IDs, die nicht mehr in der Liste
  /// `chat_groups` enthalten sind. Damit werden zugeordnete .qgap_ec-Dateien
  /// wieder für andere Chats verfügbar.
  Future<void> _cleanupOrphanedChatPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = prefs.getStringList('chat_groups') ?? [];
      final existingIds = <String>{};
      for (final gJson in groupsJson) {
        try {
          final data = json.decode(gJson);
          final id = data['id']?.toString();
          if (id != null && id.isNotEmpty) existingIds.add(id);
        } catch (_) {}
      }

      const prefixes = <String>[
        'chat_ec_file_',
        'chat_key_',
        'chat_ec_usb_only_',
        'chat_partner_uid_',
        'chat_ec_code_',
      ];

      int removed = 0;
      for (final key in prefs.getKeys().toList()) {
        for (final p in prefixes) {
          if (key.startsWith(p)) {
            final id = key.substring(p.length);
            if (!existingIds.contains(id)) {
              await prefs.remove(key);
              removed++;
              developer.log(
                  'log: 🧹 Verwaiste Zuordnung entfernt: $key',
                  name: '_cleanupOrphanedChatPrefs');
            }
            break;
          }
        }
      }
      if (removed > 0) {
        developer.log(
            'log: $removed verwaiste Chat-Zuordnungen bereinigt',
            name: '_cleanupOrphanedChatPrefs');
      }
      // Verwaiste Relay-Mappings bereinigen
      final relayRemoved = await RelayMappingService.cleanupOrphaned(existingIds);
      if (relayRemoved > 0) {
        developer.log(
            'log: $relayRemoved verwaiste Relay-Mappings bereinigt',
            name: '_cleanupOrphanedChatPrefs');
      }
    } catch (e) {
      developer.log('log: Fehler beim Aufräumen verwaister Zuordnungen: $e',
          name: '_cleanupOrphanedChatPrefs');
    }
  }

  /// Prüft, ob `fileName` (Wert eines `chat_ec_file_<id>`-Eintrags) noch von
  /// irgendeinem existierenden Chat referenziert wird.
  Future<bool> _isEcFileReferencedByAnyChat(String fileName) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = prefs.getStringList('chat_groups') ?? [];
      final existingIds = <String>{};
      for (final gJson in groupsJson) {
        try {
          final data = json.decode(gJson);
          final id = data['id']?.toString();
          if (id != null && id.isNotEmpty) existingIds.add(id);
        } catch (_) {}
      }
      for (final id in existingIds) {
        final v = prefs.getString('chat_ec_file_$id');
        if (v != null && v == fileName) return true;
      }
      return false;
    } catch (e) {
      developer.log('log: Fehler bei _isEcFileReferencedByAnyChat: $e',
          name: '_isEcFileReferencedByAnyChat');
      return false;
    }
  }

  /// Bietet dem Benutzer an, eine nicht mehr zugeordnete .qgap_ec-Datei
  /// sicher (lokal + auf USB) zu löschen.
  Future<void> _offerSecureDeleteOfEcFile(String fileName) async {
    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('EC-Schlüsseldatei löschen?'),
        content: Text(
          'Die EC-Schlüsseldatei\n\n"$fileName"\n\n'
          'ist keinem anderen Chat mehr zugeordnet.\n\n'
          'Soll sie jetzt sicher (lokal und auf erkannten USB-Speichern) '
          'gelöscht werden?\n\n'
          'Diese Aktion kann nicht rückgängig gemacht werden!',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Nein, freigeben (für andere Chats)'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Sicher löschen',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _secureDeleteEcFileByName(fileName);
  }

  /// Löscht eine .qgap_ec-Datei in allen bekannten Speicherorten
  /// (interner Speicher + dynamisch erkannte USB-Pfade).
  Future<void> _secureDeleteEcFileByName(String fileName) async {
    try {
      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }

      final List<String> localPaths = [
        '${AppStorage.schluesselDir}/',
        '/sdcard/Daten/QGap/schluessel/',
      ];
      final usbPaths = await _getAvailableUSBPaths();
      final List<String> allPaths = [...localPaths];
      for (final usbPath in usbPaths) {
        allPaths.add('$usbPath/Daten/QGap/schluessel/');
      }

      int deleted = 0;
      final List<String> deletedFrom = [];
      for (final path in allPaths) {
        final file = File('$path$fileName');
        try {
          if (await file.exists()) {
            await file.delete();
            deleted++;
            deletedFrom.add(path);
            developer.log('log: ✅ EC-Datei gelöscht: $path$fileName',
                name: '_secureDeleteEcFileByName');
          }
        } catch (e) {
          developer.log(
              'log: ❌ Fehler beim Löschen $path$fileName: $e',
              name: '_secureDeleteEcFileByName');
        }
      }

      if (deleted > 0) {
        _showInfoDialog(
          'Erfolgreich',
          'EC-Schlüsseldatei "$fileName" wurde an $deleted Speicherort(en) gelöscht:\n\n'
          '${deletedFrom.join('\n')}',
        );
      } else {
        _showInfoDialog(
          'Nichts gelöscht',
          'EC-Schlüsseldatei "$fileName" wurde an keinem bekannten Speicherort gefunden.',
        );
      }
    } catch (e) {
      developer.log('log: Fehler in _secureDeleteEcFileByName: $e',
          name: '_secureDeleteEcFileByName');
      _showInfoDialog('Fehler', 'Fehler beim Löschen: $e');
    }
  }

  // Bearbeitet eine Chat-Gruppe
  void _editChatGroup(ChatGroup group) {
    // Controller mit aktuellen Werten initialisieren
    _groupNameController.text = group.name;
    _groupDescriptionController.text = group.description;
    _selectedEmoji = group.iconEmoji;
    message_model.EncryptionType selectedEncryption = group.defaultEncryptionType;
    ChatTransport selectedTransport = group.transport;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // ScrollController für den Dialog
            final dialogScrollController = ScrollController();
            
            // FocusNode-Listener für automatisches Scrollen
            _editNameFocusNode.addListener(() {
              if (_editNameFocusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (dialogScrollController.hasClients) {
                    dialogScrollController.animateTo(
                      0.0, // Nach oben scrollen
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                    );
                  }
                });
              }
            });
            
            _editDescriptionFocusNode.addListener(() {
              if (_editDescriptionFocusNode.hasFocus) {
                Future.delayed(const Duration(milliseconds: 300), () {
                  if (dialogScrollController.hasClients) {
                    dialogScrollController.animateTo(
                      0.0, // Nach oben scrollen
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOut,
                    );
                  }
                });
              }
            });
            
            return Dialog(
              alignment: Alignment.topCenter, // Dialog oben positionieren
              insetPadding: const EdgeInsets.only(
                top: 20,  // Weniger Abstand von oben
                left: 20,
                right: 20,
                bottom: 40,
              ),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.8,
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Titel
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(28),
                          topRight: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.edit, color: Colors.blue.shade700),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Chat-bearbeiten',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    // Scrollbarer Inhalt
                    Flexible(
                      child: SingleChildScrollView(
                        controller: dialogScrollController, // Verwende den Dialog-ScrollController
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Emoji-Auswahl
                            const Text(
                              'Icon auswählen:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              height: 80,
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: GridView.builder(
                                padding: const EdgeInsets.all(8),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 6,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                                itemCount: availableEmojis.length,
                                itemBuilder: (context, index) {
                                  final emoji = availableEmojis[index];
                                  final isSelected = emoji == _selectedEmoji;
                                  return GestureDetector(
                                    onTap: () {
                                      setDialogState(() {
                                        _selectedEmoji = emoji;
                                      });
                                    },
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: isSelected ? Colors.blue.shade100 : Colors.grey.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                        border: isSelected 
                                          ? Border.all(color: Colors.blue, width: 2)
                                          : Border.all(color: Colors.grey.shade300),
                                      ),
                                      child: Center(
                                        child: Text(
                                          emoji,
                                          style: const TextStyle(fontSize: 20),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 24),
                            
                            // Gruppen-Name
                            TextField(
                              controller: _groupNameController,
                              focusNode: _editNameFocusNode,
                              decoration: const InputDecoration(
                                labelText: 'Gruppen-Name',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.group),
                              ),
                              maxLength: 30,
                            ),
                            const SizedBox(height: 16),
                            
                            // Beschreibung
                            TextField(
                              controller: _groupDescriptionController,
                              focusNode: _editDescriptionFocusNode,
                              decoration: const InputDecoration(
                                labelText: 'Beschreibung (optional)',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.description),
                              ),
                              maxLength: 100,
                              maxLines: 3,
                            ),
                            const SizedBox(height: 16),
                            
                            // Verschlüsselungstyp-Auswahl
                            const Text(
                              'Verschlüsselungstyp:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<message_model.EncryptionType>(
                              value: selectedEncryption,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.security),
                              ),
                              items: <message_model.EncryptionType>[
                                message_model.EncryptionType.oneTimePad,
                                message_model.EncryptionType.hybrid,
                                if (selectedEncryption == message_model.EncryptionType.relayForward)
                                  message_model.EncryptionType.relayForward,
                              ].map((type) {
                                String displayName;
                                String description;
                                Color color;
                                IconData icon;
                                switch (type) {
                                  case message_model.EncryptionType.oneTimePad:
                                    displayName = 'One-Time-Pad';
                                    description = 'Perfekte Sicherheit mit .qgap-Dateien';
                                    color = Colors.green;
                                    icon = Icons.shield;
                                    break;
                                  case message_model.EncryptionType.hybrid:
                                    displayName = 'Hybrid';
                                    description = 'RSA + AES (empfohlen)';
                                    color = Colors.orange;
                                    icon = Icons.auto_awesome;
                                    break;
                                  case message_model.EncryptionType.relayForward:
                                    displayName = 'ohne (Relais-Chat)';
                                    description = 'Weiterleitung ohne eigene Verschlüsselung';
                                    color = Colors.indigo;
                                    icon = Icons.compare_arrows;
                                    break;
                                  default:
                                    displayName = type.toString();
                                    description = '';
                                    color = Colors.grey;
                                    icon = Icons.security;
                                }
                                return DropdownMenuItem(
                                  value: type,
                                  child: Row(
                                    children: [
                                      Icon(icon, color: color, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              displayName,
                                              style: const TextStyle(fontWeight: FontWeight.bold),
                                            ),
                                            if (description.isNotEmpty)
                                              Text(
                                                description,
                                                style: const TextStyle(fontSize: 12, color: Colors.grey),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setDialogState(() {
                                  selectedEncryption = value!;
                                });
                              },
                            ),
                            if ((selectedEncryption == message_model.EncryptionType.rsa ||
                                selectedEncryption == message_model.EncryptionType.hybrid) &&
                                !_rsaKeysInitialized)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.red.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.error, color: Colors.red.shade700, size: 20),
                                    const SizedBox(width: 8),
                                    const Expanded(
                                      child: Text(
                                        'RSA-Schlüssel sind nicht initialisiert. Bitte initialisieren Sie RSA-Schlüssel über das Menü.',
                                        style: TextStyle(fontSize: 12, color: Colors.red),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 16),
                            // Transport-Modus
                            const Text(
                              'Transport-Modus:',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<ChatTransport>(
                              value: selectedTransport,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.swap_horiz),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: ChatTransport.online,
                                  child: Text('☁️ Online (Firestore)'),
                                ),
                                DropdownMenuItem(
                                  value: ChatTransport.offline,
                                  child: Text('📴 Offline (lokal)'),
                                ),
                                DropdownMenuItem(
                                  value: ChatTransport.airGap,
                                  child: Text('🛡️ Air-Gap (strikt isoliert)'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                setDialogState(() => selectedTransport = v);
                              },
                            ),
                            // Extra Platz für Tastatur-Sichtbarkeit
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
                    
                    // Buttons
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(28),
                          bottomRight: Radius.circular(28),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () {
                              // Controller zurücksetzen
                              _groupNameController.clear();
                              _groupDescriptionController.clear();
                              _selectedEmoji = '💬';
                              Navigator.of(context).pop();
                            },
                            child: const Text('Abbrechen'),
                          ),
                          const SizedBox(width: 12),
                          ElevatedButton(
                            onPressed: ((selectedEncryption == message_model.EncryptionType.rsa ||
                                    selectedEncryption == message_model.EncryptionType.hybrid) &&
                                !_rsaKeysInitialized)
                                ? null
                                : () async {
                              final name = _groupNameController.text.trim();
                              if (name.isEmpty) {
                                showQgapSnackBar(context, const SnackBar(
                                  content: Text('⚠️ Bitte einen Chat-Namen eingeben.'),
                                  backgroundColor: Colors.orange,
                                ));
                                return;
                              }
                              // Aktualisierte Gruppe erstellen
                              final updatedGroup = group.copyWith(
                                name: name,
                                description: _groupDescriptionController.text.trim(),
                                iconEmoji: _selectedEmoji,
                                defaultEncryptionType: selectedEncryption,
                                transport: selectedTransport,
                              );
                              
                              // Gruppe in der Liste aktualisieren
                              setState(() {
                                final index = chatGroups.indexWhere((g) => g.id == group.id);
                                if (index != -1) {
                                  chatGroups[index] = updatedGroup;
                                }
                              });
                              
                              await _saveChatGroups();
                              
                              // Controller zurücksetzen
                              _groupNameController.clear();
                              _groupDescriptionController.clear();
                              _selectedEmoji = '💬';
                              
                              if (mounted) {
                                Navigator.of(context).pop();
                                await _loadChatGroups();
                              }
                              
                              developer.log('log: Chat-Gruppe bearbeitet: ${updatedGroup.name} mit $selectedEncryption', name: '_editChatGroup');
                            },
                            style: ElevatedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            ),
                            child: const Text('Speichern'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Öffnet eine Chat-Gruppe
  void _openChatGroup(ChatGroup group) {
    _markChatAsSeen(group.id);
    NotificationService().cancelNotificationsForChat(group.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          chatGroupName: group.name,
          chatGroupId: group.id,
          encryptionType: group.defaultEncryptionType,
          firestoreChatId: group.firestoreChatId,
        ),
      ),
    ).then((result) async {
      // Aktualisiere die Gruppen-Liste wenn vom Chat zurückgekehrt wird
      _loadChatGroups();
      // Erneut als gelesen markieren: Nachrichten, die WÄHREND des offenen
      // Chats eintrafen, hat der Nutzer bereits gesehen — sonst erscheint
      // der Ungelesen-Badge sofort wieder, obwohl der Chat gerade offen war.
      await _markChatAsSeen(group.id);
      // Ungelesen-Zähler neu laden (für alle anderen Chats)
      _loadUnreadCounts();
      // Relay-Pairing aus Chat-Menü gestartet
      if (result == 'relay_pairing' && mounted) {
        _showRelayPairingRequestQr(group);
      }
    });
  }

  // ─── Pairing-Status-Banner ─────────────────────────────────────────────────

  /// Lädt den aktuellen Pairing-Status und aktualisiert die UI.
  Future<void> _loadPairingStatus() async {
    if (_deviceRole == DeviceRole.standalone) {
      if (mounted) {
        setState(() {
          _pairingCompleteness = PairingCompleteness.none;
          _pairingPartnerName  = null;
        });
      }
      return;
    }
    final completeness = await PairingService.getCompleteness();
    final name = completeness == PairingCompleteness.complete
        ? await PairingService.getPartnerDisplayName()
        : null;
    if (mounted) {
      setState(() {
        _pairingCompleteness = completeness;
        _pairingPartnerName  = name;
      });
    }
  }

  /// Öffnet den QR-Receiver und wendet das gescannte Pairing-Payload sofort an.
  Future<void> _scanAndApplyPartnerPairingQr() async {
    if (!mounted) return;
    final bytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const QrDataReceiver()),
    );
    if (bytes == null || !mounted) return;
    try {
      final text = utf8.decode(bytes);
      final parsed = jsonDecode(text) as Map<String, dynamic>?;
      if (parsed == null ||
          _normalizeLegacyType(parsed['kind'] as String?) != 'qgap_pair' ||
          parsed['modulus'] == null) {
        showQgapSnackBar(context,
            const SnackBar(content: Text('❌ Kein gültiger Pairing-QR-Code')));
        return;
      }
      await _applyScannedPairingPayload(parsed);
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, SnackBar(content: Text('Fehler: $e')));
      }
    }
  }

  /// Zeigt einen farbigen Banner mit dem aktuellen Pairing-Status.
  /// Sichtbar nur wenn Geräterolle ≠ Standalone.
  Widget _buildPairingStatusBanner() {
    final Color bgColor;
    final Color borderColor;
    final IconData iconData;
    final Color iconColor;
    final String title;
    final String subtitle;
    final String? actionLabel;
    final VoidCallback? onAction;

    switch (_pairingCompleteness) {
      case PairingCompleteness.none:
        bgColor     = Colors.orange.shade50;
        borderColor = Colors.orange.shade300;
        iconData    = Icons.link_off;
        iconColor   = Colors.orange.shade700;
        title       = '⚠️ Kein Pairing aktiv';
        subtitle    = 'Bitte Pairing mit dem '
            '${_deviceRole == DeviceRole.airGap ? 'Online-Relay' : 'Air-Gap-Gerät'}'
            ' einrichten.';
        actionLabel = 'Einrichten';
        onAction    = () async {
          await _showPairingDialog();
          await _loadPairingStatus();
        };
        break;
      case PairingCompleteness.sentOnly:
        bgColor     = Colors.amber.shade50;
        borderColor = Colors.amber.shade400;
        iconData    = Icons.qr_code_scanner;
        iconColor   = Colors.amber.shade800;
        title       = '🔄 Pairing unvollständig';
        subtitle    = 'Eigene Daten gesendet – jetzt QR-Code des Partners scannen.';
        actionLabel = 'Partner-QR scannen';
        onAction    = () async {
          await _scanAndApplyPartnerPairingQr();
          await _loadPairingStatus();
        };
        break;
      case PairingCompleteness.complete:
        bgColor     = Colors.green.shade50;
        borderColor = Colors.green.shade300;
        iconData    = Icons.verified;
        iconColor   = Colors.green.shade700;
        title       = '✅ Pairing aktiv';
        subtitle    = 'Verbunden mit „${_pairingPartnerName ?? '(unbekannt)'}".';
        actionLabel = null;
        onAction    = null;
        break;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: borderColor, width: 1.5),
      ),
      color: bgColor,
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(iconData, color: iconColor, size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade700)),
                ],
              ),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(actionLabel,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: iconColor)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ─── Transfer-Hub Kachel (fest eingepinnt, erster Eintrag) ────────────────

  Widget _buildTransferHubTile() {
    // ⚠️ Badge anzeigen wenn mind. 1 Chat einen fehlenden Key hat
    final anyNeedsKey = _chatNeedsKey.values.any((v) => v);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TransferScreen()),
          );
          // Flags nach Rückkehr neu laden (neuer Chat könnte angelegt worden sein)
          _loadChatGroups();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            children: [
              // Avatar mit optionalem ⚠️ Badge
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.teal.shade100,
                    radius: 24,
                    child: const Text('📡', style: TextStyle(fontSize: 22)),
                  ),
                  if (anyNeedsKey)
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: const BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.warning_amber,
                          color: Colors.white,
                          size: 12,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Transfer-Hub',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Colors.teal,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'QR-Codes senden/empfangen · Dateien teilen · QR-Galerie',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                    ),
                    if (anyNeedsKey) ...[
                      const SizedBox(height: 4),
                      const Text(
                        '⚠️ Mindestens ein Chat braucht noch eine Schlüsseldatei',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.orange,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.teal),
            ],
          ),
        ),
      ),
    );
  }

  // Zeigt die Einstellungen
  void _showSettings() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('⚙️ Einstellungen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Hier können Sie zufällige .qgap Dateien für die Verschlüsselung erstellen und die App-Sicherheit verwalten.'),
              const SizedBox(height: 16),
              const Text(
                'Geräterolle:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showDeviceRoleDialog();
                },
                icon: const Icon(Icons.devices, size: 20, color: Colors.teal),
                label: const Text('🔄 Geräterolle konfigurieren'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sicherheitseinstellungen:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showPasswordSettingsDialog();
                },
                icon: const Icon(Icons.lock, size: 20),
                label: const Text('🔐 App-Passwort verwalten'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Systeminfo:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showConnectionInfoDialog();
                },
                icon: const Icon(Icons.wifi, size: 20),
                label: const Text('🌐 Internetverbindung prüfen'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
              // USB-Speicher-Test
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showUSBDebugInfo();
                },
                icon: const Icon(Icons.usb, color: Colors.blue, size: 20),
                label: const Text('🔍 USB-Speicher Debug'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Schlüsseldatei-Verwaltung:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (mounted) await _showKeyFileManagementDialog();
                },
                icon: const Icon(Icons.storage, size: 20),
                label: const Text('💾 EC-Schlüsseldateien verwalten'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await Future.delayed(const Duration(milliseconds: 100));
                  if (mounted) await _showEcCodeLengthDialog();
                },
                icon: const Icon(Icons.shuffle, size: 20),
                label: const Text('Zeichen-Länge'),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _showCreateRandomFileDialog();
              },
              child: const Text('📁 Zufallsdatei erstellen'),
            ),
          ],
        );
      },
    );
  }

  // Dialog zur Konfiguration der Geräterolle (Offline / Online / Beides)
  // ─── Geräterolle ─────────────────────────────────────────────────────────

  /// Lädt Offline/Online-Rolle aus SharedPreferences und aktualisiert UI.
  Future<void> _loadDeviceRole() async {
    final role = await DeviceRoleService.get();
    if (!mounted) return;
    setState(() {
      _deviceRole = role;
      _deviceRoleOffline = role == DeviceRole.airGap;
      _deviceRoleOnline =
          role == DeviceRole.standalone || role == DeviceRole.onlineRelay;
    });
  }

  /// Prüft beim Start ob das Offline-Gerät aktive Verbindungen hat.
  /// Zeigt ggf. Sicherheitswarnung mit Auflistung der aktiven Verbindungen.
  Future<void> _checkOfflineConnections() async {
    if (!_deviceRoleOffline) return; // Nur für Offline-Geräte relevant

    try {
      const channel = MethodChannel('de.paulporg.obmc/connectivity_check');
      final raw = await channel.invokeMethod<Map<Object?, Object?>>('checkDataConnections');
      if (raw == null || !mounted) return;

      final connections = raw.map((k, v) => MapEntry(k.toString(), (v as bool?) ?? false));
      final active = connections.entries.where((e) => e.value).map((e) => e.key).toList();

      if (active.isNotEmpty && mounted) {
        // Kurze Verzögerung damit das UI fertig aufgebaut ist
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) _showActiveConnectionsWarning(active);
      }
    } catch (e) {
      developer.log('log: Verbindungsprüfung fehlgeschlagen: $e',
          name: '_checkOfflineConnections');
    }
  }

  /// Sicherheitswarnung: Offline-Gerät hat aktive Datenverbindungen.
  void _showActiveConnectionsWarning(List<String> active) {
    const labels = <String, String>{
      'wifi':        '📶  WLAN',
      'mobile_data': '📡  Mobile Daten (Mobilfunk)',
      'bluetooth':   '🔵  Bluetooth',
      'gps':         '📍  GPS / Standort',
      'nfc':         '💳  NFC',
    };

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.red.shade50,
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Expanded(child: Text('Sicherheitswarnung', style: TextStyle(color: Colors.red))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Dieses Gerät ist als Offline-Gerät (Luftspalt) konfiguriert – '
              'aber folgende Verbindungen sind noch aktiv:',
            ),
            const SizedBox(height: 12),
            ...active.map((c) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  const Icon(Icons.circle, color: Colors.red, size: 10),
                  const SizedBox(width: 8),
                  Text(
                    labels[c] ?? c,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.red),
                  ),
                ],
              ),
            )),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '🔒 Bitte alle Verbindungen deaktivieren, um den '
                'Luftspalt (Air-Gap) sicherzustellen!',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Verstanden',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showDeviceRoleDialog() async {
    DeviceRole selected = await DeviceRoleService.get();
    final pairingStatus = await PairingService.describeStatus();

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.devices, color: Colors.teal),
                SizedBox(width: 8),
                Text('🔄 Geräterolle'),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Wählen Sie, welche Rolle dieses Gerät übernimmt.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  RadioListTile<DeviceRole>(
                    value: DeviceRole.standalone,
                    groupValue: selected,
                    onChanged: (v) => setS(() => selected = v!),
                    title: const Text('Standalone'),
                    subtitle: const Text(
                        'Internet + eigene Schlüssel. Klassischer Modus.'),
                    secondary:
                        const Icon(Icons.smartphone, color: Colors.blue),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<DeviceRole>(
                    value: DeviceRole.onlineRelay,
                    groupValue: selected,
                    onChanged: (v) => setS(() => selected = v!),
                    title: const Text('Online-Relay'),
                    subtitle: const Text(
                        'Briefkasten für ein gepaartes Air-Gap-Gerät. '
                        'Eingehende Transfers landen in der Pickup-Queue.'),
                    secondary:
                        const Icon(Icons.swap_horiz, color: Colors.indigo),
                    contentPadding: EdgeInsets.zero,
                  ),
                  RadioListTile<DeviceRole>(
                    value: DeviceRole.airGap,
                    groupValue: selected,
                    onChanged: (v) => setS(() => selected = v!),
                    title: const Text('Air-Gap (Luftspalt)'),
                    subtitle: const Text(
                        'Kein Internet, Datenaustausch nur per QR/USB.'),
                    secondary: const Icon(Icons.wifi_off, color: Colors.orange),
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.teal.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.teal.shade200),
                    ),
                    child: Text(selected.description,
                        style: const TextStyle(fontSize: 12)),
                  ),
                  if (selected == DeviceRole.onlineRelay ||
                      selected == DeviceRole.airGap) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.deepPurple.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: Colors.deepPurple.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('🔗 Pairing-Status',
                              style:
                                  TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(pairingStatus,
                              style: const TextStyle(
                                  fontSize: 12, fontFamily: 'monospace')),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.qr_code, size: 16),
                                label: const Text('Pairing einrichten'),
                                onPressed: () async {
                                  Navigator.of(ctx).pop();
                                  await _showPairingDialog();
                                },
                              ),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.delete_outline,
                                    size: 16, color: Colors.red),
                                label: const Text('Pairing löschen',
                                    style: TextStyle(color: Colors.red)),
                                onPressed: () async {
                                  await PairingService.clearPairing();
                                  if (!ctx.mounted) return;
                                  Navigator.of(ctx).pop();
                                  if (mounted) {
                                    showQgapSnackBar(
                                        context,
                                        const SnackBar(
                                            content:
                                                Text('Pairing gelöscht.')));
                                    await _loadPairingStatus();
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () async {
                  await DeviceRoleService.set(selected);
                  if (mounted) {
                    setState(() {
                      _deviceRole = selected;
                      _deviceRoleOffline = selected == DeviceRole.airGap;
                      _deviceRoleOnline =
                          selected == DeviceRole.standalone ||
                              selected == DeviceRole.onlineRelay;
                    });
                    Navigator.of(ctx).pop();
                    showQgapSnackBar(
                        context,
                        SnackBar(
                            content: Text(
                                '✅ Geräterolle: ${selected.shortLabel}'),
                            backgroundColor: Colors.teal));
                    await _checkOfflineConnections();
                    await _loadPairingStatus();
                  }
                },
                child: const Text('Speichern'),
              ),
            ],
          );
        });
      },
    );
  }

  /// Wendet ein bereits geparstes Pairing-Payload (`qgap_pair` JSON) an.
  /// Wird sowohl vom Pairing-Dialog (nach explizitem Scan) als auch vom
  /// Hauptscreen-QR-Scanner aufgerufen, wenn der Inhalt automatisch als
  /// Pairing-Daten erkannt wurde.
  Future<void> _applyScannedPairingPayload(Map<String, dynamic> parsed) async {
    final myFp = _rsaKeyManager.getMyPublicKeyFingerprint();
    if (myFp == null) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text(
                'Pairing nicht möglich: kein eigener RSA-Schlüssel vorhanden.')),
      );
      return;
    }
    try {
      final pubKeyJson = jsonEncode({
        'modulus': parsed['modulus'].toString(),
        'exponent': parsed['exponent'].toString(),
      });
      final partnerName = (parsed['name'] as String?)?.trim().isNotEmpty == true
          ? (parsed['name'] as String).trim()
          : 'Partner';
      final partnerUid = (parsed['uid'] as String?)?.trim();
      final partnerRoleId = (parsed['role'] as String?) ?? '';
      final partnerFp = (parsed['fingerprint'] as String?) ?? '–';

      // Bestätigungsdialog mit Eckdaten anzeigen, bevor gespeichert wird.
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('🔗 Pairing-Daten erkannt'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Partner: $partnerName',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              if (partnerUid != null && partnerUid.isNotEmpty)
                Text('UID: $partnerUid',
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace')),
              Text('Fingerprint: $partnerFp',
                  style: const TextStyle(
                      fontSize: 11, fontFamily: 'monospace')),
              if (partnerRoleId.isNotEmpty)
                Text('Rolle: $partnerRoleId',
                    style: const TextStyle(fontSize: 11)),
              const SizedBox(height: 8),
              const Text(
                  'Soll dieses Pairing übernommen werden? Ein vorhandenes Pairing wird ersetzt.',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Abbrechen')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Übernehmen')),
          ],
        ),
      );
      if (ok != true) return;

      await PairingService.savePairing(
        partnerPublicKeyJson: pubKeyJson,
        partnerDisplayName: partnerName,
        myFingerprint: myFp,
        partnerOnlineUid:
            (partnerUid == null || partnerUid.isEmpty) ? null : partnerUid,
      );
      if (partnerUid != null && partnerUid.isNotEmpty) {
        await LocalContactService.saveLocalName(partnerUid, partnerName);
      }
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text('✅ Pairing gespeichert.'),
            backgroundColor: Colors.green),
      );
      await _loadPairingStatus();
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context,
          SnackBar(content: Text('Pairing fehlgeschlagen: $e')));
    }
  }

  /// Pairing-Dialog mit den vorhandenen Übertragungswegen:
  /// - Eigene Daten teilen: animierter QR (`QrDataSender`) ODER `.qgap_pair`-Datei.
  /// - Partner-Daten empfangen: animierter QR (`QrDataReceiver`) ODER
  ///   `.qgap_pair`-Datei aus dem Dateisystem.
  Future<void> _showPairingDialog() async {
    final myFp = _rsaKeyManager.getMyPublicKeyFingerprint() ?? '(kein Key)';
    final myUid = AuthService.currentUid ?? '(nicht eingeloggt)';
    final myPubKey = _rsaKeyManager.getMyPublicKey();

    // Eigenen Anzeigenamen vorbelegen, falls bereits gespeichert.
    final myNameCtrl = TextEditingController(
      text: await LocalContactService.getLocalName(myUid, fallback: ''),
    );
    final myRole = await DeviceRoleService.get();

    if (myPubKey == null) {
      if (!mounted) return;
      showQgapSnackBar(
          context,
          const SnackBar(
              content: Text(
                  'Kein RSA-Key vorhanden – bitte zuerst einen Schlüssel generieren.')));
      return;
    }

    Uint8List buildOwnPayload() {
      final map = {
        'v': 1,
        'kind': 'qgap_pair',
        'uid': myUid,
        'name': myNameCtrl.text.trim(),
        'role': myRole.id,
        'modulus': myPubKey.modulus.toString(),
        'exponent': myPubKey.exponent.toString(),
        'fingerprint': myFp,
      };
      return Uint8List.fromList(utf8.encode(jsonEncode(map)));
    }

    Future<bool> applyPartnerPayload(Uint8List bytes) async {
      try {
        final text = utf8.decode(bytes);
        final parsed = jsonDecode(text);
        if (parsed is! Map ||
            _normalizeLegacyType(parsed['kind'] as String?) != 'qgap_pair' ||
            parsed['modulus'] == null ||
            parsed['exponent'] == null) {
          throw const FormatException(
              'Datei/QR enthält keine gültigen Pairing-Daten.');
        }
        final pubKeyJson = jsonEncode({
          'modulus': parsed['modulus'].toString(),
          'exponent': parsed['exponent'].toString(),
        });
        final partnerName = (parsed['name'] as String?)?.trim().isNotEmpty == true
            ? (parsed['name'] as String).trim()
            : 'Partner';
        final partnerUid = (parsed['uid'] as String?)?.trim();
        await PairingService.savePairing(
          partnerPublicKeyJson: pubKeyJson,
          partnerDisplayName: partnerName,
          myFingerprint: myFp,
          partnerOnlineUid:
              (partnerUid == null || partnerUid.isEmpty) ? null : partnerUid,
        );
        // Wenn der Partner eine Online-UID liefert, auch als Kontaktnamen merken.
        if (partnerUid != null && partnerUid.isNotEmpty) {
          await LocalContactService.saveLocalName(partnerUid, partnerName);
        }
        return true;
      } catch (e) {
        if (mounted) {
          showQgapSnackBar(context,
              SnackBar(content: Text('Pairing fehlgeschlagen: $e')));
        }
        return false;
      }
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(builder: (ctx, setS) {
          return AlertDialog(
            title: const Text('🔗 Pairing einrichten'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Eigene Daten ──────────────────────────────────────────
                  const Text('Eigene Daten an den Partner senden:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  SelectableText('UID:         $myUid',
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                  SelectableText('Fingerprint: $myFp',
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                  Text('Rolle:       ${myRole.shortLabel}',
                      style: const TextStyle(
                          fontSize: 11, fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: myNameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Eigener Anzeigename (Partner sieht ihn)',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code, size: 16),
                        label: const Text('Per QR senden'),
                        onPressed: () async {
                          if (myNameCtrl.text.trim().isEmpty) {
                            showQgapSnackBar(
                                ctx,
                                const SnackBar(
                                    content: Text(
                                        'Bitte zuerst eigenen Anzeigenamen eingeben.')));
                            return;
                          }
                          final payload = buildOwnPayload();
                          if (!ctx.mounted) return;
                          await Navigator.of(ctx).push(MaterialPageRoute(
                            builder: (_) => QrDataSender(bytes: payload),
                          ));
                          // Eigene Daten als gesendet markieren
                          await PairingService.markOwnDataSent();
                          await _loadPairingStatus();
                          if (!ctx.mounted) return;
                          // Direkt zur Gegenrichtung führen
                          final doScanNow = await showDialog<bool>(
                            context: ctx,
                            builder: (dlgCtx) => AlertDialog(
                              title: const Row(children: [
                                Icon(Icons.check_circle_outline,
                                    color: Colors.green),
                                SizedBox(width: 8),
                                Flexible(
                                    child: Text('Deine Daten gesendet')),
                              ]),
                              content: const Text(
                                'Lass den Partner deinen QR-Code scannen.\n\n'
                                'Wenn er fertig ist, zeigt er dir seinen '
                                'QR-Code – scanne ihn, um das Pairing '
                                'abzuschließen.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(dlgCtx).pop(false),
                                  child: const Text('Später'),
                                ),
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.qr_code_scanner,
                                      size: 16),
                                  label: const Text('Jetzt scannen'),
                                  onPressed: () =>
                                      Navigator.of(dlgCtx).pop(true),
                                ),
                              ],
                            ),
                          );
                          if (doScanNow == true && ctx.mounted) {
                            final scanBytes =
                                await Navigator.of(ctx).push<Uint8List>(
                              MaterialPageRoute(
                                  builder: (_) => const QrDataReceiver()),
                            );
                            if (scanBytes != null) {
                              final ok = await applyPartnerPayload(scanBytes);
                              if (ok && ctx.mounted) {
                                Navigator.of(ctx).pop();
                                if (mounted) {
                                  await _loadPairingStatus();
                                  showQgapSnackBar(
                                    context,
                                    const SnackBar(
                                      content: Text(
                                          '✅ Pairing vollständig abgeschlossen!'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              }
                            }
                          }
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text('Als .qgap_pair speichern'),
                        onPressed: () async {
                          if (myNameCtrl.text.trim().isEmpty) {
                            showQgapSnackBar(
                                ctx,
                                const SnackBar(
                                    content: Text(
                                        'Bitte zuerst eigenen Anzeigenamen eingeben.')));
                            return;
                          }
                          await _exportPairFile(buildOwnPayload());
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  // ── Partner-Daten ─────────────────────────────────────────
                  const Text('Partner-Daten empfangen:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.qr_code_scanner, size: 16),
                        label: const Text('QR scannen'),
                        onPressed: () async {
                          final bytes = await Navigator.of(ctx).push<Uint8List>(
                            MaterialPageRoute(
                                builder: (_) => const QrDataReceiver()),
                          );
                          if (bytes == null) return;
                          final ok = await applyPartnerPayload(bytes);
                          if (ok) {
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
                            if (mounted) {
                              await _loadPairingStatus();
                              showQgapSnackBar(
                                  context,
                                  const SnackBar(
                                      content:
                                          Text('✅ Pairing gespeichert.'),
                                      backgroundColor: Colors.green));
                            }
                          }
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('.qgap_pair-Datei wählen'),
                        onPressed: () async {
                          final bytes = await _pickPairFile();
                          if (bytes == null) return;
                          final ok = await applyPartnerPayload(bytes);
                          if (ok) {
                            if (!ctx.mounted) return;
                            Navigator.of(ctx).pop();
                            if (mounted) {
                              await _loadPairingStatus();
                              showQgapSnackBar(
                                  context,
                                  const SnackBar(
                                      content:
                                          Text('✅ Pairing gespeichert.'),
                                      backgroundColor: Colors.green));
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Schließen'),
              ),
            ],
          );
        });
      },
    );
  }

  /// Exportiert das Pairing-Payload als `.qgap_pair`-Datei und öffnet
  /// den Share-Sheet (USB-Übertragung über Filebrowser möglich).
  Future<void> _exportPairFile(Uint8List payload) async {
    try {
      final dir = Platform.isAndroid
          ? (await getExternalStorageDirectory() ??
              await getApplicationDocumentsDirectory())
          : await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outPath = '${dir.path}/qgap_pair_$ts.qgap_pair';
      final f = File(outPath);
      await f.writeAsBytes(payload, flush: true);
      if (!mounted) return;
      await Share.shareXFiles([XFile(outPath)],
          text: 'QGap-Pairing-Daten');
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context,
          SnackBar(content: Text('Export fehlgeschlagen: $e')));
    }
  }

  /// Wählt eine `.qgap_pair`-Datei und liefert deren Inhalt zurück.
  Future<Uint8List?> _pickPairFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['qgap_pair'],
        withData: true,
        dialogTitle: '.qgap_pair-Datei wählen',
      ).catchError((_) => FilePicker.platform.pickFiles(
            type: FileType.any,
            withData: true,
          ));
      if (res == null || res.files.isEmpty) return null;
      final f = res.files.first;
      if (f.bytes != null) return f.bytes;
      if (f.path != null) {
        return await File(f.path!).readAsBytes();
      }
      return null;
    } catch (e) {
      if (!mounted) return null;
      showQgapSnackBar(context,
          SnackBar(content: Text('Datei-Auswahl fehlgeschlagen: $e')));
      return null;
    }
  }

  // Dialog zur Anzeige der Internetverbindungsinfo
  void _showConnectionInfoDialog() async {
    // Lade gespeicherte Verbindungszeit
    final prefs = await SharedPreferences.getInstance();
    final lastConnection = prefs.getString('last_internet_connection');
    
    // Aktuelle Verbindung prüfen
    final connectivity = Connectivity();
    final connectivityResult = await connectivity.checkConnectivity();
    
    String currentStatus = '';
    String statusIcon = '';
    Color statusColor = Colors.grey;
    
    if (connectivityResult.contains(ConnectivityResult.mobile)) {
      currentStatus = 'Mobilfunk (Mobile Daten)';
      statusIcon = '📱';
      statusColor = Colors.green;
      // Aktuelle Zeit speichern
      await prefs.setString('last_internet_connection', DateTime.now().toIso8601String());
    } else if (connectivityResult.contains(ConnectivityResult.wifi)) {
      currentStatus = 'WLAN (WiFi)';
      statusIcon = '📶';
      statusColor = Colors.green;
      // Aktuelle Zeit speichern
      await prefs.setString('last_internet_connection', DateTime.now().toIso8601String());
    } else if (connectivityResult.contains(ConnectivityResult.ethernet)) {
      currentStatus = 'Ethernet (Kabelverbindung)';
      statusIcon = '🔌';
      statusColor = Colors.green;
      // Aktuelle Zeit speichern
      await prefs.setString('last_internet_connection', DateTime.now().toIso8601String());
    } else {
      currentStatus = 'Keine Verbindung';
      statusIcon = '❌';
      statusColor = Colors.red;
    }
    
    String lastConnectionText = 'Nie';
    if (lastConnection != null) {
      try {
        final lastTime = DateTime.parse(lastConnection);
        lastConnectionText = _formatDetailedDateTime(lastTime);
      } catch (e) {
        lastConnectionText = 'Unbekannt';
      }
    }
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('🌐 Internetverbindung'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Aktueller Status
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: statusColor.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Text(statusIcon, style: const TextStyle(fontSize: 24)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Aktueller Status:',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            currentStatus,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: statusColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              // Letzte Verbindung
              Row(
                children: [
                  const Icon(Icons.history, size: 20, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text(
                    'Letzte Internetverbindung:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  lastConnectionText,
                  style: const TextStyle(
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              
              // Hinweis
              Text(
                'Die letzte Verbindungszeit wird nur aktualisiert, wenn diese Funktion verwendet wird.',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                // Dialog erneut anzeigen um aktualisierte Daten zu sehen
                await Future.delayed(const Duration(milliseconds: 100));
                _showConnectionInfoDialog();
              },
              child: const Text('🔄 Aktualisieren'),
            ),
          ],
        );
      },
    );
  }

  // Formatiert DateTime detailliert für die Anzeige
  String _formatDetailedDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);
    
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year.toString();
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final second = dateTime.second.toString().padLeft(2, '0');
    
    String timeAgo = '';
    if (difference.inDays > 0) {
      timeAgo = ' (vor ${difference.inDays} Tag${difference.inDays > 1 ? 'en' : ''})';
    } else if (difference.inHours > 0) {
      timeAgo = ' (vor ${difference.inHours} Stunde${difference.inHours > 1 ? 'n' : ''})';
    } else if (difference.inMinutes > 0) {
      timeAgo = ' (vor ${difference.inMinutes} Minute${difference.inMinutes > 1 ? 'n' : ''})';
    } else {
      timeAgo = ' (gerade eben)';
    }
    
    return '$day.$month.$year um $hour:$minute:$second$timeAgo';
  }

  // Dialog für Passwort-Einstellungen
  void _showPasswordSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final hasPassword = prefs.getString('app_password') != null;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('🔐 App-Passwort verwalten'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasPassword) ...[
                const Icon(Icons.check_circle, color: Colors.green, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'App-Passwort ist aktiv',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Die App ist durch ein Passwort geschützt.'),
              ] else ...[
                const Icon(Icons.warning, color: Colors.orange, size: 48),
                const SizedBox(height: 12),
                const Text(
                  'Kein Passwort festgelegt',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange,
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Für zusätzliche Sicherheit können Sie ein App-Passwort festlegen.'),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
            if (hasPassword) ...[
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showChangePasswordDialog();
                },
                child: const Text('Ändern'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showRemovePasswordDialog();
                },
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Entfernen'),
              ),
            ] else ...[
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  _showSetPasswordDialog();
                },
                child: const Text('Passwort festlegen'),
              ),
            ],
          ],
        );
      },
    );
  }

  // Dialog zum Festlegen eines neuen Passworts
  void _showSetPasswordDialog() {
    String password = '';
    String confirmPassword = '';
    bool obscurePassword = true;
    bool obscureConfirm = true;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('🔐 Passwort festlegen'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Legen Sie ein sicheres Passwort für die App fest (max. 50 Zeichen):',
                      style: TextStyle(fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      onChanged: (value) => password = value,
                      obscureText: obscurePassword,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: 'Neues Passwort',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscurePassword ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              obscurePassword = !obscurePassword;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => confirmPassword = value,
                      obscureText: obscureConfirm,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: 'Passwort bestätigen',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureConfirm ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              obscureConfirm = !obscureConfirm;
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    if (password.isEmpty) {
                      developer.log('log: Passwort darf nicht leer sein', name: 'PasswordSettings');
                      return;
                    }
                    
                    if (password != confirmPassword) {
                      developer.log('log: Passwörter stimmen nicht überein', name: 'PasswordSettings');
                      return;
                    }
                    
                    if (password.length > 50) {
                      developer.log('log: Passwort zu lang (max. 50 Zeichen)', name: 'PasswordSettings');
                      return;
                    }
                    
                    // Passwort gehasht speichern (SHA-256, OWASP M4)
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setString('app_password', _hashPassword(password));
                    
                    if (mounted) {
                      Navigator.of(context).pop();
                    }
                    
                    developer.log('log: ✅ App-Passwort erfolgreich festgelegt', name: 'PasswordSettings');
                  },
                  child: const Text('Festlegen'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Dialog zum Ändern des Passworts
  void _showChangePasswordDialog() {
    String currentPassword = '';
    String newPassword = '';
    String confirmPassword = '';
    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('🔐 Passwort ändern'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      onChanged: (value) => currentPassword = value,
                      obscureText: obscureCurrent,
                      decoration: InputDecoration(
                        labelText: 'Aktuelles Passwort',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureCurrent ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              obscureCurrent = !obscureCurrent;
                            });
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => newPassword = value,
                      obscureText: obscureNew,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: 'Neues Passwort',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureNew ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              obscureNew = !obscureNew;
                            });
                          },
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 4, left: 4),
                      child: Text(
                        'Leer lassen, um den Passwortschutz zu deaktivieren',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      onChanged: (value) => confirmPassword = value,
                      obscureText: obscureConfirm,
                      maxLength: 50,
                      decoration: InputDecoration(
                        labelText: 'Neues Passwort bestätigen',
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscureConfirm ? Icons.visibility : Icons.visibility_off,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              obscureConfirm = !obscureConfirm;
                            });
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    if (currentPassword.isEmpty) {
                      developer.log('log: Aktuelles Passwort erforderlich', name: 'PasswordSettings');
                      return;
                    }

                    // Aktuelles Passwort prüfen (SHA-256 Vergleich)
                    final prefs = await SharedPreferences.getInstance();
                    final storedHash = prefs.getString('app_password');

                    if (storedHash == null || !_verifyPassword(currentPassword, storedHash)) {
                      developer.log('log: Aktuelles Passwort ist falsch', name: 'PasswordSettings');
                      return;
                    }

                    // Leeres neues Passwort = Passwortschutz deaktivieren
                    if (newPassword.isEmpty) {
                      await prefs.remove('app_password');
                      if (mounted) {
                        Navigator.of(context).pop();
                      }
                      developer.log('log: ✅ App-Passwort deaktiviert (leere Eingabe)', name: 'PasswordSettings');
                      return;
                    }

                    if (newPassword != confirmPassword) {
                      developer.log('log: Neue Passwörter stimmen nicht überein', name: 'PasswordSettings');
                      return;
                    }

                    if (newPassword.length > 50) {
                      developer.log('log: Neues Passwort zu lang (max. 50 Zeichen)', name: 'PasswordSettings');
                      return;
                    }

                    // Neues Passwort gehasht speichern
                    await prefs.setString('app_password', _hashPassword(newPassword));
                    
                    if (mounted) {
                      Navigator.of(context).pop();
                    }
                    
                    developer.log('log: ✅ App-Passwort erfolgreich geändert', name: 'PasswordSettings');
                  },
                  child: const Text('Ändern'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Dialog zum Entfernen des Passworts
  void _showRemovePasswordDialog() {
    String currentPassword = '';
    bool obscurePassword = true;
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('🔓 Passwort entfernen'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Sind Sie sicher, dass Sie das App-Passwort entfernen möchten?\n\nDie App wird dann ohne Passwort-Schutz gestartet.',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    onChanged: (value) => currentPassword = value,
                    obscureText: obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Aktuelles Passwort zur Bestätigung',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(
                          obscurePassword ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setDialogState(() {
                            obscurePassword = !obscurePassword;
                          });
                        },
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    if (currentPassword.isEmpty) {
                      developer.log('log: Passwort zur Bestätigung erforderlich', name: 'PasswordSettings');
                      return;
                    }
                    
                    // Aktuelles Passwort prüfen (SHA-256 Vergleich)
                    final prefs = await SharedPreferences.getInstance();
                    final storedHash = prefs.getString('app_password');

                    if (storedHash == null || !_verifyPassword(currentPassword, storedHash)) {
                      developer.log('log: Passwort ist falsch', name: 'PasswordSettings');
                      return;
                    }
                    
                    // Passwort entfernen
                    await prefs.remove('app_password');
                    
                    if (mounted) {
                      Navigator.of(context).pop();
                    }
                    
                    developer.log('log: ✅ App-Passwort erfolgreich entfernt', name: 'PasswordSettings');
                  },
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                  child: const Text('Entfernen'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Dialog zur Erstellung einer zufälligen .qgap_ec Datei
  void _showCreateRandomFileDialog({void Function(String createdFileName)? onFileCreated}) {
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
                    
                    developer.log('log: Starte Dateierstellung: $trimmedFileName.qgap_ec ($size MB)', name: 'CreateRandomFile');
                    
                    // Kurze Verzögerung um sicherzustellen dass der Dialog geschlossen ist
                    await Future.delayed(const Duration(milliseconds: 100));
                    
                    _createRandomFileWithProgress(trimmedFileName, size, onFileCreated: onFileCreated);
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

  // Erstellt eine zufällige binäre .qgap_ec Datei mit Progress Dialog
  void _createRandomFileWithProgress(String fileName, int sizeInMB, {void Function(String)? onFileCreated}) {
    developer.log('log: _createRandomFileWithProgress aufgerufen: $fileName, $sizeInMB MB', name: 'CreateRandomFile');
    
    double progress = 0.0;
    late StateSetter updateProgress;
    
    // Progress Dialog sofort anzeigen
    showDialog(
      context: context,
      barrierDismissible: false, // Nicht schließbar während Erstellung
      builder: (BuildContext dialogContext) {
        developer.log('log: Progress Dialog wird aufgebaut', name: 'CreateRandomFile');
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
      developer.log('log: Starte Dateierstellung nach Dialog-Anzeige', name: 'CreateRandomFile');
      
      // Datei-Erstellung mit Progress-Updates
      _performFileCreationWithProgress(fileName, sizeInMB, (newProgress) {
        developer.log('log: Progress Update: ${(newProgress * 100).toInt()}%', name: 'CreateRandomFile');
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

        // Erfolg oder Fehler nur über developer.log protokollieren
        if (createdFileName != null) {
          developer.log('log: ✅ Datei "$createdFileName" erfolgreich erstellt ($sizeInMB MB)', name: 'CreateRandomFile');
          onFileCreated?.call(createdFileName);

          // Code aus Dateiname extrahieren und kurz anzeigen, damit der
          // Anwender ihn dem Empfänger ggf. mitteilen kann.
          final code =
              EcKeyfileService.extractCodeFromFilename(createdFileName);
          if (mounted && code != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 6),
                content: Text(
                    '🎲 EC-Code: $code\nDatei: $createdFileName'),
              ),
            );
          }
        } else {
          developer.log('log: ❌ Fehler beim Erstellen der Datei', name: 'CreateRandomFile');
        }
      }).catchError((error) {
        developer.log('log: Fehler bei Dateierstellung: $error', name: 'CreateRandomFile');
        
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
    String fileName, 
    int sizeInMB, 
    Function(double) onProgressUpdate
  ) async {
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
        developer.log('log: Ordner erstellt: ${qgapDir.path}', name: '_performFileCreation');
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
              content: Text('Die Datei "$fullFileName" existiert bereits. Überschreiben?'),
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
          final currentChunkSize = remainingBytes > chunkSize ? chunkSize : remainingBytes;
          
          // Chunk generieren
          final chunk = List<int>.generate(currentChunkSize, (index) => random.nextInt(256));
          sink.add(chunk);
          
          writtenBytes += currentChunkSize;
          
          // Progress aktualisieren
          final progress = writtenBytes / totalBytes;
          onProgressUpdate(progress);
          
          developer.log('log: Fortschritt: ${(progress * 100).toInt()}% ($writtenBytes/$totalBytes bytes)', name: 'CreateRandomFile');
          
          // Pause für UI-Responsiveness und Progress-Update
          await Future.delayed(const Duration(milliseconds: 100));
        }
        
        // Finaler Progress-Update
        onProgressUpdate(1.0);
        
      } finally {
        await sink.close();
      }
      
      developer.log('log: Zufallsdatei erfolgreich erstellt: $filePath ($totalBytes bytes)', name: '_performFileCreationWithProgress');
      return fullFileName;

    } catch (e) {
      developer.log('log: Fehler beim Erstellen der Zufallsdatei: $e', name: '_performFileCreationWithProgress');
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Desktop: .qgap/.qgap_ch/.qgap_ec-Dateien direkt aufs Fenster ziehen
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      return DropTarget(
        onDragDone: (detail) async {
          for (final f in detail.files) {
            if (!mounted) return;
            await _handleIncomingFileIntent(f.path);
          }
        },
        child: _safeBuild(context),
      );
    }
    return _safeBuild(context);
  }

  // Sicherer Build-Wrapper mit Fehlerbehandlung
  Widget _safeBuild(BuildContext context) {
    try {
      return _buildMainScaffold(context);
    } catch (e) {
      developer.log('log: Build-Fehler abgefangen: $e', name: 'safeBuild');
      return Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/images/icon_logo_qgap.png',
                height: 32,
                width: 32,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(Icons.error);
                },
              ),
              const SizedBox(width: 8),
              const Text('QR Code Chat'),
            ],
          ),
          backgroundColor: Colors.blue,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'App-Fehler aufgetreten',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text('Bitte App neu starten'),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  _initializeApp();
                },
                child: const Text('Neu laden'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildMainScaffold(BuildContext context) {
    // Hintergrund- und AppBar-Farbe je nach Geräterolle
    final Color appBarColor;
    final Color scaffoldBg;

    switch (_deviceRole) {
      case DeviceRole.airGap:
        // Air-Gap (Luftspalt) → Grün
        appBarColor = Colors.green.shade700;
        scaffoldBg  = Colors.green.shade50;
        break;
      case DeviceRole.onlineRelay:
        // Online-Relay (Briefkasten) → Indigo
        appBarColor = Colors.indigo.shade400;
        scaffoldBg  = Colors.indigo.shade50;
        break;
      case DeviceRole.standalone:
        // Standalone → Standard Blau/Weiß
        appBarColor = Colors.blue;
        scaffoldBg  = Colors.white;
        break;
    }

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        backgroundColor: appBarColor,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/images/icon_logo_qgap.png',
              height: 32,
              width: 32,
              errorBuilder: (context, error, stackTrace) {
                return const Text('🏠');
              },
            ),
            const SizedBox(width: 8),
            const Text('QGap Chat Gruppen'),
          ],
        ),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) async {
              if (value == 'settings') {
                _showSettings();
              } else if (value == 'info') {
                showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text('QGap Chat'),
                      content: const Text(
                        'Once Book Message Code Chat\n\n'
                        'Erstellen Sie verschiedene Chat-Gruppen mit eigenen Verschlüsselungseinstellungen.\n\n'
                        'Jede Gruppe kann unterschiedliche .qgap Dateien und Byte-Positionen verwenden.'
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    );
                  },
                );
              } else if (value == 'rsa_keys') {
                _showRSAKeyManagement();
              } else if (value == 'storage_location') {
                _showStorageLocationDialog();
              } else if (value == 'export_public_key') {
                _showPublicKeyExport();
              } else if (value == 'toggle_notifications') {
                final newVal = !_notificationsEnabled;
                await NotificationService.setEnabled(newVal);
                if (mounted) setState(() => _notificationsEnabled = newVal);
              } else if (value == 'public_screen') {
                if (mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const PublicScreenListScreen(),
                  )).then((_) => _loadPublicSessions());
                }
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Text('Einstellungen'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'storage_location',
                child: Row(
                  children: [
                    Icon(Icons.folder_outlined, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Text('Speicherort'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'info',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Text('Info'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'public_screen',
                child: Row(
                  children: [
                    Icon(Icons.slideshow, color: Colors.deepPurple, size: 20),
                    SizedBox(width: 8),
                    Text('Präsentationen'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'rsa_keys',
                child: Row(
                  children: [
                    Icon(Icons.vpn_key, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Text('RSA-Schlüssel'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'export_public_key',
                child: Row(
                  children: [
                    Icon(Icons.qr_code, color: Colors.grey, size: 20),
                    SizedBox(width: 8),
                    Text(' teilen'),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'toggle_notifications',
                child: Row(
                  children: [
                    Icon(
                      _notificationsEnabled
                          ? Icons.notifications_active
                          : Icons.notifications_off,
                      color: _notificationsEnabled ? Colors.blue : Colors.grey,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _notificationsEnabled
                          ? 'Benachrichtigungen deaktivieren'
                          : 'Benachrichtigungen aktivieren',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Suchfeld: filtert Chats nach Name/Beschreibung/Nachrichtentext
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 20, 4),
            child: TextField(
              controller: _chatSearchController,
              decoration: InputDecoration(
                hintText: 'Chats durchsuchen …',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _chatSearchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Suche löschen',
                        onPressed: () {
                          _chatSearchController.clear();
                          setState(() => _chatSearchQuery = '');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                filled: true,
                fillColor: Colors.white,
              ),
              onChanged: (value) => setState(() => _chatSearchQuery = value),
            ),
          ),
          Expanded(
            child: ListView.builder(
          padding: const EdgeInsets.only(
            left: 16,
            right: 20,
            top: 8,
            bottom: 80, // Extra Platz für FloatingActionButton
          ),
          // +1 für den fest eingepinnten Transfer-Hub-Eintrag (nur ohne/mit passender Suche)
          // +1 für Pairing-Status-Banner (wenn Online-Relay/Air-Gap, nur ohne/mit passender Suche)
          // +N für Präsentations-Sessions (nach den Chat-Gruppen)
          itemCount: _visibleChatGroups.length +
              (_transferHubVisible ? 1 : 0) +
              _visiblePublicSessions.length +
              ((_deviceRole != DeviceRole.standalone && _pairingBannerVisible) ? 1 : 0),
          itemBuilder: (context, index) {
            final visibleGroups = _visibleChatGroups;
            final visibleSessions = _visiblePublicSessions;
            final showPairingBanner =
                _deviceRole != DeviceRole.standalone && _pairingBannerVisible;
            final showTransferHub = _transferHubVisible;
            int idx = index;
            // ── Pairing-Status-Banner ──────────────────────────────────────
            if (showPairingBanner) {
              if (idx == 0) return _buildPairingStatusBanner();
              idx -= 1;
            }
            // ── Transfer-Hub (fest, nicht löschbar) ──────────────────────
            if (showTransferHub) {
              if (idx == 0) return _buildTransferHubTile();
              idx -= 1;
            }

            // ── Präsentationen (nach den Chat-Gruppen) ───────────────
            if (idx >= visibleGroups.length) {
              final session = visibleSessions[idx - visibleGroups.length];
              return _buildPublicSessionTile(session);
            }

            // ── Chat-Gruppen ──────────────────────────────────────────────
            final group = visibleGroups[idx];
            final needsKey = _chatNeedsKey[group.id] ?? false;
              return Card(
                margin: const EdgeInsets.only(bottom: 6), // Reduziert von 12 auf 8
                elevation: 2,
                child: ListTile(
                  contentPadding: const EdgeInsets.all(4),
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        backgroundColor: Colors.blue.shade100,
                        child: Text(
                          group.iconEmoji,
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                      // Transport+Crypto-Badge unten rechts
                      Positioned(
                        bottom: -2,
                        right: -2,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: ChatTransportBadge(
                            transport: group.transport,
                            encryption: group.defaultEncryptionType,
                            ecUsbOnly: _chatEcUsbOnly[group.id] ?? false,
                            iconSize: 14,
                          ),
                        ),
                      ),
                      // ⚠️ Badge wenn OTP-Schlüsseldatei fehlt
                      if (needsKey)
                        Positioned(
                          top: -4,
                          right: -4,
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(
                              color: Colors.orange,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.warning_amber,
                              color: Colors.white,
                              size: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      // 🔴 Ungelesen-Badge
                      if ((_unreadCounts[group.id] ?? 0) > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '${_unreadCounts[group.id]}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (group.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.description,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 14,
                          ),
                        ),
                      ],
                      // ⚠️ Hinweis wenn Schlüsseldatei fehlt
                      if (needsKey) ...[
                        const SizedBox(height: 4),
                        const Row(
                          children: [
                            Icon(Icons.warning_amber,
                                size: 14, color: Colors.orange),
                            SizedBox(width: 4),
                            Text(
                              '⚠️ .qgap Schlüsseldatei fehlt noch',
                              style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                      // Zeige letzten Zeitstempel an, falls vorhanden
                      if (lastMessageTimes[group.id] != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.message,
                              size: 14,
                              color: Colors.green.shade600,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Letzte Nachricht: ${_formatDateTime(lastMessageTimes[group.id]!)}',
                              style: TextStyle(
                                color: Colors.green.shade600,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                      // Verschlüsselungstyp anzeigen
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                                ? Icons.shield 
                                : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                                ? Icons.vpn_key 
                                : Icons.lock_outline,
                            size: 14,
                            color: group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                                ? Colors.green.shade600
                                : Colors.blue.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                                ? 'One-Time-Pad'
                                : group.defaultEncryptionType == message_model.EncryptionType.rsa 
                                ? 'RSA-Verschlüsselung'
                                : group.defaultEncryptionType == message_model.EncryptionType.relayForward
                                ? 'Relay-Weiterleitung'
                                : 'Hybrid (RSA + AES)',
                            style: TextStyle(
                              color: group.defaultEncryptionType == message_model.EncryptionType.oneTimePad 
                                  ? Colors.green.shade600
                                  : Colors.blue.shade600,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      // 🔑 Kontaktschlüssel-Status für RSA/Hybrid-Chats
                      if (group.defaultEncryptionType == message_model.EncryptionType.rsa ||
                          group.defaultEncryptionType == message_model.EncryptionType.hybrid) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              _chatContactName[group.id] != null
                                  ? Icons.key
                                  : Icons.key_off,
                              size: 14,
                              color: _chatContactName[group.id] != null
                                  ? Colors.green.shade600
                                  : Colors.orange.shade700,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _chatContactName[group.id] != null
                                    ? '🔑 Schlüssel: ${_chatContactName[group.id]}'
                                    : '⚠️ Kein Kontaktschlüssel importiert',
                                style: TextStyle(
                                  color: _chatContactName[group.id] != null
                                      ? Colors.green.shade600
                                      : Colors.orange.shade700,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'edit') {
                        _editChatGroup(group);
                      } else if (value == 'delete') {
                        _deleteChatGroup(group);
                      } else if (value == 'info') {
                        _showChatGroupInfo(group);
                      } else if (value == 'online_invite') {
                        _sendOnlineInvite(group);
                      } else if (value == 'offline_ec_invite') {
                        _sendOfflineEcInvite(group);
                      } else if (value == 'relay_pairing') {
                        _showRelayPairingRequestQr(group);
                      } else if (value == 'relay_config_qr') {
                        _showRelayConfigQrForGroup(group);
                      }
                    },
                    itemBuilder: (BuildContext context) {
                      final isOtp = group.defaultEncryptionType ==
                          message_model.EncryptionType.oneTimePad;
                      final isRelayPhoneChat =
                          group.firestoreChatId?.startsWith('relay_') == true &&
                          group.defaultEncryptionType == message_model.EncryptionType.relayForward;
                      return [
                        // Online-Einladung auch für OTP-Chats mit Transport
                        // "online" — sonst kann kein Firestore-Sync entstehen.
                        if (isOtp && group.transport == ChatTransport.online)
                          PopupMenuItem<String>(
                            value: 'online_invite',
                            child: Row(
                              children: [
                                Icon(
                                  group.firestoreChatId != null
                                      ? Icons.cloud_done
                                      : Icons.cloud_upload,
                                  color: group.firestoreChatId != null
                                      ? Colors.green
                                      : Colors.blue,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  group.firestoreChatId != null
                                      ? 'Online-Einladung erneut senden'
                                      : 'Online-Einladung senden ☁️',
                                  style: TextStyle(
                                    color: group.firestoreChatId != null
                                        ? Colors.green
                                        : Colors.blue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // Offline-EC-Einladung nur für Offline-/AirGap-Chats
                        // — bei Online-Chats führt sie zu falscher Paarung.
                        if (isOtp && group.transport != ChatTransport.online)
                          const PopupMenuItem<String>(
                            value: 'offline_ec_invite',
                            child: Row(
                              children: [
                                Icon(Icons.qr_code,
                                    color: Colors.blue, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'EC-Einladung senden 🔒',
                                  style: TextStyle(color: Colors.blue),
                                ),
                              ],
                            ),
                          ),
                        if (isOtp)
                          const PopupMenuItem<String>(
                            value: 'relay_pairing',
                            child: Row(
                              children: [
                                Icon(Icons.compare_arrows,
                                    color: Colors.indigo, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Relay-Pairing starten 📡',
                                  style: TextStyle(color: Colors.indigo),
                                ),
                              ],
                            ),
                          )
                        else if (isRelayPhoneChat)
                          const PopupMenuItem<String>(
                            value: 'relay_config_qr',
                            child: Row(
                              children: [
                                Icon(Icons.qr_code_2,
                                    color: Colors.indigo, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Config-QR für Air-Gap anzeigen 📡',
                                  style: TextStyle(color: Colors.indigo),
                                ),
                              ],
                            ),
                          )
                        else
                          PopupMenuItem<String>(
                            value: 'online_invite',
                            child: Row(
                              children: [
                                Icon(
                                  group.isOnlineEnabled
                                      ? Icons.cloud_done
                                      : Icons.cloud_upload,
                                  color: group.isOnlineEnabled
                                      ? Colors.green
                                      : Colors.blue,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  group.isOnlineEnabled
                                      ? 'Online-Einladung erneut senden'
                                      : 'Online-Einladung senden ☁️',
                                  style: TextStyle(
                                    color: group.isOnlineEnabled
                                        ? Colors.green
                                        : Colors.blue,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const PopupMenuItem<String>(
                          value: 'info',
                          child: Row(
                            children: [
                              Icon(Icons.info, color: Colors.grey, size: 20),
                              SizedBox(width: 8),
                              Text('Info', style: TextStyle(color: Colors.grey)),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Row(
                            children: [
                              Icon(Icons.edit, color: Colors.blue, size: 20),
                              SizedBox(width: 8),
                              Text('Bearbeiten',
                                  style: TextStyle(color: Colors.blue)),
                            ],
                          ),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete, color: Colors.red, size: 20),
                              SizedBox(width: 8),
                              Text('Löschen',
                                  style: TextStyle(color: Colors.red)),
                            ],
                          ),
                        ),
                      ];
                    },
                  ),
                  onTap: () => _openChatGroup(group),
                ),
              );
            },
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            heroTag: 'fab_qr_scan',
            onPressed: _scanChatInvite,
            tooltip: 'QR-Code scannen (Einladung / Key)',
            child: const Icon(Icons.qr_code_scanner),
          ),
          const SizedBox(width: 16),
          FloatingActionButton(
            heroTag: 'fab_add_chat',
            onPressed: _createChatGroup,
            tooltip: 'Chat-Gruppe erstellen',
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  // Dialog zur Einstellung der EC-Code-Länge (Zufalls-Suffix in `.qgap_ec`-Dateinamen)
  Future<void> _showEcCodeLengthDialog() async {
    final current = await EcKeyfileService.getCodeLength();
    if (!mounted) return;
    int selected = current;
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('🎲 .qgap_ec Zufallszeichen-Länge'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Anzahl Zufallszeichen, die an neue .qgap_ec-Schlüssel-'
                    'Dateinamen angehängt werden.\n'
                    'Der Code identifiziert die Schlüsseldatei beim Empfänger '
                    'eindeutig, ohne den Dateinamen preiszugeben.',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(
                        'Länge: $selected',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'min ${EcKeyfileService.kMinCodeLength} · '
                        'max ${EcKeyfileService.kMaxCodeLength}',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                  Slider(
                    min: EcKeyfileService.kMinCodeLength.toDouble(),
                    max: EcKeyfileService.kMaxCodeLength.toDouble(),
                    divisions: EcKeyfileService.kMaxCodeLength -
                        EcKeyfileService.kMinCodeLength,
                    value: selected.toDouble(),
                    label: '$selected',
                    onChanged: (v) {
                      setStateDialog(() => selected = v.round());
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Abbrechen'),
                ),
                TextButton(
                  onPressed: () async {
                    await EcKeyfileService.setCodeLength(selected);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: const Text('Speichern'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Dialog zur Verwaltung von Schlüsseldateien (USB-Stick-Funktionen)
  Future<void> _showKeyFileManagementDialog() async {
    // Alle lokalen .qgap_ec-Dateien laden
    final localEcFiles = (await _getLocalKeyFiles())
        .where((f) => f.endsWith('.qgap_ec'))
        .toList()
      ..sort();

    // Chat-Zuordnung aufbauen: Dateiname → Liste der Chat-Namen
    final prefs = await SharedPreferences.getInstance();
    final Map<String, List<String>> assignments = {
      for (final f in localEcFiles) f: [],
    };
    for (final group in chatGroups) {
      final assigned = prefs.getString('chat_ec_file_${group.id}') ?? '';
      if (assigned.isNotEmpty) {
        assignments.putIfAbsent(assigned, () => []).add(group.name);
      }
    }

    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (BuildContext dlgCtx) {
        return AlertDialog(
          title: const Text('💾 EC-Schlüsseldateien verwalten'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Dateiliste mit Zuordnungen ────────────────────────────
                const Text(
                  'Vorhandene .qgap_ec Dateien (lokal):',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                if (localEcFiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Keine .qgap_ec Dateien lokal gefunden.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: localEcFiles.length,
                      itemBuilder: (_, i) {
                        final f = localEcFiles[i];
                        final chats = assignments[f] ?? [];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('📄 '),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(f,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontFamily: 'monospace'),
                                        overflow: TextOverflow.ellipsis),
                                    Text(
                                      chats.isEmpty
                                          ? '(frei – kein Chat zugeordnet)'
                                          : '→ ${chats.join(', ')}',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: chats.isEmpty
                                              ? Colors.grey
                                              : Colors.green.shade700),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),

                const Divider(height: 20),
                const Text(
                  'Aktionen:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),

                // ── Aktionen ──────────────────────────────────────────────
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dlgCtx).pop();
                    _copyKeyFilesToUSB();
                  },
                  icon: const Icon(Icons.copy, color: Colors.blue, size: 20),
                  label: const Text('📁➡️💾 Datei(en) auf USB-Stick kopieren'),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dlgCtx).pop();
                    _moveKeyFileToUSB();
                  },
                  icon: const Icon(Icons.drive_file_move,
                      color: Colors.orange, size: 20),
                  label: const Text('📁➡️💾 Datei auf USB-Stick verschieben'),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dlgCtx).pop();
                    _copyKeyFilesFromUSB();
                  },
                  icon: const Icon(Icons.copy, color: Colors.green, size: 20),
                  label: const Text('💾➡️📁 Datei(en) von USB-Stick kopieren'),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(dlgCtx).pop();
                    _secureDeleteKeyFile();
                  },
                  icon: const Icon(Icons.delete_forever,
                      color: Colors.red, size: 20),
                  label: const Text('🗑️ Datei sicher löschen'),
                  style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dlgCtx).pop(),
              child: const Text('Schließen'),
            ),
          ],
        );
      },
    );
  }

  // Kopiert mehrere .qgap_ec Schlüsseldateien auf den USB-Stick (Multi-Select)
  Future<void> _copyKeyFilesToUSB() async {
    try {
      final localFiles = (await _getLocalKeyFiles())
          .where((f) => f.endsWith('.qgap_ec'))
          .toList();

      if (localFiles.isEmpty) {
        _showInfoDialog('Keine Dateien', 'Keine lokalen .qgap_ec Dateien gefunden.');
        return;
      }

      final selectedFiles = await _showMultiFileSelectionDialog(
        'Dateien auf USB-Stick kopieren',
        localFiles,
        'Wähle die .qgap_ec Dateien, die auf den USB-Stick kopiert werden sollen:',
      );
      if (selectedFiles == null || selectedFiles.isEmpty) return;

      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }

      final usbPaths = await _getAvailableUSBPaths();
      if (usbPaths.isEmpty) {
        _showInfoDialog('USB-Stick nicht gefunden',
            'Kein USB-Stick angeschlossen oder nicht zugänglich.');
        return;
      }

      int successCount = 0;
      final List<String> errors = [];

      for (final fileName in selectedFiles) {
        final sourceFile = File(
            AppStorage.keyFilePath(fileName));
        if (!await sourceFile.exists()) {
          errors.add('$fileName: Quelldatei nicht gefunden');
          continue;
        }
        final sourceSize = await sourceFile.length();
        bool copied = false;
        for (final usbPath in usbPaths) {
          try {
            final usbKeyDir = Directory('$usbPath/Daten/QGap/schluessel');
            if (!await usbKeyDir.exists()) {
              await usbKeyDir.create(recursive: true);
            }
            final targetFile = File('${usbKeyDir.path}/$fileName');
            // Bytes explizit lesen+schreiben (File.copy liefert auf FUSE-USB 0 Bytes)
            final bytes = await sourceFile.readAsBytes();
            if (bytes.isEmpty) {
              errors.add('$fileName: Quelldatei ist leer ($sourceSize Bytes gelesen)');
              break;
            }
            await _writeFileReliable(targetFile, bytes);
            final writtenSize = bytes.length;
            successCount++;
            copied = true;
            developer.log(
                'log: ✅ $fileName auf USB kopiert ($writtenSize Bytes)',
                name: '_copyKeyFilesToUSB');
            break;
          } catch (e) {
            developer.log('log: ❌ Fehler $usbPath $fileName: $e',
                name: '_copyKeyFilesToUSB');
            errors.add('$fileName: $e');
          }
        }
        if (!copied && !errors.any((e) => e.startsWith(fileName))) {
          errors.add('$fileName: Kein beschreibbarer USB-Pfad gefunden');
        }
      }

      if (errors.isEmpty) {
        _showInfoDialog('Erfolgreich',
            '$successCount Datei(en) vollständig auf USB-Stick kopiert.');
      } else {
        _showInfoDialog(
          successCount > 0 ? 'Teilweise erfolgreich' : 'Fehler',
          '${successCount > 0 ? "$successCount Datei(en) kopiert.\n\n" : ""}Fehler:\n${errors.join('\n')}',
        );
      }
    } catch (e) {
      developer.log('log: Fehler _copyKeyFilesToUSB: $e',
          name: '_copyKeyFilesToUSB');
      _showInfoDialog('Fehler', 'Fehler beim Kopieren: $e');
    }
  }

  /// Schreibt Bytes zuverlässig via [RandomAccessFile] + fsync + close.
  /// Verhindert lautlose 0-Byte-Dateien auf FUSE/USB-OTG-Pfaden unter Android.
  /// [flush()] ruft fsync() auf → Daten werden physisch auf den Datenträger
  /// geschrieben, bevor der Dateideskriptor geschlossen wird.
  /// Anschließend wird die Datei zurückgelesen um sicherzustellen, dass
  /// die tatsächlichen Bytes auf dem Datenträger stehen – zuverlässiger als
  /// [File.length()], das auf FAT32/USB manchmal einen gecachten Wert liefert.
  Future<void> _writeFileReliable(File targetFile, List<int> bytes) async {
    final raf = await targetFile.open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.flush(); // fsync – erzwingt physisches Schreiben
    } finally {
      await raf.close(); // Dateideskriptor schließen
    }
    // Datei zurücklesen und Länge prüfen (zuverlässiger als targetFile.length()
    // auf FAT32/USB-OTG, wo der Verzeichniseintrag gecacht sein kann)
    final readBack = await targetFile.readAsBytes();
    if (readBack.length != bytes.length) {
      await targetFile.delete().catchError((_) => targetFile);
      throw Exception(
          'Schreibfehler: ${readBack.length} von ${bytes.length} Bytes '
          'auf dem Datenträger gelesen – Datei wurde gelöscht');
    }
  }

  // Kopiert eine Schlüsseldatei auf den USB-Stick (unused – über _copyEcFilesToUsb abgedeckt)
  // ignore: unused_element
  Future<void> _copyKeyFileToUSB() async {
    try {
      // Verfügbare lokale Schlüsseldateien auflisten
      List<String> localFiles = await _getLocalKeyFiles();
      
      if (localFiles.isEmpty) {
        _showInfoDialog('Keine Dateien', 'Es wurden keine lokalen Schlüsseldateien gefunden.');
        return;
      }
      
      // Datei-Auswahl-Dialog
      String? selectedFile = await _showFileSelectionDialog(
        'Schlüsseldatei für Kopierung auswählen', 
        localFiles,
        'Wählen Sie die Datei, die auf den USB-Stick kopiert werden soll:'
      );
      
      if (selectedFile == null) return;
      
      // Berechtigung anfordern
      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }
      
      // Quelldatei
      final sourceFile = File(AppStorage.keyFilePath(selectedFile));
      if (!await sourceFile.exists()) {
        _showInfoDialog('Fehler', 'Quelldatei nicht gefunden: $selectedFile');
        return;
      }
      
      // Auf alle verfügbaren USB-Mount-Punkte kopieren
      List<String> usbPaths = await _getAvailableUSBPaths();
      
      if (usbPaths.isEmpty) {
        _showInfoDialog('USB-Stick nicht gefunden', 'Kein USB-Stick angeschlossen oder nicht zugänglich.\n\nStellen Sie sicher, dass:\n- Ein USB-Stick angeschlossen ist\n- Der USB-Stick gemountet wurde\n- Die erforderlichen Berechtigungen erteilt wurden');
        return;
      }
      
      bool anySuccess = false;
      for (String usbPath in usbPaths) {
        try {
          final usbKeyDir = Directory('$usbPath/Daten/QGap/schluessel');
          if (!await usbKeyDir.exists()) {
            await usbKeyDir.create(recursive: true);
            developer.log('log: USB-Ordner erstellt: ${usbKeyDir.path}', name: '_copyKeyFileToUSB');
          }

          // Explizit bytes lesen und schreiben statt File.copy(),
          // da File.copy() auf FUSE-gemounteten USB-OTG-Pfaden
          // unter Android lautlos 0-Byte-Dateien erzeugt.
          final targetFile = File('${usbKeyDir.path}/$selectedFile');
          final bytes = await sourceFile.readAsBytes();
          await _writeFileReliable(targetFile, bytes);

          anySuccess = true;
          developer.log('log: ✅ Datei auf USB kopiert: ${targetFile.path} (${bytes.length} Bytes)', name: '_copyKeyFileToUSB');
          break; // Erfolgreich auf einen USB kopiert, weitere nicht nötig
        } catch (e) {
          developer.log('log: ❌ Fehler beim Kopieren auf $usbPath: $e', name: '_copyKeyFileToUSB');
        }
      }
      
      if (anySuccess) {
        _showInfoDialog('Erfolgreich', 'Schlüsseldatei "$selectedFile" wurde auf den USB-Stick kopiert.');
      } else {
        _showInfoDialog('Fehler', 'Kein USB-Stick gefunden oder nicht berechtigt. Stellen Sie sicher, dass ein USB-Stick angeschlossen ist.');
      }
      
    } catch (e) {
      developer.log('log: Fehler beim Kopieren auf USB: $e', name: '_copyKeyFileToUSB');
      _showInfoDialog('Fehler', 'Fehler beim Kopieren: $e');
    }
  }

  // Verschiebt eine Schlüsseldatei auf den USB-Stick
  Future<void> _moveKeyFileToUSB() async {
    try {
      // Verfügbare lokale Schlüsseldateien auflisten
      List<String> localFiles = await _getLocalKeyFiles();
      
      if (localFiles.isEmpty) {
        _showInfoDialog('Keine Dateien', 'Es wurden keine lokalen Schlüsseldateien gefunden.');
        return;
      }
      
      // Datei-Auswahl-Dialog
      String? selectedFile = await _showFileSelectionDialog(
        'Schlüsseldatei für Verschiebung auswählen', 
        localFiles,
        'ACHTUNG: Die Datei wird vom lokalen Gerät gelöscht!\n\nWählen Sie die Datei, die auf den USB-Stick verschoben werden soll:'
      );
      
      if (selectedFile == null) return;
      
      // Bestätigung
      bool? confirmed = await _showConfirmationDialog(
        'Datei verschieben?',
        'Die Datei "$selectedFile" wird vom lokalen Gerät gelöscht und auf den USB-Stick verschoben.\n\nSind Sie sicher?'
      );
      
      if (confirmed != true) return;
      
      // Berechtigung anfordern
      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }
      
      // Quelldatei
      final sourceFile = File(AppStorage.keyFilePath(selectedFile));
      if (!await sourceFile.exists()) {
        _showInfoDialog('Fehler', 'Quelldatei nicht gefunden: $selectedFile');
        return;
      }
      
      // Auf USB kopieren und dann lokal löschen
      List<String> usbPaths = await _getAvailableUSBPaths();
      
      if (usbPaths.isEmpty) {
        _showInfoDialog('USB-Stick nicht gefunden', 'Kein USB-Stick angeschlossen oder nicht zugänglich.');
        return;
      }
      
      bool copySuccess = false;
      for (String usbPath in usbPaths) {
        try {
          final usbKeyDir = Directory('$usbPath/Daten/QGap/schluessel');
          if (!await usbKeyDir.exists()) {
            await usbKeyDir.create(recursive: true);
          }

          // Explizit bytes lesen und schreiben statt File.copy(),
          // da File.copy() auf FUSE-gemounteten USB-OTG-Pfaden
          // unter Android lautlos 0-Byte-Dateien erzeugt.
          final targetFile = File('${usbKeyDir.path}/$selectedFile');
          final bytes = await sourceFile.readAsBytes();
          await _writeFileReliable(targetFile, bytes);

          copySuccess = true;
          developer.log('log: ✅ Datei auf USB kopiert: ${targetFile.path} (${bytes.length} Bytes)', name: '_moveKeyFileToUSB');
          break; // Nur auf einen USB-Pfad kopieren
        } catch (e) {
          developer.log('log: ❌ Fehler beim Kopieren auf $usbPath: $e', name: '_moveKeyFileToUSB');
        }
      }
      
      if (copySuccess) {
        // Lokale Datei löschen
        await sourceFile.delete();
        developer.log('log: ✅ Lokale Datei gelöscht: ${sourceFile.path}', name: '_moveKeyFileToUSB');
        _showInfoDialog('Erfolgreich', 'Schlüsseldatei "$selectedFile" wurde auf den USB-Stick verschoben.');
      } else {
        _showInfoDialog('Fehler', 'Kein USB-Stick gefunden oder nicht berechtigt. Datei wurde nicht verschoben.');
      }
      
    } catch (e) {
      developer.log('log: Fehler beim Verschieben auf USB: $e', name: '_moveKeyFileToUSB');
      _showInfoDialog('Fehler', 'Fehler beim Verschieben: $e');
    }
  }

  // Kopiert mehrere .qgap_ec Dateien vom USB-Stick (Multi-Select)
  Future<void> _copyKeyFilesFromUSB() async {
    try {
      final usbFiles = (await _getUSBKeyFiles())
          .where((f) => f.endsWith('.qgap_ec'))
          .toList();

      if (usbFiles.isEmpty) {
        _showInfoDialog('Keine Dateien',
            'Keine .qgap_ec Dateien auf dem USB-Stick gefunden.');
        return;
      }

      final selectedFiles = await _showMultiFileSelectionDialog(
        'Dateien von USB-Stick kopieren',
        usbFiles,
        'Wähle die .qgap_ec Dateien, die vom USB-Stick kopiert werden sollen:',
      );
      if (selectedFiles == null || selectedFiles.isEmpty) return;

      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }

      final usbPaths = await _getAvailableUSBPaths();
      final localDir = Directory(AppStorage.schluesselDir);
      if (!await localDir.exists()) await localDir.create(recursive: true);

      int successCount = 0;
      final List<String> errors = [];

      for (final fileName in selectedFiles) {
        File? sourceFile;
        for (final usbPath in usbPaths) {
          final testFile = File('$usbPath/Daten/QGap/schluessel/$fileName');
          if (await testFile.exists()) {
            sourceFile = testFile;
            break;
          }
        }
        if (sourceFile == null) {
          errors.add('$fileName: Quelldatei auf USB nicht gefunden');
          continue;
        }
        final targetFile =
            File(AppStorage.keyFilePath(fileName));
        try {
          final bytes = await sourceFile.readAsBytes();
          if (bytes.isEmpty) {
            errors.add('$fileName: USB-Datei ist leer');
            continue;
          }
          await _writeFileReliable(targetFile, bytes);
          await EcProvenanceService.markUsbImport(fileName);
          successCount++;
          developer.log('log: ✅ $fileName von USB kopiert (${bytes.length} Bytes)',
              name: '_copyKeyFilesFromUSB');
        } catch (e) {
          developer.log('log: ❌ Fehler bei $fileName: $e',
              name: '_copyKeyFilesFromUSB');
          errors.add('$fileName: $e');
        }
      }

      if (errors.isEmpty) {
        _showInfoDialog('Erfolgreich',
            '$successCount Datei(en) vollständig vom USB-Stick kopiert.');
      } else {
        _showInfoDialog(
          successCount > 0 ? 'Teilweise erfolgreich' : 'Fehler',
          '${successCount > 0 ? "$successCount Datei(en) kopiert.\n\n" : ""}Fehler:\n${errors.join('\n')}',
        );
      }
    } catch (e) {
      developer.log('log: Fehler _copyKeyFilesFromUSB: $e',
          name: '_copyKeyFilesFromUSB');
      _showInfoDialog('Fehler', 'Fehler beim Kopieren: $e');
    }
  }

  // Kopiert eine Schlüsseldatei vom USB-Stick (unused – über _importEcFromUsbAndAssign abgedeckt)
  // ignore: unused_element
  Future<void> _copyKeyFileFromUSB() async {
    try {
      // Verfügbare USB-Schlüsseldateien auflisten
      List<String> usbFiles = await _getUSBKeyFiles();
      
      if (usbFiles.isEmpty) {
        _showInfoDialog('Keine Dateien', 'Es wurden keine Schlüsseldateien auf dem USB-Stick gefunden.');
        return;
      }
      
      // Datei-Auswahl-Dialog
      String? selectedFile = await _showFileSelectionDialog(
        'Schlüsseldatei vom USB-Stick auswählen', 
        usbFiles,
        'Wählen Sie die Datei, die vom USB-Stick kopiert werden soll:'
      );
      
      if (selectedFile == null) return;
      
      // Berechtigung anfordern
      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }
      
      // USB-Quelldatei finden mit dynamischen Pfaden
      File? sourceFile;
      List<String> usbPaths = await _getAvailableUSBPaths();
      
      for (String usbPath in usbPaths) {
        final testFile = File('$usbPath/Daten/QGap/schluessel/$selectedFile');
        if (await testFile.exists()) {
          sourceFile = testFile;
          developer.log('log: USB-Quelldatei gefunden: ${testFile.path}', name: '_copyKeyFileFromUSB');
          break;
        }
      }
      
      if (sourceFile == null) {
        _showInfoDialog('Fehler', 'Quelldatei auf USB-Stick nicht gefunden: $selectedFile');
        return;
      }
      
      // Lokales Verzeichnis erstellen
      final localDir = Directory(AppStorage.schluesselDir);
      if (!await localDir.exists()) {
        await localDir.create(recursive: true);
      }
      
      // Zieldatei
      final targetFile = File(AppStorage.keyFilePath(selectedFile));
      
      // Prüfen ob Datei bereits existiert
      if (await targetFile.exists()) {
        bool? overwrite = await _showConfirmationDialog(
          'Datei überschreiben?',
          'Die Datei "$selectedFile" existiert bereits lokal.\n\nÜberschreiben?'
        );
        if (overwrite != true) return;
      }
      
      // Kopieren via RandomAccessFile (File.copy kann 0-Byte-Dateien erzeugen)
      final bytes = await sourceFile.readAsBytes();
      if (bytes.isEmpty) {
        _showInfoDialog('Fehler', 'Quelldatei auf USB-Stick ist leer: $selectedFile');
        return;
      }
      await _writeFileReliable(targetFile, bytes);
      developer.log('log: ✅ Datei von USB kopiert: ${targetFile.path} (${bytes.length} Bytes)', name: '_copyKeyFileFromUSB');
      
      _showInfoDialog('Erfolgreich', 'Schlüsseldatei "$selectedFile" wurde vom USB-Stick kopiert.');
      
    } catch (e) {
      developer.log('log: Fehler beim Kopieren von USB: $e', name: '_copyKeyFileFromUSB');
      _showInfoDialog('Fehler', 'Fehler beim Kopieren: $e');
    }
  }

  // Sicheres Löschen mehrerer .qgap_ec Schlüsseldateien (Multi-Select)
  Future<void> _secureDeleteKeyFile() async {
    try {
      // Nur .qgap_ec-Dateien (lokal + USB), dedupliziert
      final localEcFiles = (await _getLocalKeyFiles())
          .where((f) => f.endsWith('.qgap_ec'))
          .toList();
      final usbEcFiles = (await _getUSBKeyFiles())
          .where((f) => f.endsWith('.qgap_ec'))
          .toList();
      final allFiles = {...localEcFiles, ...usbEcFiles}.toList()..sort();

      if (allFiles.isEmpty) {
        _showInfoDialog('Keine Dateien', 'Keine .qgap_ec Dateien gefunden.');
        return;
      }

      // Multi-Select
      final selectedFiles = await _showMultiFileSelectionDialog(
        '🗑️ Dateien sicher löschen',
        allFiles,
        '⚠️ WARNUNG: Diese Aktion kann nicht rückgängig gemacht werden!\n\n'
        'Dateien werden lokal UND auf allen erkannten USB-Speichern gelöscht.',
      );
      if (selectedFiles == null || selectedFiles.isEmpty) return;

      // Einmalige Bestätigung für alle ausgewählten Dateien
      final confirmed = await _showConfirmationDialog(
        '${selectedFiles.length} Datei(en) löschen?',
        '${selectedFiles.map((f) => '• $f').join('\n')}\n\n'
        'Diese Dateien werden PERMANENT gelöscht.\nSind Sie sicher?',
      );
      if (confirmed != true) return;

      if (!await _requestStoragePermission()) {
        _showInfoDialog('Berechtigung', 'Speicher-Berechtigung erforderlich.');
        return;
      }

      final List<String> localBasePaths = [
        '${AppStorage.schluesselDir}/',
        '/sdcard/Daten/QGap/schluessel/',
      ];
      final usbPaths = await _getAvailableUSBPaths();
      final List<String> allPaths = [
        ...localBasePaths,
        ...usbPaths.map((p) => '$p/Daten/QGap/schluessel/'),
      ];

      int successCount = 0;
      final List<String> errors = [];

      for (final fileName in selectedFiles) {
        bool anyDeleted = false;
        for (final basePath in allPaths) {
          final file = File('$basePath$fileName');
          if (await file.exists()) {
            try {
              await file.delete();
              anyDeleted = true;
              developer.log('log: ✅ Gelöscht: $basePath$fileName',
                  name: '_secureDeleteKeyFile');
            } catch (e) {
              developer.log('log: ❌ Löschen fehlgeschlagen: $basePath$fileName: $e',
                  name: '_secureDeleteKeyFile');
              errors.add('$fileName: $e');
            }
          }
        }
        if (anyDeleted) {
          successCount++;
        } else if (!errors.any((e) => e.startsWith(fileName))) {
          errors.add('$fileName: Datei nicht gefunden');
        }
      }

      if (errors.isEmpty) {
        _showInfoDialog('Erfolgreich',
            '$successCount Datei(en) sicher gelöscht.');
      } else {
        _showInfoDialog(
          successCount > 0 ? 'Teilweise erfolgreich' : 'Fehler',
          '${successCount > 0 ? "$successCount Datei(en) gelöscht.\n\n" : ""}Fehler:\n${errors.join('\n')}',
        );
      }
    } catch (e) {
      developer.log('log: Fehler beim sicheren Löschen: $e',
          name: '_secureDeleteKeyFile');
      _showInfoDialog('Fehler', 'Fehler beim Löschen: $e');
    }
  }

  // Debug-Funktion zur USB-Erkennung
  void _showUSBDebugInfo() async {
    // Berechtigung zuerst anfordern
    if (!await _requestStoragePermission()) {
      _showInfoDialog('Berechtigung erforderlich', 'Speicher-Berechtigung ist erforderlich für die USB-Debug-Analyse.');
      return;
    }
    
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('🔍 USB-Speicher Debug'),
          content: FutureBuilder<Map<String, dynamic>>(
            future: _getUSBDebugData(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Analysiere USB-Speicher...'),
                  ],
                );
              }
              
              if (snapshot.hasError) {
                return Text('Fehler: ${snapshot.error}');
              }
              
              final data = snapshot.data!;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('📊 Gefundene USB-Pfade: ${data['usbPaths'].length}'),
                    const SizedBox(height: 8),
                    ...((data['usbPaths'] as List<String>).map((path) => 
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('✅ $path', style: const TextStyle(color: Colors.green, fontSize: 12)),
                      )
                    )),
                    const SizedBox(height: 16),
                    Text('📂 Storage-Verzeichnisse: ${data['storageEntries'].length}'),
                    const SizedBox(height: 8),
                    ...((data['storageEntries'] as List<String>).map((entry) => 
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('📁 $entry', style: const TextStyle(fontSize: 12)),
                      )
                    )),
                    const SizedBox(height: 16),
                    Text('💾 Media_rw-Verzeichnisse: ${data['mediaRwEntries'].length}'),
                    const SizedBox(height: 8),
                    ...((data['mediaRwEntries'] as List<String>).map((entry) => 
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('💾 $entry', style: const TextStyle(fontSize: 12)),
                      )
                    )),
                    const SizedBox(height: 16),
                    Text('🔍 USB-Dateien gefunden: ${data['usbFiles'].length}'),
                    const SizedBox(height: 8),
                    ...((data['usbFiles'] as List<String>).map((file) => 
                      Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text('📄 $file', style: const TextStyle(color: Colors.blue, fontSize: 12)),
                      )
                    )),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _coupleUsbSaf();
              },
              icon: const Icon(Icons.usb, color: Colors.blue),
              label: const Text('USB koppeln'),
            ),
            TextButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _uncoupleUsbSaf();
              },
              icon: const Icon(Icons.link_off, color: Colors.orange),
              label: const Text('Lösen'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Schließen'),
            ),
          ],
        );
      },
    );
  }

  /// Öffnet den System-Picker (ACTION_OPEN_DOCUMENT_TREE), damit der User
  /// den USB-Stick als beschreibbares Volume freigibt.
  /// Wechselt den Basis-Speicherort ([customRoot] = null → Standard) und
  /// bietet an, die vorhandenen Dateien ins neue Ziel mitzunehmen.
  Future<void> _switchStorageRoot(String? customRoot) async {
    final oldRoot = AppStorage.root;
    final newRoot = customRoot ?? AppStorage.defaultRoot;
    if (newRoot == oldRoot) return;

    bool copyFiles = false;
    if (await Directory(oldRoot).exists()) {
      if (!mounted) return;
      final answer = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Dateien mitnehmen?'),
          content: Text(
            'Sollen die vorhandenen Dateien\n\n$oldRoot\n\n'
            'in den neuen Ordner\n\n$newRoot\n\nkopiert werden?\n\n'
            '(Vorhandene Ziel-Dateien werden nicht überschrieben; '
            'die Originale bleiben am alten Ort erhalten.)',
            style: const TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Nur wechseln'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.drive_file_move, size: 18),
              label: const Text('Kopieren & wechseln'),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (answer == null) return; // abgebrochen
      copyFiles = answer;
    }

    if (copyFiles) {
      final (copied, skipped) =
          await AppStorage.copyContents(oldRoot, newRoot);
      if (mounted) {
        showQgapSnackBar(context, SnackBar(
          content: Text('✅ $copied Datei(en) kopiert'
              '${skipped > 0 ? ', $skipped übersprungen' : ''}'),
          backgroundColor: Colors.green,
        ));
      }
    }
    await AppStorage.setCustomRoot(customRoot);
  }

  /// Einstellung: Basis-Speicherort der QGap-Dateien ändern
  /// (z. B. USB-Stick, Netzlaufwerk, andere Partition).
  Future<void> _showStorageLocationDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.folder_outlined, color: Colors.blueGrey),
              SizedBox(width: 8),
              Expanded(child: Text('Speicherort')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Aktueller Ordner:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              SelectableText(AppStorage.root,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              Text('Standard: ${AppStorage.defaultRoot}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              const Text(
                'Hinweis: Bereits vorhandene Dateien werden nicht automatisch '
                'verschoben. Ein gewählter USB-Stick bzw. ein Netzlaufwerk '
                'muss beim App-Start verfügbar sein.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
            ],
          ),
          actions: [
            if (AppStorage.isCustomRoot)
              TextButton(
                onPressed: () async {
                  await _switchStorageRoot(null);
                  setDlgState(() {});
                },
                child: const Text('Standard wiederherstellen'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Schließen'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Ordner wählen …'),
              onPressed: () async {
                try {
                  final picked = await FilePicker.platform.getDirectoryPath(
                    dialogTitle: 'Basisordner für QGap-Dateien wählen',
                  );
                  if (picked == null || picked.isEmpty) return;
                  // Unterordner "qgap" anhängen, außer der Ordner heißt schon so
                  final norm = picked.replaceAll('\\', '/');
                  final newRoot = norm.toLowerCase().endsWith('/QGap') ||
                          norm.toLowerCase().endsWith('qgap')
                      ? norm
                      : '$norm/QGap';
                  await _switchStorageRoot(newRoot);
                  setDlgState(() {});
                } catch (e) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Ordnerwahl fehlgeschlagen: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _coupleUsbSaf() async {
    try {
      final picked = await UsbSafService.pickUsbTreeUri();
      if (!mounted) return;
      if (picked == null || picked.isEmpty) {
        showQgapSnackBar(context,
          const SnackBar(content: Text('USB-Auswahl abgebrochen.')),
        );
        return;
      }
      showQgapSnackBar(context,
        SnackBar(
          content: Text('✅ USB-Stick gekoppelt:\n$picked'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context,
        SnackBar(content: Text('USB-Auswahl fehlgeschlagen: $e')),
      );
    }
  }

  /// Entfernt die persistierte Tree-URI.
  Future<void> _uncoupleUsbSaf() async {
    try {
      await UsbSafService.clearUsbTreeUri();
      if (!mounted) return;
      showQgapSnackBar(context,
        const SnackBar(content: Text('USB-Kopplung gelöst.')),
      );
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context,
        SnackBar(content: Text('Fehler beim Lösen der Kopplung: $e')),
      );
    }
  }

  // Sammelt Debug-Daten über USB-Speicher
  Future<Map<String, dynamic>> _getUSBDebugData() async {
    List<String> usbPaths = [];
    List<String> usbFiles = [];
    List<String> storageEntries = [];
    List<String> mediaRwEntries = [];
    
    try {
      usbPaths = await _getAvailableUSBPaths();
      usbFiles = await _getUSBKeyFiles();
    } catch (e) {
      developer.log('log: Fehler bei USB-Pfad-Analyse: $e', name: '_getUSBDebugData');
    }
    
    // Erweiterte Pfad-Analyse: Teste mehr mögliche USB-Speicherorte
    try {
      // Teste alle wichtigen Mount-Punkte
      List<String> testPaths = [
        '/storage/usbotg',
        '/mnt/usb', 
        '/storage/usb',
        '/mnt/usbstorage',
        '/storage/emulated/0',
        '/storage/extSdCard',
        '/storage/sdcard1',
        '/mnt/media_rw'
      ];
      
      for (String testPath in testPaths) {
        try {
          final dir = Directory(testPath);
          bool exists = await dir.exists();
          if (exists) {
            storageEntries.add('✅ $testPath (verfügbar)');
            
            // Teste Schreibzugriff detaillierter
            try {
              final testFile = File('$testPath/.test_write_${DateTime.now().millisecondsSinceEpoch}.tmp');
              await testFile.writeAsString('test');
              final content = await testFile.readAsString();
              await testFile.delete();
              
              if (content == 'test') {
                storageEntries.add('   └─ Schreibzugriff: ✅ VOLLSTÄNDIG');
              } else {
                storageEntries.add('   └─ Schreibzugriff: ⚠️ TEILWEISE');
              }
            } catch (e) {
              storageEntries.add('   └─ Schreibzugriff: ❌ VERWEIGERT (${e.toString().split(':').first})');
            }
            
            // Teste ob es ein USB-Gerät ist (nicht interner Speicher)
            if (!testPath.contains('emulated') && !testPath.contains('obb')) {
              storageEntries.add('   └─ Typ: 📱 Wahrscheinlich EXTERNER Speicher');
            } else {
              storageEntries.add('   └─ Typ: 🏠 Interner Speicher');
            }
            
          } else {
            storageEntries.add('❌ $testPath (nicht vorhanden)');
          }
        } catch (e) {
          storageEntries.add('⚠️ $testPath (Zugriffsfehler: ${e.toString().substring(0, 30)}...)');
        }
      }
      
    } catch (e) {
      storageEntries.add('Allgemeiner Fehler bei Pfad-Tests: $e');
      developer.log('log: Fehler beim Testen der Pfade: $e', name: '_getUSBDebugData');
    }
    
    // Erweiterte Berechtigungsanalyse
    try {
      mediaRwEntries.add('🔐 Detaillierte Berechtigungsanalyse:');
      
      // Prüfe manageExternalStorage
      try {
        final manageStatus = await Permission.manageExternalStorage.status;
        String statusText = '';
        switch (manageStatus) {
          case PermissionStatus.granted:
            statusText = '✅ ERTEILT';
            break;
          case PermissionStatus.denied:
            statusText = '❌ VERWEIGERT';
            break;
          case PermissionStatus.permanentlyDenied:
            statusText = '🚫 DAUERHAFT VERWEIGERT';
            break;
          default:
            statusText = '⚠️ ${manageStatus.name}';
        }
        mediaRwEntries.add('   └─ manageExternalStorage: $statusText');
      } catch (e) {
        mediaRwEntries.add('   └─ manageExternalStorage: ❌ Fehler ($e)');
      }
      
      // Prüfe storage
      try {
        final storageStatus = await Permission.storage.status;
        String statusText = '';
        switch (storageStatus) {
          case PermissionStatus.granted:
            statusText = '✅ ERTEILT';
            break;
          case PermissionStatus.denied:
            statusText = '❌ VERWEIGERT';
            break;
          case PermissionStatus.permanentlyDenied:
            statusText = '🚫 DAUERHAFT VERWEIGERT';
            break;
          default:
            statusText = '⚠️ ${storageStatus.name}';
        }
        mediaRwEntries.add('   └─ storage: $statusText');
      } catch (e) {
        mediaRwEntries.add('   └─ storage: ❌ Fehler ($e)');
      }
      
      // Android-Version Info
      mediaRwEntries.add('');
      mediaRwEntries.add('📱 System-Info:');
      mediaRwEntries.add('   └─ Plattform: Android');
      mediaRwEntries.add('   └─ USB-Erkennungsalgorithmus: Erweitert v2.0');

      // ── SAF-Status (Storage Access Framework) ────────────────────────────
      mediaRwEntries.add('');
      mediaRwEntries.add('🗂️ SAF (Storage Access Framework):');
      try {
        final safUri = await UsbSafService.getPersistedUsbTreeUri();
        if (safUri == null || safUri.isEmpty) {
          mediaRwEntries.add('   └─ USB-Stick: ❌ NICHT gekoppelt');
          mediaRwEntries.add('   └─ Aktion: Button „USB koppeln" unten antippen');
        } else {
          mediaRwEntries.add('   └─ USB-Stick: ✅ gekoppelt');
          mediaRwEntries.add('   └─ Tree-Uri: $safUri');
          // Probelisting im QGap-Schlüsselordner
          try {
            final files = await UsbSafService.listUsbDir(
                subPath: 'Daten/QGap/schluessel', suffix: '.qgap_ec');
            mediaRwEntries.add('   └─ .qgap_ec auf Stick: ${files.length}');
            for (final f in files.take(8)) {
              mediaRwEntries.add('       • ${f.name} (${f.size} B)');
            }
            if (files.length > 8) {
              mediaRwEntries.add('       … +${files.length - 8} weitere');
            }
          } catch (e) {
            mediaRwEntries.add('   └─ Probelisting fehlgeschlagen: $e');
          }
        }
      } catch (e) {
        mediaRwEntries.add('   └─ SAF-Status nicht abrufbar: $e');
      }
    } catch (e) {
      mediaRwEntries.add('Fehler bei Berechtigungscheck: $e');
      developer.log('log: Fehler bei Berechtigungscheck: $e', name: '_getUSBDebugData');
    }
    
    return {
      'usbPaths': usbPaths,
      'usbFiles': usbFiles,
      'storageEntries': storageEntries,
      'mediaRwEntries': mediaRwEntries,
    };
  }

  // Hilfsfunktionen
  
  // Listet lokale Schlüsseldateien auf
  Future<List<String>> _getLocalKeyFiles() async {
    List<String> files = [];
    
    List<String> localPaths = [
      '${AppStorage.schluesselDir}/',
      '/sdcard/Daten/QGap/schluessel/',
    ];
    
    for (String path in localPaths) {
      try {
        final dir = Directory(path);
        if (await dir.exists()) {
          await for (FileSystemEntity entity in dir.list()) {
            if (entity is File && entity.path.contains('.qgap')) {
              String fileName = AppStorage.fileNameOf(entity.path);
              if (!files.contains(fileName)) {
                files.add(fileName);
              }
            }
          }
        }
      } catch (e) {
        developer.log('log: Fehler beim Auflisten von $path: $e', name: '_getLocalKeyFiles');
      }
    }
    
    return files;
  }

  // Listet USB-Schlüsseldateien auf mit verbesserter USB-Erkennung
  Future<List<String>> _getUSBKeyFiles() async {
    List<String> files = [];
    
    // Verfügbare USB-Speicherpfade dynamisch ermitteln
    List<String> usbPaths = await _getAvailableUSBPaths();
    
    for (String path in usbPaths) {
      try {
        final keyDir = Directory('$path/Daten/QGap/schluessel');
        if (await keyDir.exists()) {
          await for (FileSystemEntity entity in keyDir.list()) {
            if (entity is File &&
                (entity.path.endsWith('.qgap_ec') ||
                    entity.path.endsWith('.qgap'))) {
              String fileName = AppStorage.fileNameOf(entity.path);
              if (!files.contains(fileName)) {
                files.add(fileName);
                developer.log('log: ✅ USB-Datei gefunden: $fileName in $path', name: '_getUSBKeyFiles');
              }
            }
          }
        } else {
          developer.log('log: USB-Schlüssel-Ordner existiert nicht: $keyDir', name: '_getUSBKeyFiles');
        }
      } catch (e) {
        developer.log('log: Fehler beim Auflisten von USB $path: $e', name: '_getUSBKeyFiles');
      }
    }
    
    return files;
  }

  // Ermittelt verfügbare USB-Speicherpfade dynamisch
  Future<List<String>> _getAvailableUSBPaths() async {
    // Windows: Wechseldatenträger (USB-Sticks) via PowerShell ermitteln
    if (Platform.isWindows) {
      try {
        final res = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          r"Get-Volume | Where-Object {$_.DriveType -eq 'Removable' -and $_.DriveLetter} | Select-Object -ExpandProperty DriveLetter",
        ]);
        final drives = (res.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .map((l) => '$l:')
            .toList();
        developer.log('log: Windows-USB-Laufwerke: $drives',
            name: '_getAvailableUSBPaths');
        return drives;
      } catch (e) {
        developer.log('log: Windows-USB-Erkennung fehlgeschlagen: $e',
            name: '_getAvailableUSBPaths');
        return [];
      }
    }
    // iOS: kein direkter USB-Zugriff → Import/Export läuft über die Dateien-App
    if (!Platform.isAndroid) return [];

    List<String> candidatePaths = [];

    // Methode 1 (primär): Nativer Platform Channel → StorageManager.getStorageVolumes()
    // Liefert zuverlässig alle Volumes inkl. USB OTG auch auf Samsung/SELinux
    try {
      const storageChannel =
          MethodChannel('de.paulporg.obmc/storage');
      final List<dynamic>? nativeVolumes =
          await storageChannel.invokeMethod<List<dynamic>>('getStorageVolumes');
      if (nativeVolumes != null) {
        for (final v in nativeVolumes) {
          final path = v as String;
          // Internen Speicher ausschließen
          if (!path.contains('/emulated') && !candidatePaths.contains(path)) {
            candidatePaths.add(path);
            developer.log('log: StorageManager USB-Volume: $path',
                name: '_getAvailableUSBPaths');
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler bei nativem getStorageVolumes: $e',
          name: '_getAvailableUSBPaths');
    }

    // Methode 2 (Fallback): Statische + dynamische Pfade
    List<String> fallbackPaths = [
      '/storage/usbotg',
      '/mnt/usb',
      '/storage/usb',
      '/mnt/usbstorage',
      '/storage/usb1',
      '/storage/usb2',
      '/storage/extSdCard',
      '/storage/external_sd',
      '/storage/sdcard1',
      '/storage/external',
      '/storage/udisk',
      '/storage/external_usb',
      '/mnt/media_rw/usbotg',
      '/mnt/ext_sd',
    ];

    // Dynamische Suche via /storage/ und /mnt/media_rw/
    try {
      final storageDir = Directory('/storage');
      if (await storageDir.exists()) {
        await for (final entity in storageDir.list()) {
          if (entity is Directory) {
            final name = entity.path.split('/').last;
            if (name != 'emulated' && name != 'self' && !name.startsWith('.')) {
              if (!fallbackPaths.contains(entity.path)) {
                fallbackPaths.add(entity.path);
              }
            }
          }
        }
      }
      final mediaRwDir = Directory('/mnt/media_rw');
      if (await mediaRwDir.exists()) {
        await for (final entity in mediaRwDir.list()) {
          if (entity is Directory) {
            if (!fallbackPaths.contains(entity.path)) {
              fallbackPaths.add(entity.path);
            }
          }
        }
      }
    } catch (e) {
      developer.log('log: Fehler bei dynamischem USB-Scan: $e',
          name: '_getAvailableUSBPaths');
    }

    // Fallback-Pfade hinzufügen die noch nicht via StorageManager gefunden wurden
    for (final path in fallbackPaths) {
      if (!candidatePaths.contains(path)) {
        candidatePaths.add(path);
      }
    }

    // Teste alle Kandidaten auf Existenz
    List<String> availablePaths = [];
    List<Future<String?>> tests = candidatePaths.map((path) async {
      try {
        final dir = Directory(path);
        if (await dir.exists() &&
            !path.contains('emulated') &&
            !path.contains('obb')) {
          try {
            final testDir = Directory(
                '$path/.usb_test_${DateTime.now().millisecondsSinceEpoch}');
            await testDir.create();
            await testDir.delete();
            developer.log('log: ✅ USB-Pfad beschreibbar: $path',
                name: '_getAvailableUSBPaths');
            return path;
          } catch (_) {
            developer.log('log: ⚠️ USB-Pfad schreibgeschützt: $path',
                name: '_getAvailableUSBPaths');
            return path;
          }
        }
        return null;
      } catch (_) {
        return null;
      }
    }).toList();

    try {
      final results = await Future.wait(tests, eagerError: false);
      for (final result in results) {
        if (result != null && !availablePaths.contains(result)) {
          availablePaths.add(result);
        }
      }
    } catch (e) {
      developer.log('log: Fehler bei USB-Tests: $e',
          name: '_getAvailableUSBPaths');
    }

    developer.log(
        'log: Gefundene USB-Pfade: ${availablePaths.length} -> $availablePaths',
        name: '_getAvailableUSBPaths');
    return availablePaths;
  }

  // Datei-Auswahl-Dialog
  Future<String?> _showFileSelectionDialog(String title, List<String> files, String description) async {
    return await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        String? selectedFile = files.isNotEmpty ? files.first : null;
        
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(description),
                  const SizedBox(height: 16),
                  if (files.isNotEmpty) ...[
                    const Text('Verfügbare Dateien:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      value: selectedFile,
                      isExpanded: true,
                      items: files.map((String fileName) {
                        return DropdownMenuItem<String>(
                          value: fileName,
                          child: Text(fileName),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setDialogState(() {
                          selectedFile = newValue;
                        });
                      },
                    ),
                  ] else ...[
                    const Text('Keine Dateien gefunden.', style: TextStyle(color: Colors.grey)),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Abbrechen'),
                ),
                if (files.isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(selectedFile),
                    child: const Text('Auswählen'),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  /// Multi-Auswahl-Dialog: Gibt die ausgewählten Dateinamen zurück (oder null bei Abbruch).
  Future<List<String>?> _showMultiFileSelectionDialog(
      String title, List<String> files, String description) async {
    if (files.isEmpty) return null;
    final Set<String> selected = {files.first};
    return await showDialog<List<String>>(
      context: context,
      builder: (BuildContext dlgCtx) {
        return StatefulBuilder(builder: (dlgCtx, setDialogState) {
          return AlertDialog(
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const SizedBox(height: 12),
                const Text('Dateien auswählen:',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView(
                    shrinkWrap: true,
                    children: files
                        .map((f) => CheckboxListTile(
                              dense: true,
                              title: Text(f,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
                              value: selected.contains(f),
                              onChanged: (v) => setDialogState(() {
                                if (v == true) {
                                  selected.add(f);
                                } else {
                                  selected.remove(f);
                                }
                              }),
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dlgCtx).pop(null),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(dlgCtx).pop(selected.toList()),
                child: const Text('Löschen'),
              ),
            ],
          );
        });
      },
    );
  }

  // Bestätigungs-Dialog
  Future<bool?> _showConfirmationDialog(String title, String message) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Abbrechen'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(
                backgroundColor: Colors.red.shade50,
              ),
              child: const Text('Bestätigen', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  // Info-Dialog
  void _showInfoDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  // Speicher-Berechtigung anfordern
  Future<bool> _requestStoragePermission() async {
    if (!Platform.isAndroid) return true; // iOS/Windows: kein Storage-Permission-Modell nötig
    try {
      PermissionStatus status = await Permission.manageExternalStorage.request();
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      return status.isGranted;
    } catch (e) {
      try {
        PermissionStatus status = await Permission.storage.request();
        return status.isGranted;
      } catch (e2) {
        developer.log('log: Fehler bei Berechtigung: $e2', name: '_requestStoragePermission');
        return false;
      }
    }
  }

  // Dialog zur RSA-Schlüsselverwaltung
  void _showRSAKeyManagement() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.vpn_key, color: Colors.blue),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '🔐 RSA-Schlüsselverwaltung',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
              content: LayoutBuilder(
                builder: (context, constraints) {
                  final maxHeight = MediaQuery.of(context).size.height * 0.6;
                  return ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth,
                      maxHeight: maxHeight,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                    Text(
                      _rsaKeysInitialized 
                        ? '✅ RSA-Schlüsselpaar ist initialisiert'
                        : '⏳ RSA-Schlüssel werden initialisiert...',
                      style: TextStyle(
                        color: _rsaKeysInitialized ? Colors.green : Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (_rsaKeysInitialized) ...[
                      const SizedBox(height: 16),
                      
                      // Öffentlicher Schlüssel Fingerprint
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Ihr öffentlicher Schlüssel-Fingerprint:',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _rsaKeyManager.getMyPublicKeyFingerprint() ?? 'Fehler beim Laden',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Aktionen
                      ListTile(
                        leading: const Icon(Icons.qr_code, color: Colors.blue),
                        title: const Text('Öffentlichen Schlüssel teilen'),
                        subtitle: const Text('QR-Code für andere anzeigen'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _showPublicKeyExport();
                        },
                      ),
                      
                      ListTile(
                        leading: const Icon(Icons.qr_code_scanner, color: Colors.green),
                        title: const Text('Öffentlichen Schlüssel importieren'),
                        subtitle: const Text('QR-Code scannen'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _showImportPublicKey();
                        },
                      ),
                      
                      ListTile(
                        leading: const Icon(Icons.people, color: Colors.orange),
                        title: const Text('Gespeicherte Kontakte'),
                        subtitle: const Text('Verwaltung der Kontakt-Schlüssel'),
                        onTap: () {
                          Navigator.of(context).pop();
                          _showContactKeyManagement();
                        },
                      ),
                      
                      ListTile(
                        leading: const Icon(Icons.refresh, color: Colors.red),
                        title: const Text('Neues Schlüsselpaar generieren'),
                        subtitle: const Text(
                          'Vorsicht: Alle alten Nachrichten nicht mehr entschlüsselbar',
                          softWrap: true,
                        ),
                        onTap: () async {
                          final confirmed = await _showConfirmationDialog(
                            'Neues Schlüsselpaar generieren?',
                            'Dies wird das aktuelle Schlüsselpaar ersetzen. Alle alten RSA-verschlüsselten Nachrichten können dann nicht mehr entschlüsselt werden.\n\nFortfahren?',
                          );
                          if (confirmed == true) {
                            await _rsaKeyManager.generateAndSaveKeyPair();
                            setState(() {});
                            if (context.mounted) {
                              Navigator.of(context).pop();
                              showQgapSnackBar(context, 
                                const SnackBar(
                                  content: Text('✅ Neues RSA-Schlüsselpaar generiert'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          }
                        },
                      ),
                        ],
                        ],
                      ),
                    ),
                  );
                },
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
      },
    );
  }

  // Dialog zum Exportieren des öffentlichen Schlüssels
  void _showPublicKeyExport() async {
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

    if (!mounted) return;

    // Exportart wählen
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.share, color: Colors.blue),
            SizedBox(width: 8),
            Text('Öffentlichen Schlüssel teilen'),
          ],
        ),
        content: const Text(
          'Wie soll der eigene öffentliche RSA-Schlüssel geteilt werden?'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('Per QR-Code'),
            onPressed: () => Navigator.of(ctx).pop('qr'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.attach_file),
            label: const Text('Als .qgap_aes Datei'),
            onPressed: () => Navigator.of(ctx).pop('file'),
          ),
        ],
      ),
    );

    if (choice == null || !mounted) return;

    if (choice == 'qr') {
      final payload = Uint8List.fromList(utf8.encode('QGAP_RSA_PUB:$pubKeyString'));
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => QrDataSender(bytes: payload)),
      );
    } else {
      // Als .qgap_aes Datei teilen
      await _sharePublicKeyAsFile(pubKeyString);
    }
  }

  /// Teilt den eigenen öffentlichen RSA-Schlüssel als .qgap_aes Datei.
  Future<void> _sharePublicKeyAsFile(String pubKeyString) async {
    if (!mounted) return;
    // Kurzform des Fingerprints als ID-Vorschlag (erste 8 Hex-Zeichen ohne Doppelpunkte)
    final fp = _rsaKeyManager.getMyPublicKeyFingerprint();
    final idPart = fp != null ? fp.replaceAll(':', '').substring(0, 8) : 'XXX';
    final defaultName = 'Public_Key_$idPart';
    final nameCtrl = TextEditingController(text: defaultName);
    // ID-Anteil vorselektieren, damit man direkt tippen kann
    nameCtrl.selection = TextSelection(
      baseOffset: 'Public_Key_'.length,
      extentOffset: defaultName.length,
    );
    final chosenName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dateiname wählen'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Dateiname (ohne Endung)',
            suffixText: '.qgap_aes',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Abbrechen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Teilen'),
          ),
        ],
      ),
    );
    if (chosenName == null || chosenName.isEmpty || !mounted) return;
    final fileName = '$chosenName.qgap_aes';
    final content = 'QGAP_RSA_PUB:$pubKeyString';
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(content, flush: true);
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/octet-stream', name: fileName)],
        subject: fileName,
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(content: Text('Fehler beim Teilen: $e')),
        );
      }
    }
  }

  /// Verarbeitet einen vom gepaarten Air-Gap-Gerät per QR-Code übergebenen
  /// Relay-Wrap-Envelope (QGap-Magic + Version 0x01 + Type 0x10).
  ///
  /// Format des Wraps:
  ///   [0..3]  'QGap'
  ///   [4]     Version 0x01
  ///   [5]     Type 0x10
  ///   [6..7]  DestUidLen   uint16 BE
  ///   [8..]   DestUid      UTF-8
  ///   [..]    ChatGroupIdLen uint16 BE
  ///   [..]    ChatGroupId  UTF-8
  ///   [..]    Inner QGap-Envelope (Type 0x01/0x02/0x03), wird unverändert
  ///           als preencrypted Blob per Firestore an DestUid weitergeleitet.
  ///   [8..]   DestUid      UTF-8
  ///   [..]    ChatGroupIdLen uint16 BE
  ///   [..]    ChatGroupId  UTF-8
  ///   [..]    Inner QGap-Envelope (Type 0x01/0x02/0x03), wird unverändert
  ///           als preencrypted Blob per Firestore an DestUid weitergeleitet.

  // ═══════════════════════════════════════════════════════════════════════════
  // RELAY-PAIRING FLOW
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Schritt 1: Air-Gap A zeigt QR {QGAP_relay_pair_req, chatGroupId, ecCode}
  //            → Relay A scannt → _handleRelayPairRequest
  // Schritt 2: Relay A erstellt Einladung {QGAP_relay_pair_inv} für Online B
  //            → _sendOfflineEcInvite-ähnlich, aber mit relayUid
  // Schritt 3: Online B empfängt Einladung → _handleRelayPairInv
  //            → erstellt lokalen Chat → sendet ACK via Firestore an Relay A
  // Schritt 4: Relay A empfängt ACK → _handleRelayPairAck
  //            → aktualisiert relay_map → zeigt Config-QR für Air-Gap A
  // Schritt 5: Air-Gap A scannt Config-QR → _handleRelayConfig
  //            → speichert chat_partner_uid_ = B's UID → Relay-Wrap aktiv!

  /// Schritt 1 (Relay-Phone): Verarbeitet einen gescannten Pairing-Request
  /// vom Air-Gap-Gerät. Speichert das Relay-Mapping und erstellt eine
  /// Einladung für Online B.
  Future<void> _handleRelayPairRequest(Map<String, dynamic> data) async {
    if (!mounted) return;
    final chatGroupId = data['chatGroupId'] as String?;
    final ecCode = (data['ecCode'] as String?) ?? '';

    if (chatGroupId == null || chatGroupId.isEmpty) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Ungültiger Pairing-Request (keine Chat-ID).')));
      return;
    }

    final myUid = AuthService.currentUid;
    if (myUid == null) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Nicht mit Firebase verbunden – Relay-Pairing nicht möglich.')));
      return;
    }

    // Bestehendes Mapping prüfen
    final existing = await RelayMappingService.load(chatGroupId);
    if (existing != null && existing.pairingComplete) {
      if (!mounted) return;
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Pairing bereits abgeschlossen'),
          content: Text(
            'Für Chat-ID "$chatGroupId" ist das Relay-Pairing bereits '
            'abgeschlossen (Partner: ${existing.destUid ?? "?"}).\n\n'
            'Neu pairen?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Neu pairen')),
          ],
        ),
      );
      if (overwrite != true || !mounted) return;
    }

    // Firestore-Chat anlegen (Relay A ist Mitglied, B tritt später bei)
    // Die ID wird aus chatGroupId abgeleitet (reproducible, kein Zufalls-Id nötig)
    final firestoreChatId = 'relay_${chatGroupId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';
    try {
      final svc = FirestoreService();
      final alreadyMember = await svc.isMemberOf(firestoreChatId);
      if (!alreadyMember) {
        await svc.createChat(firestoreChatId);
        await svc.sendHandshake(firestoreChatId);
      }
      developer.log(
          'log: ☁️ Relay-Firestore-Chat angelegt: $firestoreChatId',
          name: '_handleRelayPairRequest');
    } catch (e) {
      developer.log('log: ⚠️ Firestore-Chat konnte nicht angelegt werden: $e',
          name: '_handleRelayPairRequest');
    }

    // Mapping speichern (ohne destUid – kommt erst nach ACK)
    await RelayMappingService.save(RelayMapping(
      chatGroupId: chatGroupId,
      ecCode: ecCode,
      firestoreChatId: firestoreChatId,
      pairingComplete: false,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    developer.log(
        'log: 📡 relay_map_$chatGroupId gespeichert (ecCode=$ecCode, firestoreChatId=$firestoreChatId, wartet auf ACK)',
        name: '_handleRelayPairRequest');

    if (!mounted) return;

    // Einladungs-Payload für Online B erstellen (inkl. firestoreChatId!)
    final payloadMap = <String, dynamic>{
      'version': 1,
      'chatType': 'qgap_relay_pair_inv',
      'chatGroupId': chatGroupId,
      'relayUid': myUid,
      'ecCode': ecCode,
      'firestoreChatId': firestoreChatId,
    };
    final jsonStr = jsonEncode(payloadMap);

    final fileNameCtrl = TextEditingController(text: 'RelayEinladung_EC');
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.compare_arrows, color: Colors.blue),
            SizedBox(width: 8),
            Flexible(child: Text('Relay-Pairing: Schritt 2')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pairing-Request vom Air-Gap-Gerät empfangen ✅\n\n'
              'Jetzt eine Einladungsdatei an Online-Partner B senden. '
              'B erstellt einen lokalen Chat und schickt automatisch '
              'eine Bestätigung (ACK) zurück.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 10),
            Text('Chat-ID: $chatGroupId',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            Text('EC-Code: $ecCode',
                style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
            const SizedBox(height: 12),
            TextField(
              controller: fileNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Dateiname',
                border: OutlineInputBorder(),
                suffixText: '.qgap_ch',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen')),
          OutlinedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('QR-Code'),
            onPressed: () => Navigator.of(ctx).pop('qr'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.share),
            label: const Text('Datei senden'),
            onPressed: () => Navigator.of(ctx).pop('file'),
          ),
        ],
      ),
    );
    final rawName = fileNameCtrl.text.trim();
    fileNameCtrl.dispose();
    if (action == null || !mounted) return;

    if (action == 'qr') {
      final bytes = Uint8List.fromList(utf8.encode(jsonStr));
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
      );
      if (mounted) {
        showQgapSnackBar(context, const SnackBar(
          content: Text('📡 Warte auf ACK von Partner B über Firestore…'),
          backgroundColor: Colors.indigo,
          duration: Duration(seconds: 5),
        ));
      }
      return;
    }

    // Datei-Export
    String baseName = rawName.isEmpty ? 'RelayEinladung_EC' : rawName;
    if (baseName.endsWith('.qgap_ch')) baseName = baseName.substring(0, baseName.length - 8);
    final fileName = '$baseName.qgap_ch';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(jsonStr, flush: true);
    final result = await Share.shareXFiles(
      [XFile(file.path, name: fileName, mimeType: 'application/octet-stream')],
    );
    if (!mounted) return;
    if (result.status == ShareResultStatus.success) {
      showQgapSnackBar(context, SnackBar(
        content: Text('✅ Relay-Einladung "$fileName" gesendet. Warte auf ACK…'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 6),
      ));
    }
  }

  /// Schritt 3 (Online B): Verarbeitet eine Relay-Pairing-Einladung.
  /// Erstellt lokalen OTP-Chat und sendet ACK via Firestore an Relay A.
  Future<void> _handleRelayPairInv(Map<String, dynamic> data) async {
    if (!mounted) return;
    final chatGroupId     = data['chatGroupId']     as String?;
    final relayUid        = data['relayUid']        as String?;
    final ecCode          = (data['ecCode']         as String?) ?? '';
    final firestoreChatId = data['firestoreChatId'] as String?;

    if (chatGroupId == null || chatGroupId.isEmpty || relayUid == null || relayUid.isEmpty) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Ungültige Relay-Einladung (fehlende Felder).')));
      return;
    }

    // Schon vorhanden?
    final existing = chatGroups.where((g) => g.id == chatGroupId).firstOrNull;
    if (existing != null) {
      final prefs = await SharedPreferences.getInstance();
      // partner_uid nachpflegen falls leer
      if ((prefs.getString('chat_partner_uid_${existing.id}') ?? '').isEmpty) {
        await prefs.setString('chat_partner_uid_${existing.id}', relayUid);
      }
      // firestoreChatId nachpflegen
      if (firestoreChatId != null &&
          (prefs.getString('chat_firestore_relay_id_${existing.id}') ?? '').isEmpty) {
        await prefs.setString('chat_firestore_relay_id_${existing.id}', firestoreChatId);
        // Firestore-Chat beitreten
        try {
          final svc = FirestoreService();
          await svc.joinChat(firestoreChatId);
          await svc.sendHandshake(firestoreChatId);
        } catch (e) {
          developer.log('log: Firestore-Chat-Beitritt fehlgeschlagen: $e',
              name: '_handleRelayPairInv');
        }
      }
      if (!mounted) return;
      showQgapSnackBar(context, SnackBar(
        content: Text('ℹ️ Relay-Chat „${existing.name}" bereits vorhanden.'),
        backgroundColor: Colors.blueGrey,
      ));
      return;
    }

    // Dialog: lokalen Namen vergeben
    final nameCtrl = TextEditingController();
    String selectedEmoji = '📡';
    const emojiOptions = ['📡', '🔒', '💬', '🛡️', '🔐', '🤝', '🧑‍💻', '👤'];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.compare_arrows, color: Colors.blue),
              SizedBox(width: 8),
              Flexible(child: Text('Relay-EC-Einladung empfangen')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Einladung zu einem Air-Gap-Relay-Chat (One-Time-Pad).\n'
                'Nachrichten werden vom Air-Gap-Gerät über dieses Relay gesendet.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 10),
              const Text(
                'Bitte vergib einen lokalen Namen und Symbol:',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Chat-Name (lokal)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final e in emojiOptions)
                    ChoiceChip(
                      label: Text(e, style: const TextStyle(fontSize: 18)),
                      selected: selectedEmoji == e,
                      onSelected: (_) => setS(() => selectedEmoji = e),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('EC-Code:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    SelectableText(ecCode,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.blue)),
                    const SizedBox(height: 4),
                    const Text(
                      'Die zugehörige .qgap_ec-Datei muss per USB importiert werden.',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
            ElevatedButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Beitreten'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final localName = nameCtrl.text.trim();
    final prefs = await SharedPreferences.getInstance();
    final newGroup = ChatGroup(
      id: chatGroupId,
      name: localName,
      description: 'Relay-Chat (leitet Nachrichten via Firestore weiter)',
      createdAt: DateTime.now(),
      iconEmoji: selectedEmoji,
      // Relay B leitet eingehende Nachrichten von Relay A nur weiter (als QR
      // für Air-Gap B). Keine eigene Entschlüsselung → relayForward.
      defaultEncryptionType: message_model.EncryptionType.relayForward,
      transport: ChatTransport.online,
      firestoreChatId: firestoreChatId,
    );
    final groupsJson = List<String>.from(prefs.getStringList('chat_groups') ?? []);
    groupsJson.add(json.encode(newGroup.toJson()));
    await prefs.setStringList('chat_groups', groupsJson);

    // Relay A als Partner-UID speichern (für B→A Nachrichten)
    await prefs.setString('chat_partner_uid_${newGroup.id}', relayUid);
    // EC-Code speichern
    if (ecCode.isNotEmpty) {
      await prefs.setString('chat_ec_code_${newGroup.id}', ecCode);
    }
    // Firestore-Chat-ID speichern (für direktes Senden via Chat)
    if (firestoreChatId != null && firestoreChatId.isNotEmpty) {
      await prefs.setString('chat_firestore_relay_id_${newGroup.id}', firestoreChatId);
    }

    // Firestore-Chat beitreten (Online B wird Mitglied)
    if (firestoreChatId != null && firestoreChatId.isNotEmpty) {
      try {
        final svc = FirestoreService();
        await svc.joinChat(firestoreChatId);
        await svc.sendHandshake(firestoreChatId);
        developer.log(
            'log: ☁️ Online B dem Relay-Firestore-Chat beigetreten: $firestoreChatId',
            name: '_handleRelayPairInv');
      } catch (e) {
        developer.log('log: ⚠️ Firestore-Chat-Beitritt fehlgeschlagen: $e',
            name: '_handleRelayPairInv');
      }
    }

    await _loadChatGroups();

    // ACK via Firestore an Relay A senden (inkl. eigener UID für Config-QR)
    try {
      final myUid = AuthService.currentUid;
      if (myUid != null) {
        final ackPayload = jsonEncode({
          'chatGroupId': chatGroupId,
          'senderUid': myUid,
          if (firestoreChatId != null) 'firestoreChatId': firestoreChatId,
        });
        print('QGAP_RELAY: ACK senden → relayUid=$relayUid chatGroupId=$chatGroupId firestoreChatId=$firestoreChatId');
        await FirestoreService().sendUserTransfer(
          receiverUid: relayUid,
          encryptionType: 'qgap_ec',
          payloadType: FirestoreService.kPayloadTypeRelayPairAck,
          fileName: 'relay_ack_$chatGroupId.json',
          payloadBytes: Uint8List.fromList(utf8.encode(ackPayload)),
          wrap: false,
          firestoreChatId: chatGroupId,
        );
        print('QGAP_RELAY: ✅ ACK erfolgreich gesendet');
        developer.log(
            'log: ✅ Relay-ACK gesendet → relayUid=$relayUid, chatGroupId=$chatGroupId',
            name: '_handleRelayPairInv');
      } else {
        print('QGAP_RELAY: ⚠️ ACK nicht gesendet – myUid ist null');
      }
    } catch (e) {
      print('QGAP_RELAY: ❌ ACK-Fehler: $e');
      developer.log('log: ⚠️ ACK konnte nicht gesendet werden: $e',
          name: '_handleRelayPairInv');
    }

    if (!mounted) return;
    showQgapSnackBar(context, SnackBar(
      content: Text(
        '✅ Relay-Chat „$localName" angelegt. ACK an Relay gesendet.\n'
        'Bitte .qgap_ec mit Code "$ecCode" per USB importieren.',
      ),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 7),
    ));
  }

  /// Schritt 4 (Relay-Phone): Verarbeitet einen eingehenden ACK von Online B.
  /// Aktualisiert das Relay-Mapping mit B's UID und bietet den Config-QR für
  /// Air-Gap A an.
  Future<void> _handleRelayPairAck({
    required String chatGroupId,
    required String senderUid,
    String? firestoreChatId,
  }) async {
    print('QGAP_RELAY: _handleRelayPairAck chatGroupId=$chatGroupId senderUid=$senderUid');
    final updated = await RelayMappingService.confirmAck(
      chatGroupId: chatGroupId,
      destUid: senderUid,
    );
    developer.log(
        'log: ✅ relay_map_$chatGroupId: ACK von $senderUid empfangen, pairing complete',
        name: '_handleRelayPairAck');

    // firestoreChatId aus dem ACK übernehmen falls noch nicht im Mapping
    final firestoreId = firestoreChatId ??
        updated?.firestoreChatId ??
        'relay_${chatGroupId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';

    if (!mounted) return;
    if (updated == null) {
      await RelayMappingService.save(RelayMapping(
        chatGroupId: chatGroupId,
        ecCode: '',
        destUid: senderUid,
        firestoreChatId: firestoreId,
        pairingComplete: true,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }

    // ChatGroup auf dem Relay erstellen (falls noch nicht vorhanden)
    final prefs = await SharedPreferences.getInstance();
    final existingGroup = chatGroups.where((g) => g.id == chatGroupId).firstOrNull;
    if (existingGroup == null) {
      final ecCode = updated?.ecCode ?? '';
      final newGroup = ChatGroup(
        id: chatGroupId,
        name: '📡 Relay-Chat',
        description: 'Relay-Weiterleitungs-Chat (Air-Gap ↔ Online B)',
        createdAt: DateTime.now(),
        iconEmoji: '📡',
        // Relay-Phone leitet Nachrichten nur weiter – keine eigene Entschlüsselung.
        defaultEncryptionType: message_model.EncryptionType.relayForward,
        transport: ChatTransport.online,
        firestoreChatId: firestoreId,
      );
      final groupsJson = List<String>.from(prefs.getStringList('chat_groups') ?? []);
      groupsJson.add(json.encode(newGroup.toJson()));
      await prefs.setStringList('chat_groups', groupsJson);
      await prefs.setString('chat_partner_uid_$chatGroupId', senderUid);
      if (ecCode.isNotEmpty) {
        await prefs.setString('chat_ec_code_$chatGroupId', ecCode);
      }
      await prefs.setString('chat_firestore_relay_id_$chatGroupId', firestoreId);
      await _loadChatGroups();
      print('QGAP_RELAY: ✅ Relay-ChatGroup erstellt: $chatGroupId');
    } else {
      // Partner-UID nachpflegen
      await prefs.setString('chat_partner_uid_$chatGroupId', senderUid);
      await prefs.setString('chat_firestore_relay_id_$chatGroupId', firestoreId);
      print('QGAP_RELAY: ✅ Relay-ChatGroup bereits vorhanden, UID/FirestoreId aktualisiert');
    }

    if (!mounted) return;
    showQgapSnackBar(context, SnackBar(
      content: const Text('✅ Relay-Pairing abgeschlossen! Config-QR für Air-Gap bereit.'),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 5),
      action: SnackBarAction(
        label: 'Config-QR',
        onPressed: () => _showRelayConfigQr(chatGroupId, senderUid, firestoreId),
      ),
    ));
  }

  /// Zeigt den Config-QR für Air-Gap erneut an (aus dem Chat-Menü).
  Future<void> _showRelayConfigQrForGroup(ChatGroup group) async {
    final mapping = await RelayMappingService.load(group.id);
    if (mapping == null || mapping.destUid == null) {
      if (!mounted) return;
      showQgapSnackBar(context, const SnackBar(
        content: Text('⚠️ Kein Relay-Mapping gefunden – Pairing noch nicht abgeschlossen?'),
        backgroundColor: Colors.orange,
      ));
      return;
    }
    final firestoreId = mapping.firestoreChatId ??
        'relay_${group.id.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')}';
    _showRelayConfigQr(group.id, mapping.destUid!, firestoreId);
  }

  /// Schritt 4b (Relay-Phone): Zeigt den Config-QR für Air-Gap A an.
  /// Der QR enthält chatGroupId + destUid (B's Firebase-UID) + firestoreChatId.
  void _showRelayConfigQr(String chatGroupId, String destUid, String firestoreChatId) async {
    final payload = jsonEncode({
      'version': 1,
      'chatType': 'qgap_relay_cfg',
      'chatGroupId': chatGroupId,
      'destUid': destUid,
      'firestoreChatId': firestoreChatId,
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
    );
  }

  /// Schritt 5 (Air-Gap A): Verarbeitet den Config-QR vom Relay-Phone.
  /// Speichert die Partner-UID (B's Firebase-UID) → Relay-Wrap ist ab jetzt
  /// für diesen Chat aktiv.
  Future<void> _handleRelayConfig(Map<String, dynamic> data) async {
    if (!mounted) return;
    final chatGroupId     = data['chatGroupId']     as String?;
    final destUid         = data['destUid']         as String?;
    final firestoreChatId = data['firestoreChatId'] as String?;

    if (chatGroupId == null || chatGroupId.isEmpty || destUid == null || destUid.isEmpty) {
      showQgapSnackBar(context,
        const SnackBar(content: Text('Ungültiger Relay-Config-QR (fehlende Felder).')));
      return;
    }

    final group = chatGroups.where((g) => g.id == chatGroupId).firstOrNull;
    if (group == null) {
      showQgapSnackBar(context, SnackBar(
        content: Text('Chat-ID "$chatGroupId" nicht gefunden.\n'
            'Bitte zuerst die EC-Einladung austauschen.'),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('chat_partner_uid_$chatGroupId', destUid);
    // Firestore-Chat-ID speichern (für direktes Senden via Relay-Chat)
    if (firestoreChatId != null && firestoreChatId.isNotEmpty) {
      await prefs.setString('chat_firestore_relay_id_$chatGroupId', firestoreChatId);
    }
    developer.log(
        'log: ✅ chat_partner_uid_$chatGroupId = $destUid, firestoreChatId=$firestoreChatId (Relay-Pairing Schritt 5)',
        name: '_handleRelayConfig');

    if (!mounted) return;
    showQgapSnackBar(context, SnackBar(
      content: Text(
        '✅ Relay-Pairing abgeschlossen für „${group.name}"!\n'
        'Nachrichten werden jetzt automatisch via Relay weitergeleitet.',
      ),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 5),
    ));
  }

  /// Erzeugt den Pairing-Request-QR für Air-Gap A.
  /// Air-Gap A scannt ihn auf dem Relay-Phone (Schritt 1 des Pairing-Flows).
  Future<void> _showRelayPairingRequestQr(ChatGroup group) async {
    final prefs = await SharedPreferences.getInstance();
    // Alle möglichen Quellen für EC-Code / EC-Datei durchsuchen
    String ecCode = (prefs.getString('chat_ec_code_${group.id}') ?? '').trim();
    String ecFile = (prefs.getString('chat_ec_file_${group.id}')
        ?? prefs.getString('chat_key_${group.id}') ?? '').trim();
    String resolvedCode = ecCode;

    // Wenn Code fehlt aber Datei vorhanden → Code aus Dateinamen extrahieren
    if (resolvedCode.isEmpty && ecFile.isNotEmpty) {
      resolvedCode = EcKeyfileService.extractCodeFromFilename(ecFile) ?? '';
    }
    // Wenn noch immer leer → über EcKeyfileService nach Dateien auf Gerät suchen
    if (resolvedCode.isEmpty && ecCode.isNotEmpty) {
      final match = await EcKeyfileService.findEcFileByCode(ecCode);
      if (match != null && match.isNotEmpty) {
        resolvedCode = ecCode;
        await prefs.setString('chat_ec_file_${group.id}', match);
      }
    }

    if (resolvedCode.isEmpty) {
      if (!mounted) return;
      showQgapSnackBar(context, const SnackBar(
        content: Text(
          'Kein EC-Code für diesen Chat gefunden. '
          'Bitte zuerst eine .qgap_ec-Datei zuordnen.',
        ),
        backgroundColor: Colors.orange,
      ));
      return;
    }

    final payload = jsonEncode({
      'version': 1,
      'chatType': 'qgap_relay_pair_req',
      'chatGroupId': group.id,
      'ecCode': resolvedCode,
    });
    final bytes = Uint8List.fromList(utf8.encode(payload));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.compare_arrows, color: Colors.blue),
            SizedBox(width: 8),
            Flexible(child: Text('Relay-Pairing: Schritt 1')),
          ],
        ),
        content: const Text(
          'Das Relay-Handy scannt diesen QR-Code.\n\n'
          'Der QR enthält die Chat-ID und den EC-Code — keine '
          'persönlichen Daten. Danach erstellt das Relay eine '
          'Einladung für Online-Partner B.',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Schließen'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('QR anzeigen'),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => QrDataSender(bytes: bytes)),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _handleScannedRelayWrap(Uint8List bytes) async {
    if (!mounted) return;
    if (!_deviceRoleOnline) {
      showQgapSnackBar(
        context,
        const SnackBar(
          content: Text(
            '\u26a0\ufe0f Dieses Ger\u00e4t ist nicht als Online-Relay konfiguriert. '
            'Bitte Ger\u00e4terolle in den Einstellungen \u00e4ndern.',
          ),
        ),
      );
      return;
    }
    if (AuthService.currentUid == null) {
      showQgapSnackBar(
        context,
        const SnackBar(
          content: Text(
            'Nicht mit Firebase verbunden \u2013 Anmeldung erforderlich.',
          ),
        ),
      );
      return;
    }

    // Header parsen (Format v2: destUid + chatGroupId + ecCode + inner)
    String destUid;
    String chatGroupId;
    String ecCode = '';
    Uint8List inner;
    try {
      if (bytes.length < 10) {
        throw const FormatException('Relay-Wrap zu kurz');
      }
      final destLen = (bytes[6] << 8) | bytes[7];
      final destEnd = 8 + destLen;
      if (bytes.length < destEnd + 2) {
        throw const FormatException('Relay-Wrap: DestUid abgeschnitten');
      }
      destUid = utf8.decode(bytes.sublist(8, destEnd));
      final cgLen = (bytes[destEnd] << 8) | bytes[destEnd + 1];
      final cgEnd = destEnd + 2 + cgLen;
      if (bytes.length < cgEnd + 2) {
        throw const FormatException('Relay-Wrap: ChatGroupId abgeschnitten');
      }
      chatGroupId = utf8.decode(bytes.sublist(destEnd + 2, cgEnd));
      // v2: ecCode-Feld (Länge 0 = kein Code / Altformat)
      final ecLen = (bytes[cgEnd] << 8) | bytes[cgEnd + 1];
      final ecEnd = cgEnd + 2 + ecLen;
      if (bytes.length < ecEnd) {
        throw const FormatException('Relay-Wrap: ecCode abgeschnitten');
      }
      if (ecLen > 0) {
        ecCode = utf8.decode(bytes.sublist(cgEnd + 2, ecEnd));
      }
      inner = Uint8List.fromList(bytes.sublist(ecEnd));
      if (inner.isEmpty) {
        throw const FormatException('Relay-Wrap: leerer Inner-Envelope');
      }
      // Inner-Magic plausibilisieren ('QGap')
      if (inner.length < 6 ||
          inner[0] != 0x4F || inner[1] != 0x42 ||
          inner[2] != 0x4D || inner[3] != 0x43) {
        throw const FormatException(
            'Relay-Wrap: Inner-Envelope hat keine QGap-Magic');
      }
    } catch (e) {
      developer.log('log: Relay-Wrap parsen fehlgeschlagen: $e',
          name: '_handleScannedRelayWrap');
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(content: Text('Ungültiges Relay-Paket: $e')),
      );
      return;
    }

    if (destUid.isEmpty) {
      if (!mounted) return;
      showQgapSnackBar(
        context,
        const SnackBar(
            content: Text('Relay-Paket ohne Empf\u00e4nger-UID \u2013 Abbruch.')),
      );
      return;
    }

    // ─── Schlüsseldatei-Check ────────────────────────────────────────────────
    // Wenn der Relay-Wrap einen ecCode enthält: prüfen ob die zugehörige
    // .qgap_ec-Datei auf diesem Relay-Handy lokal vorhanden ist.
    // Das wäre ein Sicherheitsproblem (Schlüssel sollte nur auf Air-Gap sein).
    bool relayHadKeyFile = false;
    if (ecCode.isNotEmpty) {
      final foundFile = await EcKeyfileService.findEcFileByCode(ecCode);
      if (foundFile != null) {
        relayHadKeyFile = true;
        developer.log(
            'log: ⚠️ SICHERHEIT: Schlüsseldatei "$foundFile" ist auf Relay-Handy vorhanden! ecCode=$ecCode',
            name: '_handleScannedRelayWrap');
        if (!mounted) return;
        final continueAnyway = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.security, color: Colors.red),
                SizedBox(width: 8),
                Flexible(child: Text('⚠️ Sicherheitswarnung')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Die zugehörige Schlüsseldatei ist auf diesem '
                  'Relay-Handy gespeichert!',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Datei: $foundFile',
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Das Relay-Handy sollte KEINE Schlüsseldateien '
                  'besitzen — Schlüssel gehören nur auf das Air-Gap-Gerät. '
                  'Bitte die Datei vom Relay-Handy löschen.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Die Nachricht wird dennoch weitergeleitet, aber '
                  'der Empfänger wird über diesen Sicherheitshinweis '
                  'informiert.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Abbrechen'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Trotzdem weiterleiten'),
              ),
            ],
          ),
        );
        if (continueAnyway != true || !mounted) return;
      }
    }

    // ─── Bestätigungsdialog ───────────────────────────────────────────────────
    final innerType = inner[5];
    final innerLabel = innerType == 0x01
        ? 'Text'
        : innerType == 0x02
            ? 'Datei'
            : innerType == 0x03
                ? 'Sprachnachricht'
                : 'unbekannt (0x${innerType.toRadixString(16)})';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cloud_upload, color: Colors.blue),
            SizedBox(width: 8),
            Flexible(child: Text('Nachricht weiterleiten?')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Eine vom gepaarten Air-Gap-Gerät verschlüsselte '
              'Nachricht wurde gescannt. Sie wird unverändert (vorverschlüsselt) '
              'über Firestore an den angegebenen Empfänger weitergeleitet.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            const Text('Empfänger-UID:',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            SelectableText(
              destUid,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 8),
            const Text('Chat-ID:',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
            SelectableText(
              chatGroupId,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Text('Typ: $innerLabel \u00b7 ${inner.length} Bytes',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Weiterleiten'),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    if (inner.length > FirestoreService.kMaxTransferBytes) {
      showQgapSnackBar(
        context,
        SnackBar(
          content: Text(
            'Nachricht zu groß für Firestore-Transfer: '
            '${inner.length} Bytes (max ${FirestoreService.kMaxTransferBytes}).',
          ),
        ),
      );
      return;
    }

    // Relay-Mapping nachschlagen für firestoreChatId (nur Relay A hat dieses Mapping)
    final relayMap = await RelayMappingService.load(chatGroupId);
    String? firestoreChatId = relayMap?.firestoreChatId;

    // Relay B hat kein relay_map, aber hat eine ChatGroup mit dieser chatGroupId
    // (angelegt via _handleRelayPairInv). Deren firestoreChatId verwenden.
    // Wenn diese gefunden wird, handelt es sich um eine B→A Weiterleitung.
    bool isBtoA = false;
    if (firestoreChatId == null || firestoreChatId.isEmpty) {
      final matchingGroup = chatGroups.where((g) => g.id == chatGroupId).firstOrNull;
      if (matchingGroup?.firestoreChatId != null &&
          matchingGroup!.firestoreChatId!.isNotEmpty) {
        firestoreChatId = matchingGroup.firestoreChatId;
        isBtoA = true;
        developer.log(
            'log: 📡 B→A Relay: firestoreChatId=$firestoreChatId aus ChatGroup (kein relay_map)',
            name: '_handleScannedRelayWrap');
      }
    }

    try {
      if (firestoreChatId != null && firestoreChatId.isNotEmpty) {
        // Direktes Senden über den Firestore-Chat (effizienter als sendUserTransfer)
        final innerB64 = base64.encode(inner);
        await FirestoreService().sendMessage(
          firestoreChatId,
          innerB64,
          // B→A: eigener Typ damit Relay A die Richtung erkennt → _kRelayBtoASentinel
          // A→B: offlineRelay wie bisher
          type: isBtoA ? CloudMessageType.offlineRelayBtoA : CloudMessageType.offlineRelay,
        );
        developer.log(
            'log: ✅ Relay-Forward via Firestore-Chat gesendet '
            '(chat=$firestoreChatId, dest=$destUid, keyFileWarning=$relayHadKeyFile)',
            name: '_handleScannedRelayWrap');
      } else {
        // Fallback: sendUserTransfer wenn noch kein Firestore-Chat
        final id = await FirestoreService().sendUserTransfer(
          receiverUid: destUid,
          receiverPublicKeyJson: null,
          encryptionType: 'qgap_ec',
          payloadType: FirestoreService.kPayloadTypeRelayPreencrypted,
          fileName: 'msg_${chatGroupId}_${DateTime.now().millisecondsSinceEpoch}.qgap',
          payloadBytes: inner,
          senderIsOffline: true,
          wrap: false,
          firestoreChatId: chatGroupId,
          relayHadKeyFile: relayHadKeyFile,
        );
        developer.log(
            'log: ✅ Relay-Forward via sendUserTransfer gesendet (id=$id, dest=$destUid, chat=$chatGroupId, keyFileWarning=$relayHadKeyFile)',
            name: '_handleScannedRelayWrap');
      }
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(
          content: Text(
              '✅ Nachricht an $destUid weitergeleitet (${inner.length} B).'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 5),
        ),
      );

      // Sentinel-Nachricht lokal in den Relay-Chat schreiben (sichtbar im Chat-Verlauf)
      try {
        final prefs = await SharedPreferences.getInstance();
        final messagesKey = 'messages_$chatGroupId';
        final existing = prefs.getStringList(messagesKey) ?? [];
        final sentinelMsg = message_model.Message(
          text: base64.encode(inner),
          originalText: '__RELAY_FWD__',
          isMe: true,
          timestamp: DateTime.now(),
          id: 'relay_fwd_${DateTime.now().millisecondsSinceEpoch}',
        );
        existing.add(json.encode(sentinelMsg.toJson()));
        await prefs.setStringList(messagesKey, existing);
      } catch (_) {}
    } catch (e) {
      developer.log('log: Relay-Forward fehlgeschlagen: $e',
          name: '_handleScannedRelayWrap');
      if (!mounted) return;
      showQgapSnackBar(
        context,
        SnackBar(content: Text('Weiterleitung fehlgeschlagen: $e')),
      );
    }
  }

  /// Scannt einen QR-Code und erkennt automatisch ob es eine Chat-Einladung
  /// (.qgap_ch JSON), ein Pairing-Payload (.qgap_pair JSON), ein
  /// Relay-Wrap-Envelope (QGap-Magic + Type 0x10, vom gepaarten Air-Gap-
  /// Ger\u00e4t f\u00fcr Firestore-Weiterleitung) oder ein RSA-Public-Key ist.
  // ── Präsentationen (PublicScreen) auf der Startseite ─────────────

  /// Lädt die lokal bekannten Lied-Sessions für die Startseiten-Liste.
  Future<void> _loadPublicSessions() async {
    try {
      final sessions = await _publicScreenService.loadMySessions();
      if (mounted) setState(() => _publicSessions = sessions);
    } catch (e) {
      developer.log('log: Lied-Sessions laden fehlgeschlagen: $e',
          name: '_loadPublicSessions');
    }
  }

  /// Kachel einer Präsentation in der Chat-Liste.
  Widget _buildPublicSessionTile(PublicScreenSession session) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 2,
      child: ListTile(
        contentPadding: const EdgeInsets.all(4),
        leading: CircleAvatar(
          backgroundColor: Colors.deepPurple.shade100,
          child: const Icon(Icons.slideshow, color: Colors.deepPurple),
        ),
        title: Text(
          session.title,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('Präsentation · ${session.state.label}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PublicScreenAdminScreen(sessionId: session.id),
          )).then((_) => _loadPublicSessions());
        },
      ),
    );
  }

  /// Desktop-Ersatz für den QR-Scan: Einladungs-/Admin-Code aus der
  /// Zwischenablage einfügen oder .qgap_ch-Datei wählen.
  Future<Uint8List?> _promptInviteCodePaste() async {
    final ctrl = TextEditingController();
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final t = clip?.text?.trim() ?? '';
      if (t.startsWith('{')) ctrl.text = t;
    } catch (_) {}
    if (!mounted) return null;
    final bytes = await showDialog<Uint8List>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Einladung / Admin-Code empfangen'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'QR-Scannen ist auf diesem Gerät nicht verfügbar.\n'
              'Füge den kopierten Code ein oder wähle eine .qgap_ch-Datei.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '{"kind": …}',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen'),
          ),
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('Datei wählen …'),
            onPressed: () async {
              try {
                final result = await FilePicker.platform.pickFiles(
                  type: FileType.any,
                  allowMultiple: false,
                  withData: true,
                  dialogTitle: '.qgap_ch-Datei wählen',
                );
                if (result == null || result.files.isEmpty) return;
                final picked = result.files.first;
                final data = picked.bytes ??
                    (picked.path != null
                        ? await File(picked.path!).readAsBytes()
                        : null);
                if (data != null && ctx.mounted) {
                  Navigator.of(ctx).pop(Uint8List.fromList(data));
                }
              } catch (_) {}
            },
          ),
          ElevatedButton(
            onPressed: () {
              final t = ctrl.text.trim();
              Navigator.of(ctx)
                  .pop(t.isEmpty ? null : Uint8List.fromList(utf8.encode(t)));
            },
            child: const Text('Übernehmen'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return bytes;
  }

  /// Verarbeitet einen gescannten Admin-QR (kind=qgap_ps_admin):
  /// koppelt dieses Handy als Co-Admin an die Lied-Session.
  Future<void> _handlePublicScreenAdminQr(Map<String, dynamic> data) async {
    final sessionId = data['sessionId'] as String?;
    final secret    = data['adminSecret'] as String?;
    if (sessionId == null || sessionId.isEmpty ||
        secret == null || secret.isEmpty) {
      showQgapSnackBar(context, const SnackBar(
        content: Text('❌ Ungültiger Admin-QR (Session-ID/Secret fehlt)'),
        backgroundColor: Colors.red,
      ));
      return;
    }
    try {
      final session =
          await _publicScreenService.joinAsAdmin(sessionId, secret);
      await _loadPublicSessions();
      if (!mounted) return;
      showQgapSnackBar(context, SnackBar(
        content: Text('✅ Admin-Modus für „${session.title}“ aktiviert'),
        backgroundColor: Colors.green,
      ));
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PublicScreenAdminScreen(sessionId: sessionId),
      )).then((_) => _loadPublicSessions());
    } catch (e) {
      if (!mounted) return;
      showQgapSnackBar(context, SnackBar(
        content: Text('❌ Admin-Kopplung fehlgeschlagen: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _scanChatInvite() async {
    if (!mounted) return;
    Uint8List? receivedBytes;
    if (Platform.isWindows || Platform.isLinux) {
      // Kein Kamera-Scan auf Desktop → Code einfügen oder Datei wählen
      receivedBytes = await _promptInviteCodePaste();
    } else {
      receivedBytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(builder: (_) => const QrDataReceiver()),
      );
    }
    if (receivedBytes == null || !mounted) return;

    try {
      // ① Relay-Wrap-Envelope erkennen (QGap-Magic + Version 0x01 + Type 0x10).
      //    Das ist eine vom Air-Gap-Gerät verpackte OTP-Nachricht, die per
      //    Firestore an einen Partner-User weitergeleitet werden soll.
      if (receivedBytes.length >= 6 &&
          receivedBytes[0] == 0x4F && // 'O'
          receivedBytes[1] == 0x42 && // 'B'
          receivedBytes[2] == 0x4D && // 'M'
          receivedBytes[3] == 0x43 && // 'C'
          receivedBytes[4] == 0x01 && // version
          receivedBytes[5] == 0x10) { // type=relay-wrap
        await _handleScannedRelayWrap(receivedBytes);
        return;
      }

      // ② Bare QGap-Envelope (Type 0x01 Text / 0x02 File / 0x03 Voice):
      //    B→A-Relay-Nachricht vom Relay-Phone oder Air-Gap ohne Relay-Wrap.
      //    Metadata parsen → passendem Chat zuordnen → navigieren.
      if (receivedBytes.length >= 8 &&
          receivedBytes[0] == 0x4F &&
          receivedBytes[1] == 0x42 &&
          receivedBytes[2] == 0x4D &&
          receivedBytes[3] == 0x43) {
        final innerType = receivedBytes[5];
        developer.log(
            'log: QGap-Envelope Typ 0x${innerType.toRadixString(16)} – suche passenden Chat',
            name: '_scanChatInvite');
        // Metadaten aus Envelope extrahieren
        final metaLen = (receivedBytes[6] << 8) | receivedBytes[7];
        final metaEnd = 8 + metaLen;
        if (receivedBytes.length < metaEnd) {
          if (!mounted) return;
          showQgapSnackBar(context, const SnackBar(content: Text('⚠️ QGap-Envelope zu kurz')));
          return;
        }
        final metadata = utf8.decode(receivedBytes.sublist(8, metaEnd));
        final payload = Uint8List.fromList(receivedBytes.sublist(metaEnd));
        // base64(meta)+base64(payload) – gleiches Format wie Firestore-Text
        final scannedData = base64.encode(utf8.encode(metadata)) + base64.encode(payload);
        final keyFileName = metadata.split(';').first;
        // Passenden Chat anhand der Schlüsseldatei suchen
        final prefs = await SharedPreferences.getInstance();
        ChatGroup? matchingGroup;
        for (final group in chatGroups) {
          final chatKey = prefs.getString('chat_key_${group.id}') ?? '';
          if (chatKey == keyFileName) {
            matchingGroup = group;
            break;
          }
        }
        if (!mounted) return;
        if (matchingGroup != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatScreen(
                chatGroupName: matchingGroup!.name,
                chatGroupId: matchingGroup.id,
                encryptionType: matchingGroup.defaultEncryptionType,
                firestoreChatId: matchingGroup.firestoreChatId,
                pendingScannedData: scannedData,
                pendingMetadata: metadata,
              ),
            ),
          ).then((_) => _loadChatGroups());
        } else {
          showQgapSnackBar(context, SnackBar(
            content: Text('⚠️ Kein Chat für Schlüsseldatei "$keyFileName" gefunden'),
            backgroundColor: Colors.orange,
          ));
        }
        return;
      }

      // ③ Textbasierter QR (Einladung / Pairing / RSA-Key).
      //    utf8.decode kann scheitern, wenn jemand einen anderen
      //    Binärcode scannt – das soll kein Stacktrace werden.
      String decoded;
      try {
        decoded = utf8.decode(receivedBytes);
      } on FormatException catch (e) {
        developer.log(
            'log: QR-Inhalt ist weder QGap-Envelope noch UTF-8 (${receivedBytes.length} B): $e',
            name: '_scanChatInvite');
        if (!mounted) return;
        showQgapSnackBar(
          context,
          SnackBar(
            content: Text(
              'QR-Code-Inhalt nicht lesbar (${receivedBytes.length} Bytes, '
              'kein QGap-Format und kein gültiges UTF-8).',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      // Prüfen ob es ein Chat-Einladungs-JSON ist
      Map<String, dynamic>? jsonData;
      try {
        jsonData = jsonDecode(decoded) as Map<String, dynamic>?;
      } catch (_) {
        jsonData = null;
      }

      if (jsonData != null &&
          _normalizeLegacyType(jsonData['kind'] as String?) == 'qgap_pair' &&
          jsonData['modulus'] != null && jsonData['exponent'] != null) {
        // → Pairing-Payload (Online-Relay ↔ Air-Gap)
        await _applyScannedPairingPayload(jsonData);
      } else if (jsonData != null &&
          _normalizeLegacyType(jsonData['kind'] as String?) == 'qgap_ps_admin') {
        // → Admin-Kopplung für Präsentation (PublicScreen)
        await _handlePublicScreenAdminQr(jsonData);
      } else if (jsonData != null &&
          _normalizeLegacyType(jsonData['chatType'] as String?) == 'qgap_relay_pair_req') {
        // → Relay-Pairing-Request vom Air-Gap-Gerät (Schritt 1)
        await _handleRelayPairRequest(jsonData);
      } else if (jsonData != null &&
          _normalizeLegacyType(jsonData['chatType'] as String?) == 'qgap_relay_cfg') {
        // → Relay-Config-QR vom Relay-Phone (Schritt 5 – Air-Gap empfängt destUid)
        await _handleRelayConfig(jsonData);
      } else if (jsonData != null && (
            jsonData.containsKey('firestoreChatId') ||
            _normalizeLegacyType(jsonData['chatType'] as String?) == 'qgap_ec_offline' ||
            _normalizeLegacyType(jsonData['chatType'] as String?) == 'qgap_relay_pair_inv' ||
            (jsonData.containsKey('chatGroupId') && jsonData.containsKey('ecCode'))
          )) {
        // → Chat-Einladung (.qgap_ch) – Online (firestoreChatId)
        //   ODER Offline-EC (chatType=QGAP_ec_offline / chatGroupId+ecCode)
        //   ODER Relay-Pairing-Einladung (chatType=QGAP_relay_pair_inv)
        await _handleQGapChIntent('qr_scan.qgap_ch', receivedBytes);
      } else {
        // → RSA Public Key oder unbekanntes Format
        final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(decoded);
        if (publicKey == null) {
          showQgapSnackBar(context, const SnackBar(
            content: Text('❌ Kein erkanntes Format (keine Einladung, kein RSA-Key)'),
            backgroundColor: Colors.red,
          ));
          return;
        }
        // RSA-Key-Verarbeitung wie in _showImportPublicKey
        final controller = TextEditingController();
        final contactName = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Kontaktname festlegen'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Name', hintText: 'z. B. Alice'),
              autofocus: true,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('Abbrechen')),
              TextButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), child: const Text('Speichern')),
            ],
          ),
        );
        if (contactName == null || contactName.isEmpty || !mounted) return;
        await _rsaKeyManager.saveContactPublicKey(contactName, publicKey);
        showQgapSnackBar(context, SnackBar(
          content: Text('✅ Public Key von „$contactName" gespeichert.'),
          backgroundColor: Colors.green,
        ));
      }
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, SnackBar(content: Text('Fehler beim Verarbeiten: $e')));
      }
    }
  }

  // Öffentlichen Schlüssel eines Kontakts via QR-Fountain-Code importieren
  void _showImportPublicKey() async {
    if (!mounted) return;
    final receivedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const QrDataReceiver()),
    );

    if (receivedBytes == null || !mounted) return;

    try {
      final decoded = utf8.decode(receivedBytes);
      final publicKey = _rsaKeyManager.loadPublicKeyFromQRCode(decoded);
      if (publicKey == null) {
        showQgapSnackBar(context, 
          const SnackBar(
            content: Text('❌ Ungültiger QR-Code: Kein RSA-Public-Key'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Kontaktname abfragen
      final controller = TextEditingController();
      final contactName = await showDialog<String>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Kontaktname festlegen'),
            content: TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'z. B. Alice',
              ),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Abbrechen'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
                child: const Text('Speichern'),
              ),
            ],
          );
        },
      );

      if (contactName == null || contactName.isEmpty) return;

      final existing = await _rsaKeyManager.getContactKeys();
      if (existing.containsKey(contactName)) {
        if (!mounted) return;
        final overwrite = await _showConfirmationDialog(
          'Schlüssel überschreiben?',
          'Für "$contactName" existiert bereits ein Schlüssel. Überschreiben?',
        );
        if (overwrite != true) return;
      }

      await _rsaKeyManager.saveContactPublicKey(contactName, publicKey);

      if (!mounted) return;
      showQgapSnackBar(context, 
        SnackBar(
          content: Text('✅ Schlüssel für "$contactName" importiert'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        showQgapSnackBar(context, 
          SnackBar(
            content: Text('❌ Fehler beim Einlesen des Schlüssels: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Dialog zur Kontakt-Schlüssel-Verwaltung
  void _showContactKeyManagement() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: const [
              Icon(Icons.people, color: Colors.orange),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '👥 Kontakt-Schlüssel',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            height: 300,
            child: FutureBuilder<Map<String, String>>(
              future: _rsaKeyManager.getContactKeys(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Fehler: ${snapshot.error}'),
                  );
                }
                
                final contactKeys = snapshot.data ?? {};
                
                if (contactKeys.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.person_off, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'Keine Kontakt-Schlüssel gespeichert',
                          style: TextStyle(color: Colors.grey),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Importieren Sie Schlüssel über QR-Code',
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }
                
                return ListView.builder(
                  itemCount: contactKeys.length,
                  itemBuilder: (context, index) {
                    final contactName = contactKeys.keys.elementAt(index);
                    return ListTile(
                      leading: const Icon(Icons.person, color: Colors.blue),
                      title: Text(contactName),
                      subtitle: const Text('RSA-Schlüssel gespeichert'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () async {
                          final confirmed = await _showConfirmationDialog(
                            'Kontakt-Schlüssel löschen?',
                            'Möchten Sie den Schlüssel für "$contactName" wirklich löschen?',
                          );
                          if (confirmed == true) {
                            await _rsaKeyManager.removeContactKey(contactName);
                            Navigator.of(context).pop();
                            _showContactKeyManagement(); // Dialog neu laden
                          }
                        },
                      ),
                    );
                  },
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
}
