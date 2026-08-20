// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qgap/screens/home_screen.dart';

/// Sperrt den Zugriff auf die App mit dem App-Passwort (falls gesetzt).
///
/// Fragt das Passwort beim Start ab und erneut, sobald die App aus dem
/// Hintergrund zurückkehrt (nur wenn ein Passwort hinterlegt ist).
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _checked = false;
  bool _locked = false;
  String? _error;
  final TextEditingController _pwController = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pwController.dispose();
    super.dispose();
  }

  Future<void> _checkLock() async {
    final prefs = await SharedPreferences.getInstance();
    final hasPassword = prefs.getString('app_password') != null;
    if (mounted) {
      setState(() {
        _locked = hasPassword;
        _checked = true;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Beim nächsten Vordergrund-Aufruf erneut sperren, falls ein
      // App-Passwort gesetzt ist (asynchron nachladen, kein Warten nötig).
      SharedPreferences.getInstance().then((prefs) {
        if (mounted && prefs.getString('app_password') != null) {
          setState(() => _locked = true);
        }
      });
    }
  }

  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    return sha256.convert(bytes).toString();
  }

  Future<void> _unlock() async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString('app_password');
    if (storedHash == null || _hashPassword(_pwController.text) == storedHash) {
      _pwController.clear();
      if (mounted) setState(() { _locked = false; _error = null; });
      return;
    }
    setState(() => _error = 'Falsches Passwort');
  }

  @override
  Widget build(BuildContext context) {
    if (!_checked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_locked) {
      return const HomeScreen();
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock, size: 64, color: Colors.blue),
                const SizedBox(height: 16),
                const Text('QGap ist gesperrt',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: TextField(
                    controller: _pwController,
                    obscureText: _obscure,
                    autofocus: true,
                    onSubmitted: (_) => _unlock(),
                    decoration: InputDecoration(
                      labelText: 'App-Passwort',
                      border: const OutlineInputBorder(),
                      errorText: _error,
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _unlock, child: const Text('Entsperren')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
