// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Einmaliger „Pro"-Kauf pro Hauptversion (Google Play Billing / App Store).
///
/// Produkt-ID pro Hauptversion: qgap_pro_v1, qgap_pro_v2, …
/// Das Produkt muss in der Play Console als „nicht-verbrauchbarer"
/// In-App-Artikel mit derselben ID angelegt werden.
class PurchaseService {
  PurchaseService._();

  static const String proProductId = 'qgap_pro_v1';
  static const String _ownedKey = 'purchase_$proProductId';

  /// Aktueller Pro-Status (UI kann per ValueListenableBuilder reagieren).
  static final ValueNotifier<bool> isPro = ValueNotifier<bool>(false);

  static StreamSubscription<List<PurchaseDetails>>? _sub;

  static bool get platformSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    isPro.value = prefs.getBool(_ownedKey) ?? false;
    if (!platformSupported) return;
    _sub ??= InAppPurchase.instance.purchaseStream.listen(_onPurchases);
  }

  static Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.productID == proProductId &&
          (p.status == PurchaseStatus.purchased ||
              p.status == PurchaseStatus.restored)) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_ownedKey, true);
        isPro.value = true;
      }
      if (p.pendingCompletePurchase) {
        try {
          await InAppPurchase.instance.completePurchase(p);
        } catch (_) {}
      }
    }
  }

  /// Produktdetails (Name, Preis) aus dem Store laden. null = nicht verfügbar.
  static Future<ProductDetails?> proDetails() async {
    if (!platformSupported) return null;
    try {
      if (!await InAppPurchase.instance.isAvailable()) return null;
      final resp =
          await InAppPurchase.instance.queryProductDetails({proProductId});
      return resp.productDetails.isEmpty ? null : resp.productDetails.first;
    } catch (_) {
      return null;
    }
  }

  /// Startet den Kauf. Rückgabe: null bei gestartetem Kaufdialog,
  /// sonst eine Fehlermeldung für die UI.
  static Future<String?> buyPro() async {
    if (!platformSupported) {
      return 'Der Kauf ist nur in der Android-/iOS-App möglich.';
    }
    if (!await InAppPurchase.instance.isAvailable()) {
      return 'App-Store nicht verfügbar.';
    }
    final details = await proDetails();
    if (details == null) {
      return 'Produkt "$proProductId" nicht gefunden – '
          'ist es in der Play Console angelegt?';
    }
    try {
      await InAppPurchase.instance
          .buyNonConsumable(purchaseParam: PurchaseParam(productDetails: details));
      return null;
    } catch (e) {
      return 'Kauf fehlgeschlagen: $e';
    }
  }

  /// Frühere Käufe wiederherstellen (z. B. nach Neuinstallation).
  static Future<void> restore() async {
    if (!platformSupported) return;
    try {
      await InAppPurchase.instance.restorePurchases();
    } catch (_) {}
  }
}
