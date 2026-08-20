// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

//flutter build apk --debug;;adb install build\app\outputs\flutter-apk\app-debug.apk

/*Samsung:
flutter build apk --release; adb -s R5CTC01MCAB install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R5CTC01MCAB shell am start -n de.paulporg.obmc/.MainActivity
nothing
flutter build apk --release; adb -s P3127D004454 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s P3127D004454 shell am start -n de.paulporg.obmc/.MainActivity
*/
//Samsung und nothing
//flutter build apk --release; adb -s R5CTC01MCAB install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R5CTC01MCAB shell am start -n de.paulporg.obmc/.MainActivity; adb -s P3127D004454 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s P3127D004454 shell am start -n de.paulporg.obmc/.MainActivity

// Samsung tablet installieren
// adb -s R52W205KB1Z install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R52W205KB1Z shell am start -n de.paulporg.obmc/.MainActivity; 

// Samsung S9 installieren
// adb -s 2a5b5b0a02047ece install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 2a5b5b0a02047ece shell am start -n de.paulporg.obmc/.MainActivity; 


// Samsung tablet installieren, Samsung und nothing
// flutter build apk --release; adb -s R5CTC01MCAB install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R5CTC01MCAB shell am start -n de.paulporg.obmc/.MainActivity; adb -s P3127D004454 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s P3127D004454 shell am start -n de.paulporg.obmc/.MainActivity ;adb -s R52W205KB1Z install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R52W205KB1Z shell am start -n de.paulporg.obmc/.MainActivity; 


/* adb -s 192.168.0.204:5555
 adb connect 192.168.0.204:5555
 adb connect 192.168.0.28:5555
 adb connect 192.168.0.83:5555
 adb connect 192.168.0.208:5555

 adb connect 10.0.0.110:5555 (Samsung S22 MM bei ReAuTec)

adb connect 192.168.0.204:5555 (Samsung S22 MM zu Hause)
 
 (Samsung S22 MM zu Hause)
 adb devices
 adb -s R5CTC01MCAB tcpip 5555
 adb connect 192.168.0.146:5555

 (Samsung Tablet S8 MM zu Hause)
 adb devices
 adb -s R52W205KB1Z  tcpip 5555
 adb connect 192.168.0.36:5555
adb devices

*/
//  ReAuTec WiFi (kein USB): IPs statt Serials verwenden (adb connect <IP>:5555 vorher nötig)
// Samsung(Relay A)=10.0.0.110  Nothing(Air-Gap)=10.0.0.111  Tablet(Relay B)=10.0.0.129
// Weg: Air-Gap(Nothing) ↔ Relay A(Samsung) hin+zurück | Air-Gap(Nothing) ↔ Relay B(Tablet)
// flutter build apk --release; adb -s 10.0.0.110:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 10.0.0.110:5555 shell am start -n de.paulporg.obmc/.MainActivity; adb -s 10.0.0.111:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 10.0.0.111:5555 shell am start -n de.paulporg.obmc/.MainActivity; adb -s 10.0.0.129:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 10.0.0.129:5555 shell am start -n de.paulporg.obmc/.MainActivity
// nur S22 installieren bei ReAuTec//
//flutter build apk --release; adb -s 10.0.0.110:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 10.0.0.110:5555 shell am start -n de.paulporg.obmc/.MainActivity;

//  MM Home WiFi (kein USB): IPs statt Serials verwenden (adb connect <IP>:5555 vorher nötig)
// Samsung S22 (Relay A)=192.168.0.204 / Nothing(Air-Gap A)=192.168.0.28 / Tablet(Relay B)=192.168.0.83 / S9(Relay B alt)=192.168.0.208
// flutter build apk --release; adb -s 192.168.0.146:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 192.168.0.146:5555 shell am start -n de.paulporg.obmc/.MainActivity; 

//Tablet S8 installieren bei MM Home WiFi:
// adb -s 192.168.0.36:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 192.168.0.36:5555 shell am start -n de.paulporg.obmc/.MainActivity; 
// Home:
// Samsung S22 (Relay A)=192.168.0.204 / Nothing(Air-Gap A)=192.168.0.28 / Tablet(Relay B)=192.168.0.83 / S9(Relay B alt)=192.168.0.208
// flutter build apk --release; adb -s 192.168.0.146:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 192.168.0.146:5555 shell am start -n de.paulporg.obmc/.MainActivity; adb -s 192.168.0.36:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 192.168.0.36:5555 shell am start -n de.paulporg.obmc/.MainActivity; 


//Tablet S8 installieren bei MM Home WiFi:
// adb -s 192.168.0.36:5555 install -r build\app\outputs\flutter-apk\app-release.apk; adb -s 192.168.0.36:5555 shell am start -n de.paulporg.obmc/.MainActivity; 

// firebas updaten:
// D:\Daten\VSC\firebase\firebase deploy --only hosting
// D:\Daten\VSC\firebase\firebase deploy --only firestore:rules

// flutter build windows --release 2>&1

/*
"Windows Build (PowerShell):
flutter analyze 2>$null; flutter build windows --release 2>$null; Write-Host "Build=$LASTEXITCODE"
" liegt dann hier: D:\Daten\VSC\qr_code_chat\build\windows\x64\runner\Release
flutter build apk --release; adb -s R5CTC01MCAB install -r build\app\outputs\flutter-apk\app-release.apk; adb -s R5CTC01MCAB shell am start -n de.paulporg.obmc/.MainActivity

*/

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:qgap/firebase_options.dart';
import 'package:qgap/screens/app_lock_gate.dart';
import 'package:qgap/services/app_storage.dart';
import 'package:qgap/services/auth_service.dart';
import 'package:qgap/services/firestore_reconnect.dart';
import 'package:qgap/services/launch_args.dart';
import 'package:qgap/services/notification_service.dart';
import 'package:qgap/services/purchase_service.dart';
import 'package:qgap/services/single_instance.dart';
import 'package:qgap/services/windows_file_association.dart';

void main(List<String> args) async {
  // Stelle sicher, dass Flutter Binding initialisiert ist
  WidgetsFlutterBinding.ensureInitialized();

  // Windows: per Drag/„Öffnen mit“ übergebene Datei merken
  LaunchArgs.init(args);

  // Windows: nur eine Instanz — zweite reicht ihre Datei weiter und beendet sich
  if (Platform.isWindows) {
    final primary = await SingleInstance.ensurePrimary();
    if (!primary) {
      exit(0);
    }
    // Dateiverknüpfung .qgap/.qgap_ch/.qgap_ec registrieren (HKCU)
    unawaited(WindowsFileAssociation.register());
  }

  // Plattformspezifische Basis-Pfade ermitteln (Android/Windows/iOS)
  await AppStorage.init();

  // Pro-Kaufstatus laden + Purchase-Stream (Android/iOS) starten
  unawaited(PurchaseService.init());

  // ── Firebase initialisieren ───────────────────────────────────────────────
  // Android: liest automatisch aus google-services.json (keine Options nötig).
  // iOS/Windows/Web/macOS: explizite Options aus firebase_options.dart
  //   (iOS via FlutterFire CLI registriert — keine GoogleService-Info.plist nötig).
  try {
    if (Platform.isAndroid) {
      await Firebase.initializeApp().timeout(const Duration(seconds: 6));
    } else {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      ).timeout(const Duration(seconds: 6));
    }
  } catch (e) {
    debugPrint('Firebase.initializeApp fehlgeschlagen/timeout: $e');
  }

  // Firestore-Reconnect bei Netzwechseln (hängende gRPC-Streams neu aufbauen)
  FirestoreReconnect.start();

  // Stille Auto-Authentifizierung (kein UI, kein User-Eingriff nötig).
  // WICHTIG: NICHT blockierend! Auf Geräten ohne/mit eingeschränktem Netz
  // (oder bei Firebase-App-Check-Problemen) kann createUserWithEmailAndPassword
  // hängen und die UI bliebe schwarz. Login läuft daher im Hintergrund weiter.
  // Sobald er erfolgreich ist, werden Username+Passwort in SharedPreferences
  // persistiert → bei jedem späteren Start (auch offline-fähig) wird über
  // signInWithEmailAndPassword wieder genau dieselbe Firebase-UID hergestellt,
  // d. h. derselbe Firestore-User bleibt erhalten.
  unawaited(
    AuthService.ensureLoggedIn()
        .timeout(const Duration(seconds: 30))
        .catchError((Object e) {
      debugPrint('Auto-Login (Hintergrund) fehlgeschlagen: $e');
    }),
  );

  // Fehlerbehandlung für unbehandelte Ausnahmen
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('Flutter Error: ${details.exception}');
  };

  // ── Benachrichtigungsdienst initialisieren ────────────────────────────────
  // onTap wird später von HomeScreen gesetzt; hier nur Plugin initialisieren.
  await NotificationService().initialize();

  // Setze bevorzugte Orientierung
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  runApp(const MyApp()); 
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Erzwingt den vollständigen Prozess-Exit auf Desktop-Plattformen — ohne
  // dies bleibt der Prozess auf Windows wegen offener Firestore/gRPC-Streams
  // teils noch im Task-Manager sichtbar, nachdem das Fenster geschlossen wurde.
  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      exit(0);
    }
    return ui.AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'QGap Once book message Chat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color.fromARGB(255, 90, 7, 233)),
        useMaterial3: true,
      ),
      home: const AppLockGate(),
    );
  }
}
