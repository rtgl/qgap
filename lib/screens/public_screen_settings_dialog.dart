// QGap - One-Time-Pad-Messenger mit Air-Gap-QR-Uebertragung
// Copyright (C) 2026 QGap-Projekt <https://con2.net/qgap/>
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version. See the LICENSE file for details.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qgap/model/public_screen_session.dart';
import 'package:qgap/services/public_screen_service.dart';

/// Separater Einstellungs-Dialog für PublicScreen-Sessions.
/// Vier Tabs: Start | Pause | Ende | Export
class PublicScreenSettingsDialog extends StatefulWidget {
  final PublicScreenSession session;

  const PublicScreenSettingsDialog({super.key, required this.session});

  @override
  State<PublicScreenSettingsDialog> createState() =>
      _PublicScreenSettingsDialogState();
}

class _PublicScreenSettingsDialogState
    extends State<PublicScreenSettingsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late PublicScreenSession _session;
  final PublicScreenService _service = PublicScreenService();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _session = widget.session;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ── Speichern ────────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _service.updateSettings(_session);
      if (!mounted) return;
      Navigator.of(context).pop(_session);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fehler: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              decoration: const BoxDecoration(
                color: Color(0xFF5A07E9),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Session-Einstellungen',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  TabBar(
                    controller: _tabController,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white60,
                    indicatorColor: Colors.white,
                    isScrollable: true,
                    tabs: const [
                      Tab(text: 'Start'),
                      Tab(text: 'Pause'),
                      Tab(text: 'Ende'),
                      Tab(text: 'Export'),
                      Tab(text: 'Liedtext'),
                    ],
                  ),
                ],
              ),
            ),
            // Tab-Inhalte
            SizedBox(
              height: 420,
              child: TabBarView(
                controller: _tabController,
                children: [
                  _SlideConfigTab(
                    config: _session.startConfig,
                    onChanged: (c) =>
                        setState(() => _session = _session.copyWith(startConfig: c)),
                  ),
                  _SlideConfigTab(
                    config: _session.pauseConfig,
                    onChanged: (c) =>
                        setState(() => _session = _session.copyWith(pauseConfig: c)),
                  ),
                  _SlideConfigTab(
                    config: _session.endConfig,
                    onChanged: (c) =>
                        setState(() => _session = _session.copyWith(endConfig: c)),
                  ),
                  _ExportSettingsTab(
                    settings: _session.exportSettings,
                    orientation: _session.orientation,
                    onChanged: (es, ori) => setState(() => _session =
                        _session.copyWith(exportSettings: es, orientation: ori)),
                  ),
                  _TextSlideSettingsTab(
                    textSizeMode: _session.textSizeMode,
                    fixedFontSize: _session.fixedFontSize,
                    ccliLicense: _session.ccliLicense,
                    onChanged: (mode, size, license) => setState(() => _session =
                        _session.copyWith(textSizeMode: mode, fixedFontSize: size, ccliLicense: license)),
                  ),
                ],
              ),
            ),
            // Aktions-Buttons
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: const Text('Abbrechen'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Speichern'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tab: SlideConfig (Start / Pause / Ende) – nur Text ───────────────────────

class _SlideConfigTab extends StatefulWidget {
  final SlideConfig config;
  final ValueChanged<SlideConfig> onChanged;

  const _SlideConfigTab({
    required this.config,
    required this.onChanged,
  });

  @override
  State<_SlideConfigTab> createState() => _SlideConfigTabState();
}

class _SlideConfigTabState extends State<_SlideConfigTab> {
  late TextEditingController _textController;
  late SlideConfig _config;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _textController = TextEditingController(text: _config.text);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged(_config);

  Future<void> _pickColor({required bool isText}) async {
    final current = isText ? _config.textColor : _config.bgColor;
    final controller = TextEditingController(text: current.replaceFirst('#', ''));

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isText ? 'Textfarbe (Hex)' : 'Hintergrundfarbe (Hex)'),
        content: TextField(
          controller: controller,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F]')),
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(
            prefixText: '#',
            border: OutlineInputBorder(),
            hintText: 'RRGGBB',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, '#${controller.text}'),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (result == null || result.length != 7) return;
    setState(() {
      _config = isText
          ? _config.copyWith(textColor: result)
          : _config.copyWith(bgColor: result);
    });
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _textController,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Anzeigetext',
              border: OutlineInputBorder(),
              helperText: 'Dieser Text wird auf dem Viewer-Bildschirm angezeigt.',
            ),
            onChanged: (v) {
              _config = _config.copyWith(text: v);
              _notify();
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Schriftgröße:'),
              Expanded(
                child: Slider(
                  value: _config.fontSize.toDouble(),
                  min: 16,
                  max: 120,
                  divisions: 26,
                  label: '${_config.fontSize}',
                  onChanged: (v) {
                    setState(() => _config = _config.copyWith(fontSize: v.toInt()));
                    _notify();
                  },
                ),
              ),
              Text('${_config.fontSize}px'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ColorSwatch(
                label: 'Textfarbe',
                hex: _config.textColor,
                onTap: () => _pickColor(isText: true),
              ),
              const SizedBox(width: 12),
              _ColorSwatch(
                label: 'Hintergrund',
                hex: _config.bgColor,
                onTap: () => _pickColor(isText: false),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Tab: Export-Einstellungen ─────────────────────────────────────────────────

class _ExportSettingsTab extends StatefulWidget {
  final ExportSettings settings;
  final PublicScreenOrientation orientation;
  final void Function(ExportSettings, PublicScreenOrientation) onChanged;

  const _ExportSettingsTab({
    required this.settings,
    required this.orientation,
    required this.onChanged,
  });

  @override
  State<_ExportSettingsTab> createState() => _ExportSettingsTabState();
}

class _ExportSettingsTabState extends State<_ExportSettingsTab> {
  late ExportSettings _settings;
  late PublicScreenOrientation _orientation;

  static const _resolutions = [
    (854, 480, '854×480 (SD)'),
    (1280, 720, '1280×720 (HD)'),
    (1920, 1080, '1920×1080 (Full HD)'),
    (2560, 1440, '2560×1440 (QHD)'),
  ];

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _orientation = widget.orientation;
  }

  void _notify() => widget.onChanged(_settings, _orientation);

  @override
  Widget build(BuildContext context) {
    final currentResKey = '${_settings.width}×${_settings.height}';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Auflösung
          const Text('Auflösung:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: currentResKey,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            items: _resolutions.map((r) {
              final key = '${r.$1}×${r.$2}';
              return DropdownMenuItem(value: key, child: Text(r.$3));
            }).toList(),
            onChanged: (v) {
              if (v == null) return;
              final found = _resolutions.firstWhere(
                (r) => '${r.$1}×${r.$2}' == v,
                orElse: () => (1920, 1080, ''),
              );
              setState(() => _settings = _settings.copyWith(
                width: found.$1, height: found.$2,
              ));
              _notify();
            },
          ),
          const SizedBox(height: 16),

          // Qualität
          Row(
            children: [
              const Text(
                'Qualität:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Expanded(
                child: Slider(
                  value: _settings.quality.toDouble(),
                  min: 10,
                  max: 100,
                  divisions: 18,
                  label: '${_settings.quality}',
                  onChanged: (v) {
                    setState(() => _settings = _settings.copyWith(quality: v.toInt()));
                    _notify();
                  },
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${_settings.quality}',
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'Empfohlen: 80  •  ${_settings.quality < 50 ? "Geringe Qualität" : _settings.quality < 85 ? "Gute Balance" : "Hohe Qualität"}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),

          // Format
          const Text('Format:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('JPG'),
                  subtitle: const Text('Universell'),
                  value: 'jpg',
                  groupValue: _settings.format,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setState(() => _settings = _settings.copyWith(format: v));
                    _notify();
                  },
                ),
              ),
              Expanded(
                child: RadioListTile<String>(
                  title: const Text('WebP'),
                  subtitle: const Text('~30% kleiner'),
                  value: 'webp',
                  groupValue: _settings.format,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setState(() => _settings = _settings.copyWith(format: v));
                    _notify();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Viewer-Orientierung
          const Text(
            'Viewer-Orientierung:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: RadioListTile<PublicScreenOrientation>(
                  title: const Text('Querformat'),
                  subtitle: const Text('(Landscape)'),
                  value: PublicScreenOrientation.landscape,
                  groupValue: _orientation,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setState(() => _orientation = v!);
                    _notify();
                  },
                ),
              ),
              Expanded(
                child: RadioListTile<PublicScreenOrientation>(
                  title: const Text('Hochformat'),
                  subtitle: const Text('(Portrait)'),
                  value: PublicScreenOrientation.portrait,
                  groupValue: _orientation,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) {
                    setState(() => _orientation = v!);
                    _notify();
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Tab: Text-Folien-Einstellungen (Schriftgrößen-Modus) ─────────────────────

class _TextSlideSettingsTab extends StatefulWidget {
  final TextSizeMode textSizeMode;
  final int fixedFontSize;
  final String ccliLicense;
  final void Function(TextSizeMode, int, String) onChanged;

  const _TextSlideSettingsTab({
    required this.textSizeMode,
    required this.fixedFontSize,
    required this.ccliLicense,
    required this.onChanged,
  });

  @override
  State<_TextSlideSettingsTab> createState() => _TextSlideSettingsTabState();
}

class _TextSlideSettingsTabState extends State<_TextSlideSettingsTab> {
  late TextSizeMode _mode;
  late int _fixedSize;
  late TextEditingController _ccliController;

  @override
  void initState() {
    super.initState();
    _mode = widget.textSizeMode;
    _fixedSize = widget.fixedFontSize;
    _ccliController = TextEditingController(text: widget.ccliLicense);
  }

  @override
  void dispose() {
    _ccliController.dispose();
    super.dispose();
  }

  void _notify() => widget.onChanged(_mode, _fixedSize, _ccliController.text);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Schriftgröße der Liedtext-Folien',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          const Text(
            'Diese Einstellung gilt für alle Text-Folien im Viewer.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),

          // Option 1: Pro Folie
          _ModeOption(
            value: TextSizeMode.perSlide,
            groupValue: _mode,
            title: 'Pro Folie: so groß wie möglich',
            subtitle: 'Jede Folie füllt den Bildschirm maximal aus.\n'
                'Folien mit wenig Text → größere Schrift.',
            onChanged: (v) { setState(() => _mode = v); _notify(); },
          ),
          const SizedBox(height: 8),

          // Option 2: Einheitlich
          _ModeOption(
            value: TextSizeMode.uniform,
            groupValue: _mode,
            title: 'Einheitlich: gleiche Größe für alle Folien',
            subtitle: 'Der Viewer passt die Schriftgröße automatisch an –\n'
                'immer so, dass die längste bisherige Folie passt.\n'
                'Kein Zeilenumbruch durch den Viewer.',
            onChanged: (v) { setState(() => _mode = v); _notify(); },
          ),
          const SizedBox(height: 8),

          // Option 3: Fest
          _ModeOption(
            value: TextSizeMode.fixed,
            groupValue: _mode,
            title: 'Feste Schriftgröße',
            subtitle: 'Immer exakt die eingestellte Pixelgröße.',
            onChanged: (v) { setState(() => _mode = v); _notify(); },
          ),

          // Schriftgrößen-Slider (nur bei 'fixed' sichtbar)
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            crossFadeState: _mode == TextSizeMode.fixed
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 12, left: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('Schriftgröße: '),
                      Expanded(
                        child: Slider(
                          value: _fixedSize.toDouble().clamp(12, 200),
                          min: 12,
                          max: 200,
                          divisions: 94,
                          label: '$_fixedSize px',
                          onChanged: (v) {
                            setState(() => _fixedSize = v.toInt());
                            _notify();
                          },
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Text(
                          '$_fixedSize px',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 8),
          const Text(
            'CCLI Gemeinde Präsentations-Lizenz',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          const Text(
            'Wird auf der Titelfolie jedes Liedes angezeigt.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _ccliController,
            decoration: const InputDecoration(
              labelText: 'Lizenz-Nummer',
              hintText: 'z.B. 2245587',
              border: OutlineInputBorder(),
              prefixText: 'CCLI Lizenz #',
            ),
            keyboardType: TextInputType.text,
            onChanged: (_) => _notify(),
          ),
        ],
      ),
    );
  }
}

// Kompakter Radio-Button mit Titel + Beschreibung
class _ModeOption extends StatelessWidget {
  final TextSizeMode value;
  final TextSizeMode groupValue;
  final String title;
  final String subtitle;
  final ValueChanged<TextSizeMode> onChanged;

  const _ModeOption({
    required this.value,
    required this.groupValue,
    required this.title,
    required this.subtitle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => onChanged(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey.shade300,
            width: selected ? 2 : 1,
          ),
          color: selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.06)
              : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Radio<TextSizeMode>(
              value: value,
              groupValue: groupValue,
              onChanged: (v) => onChanged(v!),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: selected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Hilfwidget: Farb-Swatch ───────────────────────────────────────────────────

class _ColorSwatch extends StatelessWidget {
  final String label;
  final String hex;
  final VoidCallback onTap;

  const _ColorSwatch({
    required this.label,
    required this.hex,
    required this.onTap,
  });

  Color _hexToColor(String h) {
    final clean = h.replaceFirst('#', '');
    return Color(int.parse('FF$clean', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: _hexToColor(hex),
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 11)),
                Text(hex, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(width: 4),
            const Icon(Icons.edit, size: 14, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
